-- ========================================================
-- @File    : CamZoomMod.lua (v54)
--
-- v92（2026-10-30）：与 FreeCamMod（自由相机拍照）共存 —— 一个 pak 同时装两个 MOD
--   两个 MOD 的注入点是同两个 Lua 文件，分装两个 pak 会争抢同名文件，所以合并。
--   协议：freecam 激活期间往 _G.FreeCamActive 写递增帧号、退出写 false；
--   本侧 step() 开头检查 —— 激活期间**整体挂起**（滚轮、缩放写入、HUD、F5、
--   标定全停），只排水 wheel.txt / fp_key.txt 的 seq（挂起期的滚轮事件是
--   freecam 的 FOV 输入，不排水的话退出瞬间会被当成缩放一次吃掉）。
--   帧号 2s（100 帧）不递增 → freecam 主循环已死，强制清开关恢复本模组
--   （若 freecam 其实活着，下一帧会把开关写回来，随即再次挂起，无害）。
--   恢复时清 distPrev/rotPrev/dRot（挂起期的陈旧测量不得误触发 FX 让位/护盾），
--   缩放状态（z / zoomT / appliedMag）原样保留 = 退出即回到之前的缩放档。
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

  ipcPath = 'C:\\ProgramData\\CamZoomMod\\wheel.txt',
  beatPath = 'C:\\ProgramData\\CamZoomMod\\sniffer_beat.txt',

  -- 开镜让行自愈：游戏某些功能（视角切换键等）会把 FOV 压到低位，与「开镜」
  -- 在数值上无法区分 → 模组整段让行 → 滚轮彻底失灵，要再开一次镜才恢复。
  -- 判据：让行持续 aimStuckFrames 帧且期间用户滚过轮（真心瞄准不会一边瞄
  -- 一边滚轮）→ 判为误判，强制恢复一次。
  aimStuckFrames = 200,    -- 4s（50Hz）
  aimStuckWheel = 2,

  -- 渲染调色（v88）：不碰任何资源文件，只改 UE4 运行时渲染变量。
  -- 这是唯一不需 pak 主密钥就能改善画面的路径（pak 加密，解包需绕 ACE）。
  -- 按 F5 切换「原版 / 强化调色」对比。
  -- ⚠ 能做到「观感更接近动画」，做不到 cel shading 与描边（那必须改材质）。
  rndOn = false,           -- 当前是否已应用
  rndKeyVK = 116,          -- F5
  rndKeyPath = 'C:\\ProgramData\\CamZoomMod\\fp_key.txt',
  -- 开启时执行（可在游戏内控制台里手调试出更合适的值，再回填到这里）
  rndCmdsOn = {
    'r.Saturation 1.25',        -- 饱和度：动画感的主要来源
    'r.Tonemapper.Sharpen 1.5', -- 锐化：抵消 TAA 糊感
    'r.TonemapperGamma 2.0',    -- 提亮中间调
    'r.SceneColorFringeQuality 1',
    'r.BloomQuality 5',
  },
  -- 关闭时执行（回默认）
  rndCmdsOff = {
    'r.Saturation 1.0',
    'r.Tonemapper.Sharpen 0',
    'r.TonemapperGamma 2.2',
    'r.SceneColorFringeQuality 0',
    'r.BloomQuality 4',
  },
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
  -- 首次读取**不能把事件吞掉**：旧写法会把进游戏前累积的全部滚轮当成基准
  -- 丢掉（实测滚了 44 格、一格 delta 都没产生 →「滚轮完全失效」，连标定都不
  -- 会触发）。退一格当基准 → 当帧就产生 1 格。
  if Z.ipcSeq < 0 then Z.ipcSeq = seq - 1 end
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

-- 嗅探器心跳：sniffer 每 2s 把递增计数写 sniffer_beat.txt。连续 3 次采样
-- （约 6s）不变或文件缺失 = 进程没了 —— 这是「滚轮和按键同时失灵」最常见的
-- 原因，直接在屏幕上提示，省得再去翻日志。
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
  Z.beatStuck = (Z.beatStuck or 0) + 1
  if Z.beatStuck == 3 then
    lp('SNIFFER dead or missing, beat=', tostring(v))
    if Z.frame >= (Z.beatWarnUntil or 0) then
      Z.beatWarnUntil = Z.frame + 3000
      hud('输入嗅探器未运行：滚轮不可用', 5.0)
    end
  end
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
-- ============================================================
-- 渲染调色（v88）
-- ============================================================
-- 用途：不修改任何资源文件，只用 UE4 的运行时控制台变量调整画面观感。
-- 为什么不做真正的 cel shading：那需要替换角色材质 → 需要解包 pak → pak 是加密的
-- （每个 pak 用 md5(pak名) 经主密钥 AES 派生），主密钥不在二进制里静态存放，
-- 运行时读取又被 ACE 拦住。所以这里只做「颜色/对比/锐化」层面的强化。
local function rndSend(pc, cmd)
  local ok, err = pcall(function()
    UE4.UKismetSystemLibrary.ExecuteConsoleCommand(pc, cmd)
  end)
  return ok, err
end

local function rndToggle(pc)
  cfg.rndOn = not cfg.rndOn
  local list = cfg.rndOn and cfg.rndCmdsOn or cfg.rndCmdsOff
  for i = 1, #list do
    local ok, err = rndSend(pc, list[i])
    if not ok then lp('RND fail:', list[i], tostring(err)) end
  end
  lp('RND switched on=', tostring(cfg.rndOn), 'cmds=', #list)
  if cfg.rndOn then
    hud('画面强化：开（F5 可关）', 2.5)
  else
    hud('画面强化：关', 1.5)
  end
end

-- 读 F5（sniffer 的键盘钩子写 fp_key.txt，与轮询滚轮同一套 seq 去重）
local function pollRndKey()
  if type(io) ~= 'table' or type(io.open) ~= 'function' then return false end
  local ok, f = pcall(io.open, cfg.rndKeyPath, 'r')
  if not ok or not f then return false end
  local content = nil
  pcall(function() content = f:read('a') end)
  pcall(function() f:close() end)
  if not content or content == '' then return false end
  local seqs, vks = content:match('(%d+)%s+(%d+)')
  if not seqs then return false end
  local seq, vk = tonumber(seqs), tonumber(vks)
  if not seq or not vk then return false end
  if Z.rndKeySeq == nil then
    Z.rndKeySeq = seq
    if vk <= 0 then return false end          -- 只丢 sniffer 的初始化占位
  elseif seq == Z.rndKeySeq then
    return false
  else
    Z.rndKeySeq = seq
    if vk <= 0 then return false end
  end
  if vk ~= cfg.rndKeyVK then return false end
  if Z.frame < (Z.rndCoolUntil or 0) then return false end
  Z.rndCoolUntil = Z.frame + 25               -- 0.5s 冷却，防按住连发
  return true
end

-- ============================================================
-- FreeCam 共存检查（v92）：自由相机激活时本模组整体挂起。
-- _G.FreeCamActive 由 freecam 维护：激活=递增帧号（每帧刷新）、退出=false。
-- 布尔 true 视为旧版 freecam，无条件信任；数字才走死人开关。
-- ============================================================
local function freecamActive()
  local v = _G.FreeCamActive
  if not v then
    Z.fcStale = 0
    Z.fcFrame = nil
    return false
  end
  if type(v) == 'number' then
    if v ~= (Z.fcFrame or -1) then
      Z.fcFrame = v
      Z.fcStale = 0
      return true
    end
    Z.fcStale = (Z.fcStale or 0) + 1
    if Z.fcStale >= 100 then                  -- 2s 无心跳 = freecam 主循环已死
      lp('FreeCamActive stale -> clear (freecam loop dead?)')
      _G.FreeCamActive = false
      Z.fcFrame = nil
      Z.fcStale = 0
      return false
    end
    return true
  end
  return true    -- 布尔 true（旧版 freecam）：无条件信任
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

local function applyZoom(pawn, cam)
  if not Z.ready then return end
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
  -- 让行自愈：游戏某些功能（视角切换键等）会把 FOV 压到低位，与「开镜」在数值
  -- 上无法区分 → 模组整段让行 → 滚轮彻底失灵，只有再开一次镜才恢复。
  -- 只在让行持续 4s 且期间用户滚过轮时判为误判：真心瞄准的人不会一边瞄一边滚轮。
  if aimHit then
    Z.aimSince = Z.aimSince or Z.frame
    if (Z.frame - Z.aimSince) >= cfg.aimStuckFrames
       and (Z.wheelSinceAim or 0) >= cfg.aimStuckWheel then
      aimHit = false
      Z.aimSince = Z.frame
      Z.wheelSinceAim = 0
      Z.aimStuckCount = (Z.aimStuckCount or 0) + 1
      lp('AIM stuck -> force resume fov=', fmt(fv, 1), 'z=', fmt(Z.z, 2),
         'n=', Z.aimStuckCount)
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

    -- ===== FreeCam 共存挂起（v92）=====
    -- 自由相机激活期间整体让位：滚轮 / 缩放写入 / HUD / F5 / 标定全停。
    -- 只排水 IPC 的 seq —— 挂起期的滚轮事件是 freecam 的 FOV 输入，
    -- 不排水的话退出瞬间会被当成缩放一次吃掉（返回值直接丢弃）。
    local fcOn = freecamActive()
    if fcOn and not Z.fcSuspended then
      Z.fcSuspended = true
      lp('FREECAM active -> CamZoom suspended (wheel/HUD/keys yield)')
    elseif not fcOn and Z.fcSuspended then
      Z.fcSuspended = false
      -- 挂起期的测量全部作废：防第一帧的 gameD / dRot 突变误触发
      -- FX 让位 / 旋转护盾。缩放状态原样保留 = 回到之前的缩放档。
      Z.distPrev = nil
      Z.rotPrev = nil
      Z.dRot = nil
      lp('FREECAM ended -> CamZoom resumed, z=', fmt(Z.z, 2))
    end
    if fcOn then
      pollIPC()
      pollRndKey()
      return
    end

    local pc = getPC()
    if not pc then return end
    local pawn = getPawn()
    if not pawn then return end
    local cam = getCam(pawn)
    if not cam then return end
    if not isGameplay(pc) then
      -- 非 gameplay（主界面/加载/剧情）也要把滚轮事件消费掉：否则它们会一直
      -- 堆在文件里，进战斗后第一次读取才被发现，表现为「大厅滚了半天没反应」。
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

    -- 自动标定：gameplay 下相机距离稳定 0.5s（25 帧）就自动 calibrate。
    -- 不能只靠「滚轮产生 delta」触发 —— 首次读取会消费掉累积事件、玩家也可能
    -- 在加载/剧情里滚轮（那时 step 直接 return），结果就是 ready 永远是 false，
    -- 整个模组停摆（表现为滚轮和按键全都没反应）。
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
         'dist=', fmt(Z.dist, 0))
    end



    pollBeat()

    -- 渲染调色：F5 切换（不依赖相机标定，进游戏随时可用）
    if pollRndKey() then rndToggle(pc) end

    if Z.ready then
      if delta ~= 0 then
        onWheel(delta)
        -- 开镜期间用户仍在滚轮 → 让行自愈的判据（见 applyZoom）
        if Z.aimNow then Z.wheelSinceAim = (Z.wheelSinceAim or 0) + 1 end
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

      -- P4：近景欣赏 —— 居中区间内淡出 HUD（开镜时强制显示，否则没法瞄准）
      if cfg.hudHideOn then
        if Z.z <= cfg.hudHideZ then
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
    lp('v92 online (merged with FreeCamMod)')
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
  lp('v92 injected (loop=' .. tostring(_loopStarted) .. ', subs=' .. tostring(_subCount) .. ')')
else
  lp('v92 injected but NOT ready, allow retry')
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
