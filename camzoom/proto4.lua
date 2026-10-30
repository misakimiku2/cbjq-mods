
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v8)
-- @Brief   : 滚轮动作映射 + 按键轮询 + 事件汇总 + 角色相机属性探测
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
  wheelKeyHit = 0,
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

---事件汇总：每 2 秒输出一次计数，避免刷屏又能发现新事件
local evCount = {}
local evSummarized = 0
local function hookSummary(name)
  EventSystem.On(Event[name], function(...)
    evCount[name] = (evCount[name] or 0) + 1
  end)
  evCount[name] = evCount[name] or 0
  lp('hooked(summary)', name)
end

hookSummary('PCKeyboardEvent')
hookSummary('OnKeyboardKeyPressed')
hookSummary('MouseButtonDown')
hookSummary('MouseButtonUp')
hookSummary('MouseMove')
hookSummary('OnGamepadAnalogInput')

local function summarizeEvents()
  local parts = {}
  for k, v in pairs(evCount) do
    parts[#parts + 1] = k .. '=' .. v
    evCount[k] = 0
  end
  evSummarized = evSummarized + 1
  if evSummarized <= 30 then
    lp('EV_SUMMARY', table.concat(parts, ','))
  end
end

---滚轮按键轮询：MouseScrollUp/Down/Axis 直接查按键按下态
local wheelKeys = { 'MouseScrollUp', 'MouseScrollDown', 'MouseWheelAxis' }
local keyErrLogged = {}
local function pollWheelKeys(pc)
  for _, keyName in ipairs(wheelKeys) do
    local ok, down = pcall(function() return pc:IsInputKeyDown(keyName) end)
    if not ok then
      if not keyErrLogged[keyName] then
        keyErrLogged[keyName] = true
        lp('IsInputKeyDown ERR', keyName, tostring(down))
      end
    elseif down then
      Z.wheelKeyHit = Z.wheelKeyHit + 1
      if Z.wheelKeyHit <= 8 then
        lp('WHEELKEY_DOWN', keyName)
      end
    end
  end
end

---角色身上相机属性名探测
local pawnPropNames = { 'CameraComponent', 'Camera', 'FollowCamera', 'ArmsCamera', 'CameraBoom', 'SpringArm', 'MyCamera' }
local pawnProbed = false
local function probePawnCamera(ins)
  if pawnProbed then return end
  pawnProbed = true
  local okP, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
  if not okP or not pawn then return end
  lp('PAWN', UE4.UKismetSystemLibrary.GetPathName(pawn))
  for _, name in ipairs(pawnPropNames) do
    local ok, v = pcall(function() return pawn[name] end)
    if ok and v and v ~= 0 then
      local okF, fov = pcall(function() return v.FieldOfView end)
      lp('PAWN_PROP', name, 'fov=', tostring(fov))
      if okF and fov and fov > 1 and not Z.camComp then
        Z.camComp = v
        Z.camCompHow = 'pawn.' .. name
        Z.fovBase = fov
        lp('CAM_RESOLVED via pawn.' .. name, 'fovBase=', fov)
      end
    end
  end
  -- PlayerCameraManager 的 DefaultFOV 写测试
  local okM, pcm = pcall(UE4.UGameplayStatics.GetPlayerCameraManager, ins, 0)
  if okM and pcm then
    local okR, f1 = pcall(function() return pcm.DefaultFOV end)
    lp('PCM DefaultFOV read', tostring(f1))
    local okW = pcall(function() pcm.DefaultFOV = 50 end)
    local okR2, f2 = pcall(function() return pcm.DefaultFOV end)
    lp('PCM DefaultFOV write pcall', tostring(okW), 'readback=', tostring(f2))
    pcall(function() pcm.DefaultFOV = f1 end)
  end
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
    lp('LEAVE_COMBAT restore', tostring(Z.fovBase))
    if Z.camComp and Z.fovBase then
      pcall(function() Z.camComp.FieldOfView = Z.fovBase end)
    end
    Z.camComp = nil
    Z.camCompHow = 'none'
    Z.fovBase = nil
    Z.level = 0
    pawnProbed = false
  end

  if not Z.inCombat then return end

  pollWheelKeys(pc)

  -- 滚轮轴值仍保留探测
  local okA, v = pcall(function() return pc:GetInputAxisValue('MouseWheelAxis') end)
  if okA and v and v ~= 0 then
    local newLevel = clamp(Z.level + v, -30, 30)
    if newLevel ~= Z.level then
      Z.level = newLevel
      lp('WHEEL_AXIS', v, '-> level', Z.level)
    end
  end

  if not Z.camComp then
    probePawnCamera(ins)
  end
end

function Z.StartPolling()
  UE4.Timer.Add(0.02, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 8 then lp('Poll ERR', tostring(err)) end
    end
    if (Z.pollTick or 0) % 100 == 0 then
      summarizeEvents()
    end
    Z.pollTick = (Z.pollTick or 0) + 1
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v8 online')
    Z.StartPolling()
  end)
end)

lp('v8 injected, waiting Logined')
