
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v4)
-- @Brief   : 战斗滚轮缩放镜头 - 原型实现
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = {
  inCombat = false,
  camActor = nil,
  camComp = nil,
  camCompHow = 'none',
  fovBase = nil,
  level = 0,
  step = 2.5,        -- 每格滚轮的 FOV 变化量
  fovMin = 35,
  fovMax = 95,
  lastAxis = 0,
  pollCount = 0,
  probeDone = false,
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

---尝试多种方式拿到相机组件
local function resolveCameraComponent(vt)
  local tries = {
    { how = 'GetCineCameraComponent', fn = function() return vt:GetCineCameraComponent() end },
    { how = 'prop CineCameraComponent', fn = function() return vt.CineCameraComponent end },
    { how = 'GetCameraComponent', fn = function() return vt:GetCameraComponent() end },
    { how = 'prop CameraComponent', fn = function() return vt.CameraComponent end },
  }
  for _, t in ipairs(tries) do
    local ok, comp = pcall(t.fn)
    if ok and comp then
      return comp, t.how
    end
  end
  return nil, 'unresolved'
end

---进入战斗：定位相机并记录基础 FOV
function Z.OnEnterCombat(ins)
  lp('ENTER_COMBAT probe begin')
  local okV, vt = pcall(function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
      return pcm.ViewTarget.Target
    end
    return nil
  end)
  if not okV or not vt then
    lp('  no view target yet, will retry')
    return
  end
  Z.camActor = vt
  lp('  camActor', UE4.UKismetSystemLibrary.GetPathName(vt))
  local comp, how = resolveCameraComponent(vt)
  Z.camComp = comp
  Z.camCompHow = how
  lp('  camComp', how, comp and UE4.UKismetSystemLibrary.GetPathName(comp) or 'nil')
  if comp then
    local okF, fov = pcall(function() return comp.FieldOfView end)
    if okF then
      Z.fovBase = fov
      lp('  fovBase', fov)
    else
      lp('  FieldOfView read ERR', tostring(fov))
    end
    -- 探测写能力
    local okW = pcall(function() comp.FieldOfView = comp.FieldOfView end)
    lp('  FieldOfView write pcall', tostring(okW))
  end
  -- 轴值读取探测
  local okP, pc = pcall(UE4.UGameplayStatics.GetPlayerController, ins, 0)
  if okP and pc then
    local okA, v = pcall(function() return pc:GetInputAxisValue('MouseWheelAxis') end)
    lp('  GetInputAxisValue(MouseWheelAxis)', tostring(okA), tostring(v))
    if not okA then
      local okB, v2 = pcall(function() return pc:GetInputAxisKeyValue(UE4.FKey('MouseWheelAxis')) end)
      lp('  GetInputAxisKeyValue', tostring(okB), tostring(v2))
    end
  end
  lp('ENTER_COMBAT probe end')
end

function Z.OnLeaveCombat()
  lp('LEAVE_COMBAT, restoring fov', tostring(Z.fovBase))
  if Z.camComp and Z.fovBase then
    pcall(function() Z.camComp.FieldOfView = Z.fovBase end)
  end
  Z.camActor = nil
  Z.camComp = nil
  Z.camCompHow = 'none'
  Z.fovBase = nil
  Z.level = 0
  Z.probeDone = false
end

---应用当前缩放
function Z.ApplyZoom()
  if not Z.camComp or not Z.fovBase then return end
  local fov = clamp(Z.fovBase - Z.level * Z.step, Z.fovMin, Z.fovMax)
  local ok, err = pcall(function() Z.camComp.FieldOfView = fov end)
  if not ok then
    lp('ApplyZoom ERR', tostring(err))
    Z.camComp = nil
    return
  end
end

---轮询：轴值 + 相机状态变化
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
    Z.OnEnterCombat(ins)
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    Z.OnLeaveCombat()
  end

  if Z.inCombat then
    -- 轴值轮询
    local okA, v = pcall(function() return pc:GetInputAxisValue('MouseWheelAxis') end)
    if okA and v and v ~= 0 then
      Z.level = clamp(Z.level + v, -24, 24)
      lp('WHEEL', v, '-> level', Z.level)
      Z.ApplyZoom()
      local okR, fov = pcall(function() return Z.camComp and Z.camComp.FieldOfView or -1 end)
      lp('  fov now', tostring(fov))
    end
  end
end

function Z.StartPolling()
  UE4.Timer.Add(0.03, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 5 then lp('Poll ERR', tostring(err)) end
    end
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v4 online')
    Z.StartPolling()
  end)
end)

lp('v4 injected, waiting Logined')
