
-- ========================================================
-- @File    : CamZoomMod.lua (injected diagnostics v2)
-- @Brief   : 输入系统与宿舍滚轮缩放机制探查
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local function safeCall(name, fn)
  local ok, a, b, c = pcall(fn)
  if ok then
    lp(name, 'OK', a, b, c)
  else
    lp(name, 'ERR', a)
  end
  return ok, a
end

---浅层 dump 一张表：键名 + 值类型；table 值再展开一层键名列表
local function dumpTable(name, t)
  if type(t) ~= 'table' then
    lp('DUMP ' .. name .. ' -> ' .. type(t))
    return
  end
  local keys = {}
  for k, v in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  lp('DUMP ' .. name .. ' (' .. #keys .. ')')
  for _, k in ipairs(keys) do
    local v = t[k]
    local tv = type(v)
    local desc
    if tv == 'function' then
      desc = 'func'
    elseif tv == 'table' then
      desc = 'table'
    else
      desc = tostring(v)
    end
    lp('  .' .. tostring(k) .. ' = ' .. desc)
  end
  -- 嵌套一层
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == 'table' and v ~= _G then
      local nk = {}
      for k2, v2 in pairs(v) do
        nk[#nk + 1] = tostring(k2) .. ':' .. type(v2)
      end
      table.sort(nk)
      if #nk > 0 and #nk <= 200 then
        lp('  [' .. tostring(k) .. '] (' .. #nk .. ') ' .. table.concat(nk, ','))
      elseif #nk > 200 then
        lp('  [' .. tostring(k) .. '] (' .. #nk .. ') [too many, skipped]')
      end
    end
  end
end

function CamZoomMod.RunAllV2()
  lp('===== RunAllV2 begin =====')
  safeCall('dump GameInputModel', function()
    dumpTable('GameInputModel', GameInputModel)
    return ''
  end)
  safeCall('dump HouseCameraManager', function()
    dumpTable('HouseCameraManager', HouseCameraManager)
    return ''
  end)
  safeCall('dump HouseCameraConfig', function()
    dumpTable('HouseCameraConfig', HouseCameraConfig)
    return ''
  end)
  safeCall('dump FightLevel', function()
    dumpTable('FightLevel', FightLevel)
    return ''
  end)
  lp('===== RunAllV2 end =====')
end

---事件钩子：带计数上限，避免刷屏
local function hookEventWithCap(eventName, maxLogs)
  local n = 0
  EventSystem.On(Event[eventName], function(...)
    n = n + 1
    if n > (maxLogs or 3) then return end
    local cnt = select('#', ...)
    local args = {}
    for i = 1, cnt do
      local v = select(i, ...)
      args[i] = type(v) == 'table' and 'table' or tostring(v)
    end
    lp('EV ' .. eventName .. '(' .. cnt .. ')', table.concat(args, ' | '))
  end)
  lp('hooked', eventName)
end

if Event and Event.OnHousePlayerScrollWheel then hookEventWithCap('OnHousePlayerScrollWheel', 8) end
if Event and Event.MouseButtonDown then hookEventWithCap('MouseButtonDown', 5) end
if Event and Event.MouseMove then hookEventWithCap('MouseMove', 3) end
if Event and Event.OnGameInputModeChange then hookEventWithCap('OnGameInputModeChange', 5) end
if Event and Event.OnInputTypeChange then hookEventWithCap('OnInputTypeChange', 5) end
if Event and Event.OnGamepadAnalogInput then hookEventWithCap('OnGamepadAnalogInput', 3) end

---引擎类与能力探测
function CamZoomMod.ProbeEngine()
  lp('probe UUniversalCameraComponent raw ->', tostring(UE4.UUniversalCameraComponent))
  lp('probe UUniversalCameraActor raw ->', tostring(UE4.UUniversalCameraActor))
  safeCall('GetAllActorsOfClass-SpringArm', function()
    local ins = GetGameIns()
    local arr = UE4.UGameplayStatics.GetAllActorsOfClass(ins, UE4.USpringArmComponent)
    local n = arr and arr:Length() or -1
    local s = 'springArms=' .. tostring(n)
    for i = 1, math.min(n or 0, 8) do
      local a = arr:Get(i)
      s = s .. ' |' .. UE4.UKismetSystemLibrary.GetPathName(a)
      ok2, len = pcall(function() return a.TargetArmLength end)
      s = s .. ' len=' .. tostring(len)
    end
    return s
  end)
  safeCall('ViewTarget-in-lobby', function()
    local ins = GetGameIns()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget then
      local vt = pcm.ViewTarget.Target
      if vt then
        return 'VT=' .. UE4.UKismetSystemLibrary.GetPathName(vt)
      end
    end
    return 'VT=nil'
  end)
  safeCall('pawn-common-methods', function()
    local ins = GetGameIns()
    local pawn = UE4.UGameplayStatics.GetPlayerPawn(ins, 0)
    if not pawn then return 'no pawn' end
    local s = ''
    local ok1, loc = pcall(function() return pawn:K2_GetActorLocation() end)
    s = s .. ' K2_GetActorLocation=' .. tostring(ok1) .. (ok1 and (' ' .. tostring(loc.X)) or '')
    local ok2, comps = pcall(function() return pawn:GetComponentsByClass(UE4.UActorComponent) end)
    s = s .. ' GetComponentsByClass=' .. tostring(ok2)
    return s
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(8, function()
    CamZoomMod.RunAllV2()
    CamZoomMod.ProbeEngine()
  end)
end)

lp('v2 injected, waiting Logined')
