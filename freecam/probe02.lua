-- ========================================================
-- @File    : FreeCamProbe.lua (probe v2)
-- @Brief   : 游戏场景自由相机 —— 入口普查 + 可行性验证（一次性，不落地任何持久状态）
--
-- v2（相对 v1 的修正，基于 v1 实机日志）：
--   v1 实测结论：
--     * 游戏自带的自由相机入口**全部不存在**（pc 上没有 EnableDebugCamera /
--       ToggleDebugCamera；pcm 上没有 SetFreeWatchCameraMode / SetUniversalCameraMode）；
--       AFreeWatchModeCameraActor 类也不可见（AUniversalCameraActor 可见）
--     * 但 **spawn ACameraActor 成功**（CameraActor_xxxxxxxx），pc:SetViewTargetWithBlend 存在
--     * 正常 gameplay 的 ViewTarget 是**角色本体**（BP_Girl017_C_...），不是相机 Actor
--   v1 的 bug：spawn 那一步的 verify 返回 true，导致阶梯提前宣告命中，
--       viewtarget / povfollow 两步根本没跑到 —— Q3（POV 是否跟我们走）没验证。
--   v2 修正：引入 terminal 标记，只有「能证明画面归我们」的步骤才算命中；
--       spawn 降级为前置条件步骤。
--   v2 新增（这几条直接决定拍照能不能出片）：
--     * hold 期间若 ViewTarget 被抢回，**立即尝试重挂**，统计能不能靠每帧重设赢回来
--     * fovwrite：往我们自己这颗相机写 FOV（游戏不会再改它 —— 因为相机是我们的）
--     * dilation：SetGlobalTimeDilation 是否可用（拍照定格的前提；用 0.02 不是 0，
--       避免把 UnLua Timer 一起冻死导致无法还原）
--
-- 目的：用一次游戏运行回答五个问题，决定自由相机走哪条路。
--   Q1 引擎 / 游戏是否已经暴露「自由相机」入口
--        pc:EnableDebugCamera / pcm:SetFreeWatchCameraMode / pcm:SetUniversalCameraMode
--   Q2 若都没有，能否 spawn 一个 ACameraActor 并把 ViewTarget 切过去
--   Q3 切过去之后引擎是否真的用这个相机出画面（POV 是否跟着我们走）
--   Q4 游戏会不会自己把 ViewTarget 抢回去（切人 / 进战斗 / 剧情），多久一次
--   Q5 批量反射普查：这些相机相关函数到底挂在哪个对象上（为后续实现省几轮试错）
--
-- 安全设计：
--   * 所有调用都在 pcall 里，单步失败只记日志、直接进入下一步
--   * 结束时一定：关 DebugCamera、ViewTarget 切回 pawn、销毁临时相机
--   * 不写任何配置文件，不读写滚轮缩放 MOD 的任何全局状态（两者互不可见）
--   * 只在 gameplay（战斗 / 关卡）且站定后才启动；宿舍 / 菜单不触发
--
-- 判读：日志过滤 [FreeCam]，末尾有 ==== REPORT ==== 汇总块。
-- ========================================================

FreeCamProbe = FreeCamProbe or {}
if not FreeCamProbe._ready then

local LOG = '[FreeCam] '
local function lp(...) print(LOG, ...) end

local function fmt(v, nd)
  if v == nil then return 'nil' end
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%.' .. (nd or 1) .. 'f', v)
end

local cfg = {
  pollInterval = 0.02,     -- 50Hz，与主循环一致
  autoDelay    = 8.0,      -- 就绪后再等这么久（秒）才开跑，给用户反应时间
  stillSpeed   = 80.0,     -- 速度低于此值算站定（cm/s）
  stillFrames  = 50,       -- 连续站定帧数（50 帧 = 1s）
  settle       = 30,       -- 每步执行后等多少帧再验证（30 帧 = 0.6s）
  holdFrames   = 150,      -- 成功后再观察多少帧（150 帧 = 3s），统计 ViewTarget 被抢次数
  camFwd       = 300.0,    -- 测试机位：角色正前方 cm
  camUp        = 70.0,     -- 测试机位：抬高 cm
  probeMove    = 220.0,    -- 验证 POV 跟随：把相机抬这么多 cm
  hardLimit    = 4000,     -- 总帧数硬上限（80s），超时强制收尾
}

local S = {
  frame = 0,
  state = 'wait',          -- wait / base / run / settle / next / hold / report / done
  wait = 0,
  stillCnt = 0,
  armedFrame = 0,
  armed = false,
  done = false,
  camActor = nil,
  fwOn = false,
  ucOn = false,
  dbgOn = false,
  vtReverts = 0,
  vtSeen = nil,
  reassertTry = 0,
  reassertStuck = 0,
  camComp = nil,
  fovBefore = nil,
  success = 'none',
  results = {},
  apiDumped = false,
}

local function note(name, ok, detail)
  S.results[#S.results + 1] = { name = name, ok = ok, detail = detail or '' }
  lp('STEP ' .. string.format('%-18s', name) .. (ok and ' OK   ' or ' FAIL ') .. (detail or ''))
end

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
  return '?'
end

local function shortName(o)
  if o == nil then return 'nil' end
  local p = pathOf(o)
  local s = p:match('([^%.:]+)$')
  return s or p
end

local function isGameplay(pc)
  local s = pathOf(pc)
  return (s:find('GameController', 1, true) ~= nil) or (s:find('FightController', 1, true) ~= nil)
end

local function safeCam(pawn)
  if pawn == nil then return nil end
  local ok, c = pcall(function() return pawn.Camera end)
  if ok and c then return c end
  return nil
end

local function getPCM(pc)
  local ok, v = pcall(function() return pc.PlayerCameraManager end)
  if ok and v then return v end
  local ins = getIns()
  if ins then
    local ok2, v2 = pcall(UE4.UGameplayStatics.GetPlayerCameraManager, ins, 0)
    if ok2 and v2 then return v2 end
  end
  return nil
end

-- ============================================================
-- 反射：只做存在性判断，绝不调用（零风险）
-- ============================================================
local function hasMethod(obj, name)
  if obj == nil then return false end
  local ok, v = pcall(function() return obj[name] end)
  if not ok then return false end
  return type(v) == 'function'
end

local CAND_PC = {
  'EnableDebugCamera', 'DisableDebugCamera', 'ToggleDebugCamera',
  'SetViewTargetWithBlend', 'GetViewTarget', 'SetViewTarget',
  'GetPlayerCameraManager', 'GetThirdPersonPlayerCameraManager', 'GetInteractorFPSCameraActor',
  'SetIgnoreMoveInput', 'SetIgnoreLookInput',
}
local CAND_PCM = {
  'SetFreeWatchCameraMode', 'SetWatchCameraAscendState', 'SetWatchCameraDescendState',
  'SetUniversalCameraMode', 'SetViewTargetToUniversalCamera',
  'SetCameraCanControl', 'SetLockCamera', 'SetSpecialSceneCamera', 'SetSubtituteCamera',
  'SetCameraInstanceClass', 'GetCameraInstance', 'GetCameraInstanceClass', 'GetUniversalCameraInfo',
  'GetCameraActor', 'GetActiveCameraComponent', 'GetCameraLocation', 'GetCameraRotation',
  'StopAllCameraShakes', 'StartCameraShake', 'SetViewTarget',
  'AddOffsetToCurrentCameraLocation', 'SetManualCameraFade', 'SetGameCameraCutThisFrame',
}
local CAND_CAM = {
  'SetFieldOfView', 'GetFieldOfView', 'SetFOVOverride', 'SetCameraFOV', 'SetCameraFov',
  'SetDesiredFOV', 'SetDesiredZoom', 'SetActive', 'SetCameraProjectionMode',
}
local CAND_PAWN = {
  'GetCameraBoom', 'GetCameraComponent', 'GetThirdPersonPlayerCameraManager', 'SetLockCamera',
}
local CAND_CLASS = {
  'ACameraActor', 'ACineCameraActor', 'ADebugCameraController', 'APlayerCameraManager',
  'AThirdPersonPlayerCameraManager', 'AFreeWatchModeCameraActor', 'AUniversalCameraActor',
  'AUUniversalCameraActor', 'UCameraComponent', 'USpringArmComponent',
}

local function dumpApi(tag, obj, names)
  if obj == nil then
    lp('API ' .. string.format('%-8s', tag) .. ' object=nil')
    return
  end
  local found = {}
  for i = 1, #names do
    if hasMethod(obj, names[i]) then found[#found + 1] = names[i] end
  end
  lp('API ' .. string.format('%-8s', tag) .. ' ' .. #found .. '/' .. #names .. ' -> ' .. table.concat(found, ','))
end

local function dumpClasses()
  local out = {}
  for i = 1, #CAND_CLASS do
    local v = nil
    pcall(function() v = UE4[CAND_CLASS[i]] end)
    out[#out + 1] = CAND_CLASS[i] .. '=' .. ((v ~= nil) and 'Y' or 'N')
  end
  lp('CLS ' .. table.concat(out, ' '))
end

-- ============================================================
-- 状态快照
-- ============================================================
local function vecOf(v)
  if v == nil then return nil end
  local ok, x = pcall(function() return v.X end)
  if not ok or type(x) ~= 'number' then return nil end
  return { X = v.X, Y = v.Y, Z = v.Z }
end

local function vtTarget(pcm)
  local ok, t = pcall(function() return pcm.ViewTarget.Target end)
  if ok then return t end
  return nil
end

local function povLoc(pcm)
  if pcm == nil then return nil end
  local ok, l = pcall(function() return pcm.ViewTarget.POV.Location end)
  if ok and l then return vecOf(l) end
  return nil
end

local function povFov(pcm)
  if pcm == nil then return nil end
  local ok, f = pcall(function() return pcm.ViewTarget.POV.FOV end)
  if ok and type(f) == 'number' then return f end
  return nil
end

local function snap()
  local pc = getPC()
  if not pc then return nil end
  local pcm = getPCM(pc)
  local pawn = getPawn()
  local vt = (pcm ~= nil) and vtTarget(pcm) or nil
  local pl = nil
  if pawn ~= nil then
    local ok, l = pcall(function() return pawn:K2_GetActorLocation() end)
    if ok then pl = vecOf(l) end
  end
  return {
    pc = pc, pcm = pcm, pawn = pawn,
    vt = vt, vtName = shortName(vt), vtPath = pathOf(vt),
    pov = povLoc(pcm), povFov = povFov(pcm),
    pawnLoc = pl,
  }
end

local function dist(a, b)
  if a == nil or b == nil then return nil end
  local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ============================================================
-- 阶梯：每一步 on() 执行，等 settle 帧后 verify() 判定
-- ============================================================
local ladder = {}
local cur = nil
local povBefore = nil

-- v2：只有这些步骤「成功」才证明画面已经归我们，才能进入观察期。
-- spawn 这类只是前置条件。
local TERMINAL = {
  debugcam = true, freewatch = true, universal = true,
  viewtarget = true, povfollow = true,
}

local function pushStep(t)
  if t.terminal == nil then t.terminal = (TERMINAL[t.id] == true) end
  ladder[#ladder + 1] = t
end

-- 模式切换类入口的判据：只认 ViewTarget 名字变化。
-- 「POV 突然跑到别处」不能算证据（可能是切到非法机位 / 世界原点），只记录不采信。
local function vtJudge(expect, base)
  local n = snap()
  if n == nil then return false, 'snap nil' end
  local d = dist(n.pov, base)
  local tail = 'vt=' .. n.vtName .. ' dist=' .. fmt(d, 0)
  local hit = false
  if type(expect) == 'table' then
    for i = 1, #expect do
      if n.vtName:find(expect[i], 1, true) then hit = true end
    end
  else
    hit = (n.vtName:find(expect, 1, true) ~= nil)
  end
  if hit then return true, tail end
  return false, tail
end

local function buildLadder(s)
  ladder = {}
  local pc, pcm, pawn = s.pc, s.pcm, s.pawn
  if pc == nil or pcm == nil then
    lp('LADDER aborted: pc/pcm nil')
    return
  end

  -- 1) 引擎调试相机：最便宜，一条命令，零副作用
  if hasMethod(pc, 'EnableDebugCamera') then
    pushStep({
      id = 'debugcam',
      on = function()
        local ok, err = pcall(function() pc:EnableDebugCamera() end)
        if not ok then return false, 'err ' .. tostring(err) end
        S.dbgOn = true
        return true, 'EnableDebugCamera() 已调用'
      end,
      verify = function()
        return vtJudge('DebugCamera', s.pawnLoc)
      end,
    })
  elseif hasMethod(pc, 'ToggleDebugCamera') then
    pushStep({
      id = 'debugcam',
      on = function()
        local ok, err = pcall(function() pc:ToggleDebugCamera() end)
        if not ok then return false, 'err ' .. tostring(err) end
        S.dbgOn = true
        return true, 'ToggleDebugCamera() 已调用'
      end,
      verify = function()
        return vtJudge('DebugCamera', s.pawnLoc)
      end,
    })
  else
    note('debugcam', false, '两个入口都不存在')
  end

  -- 2) 游戏自带的自由观看模式（符号表里有 SetFreeWatchCameraMode + FreeWatchModeCameraActor）
  if hasMethod(pcm, 'SetFreeWatchCameraMode') then
    pushStep({
      id = 'freewatch',
      on = function()
        local ok, err = pcall(function() pcm:SetFreeWatchCameraMode(true) end)
        if not ok then return false, 'err ' .. tostring(err) end
        S.fwOn = true
        return true, 'SetFreeWatchCameraMode(true) 已调用'
      end,
      verify = function()
        return vtJudge({ 'FreeWatch', 'WatchCamera', 'WatchMode' }, s.pawnLoc)
      end,
    })
  else
    note('freewatch', false, 'pcm 上没有 SetFreeWatchCameraMode')
  end

  -- 3) 通用相机模式（UniversalCameraPlugin）
  if hasMethod(pcm, 'SetUniversalCameraMode') then
    pushStep({
      id = 'universal',
      on = function()
        local ok, err = pcall(function() pcm:SetUniversalCameraMode(true) end)
        if not ok then return false, 'err ' .. tostring(err) end
        S.ucOn = true
        return true, 'SetUniversalCameraMode(true) 已调用'
      end,
      verify = function()
        return vtJudge('Universal', s.pawnLoc)
      end,
    })
  else
    note('universal', false, 'pcm 上没有 SetUniversalCameraMode')
  end

  -- 4) 自己 spawn 一个 ACameraActor（最可控的路线）
  pushStep({
    id = 'spawn',
    on = function()
      local ins = getIns()
      local cls = nil
      pcall(function() cls = UE4.ACameraActor end)
      if cls == nil then pcall(function() cls = UE4.CameraActor end) end
      if cls == nil then return false, '取不到 ACameraActor 类' end
      if pawn == nil then return false, 'pawn nil' end

      local base = nil
      local ok0, l0 = pcall(function() return pawn:K2_GetActorLocation() end)
      if ok0 then base = vecOf(l0) end
      if base == nil then return false, 'pawn 位置读不到' end

      local fwd = { X = 1, Y = 0, Z = 0 }
      local okf, f = pcall(function() return pawn:GetActorForwardVector() end)
      if okf and f ~= nil then
        local fv = vecOf(f)
        if fv ~= nil then fwd = fv end
      end

      local loc = UE4.FVector(base.X + fwd.X * cfg.camFwd, base.Y + fwd.Y * cfg.camFwd, base.Z + cfg.camUp)
      local rot = nil
      local okr, r = pcall(UE4.UKismetMathLibrary.FindLookAtRotation, loc,
        UE4.FVector(base.X, base.Y, base.Z + 40.0))
      if okr and r ~= nil then rot = r else rot = UE4.FRotator(0, 0, 0) end

      local tr = nil
      local okt, t = pcall(UE4.UKismetMathLibrary.MakeTransform, loc, rot, UE4.FVector(1, 1, 1))
      if okt and t ~= nil then tr = t end
      if tr == nil then return false, 'MakeTransform 失败' end

      local a = nil
      local oks, actor = pcall(UE4.UGameplayStatics.BeginDeferredActorSpawnFromClass,
        ins, cls, tr, 1, nil)
      if oks and actor ~= nil then
        a = actor
        pcall(UE4.UGameplayStatics.FinishSpawningActor, a, tr)
      end
      if a == nil then return false, 'BeginDeferredActorSpawnFromClass 返回 nil' end

      S.camActor = a
      return true, 'spawned ' .. shortName(a)
    end,
    verify = function()
      local n = snap()
      if n == nil then return false, 'snap nil' end
      if S.camActor == nil then return false, 'camActor nil' end
      local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, S.camActor)
      if not ok or p == nil then return false, 'path nil' end
      return true, 'actor 存活 ' .. tostring(p) .. (n.vtPath == tostring(p) and ' （已是 ViewTarget）' or '')
    end,
  })

  -- 5) 把 ViewTarget 切到我们自己 spawn 的相机
  pushStep({
    id = 'viewtarget',
    on = function()
      if S.camActor == nil then return false, 'camActor nil（上一步没成）' end
      if not hasMethod(pc, 'SetViewTargetWithBlend') then return false, 'pc 上没有 SetViewTargetWithBlend' end
      local ok, err = pcall(function() pc:SetViewTargetWithBlend(S.camActor, 0.0, 0, 0.0, false) end)
      if not ok then return false, 'err ' .. tostring(err) end
      return true, '已切到 ' .. shortName(S.camActor)
    end,
    verify = function()
      local n = snap()
      if n == nil then return false, 'snap nil' end
      if S.camActor == nil then return false, 'camActor nil' end
      local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, S.camActor)
      if not ok or p == nil then return false, 'path nil' end
      if n.vtPath == tostring(p) then return true, 'ViewTarget=' .. n.vtName end
      return false, '仍是 ' .. n.vtName
    end,
  })

  -- 6) 挪动机位，验证引擎是不是真的在用我们的相机出画面
  pushStep({
    id = 'povfollow',
    on = function()
      if S.camActor == nil then return false, 'camActor nil' end
      local n = snap()
      if n == nil or n.pov == nil then return false, 'POV 读不到' end
      povBefore = n.pov
      local ok, l = pcall(function() return S.camActor:K2_GetActorLocation() end)
      if not ok then return false, '读位置失败' end
      local cur = vecOf(l)
      if cur == nil then return false, '位置 nil' end
      local ok2, err = pcall(function()
        S.camActor:K2_SetActorLocation(UE4.FVector(cur.X, cur.Y, cur.Z + cfg.probeMove), false, nil, false)
      end)
      if not ok2 then return false, 'err ' .. tostring(err) end
      return true, '抬高 ' .. fmt(cfg.probeMove, 0) .. 'cm'
    end,
    verify = function()
      local n = snap()
      if n == nil or n.pov == nil then return false, 'POV 读不到' end
      local dz = n.pov.Z - povBefore.Z
      if math.abs(dz - cfg.probeMove) < 80 then
        return true, 'POV 跟随 dz=' .. fmt(dz, 1)
      end
      return false, 'POV 没跟随 dz=' .. fmt(dz, 1)
    end,
  })
end

-- ============================================================
-- 附加探测：只在 ViewTarget 已经切到我们相机之后才跑
-- ============================================================
local function ownCompFov()
  if S.camComp == nil then return nil end
  local ok, v = pcall(function() return S.camComp.FieldOfView end)
  if ok and type(v) == 'number' then return v end
  return nil
end

local function buildExtras()
  ladder = {}

  -- 1) 往我们自己这颗相机写 FOV。相机不是游戏的了，理论上没人再改写它 ——
  --    这条决定「能不能做长焦 / 浅景深」这类拍照必备能力。
  pushStep({
    id = 'fovwrite',
    on = function()
      if S.camActor == nil then return false, 'no actor' end
      local comp = nil
      pcall(function() comp = S.camActor.CameraComponent end)
      if comp == nil then pcall(function() comp = S.camActor:GetCameraComponent() end) end
      if comp == nil then return false, '取不到 CameraComponent' end
      S.camComp = comp
      S.fovBefore = povFov(getPCM(getPC()))
      local okP, errP = pcall(function() comp.FieldOfView = 25.0 end)
      local okM, errM = pcall(function() comp:SetFieldOfView(25.0) end)
      return true, 'before=' .. fmt(S.fovBefore, 1) ..
                   ' prop=' .. (okP and 'ok' or ('err ' .. tostring(errP))) ..
                   ' method=' .. (okM and 'ok' or ('err ' .. tostring(errM)))
    end,
    verify = function()
      local now = povFov(getPCM(getPC()))
      local own = ownCompFov()
      pcall(function() if S.camComp ~= nil then S.camComp.FieldOfView = 75.0 end end)
      pcall(function() if S.camComp ~= nil then S.camComp:SetFieldOfView(75.0) end end)
      local hit = (now ~= nil and math.abs(now - 25.0) < 2.0)
      return hit, 'povFov=' .. fmt(now, 1) .. ' compFov=' .. fmt(own, 1)
    end,
  })

  -- 2) 时间膨胀：拍照定格的前提。用 0.02 而不是 0 —— 万一 UnLua Timer 受缩放影响，
  --    0.02 只是变慢（还能自己还原），0 会把自己冻死导致永远还原不了。
  pushStep({
    id = 'dilation',
    on = function()
      local ins = getIns()
      if ins == nil then return false, 'ins nil' end
      local ok, err = pcall(UE4.UGameplayStatics.SetGlobalTimeDilation, ins, 0.02)
      if not ok then return false, 'err ' .. tostring(err) end
      return true, 'set 0.02'
    end,
    verify = function()
      local ins = getIns()
      local v = nil
      pcall(function() v = UE4.UGameplayStatics.GetGlobalTimeDilation(ins) end)
      pcall(UE4.UGameplayStatics.SetGlobalTimeDilation, ins, 1.0)
      local back = nil
      pcall(function() back = UE4.UGameplayStatics.GetGlobalTimeDilation(ins) end)
      return (v ~= nil and v < 0.5), 'readback=' .. fmt(v, 4) .. ' restored=' .. fmt(back, 3)
    end,
  })
end

-- ============================================================
-- 执行器
-- ============================================================
local function scheduleNext()
  cur = table.remove(ladder, 1)
  if cur == nil then
    S.state = 'report'
    return
  end
  local ok, res, detail = pcall(cur.on)
  if not ok then
    note(cur.id, false, 'call err ' .. tostring(res))
    S.state = 'next'
    return
  end
  if not res then
    note(cur.id, false, tostring(detail or 'n/a'))
    S.state = 'next'
    return
  end
  note(cur.id, true, tostring(detail or 'ok'))
  S.state = 'settle'
  S.wait = cfg.settle
end

local function doVerify()
  if cur == nil or cur.verify == nil then
    S.state = 'next'
    return
  end
  local ok, res, detail = pcall(cur.verify)
  if ok and res then
    note(cur.id .. '/verify', true, tostring(detail or 'ok'))
    -- v2：只有 terminal 步骤才算「命中」。前置条件步骤（spawn）成功也继续往下走，
    -- 否则会像 v1 那样 ViewTarget 还没切就提前进入观察期。
    if cur.terminal then
      S.success = cur.id
      S.state = 'hold'
      S.wait = cfg.holdFrames
      lp('HIT entry=' .. cur.id .. ' -> 进入观察期 ' .. cfg.holdFrames .. ' 帧')
      return
    end
    S.state = 'next'
    return
  end
  note(cur.id .. '/verify', false, tostring((ok and detail) or ('verify err ' .. tostring(res))))
  S.state = 'next'
end

local function restore()
  local pc = getPC()
  if pc == nil then return end
  if S.fwOn and hasMethod(getPCM(pc), 'SetFreeWatchCameraMode') then
    pcall(function() getPCM(pc):SetFreeWatchCameraMode(false) end)
    S.fwOn = false
  end
  if S.ucOn and hasMethod(getPCM(pc), 'SetUniversalCameraMode') then
    pcall(function() getPCM(pc):SetUniversalCameraMode(false) end)
    S.ucOn = false
  end
  if S.dbgOn then
    if hasMethod(pc, 'DisableDebugCamera') then
      pcall(function() pc:DisableDebugCamera() end)
    elseif hasMethod(pc, 'ToggleDebugCamera') then
      pcall(function() pc:ToggleDebugCamera() end)
    end
    S.dbgOn = false
  end
  local pawn = getPawn()
  if pawn ~= nil and hasMethod(pc, 'SetViewTargetWithBlend') then
    pcall(function() pc:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
  end
  if S.camActor ~= nil then
    pcall(function() S.camActor:K2_DestroyActor() end)
    S.camActor = nil
  end
  -- 保险：无论中途出过什么岔子，时间缩放一定还原
  local ins = getIns()
  if ins ~= nil then
    pcall(UE4.UGameplayStatics.SetGlobalTimeDilation, ins, 1.0)
  end
  lp('RESTORE done, ViewTarget=' .. tostring((snap() or {}).vtName))
end

local function report()
  lp('================ REPORT ================')
  lp('frames=' .. S.frame .. ' success=' .. S.success ..
     ' vtReverts=' .. S.vtReverts .. ' reassert=' .. S.reassertTry .. ' stuck=' .. S.reassertStuck)
  for i = 1, #S.results do
    local r = S.results[i]
    lp(string.format('  %-22s %-4s %s', r.name, r.ok and 'OK' or 'FAIL', r.detail))
  end
  lp('========================================')
end

local function step()
  S.frame = S.frame + 1
  if S.done then return end

  if S.frame > cfg.hardLimit then
    lp('HARD LIMIT，强制收尾')
    S.state = 'report'
  end

  if S.state == 'wait' then
    local pc = getPC()
    if pc == nil or not isGameplay(pc) then
      S.stillCnt = 0
      S.armed = false
      return
    end
    local pawn = getPawn()
    local spd = 0
    if pawn ~= nil then
      local ok, v = pcall(function() return pawn:GetVelocity() end)
      if ok and v ~= nil then
        local vv = vecOf(v)
        if vv ~= nil then spd = math.sqrt(vv.X * vv.X + vv.Y * vv.Y + vv.Z * vv.Z) end
      end
    end
    if spd > cfg.stillSpeed then S.stillCnt = 0 else S.stillCnt = S.stillCnt + 1 end
    if S.stillCnt < cfg.stillFrames then return end
    if not S.armed then
      S.armed = true
      S.armedFrame = S.frame
      lp('ARMED 站定+gameplay 成立，' .. fmt(cfg.autoDelay, 0) .. 's 后开始普查（期间镜头会短暂异常，属正常）')
      return
    end
    if (S.frame - S.armedFrame) * cfg.pollInterval < cfg.autoDelay then return end

    local s = snap()
    if s == nil then return end
    lp('BASE vt=' .. s.vtName .. ' pov=' .. tostring(s.pov and s.pov.Z) ..
       ' pawnZ=' .. tostring(s.pawnLoc and s.pawnLoc.Z) .. ' fov=' .. fmt(s.povFov, 1))
    if not S.apiDumped then
      S.apiDumped = true
      dumpClasses()
      dumpApi('pc', s.pc, CAND_PC)
      dumpApi('pcm', s.pcm, CAND_PCM)
      dumpApi('cam', safeCam(s.pawn), CAND_CAM)
      dumpApi('pawn', s.pawn, CAND_PAWN)
    end
    buildLadder(s)
    S.state = 'next'
    return
  end

  if S.state == 'next' then
    scheduleNext()
    return
  end

  if S.state == 'settle' then
    S.wait = S.wait - 1
    if S.wait <= 0 then doVerify() end
    return
  end

  if S.state == 'hold' then
    local pc = getPC()
    local n = snap()
    if n ~= nil then
      local mine = (S.camActor ~= nil) and (n.vtPath == pathOf(S.camActor)) or false
      local dbg = n.vtName:find('DebugCamera', 1, true) ~= nil
      if not (mine or dbg) then
        S.vtReverts = S.vtReverts + 1
        if S.vtSeen ~= n.vtName then
          S.vtSeen = n.vtName
          lp('VT TAKEN BACK -> ' .. n.vtName)
        end
        -- v2：被抢回就立刻重挂 —— 这直接回答「能不能靠每帧重设赢回来」
        if S.camActor ~= nil and pc ~= nil and hasMethod(pc, 'SetViewTargetWithBlend') then
          local ok = pcall(function() pc:SetViewTargetWithBlend(S.camActor, 0.0, 0, 0.0, false) end)
          if ok then S.reassertTry = S.reassertTry + 1 end
        end
      elseif S.reassertTry > 0 then
        S.reassertStuck = S.reassertStuck + 1
      end
    end
    S.wait = S.wait - 1
    if S.wait <= 0 then
      lp('HOLD done reverts=' .. S.vtReverts .. ' reassert=' .. S.reassertTry ..
         ' stuck=' .. S.reassertStuck)
      if S.success == 'povfollow' or S.success == 'viewtarget' then
        buildExtras()
        S.state = 'next'
      else
        S.state = 'report'
      end
    end
    return
  end

  if S.state == 'report' then
    restore()
    report()
    S.done = true
    S.state = 'done'
    return
  end
end

local _started = false

local function loop()
  pcall(step)
  pcall(function() UE4.Timer.Add(cfg.pollInterval, loop) end)
end

FreeCamProbe.Start = function()
  if _started then return end
  local ok = pcall(function() UE4.Timer.Add(0.5, loop) end)
  if ok then
    _started = true
    lp('probe v2 online (loop started)')
  end
end

FreeCamProbe._ready = true
pcall(FreeCamProbe.Start)

pcall(function()
  EventSystem.On(Event.Logined, function()
    if not _started then pcall(FreeCamProbe.Start) end
  end)
end)

lp('probe v2 injected')

end -- FreeCamProbe guard
