# 尘白禁区 · 镜头 Mod 合集（CamZoomMod + FreeCamMod）

《尘白禁区》战斗镜头增强模组：**滚轮推拉镜头（CamZoomMod v92）+ 自由相机拍照（FreeCamMod v15）**，
两模组合并为一个 pak 共存（注入点相同，分装会争抢同名文件）。

> ⚠️ 本项目为玩家自制非官方内容，与游戏官方（西山居 / Seasun）无任何关联。
> 请自行评估并承担可能的封号风险；不建议在官方公开平台宣传模组。

## 功能

**CamZoomMod（滚轮缩放镜头）**
- 战斗/自由场景中滚轮推拉第三人称镜头（基准约 3.2m，拉近约 0.95m，拉远约 5.8m）
- 带平滑过渡；拉近到人物居中时 UI 自动淡出，开镜/切人/起跑演出自动让位
- 进入战斗约 2.5s 后自动校准镜头参数（相机会短暂抖动，正常现象）

**FreeCamMod（自由相机）**
- 拍照模式自由移动相机；激活期间 CamZoomMod 整体挂起，互不打架
- 共存协议：`_G.FreeCamActive` 写递增帧号做死人开关，2s 不递增即强制恢复

## 安装

1. 复制 `releases/Patch_CamZoomMod-Windows_100_P.pak` 到游戏 Paks 目录：
   `<游戏目录>\Game\cbjq\game\Game\Content\Paks\`
2. 双击 `releases/CamZoomSniffer.exe`（滚轮嗅探器），UAC 弹窗点"是"
3. 启动游戏，进场景后滚一下滚轮即可自动标定

> **为什么需要嗅探器 exe**：游戏没有滚轮轴映射（Input.ini 中 0 条 AxisMapping），
> Lua 侧读不到滚轮，必须有外部程序把滚轮事件写盘给模组读取。
> 它只在 `Game.exe` 运行时挂低级钩子（游戏是管理员进程，UIPI 规定低权限钩子收不到
> 高完整性进程的输入），不联网、不读写游戏内存。源码见 `../runtime`（local-server 仓库）
> 或本仓库 `re-tools`。务必以管理员运行，否则"游戏前台时滚轮无反应"。

## 构建

```bash
# 1. 用 repak 从游戏 pak 提取 umg_main（构建基底，不入库）
# 2. 注入 Lua 源码（camzoom/ 与 freecam/ 目录内源文件）
node build/build_both.js
# 3. 用 repak 打包为 Patch_CamZoomMod-Windows_100_P.pak
```

## 目录结构

```
cbjq-mods/
├── camzoom/         # CamZoomMod Lua 源码 + 交接文档（v54→v92 全迭代记录）
├── freecam/         # FreeCamMod Lua 源码 + 交接文档
├── build/           # pak 构建脚本（build_mod / build_freecam / build_both / lint）
├── re-tools/        # pak/AES 逆向工具集（C++/C#/JS/Rust）
├── releases/        # 可直接安装的成品（pak / 嗅探器 exe / zip）
└── HANDOFF.md       # 主交接文档：架构、坑点清单（UIPI / 消息泵 / 死人开关）
```

`HANDOFF.md` 是最有价值的工程笔记，记录了全部踩坑过程：
钩子必须由管理员+Explorer 启动、`GetMessageW` 阻塞泵不能用 PeekMessage 轮询、
freecam/camzoom 死人开关协议等。

## 致谢

- [ahalpha/Snowbreak-AnitAmend](https://github.com/ahalpha/Snowbreak-AnitAmend) — 模组打包方式与目录结构参考
- [repak](https://github.com/trumank/repak) — Unreal .pak 打包/解包工具

## 许可

本仓库不含任何游戏官方原始资源文件（构建所需基底请自行从本地游戏提取）。
