const crypto = require('crypto');
const fs = require('fs');

// Correct Snowbreak oracle:
//   pakName = filename without ext, lowercased
//   md5hex  = lowercase hex md5 of pakName (32 ascii bytes)
//   transformedKey = AES-256-ECB-ENCRYPT(baseKey, md5hexBytes) (no padding, 32 bytes out)
//   index decrypted with transformedKey (ECB), starts with mount point FString "../../../..."
const pakPath = process.argv[2] || 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/APP_Game_Startup_Settings_0-WindowsNoEditor.pak';
const pakName = pakPath.split(/[\\/]/).pop().replace(/\.pak$/i, '').toLowerCase();
const md5hex = crypto.createHash('md5').update(pakName, 'latin1').digest('hex'); // lowercase hex string
console.log('pakName:', pakName);
console.log('md5hex:', md5hex);

const pak = fs.readFileSync(pakPath);
let foot = -1;
for (let i = pak.length - 500; i < pak.length - 4; i++) {
  if (pak[i] === 0xE1 && pak[i + 1] === 0x12 && pak[i + 2] === 0x6F && pak[i + 3] === 0x5A) { foot = i; break; }
}
const idxOffset = Number(pak.readBigUInt64LE(foot + 8)) ^ 0x1C1D1E1F;
const idxSize = Number(pak.readBigUInt64LE(foot + 16));
console.log('indexOffset(decoded):', idxOffset, 'indexSize:', idxSize);
const encBlock = Buffer.from(pak.subarray(idxOffset, idxOffset + 16));

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

function check(out) {
  if (!out) return false;
  const len = out.readInt32LE(0);
  if (len > 0 && len <= 1024) {
    if (out[4] === 0x2e && out[5] === 0x2e && out[6] === 0x2f) return true;
  }
  if (len === 0 && out[4] === 0 && out[5] === 0 && out[6] === 0) return true;
  let printable = 0;
  for (let i = 0; i < 16; i++) if (out[i] >= 0x20 && out[i] < 0x7f) printable++;
  return printable >= 15;
}

function scan(file, align) {
  const data = fs.readFileSync(file);
  console.log(`scanning ${file} (${data.length} bytes, align ${align})`);
  let found = 0;
  for (let off = 0; off + 32 <= data.length; off += align) {
    const out = testBaseKey(data.subarray(off, off + 32));
    if (out && check(out)) {
      const keyHex = data.subarray(off, off + 32).toString('hex');
      console.log(`\n*** CANDIDATE at offset ${off} (0x${off.toString(16)}) key=${keyHex}`);
      console.log(`    dec = ${out.toString('latin1').replace(/[^\x20-\x7e]/g, '.')}`);
      fs.appendFileSync(__dirname + '/keyscan_hits.txt', `${file}\t${off}\t${keyHex}\n`);
      found++;
    }
  }
  console.log(`done: ${found} hits`);
}

const target = process.argv[3] || 'E:/SeasunCBJQos/Game/cbjq/game/Game/Binaries/Win64/Game.exe';
const align = parseInt(process.argv[4] || '16', 10);
scan(target, align);
