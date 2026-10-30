const crypto = require('crypto');
const fs = require('fs');

// encrypted primary index blob: first 16 bytes, from APP_Game_Startup_Settings_0
const pakPath = process.argv[2] || 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/APP_Game_Startup_Settings_0-WindowsNoEditor.pak';
const pak = fs.readFileSync(pakPath);
let foot = -1;
for (let i = pak.length - 500; i < pak.length - 4; i++) {
  if (pak[i] === 0xE1 && pak[i + 1] === 0x12 && pak[i + 2] === 0x6F && pak[i + 3] === 0x5A) { foot = i; break; }
}
const idxSize = pak.readUInt32LE(foot + 16);
const idxStart = pak.length - (pak.length - foot) - idxSize;
const encBlock = Buffer.from(pak.subarray(idxStart, idxStart + 16));
console.log(`oracle: pak=${pakPath.split('/').pop()} idx@${idxStart} size=${idxSize} block=${encBlock.toString('hex')}`);

function testKey(keyBuf) {
  try {
    const d = crypto.createDecipheriv('aes-256-ecb', keyBuf, null);
    d.setAutoPadding(false);
    const out = Buffer.concat([d.update(encBlock), d.final()]);
    // mount point FString: i32 len (1..1024), followed by '../' or printable
    const len = out.readInt32LE(0);
    const okLen = (len > 0 && len <= 1024) || len === 0;
    if (okLen) {
      const a = out[4], b = out[5], c = out[6];
      if ((a === 0x2e && b === 0x2e && c === 0x2f) || (len === 0 && a === 0 && b === 0 && c === 0)) {
        return out;
      }
      // also allow pure-printable heuristic for unusual mount points
      let printable = 0;
      for (let i = 0; i < 16; i++) if (out[i] >= 0x20 && out[i] < 0x7f) printable++;
      if (printable >= 15) return out;
    }
  } catch (e) { }
  return null;
}

function scan(file, align) {
  const data = fs.readFileSync(file);
  console.log(`scanning ${file} (${data.length} bytes, align ${align})`);
  let found = 0;
  for (let off = 0; off + 32 <= data.length; off += align) {
    const out = testKey(data.subarray(off, off + 32));
    if (out) {
      const keyHex = data.subarray(off, off + 32).toString('hex');
      console.log(`\n*** CANDIDATE at ${file} offset ${off} (0x${off.toString(16)})`);
      console.log(`    key = ${keyHex}`);
      console.log(`    dec block = ${out.toString('latin1').replace(/[^\x20-\x7e]/g, '.')} | ${out.toString('hex')}`);
      fs.appendFileSync(__dirname + '/keyscan_hits.txt', `${file}\t${off}\t${keyHex}\t${out.toString('hex')}\n`);
      found++;
    }
  }
  console.log(`done ${file}: ${found} hits`);
}

const target = process.argv[3] || 'E:/SeasunCBJQos/Game/cbjq/game/Game/Binaries/Win64/Game.exe';
const align = parseInt(process.argv[4] || '16', 10);
scan(target, align);
