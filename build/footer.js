const fs = require('fs');

const path = process.argv[2] || 'E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/APP_Game_Startup_Settings_0-WindowsNoEditor.pak';
const buf = fs.readFileSync(path);
// find magic
let off = -1;
for (let i = buf.length - 500; i < buf.length - 4; i++) {
  if (buf[i] === 0xE1 && buf[i + 1] === 0x12 && buf[i + 2] === 0x6F && buf[i + 3] === 0x5A) { off = i; break; }
}
console.log('fileLen', buf.length, 'magic at', off, 'footerSize', buf.length - off);
const foot = buf.subarray(off);
console.log('footer hex:');
for (let i = 0; i < foot.length; i += 16) {
  const line = foot.subarray(i, i + 16);
  const hex = Array.from(line).map(b => b.toString(16).padStart(2, '0')).join(' ');
  const asc = Array.from(line).map(b => (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.').join('');
  console.log((i).toString().padStart(3), hex.padEnd(48), asc);
}
