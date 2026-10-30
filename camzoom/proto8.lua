
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v12)
-- @Brief   : CineCamera 关卡直写 + CameraCache.POV 结构探测
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = { inCombat = false }

---ViewTarget 日志
local function logVT(ins, tag)
  local okV, vt = pcall(function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
      return pcm.ViewTarget.Target
    end
    return nil
  end)
  if okV and vt then
    local okN, p = pcall(UE4.UKismetSystemLibrary.GetPathName, vt)
    lp('VT_' .. tag, okN and p or '?')
    return vt, okN and p or ''
  end
  lp('VT_' .. tag, 'nil')
  return nil, ''
end

---CameraCache.POV 结构探测 + 竞速写测试
local function testCameraCache()
  local okM, pcm = pcall(function()
    return UE4.UGameplayStatics.GetPlayerCameraManager(GetGameIns(), 0)
  end)
  if not okM or not pcm then
    lp('CC no pcm')
    return
  end
  local okR, fov = pcall(function() return pcm.CameraCache.POV.FOV end)
  lp('CC read FOV', tostring(okR), tostring(fov))
  if not okR then
    lp('CC struct unreadable')
    return
  end
  local okL, lx = pcall(function() return pcm.CameraCache.POV.Location.X end)
  lp('CC read LocX', tostring(okL), tostring(lx))
  -- 竞速写 2.5 秒
  lp('CC RACE begin (writing 45)')
  local minSeen = { v = 999 }
  local writes = { n = 0 }
  local function tick()
    writes.n = writes.n + 1
    pcall(function() pcm.CameraCache.POV.FOV = 45 end)
    local okR2, v = pcall(function() return pcm.CameraCache.POV.FOV end)
    if okR2 and v and v < minSeen.v then minSeen.v = v end
    if writes.n >= 155 then
      lp('CC RACE end writes=', writes.n, 'minReadback=', string.format('%.1f', minSeen.v))
    else
      UE4.Timer.Add(0.016, tick)
    end
  end
  tick()
end

---CineCamera 直写竞速测试（若 ViewTarget 是相机 Actor）
local function testCineCamera(vt)
  local okR, comp = pcall(function() return vt:K2_GetRootComponent() end)
  if not okR or not comp then
    lp('CINE root comp fail', tostring(okR))
    return
  end
  local okF, fov = pcall(function() return comp.FieldOfView end)
  lp('CINE comp fov', tostring(okF), tostring(fov))
  if not (okF and fov and fov > 1) then return end
  lp('CINE RACE begin (writing fov-30)')
  local minSeen = { v = 999 }
  local writes = { n = 0 }
  local target = fov - 30
  local function tick()
    writes.n = writes.n + 1
    pcall(function() comp.FieldOfView = target end)
    local okR2, v = pcall(function() return comp.FieldOfView end)
    if okR2 and v and v < minSeen.v then minSeen.v = v end
    if writes.n >= 155 then
      pcall(function() comp.FieldOfView = fov end)
      lp('CINE RACE end writes=', writes.n, 'minReadback=', string.format('%.1f', minSeen.v))
    else
      UE4.Timer.Add(0.016, tick)
    end
  end
  tick()
end

function Z.Poll()
  local okIns, ins = pcall(GetGameIns)
  if not okIns or not ins then return end
  local okP, pc = pcall(UE4.UGameplayStatics.GetPlayerController, ins, 0)
  if not okP or not pc then return end
  local okN, ctrlPath = pcall(UE4.UKismetSystemLibrary.GetPathName, pc)
  if not okN then return end

  local isCombat = string.find(ctrlPath or '', 'GameController', 1, true) ~= nil
    or string.find(ctrlPath or '', 'FightController', 1, true) ~= nil

  if isCombat and not Z.inCombat then
    Z.inCombat = true
    lp('ENTER_COMBAT')
    Z.testsDone = false
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
  end

  if not Z.inCombat or Z.testsDone then return end

  -- 进战斗 2 秒后跑一轮测试
  Z.testsDone = true
  UE4.Timer.Add(2, function()
    local vt, path = logVT(ins, 'NOW')
    if path and string.find(path, 'CineCamera', 1, true) then
      lp('CINE level detected')
      testCineCamera(vt)
      UE4.Timer.Add(3.2, testCameraCache)
    else
      testCameraCache()
    end
  end)
end

local codeCount = {}
EventSystem.On(Event.PCKeyboardEvent, function(...)
  local n = select('#', ...)
  if n >= 1 then
    local key = tostring(select(1, ...)) .. '|' .. tostring(n >= 2 and select(2, ...) or '?')
    codeCount[key] = (codeCount[key] or 0) + 1
  end
end)

function Z.StartPolling()
  UE4.Timer.Add(0.03, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 8 then lp('Poll ERR', tostring(err)) end
    end
    if (Z.tick or 0) % 100 == 0 then
      local parts = {}
      for k, v in pairs(codeCount) do
        parts[#parts + 1] = k .. 'x' .. v
        codeCount[k] = 0
      end
      table.sort(parts)
      lp('CODE_SUMMARY', table.concat(parts, ' '))
    end
    Z.tick = (Z.tick or 0) + 1
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v12 online')
    Z.StartPolling()
  end)
end)

lp('v12 injected, waiting Logined')
