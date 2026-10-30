# FreeCamMod —— 游戏场景自由相机（与 CamZoomMod 完全独立）

> 需求：宿舍有拍照模式，但那是限定场景。要的是**游戏场景（战斗/关卡）里的自由镜头**，
> 用于随意构图拍照。明确要求：不要和滚轮缩放 MOD（CamZoomMod）混在一起。
> 状态：**v18 = ESC 退出 + 提示窗精装（嗅探器侧 overlay v2）**；碰撞为 v17 扫掠-滑移版；
> v15 起与 CamZoomMod 合并成一个 pak（见「共存 —— 已实施」节）。
> v13/v14 实测结论仍有效，交接快照见下方「当前状态快照」。

---

# ★ v18 ESC 退出 + 提示窗精装（2026-10-30，待实机验证）

**需求（用户原话）**：UI 太简陋要精装，先做按键样式 —— 白描边圆角矩形 + 字母 + 黑色
投影；ESC 也能退出拍照模式（拍照模式 UI 全隐藏，不搞复杂的排除隐藏）；UI 不要底部
背景，直接透明。

**改动一：ESC 退出（本 Lua，v18）**
- `cfg.escVK = 27`；step() 键处理链加 `elseif vks[i] == cfg.escVK and S.on then exit('esc')`
  （只在拍照模式内生效；拍照模式外 ESC 照常进游戏菜单）。
- **blockList 追加 27**：拍照模式下嗅探器把 ESC「先记录后吞」—— fp_key.txt 照样收到
  （我们用它退出），游戏菜单不弹。安全兜底不变：3s 死人开关 + ESC 本身就触发退出解禁。
- ⚠ 依赖嗅探器白名单放行 ESC：`runtime/wheel_sniffer.py` 的 KEYS_OF_INTEREST 已加
  0x1B（必须重启嗅探器才生效，见下方运维）。

**改动二：操作提示窗精装（嗅探器侧，wheel_sniffer.py overlay_thread v2）**
- 纯 GDI+（gdiplusflat via ctypes）画进 PARGB 位图 → `UpdateLayeredWindow`
  逐像素 alpha。旧 v1 是 GDI 纯色底板 + DrawTextW（**v1 的窗口样式漏了
  WS_EX_LAYERED**，靠不透明绘制掩盖；v2 已补 0x00080000）。
- 键帽样式：白描边（2px, α242）圆角矩形（r8）+ 半透明深底（α89）+ 黑色投影
 （偏移 +3, α115），键帽字母白字黑影、水平垂直居中。
- 全部文字带黑色投影；标题「自 由 相 机」淡蓝；**整窗无底板**（透明浮在画面上）。
- 内容（OVL_ROWS）：鼠标 转视角 / W A S D 移动 / E 上升 Q 下降 / 滚轮 变焦 FOV /
  V 定格时间 / B 进入退出 + **ESC 退出**。
- 渲染一次静态内容；显示/隐藏逻辑不变（300ms 读 freecam_on.txt）。
- 出错写 `C:\ProgramData\CamZoomMod\overlay_err.txt`（v1 同款约定）。

**运维（两项都要做才完整生效）**：
1. pak 已装（v18，游戏需重启加载）。
2. 嗅探器需管理员重启：**双击 `runtime/restart_sniffer_admin.vbs`**（新增，一次 UAC
   内完成 杀 pythonw → 等 1.2s → 管理员重启；本 shell 非管理员，杀不掉 elevated 旧进程，
   所以做了这个一键脚本）。验证：sniffer_state.txt `hooks=on elevated=1`。

**⚠ 首次重启后 UI 仍不出现的修复记录（2026-10-30 深夜）**：
overlay 线程连踩 4 个坑，靠 `runtime/overlay_test.py`（AST 提取 overlay_thread 原样
实跑 + 截屏）和 `runtime/gdip_probe*.py` 定位：
1. `GdipCloseFigure` 不存在 —— flat API 叫 **`GdipClosePathFigure`**（CloseFigure 是
   托管 API 名）。getattr 失败 → 线程死 → 无 UI（overlay_err.txt 有记录）。
2. `gp()` 绑定助手签名写错：`gp(name, *argtypes)` 把 restype 也吞进 argtypes，
   所有绑定多一个参数类型 → 首个调用 GdiplusStartup 就 TypeError。
3. `GdipCreateStringFormat(attributes, language, &out)` 实参顺序写反。
4. **本机 gdiplus.dll 的 `GdipMeasureString` 对全有效句柄也 fail-fast（0xC0000409）**
   —— 探针 1-4：裸调用/argtypes/NULL-format/交换参数全试过，同句柄的 DrawString、
   GetFontHeight 都正常；layoutRect=NULL 优雅返回 InvalidParameter，非 NULL 必崩。
   **测宽已弃用 GDI+，改 GDI GetTextExtentPoint32W**（同字体文件，±1px 由键帽
   12px padding 吸收），GDI+ 只负责绘制（DrawString/路径/ULW 实测正常）。
   ⚠ 给以后任何 GDI+ 工作的教训：**MeasureString 在本机不可用，测宽走 GDI。**
修复后 `overlay_test.py` 实跑验证：窗口创建且可见、截图确认键帽样式/透明底/六行
内容完整（含 ESC 行）。

**复验清单**：B 进入 → 提示窗为键帽样式、无底板；按 ESC → 直接退出且游戏菜单不弹；
拍照模式外按 ESC → 游戏菜单正常；B 进出回归正常。

---

# ★ v17 贴墙抽搐修复（2026-10-30 实机反馈，待复验）

**实机反馈（v16）**：碰撞生效、效果不错，但镜头贴墙后继续按方向键会**抽搐**。

**根因（机制推演）**：v16 把 6cm 安全间距做在「命中后沿视线回退」上 —— 贴墙续推时
每帧先自由逼近（间距区内扫掠不命中），触碰瞬间又被钳回 6cm 之外，位置 16↔13cm
每 2-3 帧 ping-pong 一个循环，画面抽搐。

**修法（v17）**：
- 间距并进球掠半径：**扫掠半径 = colRadius+colSkin（16cm）**，扫掠 sphere 本身
  带着安全间距去撞 —— 命中时球心就已经在「应停位置」；
- 命中响应改**扫掠-滑移**：去掉本帧位移里压入表面的法向分量
 （into = dot(位移, 法线)），保留切向分量（乘 1-t，t 由 Location 反推，不读 Time 字段）。
  效果：正对墙推入 → 停在原地不回弹（t=0 命中 → 位置不变）；斜推/贴墙平移 →
  精确沿墙滑行；擦边命中（into ≥ -0.01cm）→ 放行；
- **贴墙 standoff 不变**（相机中心离墙 ≥16cm），观感与 v16 一致；
- 起点陷入几何：MTD 推出改「刚脱出」（depth+0.5）；窄缝连续陷入（consec）→ 推力减半
  收敛，防左右墙来回弹；pawn 让行推进量改为 扫掠半径+2cm。

**复验清单**：贴墙后按住方向键 → 应稳定贴墙不抽搐；斜 45° 推墙 → 沿墙滑行；
贴墙平移 → 顺滑；远离墙 → 立即恢复自由；其余同 v16 清单（不穿地/角色不挡/定格有效/共存回归）。

---

# ★ v16 相机碰撞 —— 已实机验证：生效，但贴墙续推抽搐（v17 已修）（2026-10-30）

需求（用户原话）：拍照模式 MOD 会穿过所有游戏中场景的模型，要加碰撞效果。

**根因**：自由相机是我们 spawn 的 `ACameraActor`，无体积、位置逐帧直写 —— 穿墙是必然。

**方案（`protov1.lua` v16）**：每帧对「上一帧落点 → 本帧目标点」的位移做
`SphereTraceSingle` 球体扫掠（默认 Visibility 通道、半径 10cm），命中场景几何就把
落点钳在命中面前 6cm（`colSkin`）。要点：
- **滑墙是天然行为**：平行于墙面的位移扫掠不命中，只有直冲墙的位移被吃掉；
- **角色（pawn，ECC_Pawn=2）放行** —— 拍摄对象就是角色，被胶囊挡住就没法拍特写。
  pawn 命中的处理：起点沿视线推进 半径+2cm 后重扫（最多 4 次），让过 pawn 后
  余下路径照常可能撞墙；
- **起点陷进几何**（进相机时 POV 本来就贴墙）→ 沿 MTD 法线推出（PenetrationDepth+skin）；
- **可靠性原则**：任何接口故障都放行（宁可暂时穿墙，不可卡死相机），
  `COL err` 日志上限 5 条；FHitResult 字段全部读不到则自动停用碰撞（`COL dead`）。

**可调参数**（`cfg.col*`）：`colOn` 总开关 / `colRadius` 10 / `colSkin` 6 /
`colChannel` 1（Visibility，穿墙照旧或误挡过多换 2=Camera）/ `colComplex` /
`colMaxRetry` 4。

**结构改动**：`update()` 里相机写入从第 3 步移到第 5 步（滚轮推拉+WASD 并入
`S.pos` 后先做碰撞解析再写回，位移当帧生效且必经碰撞）；`enter()` 初始化
`S.colPrev`（扫掠起点）、`exit()` 清空。对 camzoom 无影响（未碰 FreeCamActive 协议）。

**日志判读**（`grep FreeCam .../Saved/Logs/Game.log`）：
- `freecam v16 injected` / `freecam v16 online` —— 新版本已加载
- `COL online r=10 skin=6 channel=1` —— 扫掠接口通（首次移动后打一次）
- `COL hit at=... actor=...` —— 命中场景并钳制（上限 5 条）
- `COL skip pawn ...` —— 角色让行（上限 10 条）
- `COL err ...` —— 接口故障（碰撞已放行，需排查绑定问题）
- `COL FHitResult 字段不可读 → 碰撞停用` —— 结构绑定问题，需换读法

**待实机验证清单**：
1. 飞向墙面 → 停在表面前（不再穿墙），贴墙平移顺滑
2. E/Q 下沉 → 不穿地
3. 贴近角色拍特写 → 角色不挡（skip pawn）
4. V 定格后移动 → 仍有碰撞（trace 不受时间膨胀影响）
5. v92 共存五项回归：camzoom 推近/拉远/居中/开镜/切人不受影响
6. B 进出正常，退出后 UI/滚轮缩放恢复

---

# ★ v14 实测结果（2026-10-30 05:40，用户确认）

- **大问题基本清零**：UI 隐藏 ✅、提示窗 ✅、左键开火/右键瞄准被挡住 ✅、
  技能/翻滚被挡住 ✅、Ctrl 跳跃 ✅（160-163 修饰键补上后）、WASD 冻结角色 ✅
- 相机操作全部正常：鼠标视角 / WASD 走位 / E-Q 升降 / 滚轮 FOV / V 定格 / B 进出
- 下一会话方向：体验优化（速度手感、快捷键微调等）

# ★ 与 CamZoomMod 共存 —— 已实施（2026-10-30，v15/v92 合并 pak）

方案按原计划落地，本 MOD 升到 **v15**（源码仍是 `freecam/protov1.lua`），
与 camzoom v92（`camzoom/proto49.lua`）一起由 **`work/build_both.js`** 注入同一批
两个 Lua 文件，打成**一个 pak**：`Patch_CamZoomMod-Windows_100_P.pak`（302,503 字节，
已安装；旧 freecam v14 pak 挪到 `work/pak-backup/` 可回滚）。

**本 MOD 的改动（4 处 + 1 兜底）**：
1. 激活开关 `_G.FreeCamActive`：enter() 成功后写 `S.frame`（**递增帧号**，不是
   true —— camzoom 靠「数值 2s 不递增」判断本 MOD 主循环已死并强制恢复缩放，
   死人开关防卡死本 MOD 永久带走滚轮缩放）；step() 里 `S.on` 期间每帧刷新；
   exit() 第一行就写 false（teardown 再出错也不吞开关）；注入时初始化 false。
2. **enter() 里滚轮 seq 对齐**（计划外新增的冲突点）：freecam 关闭期间滚轮事件
   一直被 camzoom 消费（同一个 wheel.txt、各自独立 seq），不对齐的话进入瞬间
   会把积压格数一次性补成 FOV 跳变。
3. Start 兜底：两个 MOD 现在都订阅 Event.Logined，若订阅被互相覆盖，第一条
   PCKeyboardEvent 再拉起主循环（camzoom 同款机制）。
4. 版本串 `freecam v15 injected` / `freecam v15 online`，日志判读用。

**camzoom 侧的对应改动**（详见主 HANDOFF v92 段）：step() 开头见开关即整体挂起
（滚轮/缩放写入/HUD/F5/标定全停，只排水 wheel.txt / fp_key.txt 的 seq），
退出自动恢复并清 distPrev/rotPrev/dRot（防陈旧测量误触发 FX 让位/护盾）。

## 测试矩阵（v92 首次实机，逐项打勾）
1. 启动 → 日志同时出现 `v92 injected` 和 `freecam v15 injected`（缺一个 =
   Logined 订阅覆盖问题，但两边都有 PCKeyboardEvent 兜底，滚一下滚轮/按个键再看）
2. camzoom 单独回归：推近/拉远/居中/开镜/切人，行为应与 v87 完全一致
3. B 进入自由相机 → 日志 `FREECAM active -> CamZoom suspended`；
   此时滚轮只改 FOV、**不再**改缩放；UI 全隐藏
4. V 定格 / 解除正常；B 退出 → 日志 `FREECAM ended -> CamZoom resumed, z=...`；
   UI 恢复；滚轮缩放从进入前的档位继续
5. 进相机期间按 F5 应无反应（camzoom 挂起中）；退出后 F5 恢复画面强化切换
6. 边角：没滚过滚轮直接进自由相机再退出（camzoom 未标定）→ 退出后自动标定仍工作

---

# ★ 当前状态快照（2026-10-30 05:50，交接用）

## 实机已验证可用
| 功能 | 状态 |
| --- | --- |
| B 进/出自由相机 | ✅（接管时从当前 POV 位置起步，不跳镜头） |
| 鼠标转视角 | ✅（搬 `pc:GetControlRotation()` 增量） |
| WASD 移动相机 | ✅（引擎输入轴，`GetInputAxisValue`） |
| E/Q 升降 | ✅（嗅探器 keys_held.txt 通道） |
| 滚轮 FOV 12°~110° | ✅（写自己相机的 FieldOfView，**不被回写**） |
| 速度随 FOV 缩放 | ✅（长焦自动减速，观感一致） |
| 游戏内 UI 全隐藏 | ✅（截图已验证，画面干净） |
| 操作提示窗（左上角） | ✅（嗅探器内置 ctypes 置顶窗，用户已截图确认） |
| V 定格（时间膨胀 0.02） | ✅ |
| 视点被抢自动让位 | ✅（剧情/过场不再抽搐） |

## 当前已知问题（按优先级）
1. **按键屏蔽从未真正生效过** —— 根因刚定位：`cfg` 表里有两个 `blockList`
   （安全默认轮留下的 `''` 排在后面，把大名单覆盖了）。Lua table 同名键后者覆盖前者。
   **已删除重复项并重装（v13，143,785 字节，md5 84d910ae），待实机验证。**
   日志判据：进相机时应出现 `BLOCK 1 2 10 32 17 16 81 69 ...`（之前一直是 `BLOCK 0`）。
2. 前台判定已改三重：pid（ever 集合）+ **窗口标题含「尘白禁区」** + 独占全屏兜底。
   ⚠ 已知边界：任何标题含「尘白禁区」的窗口（如浏览器里的相关标签页）都会被当作
   游戏前台而启用屏蔽。恢复方式：按 B 退出（嗅探器先记录后吞，B 一定能用）。
3. ~~鼠标左键开火 / 右键瞄准：无解~~ **v14 已解决**：之前"游戏走 Raw Input 吞不掉"
   的判断是错的——真正原因是前台判定坏了，黑名单被 `load_block` 每秒清空，
   鼠标钩子的 `return 1` 从未生效。前台判定修好后 LMB/RMB 实测都能挡住。
   **新的坑：低级键盘钩子里左右修饰键 vkCode 带区分**——LCtrl=162、RCtrl=163、
   LShift=160、RShift=161、LAlt=164、RAlt=165。写 17/16 挡不住左边的键
   （用户实测"Ctrl 还能让人物跳一下"就是这个原因）。Alt 不挡（Alt+Tab 要用）。
   WASD 也已加入黑名单（角色彻底不动），相机走位由 keys_held 通道接管
   （先记录后吞，update() 里轴 + held 两路合并，轴死 held 活，无需改逻辑）。
4. `SetIgnoreMoveInput(true)` **挡不住角色移动**（`PAWN MOVED` 实证）——游戏移动
   疑似也走 Raw Input。**关键未知**：如果屏蔽生效后吞掉 WASD，角色还动不动？
   - 还动 → 角色移动完全 Raw Input，键盘屏蔽对移动无效
   - 不动了 → 移动来自 legacy 轴，屏蔽后走位自动切换到 keys_held 通道（已实现合并）
5. 帮助面板的游戏内 UMG 路线已废弃（NewObject 的 TextBlock 没字体），保留代码未启用。

## 给下一个 agent 的注意事项
- **改 pak 后必须重启游戏**（pak 在启动时挂载）；**改 .py 后必须重启嗅探器**
  （`taskkill /F /IM pythonw.exe` + 管理员 vbs；进程名是 **pythonw.exe**）
- 日志：`E:/SeasunCBJQos/Game/cbjq/game/Saved/Logs/Game.log` 过滤 `[FreeCam]`
- 嗅探器状态：`C:\ProgramData\CamZoomMod\sniffer_state.txt`（`hooks=on` 才正常）
- 提示窗错误：`overlay_err.txt`（有内容 = 窗口创建失败及原因）
- 输入普查结论：`IsInputKeyDown` / `FKey('B')` 构造 / `GetInputMouseDelta` 全部可用
  → **下一步大方向：输入层迁引擎内，嗅探器降级为可选增强（滚轮 FOV + 提示窗）**，
  分发就只剩一个 pak
- `PCKeyboardEvent` 只派发滚轮事件（`args=13,true`），键位路线死，别再试

---

## 一、两条 MOD 为什么不能共存（关键约束）

两者的注入点是同一批游戏 Lua 文件：

- `Game/Content/Script/UMG/Main/umg_main.lua`（插在 `return tbClass` 之前）
- `Game/Content/Script/Resource/ResourceAmend.lua`（追加到末尾）

同目录多个 pak 覆盖同一路径时，优先级取决于挂载/名字排序，**不可靠**。所以同一时刻只能
装一个：`install_freecam.sh` 会把 camzoom 挪到 `work/pak-backup/`，`restore_camzoom.sh` 换回。

> 若以后要同时用，正确做法是**一个 pak + 两个模块**（camzoom 和 freecam 各自定义独立全局表，
> 互不引用），而不是让两个 pak 互相抢文件。届时只合并“产物”，源码仍分开。

## 二、注入/构建流程（与 camzoom 同源）

| 项 | 值 |
| --- | --- |
| 源 | `work/freecam/protov1.lua`（v18，共存开关 + 碰撞·扫掠滑移 + ESC 退出） |
| 构建 | **`cd work && node build_both.js`（v92 起用这个：camzoom+freecam 一起打进一个 pak）；`build_freecam.js` 只在需要单独构建 freecam 时用** |
| 产物 | `work/merged-mod-new.pak`（329,251 字节）→ 安装为 `Patch_CamZoomMod-Windows_100_P.pak` |
| 安装 | 手动 cp（旧的 install_freecam.sh / restore_camzoom.sh 是单 MOD 时代的换装脚本，留着备查） |
| 目标 | `E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/Patch_CamZoomMod-Windows_100_P.pak` |
| Lua Key | `E1671E910EB54736B49908575F08CAFB`（AES-256-ECB，无 padding） |
| repak | `tools/repak.exe pack . out --version V8B --mount-point ../../../` |

⚠ 构建坑（已修）：JS `String.replace` 的替换串里 `$'` 是「匹配点之后的内容」。
Lua 源码含 `$'`（如 `match('([^%.:]+)$')`）会被吃掉字符导致语法错误，
必须用**函数形式** `replace(re, () => probe)`。camzoom 的 `build_mod.js` 有同样的隐患，
只是它源码里恰好没出现 `$'`。

## 三、运行环境事实（继承自 CamZoomMod 的实测）

- Lua 运行时是 **UnLua**（`LogUnLua`），反射可直接读写 UObject 成员与调用 UFUNCTION
- 入口：`GetGameIns()` / `UE4.UGameplayStatics.*` / `EventSystem.On(Event.Logined, ...)` /
  `UE4.Timer.Add(interval, fn)` 递归自注册（**唯一稳定的 50Hz 节拍**；战斗中 UMG Tick 不跑）
- `pc.PlayerCameraManager` → `GamePlayerCameraManager_C`（继承自游戏侧
  `AThirdPersonPlayerCameraManager`）；`pawn.Camera` → `UCameraComponent`
- `pcm.ViewTarget.Target` / `pcm.ViewTarget.POV` 可读（诊断脚本已验证）
- **重要教训**：camzoom 实测「写 FOV → 0.35s 内被游戏回写」，说明游戏的相机更新在我们的
  Timer 之后。所以自由相机**不能靠抢写一个共用的相机组件**，要靠「让引擎从我们的相机算 POV」。

## 四、符号表勘察（`work/exe_strings_cam.txt`）

游戏自带一套相机框架（`UniversalCameraPlugin` / `GameCameraAnimation` / `CameraNode_*`），
**并且有现成的自由观看相机**：

| 符号 | 含义猜测 | 备注 |
| --- | --- | --- |
| `SetFreeWatchCameraMode` | 自由观看模式开关 | 最可能的一次调用就成形的路线 |
| `SetWatchCameraAscendState/DescendState` | 上升/下降状态 | 说明支持飞行式位移 |
| `FreeWatchModeCameraActor` | 自由观看相机 Actor | 可作为 ViewTarget |
| `SetUniversalCameraMode`、`SetViewTargetToUniversalCamera` | 通用相机模式 | 次选 |
| `EnableDebugCamera`/`DisableDebugCamera`/`DebugCameraControllerRef` | 引擎调试相机 | 若 UFUNCTION 存在 = 零成本路线 |
| `GetInteractorFPSCameraActor` / `AInteractionFPSCameraActor` | 交互第一人称相机 | 用户说改不动的第一人称镜头很可能就是它 |

⚠ 这些只是二进制字符串，**不一定都是 UFUNCTION**（可能是纯 C++ 成员，Lua 调不到）。
只有 probe 的存在性检查（`type(obj[name]) == 'function'`）能确认。

## 五、probe v1（`freecam/probe01.lua`）做了什么

一次性普查，不落地任何持久状态，全程 pcall，单步失败即跳过下一步：

1. **ARM**：只在 gameplay 且站定 1s 后启动，再等 8s 才开跑（会打一行 ARMED）
2. **反射普查**：分别对 pc / pcm / cam / pawn 逐个检查候选方法是否存在；
   再检查一批 UClass 是否可见（只查 `type()`，**不调用**，零风险）
3. **阶梯**（命中即停，然后进入 3s 观察期）：
   - `debugcam`：pc:EnableDebugCamera / ToggleDebugCamera
   - `freewatch`：pcm:SetFreeWatchCameraMode(true)
   - `universal`：pcm:SetUniversalCameraMode(true)
   - `spawn`：BeginDeferredActorSpawnFromClass + FinishSpawningActor 生成 ACameraActor
   - `viewtarget`：pc:SetViewTargetWithBlend(camActor, 0, 0, 0, false)
   - `povfollow`：把相机抬高 220cm，看 POV 是否跟着走（**判定引擎是否真在用我们的相机**）
4. **观察**：150 帧内统计 ViewTarget 被游戏抢回的次数
5. **还原**：关 DebugCamera、ViewTarget 切回 pawn、销毁临时相机
6. **REPORT**：日志末尾打印汇总

判读：`grep "FreeCam" .../Saved/Logs/Game.log`，看 `==== REPORT ====` 块。

---

# 七、v2 实机结论（2026-10-30，决定性）

```
STEP viewtarget         OK   已切到 CameraActor_2147477897
STEP viewtarget/verify  OK   ViewTarget=CameraActor_2147477897
HOLD done reverts=0 reassert=0 stuck=0
STEP fovwrite/verify    OK   povFov=25.0 compFov=25.0
STEP dilation/verify    OK   readback=0.0200 restored=1.000
```

| 结论 | 证据 |
| --- | --- |
| **画面完全归我们的相机，且没有争抢** | 150 帧（3s）观察期 `reverts=0`，一次都没被抢回，**不需要每帧重挂 ViewTarget** |
| **FOV 可自由控制** | 写 25°，渲染 POV 读回 25.0（camzoom 那边写 FOV 被回写的坑在这里不存在） |
| **定格可行，且控制循环不受影响** | `SetGlobalTimeDilation(0.02)` 生效；那一帧只慢了 0.09s → UnLua Timer 走真实时间 |
| 常量 | 基础 FOV 因地图而异（本次 BASE 读到 90.0，camzoom 默认是 75） |

游戏自带入口全部判死，不要再试：`EnableDebugCamera` / `ToggleDebugCamera` /
`SetFreeWatchCameraMode` / `SetUniversalCameraMode`，`AFreeWatchModeCameraActor` 类不可见。

# 八、v1 功能版（`freecam/protov1.lua`）

| 操作 | 行为 |
| --- | --- |
| **B** | 进入/退出自由相机。进入时从当前 POV 的位置与角度接管，**不跳镜头** |
| **鼠标** | 转视角。搬 `pc:GetControlRotation()` 的增量（Yaw/Pitch），零延迟、不用改嗅探器 |
| **滚轮** | 沿视线前后移动 45cm/格，指数平滑（tau 0.12s） |
| **V** | 开关定格（时间膨胀 0.02） |

> ⚠ **按键必须落在嗅探器白名单里**。v1 初版绑 F7，实机怎么按都没反应 —— 根因在
> `runtime/wheel_sniffer.py` 的 `KEYS_OF_INTEREST = {V, B, F5}`：钩子**只转发白名单内的键**，
> 其余静默丢弃。已把 F6/F7/F8 加进白名单并重编 exe（`dist/_build/out/CamZoomSniffer.exe`，
> 旧版备份为 `dist/CamZoomSniffer.exe.bak-20261030`）；重启嗅探器（管理员）后可改回 F7/F8。
> 判据：`C:\ProgramData\CamZoomMod\fp_key_raw.txt` 里有没有对应 `vk=`。没有就是被白名单吞了。

安全兜底：进入后 `SetIgnoreMoveInput(true)` 防止角色乱跑；每 5 帧 `StopAllCameraShakes(true)`
压抖动；每 10 帧检查 ViewTarget 被抢就重挂；离开 gameplay / 嗅探器心跳断 15s → 自动还原。

已知限制：
- Pitch 受游戏瞄准俯仰限位约束（约 ±80°），暂时不能垂直看上去天/垂直下瞰
- 没有垂直上下和平移（strafe）—— 只能「转头 + 沿视线推拉」。要让相机任意走位需要
  WASD，而目前按键通道只有 keydown 事件流（`fp_key.txt` 是 “seq vk”，没有 keyup/按住状态），
  需要给 `runtime/wheel_sniffer.py` 加一份「当前按住的键集合」
- 未知：蠕动/位移手感是否可接受（v1 每 20ms 写一次相机 transform）

---

# 九、v2（2026-10-30）带鱼屏黑边 + 走位

**黑边根因**：`ACameraActor` 构造函数默认 `bConstrainAspectRatio = true`（按 16:9 锁比例），
21:9 屏上就会出现**左右黑边**。修法：spawn 后取 `CameraComponent`，
`bConstrainAspectRatio = false`，并把 `AspectRatio` 设成
`UGameplayStatics.GetViewportSize()` 读到的真实比值（日志 `ASPECT viewport=… ratio=…`）。
UI 会画到黑边上（UMG 按视口布局，不受相机影响）→ 下一步要把 HUD 关掉。

**走位**：WASD 前后左右、Q/E 升降。走位需要**持续按键状态**，而 `fp_key.txt` 只有按下瞬间
一条事件（且系统 repeat 被 1.5s 去重吃掉），所以给嗅探器加了 `keys_held.txt`
（空格分隔的 VK，无键写 `0`）；`KEYS_OF_INTEREST` 增加 W/A/S/D/Q/E。
丢焦点收不到 KEYUP 的兜底：`tick()` 每秒把「超过 2.5s 没有 repeat」的键剔除。

⚠ 改了 `runtime/wheel_sniffer.py` 后**必须重启嗅探器**（管理员 vbs 直接跑 .py）：
先结束掉现有的两个 `CamZoomSniffer.exe`，再双击 `runtime/start_wheel_sniffer_admin.vbs`。

---

# 十、v3（2026-10-30）按帧更新 + 滚轮改 FOV + 升降换键

**实测**：进入后 W/A/S/D **走引擎输入轴生效**（不需要嗅探器）。Q/E 被游戏占为大招，
升降改到 **Z/X**（走文件通道，需重启嗅探器）；同时尝试引擎轴 `MoveUp`，有值就用。

**卡顿的真因**：不是帧率下降，是**时间采样错拍**。主循环 50Hz（20ms）对 60fps（16.7ms）
会出现「有时一帧一更新、有时两帧一更新」的抖动，主观感受就是掉帧。
修法两条：
1. `pollInterval = 0.006` —— UE Timer 由世界 Tick 驱动，间隔小于帧长即**等价于按帧更新**
2. `dt` 改由 `UGameplayStatics.GetRealTimeSeconds()` 实测（不受时间缩放影响），
   不再写死 0.02 —— 否则位移/FOV 速度会随帧率漂移

**滚轮改为控制 FOV**：12°–110°，每格 5°，指数平滑（tau 0.1s）。
写 `camComp.FieldOfView`，相机是我们 spawn 的，**不存在 camzoom 那种被游戏回写的问题**。
前后走位交给 W/S（wheelStep 停用）。

若按帧更新后**仍然**觉得拖沓，下一个嫌疑是 TAA/动态分辨率，或游戏相机管理器上挂的
lag 类 modifier —— 那就不是更新频率的问题，要另找入口。

---

# 十一、v4（2026-10-30）屏蔽输入 + 隐藏 UI + 屏显操作提示

**屏蔽游戏输入**：`pawn:DisableInput(pc)`（+ 原有的 `SetIgnoreMoveInput(true)`）。
只摘 pawn 的 InputComponent，PlayerController 侧的 ControlRotation 照常更新 ——
鼠标转视角正是靠 ControlRotation，所以**不能** `SetIgnoreLookInput`。
屏蔽后 Q/E 不再触发大招，升降键改回 **E 上升 / Q 下降**（Z/X 作备用）。

**隐藏 UI**：`GetAllWidgetsOfClass(pc, nil, UUserWidget)` 抓全部 UserWidget，
对每个 `SetRenderOpacity(0)`，退出时还原各自原值。
⚠ 不能用 `SetVisibility(Collapsed)` —— 游戏自己的显示逻辑会把它改回来（camzoom v63 的血泪）。
游戏也会周期性改回透明度，所以每 `hudRehide` 帧重压一次，并每 ~2s 补抓新出现的 widget。

**MOD 自己的 UI**：`UKismetSystemLibrary.PrintString(ins, text, true, false, color, dur)`
走 GEngine 的 OnScreenDebugMessage，**UMG 隐藏后依然可见**，正好当操作提示面板用。
进入时打一次，之后每 1.2s 刷新（内容：鼠标转视角 / WASD / E-Q 升降 / 滚轮 FOV / V 定格 / B 退出）。

⚠ **E/Q 和 Z/X 都走嗅探器文件通道**，`keys_held.txt` 由新版嗅探器输出 ——
**必须重启嗅探器**才有升降。

---

# 十二、v5（2026-10-30）真屏蔽输入 + 自建 UI

**`PrintString` 在发行版是空操作**：`UKismetSystemLibrary::PrintString` 被
`UE_BUILD_SHIPPING` 宏裁掉，实机确认不显示。屏幕提示必须自己造 UI。

**`pawn:DisableInput(pc)` 对这款游戏无效**：调用返回成功（日志 `INPUT DisableInput=true`），
但左键照样开火、右键照样瞄准、空格照样翻滚、Q/E 照样放大招 —— 游戏没走 pawn 的
InputComponent。真正生效的办法是**让嗅探器在低级钩子里吞事件**：钩子回调返回 1，
事件不再往后传，游戏就收不到。
- `block_vk.txt`（Lua 进/出自由相机时写）约定：1=左键 2=右键 4=中键 10=滚轮，其余写 VK
- 记录与吞掉的顺序：先写 `keys_held.txt` / `fp_key.txt`，再吞 —— 所以 B/V/Q/E
  **我们照样能收到，游戏收不到**
- ⚠ 黑名单里**绝不能列 W/A/S/D**：走位轴要游戏自己收得到才有值
- 黑名单 1s 刷新一次（在 `tick()` 里读），进出自由相机允许最多 1s 生效延迟

**自建 UI**：`NewObject(UUserWidget)` + 手工搭 `UWidgetTree`（CanvasPanel + TextBlock），
`AddToViewport`，退出时 `RemoveFromViewport`。不依赖任何游戏素材。
hudCollect 里要**排除自己这个 widget**，否则会被一起隐藏。

---

# 十三、⚠ 事故与整改（2026-10-30）—— 吞事件做成全局，害用户重启电脑

**经过**：黑名单早期版本在钩子里无差别 `return 1`，**不看前台窗口**。
用户在自由相机里切到桌面/任务管理器时，鼠标点击照样被吞、键盘也被吞一部分，
**连杀进程都点不动，只能重启电脑**。

**根因**：低级钩子吞事件是**全局**的，而黑名单只是一个静态文件，
游戏/游戏外的场景完全没有区分。

**整改（三道闸，缺一不可）**：
1. `load_block()` 里 `foreground_is_game()` —— 只在游戏前台才吞
2. **死人开关**：黑名单文件 mtime 超过 3s 未更新即视为空；Lua 侧每 0.5s 重写一次维持。
   游戏崩了 / Lua 挂了 / 忘了写 0，都会**自动解禁**，不会留下需要重启的状态
3. `remove_hooks()` 里 `_block.clear()` + `_held.clear()` —— 钩子没了绝不能再吞

**并且默认关闭**：`cfg.blockList = ''`（写 0）。两个理由：
实测吞了之后游戏照样开枪（疑似 Raw Input），收益存疑；而风险是整机输入锁死。
以后要启用，必须确认上面三道闸都还在。

**运维提醒**：嗅探器现在以 **pythonw.exe** 运行（vbs 直接跑 .py），
任务管理器里看不到 `CamZoomSniffer.exe`。查状态看
`C:\ProgramData\CamZoomMod\sniffer_state.txt`（`hooks=on ... game_pids=[...]` 才正常）。

---

# 十四、⚠ 事故 2（2026-10-30）—— 脚本删码误删三个函数，MOD 整个死掉

用 python 脚本按「字符串边界」删 makeHelp/findFont 时，结束标记匹配到了
更靠后的位置，把 `hudCollect / hudHide / hudRestore` 一起删了。
后果链：进相机 → `hudCollect` 报 nil 调用 → ENTER 中断（`writeOverlay('1')` 没执行，
提示窗不出现）→ 主循环每 12 帧报错 → 20 次后 MOD 退出 → 游戏 UI 回来、
移动/技能回来、视点被抢回 —— 表面上像「所有问题都回归了」。

**教训：删除代码必须以「函数定义的完整文本」为边界，不能拿注释头当锚点；
删完必须 grep 确认所有调用点仍有定义。**

已恢复三个函数并重建（142,107 → 后续版本）。

# 十五、输入能力普查结果（2026-10-30，重要）

```
INPAPI IsInputKeyDown=Y WasInputKeyJustPressed=Y WasInputKeyJustReleased=Y
       GetInputMouseDelta=Y GetMousePosition=Y GetInputAxisValue=Y
INPAPI FKey=true
INPAPI IsInputKeyDown(B)=false ok=true      ← FKey('B') 构造成功、调用成功
KBD n=1..20 args=13,true                    ← PCKeyboardEvent 只有滚轮类事件
```

**结论：引擎内输入查询全部可用，MOD 可以脱离嗅探器独立运行。**
- `UE4.FKey('B')` 直接用字符串构造，UnLua 自动转
- `pc:IsInputKeyDown(k)` 可做按键状态轮询（含按住态，比文件 IPC 强得多）
- `PCKeyboardEvent` 只派发滚轮类事件，键位走不通
- 嗅探器降级为**可选增强**：滚轮 FOV + 置顶提示窗。核心功能（B/V 开关、
  WASD 走位、E/Q 升降）全部走引擎查询

---

# 十七、v11（2026-10-30）Ctrl/Space 屏蔽 + 前台判定加固

- UI 隐藏确认恢复（截图验证，画面全干净）
- 键盘动作键（Space 跳跃/翻滚、Ctrl 闪避）`SetIgnoreMoveInput` 挡不住 —— 它只挡移动轴。
  键盘事件走传统消息路径（WASD 轴就是从这条来的），嗅探器**吞得到**，重新启用黑名单，
  但只列键盘键 `'32 17'`（鼠标左右键走 Raw Input，吞不掉，列了也没用）
- 前台判定加固：pid 快照会间歇性抽风，改用 `_game_pids_ever`（会话内曾经见过的 pid）
  做 `foreground_is_game` 匹配，不受抽风影响
- 操作提示窗改为嗅探器内置（纯 ctypes 置顶窗口：TOPMOST + TRANSPARENT 鼠标穿透 +
  TOOLWINDOW 不进任务栏；独立线程 + 自己的消息泵，每 0.3s 读 `freecam_on.txt`）
- `PCKeyboardEvent` 实测只派发滚轮事件（`args=13,true`），键位路线死

---

# 十九、v12（2026-10-30）提示窗修复：64 位 ctypes 三个坑

提示窗一直不出现的原因：**Python 3.13 的 `ctypes.wintypes` 没有 `WNDCLASS`/
`HCURSOR`/`PAINTSTRUCT`**，`overlay_thread` 第一步就 AttributeError，
而异常被静默吞掉，窗口从未创建。已用独立测试脚本逐步验证并修复：

1. 手工定义 `WNDCLASSW / PAINTSTRUCT`，`HCURSOR = c_void_p`
2. **所有句柄必须显式 argtypes/restypes**，否则 64 位句柄按 32 位截断直接
   `OverflowError`（CreateWindowExW/GetModuleHandleW/DestroyWindow/
   UnregisterClassW/BeginPaint…全都要）
3. `FillRect` / `DrawTextW` 在 **user32** 不在 gdi32
4. WNDPROC 回调返回值用 `LRESULT = c_longlong`（c_long 在 64 位会截断）
5. 失败不再静默：写 `overlay_err.txt`

验证方式：`runtime/overlay_test.py`（已删，逻辑已并入嗅探器）在隐藏模式下
走完整创建→显示→置顶→销毁流程，输出 ALL OK。

# 二十、下一步（按依赖顺序）

1. 实测手感：转视角是否跟手、推拉是否发抖、进入/退出是否干净
2. 若有垂饵/平移需求 → 改 `runtime/wheel_sniffer.py` 输出按住键集合，重建 exe
3. HUD 全关（复用 UMG 遍历思路，独立实现）、景深/对焦参数、`ExecuteConsoleCommand`
   试超采样出高分辨率截图

---

## 六、下一步（等实测结果再定）

- 命中 `debugcam` / `freewatch`：几乎零成本，剩下只有输入、定格、HUD、景深四件事
- 命中 `spawn+viewtarget`：走「自己管理相机 Actor」路线，工作量中等，但最可控
- 全部落空：只能上原生 hook（覆盖 `UpdateCamera` 之后的 CameraCache.POV），成本最高

无论哪条，真正的工作都不在相机本体，而在：50Hz 写位姿的转视角卡顿 /
`StopAllCameraShakes` / 弹簧臂碰撞与 lag 关掉 / 时间膨胀定格 / UMG 全关 /
景深参数 / `r.ScreenPercentage` 超采样出高分辨率。
