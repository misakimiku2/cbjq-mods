
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v9)
-- @Brief   : 滚轮键值校准 + FOV 视觉验证
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
}

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

---PCKeyboardEvent 键值直方图（找出滚轮上下对应的 code）
local codeCount = {}
EventSystem.On(Event.PCKeyboardEvent, function(...)
  local n = select('#', ...)
  if n >= 1 then
    local code = tostring(select(1, ...))
    local pressed = n >= 2 and tostring(select(2, ...)) or '?'
    local key = code .. '|' .. pressed
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

---FOV 视觉验证：进战斗 3 秒后 FOV=45 保持 2 秒再恢复
local function fovVisualTest()
  local okP, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, GetGameIns(), 0)
  if not okP or not pawn then
    lp('FOVTEST no pawn')
    return
  end
  local okC, cam = pcall(function() return pawn.Camera end)
  if not okC or not cam then
    lp('FOVTEST no pawn.Camera')
    return
  end
  local okR, f1 = pcall(function() return cam.FieldOfView end)
  lp('FOVTEST before', tostring(f1))
  local okW = pcall(function() cam.FieldOfView = 45 end)
  lp('FOVTEST set45 pcall', tostring(okW))
  UE4.Timer.Add(2, function()
    local okR2, f2 = pcall(function() return cam.FieldOfView end)
    lp('FOVTEST readback', tostring(f2))
    pcall(function() cam.FieldOfView = f1 or f2 end)
    lp('FOVTEST restored to', tostring(f1))
  end)
end

---角色相机解析
local function resolvePawnCamera(ins)
  if Z.camComp then return end
  local okP, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
  if not okP or not pawn then return end
  local okC, cam = pcall(function() return pawn.Camera end)
  if okC and cam then
    local okR, fov = pcall(function() return cam.FieldOfView end)
    if okR and fov and fov > 1 then
      Z.camComp = cam
      Z.camCompHow = 'pawn.Camera'
      Z.fovBase = fov
      lp('CAM_RESOLVED via pawn.Camera fovBase=', fov)
    end
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
    Z.testDone = false
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
    if Z.camComp and Z.fovBase then
      pcall(function() Z.camComp.FieldOfView = Z.fovBase end)
    end
    Z.camComp = nil
    Z.fovBase = nil
    Z.level = 0
  end

  if not Z.inCombat then return end

  if not Z.camComp then
    resolvePawnCamera(ins)
  end

  -- 进战斗 3 秒后做一次 FOV 视觉验证
  if Z.camComp and not Z.testDone then
    Z.testDone = true
    UE4.Timer.Add(3, fovVisualTest)
  end

  -- 滚轮键值轮询（用已知可能存在的键名）
  local okI, down1 = pcall(function() return pc:IsInputKeyDown('MouseScrollUp') end)
  if okI and down1 then lp('KEY MouseScrollUp down') end
  local okI2, down2 = pcall(function() return pc:IsInputKeyDown('MouseScrollDown') end)
  if okI2 and down2 then lp('KEY MouseScrollDown down') end
end

function Z.StartPolling()
  UE4.Timer.Add(0.02, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 8 then lp('Poll ERR', tostring(err)) end
    end
    if (Z.tick or 0) % 100 == 0 then
      summarizeCodes()
    end
    Z.tick = (Z.tick or 0) + 1
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v9 online')
    Z.StartPolling()
  end)
end)

lp('v9 injected, waiting Logined')
