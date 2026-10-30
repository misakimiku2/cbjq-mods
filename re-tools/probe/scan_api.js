#!/usr/bin/env node
'use strict';
// 扫描 dump 出来的字节码，提取所有 `Xxx.<method>` 形式的调用点
// 用法: node work/probe/scan_api.js <dir> [前缀,如 ShopLogic]
const fs = require('fs');
const path = require('path');
const { load } = require('../../tools/luac54.js');

const dir = process.argv[2] || 'D:/test/cbjq-re/work/_dump';
const prefix = (process.argv[3] || 'ShopLogic').toLowerCase();

const OPS = { GETTABUP: 11, GETFIELD: 14, SELF: 20, CALL: 68 };
const calls = new Map();

function kstr(p, i) { return typeof p.consts[i] === 'string' ? p.consts[i] : null; }

function scan(p, caller) {
  const reg = {};      // reg -> 符号名
  for (let pc = 0; pc < p.code.length; pc++) {
    const i = p.code[pc];
    const op = i & 0x7f;
    const A = (i >>> 7) & 0xff, B = (i >>> 16) & 0xff, C = (i >>> 24) & 0xff;
    if (op === OPS.GETTABUP) {
      const name = kstr(p, C);
      if (name) reg[A] = name;
    } else if (op === OPS.GETFIELD) {
      const name = kstr(p, C);
      const base = reg[B];
      if (name && base) {
        reg[A] = base + '.' + name;
        if (base.toLowerCase().includes(prefix)) {
          const key = base + '.' + name;
          if (!calls.has(key)) calls.set(key, new Set());
          calls.get(key).add(caller);
        }
      } else reg[A] = undefined;
    } else if (op === OPS.SELF) {
      const name = kstr(p, C);
      const base = reg[B];
      if (name && base && base.toLowerCase().includes(prefix)) {
        const key = base + '.' + name;
        if (!calls.has(key)) calls.set(key, new Set());
        calls.get(key).add(caller);
      }
      reg[A] = undefined;
    } else if (op === OPS.CALL) {
      reg[A] = undefined;
    } else if (A > 0) {
      reg[A] = undefined;
    }
  }
  p.protos.forEach((q, i) => scan(q, caller + '/' + (q.upvalnames[0] || 'sub' + i)));
}

for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.luac'))) {
  try {
    const mod = load(fs.readFileSync(path.join(dir, f)));
    scan(mod.main, path.basename(f, '.luac'));
  } catch (e) { /* 跳过解析失败的文件 */ }
}

const arr = [...calls.entries()].sort((a, b) => a[0].localeCompare(b[0]));
console.log(`共 ${arr.length} 个 ${prefix}.* 调用点\n`);
for (const [k, set] of arr) {
  console.log(`${k}   ← ${[...set].slice(0, 3).join(', ')}${set.size > 3 ? ` (+${set.size - 3})` : ''}`);
}
