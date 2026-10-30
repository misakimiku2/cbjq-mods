
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v17)
-- @Brief   : AddCameraDataOffset 位移缩放视觉测试
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = { inCombat = false }

---把 pcm 转成定制相机管理器
local function getCustomCam()
  local okM, pcm = pcall(function()
    return UE4.UGameplayStatics.GetPlayerCameraManager(GetGameIns(), 0)
  end)
  if not okM or not pcm then
    lp('CC no pcm')
    return nil
  end
  local okC, cam = pcall(function() return pcm:Cast(UE4.AThirdPersonPlayerCameraManager) end)
  if not okC or not cam then
    lp('CC cast fail', tostring(okC), tostring(cam))
    return nil
  end
  return cam
end

---方法存在性探测
local function probeMethods(cam)
  local methods = { 'AddCameraDataOffset', 'AddCameraDataOffsetWithRotate', 'ClearCameraDataOffset',
    'SetFollowCamera', 'SetSocketCameraInfo', 'SetTempCameraInfo', 'SetYawLimit',
    'ChangeCurrentViewTargetTransformWithBlend', 'GetPlayerCameraComponentTrans', 'SetCameraPitchInterpTo' }
  for _, m in ipairs(methods) do
    local ok, r = pcall(function() return cam[m] end)
    lp('METHOD', m, 'exists=', tostring(ok and r ~= nil))
  end
end

---位移测试：加偏移 2.5 秒后清除
local function testOffset(cam, vec, tag)
  local ok1, r1 = pcall(function() return cam:AddCameraDataOffset(vec) end)
  lp('OFFSET ' .. tag, 'add pcall=', tostring(ok1), tostring(r1))
  if ok1 then
    UE4.Timer.Add(2.5, function()
      pcall(function() cam:ClearCameraDataOffset() end)
      lp('OFFSET ' .. tag .. ' cleared')
    end)
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
    Z.testsDone = false
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
  end

  if not Z.inCombat or Z.testsDone then return end
  Z.testsDone = true

  UE4.Timer.Add(2, function()
    local cam = getCustomCam()
    if not cam then return end
    lp('CUSTOM CAM OK')
    probeMethods(cam)
    -- 三段位移测试：Z-120（可能是后退/拉近）→ Z+120 → Y+120
    testOffset(cam, UE4.FVector(0, 0, -120), 'Zm120')
    UE4.Timer.Add(3, function() testOffset(cam, UE4.FVector(0, 0, 120), 'Zp120') end)
    UE4.Timer.Add(6, function() testOffset(cam, UE4.FVector(0, 120, 0), 'Yp120') end)
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
    lp('prototype v17 online')
    Z.StartPolling()
  end)
end)

lp('v17 injected, waiting Logined')
