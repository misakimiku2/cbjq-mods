-- ========================================================
-- @File    : CamZoomMod.lua (v69)
--
-- v69（2026-10-29）：P5 第一人称贴脸（独立模式，不动 z 倍率体系）
--   需求（用户原话 + 三问答复）：保留角色本体、只把相机贴到脸上；用单独
--   按键切换；FP 模式下要有自己的「第一人称开镜瞄准」。
--   设计要点：
--   a) **独立状态机 fpMode**，不复用 z 倍率 —— 进入时记下 fpFromMag（当前
--      施加量）与 zTarget，mag 在 fpFadeIn 内从 fpFromMag 平滑混到 fpWant，
--      退出时按同一套混回，之后交还原有 applyZoom 路径（mag 连续，无跳变）。
--   b) 目标位 = 沿本地 X 把相机推到「距角色中心 fpBack cm」。基准距离取
--      fpBaseD = dist + appliedMag（游戏 boom 贡献的近似），进入时锁一次 ——
--      角色体型、开镜机位不同都能自适配，不用硬编码 baseDist。
--   c) 眼位高度：若拿得到 CapsuleHalfHeight，进入时把相机世界 Z 对齐到
--      「脚底 + 86% 身高」的眼位（relLoc.Z 本地 Z = 世界上，可直写），
--      拿不到就退回 cfg.fpUp 手调值。
--   d) FP 模式下**绕开**：居中积分（强制 lat=0）、FX 让位、旋转护盾、
--      距离钳制（minCamDist=90 会顶住贴脸，必须跳过）、游戏接管让行。
--      改用一个轻量安全网：写入值被游戏连续改写超过 takeoverCm*3 达 3 帧
--      → 释放 12 帧（防 v43 式互殴），之后重新占据。
--   e) 开镜（cfg.fpAimMode）：'hold' = 保持贴脸并换 fpBackAim 的更近目标；
--      'release' = 交还游戏原版开镜。hold 时延迟 fpAimLockFrames 帧再锁
--      一次 fpBaseD（躲开游戏开镜机位的动画段）。
--   f) HUD：FP 下强制隐藏（复用 P4 的 HH），开镜时自动还回准星。
--   g) 输入：V 键经 runtime/wheel_sniffer.py 的键盘钩子写 fp_key.txt
--      （"seq vk"），Lua 侧轮询。FP 下滚轮任意方向 = 退出 FP。
--   诊断（HB）：fp= 混合量 / fpA= 开镜 / fpD= 锁定的游戏 boom 距离 /
--   fpW= 写入 mag / fpZ= 垂直偏移 / eyeZ= 目标眼位世界 Z。
--
-- v54（2026-10-29）：FOV 路线正式判死，收口为「纯位移推近」
--   五轮普查（v50~v53）已把所有入口试遍，结论见 HANDOFF 第四节 P2。
--   a) zMin 0.38 → 0.31：相机-角色距离 ~132cm → ~95cm，比原来再近约 1.35 倍；
--      用户实测「算是能接受」，距离档位到此为止。
--   b) zoomStep = 0：关掉光学变焦积累。FOV 拿不到，继续累积 zoomT 只会留下
--      无效状态和每帧无意义的 FOV 写入（rev 刷屏）。
--   c) zoomPullEnd = 0：那个 60cm 后拉是给 FOV 配的，已删。
--   applyFov 保留但永远走不到写入分支（amt 恒 0），日后若找到 FOV 入口，
--   把 zoomStep 改回 0.10 即可恢复全套光学变焦逻辑。
--
-- v53（2026-10-29）：FOV 普查收尾。v52 的晚帧实验结论 = UMG Tick 战斗中完全不跑
--   （LATEW start/end 的 tk 都是 0），Slate 晚帧这条路死。转向用户提供的新线索：
--   角色界面 / 拍照模式里 FOV 会变。若那是 Lua 干的，模块表里必有痕迹 ——
--   本版全量扫 package.loaded，输出三段：SCAN fov / SCAN mods / SCAN keys。
--   同时新增 PMW 行（每 2s 一条）：非 gameplay 状态也记录 fov 值，用来确认
--   拍照模式改的是不是同一个 cam.FieldOfView。
-- @Brief   : 第三人称滚轮缩放镜头（GTA 风格）
--
-- v52（2026-10-29）：FOV 路线判死后的转向 + 最后一次晚帧实验
--   实机证据（v50/v51 三轮普查）：cam.FieldOfView 写入**能落地**（立即回读=45），
--   但 0.35s 内必被游戏改回 75，HB 的 rev 每帧 +1 → 游戏的相机更新发生在我们
--   的 Timer 之后，逐帧重写永远晚一步。而 SetFOVOverride 在 exe 符号表里有，
--   却不在 cam（CameraComponent）/ pcm（GamePlayerCameraManager_C）上；
--   pcm:GetCameraInstance() 无参返回 nil，带 ACameraActor 类只返回普通相机 actor。
--   → FOV 唯一还可能生效的时机是「比游戏相机更新更晚的那一帧尾部」。
--   本版两件事：
--   a) 【功能转向】zMin 0.38 → 0.31（相机-角色距离 ~132cm → ~97cm），把原来
--      "再往里滚"的余量做成**真实推近**（约 1.35 倍）——FOV 拿不到，只能靠距离。
--      zoomPullEnd 由 60 改 0：那个后拉是为 FOV 配的，FOV 不通时它就是
--      "往里滚反而往后退"的错误手感。距离钳制 minCamDist=90 仍是硬底线。
--   b) 【最后实验】给 package.loaded['UMG.Main.umg_main'].Tick 套壳（保留原函数），
--      在标定后约 6~9s 的 3 秒里从那里写 FOV=50°。若 UMG Tick 真在相机更新之后
--      执行，HB 的 fov= 会变成 50 → FOV 还能救；若 fov 恒 75 且 tk=0，说明这个
--      晚帧入口在战斗中根本不跑，FOV 彻底作废。
--   判读：HB 里新增 tk=（UMG Tick 计数）和 fov=（读回值）；LATEW start/end 各一行。
--
-- v50（2026-10-29）：P2 光学变焦 —— 拉到最近后继续往里滚 → FOV 收窄
--   需求（用户原话）：镜头拉到最近时，再滚轮往里滚，就把 FOV 调小一些。
--   实现：z 走到 zMin 后不再往下走，多出来的滚轮量转成 zoomT（0..1），
--   FOV 从 baseFov(75) 收窄到 zoomFovEnd(45)，同时相机后退 zoomPullEnd(60cm)
--   —— 只收 FOV 不收距离的话相机几乎贴在角色模型上，广角贴脸畸变极重；
--   退 60cm 换来「长焦近景」的透视压缩，主体反而略变大（约 1.3 倍）。
--   两个量都可单独调：不想要后拉就把 zoomPullEnd 设 0。
--   ⚠ 关键坑：开镜判定的阈值不能再用固定 baseFov−12 —— 我们自己收窄到 45
--   会被自己的判定当成「开镜」并整段让行。改为阈值随变焦一起下移
--   min(目标FOV−6, baseFov−12)，变焦量 0 时行为与 v49 完全一致。
--   ⚠ FOV 写入位置：v26 的 P2 探测证明「写一次 → 0.25s 内被游戏回写」，
--   但那次只写了一次。本版改为在 50Hz 主循环里逐帧重写（applyFov）——
--   Timer 循环是实机唯一稳定节拍的 Lua 入口（战斗中 UMG Tick 从不执行，
--   v48 的 LATE alive 计数为 0）。是否压得住游戏回写由实机验证，日志里
--   fov= / fovW= / rev= 三个字段直接判读：
--     rev≈0 且 fov 稳定在目标值 → 写住了；
--     rev 持续增长 → 游戏每帧在我们之后回写，这条路线作废（改走位移构图）。
--
-- v49（2026-10-29）：P1e 第五轮：回到 v47 让位机制 + 挤压门 + 冷却
--   v48 实测：距离伺服彻底发散 —— 30s 内 19 次 FX 触发（退出坡与游戏反应
--   互相触发）、hold 逐次棘轮上漂（157→340）、mag 冲到 700 上限、dist 在
--   114~351 乱跳（HB 实证），相机完全失控 = 用户报"坐标更乱"。根因：伺服
--   的「dist 对 magW 1:1 响应」假设在实机不成立 —— 游戏侧会对相机位置做出
--   反应/钳制，反馈回路发散。**伺服路线废弃，此结论不再重试。**
--   v49 = v47 的让位机制（滑回原版机位，用户实测正常起跑可接受）+ 两道修正：
--   a) 挤压门：碰撞把 boom 压短时（D = dist+appliedMag < baseDist−40）不让
--   位 —— 靠墙时碰撞释放与滑出同向叠加是 v47 靠墙闪光的根源，此时交给
--   距离钳制托底、释放按原版节奏进行（原版速度用户无感）；
--   b) 冷却：窗口结束后 1s 内不再触发，防退出坡与游戏反应连环触发。
--   v48 的钳制锁存修复保留（极限环修复有效）。
--
-- v48（2026-10-29）：P1e 第四轮：让位窗口改距离伺服 + 修钳制极限环
--   v47 实测反馈：a) 正常起跑"过渡到原版镜头再过渡回来"被用户评为微妙；
--   b) 靠墙起跑有一闪而过的剧烈晃动 —— 靠墙时游戏碰撞把 boom 压短，起跑
--   瞬间碰撞释放 + 前冲叠加，"滑回原版机位"与游戏自身的快速回弹同向叠加，
--   相机 0.1s 内被甩出 2m+。
--   a) FX 窗口从「滑回原版机位」改为「距离伺服」：检测到游戏引起的距离
--   突变后，把相机-人物距离焊住在事件前的值（fxDist=distPrev）。每帧用
--   D(boom贡献)=dist+appliedMag 反推游戏 boom 的动作，写入
--   magW = D+趋势(限幅±30) − fxDist 精确抵消；写入速率限 ±60cm/帧防伺服
--   自身抽搐（前冲被 2~3 帧平滑吸收）；顶棚 magW ≤ D−90 保证前冲瞬间
--   dist≥90 穿人仍不可能。演出期间缩放纹丝不动（正常起跑不再有任何
--   过渡），窗口结束走 0.45s 慢坡滑到游戏冲刺机位（合法动态）。
--   b) 距离钳制改「顶棚式 + 迟滞锁存」：v46 的 deficit 式在临界点有
--   极限环 —— dist 钳到 90 时条件(<90)不再成立、写满量恢复 → dist 弹回
--   49 → 再钳 → 49↔90 以 ~12Hz 振荡（贴墙站立即可见）。改为：dist<90
--   置锁存，锁存期间写入量顶到 D−90（保持 90），dist>105 才解锁。
-- v47（2026-10-29）：P1e 第三轮：FX 让位窗口（v46 钳制只防穿人，用户实测仍晃）
--   v46 实机数据：5 次前冲全部被钳住（dist 单帧 220→70，托在 90cm），但用户
--   仍报晃。原因：钳制只托底，游戏前冲的整套动态 —— 跟拍滞后把 dist 甩到
--   220（人物缩到 56%）→ 猛推 → 钳制托在 90 → 弹性回弹到 199 → 落回 124
--   —— 在拉近状态下依然是一串大幅度推拉，视觉上人物忽大忽小。
--   根治：FX 让位窗口 —— 检测到「游戏引起的距离突变」时，把缩放偏移在
--   ~5 帧(100ms)内平滑滑到 0，整个 FX 期间相机完全等于原版机位（原版同款
--   动态幅度 = 用户视为正常），窗口结束后走 aimBlend 从当前机位滑回缩放位
--   （出口用 0.45s 慢坡，长距离回归不跳）。
--   关键：gameD = 测得 Δdist + 自身写入量修正 —— 把我们自己滚动滚轮引起
--   的距离变化从信号里剥离，滚轮不会误触发；只有游戏演出（跟拍滞后
--   ~+19cm/帧、前冲 ~-150cm/帧、冲脸闪避）才会过阈值。触发只在拉近状态
--   （缩放位比原版近，mag>10）——拉远时前冲比原版还温和，无需让位。
--   门槛 15cm/20ms 之下的合法动态（走跑过渡、地形、冲刺 boom 拉长 ~4cm/帧、
--   急停回追）不触发；距离钳制保留作第二道保险（慢速收拢跌破 90 仍托底）。
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
  zMin = 0.31,
  zMax = 1.80,
  notchStep = 0.075,
  tau = 0.15,              -- 平滑时间常数（秒），越大越慢越柔
  pollInterval = 0.02,
  calMag = 60.0,
  maxOffset = 700.0,
  applyEps = 0.002,
  invertWheel = true,      -- 上滚 = 拉近（GTA 习惯）

  -- 光学变焦 / 长焦近景（P2 v50）：z 到 zMin 后，多余的滚轮量转成 FOV 收窄
  zoomStep = 0.0,          -- 【v54 关闭】光学变焦：FOV 写入被游戏相机图每帧覆盖，
                           -- 拿不到就不要再积累无效状态；改由 zMin=0.31 的真实推近代替
  zoomTau = 0.12,          -- 变焦平滑时间常数（秒）
  zoomFovEnd = 45.0,       -- 变焦满档时的 FOV（度）：baseFov 75 → 45
  zoomPullEnd = 0.0,      -- 变焦满档时相机后退量（cm）：抵消广角贴脸畸变，设 0 关掉
  centerStart = 0.96,      -- 从这个倍率开始把人物往中间拉
  centerFull = 0.74,       -- 居中量满档的倍率（原 portraitStart）

  -- P4 近景欣赏：拉近到人物居中时淡出 HUD
  hudHideOn = true,        -- 总开关
  hudHideZ = 0.80,         -- 倍率低于此值开始淡出（0.80 ≈ 2.5m）
  hudHideHyst = 0.06,      -- 迟滞：回到 hudHideZ+此值 以上才淡入
  hudFadeOut = 0.25,       -- 淡出时长（秒）
  hudFadeIn = 0.20,        -- 淡入时长（秒）
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
  clampHyst = 15.0,        -- 距离钳制解锁迟滞（cm）：dist 超过 90+此值才解锁
  fxDistRate = 15.0,       -- FX 触发门槛：游戏引起的 |Δdist|（cm/20ms，已剥离滚轮自变）
  fxFrames = 32,           -- FX 窗口帧数（20ms/帧 ≈ 0.64s），期间游戏动态持续则续期
  fxSqueezeD = 40.0,       -- 挤压门（cm）：D 低于 baseDist 此值时不让位（碰撞压短 boom）
  fxCoolFrames = 50,       -- FX 冷却帧数（1s）：窗口结束后防连环触发
  clampHyst = 15.0,        -- 距离钳制解锁迟滞（cm）：dist 超过 90+此值才解锁
  ringFrames = 15,         -- 记录器环形缓冲帧数（常驻，触发时倾倒=起跑前 300ms）
  traceSpdTrig = 120.0,    -- 轨迹触发速度（cm/s）：覆盖起跑加速段

  -- P5 第一人称贴脸（v69）：独立模式，与 z 倍率体系互不干扰
  fpOn = false,            -- 【v85 关闭】第一人称：游戏在相机贴近时会隐藏角色，
                           -- Lua 侧压不住（SetVisibility/SetHiddenInGame/SetOwnerNoSee
                           -- 全试过无效），看不到身体。代码保留，改 true 即可恢复。
  fpKeyVK = 86,            -- 主键 VK 码（V=86）；撞到游戏功能就换下面备选
  fpKeyAlt = { 116, 45 },  -- 备选：F5=116 / Insert=45，任一都能切（V 会被游戏占用）
  -- B 键：循环「视角距离」预设。第一人称看不到自己的身体是正常的（躯干在相机
  -- 正下方，平视时在视野外），想要平视也能看到角色就把值往正数调成过肩视角。
  fpBackKeyVK = 66,        -- B 键：循环视角档位
  -- 三个档位（back = 沿视线前后，正数=后退；lat = 侧向，正数=相机往右让）
  -- 档 1 是真第一人称：相机在眼前，看不到自己的身体（游戏在近距离会隐藏角色，
  --   Lua 层压不住 —— SetVisibility/SetHiddenInGame/SetOwnerNoSee 全试过无效）。
  -- 档 2/3 是近距离过肩：相机退到角色斜后方，能看到整个角色，视野不被后脑挡。
  fpViewPresets = {
    { back = -6.0,  lat = 0.0,  name = 'first-person' },
    { back = 70.0,  lat = 24.0, name = 'over-shoulder-near' },
    { back = 100.0, lat = 30.0, name = 'over-shoulder' },
  },
  fpViewIdx = 1,
  fpLatOffset = 0.0,       -- 由档位设置，当前侧向偏移
  fpKeyCool = 0.45,        -- 同一次按键的重复触发冷却（秒），防按住连发
  fpKeyPath = 'D:\\test\\cbjq-re\\runtime\\fp_key.txt',
  fpBack = -6.0,           -- 相机相对「眼睛位置」的位置（沿视线方向，正=后退/负=前移）：
                           --   -6 = 眼睛**前方** 6cm（不藏头也不会看到头骨，低头能看到身体）
                           --   0  = 正好在眼睛里（需要藏头，否则 near clip 穿帮）
                           --   8+ = 眼睛后方（过肩视角，能看到后脑）
  fpBackAim = -2.0,        -- 开镜时的同一量（更贴近瞄准线）
  fpUp = 0.0,              -- 已废弃（v74 起垂直量由误差迭代自动求解），保留字段兼容
  fpEyeRatio = 0.93,       -- 眼位高度：眼睛在「脚底→头顶」中的比例（**仅胶囊兜底时用**）
  -- 眼位实测（v80）：优先骨骼 / 包围盒，胶囊只在两者都不可用时兜底。
  -- 胶囊半高实测所有角色都是 88.0（游戏统一了碰撞胶囊），不代表真实身高。
  fpEyeBones = { 'Bip001-Head', 'Bip001 Head', 'Bip001-HeadNub', 'Head', 'head' },
  fpEyeDropCm = 8.0,       -- 头骨坐标 → 眼睛：往下挪多少 cm（头骨在颅中，眼在下方）
  fpTopToEyeCm = 12.0,     -- 包围盒顶部 → 眼睛：往下挪多少 cm（头顶到眼睛的距离）
  -- P5b 藏头：**默认关闭**。实测尘白不同角色骨骼差异极大（girl014b 有 33 个 head
  -- 骨骼，另一个角色只有 1 个 Bip001-Head），隐藏结果只剔头发不剔头骨（变光头），
  -- 而且开镜交还游戏时很容易忘记恢复。改用「相机放在眼睛前方」绕开这个问题，
  -- 不需要动任何骨骼，进/退第一人称都没有副作用。
  fpHideHead = false,
  fpHideBones = {
    'head', 'Head', 'HEAD', 'Bip01_Head', 'Bip01 Head', 'Bip01-head',
    'head_01', 'Head_01', 'j_head', 'J_Head', 'mixamorig:Head', 'head_jnt',
  },
  fpEyeMaxUp = 90.0,       -- 自动眼位修正上限（cm），防止读到脏值把相机甩上天
  fpLatMax = 90.0,         -- 横向修正上限（cm）：肩部视角下相机要往中线挪的余量
  fpFadeIn = 0.30,         -- 进入过渡时长（秒）
  fpFadeOut = 0.28,        -- 退出过渡时长（秒）
  fpAimMode = 'hold',      -- 'hold' = FP 下保持贴脸（第一人称开镜）；'release' = 交还游戏
  fpAimLockFrames = 10,    -- 开镜后延迟多少帧再重锁 fpBaseD（躲开开镜机位动画）
  fpSuspendFrames = 12,    -- 安全网：被游戏连续改写时释放的帧数
  fpDevTol = 20.0,         -- 距离守卫：实测贴脸距离偏离 fpBack 超过此值（cm）才校正
  fpDevFrames = 5,         -- 且需连续偏离这么多帧（0.1s），避免 bob/摆动误触发
  fpDevCoolFrames = 40,    -- 校正冷却（0.8s）：只在偏差持续时一次性重锁，不做逐帧伺服
  fpMagTau = 0.20,         -- 历史字段（v78 起位置由误差迭代驱动，不再用渐变）
  fpGain = 0.45,           -- 误差迭代增益：每帧吃掉误差的比例（越大越快越硬）
  fpStepMax = 80.0,        -- 单帧最大修正量（cm），防大误差时跳变
  fpErrEps = 1.0,          -- 误差小于此值停止修正（cm）

  -- v71 开镜让行自愈：游戏某些功能（比如某个视角切换键）会把 FOV 压到低位，
  -- 与「开镜」在数值上无法区分 → 模组整段让行 → 滚轮完全失灵，只有再开一次
  -- 镜才能恢复。判定条件：让行已持续 aimStuckFrames 帧，且期间用户滚过轮
  -- （说明他在尝试缩放，不是专心瞄准）→ 判为误判，强制恢复一次。
  aimStuckFrames = 200,    -- 4s（50Hz）：真开镜时没人会滚轮，缩短到 4s 让误判恢复得快
  aimStuckWheel = 2,       -- 期间至少滚过 2 下才触发自愈

  -- v86 dither 抑制（实验）：第三人称仰视/贴墙时角色会被游戏做成点阵半透明
  -- （引擎的相机遮挡淡出）。可见性 API 无效（v83 验证），这里改试**材质标量参数**：
  -- 把常见的 dither/fade 参数拉到 1.0 = 完全不透明。参数名靠猜，首次会把
  -- 材质名与尝试列表打进日志，命中与否看画面。
  ditherFix = true,
  ditherParams = {
    'Dither', 'DitherAlpha', 'DitherScale', 'DitherFade',
    'FadeAlpha', 'CameraFade', 'NearFade', 'ClipFade',
  },

  ipcPath = 'D:\\test\\cbjq-re\\runtime\\wheel.txt',
  beatPath = 'D:\\test\\cbjq-re\\runtime\\sniffer_beat.txt',
  wheelAxisName = 'MouseScrollWheel',
}

local Z = {
  z = 1.0, zTarget = 1.0,
  zoomT = 0.0,            -- 光学变焦目标（0..1，P2 v50）
  zoomS = 0.0,            -- 光学变焦当前值（指数平滑逼近 zoomT）
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
  fovWritten = nil,       -- 上一帧写进 camera.FieldOfView 的值（nil = 当前不持有 FOV 写入权）
  fovRev = 0,             -- 读回值与写入值不符的帧数（诊断：游戏是否在我们之后回写）
  lastWarn = 0,

  -- P5 第一人称（v69）
  fp = 0.0,               -- 当前混合量（0=第三人称完全体，1=贴脸完全体）
  fpTarget = 0.0,         -- 目标混合量
  fpFromMag = nil,        -- 进入/退出时记下的施加量（混合起点）
  fpSavedZ = nil,         -- 进入 FP 前的 zTarget，退出时还原
  fpBaseD = nil,          -- 锁定的「游戏 boom 距离」（dist + appliedMag）
  fpEyeZ = nil,           -- 目标眼位的世界 Z（能算出来才有）
  fpZOff = 0.0,           -- 垂直写入量（relLoc.Z）
  fpAimNow = false,
  fpAimFrames = 0,
  fpKeySeq = -1,
  fpKeyChecked = false,
  fpSuspendUntil = 0,
  fpRewrote = 0,
  fpLog = 0,
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
-- FOV 能力普查（v51 取证用，一次性；正式功能不依赖它的结果）
-- 现象：v50 逐帧写 pawn.Camera.FieldOfView 完全无效 —— HB 里 fov= 恒 75、
-- fovW=45、rev 每帧 +1，说明游戏每帧都在我们之后把该属性写回默认值。
-- 结论方向：不能"抢着写这个属性"，必须改游戏侧的 FOV 源。
-- 本普查把 CameraBlueprint 模块符号表里能想到的入口逐个试一遍：
--   每次只写一个入口 → 立刻回读（判断写有没有落地）→ 0.35s 后再回读
--   （判断有没有被游戏当帧回写）→ 还原。
-- 判读：held=true 的那个入口就是我们要的。
-- ============================================================
local function propOf(obj, name)
  if obj == nil then return nil end
  local ok, v = pcall(function() return obj[name] end)
  if ok then return v end
  return nil
end

-- ============================================================
-- P4：近景欣赏模式 —— 拉近到人物居中时淡出 HUD（v63 实装）
--   控件名来自 v60/v61 的控件树普查（umg_fight_pc_C）：
--     Center             准星容器（内含 AimNode→Cross→CrossHair / Dot / Reload / Disarm）
--     AimCrossHairOverlay 准星叠加层
--     PlayerSelect       右上角角色 + 技能栏
--     LevelTask          左上角任务标识（战斗中）
--     LevelTaskOpenWorld 左上角任务标识（开放世界）
--     TaskBtn            任务按钮
--     HitEffect          命中特效层
--     HP                 左下角血条/弹药块
--   伤害数字是独立 widget（umg_fight_Damage_C），从 GetAllWidgetsOfClass 的数组里抓。
--   淡出用 SetRenderOpacity（不 Collapse：Collapse 会被游戏自己的显示逻辑反复改回来）
-- ============================================================
local function uobjClass(obj)
  local n
  pcall(function() n = obj:GetClass():GetName() end)
  return n
end

-- UnLua: GetAllWidgetsOfClass 的出参是 userdata 容器，Num() 取长度，1 基索引
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

local HUD_NAMES = { 'Center', 'AimCrossHairOverlay', 'PlayerSelect', 'LevelTask',
                    'LevelTaskOpenWorld', 'TaskBtn', 'HitEffect', 'HP',
                    -- v65 补：控制树坐标 dump 定位出来的两组漏网
                    'uw_fight_monster_tips',        -- 任务/敌人方向指示（星星、箭头）
                    'Special_Signa',                -- 底部中央弧形技能状态条
                    'SkillPanel',
                    'uw_fight_skill_aim' }  -- v66 追加：角色技能状态牌（待验证）                  -- 右下角技能键（Ctrl/E/Q）

local HH = {
  alpha = 1.0,
  applied = -1,
  found = false,
  widgets = {},
  dmg = nil,
  want = false,
  lastTry = -999,
  tries = 0,
}

local function hhCollect(w, map, depth, budget)
  if w == nil or depth > 6 or budget.n >= 400 then return end
  budget.n = budget.n + 1
  local nm
  pcall(function() nm = w:GetName() end)
  if type(nm) == 'string' and map[nm] == nil then map[nm] = w end
  local c
  pcall(function() c = w:GetChildrenCount() end)
  if type(c) == 'number' and c > 0 then
    for i = 0, math.min(c - 1, 30) do
      local ch
      pcall(function() ch = w:GetChildAt(i) end)
      if ch ~= nil then hhCollect(ch, map, depth + 1, budget) end
    end
  end
end

local function hhFind()
  local pc = getPC()
  if not pc then return false, 'no pc' end
  local cls
  pcall(function() cls = UE4.UUserWidget end)
  local arr
  if not pcall(function() arr = UE4.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(pc, nil, cls) end) then
    return false, 'call failed'
  end
  if arr == nil then return false, 'nil arr' end
  local n = arrCount(arr)
  if not n or n <= 0 then return false, 'n=' .. tostring(n) end
  local target, dmg
  for i = 1, math.min(n, 12) do
    local w = arrAt(arr, i)
    local c = uobjClass(w)
    if c ~= nil then
      if string.find(c, 'fight_pc') then target = w end
      if string.find(c, 'Damage') then dmg = w end
    end
  end
  if target == nil then return false, 'no fight_pc (n=' .. n .. ')' end
  local tree, root
  pcall(function() tree = target.WidgetTree end)
  if tree ~= nil then pcall(function() root = tree.RootWidget end) end
  if root == nil then return false, 'no root' end
  local map = {}
  hhCollect(root, map, 0, { n = 0 })
  HH.widgets = map
  HH.dmg = dmg
  HH.target = target        -- v67：整棵 HUD 的根，直接调它的透明度等于「隐藏所有 UI」
  local got = {}
  for _, nm in ipairs(HUD_NAMES) do
    if map[nm] ~= nil then got[#got + 1] = nm end
  end
  HH.found = true
  lp('HUD found=', #got, 'missing=', #HUD_NAMES - #got, 'list=', table.concat(got, ','),
     'dmg=', tostring(dmg ~= nil))
  return true
end

-- v67：整根 HUD 一起改透明度（UMG 的 RenderOpacity 沿树相乘，父级 0 则全部不可见）。
-- 逐个控件的兜底保留 —— 万一某些部件被 AddToViewport 挂到别处，仍然能盖住。
local function hhApply(a)
  if HH.target ~= nil then pcall(function() HH.target:SetRenderOpacity(a) end) end
  if HH.dmg ~= nil then pcall(function() HH.dmg:SetRenderOpacity(a) end) end
  for _, nm in ipairs(HUD_NAMES) do
    local w = HH.widgets[nm]
    if w ~= nil then pcall(function() w:SetRenderOpacity(a) end) end
  end
end

-- wantHide: 目标是否隐藏；由 step() 每帧算（近景 + 非开镜）
local function hhUpdate(wantHide)
  if not HH.found then
    if Z.frame - HH.lastTry < 50 then return end
    HH.lastTry = Z.frame
    HH.tries = HH.tries + 1
    local ok, why = hhFind()
    if not ok then
      if HH.tries <= 6 then lp('HUD wait', HH.tries, why or '') end
      return
    end
    HH.alpha = wantHide and 0.0 or 1.0
    hhApply(HH.alpha)
    HH.applied = HH.alpha
    return
  end

  -- 定时校验缓存：切人 / 切场景后控件会被重建，失效就重新找
  if Z.frame - (HH.lastCheck or 0) > 150 then
    HH.lastCheck = Z.frame
    local bad = false
    if HH.target ~= nil then
      local tn
      pcall(function() tn = HH.target:GetName() end)
      if tn == nil then bad = true end
    end
    for _, nm in ipairs(HUD_NAMES) do
      local w = HH.widgets[nm]
      if w ~= nil then
        local n2
        pcall(function() n2 = w:GetName() end)
        if n2 == nil then bad = true end
      end
    end
    if bad then
      HH.found = false
      HH.widgets = {}
      HH.dmg = nil
      HH.lastTry = -999
      lp('HUD cache stale -> refind')
    end
  end

  local targetA = wantHide and 0.0 or 1.0
  if math.abs(HH.alpha - targetA) < 0.004 then
    HH.alpha = targetA
  else
    local dur = wantHide and cfg.hudFadeOut or cfg.hudFadeIn
    local stepA = cfg.pollInterval / dur
    if HH.alpha < targetA then HH.alpha = math.min(targetA, HH.alpha + stepA)
    else HH.alpha = math.max(targetA, HH.alpha - stepA) end
  end
  if math.abs(HH.applied - HH.alpha) > 0.004 then
    HH.applied = HH.alpha
    hhApply(HH.alpha)
  end
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
  -- v73 关键修复：首次读取**不能把事件吞掉**。
  -- 旧写法 `if Z.ipcSeq < 0 then Z.ipcSeq = seq; return 0 end` 会把「进游戏
  -- 之前累积的全部滚轮」当成基准丢掉。实测用户滚了 44 格、一次 delta 都没
  -- 产生（HB 里 z 恒 1.00、src=none），直接表现为「滚轮完全失效」。
  -- 现在首次读取退一格当基准 → 当帧就产生 steps=1，滚一格就有反应。
  if Z.ipcSeq < 0 then
    Z.ipcSeq = seq - 1
    lp('IPC first read seq=', seq, 'dir=', dir, '(treat as 1 notch)')
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
  if num == 13 then Z.notch = (Z.notch or 0) + 1 end
  -- v70 探测：把前 24 个不同的键码打进日志。如果 V(86) 会在这里出现，说明
  -- 游戏自己就在派发键盘事件 —— 那以后 FP 切换可以彻底不依赖外部嗅探器。
  Z.keySeen = Z.keySeen or {}
  if num > 0 and not Z.keySeen[num] and (Z.keyN or 0) < 24 then
    Z.keySeen[num] = true
    Z.keyN = (Z.keyN or 0) + 1
    lp('KEYEV num=', num, 'n=', Z.keyN, 'total=', Z.notchTotal)
  end
end

-- 嗅探器心跳（v70）：sniffer 每 2s 把递增计数写进 sniffer_beat.txt。
-- 文件连续 3 次采样（约 6s）不变 = 进程没了 —— 这正是「滚轮和 V 键同时失灵」
-- 的唯一常见原因，直接在屏幕上提示，省得又去翻日志。
local function pollBeat()
  if Z.frame % 100 ~= 0 then return end
  if type(io) ~= 'table' or type(io.open) ~= 'function' then return end
  local v = nil
  local ok, f = pcall(io.open, cfg.beatPath, 'r')
  if ok and f then
    local s = nil
    pcall(function() s = f:read('a') end)
    pcall(function() f:close() end)
    v = tonumber(s)
  end
  if v ~= nil and Z.beatVal ~= v then
    Z.beatVal = v
    Z.beatStuck = 0
    return
  end
  -- 走到这里 = 文件缺失（嗅探器从没运行过）或计数没变（进程被收掉了）
  Z.beatStuck = (Z.beatStuck or 0) + 1
  if Z.beatStuck == 3 then
    lp('SNIFFER dead or missing, beat=', tostring(v))
    if Z.frame >= (Z.beatWarnUntil or 0) then
      Z.beatWarnUntil = Z.frame + 3000
      hud('输入嗅探器未运行：滚轮/第一人称都不可用', 5.0)
    end
  end
end

-- ============================================================
-- 键盘 IPC（P5）：sniffer 的 WH_KEYBOARD_LL 钩子把「游戏前台时按下的键」
-- 写成 "seq vk" 到 fp_key.txt。返回值 = VK 码（同一 seq 只消费一次）。
-- 与 pollIPC 同一套序号去重逻辑，但状态字段完全独立。
-- ============================================================
local function pollFPKey()
  if not cfg.fpOn then return nil end
  if not Z.fpKeyChecked then
    Z.fpKeyChecked = true
    lp('FPKEY io=', tostring(type(io) == 'table' and type(io.open) == 'function'))
  end
  if type(io) ~= 'table' or type(io.open) ~= 'function' then return nil end
  local ok, f = pcall(io.open, cfg.fpKeyPath, 'r')
  if not ok or not f then return nil end
  local content = nil
  pcall(function() content = f:read('a') end)
  pcall(function() f:close() end)
  if not content or content == '' then return nil end
  local seqs, vks = content:match('(%d+)%s+(%d+)')
  if not seqs then return nil end
  local seq, vk = tonumber(seqs), tonumber(vks)
  if not seq or not vk then return nil end
  -- v73 同款修复：首次读取不吞真按键。sniffer 启动时写的是 "1 0"（占位），
  -- 真按键会带非零 vk —— 只丢占位，不丢按键。
  -- 旧写法直接把首次读到的 vk 一起丢掉，实测用户就按了一次 B，
  -- 恰好吃在首次读取上 → fp_key.txt 明明写着 "2 66"，游戏里毫无反应。
  if Z.fpKeySeq < 0 then
    Z.fpKeySeq = seq
    lp('FPKEY first read seq=', seq, 'vk=', vk)
    if vk <= 0 then return nil end
    return vk
  end
  if seq == Z.fpKeySeq then return nil end
  Z.fpKeySeq = seq
  if vk <= 0 then return nil end
  return vk
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
-- dither 抑制（v86）：角色被墙/相机挤近时，游戏把角色材质做成点阵半透明
-- （相机遮挡淡出）。可见性 API 压不住（v83 已证），改试材质标量参数 ——
-- 把常见 dither/fade 参数拉到 1.0 = 完全不透明。参数名靠猜，首次 dump 材质名。
local function applyDitherFix(pawn)
  if not cfg.ditherFix then return end
  local okM, mesh = pcall(function() return pawn.Mesh end)
  if not okM or not mesh then return end
  for i = 1, #cfg.ditherParams do
    pcall(function() mesh:SetScalarParameterValueOnMaterials(cfg.ditherParams[i], 1.0) end)
  end
  if not Z.ditherLogged then
    Z.ditherLogged = true
    local okN, n = pcall(function() return mesh:GetNumMaterials() end)
    lp('DITHER numMaterials=', tostring(okN and n or 'nil'))
    if okN and type(n) == 'number' then
      for i = 0, math.min(n - 1, 8) do
        local ok1, mat = pcall(function() return mesh:GetMaterial(i) end)
        local nm = '?'
        if ok1 and mat then pcall(function() nm = mat:GetName() end) end
        lp('DITHER mat', i, tostring(nm))
      end
    end
    lp('DITHER params tried=', table.concat(cfg.ditherParams, ','))
  end
end

-- 目标位移：正值 = 相机后拉，负值 = 推近（最终都要乘 coef 换算成本地轴符号）
-- v50：删掉 v26 的「FOV 可用 → 改走后拉构图」分支。fovWorks() 原本是探测 FOV
-- 能不能写住的开关，现在 FOV 由变焦主动持有 —— 那个分支会让 targetOffset 在
-- 开始写 FOV 的瞬间跳到 portraitPull(150)，位移必须永远纯线性。
local function targetOffset(z)
  return (z - 1.0) * Z.baseDist * (Z.coef or 1.0)
end

-- 光学变焦（v50 P2）：FOV 从 baseFov 收到 zoomFovEnd，amt=0 时释放写入权
-- （游戏自己管 FOV 时的一切行为照旧：开镜 75→35、冲刺 75→79.9）
local function applyFov(cam, amt)
  local baseF = Z.baseFov or 75.0
  if amt <= 0.004 then
    if Z.fovWritten ~= nil then
      pcall(function() cam.FieldOfView = baseF end)
      Z.fovWritten = nil
      lp('FOV restore base=', fmt(baseF, 1), 'rev=', Z.fovRev or 0)
    end
    return
  end
  local fov = baseF + (cfg.zoomFovEnd - baseF) * amt
  if pcall(function() cam.FieldOfView = fov end) then
    Z.fovWritten = fov
    local bucket = math.floor(amt * 20 + 0.5)
    if bucket ~= Z.lastFovBucket then
      Z.lastFovBucket = bucket
      lp('FOV set=', fmt(fov, 1), 'amt=', fmt(amt, 2), 'rev=', Z.fovRev or 0)
    end
  end
end

-- ============================================================
-- P5 第一人称贴脸（v69）
-- ============================================================
-- 设计原则：**不碰 z 倍率体系**。FP 只是给 mag 加一条并行目标，
-- 最终写入量按混合系数 fp 在「正常路径的 mag」和「FP 目标 mag」之间插值：
--   mag = targetOffset(z) + (fpBaseMag − targetOffset(z)) * fp
-- 这样进入/退出都是天然连续的（fp 从 0→1 或 1→0），不需要额外记录起点，
-- 退出后也不需要任何还原动作 —— fp=0 时公式退化成原来的 targetOffset(z)。

-- 胶囊半高（眼睛位置的唯一可靠来源）。拿不到就退回 cfg.fpUp 手调。
local function capsuleHalfH(pawn)
  local ok, h = pcall(function() return pawn.CapsuleComponent.CapsuleHalfHeight end)
  if ok and type(h) == 'number' and h > 20 and h < 400 then return h end
  ok, h = pcall(function() return pawn:GetSimpleCollisionHalfHeight() end)
  if ok and type(h) == 'number' and h > 20 and h < 400 then return h end
  return nil
end

-- 骨骼名探测：尘白用的是自定义命名（实测 `girl014b_bone_Head_02_002` 这种），
-- 角色 ID 还会出现在前缀里，所以**不能靠候选名猜**。这里直接扫出所有名字含
-- head 的骨骼存进 Z.fpHeadBoneList，藏头时整批隐藏（头部含头发/表情等一堆子骨骼）。
-- 每个 mesh 各探一次（切人/换皮肤后前缀会变）。
local function fpProbeBones(pawn)
  local okM, mesh = pcall(function() return pawn.Mesh end)
  if not okM or not mesh then return nil end
  if Z.fpBoneProbedMesh == mesh and Z.fpHeadBoneList then
    return Z.fpHeadBoneList
  end
  Z.fpBoneProbedMesh = mesh
  Z.fpHeadBoneList = {}
  local okN, n = pcall(function() return mesh:GetNumBones() end)
  if not okN or type(n) ~= 'number' or n <= 0 then
    lp('FP probe: GetNumBones 不可用 =', tostring(n))
    return nil
  end
  local hits = 0
  for i = 0, math.min(n - 1, 800) do
    local ok2, nm = pcall(function() return mesh:GetBoneName(i) end)
    if ok2 and nm ~= nil then
      local s = tostring(nm)
      local low = string.lower(s)
      if string.find(low, 'head', 1, true) then
        hits = hits + 1
        Z.fpHeadBoneList[#Z.fpHeadBoneList + 1] = s
        if hits <= 4 then lp('FP headbone idx=', i, 'name=', s) end
      end
    end
  end
  lp('FP probe numBones=', n, 'head bones=', hits)
  return Z.fpHeadBoneList
end

-- 藏头 / 恢复（P5b）：只隐藏头部骨骼，身体、手臂、武器全部保留。
-- UE4 的标准第一人称做法是 HideBoneByName —— 它会把该骨骼影响的所有三角形
-- 一起剔除（含头发/面部材质），不需要碰材质槽。
-- 退出时用 UnHideBoneByName 还原，切人后要对新 pawn 重新施加。
local function fpHeadApply(pawn, hide)
  if not cfg.fpHideHead then return end
  -- 恢复：不需要 pawn，按「当时藏的那个 mesh」还原（切过人也不会漏）
  if not hide then
    local target = Z.fpHiddenMesh
    if target and Z.fpHiddenHead then
      for i = 1, #Z.fpHiddenHead do
        pcall(function() target:UnHideBoneByName(Z.fpHiddenHead[i]) end)
      end
      lp('FP head restored, n=', #Z.fpHiddenHead)
    end
    Z.fpHiddenHead = nil
    Z.fpHiddenMesh = nil
    return
  end
  if not pawn then return end
  local okM, mesh = pcall(function() return pawn.Mesh end)
  if not okM or not mesh then
    lp('FP head: pawn.Mesh 不可用')
    return
  end
  if Z.fpHiddenHead and Z.fpHiddenMesh == mesh then return end   -- 已对这个 mesh 施加过
  if Z.fpHiddenHead then fpHeadApply(nil, false) end              -- 换人了：先还原旧的
  -- 优先用探测到的真实骨骼名（尘白是 `girl014b_bone_Head_02_002` 这种自定义命名，
  -- 候选名一个都匹配不上）；探测失败才退回候选列表。
  local list = fpProbeBones(pawn)
  if not list or #list == 0 then list = cfg.fpHideBones end
  Z.fpHiddenHead = {}
  Z.fpHiddenMesh = mesh
  for i = 1, #list do
    local nm = list[i]
    local ok = pcall(function() mesh:HideBoneByName(nm, 0) end)
    if ok then
      Z.fpHiddenHead[#Z.fpHiddenHead + 1] = nm
    end
  end
  lp('FP head hidden, n=', #Z.fpHiddenHead, 'first=', tostring(Z.fpHiddenHead[1]))
end

-- 眼位高度（v80：按角色实测，不再用胶囊半高）
--
-- ⚠ 胶囊半高**不能**用来算眼位：实测所有角色 `CapsuleHalfHeight` 都是 88.0
-- （游戏为了碰撞/移动手感统一了胶囊），完全不代表真实身高。拿它算出来
-- 所有角色眼位一样高，矮个子的相机飘在头顶上、高个子的在胸口。
--
-- 三级回退，返回 眼位世界 Z + 来源标记（日志里能看出用的哪一级）：
--   1) 头部骨骼的世界坐标（最准，直接就是头骨）—— GetSocketLocation 对骨骼
--      也可能有效（取决于骨架是否注册了同名 socket），失败返回原点；
--   2) mesh 包围盒顶部减去头高（动画姿态会影响，但量级正确）；
--   3) 胶囊半高 × fpEyeRatio（仅兜底，各角色会一样）。
local function fpEyeHeight(pawn, pl)
  if not pl then return nil, 'none' end
  local okM, mesh = pcall(function() return pawn.Mesh end)
  if okM and mesh then
    -- 1) 骨骼位置
    for i = 1, #cfg.fpEyeBones do
      local nm = cfg.fpEyeBones[i]
      local ok, loc = pcall(function() return mesh:GetSocketLocation(nm) end)
      if ok and loc and type(loc.Z) == 'number' and math.abs(loc.Z) > 1.0 then
        local dz = loc.Z - pl.Z
        local dx = math.abs((loc.X or 0) - pl.X)
        local dy = math.abs((loc.Y or 0) - pl.Y)
        -- 合理性检查：头骨应该在胶囊中心上方 10~130cm、水平方向基本对齐。
        -- GetSocketLocation 对不存在的 socket 返回 (0,0,0)，若世界坐标恰好接近
        -- 原点就会误判，所以水平距离也要卡。
        if dz > 10.0 and dz < 130.0 and dx < 60.0 and dy < 60.0 then
          return loc.Z - cfg.fpEyeDropCm, 'bone:' .. nm
        end
      end
    end
    -- 2) mesh 包围盒顶部
    local ok2, b = pcall(function() return mesh.Bounds end)
    if ok2 and b and b.Origin and b.BoxExtent and type(b.BoxExtent.Z) == 'number' then
      local top = b.Origin.Z + b.BoxExtent.Z
      local dz = top - pl.Z
      if dz > 30.0 and dz < 130.0 then
        return top - cfg.fpTopToEyeCm, 'bounds'
      end
    end
  end
  -- 3) 胶囊兜底
  local half = capsuleHalfH(pawn) or 88.0
  return pl.Z + half * (2.0 * cfg.fpEyeRatio - 1.0), 'capsule'
end


-- FP 位置驱动（v78：**误差迭代**，不再反推挂点）
--
-- 走过的弯路（不要再回头）：
--   v69 线性近似 Δmag = Δdist*coef → 相机越过角色后方向自激，镜头一直往前跑；
--   v74 反推挂点 G 再几何投影 → relLoc 的本地轴是**父组件坐标系**，与相机
--       forward 差约 12.6°（标定 dot=0.976），用 forward 反推 292cm 偏移的
--       误差可达 60cm。实测写入 mag=292 时相机距角色仍有 68cm（应为 8cm），
--       而且算法自己认为"已到位"（newX≈relNow），于是再也不修正。
--
-- 现在：目标点是**固定的世界坐标**，每帧拿**实测相机位置**算误差，再把误差
-- 按相机三轴分解成写入增量（增益 fpGain、单帧限幅 fpStepMax）。轴不准也没关系
-- —— 误差用的是实测值，方向大致对就能收敛；残差在下一帧继续被吃掉。
-- 这是位置收敛，不是「反推游戏 boom 动作」那种伺服（后者才会与游戏耦合发散）。
local function fpComputeTarget(pawn, cam)
  local pl = Z.plast or pawnLoc(pawn)
  local cl = Z.clast or worldLoc(cam)
  if not (pl and cl) then return false end
  local okR, rot = pcall(function() return cam:K2_GetComponentRotation() end)
  if not okR or not rot then return false end
  local okA, fwd = pcall(function() return UE4.UKismetMathLibrary.GetForwardVector(rot) end)
  local okB, rgt = pcall(function() return UE4.UKismetMathLibrary.GetRightVector(rot) end)
  local okC, upv = pcall(function() return UE4.UKismetMathLibrary.GetUpVector(rot) end)
  if not (okA and okB and okC and fwd and rgt and upv) then return false end
  local ex = unit(v3(fwd.X, fwd.Y, fwd.Z))
  local ey = unit(v3(rgt.X, rgt.Y, rgt.Z))
  local ez = unit(v3(upv.X, upv.Y, upv.Z))
  if vlen(ex) < 0.9 or vlen(ey) < 0.9 or vlen(ez) < 0.9 then return false end

  local eyeZ, eyeSrc = fpEyeHeight(pawn, pl)
  if not eyeZ then return false end
  local half = capsuleHalfH(pawn) or 88.0

  local back = (Z.fpAimNow and cfg.fpAimMode == 'hold') and cfg.fpBackAim or cfg.fpBack

  -- 目标点：眼位 + 相机**水平前向** × (−back)
  --
  -- ⚠ 绝不能再用「相机→眼位」方向来构造目标点。相机一旦接近眼位，那个方向
  -- 就是病态的（距离 vd→0，分母趋零，方向随数值噪声乱指），目标点跟着乱跳，
  -- 迭代永远收敛不了 —— 实测 err 恒定 7.8 不下降、want 每帧在 298~307 之间
  -- 抖、偶尔 err 冲到 340（相机被甩到 367cm），画面就是疯狂抖动。
  --
  -- 改用相机水平前向（相机几乎垂直看时用角色朝向兜底）：只依赖**朝向**，
  -- 与相机当前位置无关，所以误差是单调收敛的。
  local hx, hy = ex.X, ex.Y
  local hl = math.sqrt(hx * hx + hy * hy)
  if hl < 0.25 then
    local okP, pr = pcall(function() return pawn:K2_GetActorRotation() end)
    if okP and pr and type(pr.Yaw) == 'number' then
      local yaw = math.rad(pr.Yaw)
      hx, hy = math.cos(yaw), math.sin(yaw)
    else
      hx, hy = 1.0, 0.0
    end
    hl = 1.0
  end
  local fwdAmt = -back          -- back 为负 = 往眼睛前方，取反得到前进量
  -- 侧向偏移（过肩档用）：沿相机水平右向让开，避免后脑正好挡在视线上
  local lat = cfg.fpLatOffset or 0.0
  local rx, ry = ey.X, ey.Y
  local rl = math.sqrt(rx * rx + ry * ry)
  if rl < 0.25 then
    rx, ry, rl = -hy, hx, (hl or 1.0)   -- 兜底：水平前向顺时针转 90°
  end
  local tx = pl.X + (hx / hl) * fwdAmt + (rx / rl) * lat
  local ty = pl.Y + (hy / hl) * fwdAmt + (ry / rl) * lat
  local tz = eyeZ

  if Z.fpWantX == nil then Z.fpWantX = Z.appliedMag or 0.0 end
  if Z.fpWantY == nil then Z.fpWantY = Z.appliedLat or 0.0 end
  if Z.fpWantZ == nil then Z.fpWantZ = Z.appliedZOff or 0.0 end

  local dx, dy, dz = tx - cl.X, ty - cl.Y, tz - cl.Z
  local err = math.sqrt(dx * dx + dy * dy + dz * dz)
  Z.fpErrNow = err
  if err > 200.0 then
    -- 误差突然变得极大（相机被游戏甩走 / 切场景 / 状态错乱）：丢掉累积的
    -- want，从当前实际位置重新开始，不要带着一个已经失真的累积量一路推过去
    Z.fpWantX = Z.appliedMag or 0.0
    Z.fpWantY = Z.appliedLat or 0.0
    Z.fpWantZ = Z.appliedZOff or 0.0
    lp('FP drive reset (err=', fmt(err, 1), ')')
  end
  if err > cfg.fpErrEps then
    local g = cfg.fpGain
    local mx = (dx * ex.X + dy * ex.Y + dz * ex.Z) * g
    local my = (dx * ey.X + dy * ey.Y + dz * ey.Z) * g
    local mz = (dx * ez.X + dy * ez.Y + dz * ez.Z) * g
    local cap = cfg.fpStepMax
    if mx > cap then mx = cap elseif mx < -cap then mx = -cap end
    if my > cap then my = cap elseif my < -cap then my = -cap end
    if mz > cap then mz = cap elseif mz < -cap then mz = -cap end
    Z.fpWantX = Z.fpWantX + mx
    Z.fpWantY = Z.fpWantY + my
    Z.fpWantZ = Z.fpWantZ + mz
  end
  if Z.fpWantX > cfg.maxOffset then Z.fpWantX = cfg.maxOffset end
  if Z.fpWantX < -cfg.maxOffset then Z.fpWantX = -cfg.maxOffset end
  if Z.fpWantY > cfg.fpLatMax then Z.fpWantY = cfg.fpLatMax end
  if Z.fpWantY < -cfg.fpLatMax then Z.fpWantY = -cfg.fpLatMax end
  if Z.fpWantZ > cfg.fpEyeMaxUp then Z.fpWantZ = cfg.fpEyeMaxUp end
  if Z.fpWantZ < -cfg.fpEyeMaxUp then Z.fpWantZ = -cfg.fpEyeMaxUp end

  Z.fpMagTarget = Z.fpWantX
  Z.fpLatTarget = Z.fpWantY
  Z.fpZTarget = Z.fpWantZ
  Z.fpEyeZ = eyeZ

  Z.fpLogN = (Z.fpLogN or 0) + 1
  if Z.fpLogN <= 3 or Z.fpLogN % 100 == 0 then
    lp('FP drive err=', fmt(err, 1), 'want=', fmt(Z.fpWantX, 1), fmt(Z.fpWantY, 1),
       fmt(Z.fpWantZ, 1), 'distNow=', fmt(Z.dist, 1), 'back=', fmt(back, 1),
       'eyeZ=', fmt(eyeZ, 1), 'eyeSrc=', eyeSrc, 'half=', fmt(half, 1),
       'pawnZ=', fmt(pl.Z, 1))
  end
  return true
end

local function fpEnter(pawn, cam)
  -- 没标定就没有 coef（本地 X 轴方向未知），进 FP 会把相机往反方向推。
  -- 但也不能直接丢弃这次按键 —— 挂起，标定一成功就自动进（v72）。
  if not Z.ready then
    Z.fpPending = true
    Z.calStable = 100          -- 下一帧立刻尝试自动标定
    lp('FP enter deferred: not calibrated yet')
    return
  end
  if Z.fpSavedZ == nil then Z.fpSavedZ = Z.zTarget end
  Z.fpTarget = 1.0
  Z.fpBaseMag = nil
  Z.fpBaseY = nil
  Z.fpBaseZ = nil
  Z.fpZTarget = nil
  Z.fpLatTarget = nil
  Z.fpLogN = 0
  Z.fpWantX = nil            -- 误差迭代的起点 = 当前施加量（避免突变）
  Z.fpWantY = nil
  Z.fpWantZ = nil
  Z.fpFromLat = Z.appliedLat or 0.0
  Z.fpSuspendUntil = 0
  fpProbeBones(pawn)
  fpHeadApply(pawn, true)
  Z.fpRewrote = 0
  Z.fpAimNow = false
  Z.fpAimWas = false
  Z.fpAimFrames = 0
  Z.fpDev = 0
  Z.fpDevCool = 0
  fpComputeTarget(pawn, cam)
  if cfg.fpAimMode == 'release' then
    -- release 模式：进 FP 时把居中量清掉，避免残留 lat 把相机推歪
    Z.appliedLat = nil
  end
  hud('第一人称：开', 2.0)
end

local function fpExit()
  Z.fpTarget = 0.0
  if Z.fpSavedZ then Z.zTarget = Z.fpSavedZ end
  hud('第一人称：关', 1.5)
end

-- 混合量推进（50Hz）
local function fpStep(pawn)
  local t = Z.fpTarget or 0.0
  local cur = Z.fp or 0.0
  if cur == t then return end
  local dur = (t > cur) and cfg.fpFadeIn or cfg.fpFadeOut
  if dur < 0.02 then dur = 0.02 end
  local d = cfg.pollInterval / dur
  if cur < t then
    cur = math.min(t, cur + d)
  else
    cur = math.max(t, cur - d)
  end
  Z.fp = cur
  if cur <= 0.0 then
    Z.fp = 0.0
    Z.fpBaseMag = nil
    Z.fpBaseY = nil
    Z.fpBaseZ = nil
    Z.fpWantX = nil
    Z.fpWantY = nil
    Z.fpWantZ = nil
    Z.fpMagTarget = nil
    Z.fpLatTarget = nil
    Z.fpZTarget = nil
    Z.fpBaseD = nil
    Z.fpFromLat = nil
    Z.fpEyeZ = nil
    Z.fpZOff = 0.0
    Z.fpSavedZ = nil
    Z.fpSuspendUntil = 0
    Z.fpAimFrames = 0
    -- 所有权一并交还正常路径：最后一帧 FP 写入量已等于 targetOffset(z)，
    -- 此时清 appliedMag 不会造成跳变，反而避免正常路径把「FP 残值」误判成游戏接管
    Z.appliedMag = nil
    Z.appliedLat = nil
    Z.appliedZOff = nil
    fpHeadApply(pawn, false)      -- 退出第一人称，把头还回来
    lp('FP fully off')
  end
end

-- FP 写入路径：绕开居中积分 / FX 让位 / 旋转护盾 / 距离钳制 / 接管让行
local function applyFirstPerson(pawn, cam)
  local coef = Z.coef or 1.0
  local fp = Z.fp or 0.0
  if fp < 0.001 then return end

  -- 开镜判定沿用 P4 的同一套（fov 掉下 baseFov−12）
  local fv = fovOf(cam)
  local baseF = Z.baseFov or 75.0
  local aim = (fv ~= nil and fv > 5.0 and fv < baseF - 12.0)
  Z.fpAimNow = aim
  Z.aimNow = aim                    -- 供 HH：开镜时必须把 HUD（准星）还回来
  if aim then Z.fpAimFrames = Z.fpAimFrames + 1 else Z.fpAimFrames = 0 end

  -- release 模式：开镜整段交还游戏（贴脸偏移还原到 0，但保留 fp 混合量，
  -- 退出开镜后下一帧自动重新占据）
  if aim and cfg.fpAimMode == 'release' then
    if Z.appliedMag ~= nil or Z.appliedZOff ~= nil then
      setRel(cam, Z.baseRel)
      Z.appliedMag = nil
      Z.appliedLat = nil
      Z.appliedZOff = nil
      lp('FP release for aim (fp=', fmt(fp, 2), ')')
    end
    return
  end

  -- hold 模式：开镜时游戏会自己把相机挪到开镜机位，此时**不做任何写入**，
  -- 整段交还游戏；退出开镜后由下面的误差迭代重新收敛（会自然滑回眼位）。
  if aim and cfg.fpAimMode == 'hold' then
    if Z.appliedMag ~= nil or Z.appliedZOff ~= nil then
      setRel(cam, Z.baseRel)
      Z.appliedMag = nil
      Z.appliedLat = nil
      Z.appliedZOff = nil
      Z.fpWantX = nil
      Z.fpWantY = nil
      Z.fpWantZ = nil
      -- 交还游戏时**必须把头还回来**（开镜是第三人称过肩视角，能看到角色；
      -- v78 忘了这一步，导致开镜后角色变成光头）
      fpHeadApply(nil, false)
      lp('FP aim: 交还游戏，退出开镜后重新收敛')
    end
    return
  end
  Z.fpAimNow = false

  -- 每帧做一次误差迭代：目标点是固定世界坐标，用实测相机位置算误差，
  -- 逐帧吃掉（v78）。这样相机低头/抬头、走动、切人都不需要单独处理。
  fpComputeTarget(pawn, cam)

  -- 目标直接接管（上面已每帧算好），不做额外渐变：
  -- 进入/退出的平滑由 fp 混合负责（mag = magN + (target−magN)×fp），足够柔
  if Z.fpMagTarget ~= nil then Z.fpBaseMag = Z.fpMagTarget end
  if Z.fpZTarget ~= nil then Z.fpBaseZ = Z.fpZTarget end
  if Z.fpLatTarget ~= nil then Z.fpBaseY = Z.fpLatTarget end

  -- 安全网：游戏连续改写 relLoc（切人复位 / 演出）时先让开，防 v43 式互殴
  if Z.frame < (Z.fpSuspendUntil or 0) then return end
  local cur = relLoc(cam)
  if cur ~= nil and Z.appliedMag ~= nil then
    local dx = cur.X - (Z.baseRel.X + Z.appliedMag)
    local dy = (cur.Y or 0) - (Z.baseRel.Y + (Z.appliedLat or 0))
    local dz = (cur.Z or 0) - (Z.baseRel.Z + (Z.appliedZOff or 0))
    if math.abs(dx) > cfg.takeoverCm * 3 or math.abs(dz) > cfg.takeoverCm * 3
       or math.abs(dy) > cfg.takeoverCm * 3 then
      Z.fpRewrote = (Z.fpRewrote or 0) + 1
      if Z.fpRewrote >= 3 then
        Z.fpRewrote = 0
        Z.fpSuspendUntil = Z.frame + cfg.fpSuspendFrames
        Z.appliedMag = nil
        Z.appliedZOff = nil
        Z.fpBaseMag = nil
        lp('FP suspend: game rewrote relLoc dx=', fmt(dx, 1), 'dz=', fmt(dz, 1))
        return
      end
    else
      Z.fpRewrote = 0
    end
  end

  -- 【探测】第一人称下强制保持角色可见。
  -- 现象：相机确实落在眼睛位置（dist 51cm ≈ 眼位高度差 50.6cm，err 已收敛），
  -- 但低头也看不到任何身体部位，而滚轮拉到 z=0.31（约 95cm）时角色正常可见
  -- —— 高度怀疑游戏在「相机贴近角色」时自己把角色隐藏了（第三人称游戏常见做法）。
  -- 这里每 5 帧覆盖一次可见性三件套，看能否压住；日志打 first-only 结果。
  if Z.frame % 5 == 0 then
    local okM2, mesh2 = pcall(function() return pawn.Mesh end)
    if okM2 and mesh2 then
      pcall(function() mesh2:SetVisibility(true, true) end)
      pcall(function() mesh2:SetHiddenInGame(false, true) end)
      pcall(function() mesh2:SetOwnerNoSee(false) end)
      if not Z.fpVisLogged then
        Z.fpVisLogged = true
        local okV, vv = pcall(function() return mesh2:IsVisible() end)
        local okH, hh = pcall(function() return mesh2.bHiddenInGame end)
        local okO, oo = pcall(function() return mesh2.bOwnerNoSee end)
        lp('FP force visible: IsVisible=', tostring(okV and vv),
           'bHiddenInGame=', tostring(okH and hh), 'bOwnerNoSee=', tostring(okO and oo))
      end
    end
  end

  -- 混合：正常路径目标 ←→ FP 目标
  local magN = targetOffset(Z.z)
  local mag = magN + (Z.fpBaseMag - magN) * fp
  if mag > cfg.maxOffset then mag = cfg.maxOffset end
  if mag < -cfg.maxOffset then mag = -cfg.maxOffset end
  local wZ = Z.baseRel.Z + (Z.fpBaseZ or 0.0) * fp
  local wantX = Z.baseRel.X + mag
  -- 横向：从进入时的居中量平滑过渡到 FP 解出的横向修正（肩部视角 → 中线）
  local latFrom = Z.fpFromLat or 0.0
  local wantY = Z.baseRel.Y + latFrom * (1.0 - fp) + (Z.fpBaseY or 0.0) * fp

  if cur ~= nil and math.abs(cur.X - wantX) < 0.2
     and math.abs((cur.Y or 0) - wantY) < 0.2
     and math.abs((cur.Z or 0) - wZ) < 0.2 then
    Z.appliedMag = wantX - Z.baseRel.X
    Z.appliedLat = wantY - Z.baseRel.Y
    Z.appliedZOff = wZ - Z.baseRel.Z
    return
  end

  if setRel(cam, v3(wantX, wantY, wZ)) then
    Z.appliedMag = wantX - Z.baseRel.X
    Z.appliedLat = wantY - Z.baseRel.Y
    Z.appliedZOff = wZ - Z.baseRel.Z
    Z.fpLog = (Z.fpLog or 0) + 1
    if Z.fpLog % 25 == 1 then
      lp('FP apply fp=', fmt(fp, 2), 'mag=', fmt(mag, 1), 'lat=', fmt(wantY, 1),
         'zOff=', fmt(wZ - Z.baseRel.Z, 1), 'dist=', fmt(Z.dist, 1),
         'aim=', tostring(aim), 'cur=', vstr(cur))
    end
  end
end

local function applyZoom(pawn, cam)
  if not Z.ready then return end
  -- P5：贴脸模式走自己的写入路径（z 倍率只作为混合的一端参与插值）
  if (Z.fp or 0.0) > 0.001 then
    applyFirstPerson(pawn, cam)
    return
  end
  local z = Z.z
  local zt = Z.zoomS or 0

  -- 开镜时彻底让行；退出开镜后按 aimRamp 平滑恢复，避免硬切。
  -- v50 关键：阈值随光学变焦一起下移。固定用 baseFov−12(63) 的话，我们自己
  -- 收到的 45 会被自己的判定当成「开镜」→ 整段让行 → 变焦永远不生效。
  Z.aimNow = false
  local fv = fovOf(cam)
  local baseF = Z.baseFov or 75.0
  local fovThT = baseF + (cfg.zoomFovEnd - baseF) * zt
  -- 诊断：读回值与上一帧写入值不符 = 游戏在两帧之间改过 FOV（回写/演出 kick）
  if Z.fovWritten ~= nil and fv and math.abs(fv - Z.fovWritten) > 1.5 then
    Z.fovRev = (Z.fovRev or 0) + 1
  end
  local aimTh = math.min(fovThT - 6.0, baseF - 12.0)
  local aimHit = (fv ~= nil and fv > 5.0 and fv < aimTh)
  -- v71 自愈：FOV 被游戏压住不放时，让行会永久卡死（滚轮彻底失灵）。
  -- 只在「让行已经持续 15s 且用户期间滚过轮」时判定为误判 —— 真心瞄准的人
  -- 不会一边瞄一边滚轮，所以这个判据不会打断正常开镜。
  if aimHit then
    Z.aimSince = Z.aimSince or Z.frame
    if (Z.frame - Z.aimSince) >= cfg.aimStuckFrames
       and (Z.wheelSinceAim or 0) >= cfg.aimStuckWheel then
      aimHit = false
      Z.aimStuckCount = (Z.aimStuckCount or 0) + 1
      Z.aimSince = Z.frame
      Z.wheelSinceAim = 0
      lp('AIM stuck -> force resume fov=', fmt(fv, 1), 'th=', fmt(aimTh, 1),
         'z=', fmt(Z.z, 2), 'n=', Z.aimStuckCount)
    end
  else
    Z.aimSince = nil
    Z.wheelSinceAim = 0
  end
  if aimHit then
    Z.aimNow = true                  -- P4：开镜时必须把 HUD（至少准星）还回来
    Z.aimBlend = 0.0
    Z.fxUntil = 0                    -- 开镜让行优先，FX 窗口作废
    Z.fovWritten = nil               -- FOV 交还游戏（开镜 FOV 由游戏自己写）
    if Z.appliedMag ~= nil then
      -- 让行时一次性还原到游戏默认机位（基准恒为 0），之后不再干预
      setRel(cam, Z.baseRel)
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('APPLY released for aim fov=', fmt(fv, 1), 'th=', fmt(aimTh, 1))
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
      Z.fxUntil = 0                  -- 接管让行优先，FX 窗口作废
      -- 解除所有权：防止让行一结束就拿陈旧的 appliedMag 再误判一次接管
      Z.appliedMag = nil
      Z.appliedLat = nil
      lp('YIELD game takeover dx=', fmt(dx, 1), 'dy=', fmt(dy, 1))
      return
    end
  end

  -- FX 让位窗口（v49 = v47 机制 + 挤压门 + 冷却）：检测到游戏引起的距离
  -- 突变时，偏移在 ~5 帧内平滑滑到 0 —— 演出期间相机完全等于原版机位
  -- （原版同款动态幅度 = 用户认可的正常手感），结束后 aimBlend 0.45s 慢坡
  -- 滑回缩放位。gameD 剥离滚轮自变，滚轮不误触发。
  -- v48 教训：距离伺服（焊住 dist）与游戏 boom 的反馈形成正回路 —— 19 次
  -- 触发 / hold 棘轮上漂 / mag 冲到 700，彻底失控。伺服路线废弃不重试。
  -- v47 两个实测问题的修正：
  --   a) 挤压门：D = dist+appliedMag 是 boom 的贡献，碰撞压短 boom 时
  --   D << baseDist —— 此时「滑回原版机位」与碰撞释放同向叠加 = 靠墙闪光。
  --   不让位，交给距离钳制托底，释放按原版节奏进行（原版速度用户无感）；
  --   b) 冷却：窗口结束后 1s 不再触发，防退出坡与游戏反应互相触发成环。
  local distPrev = Z.distPrev
  local gameD = nil
  if Z.dist ~= nil and distPrev ~= nil then
    gameD = (Z.dist - distPrev) + ((Z.appliedMag or 0) - (Z.appliedPrev or Z.appliedMag or 0))
  end
  local magT = targetOffset(z)
  local squeezed = Z.dist ~= nil
    and (Z.dist + (Z.appliedMag or 0)) < Z.baseDist - cfg.fxSqueezeD
  if gameD ~= nil and math.abs(gameD) >= cfg.fxDistRate
     and Z.appliedMag ~= nil and magT > 10.0
     and Z.frame >= (Z.fxUntil or 0) and Z.frame >= (Z.fxCool or 0)
     and not squeezed then
    Z.fxUntil = Z.frame + cfg.fxFrames
    Z.fxStart = Z.frame
    Z.fxCool = Z.frame + cfg.fxFrames + cfg.fxCoolFrames
    Z.aimBlend = 0.0            -- 窗口结束后从当前机位慢坡滑回缩放位
    Z.aimRampCur = 0.45
    lp('YIELD dash FX gameD=', fmt(gameD, 1), 'dist=', fmt(Z.dist, 1),
       'mag=', fmt(Z.appliedMag, 1))
  end
  if Z.frame < (Z.fxUntil or 0) then
    -- 窗口内：偏移按 5 帧滑向 0（绝对写入幂等，到位后为无操作，相机完全
    -- 跟随游戏 boom = 原版行为，包括碰撞/弹性，零对抗）
    local p = math.min(1.0, (Z.frame - (Z.fxStart or Z.frame) + 1) / 5)
    -- v50：FOV 必须与偏移同步滑回。否则相机回到原版 3.2m 时 FOV 还窄着，
    -- 角色会突然被拉成一个大特写（远处长焦假象），窗口结束再缩回去。
    applyFov(cam, zt * (1.0 - p))
    if cur ~= nil then
      local wx = cur.X + (Z.baseRel.X - cur.X) * p
      local wy = cur.Y + (Z.baseRel.Y - cur.Y) * p
      local wz = (cur.Z or 0) + (Z.baseRel.Z - (cur.Z or 0)) * p
      if setRel(cam, v3(wx, wy, wz)) then
        Z.appliedMag = wx - Z.baseRel.X
        Z.appliedLat = wy - Z.baseRel.Y
      end
      -- 演出瞬态不得污染居中积分（v41 同理）
      Z.centerFreezeUntil = math.max(Z.centerFreezeUntil or 0, Z.frame + 30)
    end
    if gameD ~= nil and math.abs(gameD) >= cfg.fxDistRate then
      Z.fxUntil = Z.frame + cfg.fxFrames   -- 游戏动态还在继续，续期
    end
    return
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
    ab = math.min(1.0, ab + cfg.pollInterval / (Z.aimRampCur or cfg.aimRamp))
    if ab >= 1.0 then Z.aimRampCur = nil end
    Z.aimBlend = ab
  end

  -- 光学变焦（P2 v50）：FOV 收窄 + 轻微后拉。上面的开镜 / 让行 / 护盾几条
  -- 路径都在这之前 return —— 那些演出期间 FOV 归游戏管，我们一次都不写。
  applyFov(cam, zt * ab)

  -- 横向居中：拉近到 centerStart 以下开始把人物往画面中间拉
  local ct = 0
  if z < cfg.centerStart then
    if z <= cfg.centerFull then
      ct = 1.0
    else
      ct = (cfg.centerStart - z) / (cfg.centerStart - cfg.centerFull)
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

  -- 变焦满档时相机后退 zoomPullEnd cm：只收 FOV 不收距离的话，相机几乎贴在
  -- 角色模型上，广角贴脸畸变极重；退 60cm 换来长焦近景的透视压缩。
  -- coef 与 targetOffset 同一套符号，可直接相加（正值 = 后拉）
  local mag = (targetOffset(z) + cfg.zoomPullEnd * zt * (Z.coef or 1.0)) * ab
  if mag > cfg.maxOffset then mag = cfg.maxOffset end
  if mag < -cfg.maxOffset then mag = -cfg.maxOffset end
  -- 横向一律钳制，绝不允许把相机甩出去
  if lat > 160 then lat = 160 end
  if lat < -160 then lat = -160 end

  -- 距离钳制（v46 引入，v48 改顶棚式 + 迟滞锁存）：dist < 90 置锁存，锁存
  -- 期间写入量顶到 D−90（D = dist + appliedMag 为游戏 boom 贡献），相机-人物
  -- 距离保持 ≥90，穿人在结构上不可能；dist > 90+15 才解锁。
  -- v48 修极限环：v46 的 deficit 式在临界点（dist 恰到 90）条件不再成立、
  -- 写满量恢复 → dist 弹回 → 再钳，49↔90 以 ~12Hz 振荡（贴墙站立即可见）。
  -- 锁存期间同一顶棚持续生效，稳态无振荡；碰撞释放后自然解锁。
  local magW = mag
  if Z.dist ~= nil then
    local DnowC = Z.dist + (Z.appliedMag or 0)
    if Z.dist < cfg.minCamDist then
      if not Z.dclampOn then
        Z.dclampOn = true
        lp('DCLAMP on dist=', fmt(Z.dist, 1), 'D=', fmt(DnowC, 1), 'mag=', fmt(mag, 1))
      end
      Z.dclampLast = Z.frame
    elseif Z.dclampOn and Z.dist > cfg.minCamDist + cfg.clampHyst then
      Z.dclampOn = false
      lp('DCLAMP off dist=', fmt(Z.dist, 1))
    end
    if Z.dclampOn then
      local ceilD = DnowC - cfg.minCamDist
      if magW > ceilD then
        magW = ceilD
        -- 钳制期间冻结居中积分（瞬态不得污染 hold，v41 同理）
        Z.centerFreezeUntil = math.max(Z.centerFreezeUntil or 0, Z.frame + 25)
      end
    end
  end

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
      lp('APPLY z=', fmt(z, 3), 'mag=', fmt(mag, 1), 'lat=', fmt(lat, 1), 'zoom=', fmt(zt, 2), 'ab=', fmt(ab, 2))
    end
  end
end

-- 晚帧写入：由主界面 UMG Tick 调用（Slate tick 在相机更新之后、渲染之前）
-- 只有在这个时机写 FOV 才不会被游戏当帧回写
function CamZoomMod.LateTick(dt)
  Z.lateFrames = (Z.lateFrames or 0) + 1
  if Z.lateFrames % 120 == 0 then
    lp('LATE alive frames=', Z.lateFrames, 'ready=', tostring(Z.ready),
       'zoom=', fmt(Z.zoomS, 2), 'fovW=', fmt(Z.fovWritten, 1))
  end
  -- v50：FOV 写入已移到 50Hz 主循环的 applyFov —— 战斗中 UMG Tick 从不执行
  -- （v48 实测 LATE alive 计数恒为 0），Timer 循环才是唯一稳定节拍。
  -- 钩子保留只为心跳取证，别在这里加写入逻辑。
end

-- ============================================================
-- 主循环
-- ============================================================
-- 单格滚轮（v50）：拉近方向先吃距离，距离到底（zTarget==zMin）后再吃光学
-- 变焦；拉远方向反过来 —— 先把变焦退干净再退距离。否则从满档往回滚会先看到
-- 镜头猛退、FOV 还窄着，构图乱跳。
local function applyNotch(dirIn)
  if dirIn then
    if Z.zTarget > cfg.zMin + 1e-4 then
      Z.zTarget = math.max(cfg.zMin, Z.zTarget - cfg.notchStep)
    else
      Z.zTarget = cfg.zMin
      Z.zoomT = math.min(1.0, (Z.zoomT or 0) + cfg.zoomStep)
    end
  else
    if (Z.zoomT or 0) > 1e-4 then
      Z.zoomT = math.max(0.0, (Z.zoomT or 0) - cfg.zoomStep)
    else
      Z.zTarget = math.min(cfg.zMax, Z.zTarget + cfg.notchStep)
    end
  end
end

local function onWheel(steps)
  if steps == 0 then return end
  if cfg.invertWheel then steps = -steps end
  local n = math.abs(steps)
  if n > 20 then n = 20 end
  local dirIn = (steps < 0)
  for _ = 1, n do applyNotch(dirIn) end
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
    if not isGameplay(pc) then
      -- v73：非 gameplay（主界面/加载/剧情）也要把滚轮事件消费掉。
      -- 否则这些事件会一直堆在文件里，等进入战斗后第一次读取才被发现 ——
      -- 旧版会把它们连同基准一起吞掉，用户在大厅滚半天，进游戏后仍是「没反应」。
      -- 这里只 drain 丢弃，不产生缩放；按键不 drain（大厅里也可能要开第一人称）。
      pollIPC()
      return
    end

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
        -- FX 让位窗口与距离基准一并复位
        Z.fxUntil = 0
        Z.fxStart = 0
        Z.fxCool = 0
        Z.distPrev = nil
        -- 换相机组件后 FOV 写入权作废（旧组件的值留在旧组件上，不要跨组件还原）
        Z.fovWritten = nil
        Z.fovRev = 0
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
        -- P5：贴脸状态下换人，目标位置要按新角色重算（几何法会自动适配体型）
        if (Z.fpTarget or 0.0) > 0.5 then
          Z.fpBaseMag = nil
          Z.fpBaseY = nil
          Z.fpBaseZ = nil
          Z.fpWantX = nil      -- 新角色体型/挂点都变了，迭代从新实测重新开始
          Z.fpWantY = nil
          Z.fpWantZ = nil
          -- v79：**不暂停写入**。旧版在这里 suspend 12 帧，相机先被游戏复位到
          -- 第三人称、再由迭代收回来 —— 用户看到的"切人时闪一下第三人称"就是它。
          -- 迭代每帧都在收敛，切人后下一帧就能落在新角色的眼位上。
          Z.fpSuspendUntil = 0
          fpHeadApply(nil, false)      -- 旧角色的头还回去
          fpHeadApply(pawn, true)      -- 新角色重新藏头
          lp('FP relock for new pawn')
        end
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

    -- v72 自动标定：原设计只在「滚轮产生 delta」时标定，实际上这条路很脆 ——
    -- 用户快速滚 10+ 格，pollIPC 首次读取时只记下 seq 并返回 0，10 格全被静默
    -- 吞掉（既不缩放也不标定），表现就是「滚轮完全没反应」。而滚轮如需发生在
    -- 加载/剧情里（isGameplay false 时 step 直接 return）更是永远等不到。
    -- 改为：gameplay 下相机距离稳定 0.5s 就自动标定，不再依赖输入事件。
    if not Z.ready then
      local stable = (Z.dist ~= nil and Z.distPrev ~= nil
                      and math.abs(Z.dist - Z.distPrev) < 3.0)
      if stable then
        Z.calStable = (Z.calStable or 0) + 1
        if Z.calStable >= 25 then
          lp('CAL auto trigger dist=', fmt(Z.dist, 0))
          calibrate(pawn, cam)
        end
      else
        Z.calStable = 0
      end
    end

    -- 标定成功后才执行挂起的「进第一人称」请求
    if Z.fpPending and Z.ready then
      Z.fpPending = false
      fpEnter(pawn, cam)
    end

    -- P5：切换键（sniffer 键盘钩子 → fp_key.txt，seq 去重）。
    -- v71：支持主键 + 备选键（V/B/F5/Insert），并加冷却 —— 按住不放时系统
    -- 会持续发 KEYDOWN，不冷却就会把 FP 反复开关，镜头在原地抽搐。
    if cfg.fpOn then
      local vk = pollFPKey()
      if vk ~= nil then
        local match = (vk == cfg.fpKeyVK)
        if not match and cfg.fpKeyAlt then
          for i = 1, #cfg.fpKeyAlt do
            if cfg.fpKeyAlt[i] == vk then match = true break end
          end
        end
        if match and Z.frame >= (Z.fpKeyCoolUntil or 0) then
          Z.fpKeyCoolUntil = Z.frame + math.floor(cfg.fpKeyCool / cfg.pollInterval)
          lp('FP toggle vk=', vk, 'fpTarget=', fmt(Z.fpTarget, 1), 'ready=', tostring(Z.ready))
          if (Z.fpTarget or 0.0) > 0.5 then
            fpExit()
          else
            if not Z.ready then calibrate(pawn, cam) end
            fpEnter(pawn, cam)
          end
        elseif vk == cfg.fpBackKeyVK and (Z.fpTarget or 0.0) > 0.5
               and Z.frame >= (Z.fpKeyCoolUntil or 0) then
          -- B 键：循环视角距离预设。第一人称平视看不到自己是正常的（躯干在
          -- 相机正下方），把值往正数调就是过肩视角，平视能看到后脑与肩线。
          Z.fpKeyCoolUntil = Z.frame + math.floor(cfg.fpKeyCool / cfg.pollInterval)
          local n = #cfg.fpViewPresets
          cfg.fpViewIdx = (cfg.fpViewIdx % n) + 1
          local pv = cfg.fpViewPresets[cfg.fpViewIdx]
          cfg.fpBack = pv.back
          cfg.fpLatOffset = pv.lat
          Z.fpLogN = 0
          Z.fpErrNow = nil
          lp('FP view preset idx=', cfg.fpViewIdx, 'name=', pv.name,
             'back=', fmt(pv.back, 1), 'lat=', fmt(pv.lat, 1))
        end
      end
    end
    pollBeat()
    fpStep(pawn)

    -- 心跳：每 ~2 秒打一行状态，便于定位「为什么没反应」
    Z.hb = (Z.hb or 0) + 1
    if Z.hb % 100 == 0 then
      local fvh = pawn and getCam(pawn) and fovOf(getCam(pawn)) or nil
      local curD = relLoc(cam)
      local clD = worldLoc(cam)
      lp('HB frame=', Z.frame, 'z=', fmt(Z.z, 2), 'zt=', fmt(Z.zTarget, 2),
         'zoom=', fmt(Z.zoomS, 2), 'fov=', fmt(fvh, 1), 'fovW=', fmt(Z.fovWritten, 1),
         'rev=', Z.fovRev or 0, 'ready=', tostring(Z.ready), 'ab=', fmt(Z.aimBlend, 2),
         'mag=', fmt(Z.appliedMag, 1), 'lat=', fmt(Z.appliedLat, 1),
         'hold=', fmt(Z.latHold, 1), 'yd=', fmt(math.max(0, (Z.yieldUntil or 0) - Z.frame)),
         'sh=', fmt(math.max(0, (Z.shieldUntil or 0) - Z.frame)),
         'fx=', fmt(math.max(0, (Z.fxUntil or 0) - Z.frame)),
         'err=', Z.err, 'hud=', fmt(HH.alpha, 2), 'want=', tostring(HH.want and not Z.aimNow),
         'src=', Z.wheelSrc, 'baseRel=', vstr(Z.baseRel),
         'cur=', vstr(curD), 'worldZ=', fmt(clD and clD.Z or nil, 1),
         'dist=', fmt(Z.dist, 0),
         -- P5 第一人称
         'fp=', fmt(Z.fp, 2), 'fpA=', tostring(Z.fpAimNow),
         'fpD=', fmt(Z.fpBaseD, 0), 'fpZ=', fmt(Z.appliedZOff, 1),
         'fpT=', fmt(Z.fpBaseMag, 0), 'pawnZ=', fmt(Z.plast and Z.plast.Z or nil, 1),
         'beat=', tostring(Z.beatVal), 'bStuck=', Z.beatStuck or 0)
    end



    if Z.ready then
      if delta ~= 0 then
        -- P5：第一人称下滚轮**完全屏蔽**（用户要求：滚轮缩放只在第三人称生效）。
        -- 不用它退出 FP —— 低头/快速滚动很容易误触发，退出只认切换键（Insert 等）。
        if (Z.fpTarget or 0.0) > 0.5 then
          -- 什么都不做
        else
          onWheel(delta)
          -- v71：记录「开镜期间用户仍在滚轮」—— 开镜让行自愈的判据
          if Z.aimNow then Z.wheelSinceAim = (Z.wheelSinceAim or 0) + 1 end
        end
      end
      -- 指数平滑：时间常数 tau，帧率无关，手感柔和不卡顿
      local dz = Z.zTarget - Z.z
      if math.abs(dz) < 0.0008 then
        Z.z = Z.zTarget
      else
        local k = 1.0 - math.exp(-cfg.pollInterval / cfg.tau)
        Z.z = Z.z + dz * k
      end
      -- 光学变焦同一套指数平滑（单独的时间常数：变焦比推拉更跟手）
      local dzo = (Z.zoomT or 0) - (Z.zoomS or 0)
      if math.abs(dzo) < 0.0008 then
        Z.zoomS = Z.zoomT or 0
      else
        local kz = 1.0 - math.exp(-cfg.pollInterval / cfg.zoomTau)
        Z.zoomS = (Z.zoomS or 0) + dzo * kz
      end
      applyZoom(pawn, cam)
      Z.appliedPrev = Z.appliedMag   -- v47：供下一帧 gameD 剥离自身写入量

      -- v86：每 60 帧（1.2s）把 dither/fade 材质参数压回不透明。
      -- 不能每帧做 —— SetScalarParameterValueOnMaterials 会遍历全部材质槽。
      if Z.frame % 60 == 0 then applyDitherFix(pawn) end

      -- P4：近景欣赏 —— 居中区间内淡出 HUD（开镜时强制显示，否则没法瞄准）
      -- P5：贴脸模式同样整根隐藏，开镜时由 applyFirstPerson 置 aimNow 还回
      if cfg.hudHideOn then
        if (Z.fpTarget or 0.0) > 0.5 or Z.z <= cfg.hudHideZ then
          HH.want = true
        elseif Z.z >= cfg.hudHideZ + cfg.hudHideHyst then
          HH.want = false
        end
        hhUpdate(HH.want and not Z.aimNow)
      end
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
    lp('v86 online')
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
  lp('v86 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v86 injected but NOT ready, allow retry')
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
