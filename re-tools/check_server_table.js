const fs = require('fs');
// server-side converted table used by the Rust server (data/settings/chapter/level.txt)
const p = 'D:/test/cbjq-re/server2/data/settings/chapter/level.txt';
const txt = fs.readFileSync(p, 'utf8');
const lines = txt.split(/\r?\n/);
console.log('total lines:', lines.length);
console.log('header:', lines[0].slice(0, 300));
console.log('second:', lines[1] ? lines[1].slice(0, 300) : '');
let found = 0;
for (const l of lines) {
  if (/^5017[0-9]\b|^50171\b|^10121\b|^50174\b/.test(l.trim())) {
    console.log(l.slice(0, 260));
    found++;
  }
}
console.log('matched:', found);
