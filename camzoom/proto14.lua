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
  zMin = 0.60,
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

-- 角色 -> 相机 的单位向量：这才是"拉远/拉近"的物理轴
local function axisBack(pawn, cam)
  local l = camLoc(cam)
  if not l then return nil end
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okP or not pl then return nil end
  local dx, dy, dz = l.X - pl.X, l.Y - pl.Y, l.Z - pl.Z
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1 then return nil end
  return { X = dx / len, Y = dy / len, Z = dz / len, len = len }
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
-- 真正的相机距离：只能从管理器要，组件坐标是占位值（v22 已验证它不动）
local function camTransDist(pawn, pcm)
  local ok, t = pcall(function() return pcm:GetPlayerCameraComponentTrans() end)
  if not ok or t == nil then return nil end
  local loc = nil
  pcall(function() loc = t.Translation end)
  if loc == nil then pcall(function() loc = t.Location end) end
  if loc == nil then return nil end
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okP or not pl then return nil end
  local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function applyZoom(pawn, cam, pcm)
  local m = Z.mech
  if not m or not pcm or not cam then return false end
  local z = Z.z

  -- 硬性安全阈值：一旦相机距离失控，立刻复位并停用（防止再飞出去）
  local dNow = camTransDist(pawn, pcm)
  if dNow and CFG.baseDist > 60 then
    if dNow > CFG.baseDist * 2.6 or dNow < CFG.baseDist * 0.3 then
      lp('SAFETY dist=', fmt(dNow, 0), 'base=', fmt(CFG.baseDist, 0), '-> reset & disable')
      tryClearOffset(pcm)
      Z.mech = nil
      Z.z = 1.0
      Z.zTarget = 1.0
      Z.applied = nil
      hud('CamZoom: 安全保护触发，已复位', 5.0)
      return false
    end
  end

  if math.abs(z - 1.0) < 0.004 then
    if Z.applied ~= nil then
      tryClearOffset(pcm)
      Z.applied = nil
      lp('APPLY released to game')
    end
    return true
  end

  local ax = axisBack(pawn, cam)
  if not ax then return false end
  local s = (z - 1.0) * CFG.baseDist * ((m.dirBack ~= false) and 1 or -1)
  local vec = { X = ax.X * s, Y = ax.Y * s, Z = ax.Z * s }

  tryClearOffset(pcm)
  local ok = pcall(function()
    pcm:AddCameraDataOffset(UE4.FVector(vec.X, vec.Y, vec.Z))
  end)
  if not ok then
    Z.errCount = Z.errCount + 1
    if Z.errCount >= 8 then
      lp('APPLY failed, disable mech')
      Z.mech = nil
    end
    return false
  end
  Z.applied = z
  return true
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

-- ============================================================
-- v24：安全模式
--   v22 的 6 次 AddCameraDataOffset 把相机推出了地图（用户实测），
--   说明这个偏移会持续生效、ClearCameraDataOffset 并不能真正复位。
--   所以这一版：
--     · 启动/进战斗时完全不碰相机
--     · 只在用户第一次滚轮时做一次「80cm 小位移 + 2 秒连续采样」的探测，
--       目的是搞清楚它是「设一次就停」还是「每帧累加」
--     · 平时不缩放，等探测结论出来再实现
-- ============================================================
local probe = { started = false, done = false, d = {} }

local function locStr(l)
  if not l then return 'nil' end
  return string.format('(%.0f,%.0f,%.0f)', l.X, l.Y, l.Z)
end


local function camTransStr(pcm, pawn)
  local ok, t = pcall(function() return pcm:GetPlayerCameraComponentTrans() end)
  if not ok or t == nil then return 'nil' end
  local loc = nil
  local ok1, v = pcall(function() return t.Translation end)
  if ok1 and v then loc = v end
  if loc == nil then
    local ok2, v2 = pcall(function() return t.Location end)
    if ok2 and v2 then loc = v2 end
  end
  if loc == nil then return 'no-loc' end
  local d = -1
  local okP, pl = pcall(function() return pawn:K2_GetActorLocation() end)
  if okP and pl then
    local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
    d = math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  return string.format('(%.0f,%.0f,%.0f) d=%.0f', loc.X, loc.Y, loc.Z, d)
end

local verifyMechanism   -- 保留符号，主循环里可能引用

local function probeSample(pcm, pawn, tag)
  lp('PROBE2', tag, camTransStr(pcm, pawn))
end

local function startProbe(pawn, cam, pcm)
  if probe.started or probe.done then return end
  probe.started = true

  local ax = axisBack(pawn, cam)
  if not ax then
    lp('PROBE2 no axis')
    probe.done = true
    return
  end

  local mag = 80.0   -- 只推 80cm，尽量不破坏视野
  local vec = { X = ax.X * mag, Y = ax.Y * mag, Z = ax.Z * mag }

  lp('PROBE2 begin, push 80cm along pawn->cam axis', locStr(vec))
  probeSample(pcm, pawn, 't0-before')
  probe.d[#probe.d + 1] = { tag = 't0', v = camTransDist(pawn, pcm) }

  local ok = pcall(function()
    pcm:AddCameraDataOffset(UE4.FVector(vec.X, vec.Y, vec.Z))
  end)
  lp('PROBE2 addOffset ok=', tostring(ok))

  local steps = { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0 }
  for i = 1, #steps do
    local delay = steps[i] - (steps[i - 1] or 0)
    schedule(function()
      probeSample(pcm, pawn, 't+' .. steps[i] .. 's')
      probe.d[#probe.d + 1] = { tag = 't' .. steps[i], v = camTransDist(pawn, pcm) }
      if i == #steps then
        tryClearOffset(pcm)
        lp('PROBE2 cleared')
        schedule(function()
          probeSample(pcm, pawn, 'after-clear')
          probe.d[#probe.d + 1] = { tag = 'clear', v = camTransDist(pawn, pcm) }
          probe.done = true
          decideMechanism()
          lp('PROBE2 done')
        end, 0.35)
      end
    end, delay)
  end
end

-- 根据采样判断偏移语义，并直接决定实现方式
function decideMechanism()
  local d0, d1, d2, dc = nil, nil, nil, nil
  for i = 1, #probe.d do
    local s = probe.d[i]
    if s.tag == 't0' then d0 = s.v
    elseif s.tag == 't0.25' then d1 = s.v
    elseif s.tag == 't2' then d2 = s.v
    elseif s.tag == 'clear' then dc = s.v end
  end
  lp('PROBE2 decide d0=', fmt(d0, 0), 'd0.25=', fmt(d1, 0), 'd2=', fmt(d2, 0), 'dclear=', fmt(dc, 0))

  if not d0 or not d1 then
    lp('PROBE2 无有效读数，放弃')
    return
  end
  if d0 > 60 then CFG.baseDist = d0 end

  local early = d1 - d0
  local late = (d2 or d1) - d0
  local back = dc and (math.abs(dc - d0) < 25) or false

  if math.abs(early) < 15 then
    lp('PROBE2 => 偏移无效（相机没动）')
    hud('CamZoom: 该接口对本镜头无效', 5.0)
    return
  end

  if math.abs(late) > math.abs(early) * 2.0 and math.abs(late) > 60 then
    lp('PROBE2 => 每帧累加，不可直接使用')
    hud('CamZoom: 偏移会累加，需补偿方案', 5.0)
    return
  end

  -- 有效且不失控：启用缩放
  Z.mech = { name = 'addoff', kind = 'addoff', dirBack = (early > 0) }
  lp('PROBE2 => 可用! dirBack=', tostring(early > 0), 'back=', tostring(back),
     'baseDist=', fmt(CFG.baseDist, 0))
  hud('CamZoom: 镜头推拉已启用 (滚轮试)', 5.0)
end

-- 开关：探测完成前不缩放
local function canZoom()
  return probe.done
end
-- v24：不做任何自动校准，相机在用户主动滚轮之前完全不碰
local function startCalibration(pawn, cam, pcm)
  lp('(v24 无自动校准)')
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

    if delta ~= 0 then
      if not probe.done then
        -- 第一次滚轮：只做一次 80cm 探测，不缩放
        startProbe(pawn, cam, pcm)
      else
        onWheel(delta, allowWrap)
      end
    end

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
    lp('v25 online')
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
  lp('v25 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v25 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard
