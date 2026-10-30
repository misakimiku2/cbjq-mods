const luaparse = require('D:/test/cbjq-re/work/node_modules/luaparse');
const fs = require('fs');
const crypto = require('crypto');
const LUA_KEY = Buffer.from('E1671E910EB54736B49908575F08CAFB', 'latin1');
function dec(p) {
  const data = fs.readFileSync(p);
  const aligned = data.length - (data.length % 16);
  const d = crypto.createDecipheriv('aes-256-ecb', LUA_KEY, null);
  d.setAutoPadding(false);
  return Buffer.concat([d.update(data.subarray(0, aligned)), d.final()]).toString('utf8');
}
for (const f of ['camzoom-mod/Game/Content/Script/Resource/ResourceAmend.lua', 'camzoom-mod/Game/Content/Script/UMG/Main/umg_main.lua']) {
  const src = dec('D:/test/cbjq-re/work/' + f);
  try {
    luaparse.parse(src, { luaVersion: '5.3' });
    console.log(f.split('/').pop() + ': OK');
  } catch (e) {
    console.log(f.split('/').pop() + ': SYNTAX ERROR: ' + e.message);
    const lines = src.split('\n');
    const ln = e.line || 0;
    for (let i = Math.max(0, ln - 4); i < Math.min(lines.length, ln + 2); i++) {
      console.log((i + 1) + (i + 1 === ln ? ' >>> ' : '     ') + lines[i].slice(0, 150));
    }
  }
}
