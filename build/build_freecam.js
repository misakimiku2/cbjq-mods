// ============================================================
// 自由相机（FreeCam）独立构建脚本 —— 与 camzoom 完全分离
//   源  : work/freecam/probe01.lua
//   产物: work/freecam-mod-new.pak  ->  Patch_FreeCamMod-Windows_100_P.pak
//
// 注入点与 camzoom 相同（umg_main + ResourceAmend），因为这是游戏唯一的两个
// Lua 起始点。**两个 pak 会争抢同名文件，所以同一时间只能装一个**，
// 脚本会在末尾检测并提示。
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
const SRC = process.env.FREECAM_SRC
  ? process.env.FREECAM_SRC
  : path.join(ROOT, 'work/freecam/protov1.lua');
const MODDIR = path.join(ROOT, 'work/freecam-mod');
const AA = path.join(ROOT, 'antiamend-src/Basic-Universal/ExtractedAssets');
const PAKS = 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks';

const probe = fs.readFileSync(SRC, 'utf8');
// 串味检查：只禁**代码级**耦合（取用对方全局表的成员 / _G 访问）。
// 注释里提到 CamZoomMod / CamZoomSniffer（共用 IPC 目录）是允许的、也应该写清楚。
const coupled = probe.match(/\bCamZoom(?:Mod|Sniffer)?\s*\.\s*[A-Za-z_]/) ||
                probe.match(/_\s*G\s*\[\s*['"]CamZoom/);
if (coupled) {
  throw new Error('检测到与 CamZoom 的代码级耦合: ' + coupled[0] + ' —— 两个 MOD 必须互不可见');
}

const outUmg = path.join(MODDIR, 'Game/Content/Script/UMG/Main');
const outRes = path.join(MODDIR, 'Game/Content/Script/Resource');
fs.mkdirSync(outUmg, { recursive: true });
fs.mkdirSync(outRes, { recursive: true });

// 1) umg_main.lua：插在最终 return tbClass 之前
let umg = fs.readFileSync(path.join(ROOT, 'work/umg_main.lua'), 'utf8');
if (umg.includes('CamZoom')) throw new Error('umg_main.lua 源文件已被 camzoom 污染');
if (!umg.includes('return tbClass')) throw new Error('umg anchor missing');
// 注意：必须用函数形式的 replace —— probe 源码里含 `$'`，字符串形式会被当成
// JS 的替换模式（$' = 匹配点之后的全部内容），直接吃掉源码字符。
umg = umg.replace(/\r?\nreturn tbClass\s*$/, () => '\n' + probe + '\n\nreturn tbClass\n');
fs.writeFileSync(path.join(outUmg, 'umg_main.lua'), encryptLua(umg));
console.log('umg_main.lua  built, plaintext len', umg.length);

// 2) ResourceAmend.lua：追加到末尾
let ra = fs.readFileSync(path.join(AA, 'Game/Content/Script/Resource/ResourceAmend.lua'), 'utf8');
if (ra.includes('CamZoom')) throw new Error('ResourceAmend.lua 源文件已被 camzoom 污染');
ra = ra + '\n' + probe + '\n';
fs.writeFileSync(path.join(outRes, 'ResourceAmend.lua'), encryptLua(ra));
console.log('ResourceAmend.lua built, plaintext len', ra.length);

// 3) 语法 lint（语法错误会直接炸游戏启动流程）
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

// 4) 回读校验：解出来必须还是我们的代码
function dec(p) {
  const data = fs.readFileSync(p);
  const aligned = data.length - (data.length % 16);
  const d = crypto.createDecipheriv('aes-256-ecb', LUA_KEY, null);
  d.setAutoPadding(false);
  return Buffer.concat([d.update(data.subarray(0, aligned)), d.final()]).toString('utf8');
}
const back = dec(path.join(outUmg, 'umg_main.lua'));
console.log('roundtrip ok:', back.includes('[FreeCam]') && back.includes('FreeCam'));

// 5) 打包
const pakOut = path.join(ROOT, 'work/freecam-mod-new.pak');
const existing = path.join(MODDIR, 'freecam-mod.pak');
if (fs.existsSync(existing)) fs.unlinkSync(existing);
require('child_process').execFileSync(
  path.join(ROOT, 'tools/repak.exe'),
  ['pack', '.', pakOut, '--version', 'V8B', '--mount-point', '../../../'],
  { cwd: MODDIR, stdio: 'inherit' }
);
console.log('pak built:', pakOut, fs.statSync(pakOut).size, 'bytes');

// 6) 冲突检查：同目录下若还有 camzoom pak，两个 MOD 会抢同名脚本
try {
  const list = fs.readdirSync(PAKS);
  const cam = list.filter((f) => /camzoom/i.test(f));
  const fre = list.filter((f) => /freecam/i.test(f));
  if (cam.length) console.log('WARN 已安装 camzoom pak:', cam.join(','), '-> 安装 freecam 前必须移走');
  if (fre.length) console.log('NOTE 已安装 freecam pak:', fre.join(','));
} catch (e) {
  console.log('pak dir skip:', e.message);
}
