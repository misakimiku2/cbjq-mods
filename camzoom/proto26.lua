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
  zMin = 0.38,
  zMax = 1.80,
  notchStep = 0.075,
  tau = 0.15,              -- 平滑时间常数（秒），越大越慢越柔
  pollInterval = 0.02,
  calMag = 60.0,
  maxOffset = 700.0,
  applyEps = 0.002,
  invertWheel = true,      -- 上滚 = 拉近（GTA 习惯）

  -- 欣赏模式：z 低于 portraitStart 后，相机后拉 + FOV 收窄（长焦人像感）
  portraitStart = 0.74,    -- 从这个倍率开始进入
  portraitEnd = 0.42,
  portraitFov = 42.0,      -- 收窄到的 FOV
  portraitPull = 150.0,    -- 后拉距离（cm）
  centerStart = 0.96,      -- 从这个倍率开始把人物往中间拉
  centerGain = 1.0,        -- 居中强度
  aimRamp = 0.18,          -- 退出开镜后偏移恢复的时长（秒）

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
  local ok2, l2 = pcall(function() return cam.RelativeLocation end)
  if ok2 and l2 then return v3(l2.X, l2.Y, l2.Z) end
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
  lp('CAL begin baseRel=', vstr(Z.baseRel), 'relLocOk=', tostring(r ~= nil))

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

  -- 再测本地 Y 轴，用于「欣赏模式」把人物横向拉回画面中间
  Z.ySign = nil
  local testY = v3(Z.baseRel.X, Z.baseRel.Y + cfg.calMag, Z.baseRel.Z)
  if setRel(cam, testY) then
    local afterY = worldLoc(cam)
    setRel(cam, Z.baseRel)
    if afterY then
      local yDir = unit(sub(afterY, before))
      local okR, rot = pcall(function() return cam:K2_GetComponentRotation() end)
      if okR and rot then
        local okv, rv = pcall(function() return UE4.UKismetMathLibrary.GetRightVector(rot) end)
        if okv and rv then
          local s = dot(yDir, v3(rv.X, rv.Y, rv.Z))
          Z.ySign = (s > 0) and 1.0 or -1.0
          lp('CAL localY unit=', vstr(yDir), 'rightDot=', fmt(s, 3), 'ySign=', Z.ySign)
        end
      end
    end
  end

  Z.baseFov = fovOf(cam) or 75.0
  Z.ready = true
  calib.done = true
  lp('CAL done coef=', Z.coef, 'baseDist=', fmt(Z.baseDist, 0), 'ySign=', tostring(Z.ySign))
  hud('CamZoom: 推拉已启用', 3.5)
end

-- ============================================================
-- 应用
-- ============================================================
-- 欣赏模式插值系数 0..1
local function portraitT(z)
  if z >= cfg.portraitStart then return 0 end
  if z <= cfg.portraitEnd then return 1 end
  return (cfg.portraitStart - z) / (cfg.portraitStart - cfg.portraitEnd)
end

-- 目标位移：正值 = 相机后拉，负值 = 推近
-- 目标位移：正值 = 相机后拉，负值 = 推近（最终都要乘 coef 换算成本地轴符号）
local function fovWorks()
  return Z.fovActiveFrame ~= nil and (Z.frame - Z.fovActiveFrame) < 90
end

local function targetOffset(z)
  local t = portraitT(z)
  local v
  if t > 0 and fovWorks() then
    -- FOV 真的被写进去了：后拉 + 收窄 = 长焦人像
    local atStart = (cfg.portraitStart - 1.0) * Z.baseDist
    v = atStart + (cfg.portraitPull - atStart) * t
  else
    -- FOV 不可用（当前就是这种）：保持纯线性，才能继续推近
    v = (z - 1.0) * Z.baseDist
  end
  return v * (Z.coef or 1.0)
end

local function applyZoom(pawn, cam)
  if not Z.ready then return end
  local z = Z.z
  local t = portraitT(z)
  Z.portraitT = t

  -- 开镜时彻底让行；退出开镜后按 aimRamp 平滑恢复，避免硬切
  local fv = fovOf(cam)
  local aimTh = (Z.baseFov or 75.0) - 12.0
  if fv and fv > 5.0 and fv < aimTh then
    Z.aimBlend = 0.0
    if Z.appliedMag ~= nil then
      -- 释放时用「当前相对位置 - 我们施加的量」还原，而不是拿旧基准硬写，
      -- 避免开镜瞬间被我们拽回旧机位、并把基准污染成开镜机位
      local c2 = relLoc(cam)
      local b = Z.baseRel
      if c2 then
        b = v3(c2.X - (Z.appliedMag or 0), c2.Y - (Z.appliedLat or 0), c2.Z)
      end
      Z.baseRel = b
      setRel(cam, b)
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('APPLY released for aim, base=', vstr(b))
    end
    Z.latHold = nil
    Z.latPhase = nil
    return
  end
  local ab = Z.aimBlend or 1.0
  if ab < 1.0 then
    ab = math.min(1.0, ab + cfg.pollInterval / cfg.aimRamp)
    Z.aimBlend = ab
  end

  -- 注意：K2_GetRelativeLocation 在部分机型上不可用（返回 nil）。
  -- 这时不能 return，否则整个应用层会被短路；用「上次基准+上次施加量」兜底即可。
  local cur = relLoc(cam)
  if cur == nil then
    cur = v3(Z.baseRel.X + (Z.appliedMag or 0), Z.baseRel.Y + (Z.appliedLat or 0), Z.baseRel.Z)
    Z.relLocMissing = true
  end

  -- 游戏动过基准（与「基准+上帧施加量」差异大）→ 重估基准，永不累积漂移
  if Z.appliedMag ~= nil and not Z.relLocMissing then
    local expX = Z.baseRel.X + Z.appliedMag
    local expY = Z.baseRel.Y + (Z.appliedLat or 0)
    if math.abs(cur.X - expX) > 6.0 or math.abs(cur.Y - expY) > 6.0 then
      Z.baseRel = v3(cur.X - Z.appliedMag, cur.Y - (Z.appliedLat or 0), cur.Z)
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('APPLY resync baseRel=', vstr(Z.baseRel))
    end
  else
    Z.baseRel = v3(cur.X, cur.Y, cur.Z)
  end

  -- 横向居中：拉近到 centerStart 以下开始把人物往画面中间拉
  local ct = 0
  if z < cfg.centerStart then
    if z <= cfg.portraitStart then
      ct = 1.0
    else
      ct = (cfg.centerStart - z) / (cfg.centerStart - cfg.portraitStart)
    end
  end

  -- 量「角色相对相机的横向量」：正 = 角色在画面右
  local dv = nil
  do
    local pl = pawnLoc(pawn)
    local cl = worldLoc(cam)          -- 必须用世界坐标！cur 是相对坐标（恒 0），两者不能混算
    local okR, rot = pcall(function() return cam:K2_GetComponentRotation() end)
    if pl and cl and okR and rot then
      local okv, rv = pcall(function() return UE4.UKismetMathLibrary.GetRightVector(rot) end)
      if okv and rv then
        dv = dot(sub(pl, cl), v3(rv.X, rv.Y, rv.Z))
      end
    end
  end

  -- 横向居中：一次性测方向 + 定值保持（刻意不做逐帧反馈，闭环一旦判错会自激放大）
  local lat = 0
  if ct <= 0.15 or dv == nil or math.abs(dv) > 400 then
    Z.latPhase = nil
    Z.latHold = nil
    Z.latDirV = nil
  else
    if Z.latPhase == nil then
      -- 直接按测得偏差补偿（不做可见的试探位移）
      Z.latHold = dv
      if Z.latHold > 150 then Z.latHold = 150 end
      if Z.latHold < -150 then Z.latHold = -150 end
      Z.dvBefore = dv
      Z.latPhase = 'apply'
      lp('CENTER apply dv=', fmt(dv, 1), 'hold=', fmt(Z.latHold, 1), 'z=', fmt(z, 2))
    elseif Z.latPhase == 'apply' then
      -- 施加一帧后校验：偏差变大说明方向反了，翻符号
      if math.abs(dv) > math.abs(Z.dvBefore or 0) + 4 then
        Z.latHold = -(Z.latHold or 0)
        lp('CENTER flip: dv0=', fmt(Z.dvBefore or 0, 1), 'dvNow=', fmt(dv, 1),
           'newHold=', fmt(Z.latHold, 1))
      end
      Z.latPhase = 'run'
    end

    lat = (Z.latHold or 0) * ct * ab
  end

  local mag = targetOffset(z) * ab
  if mag > cfg.maxOffset then mag = cfg.maxOffset end
  if mag < -cfg.maxOffset then mag = -cfg.maxOffset end
  -- 横向一律钳制，绝不允许把相机甩出去
  if lat > 160 then lat = 160 end
  if lat < -160 then lat = -160 end

  local wantX = Z.baseRel.X + mag
  local wantY = Z.baseRel.Y + lat

  -- 已经在目标位置就不写，避免和游戏互抢造成细微抖动
  if math.abs(cur.X - wantX) < 0.4 and math.abs(cur.Y - wantY) < 0.4 then
    Z.appliedMag = mag
    Z.appliedLat = lat
    return
  end

  if math.abs(mag) < 0.4 and math.abs(lat) < 0.4 then
    if Z.appliedMag ~= nil then
      setRel(cam, Z.baseRel)
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('APPLY released')
    end
    return
  end

  if setRel(cam, v3(wantX, wantY, Z.baseRel.Z)) then
    Z.appliedMag = mag
    Z.appliedLat = lat
    local bucket = math.floor(z * 50 + 0.5)
    if bucket ~= Z.lastBucket then
      Z.lastBucket = bucket
      lp('APPLY z=', fmt(z, 3), 'mag=', fmt(mag, 1), 'lat=', fmt(lat, 1), 't=', fmt(t, 2), 'ab=', fmt(ab, 2))
    end
  end
end

-- 晚帧写入：由主界面 UMG Tick 调用（Slate tick 在相机更新之后、渲染之前）
-- 只有在这个时机写 FOV 才不会被游戏当帧回写
function CamZoomMod.LateTick(dt)
  Z.lateFrames = (Z.lateFrames or 0) + 1
  if Z.lateFrames % 120 == 0 then
    lp('LATE alive frames=', Z.lateFrames, 'ready=', tostring(Z.ready), 't=', fmt(Z.portraitT, 2))
  end
  if Z.dead or not Z.ready then return end
  local t = Z.portraitT or 0
  if t <= 0.01 then return end

  local pawn = getPawn()
  local cam = pawn and getCam(pawn)
  if not cam then return end
  local fv = fovOf(cam)
  local aimTh2 = (Z.baseFov or 75.0) - 12.0
  if fv and fv > 5.0 and fv < aimTh2 then return end

  local fov = (Z.baseFov or 75.0) + (cfg.portraitFov - (Z.baseFov or 75.0)) * t
  local okW = pcall(function() cam.FieldOfView = fov end)
  if okW then Z.fovActiveFrame = Z.frame end
  if Z.lateFrames % 90 == 0 then
    lp('LATE tick frames=', Z.lateFrames, 'targetFov=', fmt(fov, 1), 't=', fmt(t, 2))
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

    -- 切人 / 切相机检测：换了角色就重建基准，并把当前缩放立刻用到新角色上
    if Z.frame % 10 == 0 then
      local camPath = pathOf(cam)
      if Z.camPath ~= nil and Z.camPath ~= camPath then
        -- 关键：基准必须扣掉我们上一轮施加的量，否则每次切人都会把旧偏移
        -- 当成新基准再叠加一次 → 镜头越切越远
        local r = relLoc(cam)
        local b = v3(0, 0, 0)
        if r then
          b = v3(r.X - (Z.appliedMag or 0), r.Y - (Z.appliedLat or 0), r.Z)
          -- 这套相机挂点的真实基准应为 0，偏离过大说明是残留，直接归零
          if math.abs(b.X) > 50 then b.X = 0 end
          if math.abs(b.Y) > 50 then b.Y = 0 end
        end
        Z.baseRel = b
        Z.appliedMag = nil
        Z.appliedLat = nil
        Z.latPhase = nil
        Z.latHold = nil
        -- baseDist 只在「没缩放」时重测，否则测到的是带偏移的距离
        if math.abs(Z.z - 1.0) < 0.05 then
          local pl2 = pawnLoc(pawn)
          local cl2 = worldLoc(cam)
          if pl2 and cl2 then
            local d2 = vlen(sub(cl2, pl2))
            if d2 > 60 then Z.baseDist = d2 end
          end
        end
        lp('CAM change -> baseRel=', vstr(Z.baseRel),
           'baseDist=', fmt(Z.baseDist, 0), 'keepZ=', fmt(Z.z, 2))
      end
      Z.camPath = camPath
    end

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

    -- 心跳：每 ~2 秒打一行状态，便于定位「为什么没反应」
    Z.hb = (Z.hb or 0) + 1
    if Z.hb % 100 == 0 then
      local fvh = pawn and getCam(pawn) and fovOf(getCam(pawn)) or nil
      local curD = relLoc(cam)
      local clD = worldLoc(cam)
      lp('HB frame=', Z.frame, 'z=', fmt(Z.z, 2), 'zt=', fmt(Z.zTarget, 2),
         'fov=', fmt(fvh, 1), 'ready=', tostring(Z.ready), 'ab=', fmt(Z.aimBlend, 2),
         'mag=', fmt(Z.appliedMag, 1), 'lat=', fmt(Z.appliedLat, 1), 'err=', Z.err,
         'src=', Z.wheelSrc, 'baseRel=', vstr(Z.baseRel),
         'cur=', vstr(curD), 'worldZ=', fmt(clD and clD.Z or nil, 1))
    end

    if Z.ready then
      if delta ~= 0 then onWheel(delta) end
      -- 指数平滑：时间常数 tau，帧率无关，手感柔和不卡顿
      local dz = Z.zTarget - Z.z
      if math.abs(dz) < 0.0008 then
        Z.z = Z.zTarget
      else
        local k = 1.0 - math.exp(-cfg.pollInterval / cfg.tau)
        Z.z = Z.z + dz * k
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
    lp('v37 online')
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
  lp('v37 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v37 injected but NOT ready, allow retry')
end

end -- CamZoomMod guard

-- 注意：这段必须留在守卫之外。
-- ResourceAmend.lua 先加载会占掉 _ready，导致 umg_main 那份整块被跳过，
-- 而 tbClass 只在 umg_main.lua 里可见 —— 钩子必须独立执行才能装上。
pcall(function()
  if CamZoomMod._lateHooked then return end
  if type(tbClass) ~= 'table' or type(tbClass.Tick) ~= 'function' then return end
  if type(CamZoomMod.LateTick) ~= 'function' then return end
  local orig = tbClass.Tick
  tbClass.Tick = function(self, geom, d)
    pcall(orig, self, geom, d)
    pcall(function() CamZoomMod.LateTick(d) end)
  end
  CamZoomMod._lateHooked = true
  print('[CamZoom] LateTick hooked')
end)
