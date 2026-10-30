
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v13)
-- @Brief   : SetCameraFOV 绑定探测 + 相机 Boom 属性普查
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = { inCombat = false, fovSet = false, savedFov = nil }

local function getPC()
  local okIns, ins = pcall(GetGameIns)
  if not okIns or not ins then return nil end
  local okP, pc = pcall(UE4.UGameplayStatics.GetPlayerController, ins, 0)
  if okP then return pc end
  return nil
end

---进战斗后跑一轮探测
local function runProbes(pc)
  -- 1. SetCameraFOV 挂在谁身上
  local candidates = {
    { tag = 'pc', obj = pc },
    { tag = 'pawn', obj = select(2, pcall(UE4.UGameplayStatics.GetPlayerPawn, GetGameIns(), 0)) },
    { tag = 'pcm', obj = select(2, pcall(UE4.UGameplayStatics.GetPlayerCameraManager, GetGameIns(), 0)) },
  }
  for _, c in ipairs(candidates) do
    if c.obj then
      local ok, r = pcall(function() return c.obj:SetCameraFOV(nil) end)
      lp('PROBE SetCameraFOV on ' .. c.tag, 'callable=', tostring(ok), tostring(r))
    end
  end
  -- 2. 全局函数存在性
  lp('GLOBAL SetCameraFOV type=', type(_G.SetCameraFOV), 'CreateUniversalCamera=', type(_G.CreateUniversalCamera), 'SetViewTargetToUniversalCamera=', type(_G.SetViewTargetToUniversalCamera))
  -- 3. 控制器与角色上的 Boom/相机属性
  local propNames = { 'CameraBoom', 'Boom', 'Arm', 'SpringArm', 'CameraComponent', 'FollowCamera', 'ArmsCamera', 'AimCamera', 'TPCamera', 'GunCamera' }
  for _, holder in ipairs(candidates) do
    if holder.obj then
      for _, name in ipairs(propNames) do
        local ok, v = pcall(function() return holder.obj[name] end)
        if ok and v and v ~= 0 and type(v) ~= 'number' and type(v) ~= 'boolean' and type(v) ~= 'string' then
          local okT, tal = pcall(function() return v.TargetArmLength end)
          local okF, fov = pcall(function() return v.FieldOfView end)
          if okT or okF then
            lp('HIT ' .. holder.tag .. '.' .. name, 'ArmLength=', tostring(tal), 'FOV=', tostring(fov))
          end
        end
      end
    end
  end
end

---视觉测试：pc:SetCameraFOV(45) 2 秒
local function fovVisualTest(pc)
  local okR, cur = pcall(function() return pc.GetCameraFOV and pc:GetCameraFOV() or -1 end)
  lp('GetCameraFOV probe', tostring(okR), tostring(cur))
  local ok = pcall(function() pc:SetCameraFOV(45) end)
  lp('SetCameraFOV(45) pcall', tostring(ok))
  if ok then
    lp('SETFOV VISUAL TEST: narrow view expected for 2s')
    UE4.Timer.Add(2, function()
      if Z.savedFov then
        pcall(function() pc:SetCameraFOV(Z.savedFov) end)
        lp('SetCameraFOV restored', Z.savedFov)
      else
        pcall(function() pc:SetCameraFOV(75) end)
        lp('SetCameraFOV restored 75')
      end
    end)
  end
end

function Z.Poll()
  local pc = getPC()
  if not pc then return end
  local okN, ctrlPath = pcall(UE4.UKismetSystemLibrary.GetPathName, pc)
  if not okN then return end

  local isCombat = string.find(ctrlPath or '', 'GameController', 1, true) ~= nil
    or string.find(ctrlPath or '', 'FightController', 1, true) ~= nil

  if isCombat and not Z.inCombat then
    Z.inCombat = true
    lp('ENTER_COMBAT')
    UE4.Timer.Add(2, function()
      runProbes(pc)
      -- 先读取当前 FOV 作为恢复基准
      local okG, cur = pcall(function() return pc:GetCameraFOV() end)
      if okG and cur and cur > 1 then Z.savedFov = cur end
      fovVisualTest(pc)
    end)
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
  end
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
    lp('prototype v13 online')
    Z.StartPolling()
  end)
end)

lp('v13 injected, waiting Logined')
