
-- ========================================================
-- @File    : CamZoomMod.lua (prototype v19)
-- @Brief   : 轴值监控(LookUp+Wheel) + NextFrame FOV 竞速 + 开镜事件探测
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local Z = { inCombat = false }

---轴值监控
local axisLogged = {}
local function monitorAxes(pc)
  for _, name in ipairs({ 'MouseWheelAxis', 'LookUp' }) do
    local ok, v = pcall(function() return pc:GetInputAxisValue(name) end)
    if ok and v and math.abs(v) > 0.0001 then
      axisLogged[name] = (axisLogged[name] or 0) + 1
      if axisLogged[name] <= 4 then
        lp('AXIS_LIVE', name, string.format('%.3f', v))
      end
    end
  end
end

---开镜事件探测（找 AimComponent）
EventSystem.On(Event.PlayerStartAim, function(...)
  local n = select('#', ...)
  if (Z.aimLog or 0) < 3 then
    Z.aimLog = (Z.aimLog or 0) + 1
    local args = {}
    for i = 1, n do
      local v = select(i, ...)
      args[i] = type(v) == 'table' and 'table' or tostring(v)
    end
    lp('EV PlayerStartAim(' .. n .. ')', table.concat(args, ' | '))
  end
end)

---NextFrame FOV 竞速测试：写入 50 并立即回读，持续 3 秒
local function nextFrameRace()
  local okP, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, GetGameIns(), 0)
  if not okP or not pawn then
    lp('RACE2 no pawn')
    return
  end
  local okC, cam = pcall(function() return pawn.Camera end)
  if not okC or not cam then
    lp('RACE2 no cam')
    return
  end
  lp('RACE2 begin: NextFrame writes FOV=50 for 3s')
  local count = { n = 0 }
  local minSeen = { v = 999 }
  local function tick()
    count.n = count.n + 1
    pcall(function() cam.FieldOfView = 50 end)
    local okR, v = pcall(function() return cam.FieldOfView end)
    if okR and v and v < minSeen.v then minSeen.v = v end
    if count.n >= 180 then
      pcall(function() cam.FieldOfView = 75 end)
      lp('RACE2 end writes=', count.n, 'minReadback=', string.format('%.1f', minSeen.v))
    else
      UE4.Timer.NextFrame(tick)
    end
  end
  UE4.Timer.NextFrame(tick)
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
    monitorAxes(pc)
    Z.raceDone = false
  elseif not isCombat and Z.inCombat then
    Z.inCombat = false
    lp('LEAVE_COMBAT')
  end

  if not Z.inCombat then return end

  monitorAxes(pc)

  -- 进战斗 4 秒后跑 NextFrame 竞速
  if not Z.raceDone then
    Z.raceDone = true
    UE4.Timer.Add(4, nextFrameRace)
  end
end

function Z.StartPolling()
  UE4.Timer.Add(0.03, function()
    local ok, err = pcall(Z.Poll)
    if not ok then
      pollErrCount = (pollErrCount or 0) + 1
      if pollErrCount <= 8 then lp('Poll ERR', tostring(err)) end
    end
    Z.tick = (Z.tick or 0) + 1
    Z.StartPolling()
  end)
end

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(10, function()
    lp('prototype v19 online')
    Z.StartPolling()
  end)
end)

lp('v19 injected, waiting Logined')
