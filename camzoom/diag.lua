
-- ========================================================
-- @File    : CamZoomMod.lua (injected diagnostics)
-- @Brief   : 战斗滚轮缩放镜头 - 诊断阶段
-- ========================================================

CamZoomMod = CamZoomMod or {}
local LOG = '[CamZoomMod] '

local function lp(...)
  print(LOG, ...)
end

local function safeCall(name, fn)
  local ok, a, b = pcall(fn)
  if ok then
    lp(name, 'OK', a, b)
  else
    lp(name, 'ERR', a)
  end
  return ok, a, b
end

function CamZoomMod.SurveyGlobals()
  local names = {}
  for k, v in pairs(_G) do
    if type(k) == 'string' and type(v) == 'table' then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  lp('GLOBAL_TABLES(' .. #names .. ')', table.concat(names, ','))
end

function CamZoomMod.SurveyEvent()
  local names = {}
  if type(Event) == 'table' then
    for k, v in pairs(Event) do
      names[#names + 1] = tostring(k) .. '=' .. tostring(v)
    end
    table.sort(names)
  end
  lp('EVENT_KEYS(' .. #names .. ')', table.concat(names, ','))
end

function CamZoomMod.SurveyLoaded()
  local names = {}
  if type(package) == 'table' and type(package.loaded) == 'table' then
    for k, v in pairs(package.loaded) do
      names[#names + 1] = tostring(k)
    end
    table.sort(names)
  end
  lp('LOADED_MODULES(' .. #names .. ')', table.concat(names, ','))
end

function CamZoomMod.SurveyCamera()
  local ins = GetGameIns and GetGameIns() or nil
  lp('GameIns', ins)
  if not ins then return end
  safeCall('PlayerController', function()
    local pc = UE4.UGameplayStatics.GetPlayerController(ins, 0)
    return pc and UE4.UKismetSystemLibrary.GetPathName(pc) or 'nil'
  end)
  safeCall('PlayerPawn', function()
    local pawn = UE4.UGameplayStatics.GetPlayerPawn(ins, 0)
    if not pawn then return 'nil' end
    local s = UE4.UKismetSystemLibrary.GetPathName(pawn)
    local comps = pawn:GetComponentsByClass(UE4.USpringArmComponent)
    local n = comps and comps:Length() or 0
    s = s .. ' springArms=' .. tostring(n)
    for i = 1, n do
      local arm = comps:Get(i)
      s = s .. ' |' .. UE4.UKismetSystemLibrary.GetPathName(arm) .. ' len=' .. tostring(arm.TargetArmLength)
    end
    local cams = pawn:GetComponentsByClass(UE4.UCameraComponent)
    local cn = cams and cams:Length() or 0
    s = s .. ' cameras=' .. tostring(cn)
    for i = 1, cn do
      s = s .. ' |' .. UE4.UKismetSystemLibrary.GetPathName(cams:Get(i))
    end
    return s
  end)
  safeCall('CameraManager', function()
    local pcm = UE4.UGameplayStatics.GetPlayerCameraManager(ins, 0)
    return pcm and UE4.UKismetSystemLibrary.GetPathName(pcm) or 'nil'
  end)
end

function CamZoomMod.SurveyEngineClasses()
  safeCall('UniversalCamera', function()
    return UE4.UKismetSystemLibrary.GetClassDisplayName(UE4.UUniversalCameraComponent)
  end)
  safeCall('EnhancedInput', function()
    return UE4.UKismetSystemLibrary.GetClassDisplayName(UE4.UEnhancedInputComponent)
  end)
  safeCall('PlayerInput', function()
    local ins = GetGameIns()
    local pc = UE4.UGameplayStatics.GetPlayerController(ins, 0)
    if pc and pc.PlayerInput then
      return 'PlayerInput OK ' .. UE4.UKismetSystemLibrary.GetPathName(pc.PlayerInput)
    end
    return 'PlayerInput nil'
  end)
end

function CamZoomMod.RunAll()
  lp('===== RunAll begin =====')
  CamZoomMod.SurveyGlobals()
  CamZoomMod.SurveyEvent()
  CamZoomMod.SurveyLoaded()
  CamZoomMod.SurveyCamera()
  CamZoomMod.SurveyEngineClasses()
  lp('===== RunAll end =====')
end

---登录后延时执行诊断（进主界面后 8 秒）
EventSystem.On(Event.Logined, function()
  UE4.Timer.Add(8, function()
    CamZoomMod.RunAll()
  end)
end)

lp('injected, waiting Logined')
