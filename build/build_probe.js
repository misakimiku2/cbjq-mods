// ============================================================
// ShopProbe 构建：把运行时转储探针注入 umg_main.lua，单独打一个 pak
//
// 为什么单独一个 pak：
//   merged-mod-new.pak（CamZoomMod + FreeCamMod）是要分发给别人的，
//   探针不该混进去。调试期间把 mod pak 临时移出 Paks 目录，只装这个。
//
// 产物：work/probe/Patch_ZShopProbe-Windows_100_P.pak
// 用法：node work/build_probe.js
// ============================================================
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const LUA_KEY = Buffer.from('E1671E910EB54736B49908575F08CAFB', 'latin1');
const ROOT = 'D:/test/cbjq-re';

function encryptLua(text) {
  const data = Buffer.from(text, 'utf8');
  const aligned = data.length - (data.length % 16);
  const c = crypto.createCipheriv('aes-256-ecb', LUA_KEY, null);
  c.setAutoPadding(false);
  const head = Buffer.concat([c.update(data.subarray(0, aligned)), c.final()]);
  return Buffer.concat([head, data.subarray(aligned)]);
}

function decryptLua(buf) {
  const aligned = buf.length - (buf.length % 16);
  const d = crypto.createDecipheriv('aes-256-ecb', LUA_KEY, null);
  d.setAutoPadding(false);
  return Buffer.concat([d.update(buf.subarray(0, aligned)), d.final(), buf.subarray(aligned)]);
}

const probe = fs.readFileSync(path.join(ROOT, 'work/probe/shopprobe.lua'), 'utf8');
const vanilla = fs.readFileSync(path.join(ROOT, 'work/umg_main.lua'), 'utf8');

if (vanilla.includes('ShopProbe')) throw new Error('umg_main.lua 源文件已被污染');
if (!vanilla.includes('return tbClass')) throw new Error('umg_main anchor missing');

// 插在最终 return tbClass 之前；用函数形式的 replace（源码含 $' 时字符串形式会出错）
let out = vanilla.replace(/\r?\nreturn tbClass\s*$/, () => '\n' + probe + '\n\nreturn tbClass\n');
if (out === vanilla) throw new Error('注入失败：锚点没匹配上');

// 语法 lint（语法错误会直接炸游戏启动流程）
const luaparse = require(path.join(ROOT, 'work/node_modules/luaparse'));
try {
  luaparse.parse(out, { luaVersion: '5.3' });
  console.log('lint umg_main(lua 5.3): OK, plaintext len', out.length);
} catch (e) {
  console.log('lint: SYNTAX ERROR @' + e.line + ':' + e.col + ' ' + e.message);
  throw new Error('lua syntax error - build aborted');
}

// 目录
const MODDIR = path.join(ROOT, 'work/probe/pakroot');
const outUmg = path.join(MODDIR, 'Game/Content/Script/UMG/Main');
fs.mkdirSync(outUmg, { recursive: true });
fs.mkdirSync(path.join(ROOT, 'work/_dump'), { recursive: true });

const enc = encryptLua(out);
fs.writeFileSync(path.join(outUmg, 'umg_main.lua'), enc);

// 回读校验：整块 AES + 末尾明文残留必须拼回去
const back = decryptLua(fs.readFileSync(path.join(outUmg, 'umg_main.lua'))).toString('utf8');
const ok = back.includes('ShopProbe') && back.includes('return tbClass') && back.length === out.length;
console.log('roundtrip ok:', ok);
if (!ok) throw new Error('roundtrip check failed');

// 打包
const pakOut = path.join(ROOT, 'work/probe/Patch_ZShopProbe-Windows_100_P.pak');
execFileSync(path.join(ROOT, 'tools/repak.exe'),
  ['pack', '.', pakOut, '--version', 'V8B', '--mount-point', '../../../'],
  { cwd: MODDIR, stdio: 'inherit' });
console.log('pak built:', pakOut, fs.statSync(pakOut).size, 'bytes');

// 提示：同目录若还有 mod pak，会争抢 umg_main.lua
const PAKS = 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks';
try {
  const list = fs.readdirSync(PAKS).filter(f => /CamZoom|FreeCam|Probe/i.test(f));
  if (list.length) console.log('WARN 已存在的相关 pak:', list.join(', '),
    '-> 调试期需把模组 pak 移出，只留 Patch_ZShopProbe');
} catch (e) {
  console.log('pak dir skip:', e.message);
}
