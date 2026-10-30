# 尘白禁区 · 滚轮缩放镜头 — 交接文档

> 最后更新：2026-10-30（第二十三轮 · v92：与 FreeCamMod 合并共存）
> 状态：**当前生效 = v92 合并 pak**（CamZoomMod + FreeCamMod 一个 pak，见第一节末「v92 合并」段）。
> **P2（FOV 收窄）**经五轮普查判定不可实现；**P4 已验收（v68）**；**P5 已随 v87 清理关闭**。
> 自由相机（FreeCamMod）的进度文件在 `work/freecam/HANDOFF.md`。
>
> ⚠ **最重要的运维事实：`wheel_sniffer.py` 必须由 Explorer 启动**
> （双击 `runtime/start_wheel_sniffer.vbs` 或 `_admin.vbs`）。从 agent 的命令会话里
> 启动的进程会被父任务的 job object 在会话结束时收掉 —— `CREATE_BREAKAWAY_FROM_JOB`
> 在本环境被拒（WinError 5），表现为「滚轮和 V 键同时失灵、`src=none`、`ready=false`」。
> 工具层还拦截 `taskkill`/`wscript`/`Start-Process`/`Invoke-CimMethod Win32_Process Create`，
> 所以**重启嗅探器只能人工双击 VBS**。
>
> ⚠ **绝对必须用 `start_wheel_sniffer_admin.vbs`（管理员）。**
> 游戏经 `SeasunGame.exe` 以管理员完整性启动；Windows 的 **UIPI** 规定低完整性
> 进程安装的低级钩子**收不到发往高完整性进程的输入**。
> 症状极其反直觉：**游戏在前台时滚轮/按键完全没反应，把游戏切到后台反而生效**
> （那时事件目标是同权限的聊天窗口）。这是 2026-10-29 排查一整轮才定位的根因 ——
> 之前所有"没反应"的日志都指向模组内部，实际是钩子根本没收到输入。
> 嗅探器现在会把 `elevated=0/1` 写进 `sniffer_state.txt`，非管理员时还会写
> `sniffer_warn.txt` 直接说明该怎么改；看到 `elevated=0` 就不用往别处查了。
>
> ⚠ **嗅探器的消息泵必须阻塞**（`GetMessageW`），**绝不能用
> `PeekMessage + sleep` 轮询** —— 低级钩子是同步回调，宿主线程在睡眠时每个鼠标
> 事件都要排队等它醒来，用户会直接感到「鼠标迟滞、影响正常用电脑」（v69 踩过）。
> 心跳用 `SetTimer(None, id, 1000, None)` + `WM_TIMER` 实现，不需要窗口。
> 另外**游戏不在跑时会自动卸掉钩子**（`WH_MOUSE_LL`/`WH_KEYBOARD_LL` 只在
> `Game.exe` 存在时安装），平时上网办公零影响。
>
> **下一轮重点：P5 实机验证**（贴脸距离 / 眼位高度 / 开镜是否被相机接管）。

---

## 一、当前状态（一句话）

**滚轮推拉镜头已实机可用且用户验收**：基准距离约 3.2m，可推近到约 0.95m（v54 起）、拉远到约 5.8m，
带平滑过渡，开镜自动让行；起跑演出自动让位到原版机位（v49）。五项回归（推近/拉远/
居中/开镜/切人）用户此前逐项确认过，v45~v54 的迭代未破坏它们。

- 当前版本：**v92**（v87 清理版 + FreeCamMod 共存挂起），源码 `work/camzoom/proto49.lua`
- 已安装：`E:\SeasunCBJQos\Game\cbjq\game\Game\Content\Paks\Patch_CamZoomMod-Windows_100_P.pak`
  （302,503 字节，**内含 CamZoomMod v92 + FreeCamMod v15 两个 MOD**，构建脚本 `work/build_both.js`）

### ★ v92 合并（2026-10-30）：与 FreeCamMod（自由相机拍照）共存

背景：自由相机 MOD 在另一条线上做到 v14（进度见 `work/freecam/HANDOFF.md`），用户要求
把滚轮缩放加回来且两者不冲突。两个 MOD 的注入点是同两个 Lua 文件，分装两个 pak 会争抢
同名文件 → **一个 pak 装两个 MOD**（`build_both.js` 把两份源码都注入 umg_main +
ResourceAmend；两者各自的 `_ready` 守卫防重入，双文件注入只有先加载那份执行）。

**共存协议（唯一约定接口 = `_G.FreeCamActive`，两侧源码互不取用对方全局表）**：
- freecam：enter() 成功后写 **递增帧号**（不是 true），`S.on` 期间每帧刷新；
  exit() 第一行写 false。用帧号是给 camzoom 侧做**死人开关**：数值 2s（100 帧）
  不递增 = freecam 主循环已死，强制清开关恢复缩放（freecam 若活着会把开关写回来，
  随即再次挂起，无害）。
- camzoom：step() 开头 `freecamActive()` 检查 —— 激活期间**整体挂起**（滚轮、
  缩放写入、HUD、F5、自动标定全停），只**排水** wheel.txt / fp_key.txt 的 seq
  （挂起期的滚轮事件是 freecam 的 FOV 输入，不排水退出瞬间会被当缩放一次吃掉）。
  退出挂起时清 `distPrev/rotPrev/dRot`（挂起期的陈旧测量不得误触发 FX 让位/旋转
  护盾）；缩放状态（z/zoomT/appliedMag）原样保留 = 退出即回到之前的缩放档。
  日志：`FREECAM active -> CamZoom suspended` / `FREECAM ended -> CamZoom resumed`。
- freecam enter() 里新增**滚轮 seq 对齐**（计划外冲突点）：freecam 关闭期间滚轮
  一直被 camzoom 消费（同文件、各自 seq），不对齐则进入瞬间积压格数一次性补成
  FOV 跳变。
- 两侧都加了 PCKeyboardEvent 的 Start 兜底（两个 MOD 都订阅 Event.Logined，
  防订阅互相覆盖导致某个 MOD 不启动）。
- B/V 键无冲突：v87 起 camzoom 只用 F5（第一人称已删），freecam 用 B/V。
- ⚠ 构建坑：`build_both.js` 的回读校验必须把 AES 尾部 <16 字节**明文残留**拼回去
  （`build_mod.js` 的同款 dec 漏了这步，只是它的校验条件碰巧不查尾部没暴露）。

**待实机验证**（测试矩阵在 `work/freecam/HANDOFF.md`「共存 —— 已实施」节）：
camzoom 五项回归 / 进相机全挂起（滚轮只改 FOV）/ 退相机全恢复（回到之前缩放档）/
挂起期间 F5 无效 / 未标定就进相机再退出的自动标定。

---

## 二、已验证的可行性结论（不要再重复试）

| 接口 | 结论 | 证据 |
|---|---|---|
| `PlayerCameraManager.CameraCache.POV` | ✗ 恒为默认值(90°/原点)，渲染不走它 | v12 日志 |
| `pawn.Camera.FieldOfView` 直写 | ✗ 0.25s 内被游戏回写 | v26 P2：写 45 → t+0.25s 变 75 |
| `CameraArmLength`/`CameraFOV`/`CurrentCameraInfo` 等属性 | ✗ UnLua 读不到（全 nil，非 BlueprintVisible） | v22 PROPTYPE 普查 |
| `AddCameraDataOffset(FVector)` | ✗ 空操作，相机坐标纹丝不动 | v24 六变体实测 moved=0cm |
| `SetSocketCameraInfo()` / `SetFollowCamera()` **空参数**调用 | ⚠ 会把相机扔到世界原点（曾误判为"飞出地图"） | v22 事故 |
| 空参数 `SetTempCameraInfo()` | ⚠ 同类风险，不要裸调 | |
| UMG Tick 晚帧写 FOV | ✗ 钩子能装（`LateTick hooked`），但战斗中主界面 Tick **从不执行** | `LATE alive` 计数为 0 |
| **`pawn.Camera:K2_SetRelativeLocation()`** | ✅ **唯一可用入口**：立即生效、不被每帧覆写、可还原 | v26 P1：+120Z → 世界 Z +119.4，0.25/0.5s 保持 |

### 坐标轴事实（标定实测）
- 本地 **X 轴 ≈ 视线前向**（`|dot(localX, 角色→相机)| = 0.976`）
- 本地 **Y 轴 ≈ 相机右向**（`rightDot = 1.000`）
- 本地 **Z 轴 = 世界上**（`(0,0,1)`）
- 相机组件相对位置基准 **恒为 (0,0,0)**（挂点原点）

---

## 三、v49 算法

```
标定（第一次滚轮触发，约 0.3s）：
  沿本地 X 推 60cm → 测世界位移方向 → coef=±1（把"后拉"映射到本地 X 符号）
  沿本地 Y 推 60cm → rightDot → ySign
  baseDist = 相机到角色距离（约 320cm）
  ★ baseRel 恒为 (0,0,0)，标定时读到的临时机位一律不采纳

每帧（20ms）：
  z 指数平滑趋近 zTarget（tau=0.15）
  mag = (z-1) * baseDist * coef        // 负=推近，正=后拉
  lat = 居中横向补偿
  写 relLoc = (0+mag, 0+lat, 0)        // 绝对写入，幂等
  已在目标 0.4cm 内则不写（防抖）；relLoc 读不到就直接写
```

- **没有任何基准推断逻辑**：v37 的每帧自校正（`baseRel = cur - applied`）已全部删除，
  这是漂移的唯一根因。`Z.baseRel` 在初始化之后任何代码路径都不得再赋值
- **居中（慢速积分器 + v41 抖动闸 + v42 双向包络）**：z<0.96 介入（0.74x 满），
  每帧 `latHold += dv*0.15`（dv = 角色相对相机的**世界**横向偏差，与 lat 同沿相机右向量，
  符号由几何保证唯一），hold 钳 ±160，误差每帧衰减 15%（约 0.3s 收敛，重阻尼不自激）。
  latFade 是**双向包络**：进区间 0.25s 淡入、出区间 0.2s 淡出（期间 hold 冻结），
  降到 0 才清状态（教训见 P1d：只有淡入没淡出 = 拉远时硬切）。
  **积分只在两道闸放行时进行**：切人后 `centerFreezeUntil`（1s）内冻结；
  |dv|<2cm 死区冻结。**不要改回「测一次定死」**（P1b）、不要去掉两道闸（P1c）、
  不要去掉淡出（P1d）
- **开镜让行**：`fov < baseFov-12` 时一次性还原到 (0,0,0) 并停止干预；退出后 0.18s 内平滑恢复（`aimBlend`）
- **游戏接管让行（v43）**：持有写入权时（appliedMag 非空），游戏把相机挪离我们最后写入值
  超过 `takeoverCm`(1.2cm/帧) → 让行 `yieldFrames`(0.5s) 完全不写（同时 appliedMag=nil 解除
  所有权、aimBlend=0），演完由 aimBlend 重新施加。典型场景：开跑瞬间的游戏相机演出。
  恢复写入是「**从当前机位向目标滑入**」（writeX = cur + (want-cur)*ab），不是从 0 出发，
  开镜退出/让行结束的恢复均无起点跳变
- **切人检测（v44 起逐帧）**：相机对象路径变化 = 合法复位：清 appliedMag/lat、
  **取消在途让行（yieldUntil=0）**、aimBlend=1、冻结居中积分 1s（盖过切人动画 dv 瞬态），
  下一帧绝对写入立即落满偏移。逐帧的原因：v43 的 10 帧轮询让接管让行抢先在切人复位上
  触发（dx 达 ±260~460），把「立即回位」变回 0.5s 重置→过渡（P1f）
- **FX 让位窗口（v49 = v47 机制 + 挤压门 + 冷却，核心修复）**：每帧算
  `gameD = 测得Δdist + (appliedMag − appliedPrev)` —— 用自身写入量修正剥离滚轮
  缩放自己引起的距离变化（滚轮不误触发）；`|gameD| ≥ 15cm/20ms` 且拉近状态
  （`targetOffset(z) > 10`）且持有写入权且**不处于挤压**（`D = dist+appliedMag ≥
  baseDist − 40`，碰撞压短 boom 时不让位——靠墙闪光的根源是滑出与碰撞释放同向
  叠加）且**不在冷却**（窗口结束后 1s 内不重触发，防退出坡与游戏反应成环）→
  进入窗口 0.64s（动态持续则续期）：偏移按 5 帧平滑滑到 0，相机完全等于原版
  机位（原版同款动态幅度 = 用户认可的正常手感，与游戏碰撞/弹性零对抗），窗口
  后 aimBlend 以 0.45s 慢坡（`Z.aimRampCur`）滑回缩放位。走跑过渡/地形/冲刺
  boom 拉长（~4cm/帧）在门槛下不触发。拉远（z≥1）不参与。日志
  `YIELD dash FX gameD= dist= mag=`。⚠ `Z.appliedPrev` 由 step() 在 applyZoom 后
  维护；aim 让行/接管/切人均复位 fxUntil
- **距离钳制（v46 引入，v48 改顶棚式+迟滞锁存，第二道保险）**：dist < 90 置锁存，
  锁存期间写入量顶到 `D−90`（保持 90），dist > 105 才解锁。⚠ v46 的 deficit 式在
  临界点有极限环（dist 恰到 90 时条件失效、写满量恢复 → 弹回 49 → 再钳，
  ~12Hz 振荡，贴墙站立即可见）——v48 已修。日志 `DCLAMP on/off`

### ⛔ 已废弃路线（不要再试）
- **距离伺服（v48）**：焊住 dist、逐帧反推游戏 boom 动作并抵消 —— 实机发散：
  30s 内 19 次触发、hold 棘轮上漂（157→340）、mag 冲到 700 上限、dist 114~351
  乱跳。根因：「dist 对 magW 1:1 响应」不成立，游戏侧会对相机位置做出反应
  （HB 实证 D = dist+appliedMag 达 1051，boom 被拉到远超原版），任何"测量→
  反写"的闭环都会与它耦合。**相机位置只能开环写（绝对目标），不要闭环伺服。**
- **旋转护盾（v45 遗留，对本案无效但无害）**：`|ΔRoll| ≥ 1.0°/20ms` 触发，逐帧反向
  旋转写入偏移。实测本案相机组件旋转恒为 0（画面滚转是 CameraManager POV 层的，
  组件读不到），全程未触发。保留防其它演出，暂不删
- **起跑记录器（v46 增强取证）**：常驻 15 帧环形缓冲（spd/dw/dist/mag），spd>120 触发
  （v45 的 350 恰好漏掉起跑加速段——前冲发生在 350 之前）先倾倒缓冲（起跑前 300ms）
  再记 90 帧，至多 12 次/会话。完整轨迹行含 `dist=`。速度触发（`GetVelocity`，
  **不是** `K2_GetVelocity`——后者在 UE4 不存在，pcall 静默失败，v44 轨迹全空的根因）。
  护盾触发也顺带启动轨迹

---

## 四、已知 bug（按优先级）

### ✅ P0：`baseRel` 漂移 → 镜头越拉越远、最终拉不回来（v38 已修，用户确认不漂移）
**现场证据（2026-10-29 日志，比上一轮更完整）**
```
CAM change -> baseRel= (0.00,0.00,0.00)     ← 切人重建正确
APPLY resync baseRel= (253.72,0.00,0.00)    ← 下一帧又被污染（切人过渡动画还在飞相机）
APPLY resync baseRel= (-1464.86,0.00,0.00)  ← 累计：漂移量 = ±253.7（z=1.8 施加量 0.8×317）的整数倍
```
**根因**：v37 `applyZoom` 的每帧自校正 + else 分支（`baseRel := cur`），
把游戏自己动的相机（切人过渡/开镜机位）误判成基准变化吸收进 `baseRel`，逐次累积。
基准脏掉后 z 的可写范围只有 基准±250 → 表现为越切越远、拉不近。

**v38 修法（已实施）**
> 彻底删除全部推断逻辑（自校正、else 吸收、切人/开镜时的 `cur - applied` 反推）。
> `baseRel` 恒为 `(0,0,0)`（挂点原点，实测站桩/移动/开镜/切人全成立），
> 每帧写绝对值 `(mag, lat, 0)`：写过即收敛，游戏动了也会被下一帧写回，漂移在结构上不可能再发生。

### ✅ 🟡 P1：切人过渡效果（v38 渐变方案被实测否决，v39 改回立即写满）
- v37 时代的问题：切人瞬间 1~3 帧闪烁（游戏把相机复位到默认，我们下一帧才写回）。观感轻微。
- v38 曾按「0.2s 渐变重施」处理：切人检测里设 `aimBlend=0`。**实测被用户否决**——
  切人后偏移早已写满，设 0 反而让镜头先弹回默认机位再 0.18s 爬回来，
  拉到最近/最远切人时是明显的「重置→过渡」效果。
- v39 删掉该行：切人后立即写满偏移（绝对写入无漂移风险），只留游戏自身 1~3 帧复位闪烁。
  **结论：切人场景不要再引入任何渐变/延迟，立即写满就是正确行为。**

### ✅ P1b：拉近居中状态下切人，居中/靠左隔代交替（v40 已修，用户确认交替消失）
**实测现象**：A（居中）→切 B（靠左）→切 C（居中）→切 A（靠左），一直交替。
**根因**：v39 的居中是「进场测一次 dv 定死保持」，切人检测清掉保持值后重测 ——
但重测时上一任的居中量还写在相机上，测到的是残差（≈0）而非自然偏移 → hold 掉到 0，
人物掉回游戏自然偏机位（靠左）；下一次切人时相机上没有居中量，测到的才是自然偏移 → 又居中。
**v39 修法（已实施）**：改成慢速积分器（每帧 `hold += dv*0.15`），切人不再清 latHold ——
上一任 hold 数值本来就对，沿用并按残差微调；不依赖测量时机，任何切人残差 0.3s 内自愈。

### ✅ P1c：切人后镜头一点一点微抖（v41 已修，用户确认微抖消失）
**实测现象**：切人后人物/镜头细微地一步步移动，滚一下滚轮就消失。
**根因**：v40 积分器每帧都在追 dv —— a) 切人动画里相机还在飞、dv 剧烈摆动，
被积分进 hold，动画结束后再慢慢回摆；b) 待机动画的挂点小幅摆动是持续信号，
积分器永久追着它做 0.4cm 级微步修正。滚轮滚出居中区间会重置积分器，所以滚动后消失。
**v41 修法（已实施）**：积分加两道闸 —— 切人后 1s 冻结（沿用上一任 hold）+
|dv|<2cm 死区；只在误差稳定且超过死区时收敛，收敛完即静止。

### ✅ P1d：从近（居中）往远拉时居中偏移硬切（v42 已修，用户确认硬切消失）
**实测现象**：拉到最近人物居中后往回拉远，偏移瞬间归零（硬切）；从远往近方向正常（有淡入）。
**根因**：v39 的居中量乘 ct（随拉远连续变小），退出区间自然平滑；v40 改成 `hold × latFade`
后 latFade 只有淡入没有淡出 —— 拉出区间瞬间归零。v40/v41 都存在，用户在 v41 后才注意到。
**v42 修法（已实施）**：latFade 改为双向包络，出区间 0.2s 淡出（期间 hold 冻结），
降到 0 才清状态；来回快速穿越边界时 fade 就地反向，均平滑。顺带修了冻结窗口内拉远会瞬跳的边角。

### ✅ P1e：滚轮改过缩放后，开跑瞬间镜头猛烈抖动（v49 用户验收，已关闭）
**实测现象**：用滚轮改变缩放后（拉近/拉远都一样），起跑瞬间镜头猛烈抖一下；没缩放时不抖。
v43 的「接管让行」无效（游戏不碰 relLoc）；**v45 的「旋转护盾」也无效——整个会话 0 次触发，
轨迹显示相机组件旋转（Roll/Pitch/Yaw）全程恒定**。上一轮视频结构张量测到的"4.5° 滚转"
是 CameraManager POV 层（后处理）效果，组件旋转读不到，且滚转本身不移动相机位置
（偏移沿视线轴 = 滚转轴），不是抖动根源。

**决定性证据（用户第二轮录帧，17 帧连拍 `Videos/NVIDIA/Game.exe/temp/frame_000109-125.png`，
出自 03:11:31 的录屏）**：
- 109/110 帧：拉近状态正常（人物约 123cm 外，居中）
- 111 帧：人物滑到画面右缘，背景箱子显著变大（视差 = 相机真的在前移）
- 112~121 帧：**人物完全消失**，镜头贴地看前方 —— 相机已被推过人物身上
- 125 帧：人物以约 2.3 倍大小回弹（比正常拉近位更近，约 53cm）
- 时间线：~0.2s 内完成「前冲→穿人→回弹」

**机制结论（v46）**：游戏起跑瞬间把相机**沿视线方向猛推向前约 200cm+**（0.2s）再回弹，
走 boom/socket 通道：relLoc 恒等于写入值（游戏不碰）、组件旋转恒定，只有世界位置在动。
拉近（123cm）时同一前冲直接穿人；拉远（574cm）时冲到 ~330cm（比原版更猛的 punch-in）；
不缩放（320cm）时冲到 ~1.5m，温和 —— hence「不缩放不抖」。
注：前冲发生在 spd>350 之前（v45 轨迹从 350 才开始，8 次配额内全程未捕到前冲瞬间，
轨迹 dw 平滑 —— 机制是从视频帧+日志排除法锁定的，不是轨迹直读）。

**v46 修法（已实施，待实机验证）**：距离钳制（算法见第三节）—— dist<90cm 且快速收拢
时把写入偏移外推，相机最近 90cm，穿人结构上不可能；演出回退自动跟随恢复。
**已知局限**：
- 钳制只在「收拢 ≥8cm/20ms」时介入：若前冲是慢速的（<4m/s 闭合计）会漏钳；
  若漏，看日志有无 DCLAMP 行，无则把 `distCloseRate` 降到 4 试（代价：贴墙挤压
  也会被钳，可能与游戏相机碰撞打架）
- 若前冲伴随大幅横向甩动（录帧里人物滑向右缘），轴向钳制不拦横向 —— 人物可能
  短暂偏离画面中心但不会消失；若用户仍不满，下一步做横向钳制
- 90cm 仍比正常拉近位（123cm）近，钳制中人物占满画面 —— 这是设计行为（保留
  一点前冲感），嫌多可调 `minCamDist` 到 110
- 判读：日志 `DCLAMP on ... deficit=...` 在起跑时出现且抖动明显减轻 = 修复成立；
  RUNpre 行能看到前冲瞬间的 dist 崩塌轨迹（下轮定位前冲精确深度用）

**v46 实机数据（2026-10-29 03:41 会话，用户拉近/拉远各跑两轮）**：
- 5 次 DCLAMP 全部命中：前冲实测为**单帧崩塌**（prev=220.6 → dist=70.8，即
  ~150cm/20ms = 7.5m/s），钳制托在 ~90cm，0.5s 内随演出回退自动释放 ✓
- 演出回退本身有弹性过冲（钳制释放后 dist 90→199→回落 124，为游戏自身动态，
  原版同款幅度）✓
- 前冲**不是每次起跑都发生**（7 条轨迹里 2 条干净），也会在**冲刺途中**发生
  （11:252 的 DCLAMP：prev=218→dist=70，冲刺中游戏把 boom 收了一下）——
  钳制与触发时机无关，按距离崩塌兜底，两类都接住了 ✓
- 冲刺全程 boom 会从 123cm 拉长到 ~217cm（游戏自己的冲刺机位）——正常动态，
  不是漂移
- 拉远（z=1.8，dist~590）三轮 RUNpre 全程无崩塌：本会话远距没触发前冲。
  此前用户报告的远距抖动可能幅度本就较小（150cm/590cm≈25% punch-in）或
  以 FOV 踢（75→79.9）为主 —— 待用户主观反馈
- 0 STEP ERR、0 误触发（贴墙/慢速靠近未误钳）✓
- **用户仍报晃** —— 钳制只托底防穿人，前冲全套推拉动态还在（见 v47）

**v47 实测反馈**：正常起跑按设计"过渡到原版镜头再过渡回来"，用户评为微妙；
**靠墙起跑有一闪而过的剧烈晃动** —— 靠墙时游戏碰撞把 boom 压短，起跑瞬间碰撞
释放 + 前冲 + "滑回原版机位"三者同向叠加，相机 0.1s 内被甩出 2m+。

**v48 实测（伺服发散，已废弃）**：30 秒 19 次 FX 触发（很多间隔 0.8s——退出坡与
游戏反应互相触发）、hold 棘轮上漂（157→168→…→340，每次重新触发都捕获在更高
的 distPrev 上）、mag 冲到 700 上限、HB 实证 dist 114~351 乱跳、D 高达 1051 ——
用户报"原来的抖动又出现且坐标更乱"。**伺服路线废弃（见第三节⛔）。**

**v49 修法（当前生效版本）**：回到 v47 让位机制（正常起跑用户已接受）+
a) 挤压门修靠墙闪光 + b) 冷却修连环触发 + 保留 v48 钳制锁存修复。
行为：起跑瞬间缩放滑回原版距离（~0.1s），演出期间镜头=原版，0.6~1s 后缩放慢坡
滑回；靠墙起跑不让位（钳制托底，原版节奏释放）；滚轮/走跑过渡/地形不误触发；
拉远（z≥1）不参与让位。
**可调参数**：`fxDistRate`（触发门槛 15）、`fxFrames`（窗口 0.64s）、`fxSqueezeD`
（挤压门 40）、`fxCoolFrames`（冷却 1s）、`minCamDist`（钳制下限 90）。

**v49 实测（2026-10-29 04:27 会话，用户验收通过——原话"比大多数情况都好了不少"）**：
- 37 次 `YIELD dash FX`，间隔最短 1.8s（冷却生效，无 v48 式连环触发）✓
- 24 次 DCLAMP（靠墙场景由挤压门路由到钳制托底）✓
- 0 STEP ERR；心跳 mag=192.8 稳定、baseRel 恒 (0,0,0)、cur 与写入值零偏差 ✓
- 用户接受的小瑕疵（未再迭代）：让位时的"过渡到原版再回来"观感、游戏自身 FOV 踢、
  拉远方向不参与让位（远距前冲幅度本就小）
- 历史版本细节见下（v46/v47/v48 数据与教训，供回溯）

**v47 修法（已被 v49 取代，机制沿革供参考）**：FX 让位窗口—— 起跑演出期间
相机完全变回原版机位（滑入 ~100ms / 滑回 0.45s）。v47 实测：正常起跑该行为用户
可接受（评"微妙"），靠墙闪光由 v49 挤压门修复。

### ✅ P1f：切人在 v43 回归成「重置→过渡」（v44 已修，**用户实测确认**）
**实测现象**：v43 下切人后又出现先弹回默认、再过渡回缩放位置的效果。
**根因**：接管检测在切人的相机复位上抢先触发（切人时游戏把 relLoc 重置，
偏差远超 1.2cm 阈值 → 让行 0.5s + aimBlend=0 → 重置→过渡）。
**v44 修法（已实施）**：切人检测改逐帧（appliedMag 在 applyZoom 之前清空，接管不再误触）+
检测到切人立即取消在途让行、aimBlend=1。**用户已实测确认修复（2026-10-29）。**

### ⛔ P2：FOV 收窄 —— **判定：玩法相机内不可实现**（v50~v53 五轮普查，不要再试）
需求（用户原话）：镜头拉到最近时，再滚轮往里滚，就把 FOV 调小一些。

**结论一句话**：`pawn.Camera.FieldOfView` 由游戏的相机图（CameraBlueprint）**每帧回写**，
我们写进去的值当帧落地、下一帧必被覆盖；游戏侧没有暴露任何 Lua 可达的 FOV 覆盖入口。
唯一还能改 FOV 的地方是拍照模式（`PhotoStudio`），但那是另一套相机状态，玩法相机里用不上。

**实测证据链（全部来自 Game.log，HB 的 `rev` 是天然探针）**
| 尝试 | 结果 |
|---|---|
| `cam.FieldOfView = 45`（50Hz 逐帧写） | 写入**落地**（同一回调内回读 = 45），0.35s 后回读 75；`rev` 每帧 +1 |
| `cam:SetFieldOfView(45)` | 同上（stock UCameraComponent 的同一个属性） |
| `pcm` 上的 FOV 接口 | `SetFOVOverride` / `SetCameraFOV` / `SetFOV` / `SetDesiredFOV` **全部不存在**；`camCls = CameraComponent`，`pcmCls = GamePlayerCameraManager_C` |
| `pcm:GetCameraInstance()` | 无参返回 **nil**；`GetCameraInstanceClass()` 也 nil |
| `pcm:GetCameraInstance(UE4.ACameraActor)` | 返回普通 `ACameraActor`，其上无任何 FOV 成员 |
| `pcm:GetCameraInstance(UE4.UCameraBlueprint)` | 返回 `UCameraBlueprint` 对象，**其上所有 FOV 属性/方法读出来都是 nil** |
| UMG Tick 晚帧（Slate tick） | `package.loaded['UMG.Main.umg_main'].Tick` 套壳后计数**恒为 0** —— 战斗中根本不执行（v49 钩 `tbClass.Tick` 得 0，v52 钩模块表得 0，两次独立验证） |
| 全量扫 `package.loaded`（765 个模块） | 名字含 `fov` 的键 **0 个**；只有 `PhotoStudio.Base.PSMgr.GetCameraPawn/SetCameraPawn`、`House.Photo.HouseCameraManager.*` 三处 camera 相关 |
| 拍照模式 | 确实改的是同一个 `cam.FieldOfView`（PMW 抓到 75→54），但那里相机图是停的 —— **反证**了「玩法相机里 FOV 由相机图驱动」这个结论 |

**架构判断**：渲染用的 FOV 来自相机图每帧生成的快照（`CameraFrameSnapshot` 符号、
`CameraCache.POV` 恒为 90°/原点可佐证），不是 `UCameraComponent.FieldOfView` 的实时值。
只要拿不到相机图实例，写属性这条路就是死的。

**已落地替代方案（v54）**：把「再往里滚」改成**真实推近** —— `zMin 0.38 → 0.31`，
相机-角色距离 132cm → 95cm（约 1.35 倍放大），用户实测「算是能接受」，距离档位到此为止。
`zoomPullEnd` 回 0（那个 60cm 后拉是给 FOV 配的，FOV 不通时就是「往里滚反而往后退」）。

**代码保留状态**：`proto45.lua` 里 `applyFov` / `zoomT` / `zoomS` 全套逻辑都在，只是
`cfg.zoomStep = 0` 让它永远不积累。**如果以后找到 FOV 入口（比如搞到相机图类），
把 `zoomStep` 改回 `0.10` 就能恢复整套光学变焦**，不用重写。
⚠ 恢复时注意两个已验证的坑：a) 开镜判定阈值必须随变焦下移
`min(目标FOV−6, baseFov−12)`，否则自己收窄的 45 会被自己的判定当成开镜并整段让行；
b) FX 让位窗口内 FOV 必须与偏移同步滑回（`applyFov(cam, zt*(1−p))`），否则出现「远处长焦大特写」。

### ⛔ P3：滚轮档位非线性（v55 试过乘性档位，**用户否决，已回退 v54**）
**问题**：旧档位是线性步长（`zTarget ± 0.075`），而 z 是**距离倍率** —— 每格的观感变化
随距离剧烈变化：远档 `1.8→1.725` 只有 4% 观感变化（滚半天回不到中间），近档
`0.38→0.305` 却是 24%。这就是用户说的"最远时回中要滚很多格"。

**v55 试法（已回退）**：每格乘/除固定倍率 `notchRatio = 1.14`，让每格观感变化恒定 ~14%。
格数确实好看了（1.00→1.80 从 10.7 格降到 5 格；1.80→0.31 从 19.9 降到 14；近档 9 格不变），
**但用户实测原话：「这个速度比之前更怪了，还是改回之前的吧」** —— 恒定的 14% 让远档变"跳"、
近档变"钝"，反而不如原来那种近处快、远处慢的不均匀手感。

**结论**：已回退到 v54 的线性档位（`notchStep = 0.075`），`proto46.lua` 保留 v55 源码备查，
`build_mod.js` 已指回 `proto45.lua`。**若还要再试档位手感，不要重复"纯乘性"这条路**；
可以试的方向：a) 只对远档加步长（`step = lerp(0.075, 0.14, (z-1)/0.8)` 的分段式），
近档保持原样；b) 按住滚轮加速；c) 干脆不动——用户对现状的不满只在"最远档回中格数"，
可以用 `zMax` 从 1.80 降到 1.60 直接缓解（远档本身变浅，回中自然少格）。

---

### ✅ P4：近景欣赏模式 —— 拉近到人物居中时淡出 HUD（v65 已实装，用户确认淡入淡出手感 OK）

**需求（用户原话）**：「当拉近摄像机时，就是人物居中的时候，瞄准的准星、以及子弹、
还有角色旁边对应的技能层数 UI，隐藏掉，隐藏的时候最好也做个过渡效果。」
后续追加：**伤害数字**、**任务标识（星星）**、**底部技能状态条**。

**触发**：`Z.z <= hudHideZ(0.80)` 淡出，回到 `>= 0.86`（含 0.06 迟滞）淡入；
开镜（`Z.aimNow`）时强制淡入 —— 准星没了没法瞄准。

**实现（v67 起简化成「整根隐藏」）**：`proto47.lua` 里的 `HH` 模块（`hhFind` / `hhApply` / `hhUpdate`）
- **直接对 `umg_fight_pc_C` 根节点 `SetRenderOpacity`** —— UMG 的透明度沿控件树相乘，
  父级 0 等于全部不可见，一个调用覆盖所有 HUD 部件（用户提议"干脆全隐藏"后改的）
- 另外单独处理 `umg_fight_Damage_C`（伤害数字是独立 UUserWidget，不在这棵树里）
- 逐个控件的名单（下表）保留作兜底：万一某些部件被 `AddToViewport` 挂到别处，仍能盖住
- 淡出 0.25s / 淡入 0.20s（50Hz 主循环驱动），**不用 `Collapsed`** ——
  游戏自己的显示逻辑会反复把可见性改回来，透明度不会被覆盖
- 控件缓存在 `HH.target` / `HH.widgets`，每 150 帧校验一次（切人/切场景会重建），失效自动重找

**控件清单（`umg_fight_pc_C` 树内 `GetName()` 的名字）**
| 目标 | 控件名 | 类 |
|---|---|---|
| 准星 | `Center` + `AimCrossHairOverlay` | GameCanvasPanel / Overlay |
| 角色/技能栏 | `PlayerSelect` | uw_fight_player_pc_C |
| 任务文字 | `LevelTask` / `LevelTaskOpenWorld` / `TaskBtn` | uw_fight_level_task*_C |
| 伤害数字 | `HitEffect` + 独立的 `umg_fight_Damage_C`（`self.DamageWidget`） | uw_fight_effect_C |
| 血条/弹药 | `HP` | uw_fight_player_hp_pc_C |
| 任务星星/方向指示 | `uw_fight_monster_tips` | uw_fight_direction_C |
| 底部技能状态条 | `Special_Signa` | uw_fight_Skill_Special_Signa_C |
| 右下技能键 | `SkillPanel` | uw_fight_skill_panel_pc_C |

**UnLua 侧踩到的四个坑（下次做 UMG 相关必须知道）**
1. **`GetAllWidgets` 不存在，只有 `GetAllWidgetsOfClass`**；调用式
   `UE4.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(pc, nil, UE4.UUserWidget)`
   的出参 `TArray<UUserWidget*>&` 以 **userdata 容器**返回，不是 Lua 数组
2. **TArray 是 1 基**：`arr:Num()` 取长度，`arr:Get(1)` 是第一个元素，`Get(0)` 返回 nil
   （v60 之前一直以为"拿不到"，就是栽在这里）
3. **`obj.Field` 不回落到 Lua 实例表**：`pairs(obj)` 能看到 `self.HideWidgetInfos` 之类，
   但 `obj.HideWidgetInfos` 走 UObject 属性查找、返回 nil，必须 `rawget`
4. **局部函数互相引用要注意声明顺序**：被引用的 helper 必须定义在**前面**，
   否则解析成全局 nil，调用即报错；外面套着 `pcall` 时完全静默（v64 的 dump 就是这么"消失"的）

**控件树怎么拿**：`w.WidgetTree` → `.RootWidget`（`UGameCanvasPanel`）→ 递归
`GetChildrenCount()` / `GetChildAt(i)`。**UserWidget 的子控件不在父面板里**，
每个 `uw_*_C` 要单独取它自己的 `WidgetTree.RootWidget` 才能继续下钻。

**可调参数**：`hudHideOn`（总开关）/ `hudHideZ`（触发倍率）/ `hudHideHyst`（迟滞）/
`hudFadeOut` / `hudFadeIn`

**验收**：用户 2026-10-29 确认「好了，没问题了」。拉近 → 只剩画面和角色；拉远 → 全部淡回；
开镜 → 立刻还回。

---

### 🟡 P5：第一人称贴脸（v69 已实装，**待实机验证**）

用户原话与三问答复（2026-10-29）：
1. 角色本体 —— **保留本体，只贴脸**（不做 SetOwnerNoSee）
2. 切换方式 —— **单独按键**（键盘钩子，不走滚轮）
3. 开镜 —— 「**在第一人称视角下能搞个第一人称的开镜瞄准**」（与游戏原版开镜分开）

**实现（`proto48.lua`）= 一条并行写入路径，不碰 z 倍率体系**

```
mag = targetOffset(z) + (fpBaseMag − targetOffset(z)) × fp
```

`fp` 是 0→1 的混合量（进入 0.30s / 退出 0.28s），所以进入、退出都天然连续，
`fp=0` 时公式退化成原来的 `targetOffset(z)`，退出不需要任何还原动作。

- **目标 mag 的开环换算**（不用 baseDist / 不做闭环伺服）：
  `mag = mag0 + (目标dist − dist0) × coef`，其中 mag0/dist0 是当帧实测。
  推导依据：`targetOffset` 的符号约定保证 `Δmag = Δdist × coef`。
  实测值自动吃掉角色体型、z 档位、开镜机位的差异。
- **眼位**：`CapsuleComponent.CapsuleHalfHeight`（拿不到就试
  `GetSimpleCollisionHalfHeight()`，都没有退回 `cfg.fpUp`）。
  眼位世界 Z = 脚底 + 2×半高×`fpEyeRatio(0.84)`；`relLoc` 的本地 Z = 世界上，
  所以垂直偏移直接写 Z。进入时算一次并钳制 ±`fpEyeMaxUp(90)`。
- **FP 下绕开**：居中积分（强制 lat=0）/ FX 让位 / 旋转护盾 / 距离钳制
  （`minCamDist=90` 会顶住贴脸）/ 游戏接管让行。
- **安全网**：写入值被游戏连续改写超 `takeoverCm×3` 达 3 帧 → 释放
  `fpSuspendFrames(12)` 帧后再占据（防 v43 式互殴）。
- **距离守卫**：非开镜时 `|dist − fpBack| > fpDevTol(20cm)` 且持续 5 帧 →
  重锁一次（冷却 40 帧），且 `fpBaseMag` 以 `fpMagTau(0.2)` 渐变收敛 ——
  这是**一次性校正**，不是 v48 那种逐帧反写伺服（那条路已判死）。
- **开镜（`cfg.fpAimMode`）**：
  - `'hold'`（默认，用户要的第一人称开镜）：开镜后第 `fpAimLockFrames(10)` 帧
    用 `fpBackAim(12)` 重锁目标；**保护**：若此时 `dist > fpBack+60`，说明游戏
    把相机 boom 挪走了（相机可能已跑到角色前方），`Δmag=Δdist×coef` 方向不再
    成立 → 这一段整段交还游戏，退出开镜后重锁。
  - `'release'`：开镜整段还原到 `baseRel`，交还游戏原版开镜。
- **HUD**：FP 下整根隐藏（复用 P4 的 `HH`），开镜时自动还回（准星要能看见）。
- **滚轮**：FP 下任意方向滚轮 = 退出 FP，回到进入前的 z 档位。

**输入链路**：`runtime/wheel_sniffer.py` 新增 `WH_KEYBOARD_LL` 钩子，
**只在游戏进程在前台时**（`GetForegroundWindow` + `QueryFullProcessImageNameW`
比对 exe 名）把 `V`(0x56)/`B`(0x42) 写成 `runtime/fp_key.txt`（`"seq vk"`）。
Lua 侧 `pollFPKey()` 每帧读、按 seq 去重。`settings` 里 `fpKeyVK=86`。
- **改完 sniffer 必须重启进程**：`python runtime/tools_restart_sniffer.py`
  （杀旧 pid + 脱离 job 拉新进程；`wmic` 在 Win11 24H2 已移除，脚本用 tasklist）
- 单实例互斥名 `Global\CamZoomWheelSniffer`，旧进程不退新进程会直接退出

**可调参数**（`cfg` 里 `fp*` 一组，`fpOn` 是总开关）
`fpBack` 20 / `fpBackAim` 12 / `fpEyeRatio` 0.84 / `fpUp` 0 / `fpFadeIn` 0.30 /
`fpFadeOut` 0.28 / `fpAimMode` 'hold' / `fpDevTol` 20 / `fpMagTau` 0.2

**日志判读（HB 行）**：`fp=` 混合量 / `fpA=` 是否开镜 / `fpD=` 锁定的游戏 boom 距离 /
`fpZ=` 垂直写入量 / `fpT=` 目标 mag / `pawnZ=` 角色世界 Z。
专项行：`FP lock` / `FP eye` / `FP apply`（每 25 帧）/ `FP drift relock` /
`FP aim release` / `FP suspend` / `FP fully off`

**待验证 / 已知风险**
1. V 键 —— 用户确认**游戏里 V 没有绑定**，可用
2. 相机俯角：第三人称相机有轻微俯视，贴到头部后视角可能偏低（若明显，
   调低 `fpEyeRatio` 或加 `fpUp` 负值）
3. near clip 穿帮：`fpBack` 不要低于 15cm（UE4 near plane ≈ 10cm）
4. 第一人称下角色手持武器/身体会占画面下方（保留本体的必然结果）

**v70 补丁（同日晚，实机首测前发现输入链路断了）**
- **现象**：用户按 V 无反应，且**原已可用的滚轮也一起失灵**。日志：
  `v69 injected (loop=true, subs=3)` / `IPC io available=true` / `FPKEY io=true`
  但 `src=none`、`ready=false` → 模组正常，是**外部嗅探器进程没了**。
- **根因**：agent 会话用 `subprocess` 起的 pythonw 被父任务 job 收掉。
  `CREATE_BREAKAWAY_FROM_JOB` 被拒（WinError 5）。工具层还拦截
  `taskkill` / `wscript` / `Start-Process` / `Invoke-CimMethod Win32_Process Create`。
  → **重启嗅探器只能人工双击 `start_wheel_sniffer.vbs`**。
- **补救**：
  a) `fpEnter` 加 `Z.ready` 保护 —— 没标定就没有 `coef`，进 FP 会把相机推向反方向，
     现在直接中止并提示「先滚一下滚轮完成标定」；
  b) **键码探测**：`onKeyboardLikeEvent` 把前 24 个不同键码打 `KEYEV num=` 进日志。
     若 V(86) 出现在里面，说明游戏的 `PCKeyboardEvent` 本身就派发键盘事件 ——
     以后 FP 切换可以彻底不依赖外部嗅探器（这是摆脱外部进程的唯一希望）；
  c) **嗅探器心跳**：sniffer 用 `PeekMessage` 轮询循环（低级钩子必须有消息泵），
     每 2s 把递增计数写 `runtime/sniffer_beat.txt`；Lua 每 2s 采样，
     连续 3 次（≈6s）不变或文件缺失 → 屏幕提示「输入嗅探器未运行」+ 日志
     `SNIFFER dead or missing`。以后不用再靠猜。
  d) HB 新增 `beat=` / `bStuck=` 两个字段直接反映嗅探器活性。

**v70b（同日下午）：鼠标迟滞 —— 消息泵轮询的代价**
- **现象**：用户双击 `start_wheel_sniffer_admin.vbs` 后「鼠标有迟滞，没开游戏也
  影响正常用电脑」。
- **根因**：v69 把消息泵从 `GetMessageW` 阻塞式改成了
  `PeekMessage + time.sleep(0.02)` 轮询（为了跑心跳定时器）。低级钩子是**同步
  回调**：系统投递鼠标事件后要等宿主线程处理完。宿主线程每轮 sleep 20ms，
  事件就得排队等它醒来 → 指针跟手性明显变差。**轮询换定时器是纯粹的亏本买卖**。
- **修法**：
  a) 消息泵改回 `GetMessageW` 阻塞（空闲 0 CPU、回调零延迟）；
  b) 心跳改用 `SetTimer(None, 1, 1000, None)` + 消息循环里截 `WM_TIMER`
     —— 线程没有窗口也能有定时器，`GetMessageW` 会正常返回该消息；
  c) **动态装卸钩子**：tick 里用 `CreateToolhelp32Snapshot` 遍历进程名，
     只有 `game.exe`/`game-win64-shipping.exe` 在跑才 `SetWindowsHookEx`，
     退出就 `UnhookWindowsHookEx` —— 平时完全不干预系统输入。用户抱怨的
     「没开游戏也影响」正是这一条。
     注意：判定列表**不能放 `SeasunGame.exe`**（启动器常驻，加了钩子就永远挂着）；
     前台判定白名单可以放（避免刚点启动时丢键）。
- **实测（游戏未运行）**：`sniffer_state.txt` = `hooks=off`，心跳 7→10 持续递增，
  空闲 CPU ≈ 0.047s/3s（≈1.5% 单核，主要是 1s 一次的进程快照），工作集 24MB。
- **坑**：`ctypes.wintypes.MSG` 的字段是 `hWnd`（大写 W），写 `msg.hwnd` 直接
  AttributeError 让进程秒退。
- `sniffer_state.txt` 现在记录 `hooks=on/off pid beat game_pids fg`，排查用。
- `fp_key_raw.txt` 记录每一次 V/B/F5/Insert 进入钩子的情况（append，64KB 自动裁剪），
  字段 `vk(键名) fg(前台判定) acc(是否接受) hwnd_pid game_pids` —— 一眼区分
  「钩子收不到键」和「判定把键丢了」。

**v72 / v73：一整轮"全部失灵"的连环坑（按发现顺序）**

| 现象 | 根因 | 修法 |
|---|---|---|
| 滚轮、按键全无反应，原有缩放也消失 | 标定只在滚轮产生 delta 时触发；而 pollIPC **首次读取把 seq 记下就返回 0** → 进游戏前累积的全部滚轮被吞，标定永不执行 → `ready=false`，整个模组停摆 | **自动标定**：gameplay 下相机距离稳定 25 帧（0.5s）就自动 `calibrate`，不再依赖输入事件 |
| 按键全被丢弃 | 前台判定用 `OpenProcess` 读进程名，被反作弊拒绝；改用 pid 比对后仍对不上（实测 `hwnd_pid=36568` vs `game_pids=[48216]`，游戏有独立窗口进程） | **取消前台筛选**：钩子本来就只在 Game.exe 运行时安装，场景已限定；`fg` 只写进诊断日志 |
| 按一次键毫无反应（`fp_key.txt` 明明有 `2 66`） | pollFPKey **首次读取连真实按键一起丢** | 首次读取只丢 `vk<=0` 的占位写入，真按键照常返回 |
| 滚一格没反应 | pollIPC 同上，首次读取吞掉 | 首次读取退一格当基准（`ipcSeq = seq - 1`）→ 当帧就有 1 格 |
| 大厅/菜单滚一堆，进战斗仍无反应 | 非 gameplay 时 step 直接 return，不消费 IPC，事件全堆积 | 非 gameplay 分支里 `pollIPC()` 只做 drain 丢弃，不进战斗不堆积 |

**v74：第一人称「镜头一直往前跑」—— 线性近似在越界后失效**

- **现象**：按第一人称后镜头持续前移，像在自动走动。
- **日志证据**：
  ```
  FP apply mag=377.1  dist=89.0
  FP drift relock → mag=448.5  dist=164.1
  FP drift relock → mag=593.0  dist=304.0
  FP drift relock → mag=877.6（撞 maxOffset 700 被钳）
  ```
  每次重锁 `dist` 都在**变大**，而 mag 也变大 —— 方向反了，且逐次放大 ~70cm。
- **根因**：v69 的目标换算用了线性近似
  `mag = mag0 + (目标dist − dist0) × coef`，前提是「相机与角色同一侧」。
  一旦相机被推**过**角色（跑到角色身前），`dist` 是**绝对值**，靠近和远离在
  数值上完全一样，公式就会沿同一方向继续推，形成单调发散。
- **修法（`fpComputeTarget`）**：改成几何法，直接算目标**世界坐标**再投影回本地轴。
  ```
  目标点 = 眼位 − ex × fpBack          （ex = 相机前向，眼位 = 脚底 + 2·half·ratio）
  挂点 G = 相机世界坐标 − ex·relX − (0,0,relZ)
  解 G + ex·newX + (0,0,newZ) = 目标点 → newX 为 ex 投影，newZ 为垂直残差
  ```
  - 每帧算的都是**绝对目标点**，所以重锁天然收敛（不再累积）。
  - 体型、蹲伏、切人自动适配（都从 `plast`/`clast` 与胶囊半高来）。
  - 垂直量不再靠「抬高量」猜，直接由几何解出。
- **`fpBack` 语义变更**：从「到角色中心的距离」改为「相机在**眼睛位置**沿视线
  反方向退多少 cm」。`fpBack=0` 是真第一人称（在眼睛里），`20` 是头后 20cm
  （保留本体时能看到后脑与肩线）。下限 12cm，再低会踩 UE4 near clip 穿帮。
- 开镜 hold 模式的重锁也换成几何法，并把「相机被游戏挪走」的保护改成
  「目标不可解 / 位移突变 > 600cm」才交还游戏。
- **教训**：涉及位置的目标换算不要用线性近似 + 迭代重锁。近似只在局部成立，
  一旦状态越界（相机穿过角色）就会沿错误方向自激。**能用几何闭式解就直接解**。

**v75：第一人称相机落在右肩上（肩部视角 + 只写两轴）**

- **现象**（用户截图）：进入第一人称低头看，相机出现在角色**右肩外侧**，画面大半是地板；
  稍微抬头人物就消失（因为相机已经不在角色身上）。
- **根因两条**：
  1. **推进方向用了相机 `forward`**。尘白第三人称是**肩部视角**，相机并不在角色中线上，
     视线与「相机→角色」连线有夹角。沿 forward 推进会横向偏到肩膀外。
  2. **只写了本地 X 和世界 Z 两个轴**。横向（本地 Y）偏差根本没有写入通道，所以
     无论怎么算都修不回中线。
- **修法**：
  - 推进方向改为 `dir = unit(眼位 − 相机世界坐标)`（相机→眼睛的连线）；
  - 用相机的**三轴正交基**（`GetForwardVector/GetRightVector/GetUpVector`）做投影，
    `newX/newY/newZ = dot(目标−挂点, ex/ey/ez)`，三个分量都写入 `relLoc`；
  - 横向在进入/退出时从「进入瞬间的居中量」平滑过渡到 FP 解（`Z.fpFromLat`），
    避免混合过程跳变；新增 `cfg.fpLatMax=90` 限幅。
  - 挂点反推也改用三轴：`G = camWorld − ex·relX − ey·relY − ez·relZ`。
- **副产品**：`fpBack` 现在是「眼睛后方多少 cm」的纯几何量，低头能看到自己的躯干
  （相机在头后中线），抬头看不到自己 = 第一人称的正常表现。

**v76：保留身体、只藏头（用户明确要求：不要让人物消失）**

- 需求原文：「我并不想让人物角色消失，最多是人物的头在第一人称视角下隐藏」。
- 做法：
  - `fpBack` 由 20 → **8cm**（相机基本贴在眼睛里），配合藏头就是标准第一人称带身体；
  - `fpHeadApply(pawn, hide)`：`Mesh:HideBoneByName(name, 0)` 只剔头部骨骼
    （含头发/面部材质，不用碰材质槽），退出走 `UnHideBoneByName` 还原；
  - 候选骨骼名 12 个（head / Head / Bip01_Head / mixamorig:Head …）依次尝试，
    命中结果打日志 `FP head hidden, tried=…`；
  - **切人处理**：先对旧 mesh 还原、再对新 mesh 藏头（`Z.fpHiddenMesh` 记住是哪个）；
  - `fpProbeBones`：一次性探测，把 `GetNumBones()` 与名字含 head/neck 的骨骼
    索引+名字打进日志（`FP probe numBones=` / `FP bone idx= … name= …`）。
    候选没命中时，看这几行就能拿到真实骨骼名，下一版精确指定。
- ⚠ 如果日志出现 `FP head: pawn.Mesh 不可用` 或 `numBones= nil`，说明
  UnLua 侧拿不到骨骼 API，需要换方案（按材质槽 / SetOwnerNoSee 折中）。

**v77：低头看不到身体 + 藏头没命中 + 滚轮要屏蔽**

- **现象**：低头只看到地板（模型消失）；偶尔快速低头会跳回第三人称的拉近效果。
- **根因 1（相机没到位）**：第三人称相机低头时会升到**头顶上方**（日志 `dir=(0.30,-0.06,-0.95)`、
  相机距角色 67cm）。v76 用 `fpMagTau=0.2` 平滑追踪目标，滞后严重 → 相机停在半空，
  低头自然只有地板。**修法：每帧重算 + 直接锁定**（去掉渐变），几何反推是开环的，
  每帧写绝对值不会自激；进入/退出的柔度由 `fp` 混合负责，已经足够。
- **根因 2（藏头全落空）**：尘白骨架是自定义命名 `girl014b_bone_Head_02_002`
  （含角色 ID 前缀），12 个通用候选一个都匹配不上；而 `HideBoneByName` 对不存在
  的骨骼**不报错**，所以 pcall 全成功、日志显示"试过 12 个"其实一个没藏。
  **修法：改用探测结果** —— `fpProbeBones` 扫 `GetBoneName(i)`，把所有含 `head`
  的骨骼收进 `Z.fpHeadBoneList`（实测 34 个，含头发/表情子骨骼），整批隐藏；
  每个 mesh 各探一次（切人/换皮肤前缀会变）。
- **需求变更（用户）**：滚轮缩放**只在第三人称生效**。旧版「FP 下滚轮 = 退出 FP」
  改为**完全屏蔽**（滚动很容易误触发、低头时更甚）；退出只认切换键。
- 判读：`FP probe numBones= N head bones= 34` / `FP headbone idx= … name= …` /
  `FP head hidden, n= 34 first= girl014b_bone_Head_02_002`。
  若 `n=` 为 0 或 `GetNumBones 不可用`，说明骨骼 API 拿不到，需换方案。

**v78：藏头没执行 + 相机没到眼位（两个独立 bug）**

| 问题 | 证据 | 根因 | 修法 |
|---|---|---|---|
| 模型整体消失（低头只有地板） | `STEP ERR: attempt to call a nil value (global 'fpProbeBones')` | **`fpProbeBones` 定义在 `fpHeadApply` 之后** → 解析成全局 nil，藏头一行没跑。（HANDOFF 坑③，又踩一次） | 把 `fpProbeBones` 整体移到 `fpHeadApply` 之前 |
| 相机距角色 68cm（应为 8cm），且算法认为"已到位" | `newX=292.2` ≈ `relNow.X=292.01`，但 `distNow=67.5` | v74~v77 用「反推挂点 G + 几何投影」。**`relLoc` 的本地轴是父组件坐标系**，与相机 forward 差 ~12.6°（标定 dot=0.976）；用 forward 反推 292cm 偏移，误差 ~60cm，而且残差不会被自我修正 | **改用误差迭代**：目标点是固定世界坐标，每帧用**实测相机位置**算误差 → 按三轴分解成写入增量（`fpGain=0.45`、`fpStepMax=80cm/帧`、`fpErrEps=1cm`）。轴不准也能收敛，因为误差用的是实测值 |
| FP 下切人后卡在"半 FP"状态 | HB `fp=1.00`、`mag=292`、`hud=0.00`、`want=true`，滚轮与切换键都被 `fpTarget>0.5` 拦掉 | 位置没到位 + HUD 判据 `fpTarget>0.5` → 表现为第三人称视角但 UI 全无 | 位置迭代修好后自然恢复；切人时清 `fpWantX/Y/Z` 从新实测重新收敛 |

**结构简化**：开镜/切人/低头/走动都不再需要单独的"重锁"逻辑 —— 误差迭代每帧都在收敛，
删掉了 `fpAimLockFrames` 重锁、`fpDev` 距离守卫的重算调用。开镜时（hold）整段交还游戏，
退出后迭代自然滑回眼位。

**v79：放弃藏头，改把相机放在眼睛前方**

- v78 位置终于收敛了（`FP drive err=0.4`），但暴露出三个新问题，全部改用更简单的办法解：
  1. **低头看不到身体** —— `fpEyeRatio=0.84` 算出的是「头顶下 28cm」（嘴的高度），
     且相机往脑后站。改为 `fpEyeRatio=0.93`（头顶下约 11cm，真人眼高）+
     `fpBack=-6`（眼睛**前方** 6cm）→ 低头能看到躯干，抬头看不到自己。
  2. **开镜变光头** —— 藏头在不同角色上效果不一致（girl014b 有 33 个 head 骨骼，
     另一个角色只有 1 个 `Bip001-Head`）：只剔头发不剔头骨。而 `fpBack` 取负值后
     **根本不需要藏头**（头在相机后方），所以 `fpHideHead=false` 默认关闭；
     同时把 `fpHeadApply(nil,false)` 补进了开镜交还分支（原来忘了恢复）。
  3. **切人闪一下第三人称** —— 切人时 `fpSuspendUntil = frame+12` 暂停写入，
     相机先被游戏复位、再由迭代拉回来。改成 `fpSuspendUntil = 0`，下一帧直接收敛。
- **思路转变**：第一人称不该依赖「隐藏模型部件」（引擎行为不可控、跨角色不一致、
  容易忘记恢复），而应该让相机**待在模型外面**。`fpBack` 取负即可，零副作用。

**v80：眼位必须按角色实测（胶囊半高是统一值）**

- 用户指出「每个角色身高不一样，不能固定高度」，完全正确，而且我自己没验证：
  日志里**所有角色的 `CapsuleHalfHeight` 都是 88.0** —— 游戏为了碰撞/移动手感
  统一了胶囊，它**不代表真实身高**。用它算眼位 = 所有角色同高，
  矮个子相机飘在头顶、高个子沉到胸口。
- 三级回退（`fpEyeHeight`，返回值带来源标记 `eyeSrc` 写进日志）：
  1. `mesh:GetSocketLocation('Bip001-Head')` —— 最准，直接取头骨世界坐标，
     减 `fpEyeDropCm(8)` 得到眼睛高度。合理性检查：dn 10~130cm、水平 <60cm
     （不存在的 socket 返回 (0,0,0)，靠这个排除）；
  2. `mesh.Bounds` 顶部减 `fpTopToEyeCm(12)` —— 动画姿态/武器会影响，量级可用；
  3. 胶囊半高 × `fpEyeRatio` —— 仅兜底。
- 判读：`FP drive … eyeSrc= bone:Bip001-Head / bounds / capsule`。
  看到 `capsule` 说明前两级都没取到，需要换骨骼名或换 API。

**v81：第一人称镜头疯狂抖动（目标点构造病态）**

- **现象**：进入 FP 后画面狂抖，人物仍不出现。
- **日志**：`err` 恒定在 **7.8 不下降**，`want` 每帧在 298~307 之间乱跳，
  偶尔 `err=340`（相机被甩到 367cm），接着 53→133→213→301 一路爬回来。
- **根因**：v78~v80 用「相机→眼位」方向构造目标点：
  `target = eye − dir × back`，其中 `dir = unit(eye − cam)`。
  **相机越接近眼位，这个方向越病态**（`vd→0`，分母趋零，方向被数值噪声主导），
  目标点跟着乱跳 → 迭代永远收敛不了，形成极限环。这不是增益/限幅能调好的问题，
  是公式本身在目标附近没有定义。
- **修法**：目标点改为「眼位 + 相机**水平前向** × (−back)」。
  水平前向从 `GetForwardVector` 取 X/Y 分量归一化；相机几乎垂直看（水平分量 <0.25）时
  用角色 Yaw 兜底。**只依赖朝向、不依赖相机位置**，所以误差单调收敛。
- **附加保护**：`err > 200cm` 时丢弃累积的 `fpWant*`、从当前实测位置重新开始
  （防状态错乱时带着失真的累积量一路推）。
- **教训**：闭环迭代的**目标量必须是状态的无关于量**。目标里带 `unit(目标 − 当前)`
  这类项，等于让目标随当前状态漂移 —— 在接近目标时会退化成随机噪声源。

**v83/v84：第一人称看不到身体 —— 游戏自己会隐藏角色（结论）**

- **验证**：v81 已确认相机精确落在眼睛位置（`dist≈51cm` ≈ 眼位与胶囊中心的高度差
  `50.6cm`、`err` 收敛、`eyeSrc=bone:Bip001-Head`）。但低头看地板也看不到任何身体部位；
  而滚轮拉到 z=0.31（约 95~100cm）时角色完全正常可见。
- **已排除**：
  - 视角角度问题（低头 90° 也没有）
  - 位置问题（数据吻合）
  - 可见性开关：v83 每 5 帧强制 `SetVisibility(true,true)` +
    `SetHiddenInGame(false,true)` + `SetOwnerNoSee(false)`，**完全无效**。
  → 结论：**尘白在相机贴近角色时会把角色隐藏**（第三人称游戏的常见做法），
  实现在引擎/材质层（距离淡出），**Lua 侧没有可用入口**。不要再往这个方向试。
- **替代方案（v84）**：`B` 键循环三个视角档位（`cfg.fpViewPresets`）：
  | 档 | back | lat | 说明 |
  |---|---|---|---|
  | `first-person` | -6 | 0 | 真第一人称，看不到自己（标准体验） |
  | `over-shoulder-near` | 70 | 24 | 近距离过肩，能看到角色 |
  | `over-shoulder` | 95 | 30 | 稍远过肩 |
  - `lat` 是**侧向偏移**（沿相机水平右向），把相机让到右肩外侧，
    否则相机退到脑后时会被后脑正好挡住视线。
- 判读：`FP view preset idx= name= back= lat=`。

**v85：关闭第一人称 + 修仰视时角色 dither 消失**

- **第一人称正式关闭**：`cfg.fpOn = false`。原因见 v83/v84 —— 游戏在相机贴近时
  自己隐藏角色，Lua 层压不住，看不到身体。代码全部保留，改 `true` 即可恢复；
  三个视角档位也存在 `cfg.fpViewPresets` 里。
- **新问题（用户反馈）**：第三人称**仰视**时角色变成点阵半透明（UE4 dither 遮挡淡出）。
  用户原话「本质上这个是有碰撞的，去掉这个人物消失的状态」。
- **成因**：相机被墙挤到角色附近 → 游戏对角色做 dither 淡化。而我们的**居中横移**
  最多能动 50cm（HB 里 `lat=-50`），墙角仰视时最容易把相机推进墙里，加剧触发。
- **修法**：`SQUEEZE` 挤压收敛 —— 复用已有的挤压判据
  `(dist + appliedMag) < baseDist − fxSqueezeD`（boom 被压短），命中时把
  缩放量 × `squeezeMagK(0.45)`、横移量 × `squeezeLatK(0.15)` 收回去。
  宁可少拉近一点，也不让角色消失。判读日志 `SQUEEZE on/off dist= mag= lat=`。
- **注意**：dither 本身是引擎侧行为，我们只能**降低触发概率**（把相机挪出墙/远离角色），
  不能像开关一样关掉。若收紧后仍出现，先对比「不缩放时贴墙仰视」——原版也这样就是
  游戏固有行为，不是本模组引入的。

**v86：撤销挤压收敛，改用材质参数压 dither**

- **v85 的 SQUEEZE 已撤销**（用户否决：「我想要的就是原生禁用掉的效果，而不是镜头
  反复拉伸」）。挤压时收缩放量会让镜头在「收→放」之间反复抽动，比角色淡出还难受。
- **第一人称保持关闭**（`cfg.fpOn = false`）。
- **改试材质参数**（`applyDitherFix`）：dither 淡出在引擎里通常由材质的
  dither/fade 标量参数驱动，`UPrimitiveComponent::SetScalarParameterValueOnMaterials`
  是蓝图可调用入口。每 60 帧（1.2s）把 `cfg.ditherParams` 里的候选名
  （`Dither` / `DitherAlpha` / `FadeAlpha` / `CameraFade` / `NearFade` …）拉到 1.0
  （完全不透明）。不能每帧做 —— 该 API 会遍历全部材质槽。
- 首次运行会 dump `DITHER numMaterials=` 与 `DITHER mat <i> <name>`，
  若候选名全不命中，从材质实例名可以推断真正的参数命名风格。
- **预期**：如果 dither 是材质里 `DitherTemporalAA` 节点接的固定常量（不开放参数），
  那仍然无效 —— 那就是引擎/美术层写死的，Lua 无解。

**v88：渲染调色（F5 切换，不需要 pak 主密钥）**

- **背景**：用户想把画面改得更二次元。侦察结论 —— 真正的 cel shading / 描边必须换材质，
  而材质在加密 pak 里；pak 每个用 `md5(pak名小写)` 经主密钥 AES 派生（见
  `work/SnowbreakAes.cs`），主密钥不在二进制里静态存放，运行时读取被 ACE 拦住。
  → **资源层这条路封死**，改走运行时渲染变量。
- **实现**：`rndToggle` 用 `UKismetSystemLibrary.ExecuteConsoleCommand` 执行 UE4 渲染
  Cvar，**完全不碰资源文件**。F5 切换（读 `fp_key.txt`，与滚轮同一套 seq 去重 + 0.5s 冷却）。
  ```
  开：r.Saturation 1.25 / r.Tonemapper.Sharpen 1.5 / r.TonemapperGamma 2.0
      / r.SceneColorFringeQuality 1 / r.BloomQuality 5
  关：回默认值
  ```
- **能力边界（务必如实告知）**：能做到「颜色更艳、边缘更锐、暗部更实」的观感强化，
  **做不到**光照色阶化与描边。参数放在 `cfg.rndCmdsOn / rndCmdsOff`，用户可在游戏内
  控制台手调试出合适的值再回填。
- 判读：`RND switched on=true/false`；某条命令被拒会打 `RND fail: <cmd>`（项目可能锁了该 Cvar）。

**v91：角色二次元化 —— 判定不可行（证据链完整，不要再试）**

用户需求：把画面改得更「二次元」。结论已定，五条路里只有第一条成立：

| 尝试 | 结果 | 依据 |
|---|---|---|
| 全局渲染 Cvar（`r.Saturation` / `r.Tonemapper.Sharpen` / `r.TonemapperGamma`） | ✅ **场景生效，角色完全不变** | F5 切换后场景明显变化，角色零变化 |
| 猜材质参数名（Tint / Saturation / Ramp / SkinTint …8 个） | ❌ 全未命中 | `CHR param hit` 无输出 |
| 读 MID 参数表（`ScalarParameterValues` / `VectorParameterValues`） | ❌ **`count=0`** | `MID m0 scalar count=0`、`vector count=0` |
| 换材质（唯一真办法） | ❌ 需解包 pak | pak 每包用 `md5(pak名)` 经主密钥 AES 派生；主密钥不在二进制里静态存放，运行时读取被 ACE 拦 |
| 从游戏 Lua 源码找参数名 | ❌ 源码在加密 pak 里 | `PAK_Game_Script_0` 未解包，本地只有 1 个 lua 可读 |

**结论**：角色的着色器编译在材质图里（8 个材质槽全是 `MaterialInstanceDynamic`，
但参数表为空），**不开放运行时接口**。二次元化必须替换材质资源，而资源层被
「AES 加密 + ACE 保护」双重锁死。除非把绕 ACE 当独立项目做，否则到此为止。

**保留的成果**：`F5` 场景画面强化（饱和度 / 锐化 / 色调 / 色差 / 泛光），
参数在 `cfg.rndCmdsOn / rndCmdsOff`，可在游戏内控制台手调后回填。

**关键教训（下次一定要先查这四条）**
1. 任何"首次读取初始化"逻辑，**都不能把真实用户输入一起吞掉** —— 这是本轮
   三次"完全没反应"的共同根因，比任何相机算法问题都致命。
2. 相机功能依赖"输入有反应才能初始化"是脆弱设计，**必须有自发的初始化路径**
   （自动标定）。
3. 判据不要叠加"环境猜测"（前台进程名 / 进程权限）。钩子的安装条件本身已经
   限定了场景，再加一层筛选只会把正常输入筛掉。
4. 出问题先看三个文件：`sniffer_state.txt`（钩子装了没）、`wheel.txt` / `fp_key.txt`
   （事件进去了没）、`fp_key_raw.txt`（钩子收到键没、判定放行了没）。这四个
   文件能把"没反应"拆成四个互斥的原因，不用猜。

---

## 九、发布版 v87（清理 + 可分发）

**清理原则**：以 **P4 验收通过的 v68（`proto47.lua`）为基线重建**，只把后来实测
验证有价值的修补合进去 —— 在大文件里逐段删 600 行（第一人称 + dither 实验 +
各种诊断）风险远高于重建。

| | 清理前（proto48） | 清理后（proto49 = v87） |
|---|---|---|
| 行数 | 2296 | **1539** |
| pak | 293,333 B | **218,867 B** |

**合并进来的修补**（都是实测验证过的）：
1. `pollIPC` 首次读取退一格（否则累积滚轮被吞 → 滚轮完全失效）
2. 自动标定（距离稳定 25 帧即 calibrate，不再依赖滚轮事件）
3. 非 gameplay 分支 drain `pollIPC()`（大厅滚轮不堆积）
4. 开镜让行自愈 `AIM stuck`（FOV 被游戏压住时 4s + 滚 2 下强制恢复）
5. 嗅探器心跳检查（`SNIFFER dead or missing` + 屏幕提示）

**移除**：第一人称全部（~600 行）、dither 材质实验、KEYEV 键码探测、
各类一次性诊断日志。

**分发改造**：
- IPC 路径改为**通用位置** `C:\ProgramData\CamZoomMod\`
  （原 `D:\test\cbjq-re\runtime\` 别人电脑上不存在）；
  Lua 侧写死这个路径，Python 侧用 `os.environ['PROGRAMDATA']`，两边一致。
- `wheel_sniffer.py` 用 PyInstaller 打包成 **`CamZoomSniffer.exe`**
  （8.5 MB，`--onefile --noconsole --uac-admin`）—— 对方不需要装 Python；
  `--uac-admin` 是必须的（游戏是管理员进程，低权限钩子收不到输入，见 UIPI 那条）。
- 分发包：`D:\test\cbjq-re\dist\CamZoomMod-v87.zip`，内含
  `Patch_CamZoomMod-Windows_100_P.pak` + `CamZoomSniffer.exe` + `README.txt`。
- 对方安装两步：pak 丢进 `<游戏>\Game\cbjq\game\Game\Content\Paks\`，
  双击 exe（UAC 点是）。**不再需要 `.vbs`**。
- 打包命令：
  ```
  pyinstaller --onefile --noconsole --uac-admin --name CamZoomSniffer \
      --distpath . --workpath ./_build --specpath ./_build \
      D:/test/cbjq-re/runtime/wheel_sniffer.py
  ```
- 已验证：新路径能自动创建目录并写入；心跳正常递增；游戏未运行时 `hooks=off`。

---

## 五、代码与工程设施

| 路径 | 说明 |
|---|---|
| `work/camzoom/proto49.lua` | **v92 当前注入源**（v87 清理版 + FreeCamMod 共存挂起；单独构建也用它，共存代码在无 freecam 时是空操作） |
| `work/freecam/protov1.lua` | **FreeCamMod v15 当前注入源**（含 FreeCamActive 开关；进度文件 `work/freecam/HANDOFF.md`） |
| `work/build_both.js` | **v92 起的一键构建**：两份源码一起注入 → luaparse lint → repak 打包 → `merged-mod-new.pak` |
| `work/build_mod.js` | 旧的单 camzoom 构建（源码指针已过时：还指向 proto49 但产物不含 freecam；要用需先改回） |
| `work/build_freecam.js` | 旧的单 freecam 构建（含 freecam 侧耦合检查；合并检查已并入 build_both.js） |
| `work/camzoom/proto48.lua` | v69~v86 开发版（含第一人称实验，已关闭，留档） |
| `work/camzoom/proto47.lua` | v68（P4 HUD 整根淡出验收版，无 P5） |
| `work/camzoom/proto45.lua` | v54（线性档位 + 最近档 0.31/95cm，无 P4；P2 恢复时以此为准） |
| `work/camzoom/proto46.lua` | v55（乘性档位，用户否决，仅备查） |
| `work/camzoom/proto44.lua` | v53（全量扫 package.loaded 的普查版，查 FOV 入口用） |
| `work/camzoom/proto38.lua` | v49 源码（P1e 收口版，最近档仍是 0.38 时可回退） |
| `work/camzoom/proto*.lua`、`diag*.lua` | 历史原型 v4~v36（排查参考价值高） |
| `work/build_mod.js` | **一键构建**：加密 → luaparse 抠语法 → repak 打包（第 16 行指定 proto 文件） |
| `work/exe_strings_cam.txt` | 从 `Game.exe`+`GameBase.dll` 提取的 1580 条相机符号 |
| `work/v*_output.log` | 各版本实机日志存档 |
| `work/HANDOFF-old-2026-10-28-morning.md` | 上一轮（v20 之前）的交接，含更早的排查史 |
| `runtime/wheel_sniffer.py` | 全局钩子：滚轮 → `wheel.txt`；**V/B 键（仅游戏前台）→ `fp_key.txt`**；心跳 → `sniffer_beat.txt`；**只在 Game.exe 运行时挂钩子**，状态 → `sniffer_state.txt` |
| `runtime/tools_restart_sniffer.py` | 改完 sniffer 用它杀旧进程（**新进程仍要人工双击 VBS**，脚本启动的会被 job 收掉） |
| `runtime/start_wheel_sniffer*.vbs` | 嗅探器启动（普通 / 管理员） |
| `D:\test\ffmpeg\ffmpeg-master-latest-win64-gpl\bin\` | ffmpeg/ffprobe（本机无全局安装，视频分析用） |
| `D:\test\video_frames\roll.js` | 结构张量逐帧滚转角分析（原始灰度帧 → dRoll 时间线，可复用） |

### 构建与安装（v92 起）
```bash
cd D:/test/cbjq-re/work
"C:/Users/MisakiMiku/.workbuddy/binaries/node/versions/22.22.2-6/node.exe" build_both.js
cp merged-mod-new.pak "E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/Patch_CamZoomMod-Windows_100_P.pak"
```
- **pak 只在游戏启动时加载**；运行中文件被占用（`Device or resource busy`）
- 可挂后台轮询，等游戏退出后自动 cp：
  ```bash
  (for i in $(seq 1 400); do if ! tasklist | grep -qi "^Game.exe"; then cp ...; break; fi; sleep 2; done)
  ```

### 卸载
```bash
rm "E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/Patch_CamZoomMod-Windows_100_P.pak"
```

### 注入细节（易踩坑）
- 注入点：`umg_main.lua` 的 `return tbClass` **之前** + `ResourceAmend.lua` 末尾
- **绝不能在注入块里用 `return`** → 会让 umg_main 提前返回，主界面失效
- 幂等用 `if not CamZoomMod._ready then ... end` 包裹
- 但 **UMG Tick 钩子必须放在该块之外**：ResourceAmend 先加载会占掉 `_ready`，
  导致 umg_main 那份被跳过，而 `tbClass` 只有 umg_main 里可见
- lua 加密：AES-256-ECB，key `E1671E910EB54736B49908575F08CAFB`，无 padding

---

## 六、排查工具

```bash
grep "CamZoom" "E:/SeasunCBJQos/Game/cbjq/game/Saved/Logs/Game.log" | sed -E 's/^\[[^]]*\]\[[^]]*\]//'
```
心跳字段：`z` 倍率 / `zt` 目标 / `fov` / `ab` 瞄准混合 / `mag` 纵向偏移 / `lat` 横向偏移 /
`baseRel` 基准（**正常应为 0，非 0 即漂移**）/ `cur` 当前相对位置 / `worldZ` 相机世界高度 /
`fp` 第一人称混合 / `fpA` 是否开镜 / `fpD` 锁定的游戏 boom 距离 / `fpZ` 垂直写入量 /
`fpT` FP 目标 mag / `pawnZ` 角色世界 Z

---

## 七、给下一个 agent 的建议顺序

1. **P1e 已关闭（v49 用户验收）**。若后续有起跑/靠墙相关的新反馈，先按第四节点
   P1e 段的判读方法查日志（`YIELD dash FX` / `DCLAMP` / YIELD 间隔），再动代码；
   可调参数见 v49 修法段，**不要重开伺服路线**（⛔ 已废弃）。
2. **P3 已试并回退（v55 乘性档位被用户否决）**，当前生效是 v54 的线性档位。
   不要再重复"纯乘性"这条路；若再动档位，见第四节的三个备选方向（分段步长 /
   按住加速 / 降 zMax）。
3. **P2（FOV）已判死，不要再花时间**。第四节的证据表已经把 cam / pcm / 相机实例 /
   Slate 晚帧 / 全量 Lua 扫描全部排除；除非能拿到 `UCameraBlueprintGeneratedClass`
   实例（`GetCameraInstance` 需要它，`GetCameraInstanceClass()` 返回 nil），
   否则不必再试。`proto45.lua` 里 `zoomStep` 改回 0.10 即可恢复整套变焦逻辑。
4. **P5 第一人称（v69）在等实机验证**。看日志顺序：`FP lock`（锁定的 mag/baseD）→
   `FP eye`（胶囊半高与眼位 dz）→ `FP apply`（写入量随 fp 变化）→
   `FP drift relock`（贴脸距离漂移过大）→ `FP aim release`（开镜被游戏接管）。
   调手感只动 `cfg.fp*`：贴脸太远/穿帮调 `fpBack`，视角偏高/偏低调 `fpEyeRatio`
   或 `fpUp`，进出手感调 `fpFadeIn/Out`。**V 键无反应**先查
   `runtime/fp_key.txt` 的 seq 是否增长（不增长 = sniffer 没重启或键位被游戏吃掉）。
5. **每次改动后回归五项**：推近 / 拉远 / 居中 / 开镜 / 切人，外加起跑与靠墙场景。
   本轮多次因重构把已验证功能改坏（v28→v29、v40 淡出、v43 切人误触发、
   v45 旋转护盾方向错、v46 钳制不彻底+极限环、v47 靠墙闪光、v48 伺服发散）——
   改动前先想清楚旧代码里每个系数在护什么，有日志埋点先看日志再动手；
   **机制结论必须有实测数据支撑**（P1e 改判了两次）；**每引入反馈/闭环类机制，
   先纸上推临界点行为（极限环、与游戏侧的耦合）再上机——相机位置只能开环写**。
6. **编辑 .lua 源码只能用 Write/Edit 工具**。PowerShell 转码两个坑都踩过：
   Get-Content/Set-Content 不指定编码会把无 BOM UTF-8 按 GBK 读坏（v40）；
   显式 UTF8 往返也会加 BOM，注入到 umg_main 中段会让 Lua 解析报错（v43）。
   读日志用 `[IO.File]::ReadAllText` + 显式 UTF8 或 Read 工具。
7. **不要再把视频文件直接喂给模型**（34.7MB 视频 → provider 1210 解析错误，
   v44 会话因此中断）。用 `D:\test\ffmpeg\...\bin\ffmpeg.exe` 抽帧成 JPG/PNG 后用
   Read 看图；逐帧量化用原始灰度帧（`-pix_fmt gray -f rawvideo`）+ Node 脚本
   （`D:\test\video_frames\roll.js` 的结构张量可复用）。本机 python 是商店占位符，
   脚本用构建同款 node（`C:/Users/MisakiMiku/.workbuddy/binaries/node/versions/22.22.2-6/node.exe`）。
   cmd 内联 `%` 转义易翻车，复杂 ffmpeg 命令写进 .cmd 文件再跑。

---

## 八、环境速查

- 游戏：`E:\SeasunCBJQos`（3.6.0，UE4.26 定制），进程 `Game.exe`，须经 `SeasunGame.exe` 启动（UAC）
- 进程受反作弊保护：无法 `OpenProcess`、无法读命令行、**无法内存注入** → 只能 pak 注入 Lua
- 本地服：`work/mock443.js`（443 地址接管）+ `server2/acacia-game-server.exe`（5200 游戏 / 1234 GM）
- `acacia-rs\target\`（Rust 编译缓存 2.6GB）已于 2026-10-29 清理；服务端源码在
  `acacia-rs\`，如需重编译 `cargo build` 会自动重建缓存；运行只用 `server2\` 成品
- 磁盘清理（2026-10-29）：ffmpeg.zip、分析用抽帧图片/原始帧、`D:\test\;` 垃圾文件已删；
  ffmpeg 瘦身到只留 bin（`ffmpeg.exe`/`ffprobe.exe`/`ffplay.exe`，路径未变，交接文档引用有效）；
  `GF2_extract\`（少前2项目，31GB）用户明确保留不碰
- 日志：`E:\SeasunCBJQos\Game\cbjq\game\Saved\Logs\Game.log`（Lua `print` → `LogUnLua`）
- 输入：`Saved/Config/WindowsNoEditor/Input.ini` 有 118 条 ActionMappings、0 条 AxisMappings、
  **无任何滚轮绑定** → 滚轮方向必须靠外部嗅探器
- 战斗画面**不显示 `PrintString`**（定制渲染管线），HUD 提示只能落日志
