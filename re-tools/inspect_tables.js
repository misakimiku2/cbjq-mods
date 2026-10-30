const fs = require('fs');
const data = JSON.parse(fs.readFileSync('D:/test/cbjq-re/convert_cache/chapter_level.json', 'utf8'));
const rows = Array.isArray(data) ? data : (data.rows || data.data || Object.values(data)[0]);
const out = [];
out.push('type: ' + (Array.isArray(data) ? 'array' : typeof data) + ' len: ' + (Array.isArray(data) ? data.length : Object.keys(data).length));
out.push('sample keys: ' + Object.keys(rows[0]).join(','));
out.push('row0: ' + JSON.stringify(rows[0]).slice(0, 600));
// find rows mentioning 5020
for (const r of rows) {
  const s = JSON.stringify(r);
  if (s.includes('5020') || (r.id_1 === 5020) || (r.id === 5020)) {
    out.push('HIT: ' + s.slice(0, 500));
    if (out.length > 12) break;
  }
}
fs.writeFileSync('D:/test/cbjq-re/work/inspect_out.txt', out.join('\n'));
console.log('ok');
