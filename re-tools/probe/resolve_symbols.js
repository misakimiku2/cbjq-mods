#!/usr/bin/env node
'use strict';
// 用 tables.tsv 把符号形式接口名（如 Chapter.REQ_ENTER_LEVEL）还原成字面量
const fs = require('fs');

const DUMP = 'D:/test/cbjq-re/work/_dump';
const JSONF = 'D:/test/cbjq-re/work/probe/protocol.json';

const tsv = fs.readFileSync(`${DUMP}/tables.tsv`, 'latin1').split('\n');
/** root -> key -> value */
const tbl = new Map();
let bad = 0;
for (const line of tsv) {
  if (!line) continue;
  const parts = line.split('\t');
  if (parts.length !== 3) { bad++; continue; }
  let [root, key, val] = parts;
  val = val.replace(/[\r\n]+$/, '');   // Lua 文本模式写入会带 \r
  if (!tbl.has(root)) tbl.set(root, new Map());
  const m = tbl.get(root);
  if (!m.has(key)) m.set(key, val);   // 同名保留第一次
}

const data = JSON.parse(fs.readFileSync(JSONF, 'utf8'));
const syms = data.filter(x => x.symbol);
let ok = 0;
const resolved = [], unresolved = [];

for (const s of syms) {
  const m = s.api.match(/^(.+)\.([^.]+)$/);
  if (!m) { unresolved.push([s.api, '格式不匹配']); continue; }
  const [, root, key] = m;
  const candidates = [`G:${root}`, `L:${root}`, `G:_G.${root}`, `L:_G.${root}`];
  let val = null;
  for (const c of candidates) {
    const t = tbl.get(c);
    if (t && t.has(key)) { val = t.get(key); break; }
  }
  if (val && /^[\x20-\x7e]+$/.test(val)) { resolved.push([s.api, val, s]); ok++; }
  else unresolved.push([s.api, val ? '值非常规字符' : '表里没找到']);
}

console.log(`符号形式 ${syms.length} 个，还原成功 ${ok} 个，未还原 ${unresolved.length} 个（tsv 行数 ${tsv.length}，格式异常 ${bad}）\n`);
resolved.slice(0, 60).forEach(([k, v]) => console.log(`  ${k}  →  ${v}`));
if (unresolved.length) {
  console.log('\n未还原：');
  unresolved.slice(0, 30).forEach(([k, why]) => console.log(`  ${k}   (${why})`));
}

fs.writeFileSync('D:/test/cbjq-re/work/probe/symbol_map.json',
  JSON.stringify(Object.fromEntries(resolved.map(([k, v]) => [k, v])), null, 2));
