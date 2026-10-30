# 全量协议采集 · 操作流程

> 目的：把「登录后默认加载」之外的模块也扫进来（背包/角色/邮件/任务/抽卡/活动…），
> 并把模块表里的字符串常量 dump 出来，用来还原 `Chapter.REQ_ENTER_LEVEL` 这类符号名。
>
> 本版探针是**持续发现**的：每 0.5 秒重新检查一次 `package.loaded` 和全局表，
> 新出现的模块立刻补扫。所以**操作顺序不重要，只要游戏开着就会一直扫**。

## 一、准备（游戏必须关闭）

```bash
# 1) 确认 Game.exe 没在跑
tasklist | grep -i "^Game.exe"

# 2) （推荐）清掉上一轮的产物，避免新旧混在一起
cd D:/test/cbjq-re
rm -f work/_dump/PROTO_*.luac work/_dump/tables.tsv
```

探针 pak 已经装好（`Patch_ZShopProbe-Windows_100_P.pak`，75,869 B）；
模组 pak 仍是 `.pak.bak`，两者不共存，本轮不用恢复。

## 二、进游戏点界面

通过 `SeasunGame.exe` 正常启动 → 登录 → 进大厅，然后**把下面每个界面各打开一次，每个停留 3~5 秒**
（画面真正出来才算加载完成）：

| 顺序 | 界面 | 备注 |
|---|---|---|
| 1 | 背包 | 各分类页签都点一遍（材料 / 道具 / 武器 / 意识） |
| 2 | 角色 | 列表 + 随便点一个角色进详情 |
| 3 | 武器 / 意识 | 各进一次列表 |
| 4 | 邮件 | 点开一封，别点领取 |
| 5 | 任务 / 成就 | 各进一次 |
| 6 | 抽卡 | 进卡池页即可，不用抽 |
| 7 | 商城 | 常规物资 / 活动兑换 / 循环中心 / 数据百货 / 甄选好物，每个页签点一遍 |
| 8 | 活动中心 | 任意活动卡片点开一次 |
| 9 | 战令 / 爬塔 / 玩法入口 | 有就进一下 |
| 10 | 好友 / 设置 | 各进一次 |

**点完回到大厅再待 30 秒**，让扫描器把最后加载的模块扫完，然后退出游戏。

## 三、判读（可选，想确认有没有在扫）

游戏运行时看日志：

```bash
grep "PROTO tick" "E:/SeasunCBJQos/Game/cbjq/game/Saved/Logs/Game.log" | tail -3
```

`scanned=` 和 `dumped=` 持续增长 = 正常。收尾行：

```
[ShopProbe] PROTODONE ticks=N scanned=N dumped=N
```

> 扫描器上限 30 分钟（3600 × 0.5s）。到点没退出也没关系，已扫到的都已落盘。

## 四、跑完之后

交给 AI 或自己执行：

```bash
NODE=C:/Users/MisakiMiku/.workbuddy/binaries/node/versions/22.22.2-6/node.exe
cd D:/test/cbjq-re
$NODE work/probe/scan_protocol.js work/_dump            # 看统计
$NODE work/probe/scan_protocol.js work/_dump --md > work/PROTOCOL.md
$NODE work/probe/scan_protocol.js work/_dump --json > work/probe/protocol.json
```

再用 `work/_dump/tables.tsv` 把符号名还原成字面量接口名。

## 五、产出物位置

| 内容 | 路径 |
|---|---|
| 含网络调用的函数字节码 | `work/_dump/PROTO_*.luac` |
| 模块表的字符串键值 | `work/_dump/tables.tsv` |
| 接口清单（人读） | `work/PROTOCOL.md` |
| 接口清单（结构化） | `work/probe/protocol.json` |

## 六、收尾：恢复模组

```bash
cd "E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks"
rm Patch_ZShopProbe-Windows_100_P.pak
mv Patch_CamZoomMod-Windows_100_P.pak.bak Patch_CamZoomMod-Windows_100_P.pak
```
