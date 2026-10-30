
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v7)
-- @Brief   : 滚轮轴(+前缀追加) + FOV 缩放 + ViewTarget 记录
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = {
  inCombat = false,
  camComp = nil,
  camCompHow = 'none',
  fovBase = nil,
  level = 0,
  step = 2.0,
  fovMin = 35,
  fovMax = 95,
  probeTried = 0,
  vtLogCount = 0,
  lastVtPath = '',
  lastVtLog = 0,
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

---战斗中周期性记录 ViewTarget 真实身份
local function logViewTarget(ins)
  Z.lastVtLog = Z.lastVtLog + 1
  if Z.lastVtLog % 50 ~= 0 then return end
  if Z.vtLogCount >= 8 then return end
  local okV, vt = pcall(function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
      return pcm.ViewTarget.Target
    end
    return nil
  end)
  local path = 'nil'
  if okV and vt then
    local okN, p = pcall(UE4.UKismetSystemLibrary.GetPathName, vt)
    path = okN and p or 'unresolved'
  end
  if path ~= Z.lastVtPath then
    Z.vtLogCount = Z.vtLogCount + 1
    Z.lastVtPath = path
    lp('VT_NOW', path)
  end
end

---扩展轴名探测
local axisCandidates = {
  'MouseWheelAxis', 'MouseScrollUp', 'MouseScrollDown', 'WheelAxis', 'Wheel',
  'ZoomWheel', 'CameraZoom', 'ZoomIn', 'ZoomOut', 'ScrollWheel', 'MouseWheel',
  'LookUp', 'Turn', 'Mouse2D',
}
local axisLogged = {}
local function probeAxes(pc)
  for _, name in ipairs(axisCandidates) do
    local ok, v = pcall(function() return pc:GetInputAxisValue(name) end)
    if ok and v and math.abs(v) > 0.001 then
      axisLogged[name] = (axisLogged[name] or 0) + 1
      if axisLogged[name] <= 2 then
        lp('AXIS_LIVE', name, string.format('%.3f', v))
      end
    end
  end
end

---解析相机组件
function Z.TryResolveCamera(ins)
  Z.probeTried = Z.probeTried + 1

  local okV, vt = pcall(function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
      return pcm.ViewTarget.Target
    end
    return nil
  end)
  if okV and vt then
    local okN, vtPath = pcall(UE4.UKismetSystemLibrary.GetPathName, vt)
    if okN and vtPath then
      local okR, comp = pcall(function() return vt:K2_GetRootComponent() end)
      if okR and comp then
        local okF, fov = pcall(function() return comp.FieldOfView end)
        if okF and fov and fov > 1 then
          Z.camComp = comp
          Z.camCompHow = 'ViewTarget.Root'
          Z.fovBase = fov
          lp('CAM_RESOLVED', 'attempt', Z.probeTried, 'path=', vtPath, 'fovBase=', fov)
          return
        end
      end
    end
  end

  -- 备用：CameraManager 的 POV/默认 FOV
  if Z.probeTried == 30 then
    local okP, pcm = pcall(UE4.UGameplayStatics.GetPlayerCameraManager, ins, 0)
    if okP and pcm then
      local okD, dfov = pcall(function() return pcm.DefaultFOV end)
      lp('CameraManager.DefaultFOV', tostring(okD), tostring(dfov))
      local okS, sfov = pcall(function() return pcm:SetFOV(60) end)
      lp('CameraManager.SetFOV probe', tostring(okS), tostring(sfov))
      if okS then
        Z.camComp = pcm
        Z.camCompHow = 'PlayerCameraManager.SetFOV'
        Z.fovBase = dfov or 90
        lp('CAM_RESOLVED via CameraManager, fovBase=', tostring(Z.fovBase))
      end
    end
  end

  if Z.probeTried == 20 or Z.probeTried == 80 or Z.probeTried == 200 then
    lp('CAM retrying, attempt', Z.probeTried)
  end
end

function Z.ApplyZoom()
  if not Z.camComp or not Z.fovBase then return end
  local fov = clamp(Z.fovBase - Z.level * Z.step, Z.fovMin, Z.fovMax)
  local ok, err = pcall(function() Z.camComp.FieldOfView = fov end)
  if not ok then
    -- CameraManager 路线用 SetFOV
    local ok2 = pcall(function() Z.camComp:SetFOV(fov) end)
    if not ok2 then
      lp('ApplyZoom ERR', tostring(err))
      return
    end
  end
  local okR, fovNow = pcall(function()
    if Z.camCompHow == 'PlayerCameraManager.SetFOV' then return -1 end
    return Z.camComp.FieldOfView
  end)
  lp('APPLY level=', Z.level, 'target=', string.format('%.1f', fov), 'readback=', string.format('%.1f', fovNow or -1))
end

function Z.OnLeaveCombat()
  lp('LEAVE_COMBAT')
  if Z.camComp and Z.fovBase and Z.camCompHow ~= 'PlayerCameraManager.SetFOV' then
    pcall(function() Z.camComp.FieldOfView = Z.fovBase end)
  end
  Z.camComp = nil
  Z.camCompHow = 'none'
  Z.fovBase = nil
  Z.level = 0
  Z.probeTried = 0
  Z.vtLogCount = 0
  Z.lastVtLog = 0
  Z.lastVtPath = ''
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
    Z.OnLeaveCombat()
  end

  if not Z.inCombat then return end

  -- 主通道：滚轮轴
  local okA, v = pcall(function() return pc:GetInputAxisValue('MouseWheelAxis') end)
  if okA and v and v ~= 0 then
    local newLevel = clamp(Z.level + v, -30, 30)
    if newLevel ~= Z.level then
      Z.level = newLevel
      lp('WHEEL', v, '-> level', Z.level)
      if Z.camComp then Z.ApplyZoom() end
    end
  end

  -- 扩展轴名探测（前 60 秒）
  if Z.probeTried < 2000 then
    probeAxes(pc)
  end

  logViewTarget(ins)

  if not Z.camComp then
    Z.TryResolveCamera(ins)
  end
end

local hookCaps = { OnKeyboardKeyPressed = 3, PCKeyboardEvent = 3 }
for name, cap in pairs(hookCaps) do
  if Event[name] then
    local n = 0
    EventSystem.On(Event[name], function(...)
      n = n + 1
      if n > cap then return end
      local cnt = select('#', ...)
      local args = {}
      for i = 1, cnt do
        local v = select(i, ...)
        args[i] = type(v) == 'table' and 'table' or tostring(v)
      end
      lp('EV ' .. name, table.concat(args, ' | '))
    end)
  end
end

function Z.StartPolling()
  UE4.Timer.Add(0.03, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 8 then lp('Poll ERR', tostring(err)) end
    end
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v7 online')
    Z.StartPolling()
  end)
end)

lp('v7 injected, waiting Logined')
