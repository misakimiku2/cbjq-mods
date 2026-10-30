const crypto = require('crypto');
const fs = require('fs');

const PAKPATH = 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/PAK_Game_Script_0-WindowsNoEditor.pak';
const buf = fs.readFileSync(PAKPATH);
let foot = -1;
for (let i = buf.length - 300; i < buf.length - 4; i++) {
  if (buf[i] === 0xE1 && buf[i + 1] === 0x12 && buf[i + 2] === 0x6F && buf[i + 3] === 0x5A) { foot = i; break; }
}
const idxOff = Number(buf.readBigUInt64LE(foot + 8) ^ 0x1C1D1E1Fn);
const idxSize = Math.min(Number(buf.readBigUInt64LE(foot + 16)), 512);
const idx = buf.subarray(idxOff, idxOff + idxSize);

const base = PAKPATH.split('/').pop().replace(/\.pak$/i, '').toLowerCase();
const md5hex = crypto.createHash('md5').update(base, 'latin1').digest('hex');
const md5buf = Buffer.from(md5hex, 'latin1');

const hits = fs.readFileSync('D:/test/cbjq-re/work/keyscan_hits.txt', 'latin1')
  .split(/\r?\n/).map(l => l.trim().split('\t').pop()).filter(h => /^[0-9a-f]{64}$/i.test(h));
const uniq = [...new Set(hits)];
console.log('candidates:', uniq.length);

function test(keyBuf, label) {
  // transformed index key
  try {
    const e = crypto.createCipheriv('aes-256-ecb', keyBuf, null);
    e.setAutoPadding(false);
    const transformed = Buffer.concat([e.update(md5buf), e.final()]);
    const d = crypto.createDecipheriv('aes-256-ecb', transformed, null);
    d.setAutoPadding(false);
    const dec = Buffer.concat([d.update(idx.subarray(0, 64)), d.final()]);
    const s = dec.toString('latin1');
    if (/[\x20-\x7e]{12,}/.test(s)) { console.log('TRANSFORMED-HIT', label, s.replace(/[^ -~]/g, '.')); return true; }
  } catch (_) {}
  // raw key
  try {
    const d = crypto.createDecipheriv('aes-256-ecb', keyBuf, null);
    d.setAutoPadding(false);
    const dec = Buffer.concat([d.update(idx.subarray(0, 64)), d.final()]);
    const s = dec.toString('latin1');
    if (/[\x20-\x7e]{12,}/.test(s)) { console.log('RAW-HIT', label, s.replace(/[^ -~]/g, '.')); return true; }
  } catch (_) {}
  return false;
}

let found = 0;
for (const k of uniq) {
  if (test(Buffer.from(k, 'hex'), k)) found++;
}
// also common known default (0x00*32) and the lua key as hex/base64 forms
test(Buffer.alloc(32, 0), 'zeros');
test(Buffer.from('E1671E910EB54736B49908575F08CAFB', 'latin1'), 'luaKeyAscii32');
console.log('done, hits:', found);
