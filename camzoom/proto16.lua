-- ========================================================
-- @File    : CamZoomMod.lua (v27)
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）—— 正式实现
--
-- v26 探测确认（2026-10-28 13:38）：
--   ✓ pawn.Camera:K2_SetRelativeLocation(...) 能移动相机、0.5s 内不被覆写、可还原
--     P1: relLoc(0,0,0) +120Z → 世界坐标 Z +119.4，t+0.25/t+0.5 均保持
--   ✗ camera.FieldOfView 写入后 0.25s 内被游戏回写（P2 实测 45 → 75）
--   ✗ AddCameraDataOffset 空操作；CameraCache.POV 是陈旧默认值
--
-- 原理：相机组件挂在某个父节点上，其「相对位置」是自由可写的。
--   先标定父空间三个基向量在世界中的方向（各推 60cm 测位移），
--   再把「角色→相机」方向的位移投影到本地轴，写入相对位置即可推拉。
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
  zMin = 0.55,
  zMax = 2.60,
  notchStep = 0.085,
  smooth = 10.0,
  pollInterval = 0.02,
  calMag = 60.0,
  maxOffset = 700.0,
  ipcPath = 'D:\\test\\cbjq-re\\runtime\\wheel.txt',
  wheelAxisName = 'MouseScrollWheel',
  invertWheel = false,
}

local Z = {
  z = 1.0, zTarget = 1.0,
  frame = 0, err = 0, dead = false,
  wheelSrc = 'none', hasDirection = false,
  notch = 0, notchTotal = 0,
  ioChecked = false, hasIO = false, ipcSeq = -1,
  axisSamples = 0,
  ready = false,          -- 标定完成
  baseRel = { X = 0, Y = 0, Z = 0 },
  basis = nil,            -- {u,v,w} 父空间三轴在世界中的单位方向
  baseDist = 300.0,
  appliedZ = nil,
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
-- 读写
-- ============================================================
local function v3(x, y, z) return { X = x, Y = y, Z = z } end

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

local function sub(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function len(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
local function unit(a)
  local l = len(a)
  if l < 0.0001 then return v3(0, 0, 0) end
  return v3(a.X / l, a.Y / l, a.Z / l)
end
local function scale(a, s) return v3(a.X * s, a.Y * s, a.Z * s) end
local function vstr(a)
  if not a then return 'nil' end
  return string.format('(%.2f,%.2f,%.2f)', a.X, a.Y, a.Z)
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
-- 标定：父空间三轴在世界中的方向
-- ============================================================
local calib = { started = false, done = false }

local function measureBasisAxis(cam, axisName)
  local base = Z.baseRel
  local test = v3(base.X, base.Y, base.Z)
  if axisName == 'X' then test.X = test.X + cfg.calMag
  elseif axisName == 'Y' then test.Y = test.Y + cfg.calMag
  else test.Z = test.Z + cfg.calMag end

  local before = worldLoc(cam)
  if not before then return nil end
  if not setRel(cam, test) then return nil end
  local after = worldLoc(cam)
  setRel(cam, base)
  if not after then return nil end

  local delta = sub(after, before)
  local d = unit(delta)
  lp('CAL axis', axisName, 'delta=', vstr(delta), 'unit=', vstr(d))
  return d
end

local function calibrate(pawn, cam)
  if calib.started then return end
  calib.started = true

  local r = relLoc(cam)
  if r then Z.baseRel = r end
  lp('CAL begin baseRel=', vstr(Z.baseRel))

  local u = measureBasisAxis(cam, 'X')
  local v = measureBasisAxis(cam, 'Y')
  local w = measureBasisAxis(cam, 'Z')
  if not u or not v or not w then
    lp('CAL failed: 无法标定基向量')
    calib.done = true
    Z.dead = true
    return
  end
  Z.basis = { u = u, v = v, w = w }

  local pl = pawnLoc(pawn)
  local cl = worldLoc(cam)
  if pl and cl then
    local d = len(sub(cl, pl))
    if d > 60 then Z.baseDist = d end
  end

  lp('CAL done basis u=', vstr(u), 'v=', vstr(v), 'w=', vstr(w),
     'baseDist=', fmt(Z.baseDist, 0))
  Z.ready = true
  calib.done = true
  hud('CamZoom: 镜头推拉已启用', 4.0)
end

-- ============================================================
-- 应用缩放
-- ============================================================
local function applyZoom(pawn, cam)
  if not Z.ready or not Z.basis then return end
  local z = Z.z

  if math.abs(z - 1.0) < 0.003 then
    if Z.appliedZ ~= nil then
      setRel(cam, Z.baseRel)
      Z.appliedZ = nil
      lp('APPLY released')
    end
    return
  end

  if Z.appliedZ and math.abs(Z.appliedZ - z) < 0.002 then return end

  local pl = pawnLoc(pawn)
  local cl = worldLoc(cam)
  if not pl or not cl then return end
  local back = unit(sub(cl, pl))
  if len(back) < 0.5 then return end

  local mag = (z - 1.0) * Z.baseDist
  if mag > cfg.maxOffset then mag = cfg.maxOffset end
  if mag < -cfg.maxOffset then mag = -cfg.maxOffset end

  -- 期望的世界位移向量，投影到父空间三轴
  local world = scale(back, mag)
  local lx = dot(world, Z.basis.u)
  local ly = dot(world, Z.basis.v)
  local lz = dot(world, Z.basis.w)

  local target = v3(Z.baseRel.X + lx, Z.baseRel.Y + ly, Z.baseRel.Z + lz)
  if setRel(cam, target) then
    Z.appliedZ = z
    local bucket = math.floor(z * 10 + 0.5)
    if bucket ~= Z.lastLogBucket then
      Z.lastLogBucket = bucket
      lp('APPLY z=', fmt(z, 2), 'localOffset=', vstr(v3(lx, ly, lz)))
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
  hud(string.format('CamZoom  x%.2f', Z.zTarget), 1.5)
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

    -- 第一次滚轮：先标定，再缩放
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
    lp('v27 online')
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
  lp('v27 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v27 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard
