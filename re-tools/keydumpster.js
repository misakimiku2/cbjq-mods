const crypto = require('crypto');
const fs = require('fs');

// AESDumpster-style scan: keys built via consecutive `mov dword ptr [mem], imm32` stores.
const PATTERNS = [
  { pat: 'C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ??', offs: [3, 10, 17, 24, 35, 42, 49, 56] },
  { pat: 'C7 ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ??', offs: [2, 9, 16, 23, 30, 37, 44, 51] },
  { pat: 'C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? 48 ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ??', offs: [3, 10, 21, 28, 35, 42, 49, 56] },
  { pat: 'C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C7 ?? ?? ?? ?? ?? ?? C3', offs: [51, 45, 38, 31, 24, 17, 10, 3] },
];

const FALSE_POS = new Set([
  'FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9FFD9',
  '67E6096A85AE67BB72F36E3C3AF54FA57F520E518C68059BABD9831F19CDE05B',
  'D89E05C107D57C3617DD703039590EF7310BC0FF11155868A78FF964A44FFABE',
  '9A99593F9A99593F0AD7633F52B8BE3FE17A543FCDCC4C3D4260E53BAE47A13F',
  '6F168073B9B21449D742241700068ADABC306FA9AA3831164DEE8DE34E0EFBB0',
]);

function parsePattern(pat) {
  const tokens = pat.split(' ');
  return tokens.map(t => (t === '??' ? null : parseInt(t, 16)));
}

function findPattern(buf, tokens, startIdx) {
  const hits = [];
  const n = tokens.length;
  outer: for (let i = startIdx; i + n <= buf.length; i++) {
    for (let j = 0; j < n; j++) {
      if (tokens[j] !== null && buf[i + j] !== tokens[j]) continue outer;
    }
    hits.push(i);
  }
  return hits;
}

function entropy(hex) {
  const freq = {};
  for (const c of hex) freq[c] = (freq[c] || 0) + 1;
  let e = 0;
  const n = hex.length;
  for (const k in freq) {
    const p = freq[k] / n;
    e += p * Math.log2(p);
  }
  return -e;
}

// ---- Snowbreak oracle ----
const pakPath = 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/APP_Game_Startup_Settings_0-WindowsNoEditor.pak';
const pak = fs.readFileSync(pakPath);
let foot = -1;
for (let i = pak.length - 500; i < pak.length - 4; i++) {
  if (pak[i] === 0xE1 && pak[i + 1] === 0x12 && pak[i + 2] === 0x6F && pak[i + 3] === 0x5A) { foot = i; break; }
}
const idxOffset = Number(pak.readBigUInt64LE(foot + 8)) ^ 0x1C1D1E1F;
const idxSize = Number(pak.readBigUInt64LE(foot + 16));
const encBlock = Buffer.from(pak.subarray(idxOffset, idxOffset + 16));
const pakName = pakPath.split('/').pop().replace(/\.pak$/i, '').toLowerCase();
const md5hex = crypto.createHash('md5').update(pakName, 'latin1').digest('hex');
console.log('oracle pak:', pakName, 'idxOff:', idxOffset);

function testBaseKey(keyBuf) {
  try {
    const e = crypto.createCipheriv('aes-256-ecb', keyBuf, null);
    e.setAutoPadding(false);
    const transformed = Buffer.concat([e.update(Buffer.from(md5hex, 'latin1')), e.final()]);
    const d = crypto.createDecipheriv('aes-256-ecb', transformed, null);
    d.setAutoPadding(false);
    return Buffer.concat([d.update(encBlock), d.final()]);
  } catch (e) { return null; }
}

function mountOk(out) {
  if (!out) return false;
  const len = out.readInt32LE(0);
  return (len > 0 && len <= 1024 && out[4] === 0x2e && out[5] === 0x2e && out[6] === 0x2f) ||
         (len === 0 && out[4] === 0 && out[5] === 0 && out[6] === 0);
}

const target = process.argv[2] || 'E:/SeasunCBJQos/Game/cbjq/game/Game/Binaries/Win64/Game.exe';
const data = fs.readFileSync(target);
console.log('scanning', target, data.length, 'bytes');

const found = new Map(); // keyHex -> {off, ent}
for (let p = 0; p < PATTERNS.length; p++) {
  const tokens = parsePattern(PATTERNS[p].pat);
  const hits = findPattern(data, tokens, 0);
  console.log(`pattern ${p}: ${hits.length} hits`);
  for (const h of hits) {
    const key = Buffer.alloc(32);
    PATTERNS[p].offs.forEach((o, k) => data.copy(key, k * 4, h + o, h + o + 4));
    const keyHex = key.toString('hex').toUpperCase();
    if (FALSE_POS.has(keyHex)) continue;
    const ent = entropy(keyHex);
    if (ent < 3.3) continue;
    if (found.has(keyHex)) continue;
    found.set(keyHex, { off: h, ent });
    const out = testBaseKey(key);
    if (mountOk(out)) {
      console.log('\n*** REAL KEY FOUND:', keyHex, 'at', h, 'entropy', ent.toFixed(2));
      console.log('    dec:', out.toString('latin1').replace(/[^\x20-\x7e]/g, '.'));
      fs.writeFileSync(__dirname + '/FOUND_KEY.txt', keyHex + '\n');
    }
  }
}
console.log('candidates (entropy>=3.3):', found.size);
let i = 0;
for (const [k, v] of found) console.log(`${i++}`, k, '@', v.off, 'ent', v.ent.toFixed(3));
