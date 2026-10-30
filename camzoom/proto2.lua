
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v5)
-- @Brief   : 战斗滚轮缩放镜头 - FOV 主方案 + 位移备选
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
  step = 2.0,
  fovMin = 35,
  fovMax = 95,
  lastLoggedLevel = 0,
  stateLogCount = 0,
  probeTried = 0,
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

---持续重试定位相机组件（进战斗后 CineCameraActor 稍后才接管 ViewTarget）
function Z.TryResolveCamera(ins)
  Z.probeTried = Z.probeTried + 1
  if Z.probeTried > 100 then return end

  local okV, vt = pcall(function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
      return pcm.ViewTarget.Target
    end
    return nil
  end)
  if not okV or not vt then return end
  Z.camActor = vt

  local okN, vtPath = pcall(UE4.UKismetSystemLibrary.GetPathName, vt)
  if not okN then return end
  if not string.find(vtPath or '', 'Camera', 1, true) then
    -- ViewTarget 还没切到相机
    return
  end

  lp('CAM_ACTOR', vtPath)

  local tries = {
    { how = 'K2_GetRootComponent', fn = function() return vt:K2_GetRootComponent() end },
    { how = 'GetCineCameraComponent', fn = function() return vt:GetCineCameraComponent() end },
    { how = 'prop CineCameraComponent', fn = function() return vt.CineCameraComponent end },
  }
  for _, t in ipairs(tries) do
    local ok, comp = pcall(t.fn)
    if ok and comp then
      local okF, fov = pcall(function() return comp.FieldOfView end)
      if okF and fov and fov > 1 then
        Z.camComp = comp
        Z.camCompHow = t.how
        Z.fovBase = fov
        lp('CAM_RESOLVED via', t.how, 'fovBase=', fov)
        return
      else
        lp('  comp got via', t.how, 'but FieldOfView read fail', tostring(okF), tostring(fov))
      end
    end
  end
  lp('  cam component unresolved this round')
end

function Z.OnEnterCombat(ins)
  lp('ENTER_COMBAT')
end

function Z.OnLeaveCombat()
  lp('LEAVE_COMBAT restore fov', tostring(Z.fovBase))
  if Z.camComp and Z.fovBase then
    pcall(function() Z.camComp.FieldOfView = Z.fovBase end)
  end
  Z.camActor = nil
  Z.camComp = nil
  Z.camCompHow = 'none'
  Z.fovBase = nil
  Z.level = 0
  Z.probeTried = 0
end

function Z.ApplyZoom()
  if not Z.camComp or not Z.fovBase then return end
  local fov = clamp(Z.fovBase - Z.level * Z.step, Z.fovMin, Z.fovMax)
  local ok, err = pcall(function() Z.camComp.FieldOfView = fov end)
  if not ok then
    lp('ApplyZoom write ERR', tostring(err))
  end
  -- 回读验证
  local okR, fovNow = pcall(function() return Z.camComp.FieldOfView end)
  lp('APPLY level=', Z.level, 'target=', string.format('%.1f', fov), 'readback=', string.format('%.1f', fovNow or -1))
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
    Z.OnEnterCombat(ins)
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    Z.OnLeaveCombat()
  end

  if not Z.inCombat then return end

  -- 相机还没解析就继续重试
  if not Z.camComp then
    Z.TryResolveCamera(ins)
    return
  end

  -- 滚轮轴轮询
  local okA, v = pcall(function() return pc:GetInputAxisValue('MouseWheelAxis') end)
  if okA and v and v ~= 0 then
    local newLevel = clamp(Z.level + v, -30, 30)
    if newLevel ~= Z.level then
      Z.level = newLevel
      lp('WHEEL', v, '-> level', Z.level)
      Z.ApplyZoom()
    end
  end

  -- 状态回读（限频）
  if Z.stateLogCount < 12 and Z.level ~= Z.lastLoggedLevel then
    Z.stateLogCount = Z.stateLogCount + 1
    Z.lastLoggedLevel = Z.level
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
    lp('prototype v5 online')
    Z.StartPolling()
  end)
end)

lp('v5 injected, waiting Logined')
