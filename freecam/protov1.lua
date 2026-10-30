-- ========================================================
-- @File    : FreeCam.lua (v1)
-- @Brief   : 游戏场景自由相机（独立于 CamZoomMod）
--
-- 基于 probe v1/v2 的实机结论：
--   * 游戏自带自由相机入口全部调不到（EnableDebugCamera / SetFreeWatchCameraMode /
--     SetUniversalCameraMode 都不在反射表里），AFreeWatchModeCameraActor 类也不可见
--   * spawn ACameraActor + pc:SetViewTargetWithBlend 完全可行，且**没有任何争抢**
--     （v2 实机：150 帧观察期 reverts=0，不需要每帧重挂 ViewTarget）
--   * 往自己这颗相机写 FOV 直接反映到渲染 POV（解决了 camzoom 那边被回写的问题）
--   * SetGlobalTimeDilation 可用，且 **UnLua Timer 不受时间缩放影响**
--     → 世界定格时我们的控制循环照常满速运行，这正是拍照需要的
--
-- v1 功能：
--   F7      进入 / 退出自由相机（引擎从 POV 当前位置接管，不跳镜头）
--   鼠标     视角旋转（搬 ControlRotation 的增量，零延迟、不需要动嗅探器）
--   滚轮     沿视线前进 / 后退
--   F8      开关定格（时间膨胀 0.02）
--   退出/换图/嗅探器失联 → 自动还原
--
-- 输入通道沿用 CamZoomSniffer 的两个文件（嗅探器与本 MOD 无关，一直在后台跑）：
--   C:\ProgramData\CamZoomMod\fp_key.txt   "seq vk"   -- 键盘
--   C:\ProgramData\CamZoomMod\wheel.txt    "seq dir"  -- 滚轮
-- ========================================================

FreeCam = FreeCam or {}
if not FreeCam._ready then

-- CamZoomMod 共存开关：激活期间 camzoom 侧整体挂起（滚轮/HUD/F5 全部让位）。
-- 值是递增的帧号而不是 true —— camzoom 靠「数值 2s 不递增」判断本 MOD 主循环
-- 是否已死（死人开关），防止一个卡死的 freecam 把滚轮缩放永久带走。
_G.FreeCamActive = false

local LOG = '[FreeCam] '
local function lp(...) print(LOG, ...) end

local function fmt(v, nd)
  if v == nil then return 'nil' end
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%.' .. (nd or 1) .. 'f', v)
end

local cfg = {
  -- ⚠ 为什么是 6ms 而不是 20ms：UE 的 Timer 由世界 Tick 驱动，间隔只要小于帧长，
  -- 就会「每帧各触发一次」。50Hz（20ms）会和 60fps（16.7ms）错拍 —— 有时一帧一更新、
  -- 有时两帧才更新一次，转镜头就是一格一格的（实测用户反馈「像掉帧」，其实帧率没变）。
  -- 设成 6ms 后等价于按帧更新；dt 也不再用固定值，改由 GetRealTimeSeconds 实测。
  pollInterval = 0.006,
  fovMin       = 12.0,    -- 滚轮最窄（长焦）
  fovMax       = 110.0,   -- 滚轮最广
  fovStep      = 5.0,     -- 每格滚轮的 FOV 变化
  fovTau       = 0.10,    -- FOV 变化平滑时间常数（秒）
  -- ⚠ 按键必须落在 CamZoomSniffer 的白名单里（runtime/wheel_sniffer.py 的
  --   KEYS_OF_INTEREST = {V=86, B=66, F5=116}），不在白名单的键会被钩子静默丢弃。
  --   当前用 B 开关、V 定格（camzoom 未安装时这两个键都空闲）。
  --   F7/F8 已在源码里加入白名单，重编并重启嗅探器后可改回 F7/F8。
  toggleVK     = 66,    -- B
  freezeVK     = 86,    -- V
  ipcKeyPath   = 'C:\\ProgramData\\CamZoomMod\\fp_key.txt',
  ipcWheelPath = 'C:\\ProgramData\\CamZoomMod\\wheel.txt',
  ipcHeldPath  = 'C:\\ProgramData\\CamZoomMod\\keys_held.txt',  -- 持续按住的键（走位用）
  -- 走位速度 cm/s。注意**观感速度 ∝ 1/FOV**：长焦（FOV 小）会把同样的位移
  -- 放大好几倍，所以默认按 FOV 比例缩放（见 cfg.minSpeedScale）。
  moveSpeed    = 220.0,
  minSpeedScale = 0.12,  -- 长焦时最多减速到 12%，再慢就没法构图了
  speedVK      = nil,    -- 后续版本：加速键
  beatPath     = 'C:\\ProgramData\\CamZoomMod\\sniffer_beat.txt',
  keyFile      = nil,   -- 外部可通过 FreeCam.cfg 覆盖，方便无人值守测试
  wheelStep    = 45.0,  -- 【已停用】滚轮改为控制 FOV，前后走位交给 W/S
  dollyTau     = 0.12,  -- 平移平滑时间常数（秒）
  lookScale    = 1.0,   -- 视角灵敏度倍率
  -- 升降键：进入自由相机后会 DisableInput，游戏收不到 Q/E，所以可以放心用
  upVK         = 69,    -- E 上升
  downVK       = 81,    -- Q 下降
  altUpVK      = 90,    -- Z（备用，同样是后台队友技能键，被屏蔽后可用）
  altDownVK    = 88,    -- X
  helpRefresh  = 1.2,   -- 屏显操作提示的刷新间隔（秒）
  ipcBlockPath = 'C:\\ProgramData\\CamZoomMod\\block_vk.txt',
  ipcOverlayPath = 'C:\\ProgramData\\CamZoomMod\\freecam_on.txt',
  -- 操作键黑名单：进入自由相机后由嗅探器在低级钩子里**先记录后吞掉**。
  -- 所以这里列的键，我们照样能用（keys_held.txt / fp_key.txt），游戏收不到。
  --
  -- ⚠ 低级键盘钩子里左右修饰键的 vkCode 是带区分的：LCtrl=162 RCtrl=163
  --   LShift=160 RShift=161 LAlt=164 RAlt=165。写 17/16 挡不住左 Ctrl/左 Shift！
  -- ⚠ 必须排除：W/A/S/D 不在黑名单（走位轴要游戏收得到才有值；
  --   相机的 WASD 走位走 keys_held 通道，两路在 update() 里合并）、
  --   Esc(27)/Alt(164,165)/Win(91,92)（保命出口，Alt+Tab 别吞）。
  -- ⚠ cfg 里同名键只能有一个：曾因残留第二个 blockList='' 把名单覆盖，
  --   表现为屏蔽整体失效且日志只有 BLOCK 0，极难排查。
  blockList    = '1 2 10 32 17 16 160 161 162 163 81 69 90 88 82 70 71 67 86 66 84 89 85 73 79 80 72 74 75 76 77 78 188 190 191 49 50 51 52 53 54 55 56 57 48 87 65 83 68',
  hudRehide    = 12,    -- 每隔多少帧重新压一次 UI 透明度（游戏会自己改回来）
  freezeRate   = 0.02,  -- 定格时的时间缩放；用 0.02 不用 0，避免系统级组件异常
  beatTimeout  = 15.0,  -- 嗅探器心跳停这么久 → 自动退出，防止卡死在自由相机里出不来
  minGameplay  = 1,     -- 必须处于 gameplay 才允许进入
}

local S = {
  frame = 0,
  on = false,
  camActor = nil,
  camComp = nil,
  pawnStart = nil,
  diagFrames = 0,
  axisSeen = {},
  moved = 0,
  pos = nil,            -- {X,Y,Z}
  yaw = 0.0,
  pitch = 0.0,
  fov = nil,
  fovTarget = nil,
  lastT = nil,
  pendingDolly = 0.0,
  lastCtrl = nil,
  keySeq = -1,
  wheelSeq = -1,
  freeze = false,
  lastBeat = nil,
  beatAge = 0.0,
  usingKeyFile = false,
  errors = 0,
  apiLogged = false,
}

-- ============================================================
-- 取对象（与 CamZoomMod 同名逻辑，但互不影响）
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

local function pathOf(o)
  if o == nil then return 'nil' end
  local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, o)
  if ok and p then return tostring(p) end
  return '?'
end

local function isGameplay(pc)
  local s = pathOf(pc)
  return (s:find('GameController', 1, true) ~= nil) or (s:find('FightController', 1, true) ~= nil)
end

local function hasMethod(obj, name)
  if obj == nil then return false end
  local ok, v = pcall(function() return obj[name] end)
  if not ok then return false end
  return type(v) == 'function'
end

-- ============================================================
-- 输入：文件 IPC（CamZoomSniffer 提供）
-- ============================================================
local IO_OK = (type(io) == 'table' and type(io.open) == 'function')

local function readFile(p)
  if not IO_OK then return nil end
  local ok, f = pcall(io.open, p, 'r')
  if not ok or not f then return nil end
  local s = nil
  pcall(function() s = f:read('a') end)
  pcall(function() f:close() end)
  return s
end

local function nums(s)
  if s == nil then return nil end
  local out = {}
  for w in s:gmatch('%-?%d+%.?%d*') do out[#out + 1] = tonumber(w) end
  if #out == 0 then return nil end
  return out
end

-- 返回本帧新到期的 vk 列表
local function pollKey()
  local src = cfg.keyFile
  local s = nil
  if src ~= nil then
    s = readFile(src)
    if s ~= nil then S.usingKeyFile = true end
  end
  if s == nil then s = readFile(cfg.ipcKeyPath) end
  local n = nums(s)
  if n == nil or n[1] == nil then return nil end
  local seq = n[1]
  if S.keySeq < 0 then
    S.keySeq = seq
    return nil
  end
  if seq == S.keySeq then return nil end
  S.keySeq = seq
  local vks = {}
  for i = 2, #n do vks[#vks + 1] = n[i] end
  return vks
end

local function pollWheel()
  local s = readFile(cfg.ipcWheelPath)
  local n = nums(s)
  if n == nil or n[1] == nil then return 0 end
  local seq = n[1]
  if S.wheelSeq < 0 then S.wheelSeq = seq end
  if seq == S.wheelSeq then return 0 end
  local steps = seq - S.wheelSeq
  S.wheelSeq = seq
  local dir = n[2] or 0
  return dir * steps
end

-- 引擎内输入轴：角色的 WASD 轴本来就存在（否则人物走不了），
-- SetIgnoreMoveInput 只是不让角色吃它 —— 轴值本身可能仍然可读。
-- 候选名先全扫一遍，谁有值就用谁，并把结果打进日志（AXIS name=value）。
local AXIS_CANDIDATES = { 'MoveForward', 'MoveBackward', 'MoveRight', 'MoveLeft',
                          'Strafe', 'Forward', 'Right', 'Up',
                          'MoveUp', 'Jump', 'Crouch', 'Sprint' }

local function axisVal(pc, name)
  if not hasMethod(pc, 'GetInputAxisValue') then return nil end
  local ok, v = pcall(function() return pc:GetInputAxisValue(name) end)
  if ok and type(v) == 'number' then return v end
  return nil
end

-- 当前按住的键集合（keys_held.txt 由嗅探器维护，内容 '0' 表示无）
local function readHeld()
  if not IO_OK then return nil end
  local s = readFile(cfg.ipcHeldPath)
  if s == nil then return nil end
  local set = {}
  for w in s:gmatch('%d+') do
    local v = tonumber(w)
    if v ~= nil and v ~= 0 then set[v] = true end
  end
  return set
end

-- 嗅探器心跳：失联太久自动退出，防止卡在自由相机里出不来
local function pollBeat(dt)
  local s = readFile(cfg.beatPath)
  local v = nil
  local n = nums(s)
  if n ~= nil then v = n[1] end
  if v ~= nil and S.lastBeat ~= v then
    S.lastBeat = v
    S.beatAge = 0.0
    return true
  end
  S.beatAge = S.beatAge + dt
  return false
end

-- ============================================================
-- UI：进相机时全隐藏 + 本 MOD 自己的屏显操作提示
-- ============================================================
local HUD = { list = {}, lastCollect = -999, toastT = 0 }

local function vec3(x, y, z) return { X = x, Y = y, Z = z } end

local function arrCount(a)
  local n
  pcall(function() n = a:Num() end)
  if type(n) == 'number' then return n end
  pcall(function() n = a.Num end)
  if type(n) == 'number' then return n end
  return nil
end

local function arrAt(a, i)
  local v
  pcall(function() v = a:Get(i) end)
  if v == nil then pcall(function() v = a[i] end) end
  return v
end

-- ⚠ PrintString 在发行版里被 UE_BUILD_SHIPPING 宏裁掉，是**空操作**，
--    实机已证实不显示。屏显改用嗅探器的置顶窗口（见 cfg.ipcOverlayPath）。
--    这里只保留日志，方便排查。
local function toast(text, dur)
  lp('TOAST', (tostring(text):gsub('\n', ' / ')))
end

-- 让嗅探器吞掉游戏输入（block_vk.txt，嗅探器每秒读一次）
-- 嗅探器置顶提示窗口的开关（1=显示 0=隐藏）
local function writeOverlay(s)
  if not IO_OK then return end
  local ok, f = pcall(io.open, cfg.ipcOverlayPath, 'w')
  if ok and f then
    pcall(function() f:write(s) end)
    pcall(function() f:close() end)
  end
end

local function writeBlock(s)
  if not IO_OK then
    lp('BLOCK io 不可用')
    return
  end
  local ok, f = pcall(io.open, cfg.ipcBlockPath, 'w')
  if ok and f then
    pcall(function() f:write(s) end)
    pcall(function() f:close() end)
    lp('BLOCK ' .. s)
  else
    lp('BLOCK 写失败')
  end
end

-- 游戏内 UMG 隐藏/还原（v6 的教训：脚本删代码时把这三个函数误删了，
-- 导致主循环每 12 帧报 nil 调用、MOD 整个死掉、看起来像"所有问题都回归"。
-- 现在只隐藏根 widget 的透明度，不用 Collapse —— 游戏会自己改回来）
local HELP = '【自由相机】鼠标 转视角 | W/S 前后 | A/D 左右\n' ..
             'E 上升 / Q 下降 | 滚轮 FOV\n' ..
             'V 定格（时间冻结）| B 退出'

local function hudCollect()
  local pc = getPC()
  if pc == nil then return 0 end
  local cls = nil
  pcall(function() cls = UE4.UUserWidget end)
  if cls == nil then return 0 end
  local arr = nil
  pcall(function() arr = UE4.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(pc, nil, cls) end)
  local n = arrCount(arr)
  if n == nil or n <= 0 then return 0 end
  local added = 0
  for i = 1, math.min(n, 24) do
    local w = arrAt(arr, i)
    if w ~= nil then
      local key = pathOf(w)
      local seen = false
      for j = 1, #HUD.list do
        if HUD.list[j].key == key then seen = true break end
      end
      if not seen then
        local op = nil
        pcall(function() op = w:GetRenderOpacity() end)
        HUD.list[#HUD.list + 1] = {
          key = key, w = w,
          prev = (type(op) == 'number') and op or 1.0,
        }
        added = added + 1
      end
    end
  end
  return added
end

local function hudHide()
  for i = 1, #HUD.list do
    local it = HUD.list[i]
    pcall(function() it.w:SetRenderOpacity(0) end)
  end
end

local function hudRestore()
  for i = 1, #HUD.list do
    local it = HUD.list[i]
    pcall(function() it.w:SetRenderOpacity(it.prev) end)
  end
  HUD.list = {}
end

-- ============================================================
-- 输入能力普查（一次性，只打日志）
--   目的：判断这个 MOD 能不能脱离外部嗅探器（.exe / .py）分发。
--   现在所有按键/滚轮都来自嗅探器的 IPC 文件，没它连开关都按不了。
--   要独立，必须证明下面至少一条成立：
--     a) pc:IsInputKeyDown(FKey) 能用（要能构造 FKey）
--     b) EventSystem 的 PCKeyboardEvent 派发完整的按键事件
-- ============================================================
local INP = { done = false, n = 0 }

local function probeInput()
  if INP.done then return end
  local pc = getPC()
  if pc == nil then return end
  INP.done = true

  local names = { 'IsInputKeyDown', 'WasInputKeyJustPressed', 'WasInputKeyJustReleased',
                  'GetInputMouseDelta', 'GetMousePosition', 'GetInputAxisValue' }
  local out = {}
  for i = 1, #names do
    out[#out + 1] = names[i] .. (hasMethod(pc, names[i]) and '=Y' or '=N')
  end
  lp('INPAPI ' .. table.concat(out, ' '))

  local fk = nil
  pcall(function() fk = UE4.FKey end)
  lp('INPAPI FKey=' .. tostring(fk ~= nil))
  if hasMethod(pc, 'IsInputKeyDown') and fk ~= nil then
    local okc, key = pcall(function() return fk('B') end)
    if okc and key ~= nil then
      local okd, v = pcall(function() return pc:IsInputKeyDown(key) end)
      lp('INPAPI IsInputKeyDown(B)=' .. tostring(v) .. ' ok=' .. tostring(okd))
    else
      lp('INPAPI FKey 构造失败 ' .. tostring(key))
    end
  end
end

pcall(function()
  EventSystem.On(Event.PCKeyboardEvent, function(...)
    if INP.n >= 20 then return end
    INP.n = INP.n + 1
    local t = {}
    local cnt = select('#', ...)
    for i = 1, cnt do t[#t + 1] = tostring((select(i, ...))) end
    lp('KBD n=' .. INP.n .. ' args=' .. table.concat(t, ','))
  end)
end)

-- ============================================================
-- 进入 / 退出
-- ============================================================
local function camCompOf(a)
  local c = nil
  pcall(function() c = a.CameraComponent end)
  if c == nil then pcall(function() c = a:GetCameraComponent() end) end
  return c
end

local function applyAspect(comp)
  if comp == nil then
    lp('ASPECT no CameraComponent')
    return
  end
  local okOff, errOff = pcall(function() comp.bConstrainAspectRatio = false end)
  local ins = getIns()
  local vw, vh = nil, nil
  if ins ~= nil then
    local okv, w, h = pcall(UE4.UGameplayStatics.GetViewportSize, ins)
    if okv and h and h > 0 then vw, vh = w, h end
  end
  if vw ~= nil then
    pcall(function() comp.AspectRatio = vw / vh end)
    lp('ASPECT viewport=' .. fmt(vw, 0) .. 'x' .. fmt(vh, 0) ..
       ' ratio=' .. fmt(vw / vh, 3) .. ' constrainOff=' .. tostring(okOff) ..
       (okOff and '' or (' err ' .. tostring(errOff))))
  else
    lp('ASPECT constrainOff=' .. tostring(okOff) ..
       (okOff and '' or (' err ' .. tostring(errOff))) .. ' (viewport 未读到)')
  end
end
local function logApiOnce(pc, pcm)
  if S.apiLogged then return end
  S.apiLogged = true
  local names = { 'SetViewTargetWithBlend', 'GetViewTarget', 'SetIgnoreMoveInput',
                  'SetIgnoreLookInput', 'GetControlRotation' }
  local out = {}
  for i = 1, #names do
    out[#out + 1] = names[i] .. (hasMethod(pc, names[i]) and '=Y' or '=N')
  end
  lp('API pc ' .. table.concat(out, ' '))
  local pn = { 'StopAllCameraShakes', 'GetCameraLocation', 'GetCameraRotation' }
  local po = {}
  for i = 1, #pn do
    po[#po + 1] = pn[i] .. (hasMethod(pcm, pn[i]) and '=Y' or '=N')
  end
  lp('API pcm ' .. table.concat(po, ' '))
end

local function enter()
  local pc = getPC()
  if pc == nil then return false, 'no pc' end
  local pcm = getPCM(pc)
  if pcm == nil then return false, 'no pcm' end
  local ins = getIns()

  local cls = nil
  pcall(function() cls = UE4.ACameraActor end)
  if cls == nil then return false, 'no ACameraActor class' end

  -- 从当前 POV 接管，避免镜头跳位
  local start = { X = 0, Y = 0, Z = 0 }
  local yaw, pitch = 0, 0
  local fov0 = 90.0
  pcall(function()
    local pov = pcm.ViewTarget.POV
    start.X = pov.Location.X; start.Y = pov.Location.Y; start.Z = pov.Location.Z
    yaw = pov.Rotation.Yaw; pitch = pov.Rotation.Pitch
    if type(pov.FOV) == 'number' and pov.FOV > 1 then fov0 = pov.FOV end
  end)

  local rl = UE4.FVector(start.X, start.Y, start.Z)
  local rr = UE4.UKismetMathLibrary.MakeRotator(0, pitch, yaw)
  local tr = UE4.UKismetMathLibrary.MakeTransform(rl, rr, UE4.FVector(1, 1, 1))

  local a = nil
  local oks, actor = pcall(UE4.UGameplayStatics.BeginDeferredActorSpawnFromClass, ins, cls, tr, 1, nil)
  if oks and actor ~= nil then
    a = actor
    pcall(UE4.UGameplayStatics.FinishSpawningActor, a, tr)
  end
  if a == nil then return false, 'spawn failed' end

  if not hasMethod(pc, 'SetViewTargetWithBlend') then
    pcall(function() a:K2_DestroyActor() end)
    return false, 'no SetViewTargetWithBlend'
  end
  local okv, errv = pcall(function() pc:SetViewTargetWithBlend(a, 0.0, 0, 0.0, false) end)
  if not okv then
    pcall(function() a:K2_DestroyActor() end)
    return false, 'SetViewTarget err ' .. tostring(errv)
  end

  S.camActor = a
  S.camComp = camCompOf(a)
  -- ⚠ 带鱼屏黑边：ACameraActor 默认 bConstrainAspectRatio=true（按 16:9 锁比例），
  -- 21:9 屏上就会左右留出黑边。关掉它，让引擎按实际视口比例出画面。
  applyAspect(S.camComp)
  S.pos = start
  S.yaw = yaw
  S.pitch = pitch
  S.pendingDolly = 0
  S.lastCtrl = nil
  S.fov = fov0
  S.fovTarget = fov0
  S.fovBase = fov0
  S.lastT = nil
  S.diagFrames = 250      -- 进入后前 250 帧（5s）扫描哪些输入轴真的有值
  S.axisSeen = {}
  S.moved = 0
  S.on = true
  _G.FreeCamActive = S.frame
  -- 滚轮 seq 对齐：freecam 关闭期间的滚轮事件属于 camzoom 的缩放输入（它一直在
  -- 消费同一个 wheel.txt），不对齐的话进入瞬间会把积压格数一次性补成 FOV 跳变。
  do
    local ws = readFile(cfg.ipcWheelPath)
    local wn = nums(ws)
    if wn ~= nil and wn[1] ~= nil then S.wheelSeq = wn[1] end
  end

  -- 只保留 SetIgnoreMoveInput：它挡住角色的位移消费，但轴值照样能读（走位靠它）。
  -- ⚠ 不要再调 pawn:DisableInput —— 它内部会 Pop 掉 pawn 的 InputComponent，
  -- 实测之后角色反而跟着 WASD 一起动了（v6 的回归）。没有收益，只有副作用。
  pcall(function() pc:SetIgnoreMoveInput(true) end)
  local pawn = getPawn()
  if pawn ~= nil then
    local okL, l = pcall(function() return pawn:K2_GetActorLocation() end)
    if okL and l ~= nil then S.pawnStart = vec3(l.X, l.Y, l.Z) end
  end
  lp('INPUT SetIgnoreMoveInput=true')

  -- 屏蔽输入（默认关闭，见 cfg.blockList 注释）
  if cfg.blockList ~= nil and cfg.blockList ~= '' then
    writeBlock(cfg.blockList)
    S.blockHeartbeat = 0      -- 死人开关：靠持续重写维持，停写即自动解禁
  else
    writeBlock('0')
  end
  -- 隐藏 UI（用透明度不用 Collapse —— Collapse 会被游戏自己的显示逻辑改回来）
  local added = hudCollect()
  hudHide()
  lp('UI hidden widgets=' .. #HUD.list .. ' (new=' .. added .. ')')

  -- 操作提示：走嗅探器的置顶小窗口（外部窗口，不会进截图 —— 用户明确要求）
  writeOverlay('1')
  HUD.toastT = 0
  toast(HELP, 2.0)

  lp('ENTER pos=' .. fmt(start.X, 0) .. ',' .. fmt(start.Y, 0) .. ',' .. fmt(start.Z, 0) ..
     ' yaw=' .. fmt(yaw, 1) .. ' pitch=' .. fmt(pitch, 1))
  return true, 'ok'
end

local function exit(reason)
  _G.FreeCamActive = false   -- 先恢复 camzoom：teardown 再怎么出错也不吞开关
  local pc = getPC()
  if pc ~= nil then
    pcall(function() pc:SetIgnoreMoveInput(false) end)
    local pawn = getPawn()
    if pawn ~= nil then
      if hasMethod(pc, 'SetViewTargetWithBlend') then
        pcall(function() pc:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
      end
    end
  end

  -- UI 还原（退出时一定要做，否则 HUD 会一直隐形）
  hudRestore()
  writeBlock('0')
  writeOverlay('0')
  toast('已退出自由相机', 1.2)
  if S.camActor ~= nil then
    pcall(function() S.camActor:K2_DestroyActor() end)
    S.camActor = nil
    S.camComp = nil
  end
  local ins = getIns()
  if ins ~= nil then
    pcall(UE4.UGameplayStatics.SetGlobalTimeDilation, ins, 1.0)
  end
  S.freeze = false
  S.on = false
  lp('EXIT ' .. tostring(reason or ''))
end

-- ============================================================
-- 每帧更新
-- ============================================================
local function angleDelta(newV, oldV)
  local d = newV - oldV
  while d > 180 do d = d - 360 end
  while d < -180 do d = d + 360 end
  return d
end

local function update(dt, pc, pcm)
  -- 0) FOV：滚轮给目标值，这里指数平滑逼近并写进我们自己这颗相机
  --    （相机是我们 spawn 的，游戏不会再回写 FOV —— 和 camzoom 那条路完全不同）
  if S.fov ~= nil and S.fovTarget ~= nil and S.camComp ~= nil then
    local d = S.fovTarget - S.fov
    if math.abs(d) > 0.05 then
      local k = 1.0 - math.exp(-dt / cfg.fovTau)
      S.fov = S.fov + d * k
      pcall(function() S.camComp.FieldOfView = S.fov end)
      pcall(function() S.camComp:SetFieldOfView(S.fov) end)
    end
  end

  -- 1) 视角：搬 ControlRotation 的增量
  local cr = nil
  if hasMethod(pc, 'GetControlRotation') then
    local ok, r = pcall(function() return pc:GetControlRotation() end)
    if ok and r ~= nil then
      local cur = { Yaw = r.Yaw, Pitch = r.Pitch }
      if S.lastCtrl ~= nil then
        S.yaw = S.yaw + angleDelta(cur.Yaw, S.lastCtrl.Yaw) * cfg.lookScale
        S.pitch = S.pitch + (cur.Pitch - S.lastCtrl.Pitch) * cfg.lookScale
      end
      S.lastCtrl = cur
    end
  end

  -- 2) 平移：滚轮累积后指数平滑（每 20ms 一次同步，视觉上是连续的）
  if S.pendingDolly ~= 0 then
    local k = 1.0 - math.exp(-dt / cfg.dollyTau)
    local step = S.pendingDolly * k
    S.pendingDolly = S.pendingDolly - step
    if math.abs(S.pendingDolly) < 0.05 then S.pendingDolly = 0 end

    local rot = UE4.UKismetMathLibrary.MakeRotator(0, S.pitch, S.yaw)
    local fwd = UE4.UKismetMathLibrary.GetForwardVector(rot)
    S.pos = { X = S.pos.X + fwd.X * step, Y = S.pos.Y + fwd.Y * step, Z = S.pos.Z + fwd.Z * step }
  end

  -- 3) 写回相机 Actor
  pcall(function()
    S.camActor:K2_SetActorLocation(UE4.FVector(S.pos.X, S.pos.Y, S.pos.Z), false, nil, false)
  end)
  pcall(function()
    S.camActor:K2_SetActorRotation(UE4.UKismetMathLibrary.MakeRotator(0, S.pitch, S.yaw), false)
  end)

  -- 4) 走位：两条通道并行，谁有值用谁。
  --    A) 引擎内输入轴（不需要嗅探器）—— 优先
  --    B) keys_held.txt（嗅探器 v2+ 才有，旧进程不会写这个文件）
  --    Q/E 升降只有 B 通道有，A 通道先记下来再说。
  local mf, mr = 0, 0
  if S.diagFrames > 0 then
    S.diagFrames = S.diagFrames - 1
    for i = 1, #AXIS_CANDIDATES do
      local nm = AXIS_CANDIDATES[i]
      local v = axisVal(pc, nm)
      if v ~= nil and math.abs(v) > 0.01 and S.axisSeen[nm] == nil then
        S.axisSeen[nm] = v
        lp('AXIS ' .. nm .. '=' .. fmt(v, 3))
      end
    end
  end
  local vF = axisVal(pc, 'MoveForward')
  local vR = axisVal(pc, 'MoveRight')
  if vF == nil then vF = axisVal(pc, 'Forward') end
  if vR == nil then vR = axisVal(pc, 'Strafe') end
  if vF ~= nil then mf = vF end
  if vR ~= nil then mr = vR end

  local held = readHeld()
  if held ~= nil then
    if held[87] then mf = mf + 1 end
    if held[83] then mf = mf - 1 end
    if held[68] then mr = mr + 1 end
    if held[65] then mr = mr - 1 end
  end

  -- 升降：优先引擎轴（若有），否则走 Z/X 文件通道
  local vu = 0
  local axisUp = axisVal(pc, 'MoveUp')
  if axisUp ~= nil then vu = axisUp end

  if mf ~= 0 or mr ~= 0 or vu ~= 0 or
     (held ~= nil and (held[cfg.upVK] or held[cfg.downVK] or
                       held[cfg.altUpVK] or held[cfg.altDownVK])) then
    local rot = UE4.UKismetMathLibrary.MakeRotator(0, S.pitch, S.yaw)
    local fwd, rgt = nil, nil
    local okF, f = pcall(UE4.UKismetMathLibrary.GetForwardVector, rot)
    if okF then fwd = f end
    local okR, r = pcall(UE4.UKismetMathLibrary.GetRightVector, rot)
    if okR then rgt = r end
    -- 按 FOV 缩放速度：长焦下同样的位移在画面上被放得很大，
    -- 不缩放的话「稍微动一下就飞出去」。
    local fovScale = 1.0
    if S.fov ~= nil and S.fovBase ~= nil and S.fov > 1 then
      fovScale = S.fov / S.fovBase
      if fovScale > 1.0 then fovScale = 1.0 end
      if fovScale < cfg.minSpeedScale then fovScale = cfg.minSpeedScale end
    end
    local spd = cfg.moveSpeed * fovScale * dt
    local dx, dy, dz = 0, 0, 0
    if fwd ~= nil and mf ~= 0 then
      dx = dx + fwd.X * mf * spd; dy = dy + fwd.Y * mf * spd; dz = dz + fwd.Z * mf * spd
    end
    if rgt ~= nil and mr ~= 0 then
      dx = dx + rgt.X * mr * spd; dy = dy + rgt.Y * mr * spd; dz = dz + rgt.Z * mr * spd
    end
    if vu ~= 0 then dz = dz + vu * spd end
    if held ~= nil then
      if held[cfg.upVK] or held[cfg.altUpVK] then dz = dz + spd end
      if held[cfg.downVK] or held[cfg.altDownVK] then dz = dz - spd end
    end
    if dx ~= 0 or dy ~= 0 or dz ~= 0 then
      S.pos = { X = S.pos.X + dx, Y = S.pos.Y + dy, Z = S.pos.Z + dz }
      S.moved = (S.moved or 0) + 1
      if S.moved <= 3 then lp('MOVE mf=' .. fmt(mf, 2) .. ' mr=' .. fmt(mr, 2)) end
    end
  end

  -- 5) 压住 shake，否则开枪/受击会抖（v2 已确认 StopAllCameraShakes 存在）
  if S.frame % 5 == 0 then
    pcall(function() pcm:StopAllCameraShakes(true) end)
  end

  -- 黑名单心跳：每 ~0.5s 重写一次文件，维持嗅探器那边的 3s 死人开关。
  -- 我们不写，它就在 3 秒后自动解禁 —— 游戏崩了也不会把输入锁死。
  if cfg.blockList ~= nil and cfg.blockList ~= '' then
    S.blockHeartbeat = (S.blockHeartbeat or 0) + dt
    if S.blockHeartbeat >= 0.5 then
      S.blockHeartbeat = 0
      writeBlock(cfg.blockList)
    end
  end

  -- 取证：自由相机期间角色到底有没有被 WASD 推动。
  -- 之前全靠「感觉」，改成硬数据：角色离进入时的位置超过 40cm 就记一行。
  if S.frame % 30 == 0 and S.pawnStart ~= nil then
    local pw = getPawn()
    if pw ~= nil then
      local okL, l = pcall(function() return pw:K2_GetActorLocation() end)
      if okL and l ~= nil then
        local d = math.sqrt((l.X - S.pawnStart.X) ^ 2 + (l.Y - S.pawnStart.Y) ^ 2 +
                            (l.Z - S.pawnStart.Z) ^ 2)
        if d > 40 then
          lp('PAWN MOVED d=' .. fmt(d, 0) .. 'cm （角色被推动了，SetIgnoreMoveInput 没兜住）')
          S.pawnStart = vec3(l.X, l.Y, l.Z)
        end
      end
    end
  end

  -- 6) UI 维护：游戏自己的逻辑会周期性把透明度改回来，所以要反复压；
  --    另外延迟创建的 widget（伤害数字、提示条）也要补进来。
  if S.frame % cfg.hudRehide == 0 then
    if S.frame - HUD.lastCollect > 100 then
      HUD.lastCollect = S.frame
      local added = hudCollect()
      if added > 0 then lp('UI +' .. added .. ' widgets=' .. #HUD.list) end
    end
    hudHide()
  end

  -- 7) ViewTarget 守护：被抢回就重挂，但**连续被抢就立刻让位退出**。
  --    游戏在剧情/切人/过场等状态会每帧强制收归视点，跟它抢的结果就是画面
  --    抽搐 + FOV 来回跳（v9 实测）。让位 = 退出自由相机，用户过完这段再按 B 进来。
  if S.frame % 3 == 0 then
    local mine = false
    local ok, p = pcall(UE4.UKismetSystemLibrary.GetPathName, S.camActor)
    local nvt = nil
    pcall(function() nvt = pc:GetViewTarget() end)
    if ok and p ~= nil and nvt ~= nil then
      mine = (tostring(p) == pathOf(nvt))
    end
    if not mine then
      S.reclaimRun = (S.reclaimRun or 0) + 1
      if S.reclaimRun <= 2 then
        pcall(function() pc:SetViewTargetWithBlend(S.camActor, 0.0, 0, 0.0, false) end)
        lp('REASSERT ViewTarget 被抢回，已重挂')
      end
      if S.reclaimRun >= 5 then
        exit('游戏连续抢回视点（剧情/过场？），自动让位')
        return
      end
    else
      S.reclaimRun = 0
    end
  end
end

-- ============================================================
-- 主循环
-- ============================================================
local function step()
  S.frame = S.frame + 1
  if S.on then _G.FreeCamActive = S.frame end   -- 共存开关心跳（camzoom 死人开关依据）
  -- dt 用真实经过时间：主循环现在是按帧跑的，写死 0.02 会让位移/FOV 速度随帧率变化；
  -- GetRealTimeSeconds 不受时间缩放影响，定格时相机也能正常动。
  local dt = cfg.pollInterval
  local ins = getIns()
  if ins ~= nil then
    local okt, t = pcall(UE4.UGameplayStatics.GetRealTimeSeconds, ins)
    if okt and type(t) == 'number' then
      if S.lastT ~= nil then
        local d2 = t - S.lastT
        if d2 > 0 and d2 < 0.25 then dt = d2 end
      end
      S.lastT = t
    end
  end
  local pc = getPC()
  if pc == nil then return end
  local pcm = getPCM(pc)
  if pcm == nil then return end
  logApiOnce(pc, pcm)
  if S.frame > 150 then probeInput() end

  local vks = pollKey()
  if vks ~= nil then
    for i = 1, #vks do
      if vks[i] == cfg.toggleVK then
        if S.on then exit('toggle off')
        elseif isGameplay(pc) then
          local ok, why = enter()
          if not ok then lp('ENTER FAILED ' .. tostring(why)) end
        else
          lp('IGNORED 非 gameplay 场景')
        end
      elseif vks[i] == cfg.freezeVK and S.on then
        local ins = getIns()
        if ins ~= nil then
          S.freeze = not S.freeze
          local v = S.freeze and cfg.freezeRate or 1.0
          pcall(UE4.UGameplayStatics.SetGlobalTimeDilation, ins, v)
          lp('FREEZE ' .. (S.freeze and 'ON' or 'OFF'))
        end
      end
    end
  end

  if pollBeat(dt) == false and S.beatAge > cfg.beatTimeout and S.on then
    exit('sniffer lost')
    return
  end

  if S.on then
    if not isGameplay(pc) then
      exit('left gameplay')
      return
    end
    local w = pollWheel()
    if w ~= 0 and S.fovTarget ~= nil then
      -- 上滚 = 收窄（长焦），下滚 = 放宽
      local nv = S.fovTarget - w * cfg.fovStep
      if nv < cfg.fovMin then nv = cfg.fovMin end
      if nv > cfg.fovMax then nv = cfg.fovMax end
      S.fovTarget = nv
      lp('FOV ' .. fmt(nv, 1))
    end
    local ok, err = pcall(update, dt, pc, pcm)
    if not ok then
      S.errors = S.errors + 1
      if S.errors <= 5 then lp('UPDATE ERR ' .. tostring(err)) end
      if S.errors > 20 then exit('too many update errors') end
    end
  end
end

local _started = false

local function loop()
  pcall(step)
  pcall(function() UE4.Timer.Add(cfg.pollInterval, loop) end)
end

FreeCam.cfg = cfg
FreeCam.state = S
FreeCam.Start = function()
  if _started then return end
  local ok = pcall(function() UE4.Timer.Add(0.5, loop) end)
  if ok then
    _started = true
    lp('freecam v15 online  B=开关自由相机  V=定格  鼠标=转视角  WASD=走位  滚轮=FOV')
  end
end

FreeCam._ready = true
pcall(FreeCam.Start)

pcall(function()
  EventSystem.On(Event.Logined, function()
    if not _started then pcall(FreeCam.Start) end
  end)
end)

-- 与 camzoom 同款兜底：两个 MOD 现在共存，若 Logined 订阅被互相覆盖，
-- 第一条滚轮/按键事件到来时再拉起主循环（Start 内部有 _started 防重入）。
pcall(function()
  EventSystem.On(Event.PCKeyboardEvent, function()
    if not _started then pcall(FreeCam.Start) end
  end)
end)

lp('freecam v15 injected (FreeCamActive flag on)')

end -- FreeCam guard
