
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v10)
-- @Brief   : LockedFOV 测试 + FOV 竞速验证 + 滚轮 FKey 提取 + 轴名普查
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = {
  inCombat = false,
  camComp = nil,
  pcm = nil,
  fovBase = nil,
  raceTestDone = false,
  lockedTestDone = false,
}

---轴名普查：用大字典发现所有活着的轴
local axisDict = {
  'LookUp', 'Turn', 'LookUpRate', 'TurnRate', 'Mouse2D', 'MouseXY', 'MouseX', 'MouseY',
  'MouseTurn', 'MouseLook', 'Yaw', 'Pitch', 'MouseYaw', 'MousePitch',
  'MouseWheelAxis', 'WheelAxis', 'MouseWheel', 'Wheel', 'MouseScrollUp', 'MouseScrollDown',
  'ScrollWheel', 'ZoomWheel', 'CameraZoom', 'ZoomIn', 'ZoomOut', 'Zoom',
  'MoveForward', 'MoveRight', 'CameraX', 'CameraY', 'ViewX', 'ViewY',
}
local axisLive = {}
local function probeAxes(pc)
  for _, name in ipairs(axisDict) do
    if not axisLive[name] then
      local ok, v = pcall(function() return pc:GetInputAxisValue(name) end)
      if ok and v and math.abs(v) > 0.0001 then
        axisLive[name] = string.format('%.3f', v)
        lp('AXIS_LIVE', name, string.format('%.3f', v))
      end
    end
  end
end

---OnKeyboardKeyPressed：尝试提取 FKey 名字（找滚轮的方向键名）
EventSystem.On(Event.OnKeyboardKeyPressed, function(...)
  local n = select('#', ...)
  if n >= 1 then
    local key = select(1, ...)
    local ok1, name1 = pcall(function() return key:GetName() end)
    local ok2, name2 = pcall(function() return UE4.UKismetInputLibrary.Key_GetName(key) end)
    local ok3, name3 = pcall(function() return key:GetFName() end)
    if (Z.fkeyLog or 0) < 10 then
      Z.fkeyLog = (Z.fkeyLog or 0) + 1
      lp('FKEY', tostring(ok1), tostring(name1), tostring(ok2), tostring(name2), tostring(ok3), tostring(name3))
    end
  end
end)

local codeCount = {}
EventSystem.On(Event.PCKeyboardEvent, function(...)
  local n = select('#', ...)
  if n >= 1 then
    local key = tostring(select(1, ...)) .. '|' .. tostring(n >= 2 and select(2, ...) or '?')
    codeCount[key] = (codeCount[key] or 0) + 1
  end
end)

local function summarizeCodes()
  local parts = {}
  for k, v in pairs(codeCount) do
    parts[#parts + 1] = k .. 'x' .. v
    codeCount[k] = 0
  end
  table.sort(parts)
  lp('CODE_SUMMARY', table.concat(parts, ' '))
end

---测试 1：PlayerCameraManager.LockedFOV 直写
local function testLockedFOV()
  if Z.lockedTestDone then return end
  Z.lockedTestDone = true
  local okM, pcm = pcall(UE4.UGameplayStatics.GetPlayerCameraManager(GetGameIns(), 0))
  if not okM or not pcm then
    lp('LOCKED no pcm')
    return
  end
  local okR, cur = pcall(function() return pcm.LockedFOV end)
  lp('LOCKED read', tostring(okR), tostring(cur))
  local okW = pcall(function() pcm.LockedFOV = 50 end)
  local okR2, now = pcall(function() return pcm.LockedFOV end)
  lp('LOCKED write pcall', tostring(okW), 'readback', tostring(now))
  if okR2 and now == 50 then
    lp('LOCKED seems writable, keeping 50 for 2s then restore')
    UE4.Timer.Add(2, function()
      pcall(function() pcm.LockedFOV = 0 end)
      lp('LOCKED restored 0')
    end)
  end
end

---测试 2：FOV 竞速——每帧重写 pawn.Camera.FieldOfView，持续 2.5 秒，看最小回读值
local function raceTick(cam, writes, minSeen)
  writes = writes + 1
  pcall(function() cam.FieldOfView = 45 end)
  local okR, v = pcall(function() return cam.FieldOfView end)
  if okR and v and v < minSeen.v then minSeen.v = v end
  if writes >= 155 then
    pcall(function() cam.FieldOfView = Z.fovBase or 75 end)
    lp('RACE end writes=', writes, 'minReadback=', string.format('%.1f', minSeen.v))
  else
    UE4.Timer.Add(0.016, function() raceTick(cam, writes, minSeen) end)
  end
end

local function startRaceTest()
  if Z.raceTestDone then return end
  Z.raceTestDone = true
  local cam = Z.camComp
  if not cam then
    lp('RACE no camComp')
    return
  end
  lp('RACE begin, forcing 45 every tick for 2.5s')
  raceTick(cam, 0, { v = 999 })
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
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
    if Z.camComp and Z.fovBase then
      pcall(function() Z.camComp.FieldOfView = Z.fovBase end)
    end
    Z.camComp = nil
    Z.fovBase = nil
  end

  if not Z.inCombat then return end

  -- 角色相机解析
  if not Z.camComp then
    local okP2, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
    if okP2 and pawn then
      local okC, cam = pcall(function() return pawn.Camera end)
      if okC and cam then
        local okR, fov = pcall(function() return cam.FieldOfView end)
        if okR and fov and fov > 1 then
          Z.camComp = cam
          Z.fovBase = fov
          lp('CAM_RESOLVED via pawn.Camera fovBase=', fov)
        end
      end
    end
  end

  -- 定时启动两个测试
  if not Z.testTimerSet then
    Z.testTimerSet = true
    UE4.Timer.Add(3, function()
      testLockedFOV()
      startRaceTest()
    end)
  end

  -- 滚轮事件计数照常（确认 13|true 仍在）
  probeAxes(pc)
end

function Z.StartPolling()
  UE4.Timer.Add(0.03, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 8 then lp('Poll ERR', tostring(err)) end
    end
    if (Z.tick or 0) % 66 == 0 then
      summarizeCodes()
    end
    Z.tick = (Z.tick or 0) + 1
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v10 online')
    Z.StartPolling()
  end)
end)

lp('v10 injected, waiting Logined')
