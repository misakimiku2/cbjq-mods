-- ========================================================
-- @File    : CamZoomMod.lua (v26)
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）
--
-- 历史结论汇总（避免重复踩坑）：
--   ✗ pawn.Camera.FieldOfView 直写        —— 每帧被游戏回写
--   ✗ PlayerCameraManager.CameraCache.POV —— 恒为默认值，渲染不走它
--   ✗ CameraArmLength/CameraFOV 等属性     —— UnLua 读不到（非 BlueprintVisible）
--   ✗ AddCameraDataOffset(FVector)        —— 实测空操作，相机坐标纹丝不动
--   ✗ 空参数调 SetSocketCameraInfo/SetFollowCamera/SetTempCameraInfo
--                                          —— 会把相机扔到世界原点（上次"飞出地图"的元凶）
--
-- v26 只做两件「可秒还原」的事，都在用户第一次滚轮时触发：
--   P1 相机组件相对位置：写 (base + 偏移) → 立刻读 → 0.25s/0.5s 再读 → 还原
--      → 判断「经理是否每帧覆写组件变换」以及「相对位移能否驱动相机」
--   P2 相机 FOV：写 45 → 立刻读 → 0.25s/0.5s 再读 → 还原 75
--      → 判断 FOV 到底是不是每帧回写
-- 两个测试都只改一个可还原的标量/向量，且都带超时自动还原。
-- ========================================================

CamZoomMod = CamZoomMod or {}
if not CamZoomMod._ready then

local LOG = '[CamZoom] '
local function lp(...) print(LOG, ...) end

local function fmt(v, nd)
  if v == nil then return 'nil' end
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%.' .. (nd or 1) .. 'f', v)
end

local CFG = {
  zMin = 0.62,
  zMax = 2.40,
  notchStep = 0.09,
  smooth = 9.0,
  pollInterval = 0.02,
  ipcPath = 'D:\\test\\cbjq-re\\runtime\\wheel.txt',
  wheelAxisName = 'MouseScrollWheel',
}

local Z = {
  z = 1.0, zTarget = 1.0,
  frame = 0, errCount = 0, dead = false,
  wheelSrc = 'none', hasDirection = false,
  notch = 0, notchTotal = 0,
  ioChecked = false, hasIO = false, ipcSeq = -1,
  axisSamples = 0,
  mech = nil,
}

-- ============================================================
-- 取对象
-- ============================================================
local function getIns()
  local fn = GetGameIns
  if type(fn) ~= 'function' then return nil end
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

local function getPC()
  local ins = getIns()
  if not ins then return nil end
  local ok, v = pcall(UE4.UGameplayStatics.GetPlayerController, ins, 0)
  if ok then return v end
  return nil
end

local function getPawn()
  local ins = getIns()
  if not ins then return nil end
  local ok, v = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
  if ok then return v end
  return nil
end

local function getPCM()
  local ins = getIns()
  if not ins then return nil end
  local ok, v = pcall(UE4.UGameplayStatics.GetPlayerCameraManager, ins, 0)
  if ok then return v end
  return nil
end

local function pathOf(obj)
  if obj == nil then return 'nil' end
  local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, obj)
  if ok and p then return tostring(p) end
  return ''
end

local function isGameplay(pc)
  local s = pathOf(pc)
  return (s:find('GameController', 1, true) ~= nil)
    or (s:find('FightController', 1, true) ~= nil)
end

local function getCam(pawn)
  local ok, c = pcall(function() return pawn.Camera end)
  if ok and c then return c end
  return nil
end

-- ============================================================
-- 读数
-- ============================================================
local function locStr(v)
  if not v then return 'nil' end
  return string.format('(%.1f,%.1f,%.1f)', v.X, v.Y, v.Z)
end

local function compLoc(cam)
  local ok, l = pcall(function() return cam:K2_GetComponentLocation() end)
  if ok and l then return { X = l.X, Y = l.Y, Z = l.Z } end
  return nil
end

local function pcmLoc(pcm)
  local ok, t = pcall(function() return pcm:GetPlayerCameraComponentTrans() end)
  if not ok or t == nil then return nil end
  local l = nil
  pcall(function() l = t.Translation end)
  if l == nil then pcall(function() l = t.Location end) end
  if l == nil then return nil end
  return { X = l.X, Y = l.Y, Z = l.Z }
end

local function fovOf(cam)
  local ok, v = pcall(function() return cam.FieldOfView end)
  if ok and type(v) == 'number' then return v end
  return nil
end

local function relLoc(cam)
  local ok, l = pcall(function() return cam:K2_GetRelativeLocation() end)
  if ok and l then return { X = l.X, Y = l.Y, Z = l.Z } end
  local ok2, l2 = pcall(function() return cam.RelativeLocation end)
  if ok2 and l2 then return { X = l2.X, Y = l2.Y, Z = l2.Z } end
  return nil
end

-- 写组件相对位置，多种签名依次尝试
local function setRelLoc(cam, v)
  local a = pcall(function()
    cam:K2_SetRelativeLocation(UE4.FVector(v.X, v.Y, v.Z), false, nil, false)
  end)
  if a then return 'K2_SetRelativeLocation' end
  local b = pcall(function()
    cam:SetRelativeLocation(UE4.FVector(v.X, v.Y, v.Z), false, nil, false)
  end)
  if b then return 'SetRelativeLocation' end
  local c = pcall(function()
    cam.RelativeLocation = UE4.FVector(v.X, v.Y, v.Z)
  end)
  if c then return 'RelativeLocation=' end
  return nil
end

-- 一次完整读数，方便前后对比
local function snap(cam, pcm)
  local s = {}
  s.comp = compLoc(cam)
  s.pcm = pcmLoc(pcm)
  s.fov = fovOf(cam)
  return s
end

local function snapStr(s)
  return 'comp=' .. locStr(s.comp) .. ' pcm=' .. locStr(s.pcm) .. ' fov=' .. fmt(s.fov, 1)
end

-- ============================================================
-- 工具
-- ============================================================
local function schedule(fn, sec)
  pcall(function() UE4.Timer.Add(sec or 0.01, fn) end)
end

local function hud(text, dur)
  lp('HUD', text)
  pcall(function()
    UE4.UKismetSystemLibrary.PrintString(getIns() or nil, text, true, false,
      UE4.FLinearColor(0.35, 0.95, 1.0, 1.0), dur or 2.5)
  end)
end

-- ============================================================
-- 滚轮输入
-- ============================================================
local function pollWheelAxis(pc)
  local ok, v = pcall(function() return pc:GetInputAxisValue(CFG.wheelAxisName) end)
  if ok and type(v) == 'number' then
    if math.abs(v) > 0.01 and Z.axisSamples < 10 then
      Z.axisSamples = Z.axisSamples + 1
      lp('WHEELAXIS', CFG.wheelAxisName, fmt(v, 3))
    end
    if math.abs(v) > 0.05 then return v end
  end
  return 0
end

local function pollIPC()
  if not Z.ioChecked then
    Z.ioChecked = true
    Z.hasIO = (type(io) == 'table' and type(io.open) == 'function')
    lp('IPC io available=', tostring(Z.hasIO))
    if not Z.hasIO then return 0 end
  end
  if not Z.hasIO then return 0 end

  local ok, f = pcall(io.open, CFG.ipcPath, 'r')
  if not ok or not f then return 0 end
  local content = nil
  pcall(function() content = f:read('a') end)
  pcall(function() f:close() end)
  if not content or content == '' then return 0 end

  local seqs, dirs = content:match('(%d+)%s+(-?%d+)')
  if not seqs then return 0 end
  local seq, dir = tonumber(seqs), tonumber(dirs)
  if not seq or not dir then return 0 end
  if Z.ipcSeq < 0 then Z.ipcSeq = seq; return 0 end
  if seq == Z.ipcSeq then return 0 end
  local steps = seq - Z.ipcSeq
  Z.ipcSeq = seq
  if steps < 1 or steps > 20 then steps = 1 end
  if dir == 0 then return 0 end
  Z.hasDirection = true
  Z.wheelSrc = 'ipc'
  return dir * steps
end

local function onKeyboardLikeEvent(...)
  local num = tonumber(select(1, ...))
  if num == nil then return end
  Z.notchTotal = Z.notchTotal + 1
  if num == 13 then Z.notch = (Z.notch or 0) + 1 end
end

-- ============================================================
-- 探测（首次滚轮触发，全部可秒还原）
-- ============================================================
local probe = { started = false, done = false }
local baseRel = nil

local function p1_relLoc(cam, pcm)
  baseRel = relLoc(cam)
  lp('P1 relLoc base=', locStr(baseRel))
  if not baseRel then return false end

  local before = snap(cam, pcm)
  lp('P1 before', snapStr(before))

  local how = setRelLoc(cam, { X = baseRel.X, Y = baseRel.Y, Z = baseRel.Z + 120 })
  lp('P1 set +120Z via=', tostring(how))
  if not how then return false end

  -- 同一帧立刻读一次（判断是否"写了就生效"）
  local now = snap(cam, pcm)
  lp('P1 immediate', snapStr(now))

  schedule(function()
    local s1 = snap(cam, pcm)
    lp('P1 t+0.25', snapStr(s1))
    schedule(function()
      local s2 = snap(cam, pcm)
      lp('P1 t+0.5', snapStr(s2))
      setRelLoc(cam, { X = baseRel.X, Y = baseRel.Y, Z = baseRel.Z })
      lp('P1 restored relLoc')
      schedule(function()
        lp('P1 after-restore', snapStr(snap(cam, pcm)))
      end, 0.2)
    end, 0.25)
  end, 0.25)
  return true
end

local function p2_fov(cam, pcm)
  local base = fovOf(cam)
  lp('P2 fov base=', fmt(base, 1))
  if not base then return false end

  local ok = pcall(function() cam.FieldOfView = 45.0 end)
  lp('P2 write 45 ok=', tostring(ok))
  if not ok then return false end

  lp('P2 immediate fov=', fmt(fovOf(cam), 1))
  schedule(function()
    lp('P2 t+0.25 fov=', fmt(fovOf(cam), 1))
    schedule(function()
      lp('P2 t+0.5 fov=', fmt(fovOf(cam), 1))
      pcall(function() cam.FieldOfView = base end)
      lp('P2 restored fov')
      schedule(function()
        lp('P2 after-restore fov=', fmt(fovOf(cam), 1))
        probe.done = true
        lp('PROBE v26 done')
        hud('CamZoom: 探测完成，见日志', 4.0)
      end, 0.2)
    end, 0.25)
  end, 0.25)
  return true
end

local function startProbe(pawn, cam, pcm)
  if probe.started or probe.done then return end
  probe.started = true
  lp('PROBE v26 begin')
  pcall(function() p1_relLoc(cam, pcm) end)
  schedule(function()
    pcall(function() p2_fov(cam, pcm) end)
  end, 1.2)
end

-- ============================================================
-- 主循环
-- ============================================================
local function step()
  if Z.dead then return end

  local okAll, err = pcall(function()
    Z.frame = Z.frame + 1

    local pc = getPC()
    if not pc then return end
    local pawn = getPawn()
    if not pawn then return end
    local cam = getCam(pawn)
    if not cam then return end
    if not isGameplay(pc) then return end

    local pcm = getPCM()

    local delta = 0
    local ipc = pollIPC()
    if ipc ~= 0 then delta = ipc end
    if delta == 0 then
      local av = pollWheelAxis(pc)
      if av ~= 0 and Z.axisArmed ~= false then
        Z.axisArmed = false
        delta = (av > 0) and 1 or -1
        Z.hasDirection = true
        if Z.wheelSrc ~= 'ipc' then Z.wheelSrc = 'axis' end
      elseif av == 0 then
        Z.axisArmed = true
      end
    end
    if delta == 0 and (Z.notch or 0) > 0 and not Z.hasDirection then
      delta = Z.notch
      Z.notch = 0
      Z.wheelSrc = 'notch'
    end
    if (Z.notch or 0) > 0 and Z.hasDirection then Z.notch = 0 end

    if delta ~= 0 and not probe.done and not probe.started then
      startProbe(pawn, cam, pcm)
    end
  end)

  if not okAll then
    Z.errCount = Z.errCount + 1
    if Z.errCount <= 8 then lp('STEP ERR', tostring(err)) end
    if Z.errCount > 80 then
      Z.dead = true
      lp('too many errors, disabled')
    end
  end
end

local _loopStarted = false
local _subCount = 0

local function loop()
  step()
  pcall(function() UE4.Timer.Add(CFG.pollInterval, loop) end)
end

function CamZoomMod.Start()
  if _loopStarted then return end
  local ok = pcall(function() UE4.Timer.Add(0.5, loop) end)
  if ok then
    _loopStarted = true
    lp('v26 online')
  end
end

if pcall(function() CamZoomMod.Start() end) then _subCount = _subCount + 1 end

if pcall(function()
  EventSystem.On(Event.Logined, function()
    schedule(CamZoomMod.Start, 2.0)
  end)
end) then _subCount = _subCount + 1 end

if pcall(function()
  EventSystem.On(Event.PCKeyboardEvent, function(...)
    if not _loopStarted then pcall(function() CamZoomMod.Start() end) end
    pcall(onKeyboardLikeEvent, ...)
  end)
end) then _subCount = _subCount + 1 end

if _loopStarted or _subCount > 0 then
  CamZoomMod._ready = true
  lp('v26 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v26 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard
