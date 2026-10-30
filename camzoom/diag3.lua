
-- ========================================================
-- @File    : CamZoomMod.lua (injected diagnostics v3)
-- @Brief   : 模块差分 + 宿舍滚轮调用链 + 战斗相机探测
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local function snapshotModules()
  local set = {}
  if type(package) == 'table' and type(package.loaded) == 'table' then
    for k, v in pairs(package.loaded) do
      set[tostring(k)] = true
    end
  end
  return set
end

local bootSnapshot = nil
local diffLogCount = 0
local lastPawnPath = nil
local probeCount = 0

function CamZoomMod.DiffModules()
  if not bootSnapshot then return end
  local newNames = {}
  local cur = snapshotModules()
  for k in pairs(cur) do
    if not bootSnapshot[k] then newNames[#newNames + 1] = k end
  end
  if #newNames > 0 and diffLogCount < 10 then
    diffLogCount = diffLogCount + 1
    table.sort(newNames)
    lp('NEW_MODULES(' .. #newNames .. ')', table.concat(newNames, ','))
    -- 更新快照基线，避免重复报告
    for _, k in ipairs(newNames) do bootSnapshot[k] = true end
  end
end

---定时器：模块差分 + 相机状态变化探测
function CamZoomMod.StartPolling()
  UE4.Timer.Add(4, function()
    CamZoomMod.DiffModules()
    CamZoomMod.PollCameraState()
    CamZoomMod.StartPolling()
  end)
end

function CamZoomMod.PollCameraState()
  if probeCount > 40 then return end
  local okIns, ins = pcall(GetGameIns)
  if not okIns or not ins then return end
  local okP, pawn = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
  if not okP or not pawn then return end
  local okN, path = pcall(UE4.UKismetSystemLibrary.GetPathName, pawn)
  if not okN then return end
  if path ~= lastPawnPath then
    lastPawnPath = path
    probeCount = probeCount + 1
    lp('PAWN_CHANGED', path)
    -- 探测该状态下的相机要素
    local okV, vt = pcall(function()
      local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
      if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
        return UE4.UKismetSystemLibrary.GetPathName(pcm.ViewTarget.Target)
      end
      return 'nil'
    end)
    lp('  ViewTarget', tostring(vt))
    local okC, ctrl = pcall(function()
      local pc = UE4.UGameplayStatics.GetPlayerController(ins, 0)
      return UE4.UKismetSystemLibrary.GetPathName(pc)
    end)
    lp('  PlayerController', tostring(ctrl))
    local okA, actors = pcall(UE4.UGameplayStatics.GetAllActorsOfClass, ins, UE4.CameraActor)
    if okA and actors then
      local n = actors:Length()
      lp('  CameraActors=' .. tostring(n))
    end
    local okR, rot = pcall(function()
      local pc = UE4.UGameplayStatics.GetPlayerController(ins, 0)
      return pc:GetControlRotation()
    end)
    if okR then lp('  GetControlRotation OK', rot.Pitch, rot.Yaw, rot.Roll) end
  end
end

---宿舍滚轮事件：带调用栈回溯，定位触发源头
local houseWheelCount = 0
EventSystem.On(Event.OnHousePlayerScrollWheel, function(...)
  houseWheelCount = houseWheelCount + 1
  if houseWheelCount > 6 then return end
  local cnt = select('#', ...)
  local args = {}
  for i = 1, cnt do
    local v = select(i, ...)
    if type(v) == 'table' then
      args[i] = 'table{' .. tostring(v.n or v.Id or '') .. '}'
    else
      args[i] = tostring(v)
    end
  end
  lp('HOUSE_WHEEL(' .. cnt .. ')', table.concat(args, ' | '))
  lp('HOUSE_WHEEL_TRACE', debug.traceback('house wheel', 2))
end)

---鼠标事件保持少量钩子确认战斗中是否继续分发
local combatMouseCount = 0
EventSystem.On(Event.MouseMove, function(...)
  combatMouseCount = combatMouseCount + 1
  if combatMouseCount > 60 then
    if combatMouseCount == 61 then lp('MouseMove still flowing (capped)') end
    return
  end
  local cnt = select('#', ...)
  if cnt >= 4 then
    local x, y, dx, dy = select(1, ...)
    -- 只记录 y 方向变化明显的，模拟滚轮线索参考
    if combatMouseCount % 20 == 0 then
      lp('MouseMove sample', x, y, dx, dy)
    end
  end
end)

EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(12, function()
    bootSnapshot = snapshotModules()
    lp('boot snapshot taken, modules=', (function()
      local n = 0
      for _ in pairs(bootSnapshot) do n = n + 1 end
      return n
    end)())
    CamZoomMod.StartPolling()
  end)
end)

lp('v3 injected, waiting Logined')
