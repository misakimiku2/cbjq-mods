-- ========================================================
-- @File    : CamZoomMod.lua (v46)
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）
--
-- v46（2026-10-29）：P1e 机制重新定位（v45 旋转护盾实机零触发，方向错误）
--   v45 实测：整个会话 0 次 SHIELD 触发，轨迹显示相机组件旋转（Roll/Pitch/
--   Yaw）全程恒定 —— 上一轮视频里看到的画面滚转是 CameraManager 层（POV
--   后处理）效果，组件旋转读不到。用户第二轮录帧（17 帧连拍）给出决定性
--   证据：起跑瞬间相机沿视线方向猛推向前 —— 109/110 帧人物正常拉近居中，
--   111 帧人物滑到画面右缘，112~121 帧人物完全消失（镜头已推过人物身上、
--   贴地看前方），125 帧人物以约 2.3 倍大小回弹（比正常拉近位更近）。
--   背景箱子同步变大 = 视差 = 相机真的前移了约 200cm+。日志侧：relLoc 恒
--   等于写入值（游戏不碰）、组件旋转恒定 → 前冲走 boom/socket 通道。
--   不缩放时同样的前冲只是 3.2m→1.5m 的温和 punch-in（原版 hence 无感）；
--   拉近到 1.2m 时同一前冲直接穿人 = 猛烈抖动。
--   a) 距离钳制（本版核心）：每帧测「相机-人物世界距离」，低于 minCamDist
--   (90cm) 且收拢速度 ≥8cm/20ms（区分游戏演出与贴墙挤压/地形慢变）时，
--   把写入偏移往外收 deficit=minCamDist-dist，相机最近只到 90cm —— 人物
--   永远在画面里，穿人不可能发生。演出回退时 deficit 自动归零、缩放自动
--   滑回，无需计时器，恢复速度与游戏自身演出一致。钳制期间冻结居中积分
--   （防前冲瞬态污染 hold）。日志 DCLAMP on/off。
--   b) 记录器增强：v45 轨迹从 spd>350 才开始，恰好漏掉起跑加速段（前冲
--   发生在 350 之前）。改为常驻 15 帧环形缓冲（spd/dw/dist），spd>120 触发
--   时先倾倒缓冲（覆盖起跑前 300ms）再记 90 帧；配额 8→12。完整轨迹行
--   加 dist= 字段。
--   c) v45 旋转护盾保留（实测对本案无效但无害，防其它演出）。
--
-- v45（2026-10-29）：修 P1e 起跑抖动（机制已由用户录屏逐帧取证锁定）
--   取证结论（60fps 逐帧 + 结构张量 + 背景差分）：起跑瞬间相机视图在
--   2~3 帧内滚转 +4.5°（缓走 lean 只有 ~22°/s，起跑突变 ~90°/s）并保持
--   到冲刺结束；背景差分同帧爆发（YDIF 5~8，基线 1~2）。结论：游戏在
--   起跑瞬间快速旋转相机父链（socket 级 yaw/pitch 为主）。无缩放时相机
--   就在父链旋转原点（relLoc=0）上，旋转只动视野不动位置 —— 原版 hence
--   「不缩放不抖」；我们写了 2m+ 的 relLoc 偏移后，同样的旋转把相机沿
--   弧线甩出（每 5° ≈ 17cm/3帧）= 猛烈抖动。游戏全程不写 relLoc（v44
--   已实锤），v43 的让行无从谈起，只能做逐帧补偿。
--   a) 旋转护盾：逐帧跟踪相机世界旋转，|ΔRoll| ≥ 1.0°/20ms 即判定为
--   游戏演出（滚轮/鼠标永远不产生 Roll，只有游戏演出会），护盾 0.4s
--   （Roll 持续快变则续期）。护盾期内每帧把写入偏移按帧间旋转增量
--   反向小角度旋转（rel' = rel − ω×rel，ω 由 ΔRoll/Pitch/Yaw 与相机
--   前/右/上轴合成），相机世界位置在演出期间保持不动 = 弧线甩动被
--   精确抵消，视野旋转（演出本身）原样保留。结束后 aimBlend=0 走
--   「从当前机位滑向目标」回归（残差仅数 cm，0.18s 滑入无感）。
--   护盾期间冻结居中积分（防演出瞬态污染 hold）。
--   b) 记录器修复：K2_GetVelocity 在 UE4 不存在（GetVelocity 才对），
--   此前 pcall 静默失败、速度恒 0，v44 的起跑轨迹因此全空；轨迹加记
--   Roll/Pitch 与世界 Z 位移，护盾触发也顺带启动轨迹（双路取证）。
-- v38（2026-10-29）：修 P0 基准漂移（切人后越拉越远、拉不近）
--   根因（日志实锤）：v37 的每帧自校正把「游戏自己动的相机」（切人过渡、
--   开镜机位）误判成基准变了，吸收进 baseRel 后逐次累积 —— 漂移量恰好是
--   ±253.7（z=1.8 的施加量）的整数倍：-253 → -507 → -761 → -1267 → -1464。
--   修法：baseRel 恒为 (0,0,0)（挂点原点），删除一切「从当前读数反推基准」
--   的逻辑；每帧写绝对目标 (mag, lat, 0)，幂等收敛，漂移在结构上不可能。
--   实机验证（2026-10-29）：✓ 不再漂移，切人后距离稳定。
--
-- v39（2026-10-29）：修 v38 引入的切人「重置→过渡」效果
--   v38 在切人检测里设 aimBlend=0（想复用开镜退出的渐变做平滑重施），
--   但切人后偏移其实早已写满，设 0 反而让镜头先弹回默认机位、
--   再用 0.18s 渐变爬回缩放位置 —— 用户实测是明显的「重置过程」。
--   删掉该行：切人后立即写满偏移（绝对写入无漂移风险），
--   行为回到 v37 的即时回位，仅保留游戏自身的 1~3 帧复位闪烁。
--
-- v40（2026-10-29）：修拉近居中状态下切人，居中/靠左隔代交替
--   （实测 A居中→B靠左→C居中→A靠左 循环）
--   根因：居中是「进场测一次 dv 定死保持」，切人检测清掉保持值后重测，
--   但重测时上一任的居中量还写在相机上 —— 测到的是残差（≈0）而非自然
--   偏移 → 保持值掉到 0，人物掉回游戏自然偏机位；下一次切人测到的才是
--   自然偏移 → 又居中。如此隔代交替。
--   修法：改成慢速积分器（每帧按残差 dv 微调 hold，增益 0.15 重阻尼），
--   切人不再清居中量（上一任数值本来就对，沿用并微调），不依赖测量时机，
--   切人动画/相机飞行造成的任何残差都会在零点几秒内自愈。
--   实机验证（2026-10-29）：✓ 交替循环消失；✗ 切人后镜头一点一点微抖
--
-- v41（2026-10-29）：修 v40 积分器导致的切人后镜头微抖
--   两处来源：a) 切人动画里相机还在飞、dv 剧烈摆动，被积分器吃进去把
--   正确的 hold 冲歪，动画结束后再慢慢回摆；b) 待机动画的挂点小幅摆动
--   是持续信号，积分器永久追着它做 0.4cm 级微步修正。
--   修法：给积分器加两道闸 —— 切人后 1s 冻结（沿用上一任 hold）+
--   |dv|<2cm 死区（待机偏差肉眼不可见，不值得追）。只在误差稳定且
--   超过死区时才收敛，收敛完即静止。
--   实机验证（2026-10-29）：✓ 微抖消失；✗ 从近（居中）往远拉时偏移硬切
--
-- v42（2026-10-29）：修从近往远拉出居中区间时的硬切（v40 引入的回归）
--   v39 的居中量乘 ct（随拉远连续变小），退出区间自然平滑；v40 改成
--   hold × latFade 后 latFade 只有淡入没有淡出 —— 拉出区间瞬间偏移归零。
--   修法：latFade 改为双向包络，出区间 0.2s 淡出（期间 hold 冻结），
--   降到 0 才清状态；来回穿越边界就地反向，均平滑。
--   实机验证（2026-10-29）：✓ 硬切消失；✗ 滚轮改过缩放后开跑瞬间镜头猛烈抖动
--
-- v43（2026-10-29）：修滚轮改过缩放后开跑瞬间的猛烈抖动
--   根因：只要偏移非 0 我们就持有 relLoc 绝对写入权，游戏任何挪相机的动作
--   都会在 20ms 内被拉回。开跑瞬间游戏自己有相机演出（冲刺机位），它写一步
--   我们拉一步，逐帧互殴 = 猛烈抖动；没缩放时不抖是因为释放态下我们从不写。
--   修法：a) 接管检测 —— 游戏把相机挪离我们写入值超过 takeoverCm(1.2cm/帧)
--   就让行 yieldFrames(0.5s)，期间完全不写，演完再由 aimBlend 重新施加
--   （与开镜让行同一套机制）；b) 恢复改「从当前机位向目标滑入」而非从 0
--   重新出发，开镜退出 / 让行结束的恢复都不再有起点跳变。
--   实机验证（2026-10-29）：✗ 起跑抖动照旧（机制不成立）；✗ 切人回归成
--   「重置→过渡」（让行抢先在切人的相机复位上触发了）
--
-- v44（2026-10-29）：修 v43 切人回归 + 起跑抖动取证
--   日志实锤：全程仅 3 次接管、全是切人触发（dx=-461.7/260.6/121.2 都是
--   游戏重置相机）；54 次心跳 cur 与写入值零偏差 —— 起跑时游戏根本不碰
--   relLoc，「互殴」假设不成立，抖动必然发生在 relLoc 之外。
--   a) 切人回归修复：切人检测改逐帧，检测到切人立即取消在途让行、清施加
--   状态、aimBlend=1，下一帧绝对写入立即落满偏移（恢复 v39 已验证行为）；
--   b) 起跑记录器：速度触发（<100 武装 / >350 触发，每次 60 帧 50Hz），
--   记录 relLoc / 相机世界位移 / 相机与角色朝向 / FOV，下一轮用轨迹定位
--   真正机制后再精准修复。
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
  centerK = 0.15,          -- 居中积分增益：每帧按残差 dv 修正的比例（重阻尼防自激）
  centerFadeIn = 0.25,     -- 居中量淡入时长（秒）：拉进居中区间的过渡
  centerFadeOut = 0.20,    -- 居中量淡出时长（秒）：拉出居中区间的过渡（v42）
  aimRamp = 0.18,          -- 退出开镜后偏移恢复的时长（秒）
  takeoverCm = 1.2,        -- 单帧内游戏把相机挪离我们写入值的阈值（cm），超过即让行
  yieldFrames = 25,        -- 让行帧数（20ms/帧 = 0.5s），让游戏的相机演出播完
  runSpdLo = 100.0,        -- 速度低于此值重新武装起跑记录器（cm/s）
  runSpdHi = 350.0,        -- 速度超过此值视为起跑，触发轨迹记录（cm/s）
  rotShieldTrig = 1.0,     -- 单帧 |ΔRoll| 阈值（度/20ms样本）：游戏演出旋转护盾
  rotShieldFrames = 20,    -- 护盾持续帧数（20ms/帧 = 0.4s），Roll 持续快变则续期
  traceFrames = 90,        -- 轨迹记录帧数（50Hz ≈ 1.8s）
  minCamDist = 90.0,       -- 距离钳制下限（cm）：相机-人物世界距离低于此值即外推
  distCloseRate = 8.0,     -- 距离收拢速度门槛（cm/20ms）：低于此视为游戏合法慢变不钳
  ringFrames = 15,         -- 记录器环形缓冲帧数（常驻，触发时倾倒=起跑前 300ms）
  traceSpdTrig = 120.0,    -- 轨迹触发速度（cm/s）：覆盖起跑加速段

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
  baseRel = { X = 0, Y = 0, Z = 0 },   -- 常量：挂点原点，任何代码路径不得再赋值
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

  -- 基准恒为 (0,0,0)。此刻读到什么都不要采纳：若在切人/过渡动画中标定，
  -- 把临时机位收进基准，漂移就从这里开始（v37 的教训）
  local rNow = relLoc(cam)
  lp('CAL begin relLocNow=', vstr(rNow))

  local before = worldLoc(cam)
  local pl = pawnLoc(pawn)
  if not before or not pl then
    lp('CAL failed: 无坐标')
    calib.done = true
    return
  end

  -- 沿本地 X 推 calMag，测世界位移方向
  local test = v3(cfg.calMag, 0, 0)
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
  local testY = v3(0, cfg.calMag, 0)
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
      -- 让行时一次性还原到游戏默认机位（基准恒为 0），之后不再干预
      setRel(cam, Z.baseRel)
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('APPLY released for aim')
    end
    return
  end
  local ab = Z.aimBlend or 1.0

  -- 让行窗口内完全不写（v43）：把相机还给游戏，让它把自己的动作演完
  if Z.frame < (Z.yieldUntil or 0) then
    return
  end

  local cur = relLoc(cam)

  -- 游戏接管检测（v43）：只要我们持有 relLoc 的绝对写入权（appliedMag 非空），
  -- 游戏若把相机挪离我们最后一次写入值超过 takeoverCm —— 正常游戏进程根本
  -- 不碰这个值，唯一来源是游戏自己的相机演出（典型：开跑瞬间的冲刺机位）——
  -- 绝不硬抢。硬抢就是实测的「开跑瞬间猛烈抖动」：游戏写一步、我们拉一步，
  -- 逐帧互殴。让行 yieldFrames 帧演完，之后 aimBlend 从 0 平滑重新施加。
  if Z.appliedMag ~= nil and cur ~= nil then
    local dx = cur.X - (Z.baseRel.X + Z.appliedMag)
    local dy = cur.Y - (Z.baseRel.Y + (Z.appliedLat or 0))
    if math.abs(dx) > cfg.takeoverCm or math.abs(dy) > cfg.takeoverCm then
      Z.yieldUntil = Z.frame + cfg.yieldFrames
      Z.aimBlend = 0.0
      -- 解除所有权：防止让行一结束就拿陈旧的 appliedMag 再误判一次接管
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('YIELD game takeover dx=', fmt(dx, 1), 'dy=', fmt(dy, 1))
      return
    end
  end

  -- 旋转护盾（v45）：游戏演出旋转相机父链期间，逐帧把写入偏移按帧间
  -- 旋转增量反向补偿（rel' = rel − ω×rel），相机世界位置保持不动，
  -- 弧线甩动被精确抵消；视野旋转（演出本身）原样保留，玩家只看到
  -- 原版同款的视角 lean。护盾结束走 aimBlend「从当前机位滑向目标」，
  -- 残差只有演出累计的几 cm，0.18s 滑入无感。
  if Z.frame < (Z.shieldUntil or 0) then
    if Z.appliedMag == nil or cur == nil or Z.dRot == nil then
      return                      -- 没持有写入权就无可补偿，静默等护盾过期
    end
    -- 期间游戏若直接改写 relLoc（罕见），丢弃护盾交还给接管逻辑
    if math.abs(cur.X - (Z.baseRel.X + Z.appliedMag)) > cfg.takeoverCm or
       math.abs(cur.Y - (Z.baseRel.Y + (Z.appliedLat or 0))) > cfg.takeoverCm then
      Z.shieldUntil = 0
      Z.shieldOn = false
      lp('SHIELD dropped: game rewrote relLoc')
      return
    end
    local dr = math.rad(Z.dRot.R)
    local dp = math.rad(Z.dRot.P)
    local dyw = math.rad(Z.dRot.Y)
    if math.abs(dr) > 1e-9 or math.abs(dp) > 1e-9 or math.abs(dyw) > 1e-9 then
      local fwd, rgt, upv = nil, nil, nil
      do
        local okR, rot = pcall(function() return cam:K2_GetComponentRotation() end)
        if okR and rot then
          local okA, f = pcall(function() return UE4.UKismetMathLibrary.GetForwardVector(rot) end)
          local okB, r = pcall(function() return UE4.UKismetMathLibrary.GetRightVector(rot) end)
          local okC, u = pcall(function() return UE4.UKismetMathLibrary.GetUpVector(rot) end)
          if okA and okB and okC then fwd, rgt, upv = f, r, u end
        end
      end
      if fwd and rgt and upv then
        -- 世界系小角速度向量 ω（UE 约定：Roll 绕前向、Pitch 绕右向、Yaw 绕上向）
        local wx = fwd.X * dr + rgt.X * dp + upv.X * dyw
        local wy = fwd.Y * dr + rgt.Y * dp + upv.Y * dyw
        local wz = fwd.Z * dr + rgt.Z * dp + upv.Z * dyw
        local px = cur.X - Z.baseRel.X
        local py = cur.Y - Z.baseRel.Y
        local pz = (cur.Z or 0) - Z.baseRel.Z
        -- rel' = rel − ω×rel（小角度逆旋转，逐帧补偿无累计误差）
        local cx = px - (wy * pz - wz * py)
        local cy = py - (wz * px - wx * pz)
        local cz = pz - (wx * py - wy * px)
        if setRel(cam, v3(Z.baseRel.X + cx, Z.baseRel.Y + cy, Z.baseRel.Z + cz)) then
          Z.appliedMag = cx
          Z.appliedLat = cy
          if not Z.shieldOn then
            Z.shieldOn = true
            lp('SHIELD compensating dR=', fmt(Z.dRot.R, 2), 'dP=', fmt(Z.dRot.P, 2),
               'dY=', fmt(Z.dRot.Y, 2))
          end
        end
      end
    end
    return
  elseif Z.shieldOn then
    Z.shieldOn = false
    Z.aimBlend = 0.0     -- 护盾结束：从补偿后的当前机位平滑滑回目标机位
    ab = 0.0             -- 同步局部值，否则当帧就会写满目标造成跳变
    lp('SHIELD off -> resume via aimBlend')
  end

  if ab < 1.0 then
    ab = math.min(1.0, ab + cfg.pollInterval / cfg.aimRamp)
    Z.aimBlend = ab
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
    local pl = Z.plast
    local cl = Z.clast               -- 用 step() 里同一份世界坐标（含钳制基准）
    local okR, rot = pcall(function() return cam:K2_GetComponentRotation() end)
    if pl and cl and okR and rot then
      local okv, rv = pcall(function() return UE4.UKismetMathLibrary.GetRightVector(rot) end)
      if okv and rv then
        dv = dot(sub(pl, cl), v3(rv.X, rv.Y, rv.Z))
      end
    end
  end

  -- 横向居中：慢速积分器 + 双向淡入淡出包络（v42）。
  -- v39 及之前是「进场测一次 dv 定死」：切人后重测时上一任的居中量还写在
  -- 相机上，测到的是残差而非自然偏移 → hold 掉到 0，居中/靠左隔代交替。
  -- 积分器不依赖测量时机：切人后保留上一任 hold（数值本来就对），只按
  -- 残差继续微调；符号由几何保证（lat 和 dv 同沿相机右向量，方向唯一）。
  -- v41 抖动闸：切人后 1s 冻结积分（沿用上一任 hold）+ |dv|<2cm 死区，
  -- 待机摆动不再被追着修，收敛完即静止。
  -- v42 双向包络：v40 起去掉了 v39 的 ct 缩放，拉出居中区间时偏移瞬间
  -- 归零（实测硬切，只发生在从近往远）。现在 latFade 是双向的：
  -- 进区间 centerFadeIn 淡入，出区间 centerFadeOut 淡出（期间 hold 冻结），
  -- fade 降到 0 才清状态；来回快速穿越边界时 fade 就地反向，均平滑。
  local lat = 0
  local inBand = (ct > 0.15 and dv ~= nil and math.abs(dv) <= 400)
  if inBand then
    if Z.latFade == nil then
      Z.latFade = 0
      lp('CENTER start dv=', fmt(dv, 1))
    end
    Z.latFade = math.min(1.0, Z.latFade + cfg.pollInterval / cfg.centerFadeIn)
    local frozen = Z.latHold ~= nil and Z.frame < (Z.centerFreezeUntil or 0)
    if not frozen and (Z.latHold == nil or math.abs(dv) >= 2.0) then
      local hold = (Z.latHold or 0) + dv * cfg.centerK
      if hold > 160 then hold = 160 end
      if hold < -160 then hold = -160 end
      Z.latHold = hold
    end
    lat = (Z.latHold or 0) * Z.latFade * ab
  elseif Z.latHold ~= nil and Z.latFade ~= nil and Z.latFade > 0 then
    -- 出区间：0.2s 淡出，偏移平滑归零后才清状态
    Z.latFade = math.max(0.0, Z.latFade - cfg.pollInterval / cfg.centerFadeOut)
    lat = (Z.latHold or 0) * Z.latFade * ab
    if Z.latFade <= 0 then
      Z.latHold = nil
      Z.latFade = nil
    end
  else
    Z.latHold = nil
    Z.latFade = nil
  end

  local mag = targetOffset(z) * ab
  if mag > cfg.maxOffset then mag = cfg.maxOffset end
  if mag < -cfg.maxOffset then mag = -cfg.maxOffset end
  -- 横向一律钳制，绝不允许把相机甩出去
  if lat > 160 then lat = 160 end
  if lat < -160 then lat = -160 end

  -- 距离钳制（v46 核心修复）：起跑瞬间游戏沿视线方向把相机猛推向前（boom/
  -- socket 通道，relLoc 与组件旋转都不变 —— v45 旋转护盾因此全程未触发）。
  -- 拉近状态下这一推会把相机推过人物身上（用户录帧实证：人物消失、贴地
  -- 看前方，回弹时再造成二次晃动）。每帧测相机-人物世界距离，低于下限就
  -- 把写入偏移往外收 deficit：相机最近只到 minCamDist，穿人在结构上不可能。
  -- 演出回退时 deficit 自动归零、缩放自动滑回 —— 无计时器、无状态机，
  -- 恢复速度与游戏自身演出一致。快速收拢门槛：贴墙挤压/地形慢变是游戏
  -- 合法行为（闭合约 0~4cm/20ms），只有 ≥8cm/20ms 的猛收才钳。
  local deficit = 0
  if Z.dist ~= nil and Z.dist < cfg.minCamDist then
    deficit = cfg.minCamDist - Z.dist
    if (Z.distPrev or 9999) - Z.dist < cfg.distCloseRate and not Z.dclampOn then
      deficit = 0                    -- 慢速靠近不是演出，不抢
    end
    if deficit > 600 then deficit = 600 end
  end
  if deficit > 0.5 then
    if not Z.dclampOn then
      Z.dclampOn = true
      lp('DCLAMP on dist=', fmt(Z.dist, 1), 'prev=', fmt(Z.distPrev, 1),
         'deficit=', fmt(deficit, 1), 'mag=', fmt(mag, 1))
    end
    Z.dclampLast = Z.frame
    -- 冻结居中积分到钳制结束后一小段（前冲瞬态不得污染 hold，v41 同理）
    Z.centerFreezeUntil = math.max(Z.centerFreezeUntil or 0, Z.frame + 25)
  elseif Z.dclampOn and Z.frame - (Z.dclampLast or 0) > 20 then
    Z.dclampOn = false
    lp('DCLAMP off')
  end
  local magW = mag - deficit

  -- 绝对写入：目标 = 基准(0) + 偏移。ab<1 时改为「从当前机位向目标滑入」
  -- 而不是从 0 重新出发 —— 开镜退出 / 让行结束的恢复都不再有起点跳变。
  -- 读 cur 同时用于接管检测与防抖；读不到就直接写（绝对写入幂等，多写无害）
  local wantX = Z.baseRel.X + magW
  local wantY = Z.baseRel.Y + lat
  local writeX, writeY = wantX, wantY
  if cur ~= nil and ab < 1.0 then
    writeX = cur.X + (wantX - cur.X) * ab
    writeY = cur.Y + (wantY - cur.Y) * ab
  end

  if cur ~= nil and math.abs(cur.X - writeX) < 0.4 and math.abs(cur.Y - writeY) < 0.4 then
    Z.appliedMag = writeX - Z.baseRel.X
    Z.appliedLat = writeY - Z.baseRel.Y
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

  if setRel(cam, v3(writeX, writeY, Z.baseRel.Z)) then
    Z.appliedMag = writeX - Z.baseRel.X
    Z.appliedLat = writeY - Z.baseRel.Y
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

    -- 切人 / 切相机检测（v44 起逐帧）：换了角色就是合法复位 —— 立即清施加
    -- 状态并取消在途让行，下一帧绝对写入立即落满偏移（v39 验证过的行为）。
    -- v43 教训：10 帧轮询 + 接管让行会抢先在切人的相机复位上触发，
    -- 把「立即回位」变成 0.5s 重置→过渡。检测提前到逐帧后，切人时
    -- appliedMag 已先清空，接管检测不再误触。
    -- 注意：这里绝不能清 latHold（v39 教训：清了会居中/靠左交替），
    -- 居中量由积分器按残差自愈
    do
      local camPath = pathOf(cam)
      if Z.camPath ~= nil and Z.camPath ~= camPath then
        Z.appliedMag = nil
        Z.appliedLat = nil
        Z.yieldUntil = 0
        Z.aimBlend = 1.0      -- 切人回位不走渐变（v38 教训），立即写满
        -- 冻结居中积分 1s（50 帧）：盖过切人动画的 dv 瞬态，防止把
        -- 上一任的正确 hold 冲歪（v41 教训：不冻结 = 切人后镜头微抖）
        Z.centerFreezeUntil = Z.frame + 50
        -- 旋转护盾状态一并复位：切人瞬间的旋转读数跳变不得触发护盾
        Z.rotPrev = nil
        Z.dRot = nil
        Z.shieldUntil = 0
        Z.shieldOn = false
        -- baseDist 只在「没缩放」时重测，否则测到的是带偏移的距离
        if math.abs(Z.z - 1.0) < 0.05 then
          local pl2 = pawnLoc(pawn)
          local cl2 = worldLoc(cam)
          if pl2 and cl2 then
            local d2 = vlen(sub(cl2, pl2))
            if d2 > 60 then Z.baseDist = d2 end
          end
        end
        lp('CAM change -> reset, baseDist=', fmt(Z.baseDist, 0), 'keepZ=', fmt(Z.z, 2))
      end
      Z.camPath = camPath
    end

    -- 每帧一次性取位置（v46）：距离钳制 / 居中 dv / 记录器共用同一份测量，
    -- 避免 50Hz 下重复 pcall；dist = 相机-人物世界距离
    Z.distPrev = Z.dist
    Z.plast = pawnLoc(pawn)
    Z.clast = worldLoc(cam)
    Z.dist = (Z.plast and Z.clast) and vlen(sub(Z.clast, Z.plast)) or nil

    -- 旋转护盾（v45）：逐帧跟踪相机世界旋转。滚轮/鼠标永远不产生 Roll，
    -- |ΔRoll| 突然超标只可能是游戏自己的相机演出（起跑 lean 一类）。演出
    -- 旋转的是相机父链：无缩放时相机在父链原点上、旋转只动视野（原版
    -- 行为，无感）；我们持有 2m+ relLoc 偏移时，同样的旋转把相机沿弧线
    -- 甩出 —— 这就是 P1e 的猛烈抖动（游戏不写 relLoc，v44 已实锤）。
    -- 触发后 applyZoom 在护盾期内逐帧反向补偿写入偏移。
    do
      local okR, rr = pcall(function() return cam:K2_GetComponentRotation() end)
      if okR and rr and type(rr.Roll) == 'number' then
        if Z.rotPrev then
          local dR = rr.Roll - Z.rotPrev.R
          local dP = rr.Pitch - Z.rotPrev.P
          local dY = rr.Yaw - Z.rotPrev.Y
          if dY > 180 then dY = dY - 360 elseif dY < -180 then dY = dY + 360 end
          Z.dRot = { R = dR, P = dP, Y = dY }
          if math.abs(dR) >= cfg.rotShieldTrig then
            if Z.frame >= (Z.shieldUntil or 0) then
              lp('SHIELD on dR=', fmt(dR, 2), 'dP=', fmt(dP, 2), 'dY=', fmt(dY, 2),
                 'mag=', fmt(Z.appliedMag, 1), 'lat=', fmt(Z.appliedLat, 1))
              -- 冻结居中积分到护盾结束后一小段，防演出瞬态污染 hold（v41 同理）
              Z.centerFreezeUntil = math.max(Z.centerFreezeUntil or 0,
                Z.frame + cfg.rotShieldFrames + 25)
              -- 护盾触发顺带启动一次轨迹（取证：θ/位置/relLoc 三方对照）
              if (Z.traceLeft or 0) <= 0 and (Z.traceCount or 0) < 8 then
                Z.traceCount = (Z.traceCount or 0) + 1
                Z.traceLeft = cfg.traceFrames
                Z.traceW = worldLoc(cam)
                lp('RUN trace start (shield) mag=', fmt(Z.appliedMag, 1), 'z=', fmt(Z.z, 2))
              end
            end
            Z.shieldUntil = Z.frame + cfg.rotShieldFrames
          end
        end
        Z.rotPrev = { R = rr.Roll, P = rr.Pitch, Y = rr.Yaw }
      end
    end

    -- 起跑记录器（v44 取证）：日志实锤起跑时游戏不碰 relLoc（全程仅 3 次
    -- 接管全是切人；54 次心跳 cur 与写入值零偏差），抖动必然发生在 relLoc
    -- 之外。速度触发一次 50Hz 轨迹记录：relLoc / 相机世界位移 / 相机与角色
    -- 朝向 / FOV，下一轮用真实轨迹定位机制，不再盲猜。
    do
      local spd = 0
      -- v45 修复：UE4 里 AActor 的蓝图函数名是 GetVelocity，K2_GetVelocity
      -- 不存在 —— v44 的 pcall 静默失败、速度恒 0，起跑轨迹从未触发过
      local okV, vv = pcall(function() return pawn:GetVelocity() end)
      if not okV or not vv then
        okV, vv = pcall(function() return pawn:K2_GetVelocity() end)
      end
      if okV and vv and vv.X then spd = vlen(vv) end
      -- 环形缓冲（v46）：常驻记录最近 ringFrames 帧（spd/dw/dist）。
      -- 前冲发生在 spd>350 之前 —— v45 轨迹从 350 才开始，恰好漏掉起跑
      -- 加速段；现在触发时先倾倒缓冲（起跑前 ~300ms）再记 90 帧。
      local w = Z.clast
      local dwx, dwy, dwz = nil, nil, nil
      if w and Z.traceW then
        dwx = w.X - Z.traceW.X
        dwy = w.Y - Z.traceW.Y
        dwz = w.Z - Z.traceW.Z
      end
      if w then Z.traceW = w end
      Z.ringN = (Z.ringN or 0) + 1
      Z.ring = Z.ring or {}
      Z.ring[(Z.ringN % cfg.ringFrames) + 1] = 'spd=' .. fmt(spd, 0) ..
        ' dw=' .. (dwx and (fmt(dwx, 1) .. ',' .. fmt(dwy, 1) .. ',' .. fmt(dwz, 1)) or 'nil') ..
        ' dist=' .. fmt(Z.dist, 0) ..
        ' mag=' .. fmt(Z.appliedMag, 1)
      if spd < cfg.runSpdLo then
        Z.runArmed = true
      elseif Z.runArmed and spd > cfg.traceSpdTrig and (Z.traceCount or 0) < 12 then
        Z.runArmed = false
        Z.traceCount = (Z.traceCount or 0) + 1
        Z.traceLeft = cfg.traceFrames
        for k = 1, cfg.ringFrames do
          local idx = (Z.ringN - cfg.ringFrames + k) % cfg.ringFrames + 1
          if Z.ring[idx] then lp('RUNpre', Z.ring[idx]) end
        end
        lp('RUN trace start spd=', fmt(spd, 0), 'mag=', fmt(Z.appliedMag, 1),
           'z=', fmt(Z.z, 2), 'dist=', fmt(Z.dist, 0))
      end
      if (Z.traceLeft or 0) > 0 then
        Z.traceLeft = Z.traceLeft - 1
        local c2 = relLoc(cam)
        local cyaw, cpit, crol = nil, nil, nil
        local okR, rr = pcall(function() return cam:K2_GetComponentRotation() end)
        if okR and rr then
          cyaw, cpit, crol = rr.Yaw, rr.Pitch, rr.Roll
        end
        local pyaw = nil
        local okP, pr = pcall(function() return pawn:K2_GetActorRotation() end)
        if okP and pr then pyaw = pr.Yaw end
        lp('RUN i=', cfg.traceFrames - Z.traceLeft,
           'spd=', fmt(spd, 0),
           'cur=', c2 and vstr(c2) or 'nil',
           'mag=', fmt(Z.appliedMag, 1),
           'dw=', (dwx and (fmt(dwx, 1) .. ',' .. fmt(dwy, 1) .. ',' .. fmt(dwz, 1)) or 'nil'),
           'dist=', fmt(Z.dist, 0),
           'cyaw=', fmt(cyaw, 1), 'cp=', fmt(cpit, 1), 'cr=', fmt(crol, 1),
           'pyaw=', fmt(pyaw, 1),
           'fov=', fmt(fovOf(cam), 1))
      end
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
         'mag=', fmt(Z.appliedMag, 1), 'lat=', fmt(Z.appliedLat, 1),
         'hold=', fmt(Z.latHold, 1), 'yd=', fmt(math.max(0, (Z.yieldUntil or 0) - Z.frame)),
         'sh=', fmt(math.max(0, (Z.shieldUntil or 0) - Z.frame)),
         'err=', Z.err,
         'src=', Z.wheelSrc, 'baseRel=', vstr(Z.baseRel),
         'cur=', vstr(curD), 'worldZ=', fmt(clD and clD.Z or nil, 1),
         'dist=', fmt(Z.dist, 0))
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
    lp('v46 online')
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
  lp('v46 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v46 injected but NOT ready, allow retry')
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
