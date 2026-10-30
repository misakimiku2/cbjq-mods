
-- ========================================================
-- @File    : CamZoomMod.lua (diagnostics v6)
-- @Brief   : 战斗输入事件通道 + 相机解析修正（不动任何 ini）
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
  probeTried = 0,
  altProbed = 0,
}

---事件钩子：战斗中捕获所有可能的输入事件，找滚轮的通道
local function hookEventCap(eventName, maxLogs)
  local n = 0
  EventSystem.On(Event[eventName], function(...)
    n = n + 1
    if n > (maxLogs or 5) then return end
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

hookEventCap('OnKeyboardKeyPressed', 6)
hookEventCap('PCKeyboardEvent', 6)
hookEventCap('OnGamePadKeyPressed', 3)
hookEventCap('MouseButtonDown', 4)
hookEventCap('MouseButtonUp', 4)
hookEventCap('OnGamepadAnalogInput', 3)

---轴名探测：确定游戏视角轴的映射名，顺带探测滚轮别名
local axisCandidates = {
  'Mouse2D', 'MouseXY', 'MouseX', 'MouseY', 'MouseWheelAxis',
  'MouseScrollUp', 'MouseScrollDown', 'Turn', 'LookUp', 'LookUpRate', 'TurnRate',
}
local axisLogged = {}
local function probeAxes(pc)
  for _, name in ipairs(axisCandidates) do
    local ok, v = pcall(function() return pc:GetInputAxisValue(name) end)
    if ok and v and math.abs(v) > 0.001 then
      local key = name .. ':' .. string.format('%.2f', v)
      axisLogged[name] = (axisLogged[name] or 0) + 1
      if axisLogged[name] <= 3 then
        lp('AXIS_LIVE', name, string.format('%.3f', v))
      end
    elseif not ok and not axisLogged['err_' .. name] then
      axisLogged['err_' .. name] = true
      lp('AXIS_ERR', name, tostring(v))
    end
  end
end

---相机解析：无限重试 + GetAllActorsOfClass 备用路线
function Z.TryResolveCamera(ins)
  Z.probeTried = Z.probeTried + 1

  local okV, vt = pcall(function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    if pcm and pcm.ViewTarget and pcm.ViewTarget.Target then
      return pcm.ViewTarget.Target
    end
    return nil
  end)
  if okV and vt then
    local okN, vtPath = pcall(UE4.UKismetSystemLibrary.GetPathName, vt)
    if okN and vtPath and string.find(vtPath, 'Camera', 1, true) then
      local okR, comp = pcall(function() return vt:K2_GetRootComponent() end)
      if okR and comp then
        local okF, fov = pcall(function() return comp.FieldOfView end)
        if okF and fov and fov > 1 then
          Z.camComp = comp
          Z.camCompHow = 'K2_GetRootComponent'
          Z.fovBase = fov
          lp('CAM_RESOLVED', 'attempt', Z.probeTried, 'fovBase=', fov)
          return
        else
          lp('CAM root comp got but no FOV', tostring(okF), tostring(fov))
        end
      else
        lp('CAM K2_GetRootComponent fail', tostring(okR), tostring(comp))
      end
    end
  end

  -- 备用路线：全场景找 CineCameraActor（每 10 次主探测试一次）
  if Z.probeTried % 10 == 0 and Z.altProbed < 5 then
    Z.altProbed = Z.altProbed + 1
    local okA, arr = pcall(UE4.UGameplayStatics.GetAllActorsOfClass, ins, UE4.CineCameraActor)
    if okA and arr then
      local n = arr:Length()
      lp('ALT CineCameraActor search ->', n)
      if n > 0 then
        local a = arr:Get(1)
        lp('ALT cam path', UE4.UKismetSystemLibrary.GetPathName(a))
        local okR2, comp2 = pcall(function() return a:K2_GetRootComponent() end)
        if okR2 and comp2 then
          local okF2, fov2 = pcall(function() return comp2.FieldOfView end)
          lp('ALT comp fov read', tostring(okF2), tostring(fov2))
          if okF2 and fov2 and fov2 > 1 then
            Z.camComp = comp2
            Z.camCompHow = 'GetAllActorsOfClass'
            Z.fovBase = fov2
            lp('CAM_RESOLVED via ALT, fovBase=', fov2)
          end
        else
          lp('ALT K2_GetRootComponent fail', tostring(okR2))
        end
      end
    else
      lp('ALT GetAllActorsOfClass(CineCameraActor) fail', tostring(okA), tostring(arr))
    end
  end

  -- 重试进度（限频）
  if Z.probeTried == 20 or Z.probeTried == 60 or Z.probeTried == 150 then
    lp('CAM retrying, attempt', Z.probeTried)
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
    lp('LEAVE_COMBAT')
    Z.camComp = nil
    Z.fovBase = nil
    Z.probeTried = 0
    Z.altProbed = 0
  end

  if not Z.inCombat then return end

  probeAxes(pc)

  if not Z.camComp then
    Z.TryResolveCamera(ins)
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
    lp('diag v6 online')
    Z.StartPolling()
  end)
end)

lp('v6 injected, waiting Logined')
