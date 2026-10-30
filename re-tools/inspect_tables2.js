const fs = require('fs');
const data = JSON.parse(fs.readFileSync('D:/test/cbjq-re/convert_cache/chapter_level.json', 'utf8'));
const out = [];
// rows with MapID 5020 / 50200, and rows with ID 10121..10124, 50170 area, and Type values histogram
const byMap = data.filter(r => r.MapID === 5020 || r.MapID === 50200 || r.MapID === 50000);
for (const r of byMap) out.push('MapID ' + r.MapID + ': ' + JSON.stringify(r).slice(0, 420));
out.push('---- IDs 10120-10125 ----');
for (const r of data.filter(r => [10120, 10121, 10122, 10123, 10124, 10125].includes(r.ID))) out.push(JSON.stringify(r).slice(0, 420));
out.push('---- IDs 50170-50175 ----');
for (const r of data.filter(r => [50170, 50171, 50172, 50173, 50174, 50175].includes(r.ID))) out.push(JSON.stringify(r).slice(0, 420));
out.push('---- Type histogram ----');
const hist = {};
for (const r of data) hist[r.Type] = (hist[r.Type] || 0) + 1;
out.push(JSON.stringify(hist));
fs.writeFileSync('D:/test/cbjq-re/work/inspect_out2.txt', out.join('\n----\n'));
console.log('ok');
