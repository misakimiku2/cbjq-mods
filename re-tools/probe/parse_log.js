#!/usr/bin/env node
'use strict';
/**
 * ShopProbe 日志解析
 *   从 Game.log 里抽出 [ShopProbe] 行，汇总能力探测/模块/键/函数，
 *   并把 hex 形式的字节码还原成 .luac（若探针走的是 io 落盘路径，则只有 FILE 行）。
 *
 * 用法: node work/probe/parse_log.js [logPath]
 */
const fs = require('fs');
const path = require('path');

const LOG = process.argv[2] || 'E:/SeasunCBJQos/Game/cbjq/game/Saved/Logs/Game.log';
const OUT = 'D:/test/cbjq-re/work/_dump/reassembled';
const TAG = '[ShopProbe]';

if (!fs.existsSync(LOG)) { console.error('找不到日志: ' + LOG); process.exit(1); }
const lines = fs.readFileSync(LOG, 'utf8').split(/\r?\n/);

const picked = [];
for (const raw of lines) {
  const i = raw.indexOf(TAG);
  if (i < 0) continue;
  picked.push(raw.slice(i + TAG.length).trim());
}
if (!picked.length) {
  console.log('日志里没有 [ShopProbe] 行 —— 探针没跑起来（pak 没加载 / umg_main 没执行）');
  process.exit(0);
}

const groups = { CAP: [], START: [], GLOBAL: [], GTABLE: [], MDHEAD: [], TICK: [], MOD: [], MODTYPE: [], KEYS: [], FN: [], FILE: [], ERR: [], LOOPERR: [], BCLOAD: [], BCSKIP: [], FNCAP: [], HINT: [], DONE: [] };
const bc = new Map(); // key -> { bytes, total, parts: Map(n->hex) }

for (const s of picked) {
  const sp = s.indexOf(' ');
  const tag = sp < 0 ? s : s.slice(0, sp);
  const rest = sp < 0 ? '' : s.slice(sp + 1);
  if (tag === 'BC') {
    // BC <modName> <label> <n> <hex>
    const m = rest.match(/^(\S+) (\S+) (\d+) ([0-9A-Fa-f]+)$/);
    if (!m) continue;
    const key = m[1] + '::' + m[2];
    if (!bc.has(key)) bc.set(key, { parts: new Map(), total: 0 });
    bc.get(key).parts.set(+m[3], m[4]);
    continue;
  }
  if (tag === 'BCBEGIN') {
    const m = rest.match(/^(\S+) (\S+) (\d+) lines= (\d+)$/);
    if (!m) continue;
    const key = m[1] + '::' + m[2];
    const rec = bc.get(key) || { parts: new Map(), total: 0 };
    rec.total = +m[3];
    bc.set(key, rec);
    continue;
  }
  if (groups[tag]) groups[tag].push(rest);
}

const p = (t, arr, max = 999) => {
  if (!arr.length) return;
  console.log(`\n=== ${t} (${arr.length}) ===`);
  arr.slice(0, max).forEach(x => console.log('  ' + x));
  if (arr.length > max) console.log(`  ... 还有 ${arr.length - max} 条`);
};

console.log(`共 ${picked.length} 行 [ShopProbe] 输出\n`);
p('能力探测', groups.CAP);
p('启动', groups.START);
p('全局命中', groups.GLOBAL);
p('模块命中', groups.MOD, 60);
p('异常类型', groups.MODTYPE);
p('全局表', groups.GTABLE);
p('表形态', groups.MDHEAD, 60);
p('模块键', groups.KEYS, 60);
p('函数', groups.FN, 120);
p('已落盘', groups.FILE, 200);
p('异常', [...groups.ERR, ...groups.LOOPERR]);
p('字节码自检', groups.BCLOAD, 40);
p('跳过的超大函数', groups.BCSKIP);
p('结束', groups.DONE);

const ticks = groups.TICK;
if (ticks.length) {
  console.log('\n=== 扫描节奏 ===');
  ticks.forEach((t, i) => { if (i < 5 || i >= ticks.length - 2) console.log('  ' + t); });
}

// 还原 hex 字节码
if (bc.size) {
  fs.mkdirSync(OUT, { recursive: true });
  let n = 0;
  for (const [key, rec] of bc) {
    const idx = [...rec.parts.keys()].sort((a, b) => a - b);
    const hex = idx.map(k => rec.parts.get(k)).join('');
    const buf = Buffer.from(hex, 'hex');
    const name = key.replace(/[^A-Za-z0-9_.-]/g, '_') + '.luac';
    fs.writeFileSync(path.join(OUT, name), buf);
    const okLen = rec.total ? (buf.length === rec.total ? '长度吻合' : `长度不符 ${buf.length}/${rec.total}`) : '';
    console.log(`  还原 ${name}  ${buf.length} 字节 ${okLen}`);
    n++;
  }
  console.log(`\n共还原 ${n} 个 .luac -> ${OUT}`);
}
