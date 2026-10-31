# FreeCamMod —— 游戏场景自由相机（与 CamZoomMod 完全独立）

> 需求：宿舍有拍照模式，但那是限定场景。要的是**游戏场景（战斗/关卡）里的自由镜头**，
> 用于随意构图拍照。明确要求：不要和滚轮缩放 MOD（CamZoomMod）混在一起。
> 状态：**v20 Lua + overlay v10（进程名根因已修，方向键应稳定可用）**。
> pak 更新到 346,389 字节（Lua v21：暗角 PP 自检 + dofSync 6 帧）；
> 嗅探器 v10：`GAME_PROCS` 补 `games.exe`。
> 待验证：① 进相机 1.5s 内四角是否发暗（判断 PP 通道）② ↑↓ 跳行 / ←→ 改值
> 是否稳定 ③ 光圈 1.4 画面是否变糊。
> v13/v14 实测结论仍有效，交接快照见下方「当前状态快照」。

---

# 📌 后续方案（已定）：景深改走 Reshade（2026-11-01 02:2x 记录）

## 为什么放弃引擎内实现

| 尝试 | 结果 |
|---|---|
| `UCameraComponent.PostProcessSettings` | 写入成功但 POV 里是 0（`povFocal=0/povW=0`），渲染端不采用 |
| 世界 `APostProcessVolume`（`bUnbound` + `Priority=100`） | 创建/参数/优先级全对，画面无任何变化 |
| 全部 DOF cvar（Quality/Recombine/RingCount/Bokeh/Max*Radius/ForceDepthResolve） | 日志回显确认生效，画面无变化 |
| 自定义 PP 材质（`WeightedBlendables` + MID） | 材质 domain 不兼容，**按 B 直接崩溃**（调用栈在渲染线程） |

**结论**：`-FeatureLevelES31` + `r.MobileHDR:1` 的 UE4 Mobile 管线在这套游戏里
没有编 DOF 与 PP 材质这两块。宿舍拍照模式同样没有景深，印证项目本身没做。

## Reshade 方案（待实施）

- **原理**：注入 D3D11（游戏后端就是 D3D11，`-FeatureLevelES31` 不影响），
  读**深度缓冲**做真实景深，完全绕开游戏后处理。
- **shader 选择**：
  - `CinematicDOF.fx` —— 更接近真实相机镜头（光圈/焦距/焦外形状可调），首选；
  - `MagicDOF.fx` —— 轻量、参数少，性能好，备选。
- **初始参数方向**：对焦距离跟随相机到主体的距离（人像 200–400cm）、
  F-stop 1.4–2.8、焦外强度中等；拍照时用快捷键开关。
- **前置条件**：装 Reshade 5.x（选 D3D11），把 shader 放进 `reshade-shaders/Shaders`。
- **风险**：全局生效（战斗也会糊），必须配开关；私服无 ACE，注入冲突风险低。
- **决定**：用户说「后面再弄」，本轮不实施。

---

# ★ v28：引擎 DOF 彻底证伪，改挂现成后处理材质（RadialBlur）

**v27 结果**：日志 `PPVOL priority=100.0` 确认设置成功，`DOF vol=true volFocal=6080 volW=1`
参数也对，**画面依旧毫无变化**。

**结论（可以钉死了）**：`-FeatureLevelES31` + `r.MobileHDR:1` 的 UE4 Mobile 管线
在这套游戏里**不实现 DOF 后处理**，不是参数、不是优先级、不是传递路径的问题。
宿舍拍照模式也没有景深（用户去确认过），说明项目本身就没做这个功能。

## v28 方案：绕开引擎 DOF，挂 Post Process 材质

从 `work/_matresearch/out_true/` 里翻到一个 ImageEffects 系列材质，
并从 uasset 头部解析出真实包路径：

```
/Game/Materials/ImageEffects/RadialBlur/radial_blur_mat
/Game/Materials/ImageEffects/RadialBlur/radial_blur_inst
```

`ImageEffects` 前缀 + Domain = Post Process，走
`PostProcessSettings.WeightedBlendables` 进后处理链 —— **完全不经过引擎的 DOF 实现**。
效果是径向模糊（中心清晰、四周虚化），不是深度景深，但拍照构图可用。

**实现要点（都很容易踩空）**：

1. **UE4.26 没有 `UKismetSystemLibrary.LoadAsset`**（那是 UE5 才加的）。UnLua 里
   加载资产的入口不确定，所以一次试 5 种：
   `UKismetSystemLibrary.LoadAsset` / `UE4.LoadObject` / `UE4.UObject.Load` /
   `FSoftObjectPath(p):TryLoad()` / `UGameplayStatics.LoadAsset`，
   谁成功日志记 `PPVOL mat[n]=<路径>`。
2. `FWeightedBlendable` 两种构造都试：`(1.0, mat)` 与无参 + 逐字段赋值。
3. 挂载后 `vol.Settings.WeightedBlendables = wbs` 回写。

pak **363,033 字节**已安装。

## 判定

| 日志 | 含义 |
|---|---|
| `PPVOL mat[n]=…` + `blendable added` | 材质挂上了 → 看画面有没有径向模糊 |
| `PPVOL mat not found` | 5 种加载入口都不通，需要换（AssetManager / 蓝图预引用） |
| `blendable build failed` | 结构体构造失败，改 table 直接 Add |

**如果材质挂上、`blendable added` 也打了，画面还是纹丝不动** —— 那说明移动端连
PP 材质通道都被裁了，引擎层面基本无解，只能考虑改 pak 里的渲染配置或放弃景深。

---

# ⏸ v26 结论：参数链全通，渲染端不消费 —— DOF 暂停，转查宿舍拍照模式

**最后一版（v25 Volume）的日志**：

```
PPVOL spawned unbind=true                    ← Volume 创建成功
DOF povFocal=0.0  povW=0.0                   ← POV 里没有 PP（相机组件路线已证伪）
DOF vol=true  volFocal=800.0  volW=1.0       ← Volume 的 Settings 和权重都写对了
```

**Volume 也写对了，画面依然一点不糊。**

## 所以问题定性

不是「参数没传到位」——三条传递路径都已验证到位：

| 路径 | 结果 |
|---|---|
| `UCameraComponent.PostProcessSettings` | 结构体写入成功，但 POV 里是空的（`povFocal=0`） |
| `APlayerCameraManager.CameraCache.POV` | 被游戏覆盖，读回恒 0 |
| 世界 `APostProcessVolume`（`bUnbound`） | 创建成功、`volFocal=800`、`volW=1`，**仍无效果** |

**结论：`-FeatureLevelES31` + `r.MobileHDR:1` 的 UE4 Mobile 前向管线，
在这套游戏里不实现景深后处理**，与参数无关。

已排除的 cvar 组合（都设过、日志确认回显）：
`r.DepthOfFieldQuality 2` / `r.DOF.Recombine.Quality 3` / `r.DOF.Gather.RingCount 7` /
`r.DOF.Gather|Scatter.EnableBokehSettings 1` / `r.DOF.Scatter.MaxSpriteRatio 1.0` /
`r.DOF.Kernel.Max{Foreground,Background}Radius 1.0` / `r.Mobile.ForceDepthResolve 1`。

## 用户决定：暂停，去研究宿舍的拍照模式

宿舍拍照模式有真实景深，说明引擎/项目里一定存在能出效果的实现。研究时值得确认：

1. **相机 Actor 的类名** —— 之前 probe 记录过候选
   `AFreeWatchModeCameraActor`（`EnableDebugCamera` / `SetFreeWatchCameraMode` /
   `SetUniversalCameraMode` 都不在反射表里）。进拍照模式后用
   `pc:GetViewTarget()` 打类名，和我们的 `CameraActor` 对比。
2. **是否用了 Post Process Material** —— 移动端管线里 DOF 最常见的替代实现：
   自定义材质 + `SceneDepth`，通过 `PostProcessSettings.WeightedBlendables` 挂上去。
   如果是这种，我们也可以挂同一个材质（AssetPath 从 pak 里捞）。
3. **是否切换了渲染管线 / FeatureLevel** —— 拍照模式若临时切 Deferred，
   PC 的 DOF 参数就能用；可对比进拍照模式前后 `r.ForwardShading`、
   `r.MobileHDR`、`r.DepthOfFieldQuality` 的回显。
4. **是否有专用 cvar 前缀** —— `r.PhotoMode.*` / `r.Camera.*`。
5. **是否假景深** —— 双层渲染 / 背景单独模糊，不经过后处理。

## 当前保留状态

- pak **361,169 字节**（v25，Volume 会在退出时销毁，对游戏无副作用）；
  更早版本备份 `.bak-v20/.bak-v21/.bak-v22/.bak-v23`。
- 嗅探器 **v11**（滑块常显、不闪、方向键可调、值变了立刻重绘）—— **这部分是好的，
  只有「画面糊不糊」没解决**。
- 用户研究出结果后继续。

---

# ★ v25：POV 诊断判定 —— 相机组件这条路从未生效，改走 PostProcessVolume

**日志铁证（v24 加的那行）**：

```
[FreeCam] DOF apply fstop=2.80 focus=800 readback=2.7999999523163/800.0 w=1.0
[FreeCam] DOF vtag=CameraActor_2147478260
[FreeCam] DOF povFocal=0.0 povW=0.0          ← POV 里压根没有 PP
```

相机组件上 `readback` 完美、`BlendWeight=1.0`、ViewTarget 也确实是我们的
CameraActor —— 但 `PlayerCameraManager.CameraCache.POV` 里的
`PostProcessSettings.DepthOfFieldFocalDistance` 和 `PostProcessBlendWeight`
**都是 0**。说明游戏的相机管理器**不把 CameraActor 的 PP 带进 POV**。

**结论：v19 起的「写相机组件」路线从一开始就不可能生效**，
之前所有 `readback=… 一致` 都只是「结构体自己写成功了」，和渲染无关。
（也解释了为什么「暗角自检」看起来有效——那是移动端管线里别的因素造成的错觉。）

## v25 改动：改用世界里的 APostProcessVolume

`FSceneView` 的后处理来自 `WorldSettings->PostProcessVolumes`，**不经过 ViewTarget
的 POV**，所以不受上面那条限制。

- 新增 `setupDofVolume()`：spawn 一个 `APostProcessVolume`，`bUnbound=true`
  （全屏生效，不依赖包围盒）、`BlendWeight=1.0`。
- spawn 走 `UGameplayStatics.BeginDeferredActorSpawnFromClass` +
  `FinishSpawningActor`（都是 BlueprintCallable，UnLua 能调）；
  `UWorld::SpawnActor` 是 C++ 模板没暴露，只作兜底。
- `applyDof` 抽出 `fillDof(st, blurR)`，**同时**写给相机组件和 Volume
  （组件那条留着作对照，Volume 是主力）。
- 退出时 `BlendWeight=0` + `DestroyActor`，不在游戏世界里留垃圾。
- 新增日志：`PPVOL spawned unbind=…` / `PPVOL spawn failed`；
  `applyDof` 增加 `DOF vol=… volFocal=… volW=…` 读回。

pak **361,169 字节**已安装。

## 下次判定

| 日志 | 含义 | 下一步 |
|---|---|---|
| `PPVOL spawned` + 画面糊 | 成功 | 收工 |
| `PPVOL spawn failed` | 反射接口不对 | 换 `UWorld::SpawnActor` 的其它重载 / 直接用场景现成 volume |
| `PPVOL spawned` 但仍不糊 | 移动端管线连 Volume 的 DOF 也不实现 | 基本到引擎限制，考虑放弃 DOF 或改用后期材质 |

---

# ★ v24：画面不糊的根因 —— 游戏跑的是移动端（ES3.1）管线（2026-10-31 23:5x）

**用户实测**：v11 滑轨正常了（UI 修复确认有效），但**画面依然完全不糊**。

## 决定性证据：启动命令行

```
LogInit: Command Line: -FeatureLevelES31 -ChannelID=jinshan ...
LogConfig: Setting CVar [[r.MobileHDR:1]]
LogConfig: Setting CVar [[r.MobileMSAA:1]]
LogConfig: Setting CVar [[r.Mobile.ForceDepthResolve:0]]
```

**`-FeatureLevelES31` 把引擎锁在 ES3.1 特性级别 → UE4 走 Mobile 前向渲染器**，
不是 PC 的 Deferred。这解释了为什么「PP 能进、readback 全对、cvar 也设上了，
就是不糊」：

- PC 的物理景深（`DepthOfFieldFstop` + 焦平面换算）在移动端**基本不实现**；
  移动端只认 `DepthOfFieldFocalDistance` / `DepthOfFieldDepthBlurRadius` /
  `Near|FarTransitionRegion`（这几项我们已经在写，方向是对的）。
- **`r.MobileMSAA:1` 下 scene depth 是 MSAA 目标，不 resolve 就读不到**，
  而 `r.Mobile.ForceDepthResolve` 默认 **0** —— 移动端 DOF 拿不到深度，
  参数再对也不会糊。这条是最可能的死结。

## 本轮改动

1. `r.Mobile.ForceDepthResolve 1`（加进 `dofCvars`，跟着每 10 秒一起补）。
2. **POV 读回日志**：`DOF povFocal=<值> povW=<值>` —— 读
   `PlayerCameraManager.CameraCache.POV.PostProcessSettings`
   （相机组件上的 readback 只能证明结构体自身写成功，真正进渲染的是 POV）。

pak **354,711 字节**已安装（备份 `.bak-v23`）。

## 下次看日志怎么判

| 日志 | 结论 | 下一步 |
|---|---|---|
| `povFocal=800` + 画面糊了 | 就是 ForceDepthResolve | 收工 |
| `povFocal=800` 但仍不糊 | 移动端 DOF 被其它条件挡住 | 试 `r.MobileMSAA 0`，或改走 Volume |
| `povFocal=0` / `nil` | PP 没进 POV | 改走世界 `APostProcessVolume` |

---

# ★ overlay v11：面板不刷新 —— ULW 的 psize 缓存是元凶（2026-10-31 22:2x）

**用户实测**：「左右键调节时滑轨一点变化都没有；必须按 F9 关掉再打开，数值才刷新。
上下选择也一样。」

## 根因：`UpdateLayeredWindow` 在 psize / pptDst 同时为 NULL 时不重贴内容

v6 为了防闪烁加了「窗口尺寸没变就传 NULL，只换内容」的缓存：

```python
psize = None
if (win_w, win_h) != SZ['wh']:
    SZ['wh'] = (win_w, win_h); psize = byref(size)
UpdateLayeredWindow(hwnd, hdcScreen, None, psize, memdc, ...)
```

实机证明这会让新内容**贴不上去**：尺寸不变时 ULW 直接返回成功但画面不动。
F9 之所以「能刷新」，是因为收起/展开改变了窗口尺寸 → 走的是另一条分支。
`paints=` 计数也印证了：paint 一直在跑（72 次），是 ULW 没把结果贴上去。

**修法**：每次都传 `psize`。传相同尺寸不会触发 resize，不会闪
（v6 的闪烁真正来源是每 120ms 无条件 `ShowWindow`，那条早在 v6 就修掉了，
尺寸缓存属于过度防御）。

## 回归测试（已加进 `runtime/overlay_test.py`）

截图前把 `DOF.fstop/focus` 改成 1.40 / 3333 并置脏，等 0.7s 再抓屏 ——
`overlay_after_key.bmp` 里面板显示 **光圈 1.4 / 对焦 3333**、旋钮位置也变了。
修复前这里会是旧值。

## 另一件事：v23 的景深修复用户还没测到

`Game.log` 最后写入 **22:06:48**，而 v23 pak（351,963 字节）是 **22:09** 才装的 ——
用户 22:16 反馈「依然没效果」时，游戏里跑的还是 v22。**需要重启游戏**才能验证
`r.DOF.Recombine.Quality 3` 那一组改动。

---

# ★ v22：暗角自检给出答案 —— PP 通道通，问题在 DOF 本身（2026-10-31 20:3x）

**实测**：进相机能看到四角暗角 ⇒ `CameraComponent.PostProcessSettings` **确实进了
渲染管线**。所以 v19/v20 怀疑的「PP 没被采用」不成立，问题收敛到「DOF 参数/开关」。

## 三个最可能的压制点，本轮全部处理

1. **`r.DepthOfFieldQuality` 运行时被压 0**（最可能）。启动日志是 `:2`，但手游改端
   常在 gameplay 里关掉整套景深。现在进相机强制 `r.DepthOfFieldQuality 2`，
   并用 `ExecuteConsoleCommand('r.DepthOfFieldQuality')` 把**运行时实际值**打到日志
   （`DOF quality=`），下一次就能确认它到底是不是 0。
2. **cvar 被周期重置**：切场景/进战斗可能把 `r.DOF.Kernel.Max*Radius` 打回 0.025。
   现在每 300 帧（5s）补一次。
3. **物理光圈路径不生效**：加了「深度模糊」兜底 ——
   `DepthOfFieldDepthBlurRadius` 直接给模糊半径，不经过 Fstop 换算；
   强度跟 `fstop` 联动（1.4 → 1.0 最糊，16 → 0 最清晰），保证滑块每一格都有反馈。
   同时补 `DepthOfFieldDepthBlurAmount=1.0` / `MinFstop=1.0`。
4. `r.DOF.Gather.RingCount 4`（原默认可能 1，模糊会碎成块）。

pak **350,671 字节**已安装；备份 `.bak-v20` / `.bak-v21`。

## 下一次验证要看的日志

```
[FreeCam] DOF quality=2          ← 运行时质量，若是 0 就说明被压了（但我们也设了 2）
[FreeCam] DOF apply fstop=.. focus=.. readback=.. w=..
[FreeCam] DOF vtag=<ViewTarget 名>
[FreeCam] DOF sync f=.. d=.. rb=.. rbVig=..
```

如果 `quality=2` 且 `readback` 正确、画面仍然不糊 —— 那就是游戏在
PlayerCameraManager 之后有自己的后处理覆盖，下一步改走世界 `APostProcessVolume`。

---

# ★ v10：找到贯穿 v6~v9 的真正根因 —— 进程名不匹配（2026-10-31 20:3x）

**用户实测**：方向键偶尔能改值（`dof.txt` 变成 `3.00 3800`），但大多数时候没反应；
按 F9 之后「左右似乎能调」（其实是面板收起后方向键漏给游戏、镜头在转）；
UI 之前还自己消失过两次。

## 根因：`GAME_PROCS` 里没有 `games.exe`

```
GAME_PROCS = ('game.exe', 'game-win64-shipping.exe')      # 旧
tasklist 实际: Games.exe   32232   Console   559 MB       # 游戏本体
```

`refresh_pids()` 按映像名精确匹配 → `_game_pids` **永远是空** →
`game_running()` 恒 False。连锁后果：

| 位置 | 后果 |
|---|---|
| `sniffer_state.txt` | `game_pids=[]` 一直为空（早就写着，一直没被当回事） |
| overlay 显隐 | 每 2s 把 `on` 置 0 → **UI 自己消失**；再进相机又出现 |
| `_ovl_on[0]` | 大部分时间是 0 |
| v6/v7 悬停交互 | `hover` 依赖 `prev_on` → 永远 False → 窗口不摘穿透 → **点击全漏** |
| v8 钩子转发 | `_ovl_on=0` → **不转发** → 点击还是漏 |
| v9 方向键 | `_ovl_on=0` → **不拦截** → 按键漏给游戏（镜头转，误以为在调） |

**一条进程名，毁了四版交互。** 之前 v6~v8 一直在「窗口/坐标/样式」上找原因，
方向全错。

## 修复

1. `GAME_PROCS = ('game.exe', 'games.exe', 'game-win64-shipping.exe')`。
   ⚠ 换游戏版本时先用 `tasklist` 核一遍映像名。
2. overlay 的隐藏判定放宽：`game_running() or _launcher_pids` 就认为游戏还在，
   宽限 5s；真退了由 `tick()` 连续 3 拍兜底清 `freecam_on.txt`。
   这样即使以后再遇到映像名变化，也不会再把 UI 弄消失。

## 附带：DOF 为什么始终不生效（本轮加诊断）

日志证据：进入相机只有一条 `DOF apply fstop=2.80 focus=800 readback=… w=1.0`，
且 `r.DOF.Kernel.Max*Radius = "1"`、启动时 `r.DepthOfFieldQuality:2` —— **参数全对**，
但画面就是不糊。说明「写进 CameraComponent 的 PostProcessSettings」**可能根本没进
渲染管线**，而 readback 只能证明结构体写成功，证明不了被采用。

新增自检（Lua v21）：
- 进相机后 **前 1.5 秒给一档暗角**（`VignetteIntensity = 1.5`），之后自动归 0。
  **看得见四角发暗 = PP 通路没问题**，问题只在 DOF 参数；
  **看不见 = 整套 PostProcessSettings 白写**，得改走世界的 `APostProcessVolume`。
- 日志加 `DOF vtag=<ViewTarget 显示名>`（确认游戏相机管理器用的是我们 spawn 的
  CameraActor）与每次值变化的 `DOF sync f=.. d=.. rb=.. rbVig=..`（限流 20 条）。
- `cfg.dofSync` 20 → **6 帧**：60fps 下原来有 0.33s 滞后，按方向键手感发滞。
- pak 更新：**346,389 字节**已安装；旧版备份 `Patch_CamZoomMod-Windows_100_P.pak.bak-v20`。

## 待验证（顺序不能乱）

1. **关游戏** → 关启动器 → 重开桌面启动器（加载 v10 嗅探器，进程名修复在这里）；
2. 开游戏（加载新 pak）→ B 进相机；
3. **先看暗角**：进相机后 1.5 秒内四角应明显发暗 → 记下「有 / 没有」；
4. 按 ↑↓ 看蓝底跳行、按 ←→ 看数值变（这次应该稳定，不再时灵时不灵）；
5. 把光圈调到 1.4 看画面是否变糊；若暗角有、糊没有 → 我再改走 PostProcessVolume。

---

# ★ overlay v9：方向盘调参，彻底放弃鼠标（2026-10-31 20:1x，离线已验证）

**用户决定**：鼠标拖拽三次实机都点不通，不再折腾这条路，**改用方向键**：
↑↓ 选参数、←→ 调数值。

## 改动

1. **删除全部鼠标交互**：分层窗口永久 `WS_EX_TRANSPARENT`，`wndproc` 不再处理
   `WM_LBUTTONDOWN/MOUSEMOVE/LBUTTONUP`，钩子里的 `PostMessage` 转发整段删除，
   `_ovl_rect / _ovl_drag / _ovl_hwnd / LASTFWD / dof_set_from_x` 全部清掉。
   鼠标点击恢复为完全穿透（不再误吞面板区域的点击）。
2. **方向键在钩子里直接拦**（`_key_proc`）：
   ```python
   if vk in _DIRKEYS and _ovl_on[0] and DOF['show']:
       adj_dof(vk); return 1        # 游戏收不到
   ```
   - 只在「拍照模式 + 面板展开」时拦；否则方向键原样给游戏（菜单照常用）。
   - KEYUP 也一起吞，避免游戏收到孤立的抬起。
   - **不进 `KEYS_OF_INTEREST`、不写 `fp_key.txt`、不进 blockList** ——
     所以不用改 Lua / 重打 pak。
3. **钩子里零 IO**：`adj_dof()` 只改内存 + 置 `dirty`；落盘（`dof.txt`）和重绘
   统一挪到 overlay 线程的 80ms 循环里。低级钩子里做文件 IO 有
   `LowLevelHooksTimeout` 风险。
4. `DOF['edit']` / `DOF['drag']` 概念取消：方向键不占用 WASD，**调滑块不再冻结
   相机走位**，`dof.txt` 第 3 字段恒 0。
5. 提示改为常驻两行：`↑↓ 选参数    ←→ 调数值` / `F9 收起面板`；版本 **v9**。

## 验证：`runtime/dof_key_test.py`（新增）

构造 `KBDLLHOOKSTRUCT` 直接调 `_key_proc`（与真实钩子同一函数），实测：

```
down x1 ret=1 -> sel=1        down x1 ret=1 -> sel=0        up x1 ret=1 -> sel=1
right x3 ret=1 -> 3.40 (was 2.80)      left x1 ret=1 -> 3.20
left x100 (clamp) -> 1.40 (下限)       right x200 (clamp) -> 8000 (上限)
dof.txt = 1.40 8000 0
state   = sel=1 fstop=1.40 focus=8000 last=vk=39 ...
```

`ret=1` 证明按键被吞（游戏收不到），clamp 生效，且 overlay 线程把值落盘。

## 键位对照

| 键 | 作用 |
|---|---|
| ↑ / ↓ | 切换参数行（光圈 ↔ 对焦） |
| ← / → | 当前行减 / 加一档（光圈 0.2，对焦 120） |
| 按住 | 系统 repeat，连续微调 |
| F9 | 收起 / 展开面板（收起后方向键还给游戏） |

## 待验证

进相机 → 直接按 ↑↓ 看蓝底在「光圈/对焦」之间跳 → 按 ←→ 看数值变、画面景深变。
若数值不变，看 `overlay_state.txt` 的 `last=` 是否为 `-`（说明按键没进钩子）。

---

# ★ overlay v8：点击改走钩子转发（2026-10-31 20:3x，实机仍失败，已被 v9 取代）

**v7 实机反馈**：仍然点不动；调试中 UI 自己消失了两次又出现。

## 取证：诊断文件说明点击**从未到达窗口**

`overlay_state.txt`：`click=-`（wndproc 一次 `WM_LBUTTONDOWN` 都没收到），
而 `dof.txt` 已变成 `3.80 680`（说明键盘那侧有时是通的）。
`fp_key_raw.txt` 里 `mouse=LMBdown blk=[]` —— **黑名单是空的**，钩子既不吞也不放行，
点击直接透传，窗口却收不到 ⇒ 窗口一直是 `WS_EX_TRANSPARENT`。

## 根因：v6/v7 的「切样式」方案依赖轮询猜悬停，注定不可靠

`hover` 是每 80ms 用 `GetCursorPos` 轮询一次再和 `_ovl_rect` 比 —— 这条链上有
DPI 口径、多屏、tick 时机三重不确定性，任一处对不上就永远 hover=0：
窗口保持穿透 → 点击漏给游戏 → `click=-`。**这不是参数调错，是方案本身错。**

## v8 改法：窗口永久穿透，钩子把事件 PostMessage 转发进窗口

```
系统鼠标事件 → WH_MOUSE_LL(_mouse_proc 手里就有真实屏幕坐标)
   ├─ 光标落在 _ovl_rect 内 且 左键 → PostMessage(窗口, 客户区坐标) + return 1（吞掉）
   └─ 光标在面板外 → 原样放行
```

- **不再切 `WS_EX_TRANSPARENT`**（窗口创建时就带，永不摘除），彻底没有竞态。
- 事件驱动、坐标来自钩子本身，不猜。
- 拖拽：`LBUTTONDOWN` 命中面板 → `_ovl_drag[0]=1`；`MOUSEMOVE` 只在拖拽中转发
  （高频事件平时不转发不吞）；`LBUTTONUP` 无论光标是否甩出面板都转发并清状态。
- `edit`（冻结走位 + 键盘调节）简化为 `ALT 按住 or 正在拖拽`。
- **顺手修了个会让钩子抛异常的真 bug**：`WM_MOUSEMOVE` 常量在模块里没定义
  （`hook_fwd_test.py` 一跑就 `NameError`），而它在 `if` 条件里、不在 `try` 内，
  真实环境会直接打断钩子回调。

## 顺带修「UI 自己消失」

`game_running()` 依赖 1s 一次的 pid 快照，偶发一拍看不到游戏就会：
- overlay 立刻 `on=False` 隐藏 → 用户看到「消失」；
- `tick()` 把 `freecam_on.txt` 清 0 → 更久消失。

现在两处都加宽限：overlay 侧最近 2s 内见过游戏就不隐藏；`tick()` 连续 3 拍
（3s）确认不在才清文件。

## 验证：`runtime/hook_fwd_test.py`（新增，离线全链路）

跳过装钩子（不需要游戏），直接构造 `MSLLHOOKSTRUCT` 调 `_mouse_proc`，实测：

```
in-fstop  hook_ret=1 fwd=LMB 150,322   state: click=120,322 HIT fstop
in-focus  hook_ret=1 fwd=LMB 150,348   state: click=120,348 HIT focus
outside   hook_ret=0                   state: click 不变（没转发）
```

面板内返回 1（吞掉）、坐标换算正确（150 物理 / 1.25 = 120 逻辑命中）、
面板外返回 0 放行 —— 与真实钩子回调走的是同一个函数。

## 待用户验证

1. 重启启动器 → 进相机；
2. 鼠标移到「光圈」滑块上按住左键横拖 → 数值应变、画面景深应实时变；
3. 拖的时候**相机应停住**（`edit=1` 冻结走位），松手后鼠标移开面板 W 能走；
4. 若仍无反应，看 `overlay_state.txt`：
   - `fwd=-` → 钩子没转发（`_ovl_on`/`_ovl_hwnd` 没置上）
   - `fwd` 有值但 `click=-` → PostMessage 到了但 wndproc 没处理

---

# ★ overlay v7：交互入口修正（2026-10-31 20:2x，实机失败，被 v8 取代）

**用户 v6 实机反馈**：版本标记确认是 v6、面板常显正常，但**鼠标和键盘都调不动**。

## 根因判断：v6 把 ALT 当成了唯一入口，而这个前提用户根本不知道

v6 的 `DOF['edit']` 用 `alt and show and prev_on` 三重门控，**同时**控制了：
窗口去 `WS_EX_TRANSPARENT`（能不能收到点击）、键盘 W/S/A/D 调节、写 `dof.txt` 的
`edit=1`（冻结走位）。而提示文案只写了「W/S 选行 A/D 调节」，**没写要按 ALT**；
「按住 ALT · 可拖动」这句又只在 edit=1 时才显示 —— 鸡生蛋，用户永远看不到。

一旦 ALT 判定不成立（没按 / GetAsyncKeyState 读不到），**鼠标点击被钩子吞掉、
键盘分支也不执行，两个入口一起死**，完全复现用户症状。

## v7 改法：交互入口与「冻结走位」解耦

| 判定 | 条件 | 作用 |
|---|---|---|
| 窗口可交互 | `prev_on and (hover or alt or drag)` | 去 `WS_EX_TRANSPARENT`，点击能进 wndproc |
| `edit`（冻结走位 + 键盘调节） | `prev_on and show and (hover or alt or drag)` | 写 `dof.txt` 第 3 字段 |

- **hover = 光标落在 `_ovl_rect` 内**，80ms 一查。鼠标移到面板上就能拖，不需要按
  任何键；拖拽期间 `drag` 条件兜底，甩出面板也不会丢 `LBUTTONUP`。
- 钩子放行条件同步改成「`_ovl_on[0]` 且光标在面板内（或 `_ovl_drag[0]`）」，
  **不再要求 ALT** —— 否则点击照样被吞，窗口收不到 `WM_LBUTTONDOWN`。
- 鼠标移开面板 → `edit` 自动归零，WASD 立刻还给相机（面板不再抢走位键）。
- 顺带修 `WM_LBUTTONDOWN` 坐标：`lp & 0xFFFF` 是有符号 16 位，拖出窗口左侧会
  变成 6 万多 → 滑块跳到最右。改 `ctypes.c_short(...).value`。
- 提示改成两行常驻：`悬停面板可拖动 · ALT 锁视角` / `W/S 选行 · A/D 调节 · F9 收起`。
  版本标记 **v7**。

## 新增诊断：`C:\ProgramData\CamZoomMod\overlay_state.txt`（400ms 覆写）

```
t=2510.4 on=1 alt=0 hover=1 edit=1 exm=1 drag=- hit=2 click=118,352 HIT fstop
```

判读表（一次复现就能定位，不用再猜）：

| 现象 | 结论 |
|---|---|
| `hover=0` 且鼠标明明在面板上 | `_ovl_rect` 与光标坐标口径不一致（DPI） |
| `click=-` | 点击压根没到窗口 → 钩子吞了 / 样式没去透明 |
| `click=… MISS of 2` | 到了窗口但没命中滑块行 → HIT 布局/坐标换算问题 |
| `click=… HIT fstop` 但画面无变化 | 问题在 Lua 侧（`dof.txt` 没读 / DOF 没进 POV） |

## 待验证

1. 重启启动器（Python 改动，pak 不用动）→ 进相机；
2. **鼠标直接移到滑块上拖**（不用按 ALT）→ 数值应实时变、相机应自动停住走位；
3. 鼠标移开面板 → W 应立刻能推相机；
4. 拖完看 `overlay_state.txt`：`click` 一栏应出现 `HIT fstop` / `HIT focus`。

---

# ★ overlay v6：滑块常显 + 修周期性闪烁（2026-10-31 20:0x，代码在盘待实机）

**用户 v20 实测三条反馈**：① 滑块要按 F9 才出现且会消失，要求**常显**；
② **UI 周期性闪烁**（频率不高）；③ DOF 是否出效果未知。

## 1) 滑块常显：`show` 与 `edit` 解耦（这是关键设计）

问题不只是「按 F9 才出现」——旧代码 `DOF['on']` 一个变量同时管三件事：
面板绘制、ALT 可拖拽、写进 dof.txt 的 `edit`（= 冻结相机走位）。
**面板一常显就等于 WASD 永远被滑块吃掉，相机走不动。**

v6 拆成两个状态：

| 字段 | 含义 | 驱动 |
|---|---|---|
| `DOF['show']` | 是否绘制面板 | 默认 **True**；F9 仅作「收起/展开」，进拍照模式自动恢复 True |
| `DOF['edit']` | 交互态 = 冻结走位 + 可拖拽 | **ALT 按住**（游戏本来就用它呼出鼠标指针），松开立刻把 WASD 还给相机 |

- `dof.txt` 第 3 字段现在写 `edit`（ALT），不再写 panel 开关。
- 退出拍照模式时 `edit` 强制归零并**只写盘一次**，避免相机走位被永久锁死。
- 编辑态时标题「景深」转亮蓝、右侧出现「按住 ALT · 可拖动」，给即时反馈。
- 底部提示文案改为 `W/S 选行    A/D 调节    F9 收起`；版本标记 **v6**。

## 2) 周期性闪烁：两处根因，都在「无条件重复调用」

1. **每 120ms 无条件 `ShowWindow(SW_SHOWNA)`**（旧 L1190）。对已显示的**分层**
   窗口反复 show 会让 DWM 重新合成 —— 8.3Hz，正是用户描述的「频率不高」。
   → 现在 `prev_on` 记录可见状态，**只在状态真变化时**调一次。
2. **每次 `UpdateLayeredWindow` 都带 `psize`**。尺寸参数就算没变，也会让分层窗口
   走「调整尺寸」路径（卸表面重贴）。→ 加 `SZ['wh']` 缓存，尺寸没变传 `NULL`。

附带：`SetWindowPos(SWP_FRAMECHANGED)` 只在 ALT 状态切换时执行（本来就有条件），
不再每拍触发整窗重算。

## 3) 定时器：单 80ms + 时间戳节流

试过拆成 991(80ms)/992(400ms) 两个 `SetTimer` 分频，**`msg.wParam` 分支在实测里
不触发**（overlay_test 里窗口一直不显示）→ 改回单定时器 991/80ms，显隐用
`now >= next_vis` 节流到 400ms。逻辑更直白，也不依赖 wParam 语义。

## 4) DOF 到底生不生效 —— 日志取证：**三项配置全部到位**

从 `E:\SeasunCBJQos\Game\cbjq\game\Saved\Logs\Game.log`（19:36-19:37 那次 v20 实测）：

- `[FreeCam] DOF apply fstop=2.80 focus=800 readback=2.7999999523163/800.0 w=1.0`
  → ① FPostProcessSettings 写穿成功 ② `PostProcessBlendWeight = 1.0`
- `r.DOF.Kernel.MaxForegroundRadius = "1"` / `MaxBackgroundRadius = "1"`
  → 进入相机时 cvar **确实改成 1.0**（游戏默认 0.025 已解除）
- 退出时两行还原为 `0.025` ✓
- 启动日志 `r.DepthOfFieldQuality:2` → 高质量 DOF 管线**是开着的**，不会跳过

**结论**：能配的都配上了，参数不是瓶颈。若实机调到 Fstop 1.4 仍然一点不糊，
只剩一种可能 —— **ACameraActor 的 POV PostProcessSettings 没被游戏相机管理器采用**。
下一轮若仍无效果，按序加诊断（都要重打 pak）：
1. 进相机时打 `pc:GetViewTarget()` 的类名，确认 ViewTarget 真是我们的 CameraActor；
2. 打 `pc.PlayerCameraManager` 当前 `CameraCache`/`PendingViewTarget`；
3. 备选路径：世界 `UPostProcessVolume`（`bUnbound=true` + `BlendWeight=1`），
   它走 `WorldSettings→PostProcessVolumes` 收集，不依赖 ViewTarget POV。

## 5) 验证（offline，已通过）

`runtime/overlay_test.py` 本轮加了两处修正：
- 铺一张 `SS_WHITERECT` 纯白 STATIC 背景（真实桌面/游戏画面是**动态**的，
  两次抓屏之间它自己会变 → 原来全屏 diff 会得到「全屏都不同」的假结果）；
- diff **只在窗口矩形内统计**，并打印窗口矩形。
- 等 `IsWindowVisible` 轮询确认可见（显隐走 400ms 节流，原来 0.4s 正好踩边界）。

实测：`rect = 48 48 313 428`（265×380，面板常显不再伸缩）、
`diff bbox = (48,48,312,427)` 与窗口矩形**完全吻合**、BMP 确认六行键位 + 景深面板
（光圈 5.6 / 对焦 1200 双滑块）+ 底部提示完整无裁切。

## 6) 待用户实机复验（本轮只改了嗅探器 Python，pak 不用重装）

1. 点桌面「尘白禁区-本地服」（一次 UAC）→ `sniffer_state.txt` 应有
   `hooks=on elevated=1`；
2. 进游戏按 **B** 进自由相机 → **UI 一进来就有滑块面板**（无需 F9），
   且**不再周期性闪烁**（盯 30s 确认）；
3. **按住 ALT**：标题「景深」变亮蓝 + 右侧出现「按住 ALT · 可拖动」→ 拖动滑块，
   画面景深应实时变化；松开 ALT 后 **WASD 应立刻能走相机**（这是本轮改动的核心，
   务必验：常显面板不能抢走走位键）；
4. 调到光圈 **1.4** 看是否明显模糊；若完全无变化，把 `Game.log` 里
   `[FreeCam] DOF` / `r.DOF.Kernel` 行发我，按上面第 4 条加诊断；
5. 退出拍照模式 → 面板消失；再进 → 面板自动回来；F9 可收起（可选）。

---

# ★ v20 实测结果 + 下轮任务（2026-10-31 19:37 记录 —— 三项已由上方 overlay v6 处理）

**本轮已交付（代码在盘上，未再改动）**：
- pak v20 = 341,393 字节已安装（Lua v20）；嗅探器 overlay v5（runtime/wheel_sniffer.py）。
- Lua v20：景深改 `CameraComponent.PostProcessSettings` + `PostProcessBlendWeight=1`；
  进相机 `ExecuteConsoleCommand` 把 `r.DOF.Kernel.MaxForegroundRadius/MaxBackgroundRadius`
  提到 1.0，退出还原 0.025；日志 `DOF apply ... readback=... w=`。
- 嗅探器 v5：ALT+面板打开时去 `WS_EX_TRANSPARENT` 变可交互；钩子对「ALT+光标在
  面板矩形内（`_ovl_rect`）」的左/右键放行；WM_LBUTTONDOWN 命中 HIT 行 → 按 x 反算
  值写 dof.txt + 节流重绘（80ms）。降采样换 GDI StretchBlt(HALFTONE) DIB→DIB
  （2x 画布 = CreateDIBSection + GDI 经 GdipCreateFromHDC 画入；~30ms/帧）。

**实测反馈（用户 19:37 报告）**：
1. **滑块消失**：面板要按 F9 才出现，且出现后消失 —— 用户明确要求
   **滑块必须常显在 UI 上**，不要 F9 专门面板。
2. **UI 周期性闪烁**（频率不高）。
3. DOF 是否出效果**未知**（本轮用户没提模糊，很可能没来得及验证或仍未生效）。

**下轮任务（按序）**：
1. **滑块常显**：去掉 F9 门控 —— `paint()` 无条件绘制景深面板（DOF['on'] 语义改为
   「面板常驻」，可保留 F9 作为可选显隐但默认开）。窗口高度固定 ~430，不再伸缩。
2. **修闪烁**（已定位嫌疑，未动手）：`wheel_sniffer.py` L1190
   `u.ShowWindow(hwnd[0], 8 if on else 0)` **每 120ms 无条件调用** —— SW_SHOWNA 反复
   作用于已显示层窗口会触发重排/重合成闪烁。修法：记录 `_vis` 状态，仅在变化时
   调用；同理 ULW 尺寸未变时不重设。可再把定时器拆成「显隐 500ms + 交互 80ms」。
3. **验证 DOF 是否生效**：日志 grep `DOF apply`（`w=` 应为 1.0）与进入相机时的
   `r.DOF.Kernel.MaxForegroundRadius 1.0` LogConfig 行。若 cvar 没生效：考虑直接在
   `DefaultEngine.ini`？不可（游戏 pak 只读）—— 备选 `ExecuteConsoleCommand` 换
   `K2_ExecuteConsoleCommand`（PlayerController 上的同名 UFUNCTION）或
   `APlayerController::ConsoleCommand`。若 PP 仍不生效：查 ViewTarget 是否真是我们的
   CameraActor（`pc:GetViewTarget()`），必要时改用世界里的 UPostProcessVolume。
4. 顺带：ALT 拖拽需实机确认（本轮未验证到）。

---

# ★ v20 景深修正 + ALT 鼠标拖拽（2026-10-31，待实机验证）

**v19 实机结果：完全无效果。根因（日志取证）**：
1. v19 挂 `UPostProcessComponent` 能写进 Settings（`readback=2.8/800` 一致），但游戏
   相机管理器不收集 ViewTarget 上的 PP 组件 → 画面无变化。
2. **游戏启动时把 DOF 核半径钳死**：日志 `LogConfig: Setting CVar
   r.DOF.Kernel.MaxForegroundRadius:0.025` / `MaxBackgroundRadius:0.025` ——
   0.025 的模糊核肉眼不可见。（当初 grep `r.DepthOfField*` 漏了 `r.DOF.*` 前缀。）

**v20 修法**：
- 景深改走 **CameraComponent.PostProcessSettings + PostProcessBlendWeight=1**
  （GetCameraView 会把相机组件的 PP 带进 POV，标准照片模式路径）。
- 进相机时 `ExecuteConsoleCommand` 把 `r.DOF.Kernel.MaxForegroundRadius/
  MaxBackgroundRadius` 提到 **1.0**，退出还原 **0.025**（游戏默认值，日志实证）。
- 日志保留 `DOF apply ... readback=.../... w=...`（w=PostProcessBlendWeight）。

**ALT + 鼠标拖拽（嗅探器 overlay v5）**：
- 游戏里**按住 ALT 会呼出鼠标指针** —— 借此做拖拽：ALT 按住且景深面板打开时，
  overlay 去掉 `WS_EX_TRANSPARENT` 变可交互；钩子对「ALT + 光标在面板矩形内」的
  左/右键**放行**（`_ovl_rect` 全局由 paint 更新），面板外照常吞掉防误触。
- 拖动滑块：WM_LBUTTONDOWN 命中行（paint 时记录 HIT 逻辑矩形）→ 按鼠标 x 反算
  值（光圈对数刻度/对焦线性）→ 写 dof.txt + 立即重绘（移动节流 80ms）。
- **降采样改 GDI StretchBlt(HALFTONE)，DIB→DIB**：v19 的纯 Python 盒滤波 0.4s/帧
  拖不动滑块；GDI+ DrawImage 本机 AV（探针 6）；GdipGetDC 交叉读不可靠（实测空帧）。
  现在 2x 画布本身是 CreateDIBSection，GDI+ 用 GdipCreateFromHDC 画进去，
  StretchBlt 拉伸到窗口 DIB —— 全程 GDI 表面，~30ms/帧，拖动流畅。
- 键盘 W/S 选行 + A/D 调节保留作备用。版本标记 v4 → **v5**。

**待实机验证**：B 进相机 → F9 → 按住 ALT 呼出鼠标 → 拖动光圈/对焦 → 画面景深应
实时变化（光圈越小越糊）；松开 ALT 恢复穿透。若仍无效果：看日志
`DOF apply ... w=` 的 w 是否 1，以及进相机时有没有 `r.DOF.Kernel.*Radius 1.0` 的
LogConfig 行。

---

# ★ v19 景深模糊（F9 面板）—— 实机无效果，被 v20 取代（2026-10-31）

**需求**：滑块选项调整景深模糊。

**方案（侦查结论落地）**：Game.exe 无 r.DepthOfField* cvar（shipping 裁掉），DOF 全是
**FPostProcessSettings 反射属性**（DepthOfFieldFstop / FocalDistance /
Near/FarTransitionRegion + bOverride_*）。APlayerCameraManager 会收集 ViewTarget
（= 自由相机 Actor）上的 **UPostProcessComponent** 并应用 —— 所以：

- **Lua v19**：进入相机时 `UE4.NewObject(UPostProcessComponent, camActor)` +
  RegisterComponent，写 `Settings.bOverride_DepthOfFieldFstop/FocalDistance/
  Near-FarTransitionRegion = true` + 值，`BlendWeight=1`、`bUnbound=true`；
  每 20 帧读 `dof.txt`（`"fstop focus edit"`）同步；`edit=1` 时冻结相机走位
  （WASD 让给滑块）；进入时日志 `DOF apply fstop=... readback=...`，若 readback
  与期望不符说明 UnLua 链式 struct 写穿不生效（已加 `c.Settings = st` 兜底回写）。
- **嗅探器（overlay v4）**：**F9** 开关「景深 · F9」面板；**W/S** 选行、**A/D**
  调节（按住连续，120ms 定时器）；参数写 dof.txt。panel 高亮选中行、轨道+白色
  填充+圆形旋钮+数值。版本标记 v3 → **v4**（截图自证）。
- 键位：F9(120) 加进 KEYS_OF_INTEREST + Lua blockList；F9 由嗅探器内部消费，
  游戏收不到。面板打开时 dof.txt edit=1，Lua 冻结相机走位。
- **滑块用键控不做鼠标拖拽**：游戏鼠标走 Raw Input，拖拽会和镜头旋转打架；
  键控（W/S/A/D 按住连续调）稳定且不需要改钩子放行逻辑。

**待实机验证**：B 进相机 → F9 打开面板 → 调光圈（1.4~16，越小越糊）/对焦
（100~8000cm）→ 画面景深应实时变化；调参时相机不应走动（edit=1 冻结）；
F9 关闭 → WASD 恢复；日志确认 `DOF apply ... readback=` 的 readback 与实际一致。
若画面无任何模糊：看日志是 `DOF no UPostProcessComponent class`（类不可见）还是
readback 不符（写穿失败，需换 UnLua 内联 struct 写法）。

---

# ★ overlay v3：防锯齿 + 生命周期绑定（2026-10-31，已验证）

**用户反馈三件事**：① 字体/按钮锯齿多 ② Alt+F4 强退游戏后 UI 残留屏幕 ③ 嗅探器
别占额外程序/UAC，绑定到本地服启动器生命周期。另：下一轮做景深模糊滑块（见末节）。

**① 防锯齿（wheel_sniffer.py overlay v3）**
- main() 开头声明 DPI 感知（PerMonitorV2，回退 SetProcessDPIAware）——不分层窗口
  会被 DWM 按虚拟化坐标拉伸。
- **2x 超采样 + 2x2 盒滤波降采样**：绘制坐标 ×K 落到 (2W1,2H1) 位图，画完纯 Python
  盒滤波（0x00FF00FF 双通道打包技巧，224K 次标量循环 ~0.5s）回物理尺寸。
- ⚠ **本机 gdiplus.dll 的 `GdipDrawImageRectRect` 原生 AV（探针 6）**——降采样只能
  纯 Python，GDI+ 只画不缩。
- ⚠ **键帽宽度不再做字体测宽，按内容硬编码**（`estw`：CJK 15px/字、ASCII 8px/字；
  `draw_cap`：单字母 36、ESC 44、双汉字 50）。原因（实机三连击）：GdipMeasureString
  本机不可用；GDI GetTextExtentPoint32W 与 GDI+ DrawString 的 em 口径不一致；最终
  发现**盒滤波源索引写错**（`base + dx` 应为 `base + 2*dx`）—— 等于把 2x 大图原尺寸
  塞进 1x 位图，全部内容撑大 2 倍、右侧被窗口裁掉（「挤压 + 显示不全」的真正元凶）。
  布局与绘制同源（draw_cap 返回宽度给布局用），窗口宽度由布局推出，保证装得下。
- **标题旁有半透明 `v3` 版本标记**：以后看截图即可确认跑的是哪版 overlay。
- overlay_test.py 实跑验证：窗口 265×278；BMP 像素级测量 —— 键帽 36 宽、间距 43、
  右边界 230 全部在窗口内；六行完整（含 ESC 行）。

**② 游戏退出 → UI 消失**
- overlay 定时器可见条件追加 `game_running()`：游戏一死立即隐藏（300ms 内）。
- tick() 检测游戏不在 + freecam_on.txt=='1' → 清写 '0'（Lua 强退没机会写的残留）。

**③ 启动器绑定（launcher.py + wheel_sniffer.py --launcher-pid）**
- launcher.py：main() 服务启动后 `start_sniffer()` —— 先按 sniffer.pid 杀旧实例
  （防互斥量占位），再以 pythonw 分离进程拉起 wheel_sniffer.py，带
  `--launcher-pid <pid>`；**继承启动器的管理员令牌，零额外 UAC**。
- wheel_sniffer.py：`--launcher-pid` → tick() 连续 3 次探测启动器进程不在
 （OpenProcess + QueryFullProcessImageNameW 防 pid 复用）→ 卸钩子 + 自尽。
- `/stop_app`（关闭全部服务）→ stop_sniffer() + 启动器 os._exit —— 完全关闭本地服
  = 完全关闭嗅探器。
- **启动器已重打包并替换桌面 `尘白禁区-本地服.exe`**（旧版备份：
  `launcher/SnowbreakLocalServer.desktop-bak-20261031.exe`）。桌面 exe 与
  dist/SnowbreakLocalServer.exe 均为新版（10,653,088 字节）。
- vbs（restart_sniffer_admin.vbs）保留作手动兜底。

**复验清单**：双击桌面启动器（UAC 一次）→ sniffer_state.txt `hooks=on elevated=1`
且出现于启动后数秒内；B 进拍照模式 → 键帽 UI 平滑无锯齿；游戏 Alt+F4 → UI 立即消失；
控制台「关闭全部服务」→ pythonw 进程消失；单独跑游戏不启动本地服 → 无嗅探器（预期）。

---

# ★ 下一轮：景深模糊滑块（侦查已完成）

Game.exe 字符串侦查：DOF 全是 **FPostProcessSettings 反射属性**
（DepthOfFieldFstop / DepthOfFieldFocalDistance / DepthOfFieldDepthBlurRadius /
DepthOfFieldNearTransitionRegion / DepthOfFieldFarTransitionRegion +
bOverride_* 开关），无 r.DepthOfField cvar（r.ScreenPercentage 存在，控制台通路可用）。

**方案**：给自由相机的 ACameraActor **NewObject 挂 PostProcessComponent**（UnLua
反射设 Settings 的 bOverride_* + DepthOfField* 字段，BlendWeight=1）→ 滑块直接写
Fstop（光圈，越小越糊）/ FocalDistance（对焦距离）。滑块 UI 需要交互模式：
按键切换「编辑态」——overlay 去 WS_EX_TRANSPARENT 接管鼠标，钩子按「光标在
overlay 矩形内 + 编辑态」放行 LMB（同一进程共享状态，_mouse_proc 可查），
退出编辑态恢复穿透。**下一轮先做 Lua probe（挂组件+设字段验证模糊可见），再做滑块。**

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
