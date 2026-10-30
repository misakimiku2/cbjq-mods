-- ========================================================
-- @File    : CamZoomMod.lua (v28)
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）
--
-- v27 实机反馈（2026-10-28 13:46）：
--   ✓ 组件相对位置能驱动相机（推拉确实发生了）
--   ✗ 但把「角色→相机」向量投影到三轴后，多余分量落到 Y/Z，
--     造成横向漂移：人物越操作越偏到画面右边
--   ✗ 拉远时相机被抬高（Z 分量），人跑出画面
--   ✗ 上滚=拉远（方向反了）
--
-- 标定数据表明：localX 占 98% → 本地 X 轴 ≈ 视线前向。
-- v28 因此只沿单一本地轴施加标量偏移（Y/Z 恒等于基准），彻底杜绝横向漂移。
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

local cfg = {
  zMin = 0.42,
  zMax = 2.20,
  notchStep = 0.06,
  smooth = 5.0,
  pollInterval = 0.02,
  calMag = 60.0,
  maxOffset = 620.0,
  applyEps = 0.004,
  invertWheel = true,      -- 上滚 = 拉近（GTA 习惯）
  ipcPath = 'D:\\test\\cbjq-re\\runtime\\wheel.txt',
  wheelAxisName = 'MouseScrollWheel',
}

local Z = {
  z = 1.0, zTarget = 1.0,
  frame = 0, err = 0, dead = false,
  wheelSrc = 'none', hasDirection = false,
  notch = 0, notchTotal = 0,
  ioChecked = false, hasIO = false, ipcSeq = -1,
  axisSamples = 0,
  ready = false,
  baseRel = { X = 0, Y = 0, Z = 0 },
  coef = 1.0,             -- 沿本地 X 轴的单位位移系数（±1，来自标定）
  baseDist = 300.0,
  appliedZ = nil,
  lastWarn = 0,
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

local function pathOf(o)
  if o == nil then return 'nil' end
  local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, o)
  if ok and p then return tostring(p) end
  return ''
end

local function isGameplay(pc)
  local s = pathOf(pc)
  return (s:find('GameController', 1, true) ~= nil) or (s:find('FightController', 1, true) ~= nil)
end

local function getCam(pawn)
  local ok, c = pcall(function() return pawn.Camera end)
  if ok and c then return c end
  return nil
end

-- ============================================================
-- 向量/读写
-- ============================================================
local function v3(x, y, z) return { X = x, Y = y, Z = z } end
local function sub(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function vlen(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
local function unit(a)
  local l = vlen(a)
  if l < 0.0001 then return v3(0, 0, 0) end
  return v3(a.X / l, a.Y / l, a.Z / l)
end
local function vstr(a)
  if not a then return 'nil' end
  return string.format('(%.2f,%.2f,%.2f)', a.X, a.Y, a.Z)
end

local function worldLoc(cam)
  local ok, l = pcall(function() return cam:K2_GetComponentLocation() end)
  if ok and l then return v3(l.X, l.Y, l.Z) end
  return nil
end

local function pawnLoc(pawn)
  local ok, l = pcall(function() return pawn:K2_GetActorLocation() end)
  if ok and l then return v3(l.X, l.Y, l.Z) end
  return nil
end

local function relLoc(cam)
  local ok, l = pcall(function() return cam:K2_GetRelativeLocation() end)
  if ok and l then return v3(l.X, l.Y, l.Z) end
  return nil
end

local function setRel(cam, v)
  return pcall(function()
    cam:K2_SetRelativeLocation(UE4.FVector(v.X, v.Y, v.Z), false, nil, false)
  end)
end

local function fovOf(cam)
  local ok, v = pcall(function() return cam.FieldOfView end)
  if ok and type(v) == 'number' then return v end
  return nil
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
      UE4.FLinearColor(0.35, 0.95, 1.0, 1.0), dur or 2.0)
  end)
end

-- ============================================================
-- 滚轮
-- ============================================================
local function pollWheelAxis(pc)
  local ok, v = pcall(function() return pc:GetInputAxisValue(cfg.wheelAxisName) end)
  if ok and type(v) == 'number' then
    if math.abs(v) > 0.01 and Z.axisSamples < 8 then
      Z.axisSamples = Z.axisSamples + 1
      lp('WHEELAXIS', cfg.wheelAxisName, fmt(v, 3))
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

  local ok, f = pcall(io.open, cfg.ipcPath, 'r')
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
-- 标定：只测本地 X 轴，确定「+X 是朝角色还是朝远方」
-- ============================================================
local calib = { started = false, done = false }

local function calibrate(pawn, cam)
  if calib.started then return end
  calib.started = true

  local r = relLoc(cam)
  if r then Z.baseRel = r end
  lp('CAL begin baseRel=', vstr(Z.baseRel))

  local before = worldLoc(cam)
  local pl = pawnLoc(pawn)
  if not before or not pl then
    lp('CAL failed: 无坐标')
    calib.done = true
    return
  end

  -- 沿本地 X 推 calMag，测世界位移方向
  local test = v3(Z.baseRel.X + cfg.calMag, Z.baseRel.Y, Z.baseRel.Z)
  if not setRel(cam, test) then
    lp('CAL failed: 写相对位置失败')
    calib.done = true
    return
  end
  local after = worldLoc(cam)
  setRel(cam, Z.baseRel)
  if not after then
    lp('CAL failed: 读世界坐标失败')
    calib.done = true
    return
  end

  local delta = sub(after, before)
  local dir = unit(delta)
  local back = unit(sub(before, pl))   -- 角色 -> 相机
  local c = dot(dir, back)
  lp('CAL localX unit=', vstr(dir), 'back=', vstr(back), 'coef=', fmt(c, 3))

  if math.abs(c) < 0.5 then
    lp('CAL failed: 本地 X 与视线轴不匹配，无法推拉')
    calib.done = true
    hud('CamZoom: 轴不匹配，需换方案', 5.0)
    return
  end

  Z.coef = (c > 0) and 1.0 or -1.0
  local d = vlen(sub(before, pl))
  if d > 60 then Z.baseDist = d end

  Z.ready = true
  calib.done = true
  lp('CAL done coef=', Z.coef, 'baseDist=', fmt(Z.baseDist, 0))
  hud('CamZoom: 推拉已启用', 3.5)
end

-- ============================================================
-- 应用
-- ============================================================
local function applyZoom(pawn, cam)
  if not Z.ready then return end
  local z = Z.z

  -- 开镜时让行，避免覆盖游戏的越肩机位
  local fv = fovOf(cam)
  if fv and fv < 60.0 then return end

  -- 自校正：每帧把「基准」贴回当前相对位置（必要时扣掉我们施加的量）
  -- 这样即使游戏自己动过相对位置，也不会累积漂移
  local cur = relLoc(cam)
  if cur then
    if Z.appliedMag then
      local expected = Z.baseRel.X + Z.appliedMag
      if math.abs(cur.X - expected) > 2.0 then
        Z.baseRel = v3(cur.X - Z.appliedMag, cur.Y, cur.Z)
        Z.appliedZ = nil        -- 基准变了，强制本帧重算并重新施加
        lp('APPLY resync baseRel=', vstr(Z.baseRel))
      else
        Z.baseRel = v3(Z.baseRel.X, cur.Y, cur.Z)
      end
    else
      Z.baseRel = v3(cur.X, cur.Y, cur.Z)
    end
  end

  if math.abs(z - 1.0) < cfg.applyEps then
    if Z.appliedMag ~= nil then
      setRel(cam, Z.baseRel)
      Z.appliedMag = nil
      Z.appliedZ = nil
      lp('APPLY released, baseRel=', vstr(Z.baseRel))
    end
    return
  end

  if Z.appliedZ and math.abs(Z.appliedZ - z) < cfg.applyEps then return end

  local mag = (z - 1.0) * Z.baseDist * Z.coef
  if mag > cfg.maxOffset then mag = cfg.maxOffset end
  if mag < -cfg.maxOffset then mag = -cfg.maxOffset end

  local target = v3(Z.baseRel.X + mag, Z.baseRel.Y, Z.baseRel.Z)
  if setRel(cam, target) then
    Z.appliedZ = z
    Z.appliedMag = mag
    local bucket = math.floor(z * 10 + 0.5)
    if bucket ~= Z.lastBucket then
      Z.lastBucket = bucket
      lp('APPLY z=', fmt(z, 2), 'localX=', fmt(target.X, 1), 'mag=', fmt(mag, 1))
    end
  end
end

-- ============================================================
-- 主循环
-- ============================================================
local function onWheel(steps)
  if steps == 0 then return end
  if cfg.invertWheel then steps = -steps end
  Z.zTarget = Z.zTarget + steps * cfg.notchStep
  if Z.zTarget > cfg.zMax then Z.zTarget = cfg.zMax end
  if Z.zTarget < cfg.zMin then Z.zTarget = cfg.zMin end
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

    if delta ~= 0 and not Z.ready then
      calibrate(pawn, cam)
    end

    if Z.ready then
      if delta ~= 0 then onWheel(delta) end
      local dz = Z.zTarget - Z.z
      local stepv = cfg.smooth * cfg.pollInterval
      if math.abs(dz) <= stepv then
        Z.z = Z.zTarget
      else
        Z.z = Z.z + (dz > 0 and stepv or -stepv)
      end
      applyZoom(pawn, cam)
    end
  end)

  if not okAll then
    Z.err = Z.err + 1
    if Z.err <= 8 then lp('STEP ERR', tostring(err)) end
    if Z.err > 80 then
      Z.dead = true
      lp('too many errors, disabled')
    end
  end
end

local _loopStarted = false
local _subCount = 0

local function loop()
  step()
  pcall(function() UE4.Timer.Add(cfg.pollInterval, loop) end)
end

function CamZoomMod.Start()
  if _loopStarted then return end
  local ok = pcall(function() UE4.Timer.Add(0.5, loop) end)
  if ok then
    _loopStarted = true
    lp('v28 online')
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
  lp('v28 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v28 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard
