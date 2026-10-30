const fs = require('fs');
const buf = fs.readFileSync('E:/SeasunCBJQos/Game/cbjq/game/Game/Content/Paks/PAK_Game_Script_0-WindowsNoEditor.pak');
let foot = -1;
for (let i = buf.length - 300; i < buf.length - 4; i++) {
  if (buf[i] === 0xE1 && buf[i + 1] === 0x12 && buf[i + 2] === 0x6F && buf[i + 3] === 0x5A) { foot = i; break; }
}
const out = [];
out.push('foot at ' + foot + ' filelen ' + buf.length);
out.push('footer hex: ' + buf.subarray(foot, foot + 221).toString('hex'));
const idxOff = Number(buf.readBigUInt64LE(foot + 8) ^ 0x1C1D1E1Fn);
const idxSize = Number(buf.readBigUInt64LE(foot + 16));
out.push('idxOff ' + idxOff + ' idxSize ' + idxSize + ' inRange ' + (idxOff + idxSize <= foot));
out.push('index first 96: ' + buf.subarray(idxOff, idxOff + 96).toString('hex'));
out.push('index ascii: ' + buf.subarray(idxOff, idxOff + 96).toString('latin1').replace(/[^ -~]/g, '.'));
fs.writeFileSync('D:/test/cbjq-re/work/pak_peek_out.txt', out.join('\n'));
console.log('done');
