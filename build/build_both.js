// ============================================================
// 合并构建脚本（v92）：一个 pak 同时装 CamZoomMod + FreeCamMod
//   为什么必须合并：两个 MOD 的注入点是同两个 Lua 文件（游戏仅有的两个
//   Lua 起始点），分装两个 pak 会争抢同名文件，覆盖优先级按名字排序不可靠。
//   两者各自的 _ready 守卫（CamZoomMod / FreeCam）天然防重入，双文件注入时
//   只有先加载那份会执行，后一份整块跳过 —— 与 v87 单 MOD 的注入模式一致。
//   共存协议见 camzoom/proto49.lua 顶部 v92 注释（_G.FreeCamActive）。
//
//   源  : work/camzoom/proto49.lua + work/freecam/protov1.lua
//   产物: work/merged-mod-new.pak -> Patch_CamZoomMod-Windows_100_P.pak
// ============================================================
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const LUA_KEY = Buffer.from('E1671E910EB54736B49908575F08CAFB', 'latin1');

function encryptLua(text) {
  const data = Buffer.from(text, 'utf8');
  const aligned = data.length - (data.length % 16);
  const c = crypto.createCipheriv('aes-256-ecb', LUA_KEY, null);
  c.setAutoPadding(false);
  const head = Buffer.concat([c.update(data.subarray(0, aligned)), c.final()]);
  return Buffer.concat([head, data.subarray(aligned)]);
}

const ROOT = 'D:/test/cbjq-re';
const CAMZOOM_SRC = path.join(ROOT, 'work/camzoom/proto49.lua');
const FREECAM_SRC = path.join(ROOT, 'work/freecam/protov1.lua');
const MODDIR = path.join(ROOT, 'work/merged-mod');
const AA = path.join(ROOT, 'antiamend-src/Basic-Universal/ExtractedAssets');

const camzoom = fs.readFileSync(CAMZOOM_SRC, 'utf8');
const freecam = fs.readFileSync(FREECAM_SRC, 'utf8');

// 代码级耦合检查（双向）：两个 MOD 只允许通过 _G.FreeCamActive 这一个约定
// 接口通信，不许取用对方的全局表成员。
const freecamCoupled = freecam.match(/\bCamZoom(?:Mod|Sniffer)?\s*\.\s*[A-Za-z_]/) ||
                       freecam.match(/_\s*G\s*\[\s*['"]CamZoom/);
if (freecamCoupled) throw new Error('freecam 源码耦合了 CamZoom: ' + freecamCoupled[0]);
const camzoomCoupled = camzoom.match(/\bFreeCam\s*\.\s*[A-Za-z_]/) ||
                       camzoom.match(/_\s*G\s*\[\s*['"]FreeCam/);
if (camzoomCoupled) throw new Error('camzoom 源码耦合了 FreeCam: ' + camzoomCoupled[0]);

const combined = camzoom + '\n' + freecam + '\n';

const outUmg = path.join(MODDIR, 'Game/Content/Script/UMG/Main');
const outRes = path.join(MODDIR, 'Game/Content/Script/Resource');
fs.mkdirSync(outUmg, { recursive: true });
fs.mkdirSync(outRes, { recursive: true });

// 1) umg_main.lua：插在最终 return tbClass 之前。
//    ⚠ 必须用函数形式的 replace —— 源码含 `$'`，字符串形式会被当成 JS 替换
//    模式（$' = 匹配点之后的全部内容），直接吃掉源码字符。
let umg = fs.readFileSync(path.join(ROOT, 'work/umg_main.lua'), 'utf8');
if (umg.includes('CamZoom') || umg.includes('FreeCam')) throw new Error('umg_main.lua 源文件已被污染');
if (!umg.includes('return tbClass')) throw new Error('umg anchor missing');
umg = umg.replace(/\r?\nreturn tbClass\s*$/, () => '\n' + combined + '\n\nreturn tbClass\n');
fs.writeFileSync(path.join(outUmg, 'umg_main.lua'), encryptLua(umg));
console.log('umg_main.lua built, plaintext len', umg.length);

// 2) ResourceAmend.lua：追加到末尾
let ra = fs.readFileSync(path.join(AA, 'Game/Content/Script/Resource/ResourceAmend.lua'), 'utf8');
if (ra.includes('CamZoom') || ra.includes('FreeCam')) throw new Error('ResourceAmend.lua 源文件已被污染');
ra = ra + '\n' + combined + '\n';
fs.writeFileSync(path.join(outRes, 'ResourceAmend.lua'), encryptLua(ra));
console.log('ResourceAmend.lua built, plaintext len', ra.length);

// 3) 语法 lint（语法错误会直接炸游戏启动流程，必须在构建期挡住）
const luaparse = require(path.join(ROOT, 'work/node_modules/luaparse'));
let bad = false;
for (const [name, src] of [['umg_main.lua', umg], ['ResourceAmend.lua', ra]]) {
  try {
    luaparse.parse(src, { luaVersion: '5.3' });
    console.log('lint ' + name + ': OK');
  } catch (e) {
    console.log('lint ' + name + ': SYNTAX ERROR @' + e.line + ':' + e.col + ' ' + e.message);
    bad = true;
  }
}
if (bad) throw new Error('lua syntax error - build aborted');

// 4) 回读校验：解出来必须同时含两个 MOD 的标记。
//    ⚠ 加密方案是「整块 AES-ECB + 末尾 <16 字节明文残留」，dec 必须把残留拼回去，
//    否则文件尾部（return tbClass）读不出来。（build_mod.js 的同款 dec 也有此
//    遗漏，只是它的校验条件碰巧不查尾部，一直没暴露。）
function dec(p) {
  const data = fs.readFileSync(p);
  const aligned = data.length - (data.length % 16);
  const d = crypto.createDecipheriv('aes-256-ecb', LUA_KEY, null);
  d.setAutoPadding(false);
  return Buffer.concat([d.update(data.subarray(0, aligned)), d.final(),
                        data.subarray(aligned)]).toString('utf8');
}
const back = dec(path.join(outUmg, 'umg_main.lua'));
const ok = back.includes('[CamZoom]') && back.includes('[FreeCam]') &&
           back.includes('FreeCamActive') && back.includes('return tbClass');
console.log('roundtrip ok:', ok);
if (!ok) throw new Error('roundtrip check failed');

// 5) 打包
const { execFileSync } = require('child_process');
const pakOut = path.join(ROOT, 'work/merged-mod-new.pak');
const existing = path.join(MODDIR, 'merged-mod.pak');
if (fs.existsSync(existing)) fs.unlinkSync(existing);
execFileSync(path.join(ROOT, 'tools/repak.exe'),
  ['pack', '.', pakOut, '--version', 'V8B', '--mount-point', '../../../'],
  { cwd: MODDIR, stdio: 'inherit' });
console.log('pak built:', pakOut, fs.statSync(pakOut).size, 'bytes');

// 6) 冲突检查：同目录若还有旧的 FreeCam pak，两个 pak 会抢同名脚本
try {
  const PAKS = 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks';
  const list = fs.readdirSync(PAKS);
  const fre = list.filter((f) => /freecam/i.test(f));
  if (fre.length) console.log('WARN 已安装旧 freecam pak:', fre.join(','),
    '-> 必须移走，否则与合并 pak 争抢 umg_main.lua / ResourceAmend.lua');
} catch (e) {
  console.log('pak dir skip:', e.message);
}
