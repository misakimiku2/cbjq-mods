
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v11)
-- @Brief   : LockedFOV/DefaultFOV 视觉测试 + PlayerInput 映射表导出
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = { inCombat = false, testsDone = false }

---测试 A：LockedFOV（修正 pcall 用法）
local function testLockedFOV()
  local okM, pcm = pcall(function()
    return UE4.UGameplayStatics.GetPlayerCameraManager(GetGameIns(), 0)
  end)
  if not okM or not pcm then
    lp('LOCKED no pcm', tostring(okM), tostring(pcm))
    return
  end
  local okR, cur = pcall(function() return pcm.LockedFOV end)
  lp('LOCKED read', tostring(okR), tostring(cur))
  if not okR then
    lp('LOCKED property not accessible')
    return
  end
  local okW = pcall(function() pcm.LockedFOV = 50 end)
  local okR2, now = pcall(function() return pcm.LockedFOV end)
  lp('LOCKED write', tostring(okW), 'readback', tostring(now))
  if okR2 and now == 50 then
    lp('LOCKED VISUAL TEST: view should be narrow for 2s')
    UE4.Timer.Add(2, function()
      pcall(function() pcm.LockedFOV = 0 end)
      lp('LOCKED restored')
    end)
  end
end

---测试 B：DefaultFOV 视觉测试
local function testDefaultFOV()
  local okM, pcm = pcall(function()
    return UE4.UGameplayStatics.GetPlayerCameraManager(GetGameIns(), 0)
  end)
  if not okM or not pcm then return end
  local okR, cur = pcall(function() return pcm.DefaultFOV end)
  lp('DFOV read', tostring(cur))
  local okW = pcall(function() pcm.DefaultFOV = 45 end)
  local okR2, now = pcall(function() return pcm.DefaultFOV end)
  lp('DFOV write', tostring(okW), 'readback', tostring(now))
  if okR2 and now == 45 then
    lp('DFOV VISUAL TEST: view should zoom for 2s')
    UE4.Timer.Add(2, function()
      pcall(function() pcm.DefaultFOV = 75 end)
      lp('DFOV restored 75')
    end)
  end
end

---导出 PlayerInput 的映射表
local function dumpInputMappings(pc)
  local okP, pi = pcall(function() return pc.PlayerInput end)
  if not okP or not pi then
    lp('PI no PlayerInput')
    return
  end
  -- AxisMappings
  local okA, ax = pcall(function() return pi.AxisMappings end)
  if okA and ax then
    local okL, n = pcall(function() return ax:Length() end)
    lp('AXIS_MAPS len', tostring(n))
    if okL and n and n > 0 and n < 60 then
      for i = 1, n do
        local okE, e = pcall(function() return ax:Get(i) end)
        if okE and e then
          local okN, name = pcall(function() return e.AxisName end)
          local okK, key = pcall(function() return e.AxisKey end)
          local okS, scale = pcall(function() return e.Scale end)
          lp('AXMAP', tostring(name), tostring(key), tostring(scale))
        end
      end
    end
  else
    lp('AXIS_MAPS unreadable', tostring(ax))
  end
  -- ActionMappings
  local okAc, am = pcall(function() return pi.ActionMappings end)
  if okAc and am then
    local okL2, n2 = pcall(function() return am:Length() end)
    lp('ACTION_MAPS len', tostring(n2))
    if okL2 and n2 and n2 > 0 and n2 < 400 then
      for i = 1, math.min(n2, 60) do
        local okE, e = pcall(function() return am:Get(i) end)
        if okE and e then
          local okN, name = pcall(function() return e.ActionName end)
          local okK, key = pcall(function() return e.Key end)
          lp('ACMAP', tostring(name), tostring(key))
        end
      end
    end
  else
    lp('ACTION_MAPS unreadable', tostring(am))
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

local function summarizeCodes()
  local parts = {}
  for k, v in pairs(codeCount) do
    parts[#parts + 1] = k .. 'x' .. v
    codeCount[k] = 0
  end
  table.sort(parts)
  lp('CODE_SUMMARY', table.concat(parts, ' '))
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
    dumpInputMappings(pc)
    UE4.Timer.Add(3, function()
      testLockedFOV()
      UE4.Timer.Add(3.5, testDefaultFOV)
    end)
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
  end
end

function Z.StartPolling()
  UE4.Timer.Add(0.03, function()
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
    lp('prototype v11 online')
    Z.StartPolling()
  end)
end)

lp('v11 injected, waiting Logined')
