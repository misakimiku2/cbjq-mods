const fs = require('fs');

function pakInfo(path) {
  const buf = fs.readFileSync(path);
  console.log('===', path.split('/').pop(), 'len', buf.length);
  console.log('first32', buf.subarray(0, 32).toString('hex'));
  console.log('last80', buf.subarray(buf.length - 80).toString('hex'));
  const hits = [];
  for (let off = 0; off < buf.length - 4; off++) {
    if (buf[off] === 0xE1 && buf[off + 1] === 0x12 && buf[off + 2] === 0x6F && buf[off + 3] === 0x5A) hits.push(off);
  }
  console.log('magic hits:', hits.slice(0, 10));
  for (const off of hits.slice(0, 3)) {
    const v = buf.readUInt32LE(off + 4);
    console.log('magic at', off, 'version', v);
    if (off + 60 < buf.length) {
      console.log('  indexOffset', buf.readBigUInt64LE(off + 8).toString());
      console.log('  indexSize', buf.readBigUInt64LE(off + 16).toString());
      console.log('  indexHash', buf.subarray(off + 24, off + 44).toString('hex'));
      console.log('  guid', buf.subarray(off + 44, off + 60).toString('hex'));
      console.log('  bEncryptedIndex', buf[off + 60]);
      console.log('  compNames', buf.subarray(off + 61, off + 61 + 32).toString('latin1').replace(/\0/g, '.'));
    }
  }
}

pakInfo('E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/APP_Game_Startup_Settings_0-WindowsNoEditor.pak');
pakInfo('E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/PAK_Game_Script_0-WindowsNoEditor.pak');
pakInfo('E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/Patch_AntiAmend-Windows_100_P.pak');
