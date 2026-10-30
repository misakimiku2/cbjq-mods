-- ========================================================
-- @File    : CamZoomMod.lua (v21)
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）
--
-- v20 实测日志结论（2026-10-28 13:13）：
--   · 12 个属性候选（CameraArmLength/CameraFOV/...）全部读不到 → 不是可读 UPROPERTY
--   · 5 个方法候选（SetCameraFOV/SetFOVOverride/...）全部 not callable
--   · 唯一真正动到相机的是 pcm:AddCameraDataOffset(FVector)
--     日志：test=-220Z → dDist=6.6%（给的是"往下 2.2 米"，被地面挡住）
--   · 游戏确有滚轮轴：AxisName = "MouseScrollWheel"（Key = Mouse Wheel Axis）
--
-- v21 因此改为：用 AddCameraDataOffset 沿视线方向做位移（真·推拉镜头），
--   判据 = 相机位移向量与视线前向的夹角余弦（能区分"后拉"与"横移/下沉"）。
-- ========================================================

CamZoomMod = CamZoomMod or {}
if not CamZoomMod._ready then

local LOG = '[CamZoom] '
local function lp(...)
  print(LOG, ...)
end

local function fmt(v, nd)
  if v == nil then return 'nil' end
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%.' .. (nd or 1) .. 'f', v)
end

local CFG = {
  zMin = 0.45,
  zMax = 2.60,
  notchStep = 0.09,
  smooth = 9.0,
  pollInterval = 0.02,
  calMag = 200.0,
  calDwell = 0.5,
  baseDist = 300.0,
  invertWheel = false,
  ipcPath = 'D:\\test\\cbjq-re\\runtime\\wheel.txt',
  hudDuration = 2.5,
  wheelAxisName = 'MouseScrollWheel',
}

local Z = {
  z = 1.0,
  zTarget = 1.0,
  mech = nil,
  calibrated = false,
  calibrating = false,
  errCount = 0,
  wheelSrc = 'none',
  hasDirection = false,
  sniffUntil = 0,
  notch = 0,
  notchTotal = 0,
  frame = 0,
  dead = false,
  ioChecked = false,
  hasIO = false,
  ipcSeq = -1,
  applied = nil,
  axisSamples = 0,
}

-- ============================================================
-- 取对象
-- ============================================================
local function getIns()
  local fn = GetGameIns
  if type(fn) ~= 'function' then return nil end
  local ok, ins = pcall(fn)
  if ok then return ins end
  return nil
end

local function getPC()
  local ins = getIns()
  if not ins then return nil end
  local ok, pc = pcall(UE4.UGameplayStatics.GetPlayerController, ins, 0)
  if ok then return pc end
  return nil
end

local function getPawn()
  local ins = getIns()
  if not ins then return nil end
  local ok, p = pcall(UE4.UGameplayStatics.GetPlayerPawn, ins, 0)
  if ok then return p end
  return nil
end

local function getPCM()
  local ins = getIns()
  if not ins then return nil end
  local ok, pcm = pcall(UE4.UGameplayStatics.GetPlayerCameraManager, ins, 0)
  if ok then return pcm end
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
-- 向量与测量
-- ============================================================
local function vecLen(v)
  if not v then return nil end
  return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
end

local function vecSub(a, b)
  return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }
end

local function vecDot(a, b)
  return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

local function camLoc(cam)
  local ok, l = pcall(function() return cam:K2_GetComponentLocation() end)
  if ok and l then return { X = l.X, Y = l.Y, Z = l.Z } end
  return nil
end

local function camFwd(cam)
  local okR, r = pcall(function() return cam:K2_GetComponentRotation() end)
  if not okR or not r then return nil end
  local okF, f = pcall(function() return UE4.UKismetMathLibrary.GetForwardVector(r) end)
  if okF and f then return { X = f.X, Y = f.Y, Z = f.Z } end
  return nil
end

local function distToPawn(pawn, loc)
  if not loc then return nil end
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okP or not pl then return nil end
  local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function measure(pawn, cam)
  local m = {}
  if not cam then return m end
  local okF, f = pcall(function() return cam.FieldOfView end)
  if okF and type(f) == 'number' then m.fov = f end
  m.loc = camLoc(cam)
  m.fwd = camFwd(cam)
  m.dist = distToPawn(pawn, m.loc)
  return m
end

-- ============================================================
-- 位移偏移（唯一真正生效的镜头接口）
-- ============================================================
local function tryClearOffset(pcm)
  pcall(function() pcm:ClearCameraDataOffset() end)
end

local function tryAddOffset(pcm, v)
  return pcall(function() pcm:AddCameraDataOffset(v) end)
end

local VARIANTS = {
  { name = 'world+',  space = 'world', sign = 1 },
  { name = 'world-',  space = 'world', sign = -1 },
  { name = 'localX+', space = 'local', sign = 1, axis = 'X' },
  { name = 'localX-', space = 'local', sign = -1, axis = 'X' },
  { name = 'localZ+', space = 'local', sign = 1, axis = 'Z' },
  { name = 'localZ-', space = 'local', sign = -1, axis = 'Z' },
}

local function variantVector(v, cam, mag)
  local s = (v.sign or 1) * mag
  if v.space == 'world' then
    local f = cam and camFwd(cam)
    if not f then return nil end
    return UE4.FVector(f.X * s, f.Y * s, f.Z * s)
  end
  if v.axis == 'Z' then return UE4.FVector(0, 0, s) end
  return UE4.FVector(s, 0, 0)
end

local function outwardVector(mech, cam, mag)
  if mech.space == 'world' then
    local f = cam and camFwd(cam)
    if not f then return nil end
    local s = mag * mech.sign
    return UE4.FVector(f.X * s, f.Y * s, f.Z * s)
  end
  local s = mag * mech.sign
  if mech.axis == 'Z' then return UE4.FVector(0, 0, s) end
  return UE4.FVector(s, 0, 0)
end

-- ============================================================
-- HUD
-- ============================================================
local function hud(text, dur)
  lp('HUD', text)   -- 同时写日志：万一屏幕文字不显示，日志里也能看到想提示什么
  pcall(function()
    UE4.UKismetSystemLibrary.PrintString(getIns() or nil, text, true, false,
      UE4.FLinearColor(0.35, 0.95, 1.0, 1.0), dur or CFG.hudDuration)
  end)
end

local function hudState()
  if Z.dead then
    hud('CamZoom: 已停用', 3.0)
    return
  end
  if not Z.mech then
    hud('CamZoom | 未找到可用镜头接口 | 滚轮:' .. Z.wheelSrc, 4.5)
    return
  end
  hud(string.format('CamZoom  x%.2f   %s   滚轮:%s', Z.z, Z.mech.name, Z.wheelSrc), 2.2)
end

-- ============================================================
-- 应用缩放
-- ============================================================
local function applyZoom(pawn, cam, pcm)
  local m = Z.mech
  if not m or not pcm or not cam then return end

  local z = Z.z

  if math.abs(z - 1.0) < 0.004 then
    if Z.applied ~= nil then
      tryClearOffset(pcm)
      Z.applied = nil
      lp('APPLY released to game')
    end
    return
  end

  local mag = (z - 1.0) * CFG.baseDist
  local vec = outwardVector(m, cam, mag)
  if not vec then return end

  tryClearOffset(pcm)
  local ok = tryAddOffset(pcm, vec)
  if not ok then
    Z.errCount = Z.errCount + 1
    if Z.errCount >= 8 then
      lp('APPLY failed, disable mech')
      Z.mech = nil
    end
    return
  end
  Z.applied = z
end

-- ============================================================
-- 滚轮输入
-- ============================================================
local function pollWheelAxis(pc)
  local ok, v = pcall(function() return pc:GetInputAxisValue(CFG.wheelAxisName) end)
  if ok and type(v) == 'number' then
    if math.abs(v) > 0.01 and Z.axisSamples < 12 then
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
  if Z.ipcSeq < 0 then
    Z.ipcSeq = seq
    return 0
  end
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
  if Z.notchTotal <= 6 then
    lp('KEYEVT', tostring(select(1, ...)), tostring(select(2, ...)), 'argc=', select('#', ...))
  end
  if num == 13 then
    Z.notch = (Z.notch or 0) + 1
    Z.sniffUntil = Z.frame + 8
  end
end

-- ============================================================
-- 校准
-- ============================================================
local function schedule(fn, sec)
  pcall(function() UE4.Timer.Add(sec or 0.01, fn) end)
end

local calIdx = 0
local calResults = {}
local verifyMechanism

local function finishCalibration()
  Z.calibrating = false

  local best = nil
  for i = 1, #calResults do
    local r = calResults[i]
    if best == nil or (r.strength or 0) > (best.strength or 0) then best = r end
  end

  if best and (best.strength or 0) >= 0.7 and (best.mag or 0) >= 80 then
    Z.mech = {
      name = best.variant.name,
      space = best.variant.space,
      axis = best.variant.axis,
      sign = (best.proj > 0) and best.variant.sign or (-best.variant.sign),
    }
    if best.baseDist and best.baseDist > 50 then CFG.baseDist = best.baseDist end
    lp('CAL WINNER', Z.mech.name, 'sign=', Z.mech.sign,
      'proj=', fmt(best.proj, 2), 'moved=', fmt(best.mag, 0),
      'baseDist=', fmt(CFG.baseDist, 0))
    hud('CamZoom 校准完成 -> ' .. Z.mech.name, 4.0)
    schedule(function() verifyMechanism() end, 0.3)
  else
    Z.mech = nil
    lp('CAL no working offset variant')
    hud('CamZoom: 位移偏移也没生效 (见 Game.log)', 6.0)
  end
end

verifyMechanism = function()
  if not Z.mech then return end
  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  local pcm = getPCM()
  if not pawn or not cam or not pcm then return end

  local before = measure(pawn, cam)
  Z.z = 1.6
  Z.zTarget = 1.6
  applyZoom(pawn, cam, pcm)
  schedule(function()
    local after = measure(pawn, cam)
    local moved = nil
    if before.loc and after.loc then
      moved = vecLen(vecSub(after.loc, before.loc))
    end
    lp('VERIFY 1.6x moved=', fmt(moved, 0), 'cm  distBefore=', fmt(before.dist, 0),
      'distAfter=', fmt(after.dist, 0))
    if moved and moved > 60 then
      hud(string.format('CamZoom 可用: %s (位移 %.0fcm)', Z.mech.name, moved), 4.0)
    else
      hud('CamZoom: 位移几乎没有效果', 5.0)
      lp('VERIFY weak')
    end
    Z.z = 1.0
    Z.zTarget = 1.0
    applyZoom(pawn, cam, pcm)
  end, 0.45)
end

local function calStep()
  if Z.dead or not Z.calibrating then return end
  calIdx = calIdx + 1
  local v = VARIANTS[calIdx]
  if not v then
    schedule(finishCalibration, 0.15)
    return
  end

  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  local pcm = getPCM()
  if not pawn or not cam or not pcm then
    Z.calibrating = false
    lp('CAL aborted: objects missing')
    return
  end

  local before = measure(pawn, cam)
  local vec = variantVector(v, cam, CFG.calMag)
  if not vec then
    schedule(calStep, 0.05)
    return
  end

  tryClearOffset(pcm)
  local ok = tryAddOffset(pcm, vec)
  if not ok then
    lp('CAL skip', v.name, '[add offset failed]')
    schedule(calStep, 0.05)
    return
  end

  schedule(function()
    local after = measure(pawn, cam)
    local moved, proj, strength = 0, 0, 0
    if before.loc and after.loc then
      local d = vecSub(after.loc, before.loc)
      moved = vecLen(d) or 0
      if moved > 1 and before.fwd then
        proj = vecDot({ X = d.X / moved, Y = d.Y / moved, Z = d.Z / moved }, before.fwd)
        strength = math.abs(proj)
      end
    end
    tryClearOffset(pcm)

    lp('CAL move', v.name, 'space=' .. v.space, 'sign=' .. tostring(v.sign),
      'moved=' .. fmt(moved, 0) .. 'cm', 'proj=' .. fmt(proj, 2),
      'distBefore=' .. fmt(before.dist, 0), 'distAfter=' .. fmt(after.dist, 0))

    calResults[#calResults + 1] = {
      variant = v, proj = proj, mag = moved, strength = strength, baseDist = before.dist,
    }
    schedule(calStep, 0.12)
  end, CFG.calDwell)
end

local function startCalibration(pawn, cam, pcm)
  if Z.calibrated or Z.calibrating then return end
  Z.calibrated = true
  Z.calibrating = true
  calIdx = 0
  calResults = {}

  pcall(function()
    local PROBE = { 'Camera', 'CameraComponent', 'CameraBlueprint', 'CameraBoom', 'SpringArm' }
    local found = {}
    for i = 1, #PROBE do
      local ok, v = pcall(function() return pawn[PROBE[i]] end)
      if ok and v then found[#found + 1] = PROBE[i] end
    end
    lp('PROBE pawn cam objs:', table.concat(found, ','))
  end)

  local b = measure(pawn, cam)
  lp('CAL v21 begin variants=', #VARIANTS, 'baseDist=', fmt(b.dist, 0), 'fov=', fmt(b.fov))
  hud('CamZoom 校准中…(相机会短暂抖动)', 4.0)
  schedule(calStep, 0.5)
end

-- ============================================================
-- 主循环
-- ============================================================
local function onWheel(steps, allowWrap)
  if steps == 0 then return end
  if CFG.invertWheel then steps = -steps end

  Z.zTarget = Z.zTarget + steps * CFG.notchStep
  if Z.zTarget > CFG.zMax then
    if allowWrap then Z.zTarget = CFG.zMin else Z.zTarget = CFG.zMax end
  elseif Z.zTarget < CFG.zMin then
    if allowWrap then Z.zTarget = CFG.zMax else Z.zTarget = CFG.zMin end
  end
  hudState()
end

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

    if not Z.calibrated and pcm then
      if Z.firstCombatFrame == nil then Z.firstCombatFrame = Z.frame end
      if Z.frame - Z.firstCombatFrame > 100 then
        startCalibration(pawn, cam, pcm)
      end
    end

    local delta = 0
    local allowWrap = false

    local ipc = pollIPC()
    if ipc ~= 0 then delta = ipc end

    if delta == 0 then
      local av = pollWheelAxis(pc)
      if av ~= 0 then
        if Z.axisArmed ~= false then
          Z.axisArmed = false
          delta = (av > 0) and 1 or -1
          Z.hasDirection = true
          if Z.wheelSrc ~= 'ipc' then Z.wheelSrc = 'axis' end
        end
      else
        Z.axisArmed = true
      end
    end

    if delta == 0 and (Z.notch or 0) > 0 and not Z.hasDirection then
      delta = Z.notch
      Z.notch = 0
      Z.wheelSrc = 'notch'
      allowWrap = true
    end
    if (Z.notch or 0) > 0 and Z.hasDirection then Z.notch = 0 end

    if delta ~= 0 then onWheel(delta, allowWrap) end

    if Z.mech then
      local dz = Z.zTarget - Z.z
      local stepv = CFG.smooth * CFG.pollInterval
      if math.abs(dz) <= stepv then
        Z.z = Z.zTarget
      else
        Z.z = Z.z + (dz > 0 and stepv or -stepv)
      end
      applyZoom(pawn, cam, pcm)
    end
  end)

  if not okAll then
    Z.errCount = Z.errCount + 1
    if Z.errCount <= 10 then lp('STEP ERR', tostring(err)) end
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
    lp('v21 online')
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
  lp('v21 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v21 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard
