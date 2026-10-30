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

const diag = fs.readFileSync('D:/test/cbjq-re/work/camzoom/proto49.lua', 'utf8');
const AA = 'D:/test/cbjq-re/antiamend-src/Basic-Universal/ExtractedAssets';

// 1) umg_main.lua: insert diag before final `return tbClass`
let umg = fs.readFileSync('D:/test/cbjq-re/work/umg_main.lua', 'utf8');
if (!umg.includes('return tbClass')) throw new Error('umg anchor missing');
umg = umg.replace(/\r?\nreturn tbClass\s*$/, '\n' + diag + '\n\nreturn tbClass\n');
fs.writeFileSync('D:/test/cbjq-re/work/camzoom-mod/Game/Content/Script/UMG/Main/umg_main.lua', encryptLua(umg));
console.log('umg_main.lua built, plaintext len', umg.length);

// 2) ResourceAmend.lua: append diag at end
let ra = fs.readFileSync(path.join(AA, 'Game/Content/Script/Resource/ResourceAmend.lua'), 'utf8');
ra = ra + '\n' + diag + '\n';
fs.writeFileSync('D:/test/cbjq-re/work/camzoom-mod/Game/Content/Script/Resource/ResourceAmend.lua', encryptLua(ra));
console.log('ResourceAmend.lua built, plaintext len', ra.length);

// sanity: decrypt-back check
function dec(p) {
  const data = fs.readFileSync(p);
  const aligned = data.length - (data.length % 16);
  const d = crypto.createDecipheriv('aes-256-ecb', LUA_KEY, null);
  d.setAutoPadding(false);
  return Buffer.concat([d.update(data.subarray(0, aligned)), d.final()]).toString('utf8');
}
const back = dec('D:/test/cbjq-re/work/camzoom-mod/Game/Content/Script/UMG/Main/umg_main.lua');
console.log('roundtrip ok:', back.startsWith('-- ========================================================') && back.includes('CamZoomMod'));

// syntax lint: both files MUST parse or the build fails (compile error would break game boot)
const luaparse = require('D:/test/cbjq-re/work/node_modules/luaparse');
let lintFailed = false;
for (const [name, src] of [
  ['umg_main.lua', umg],
  ['ResourceAmend.lua', ra],
]) {
  try {
    luaparse.parse(src, { luaVersion: '5.3' });
    console.log('lint ' + name + ': OK');
  } catch (e) {
    console.log('lint ' + name + ': SYNTAX ERROR @' + e.line + ':' + e.col + ' ' + e.message);
    lintFailed = true;
  }
}
if (lintFailed) throw new Error('lua syntax error - build aborted');

// 3) repak 打包（放在最后，避免忘记）
const { execFileSync } = require('child_process');
const pakOut = 'D:/test/cbjq-re/work/camzoom-mod-new.pak';
const pakDir = 'D:/test/cbjq-re/work/camzoom-mod';
const existing = path.join(pakDir, 'camzoom-mod.pak');
if (fs.existsSync(existing)) fs.unlinkSync(existing);
execFileSync('D:/test/cbjq-re/tools/repak.exe',
  ['pack', '.', pakOut, '--version', 'V8B', '--mount-point', '../../../'],
  { cwd: pakDir, stdio: 'inherit' });
console.log('pak built:', pakOut, fs.statSync(pakOut).size, 'bytes');
