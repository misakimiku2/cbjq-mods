# 尘白禁区 pak 解密 · 交接（2026-10-30）

> 结论：**社区 AES key 对 3.6.0 有效，635/637 个 pak 索引全部可解**。
> `work/HANDOFF.md:761 / 766` 里「资源层被 AES + ACE 双重锁死、到此为止」的判断**作废**。

## 一、为什么之前一直提示"没有 key"

有三层，缺一层都读不出来，所以用标准工具（FModel / repak）会报缺 key 或直接崩：

| # | 层 | 解决方式 |
|---|---|---|
| 1 | pak AES 主密钥 | 社区公开值（4chan /snowg/、qiyun71 教程、CS.RIN.RU 合集三处一致） |
| 2 | footer 里的 IndexOffset 被**异或混淆** | `realOffset = storedOffset ^ 0x1C1D1E1F` |
| 3 | footer 里的 IndexSize **不可信** | `realSize = (EOF - 0xCC) - realOffset - 1` |

第 2、3 层是尘白自定义的（CUE4Parse 里 `GAME_Snowbreak` 被列进 "custom pak version" 名单，
但 `FPakInfo` 并不做这个异或），所以：

- **FModel / CUE4Parse 直接读会失败** —— 它按原值 seek，落到文件外或垃圾区
- 索引内部还有 `0x1F1E1D1C` 的文件数据偏移异或（尚未实现，见第四节）

## 二、索引怎么解

```
perPakKey = AES-256-ECB-Encrypt(masterKey, ascii(md5hex(pak文件名小写, 不含 .pak)))
                                                                  ↑ 无 padding，正好 32 字节
toc       = AES-256-ECB-Decrypt(perPakKey, pak[realOffset .. realOffset+realSize])
```

即 `work/SnowbreakAes.cs` 里那套派生，**推导是对的**，之前失败纯粹是第 2/3 层没做。

解出来的 toc 是标准 UE4 索引：`FString 挂载点` + 条目表。实测：

- `APP_Game_Materials_0` → `../../../Game/Content/Materials/`，475 个文件，
  里面有 `outline_mat` / `outline_PreBakeNormal_mat` / `character_main_mat` / `character_skin_mat`
- `PAK_Game_Script_0` → `../../../Game/Content/Script/`，**5007 个 .lua**，
  其中 `Shop.lua`、`Shop/`、`IBShop.lua`、`Purchase/` 等 158 个与商店相关

## 三、工具

```bash
KEY=$(cat tools/.snowbreak-key)
NODE=C:/Users/MisakiMiku/.workbuddy/binaries/node/versions/22.22.2-6/node.exe

# 索引级：验证 / 列文件名
$NODE tools/snowbreak_pak.js $KEY verify "<pak路径>" --list=lua
$NODE tools/snowbreak_pak.js $KEY sweep "E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks"

# 文件级：真正抽取
$NODE tools/snowbreak_extract.js "<pak路径>" "<输出目录>" --limit=10 --write
$NODE tools/snowbreak_extract.js "<pak路径>" "<输出目录>" --grep=ShopLogic,goodsList --dump
```

实测结果：`total=637 pass=635 plain=1 error=2`。
两个 error 是**自己打包的 mod**（`Patch_AntiAmend` / `Patch_CamZoomMod`，repak 出的是标准
UE4 footer，没有异或），属于预期，不影响读官方包。

抽取实测：Materials 包 475 个、Blueprints 包前 300 个、Script 包 5009 个，**0 失败**；
解出的 `.uasset` 头部是标准魔数 `C1 83 2A 9E`，长度与 `UncompressedSize` 完全一致。

## 四、条目与数据布局（已实测）

```
TOC 头: mount(FString) files(4) dummy(12) hashesOff(8) hashesSize(8) dummy(24)
        namesOff(8) namesSize(8) dummy(24) baseEntryOff
hashes: 区首 4 字节计数，随后每文件 12 字节 = (u64 名字哈希, u32 条目相对偏移)
entry : FLAGS(4) [chunk(4)] offset(4|8)      FLAGS>>28==0xE → 4 字节；offset ^ 0x1F1E1D1C
region: 文件区域起始处的内联头
        [0(8)] size(8) usize(8) method(4) hash20(20) blockCount(4) blocks(16×n)
        压缩块偏移相对区域起点；每块 AES-256-ECB(perPakKey) → zlib inflate
        未压缩(method=0)：数据起点 = 区域起点 + 53（头部 SHA1 反查确认）
```

**SHA1 是最好用的校验器**：内联头里的 20 字节就是原始数据的 SHA1，
找数据起点/确认解压正确都靠它。

## 五、Lua 层还没解开（下一步）

`PAK_Game_Script_0` 里 5009 个文件能抽出，但**内容仍是密文**，用已知的
`E1671E910EB54736B49908575F08CAFB` 解不开。证据：

- 数据起点用 SHA1 校验过，排除了偏移错误
- 1327/1426 个 16 字节块互不相同 → 不是填充、不是压缩
- 密文呈 16 字节周期 → 是 ECB 类块加密，不是流加密
- 试过 master / per-pak / 每文件 md5 派生 四种 key × ECB / CBC(零IV) / CBC(首块IV) / CTR
  共 16 种组合，全部解出乱码，无 `1B 4C 75 61` 字节码头魔数

**结论**：CUE4Parse 里那个 `SnowbreakLua` 常量（署名 ByteFun）对这些文件不成立，
可能是旧版本/只对 mod 文件有效。

**建议改走运行时**（成本低得多，且不依赖这个 key）：
在已注入的 `umg_main` 里对 `package.loaded` 枚举模块，用 `string.dump(fn)` 把函数
dump 成字节码再反编译；或 `debug.getinfo(fn).source` 拿 chunk 名。这条路绕开文件层，
拿到的是运行时已解密的代码。

**已实施**：`work/probe/shopprobe.lua` + `work/build_probe.js` + `work/probe/parse_log.js`。

```bash
node work/build_probe.js      # 产出 work/probe/Patch_ZShopProbe-Windows_100_P.pak
# 装之前把 Patch_CamZoomMod-..._P.pak 改名 .bak（两个 pak 会抢 umg_main.lua）
node work/probe/parse_log.js  # 跑完游戏后解析 Game.log，hex 字节码还原成 .luac
```

探针要点：每 5s 扫一轮（**商店模块可能懒加载**，必须进界面才会 require），
只转储上一轮没见过的模块；`string.dump` 可用时优先 `io` 直接落盘，
不可用时退化成 hex 打日志。启动时序照抄 camzoom（先试 Timer，失败挂 Event.Logined）。

## 六、注意

- key 存在 `tools/.snowbreak-key`，**不要**加进 `sync_to_github.sh` 的两个发布仓库
- 游戏已停更半年，key 不会轮换，但版本号变化仍要重新验证
- 修改资源仍走 patch pak（这条路已验证可用），解包只是"看得见"
- `tools/_probe_toc.js` 是反推布局时的临时探针，可删
