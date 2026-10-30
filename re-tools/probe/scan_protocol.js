#!/usr/bin/env node
'use strict';
/**
 * 协议清单扫描：从 Lua 5.4 字节码里提取客户端主动请求（CallGS）
 *
 * 目标形态：
 *   me:CallGS("ShopLogic_BuyGoods", json.encode({ nGoodsId = id, nBuyMode = m, nCount = c }))
 *
 * 做法：对每个函数原型做一次简单的寄存器符号执行
 *   - GETTABUP(_ENV, "me")        → 记 me
 *   - SELF / GETFIELD             → 串成 "me.CallGS" 这样的符号路径
 *   - NEWTABLE + SETFIELD         → 收集表字段名
 *   - CALL json.encode(table)     → 把表传递到结果寄存器
 *   - CALL me.CallGS(name, tbl)   → 记录一条协议
 *
 * 用法:
 *   node work/probe/scan_protocol.js [dumpDir] [--json] [--filter=Shop]
 */
const fs = require('fs');
const path = require('path');
const { load } = require('../../tools/luac54.js');

const OP = {
  MOVE: 0, LOADI: 1, LOADF: 2, LOADK: 3, LOADFALSE: 5, LOADTRUE: 7, LOADNIL: 8,
  GETUPVAL: 9, SETUPVAL: 10, GETTABUP: 11, GETTABLE: 12, GETI: 13, GETFIELD: 14,
  SETTABUP: 15, SETTABLE: 16, SETI: 17, SETFIELD: 18, NEWTABLE: 19, SELF: 20,
  CALL: 68, TAILCALL: 69, RETURN: 70, RETURN0: 71, RETURN1: 72, CLOSURE: 79,
};

const dir = process.argv.slice(2).find(a => !a.startsWith('--')) || null;
const DUMP_DIR = dir && fs.existsSync(dir) ? dir : 'D:/test/cbjq-re/work/_dump';
const AS_JSON = process.argv.includes('--json');
const FILTER = (process.argv.find(a => a.startsWith('--filter=')) || '').slice(9);

const kstr = (p, i) => (typeof p.consts[i] === 'string' ? p.consts[i] : null);

// 符号名 → 字面量映射（由 resolve_symbols.js 生成）
let SYMMAP = {};
try { SYMMAP = JSON.parse(fs.readFileSync(path.join(__dirname, 'symbol_map.json'), 'utf8')); } catch (e) {}
let viaSym = 0;

// 只有真正写 R[A] 的指令才清符号；TEST/JMP/EQ/MMBIN/SETFIELD 等不写，清了会丢变量
const WRITES_A = new Set([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 19, 20,
  21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
  41, 42, 43, 44, 45, 49, 50, 51, 52, 53, 67, 79, 80]);

const api = new Map();   // 字面量接口名 -> { params, callers, where }
const symbolic = new Map(); // 符号形式（模块表字段）-> { params, callers, where }
let sites = 0, resolved = 0;

function record(name, params, caller, where) {
  if (FILTER && !name.includes(FILTER)) return;
  if (!api.has(name)) api.set(name, { params: new Set(), callers: new Set(), where: new Set() });
  const rec = api.get(name);
  params.forEach(x => rec.params.add(x));
  rec.callers.add(caller);
  rec.where.add(where);
}

function scan(p, caller, file) {
  /** 寄存器符号：{kind:'sym', v:'me.CallGS'} | {kind:'str', v:'名称'} | {kind:'tbl', keys:Set} */
  const reg = {};

  // CALL 之后 R[A] 是返回值，只清 A 之后
  const clearAfter = a => { for (const k of Object.keys(reg)) if (+k > a) delete reg[k]; };

  for (let pc = 0; pc < p.code.length; pc++) {
    const i = p.code[pc];
    const op = i & 0x7f;
    const A = (i >>> 7) & 0xff;
    const B = (i >>> 16) & 0xff;
    const C = (i >>> 24) & 0xff;
    const Bx = (i >>> 15) & 0x1ffff;

    switch (op) {
      case OP.GETTABUP: {
        const name = kstr(p, C);
        reg[A] = name ? { kind: 'sym', v: name } : undefined;
        break;
      }
      case OP.GETFIELD: {
        const name = kstr(p, C);
        const base = reg[B];
        reg[A] = (name && base && base.kind === 'sym') ? { kind: 'sym', v: base.v + '.' + name } : undefined;
        break;
      }
      case OP.SELF: {
        // R[A+1] = R[B]; R[A] = R[B][K[C]]
        const name = kstr(p, C);
        const base = reg[B];
        reg[A + 1] = base;
        reg[A] = (name && base && base.kind === 'sym') ? { kind: 'sym', v: base.v + '.' + name } : undefined;
        break;
      }
      case OP.LOADK: {
        const k = p.consts[Bx];
        reg[A] = typeof k === 'string' ? { kind: 'str', v: k } : undefined;
        break;
      }
      case OP.NEWTABLE:
        reg[A] = { kind: 'tbl', keys: new Set() };
        break;
      case OP.SETFIELD: {
        const name = kstr(p, B);
        const t = reg[A];
        if (name && t && t.kind === 'tbl') t.keys.add(name);
        else if (A > 0) reg[A] = undefined;
        break;
      }
      case OP.SETTABLE: case OP.SETI: case OP.SETTABUP:
        if (op === OP.SETTABUP) { const n = kstr(p, B); if (n && reg[A] && reg[A].kind === 'tbl') reg[A].keys.add(n); }
        if (A > 0) reg[A] = undefined;
        break;
      case OP.MOVE:
        reg[A] = reg[B];
        break;
      case OP.CALL: case OP.TAILCALL: {
        const callee = reg[A];
        if (callee && callee.kind === 'sym') {
          if (callee.v === 'json.encode') {
            // 结果继承参数表
            reg[A] = reg[A + 1];
          } else if (callee.v === 'me.CallGS' || callee.v === 'me.CallGSWithDependParam') {
            // SELF 约定：方法在 R[A]，self 在 R[A+1]，实参从 R[A+2] 起
            const nameReg = reg[A + 2];
            const tbl = reg[A + 3];
            sites++;
            const params = tbl && tbl.kind === 'tbl' ? [...tbl.keys] : [];
            if (nameReg && nameReg.kind === 'str') {
              resolved++;
              record(nameReg.v, params, caller, `${file}:${p.linedefined}`);
            } else if (nameReg && nameReg.kind === 'sym') {
              // 名字来自模块表字段，例如 Chapter.REQ_ENTER_LEVEL
              const key = nameReg.v;
              if (SYMMAP[key]) { viaSym++; record(SYMMAP[key], params, caller, `${file}:${p.linedefined}`); clearAfter(A); break; }
              if (!symbolic.has(key)) symbolic.set(key, { params: new Set(), callers: new Set(), where: new Set() });
              const rec = symbolic.get(key);
              params.forEach(x => rec.params.add(x));
              rec.callers.add(caller);
              rec.where.add(`${file}:${p.linedefined}`);
            }
          }
        }
        clearAfter(A);
        break;
      }
      default:
        if (WRITES_A.has(op) && A > 0) reg[A] = undefined;
        break;
    }
  }

  p.protos.forEach((q, idx) => {
    const nm = (q.upvalnames && q.upvalnames[0]) || ('closure' + idx);
    scan(q, caller + '/' + nm, file);
  });
}

let parsed = 0, failed = 0;
for (const f of fs.readdirSync(DUMP_DIR).filter(x => x.endsWith('.luac'))) {
  try {
    const mod = load(fs.readFileSync(path.join(DUMP_DIR, f)));
    scan(mod.main, path.basename(f, '.luac'), f);
    parsed++;
  } catch (e) { failed++; }
}

const rows = [...api.entries()].sort((a, b) => a[0].localeCompare(b[0]));

if (process.argv.includes('--md')) {
  const out = [];
  out.push('# 客户端请求接口清单（CallGS）');
  out.push('');
  out.push('> 由 `work/probe/scan_protocol.js` 从运行时 dump 的 Lua 5.4 字节码自动生成。');
  out.push('> 覆盖范围 = 当前 `work/_dump/` 里已 dump 的模块，不是全量。');
  out.push('');
  out.push(`共 **${rows.length}** 个字面量接口 + **${symbolic.size}** 个符号形式。`);
  out.push('');
  const byGroup = new Map();
  for (const [name, r] of rows) {
    const g = name.includes('_') ? name.split('_')[0] : '(无前缀)';
    if (!byGroup.has(g)) byGroup.set(g, []);
    byGroup.get(g).push([name, r]);
  }
  for (const [g, arr] of [...byGroup.entries()].sort((a, b) => b[1].length - a[1].length)) {
    out.push(`## ${g} (${arr.length})`);
    out.push('');
    out.push('| 接口 | 参数 | 调用方 |');
    out.push('|---|---|---|');
    for (const [name, r] of arr) {
      const params = [...r.params].sort().join(', ') || '—';
      const callers = [...r.callers].slice(0, 2).join('<br>') || '—';
      out.push(`| \`${name}\` | ${params} | ${callers} |`);
    }
    out.push('');
  }
  if (symbolic.size) {
    out.push(`## 符号形式 (${symbolic.size})`);
    out.push('');
    out.push('接口名不是字符串常量，而是模块表字段（如 `Chapter.REQ_ENTER_LEVEL`）。');
    out.push('要拿到字面值需要在运行时把对应模块表的字符串字段 dump 出来。');
    out.push('');
    out.push('| 符号 | 参数 | 调用方 |');
    out.push('|---|---|---|');
    for (const [name, r] of [...symbolic.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      out.push(`| \`${name}\` | ${[...r.params].sort().join(', ') || '—'} | ${[...r.callers][0] || '—'} |`);
    }
    out.push('');
  }
  console.log(out.join('\n'));
  process.exit(0);
}

if (AS_JSON) {
  const out = rows.map(([name, r]) => ({
    api: name,
    params: [...r.params].sort(),
    callers: [...r.callers].sort(),
    where: [...r.where].sort(),
  }));
  for (const [name, r] of [...symbolic.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    out.push({
      api: name, symbol: true,
      params: [...r.params].sort(),
      callers: [...r.callers].sort(),
      where: [...r.where].sort(),
    });
  }
  console.log(JSON.stringify(out, null, 2));
} else {
  console.log(`扫描 ${parsed} 个函数文件（失败 ${failed}）；CallGS 调用点 ${sites} 个，`
    + `解析出字面量 ${resolved} 个 → ${rows.length} 个接口；`
    + `符号还原 ${viaSym} 个，仍未还原 ${symbolic.size} 个\n`);
  const groups = new Map();
  for (const [name] of rows) {
    const g = name.includes('_') ? name.split('_')[0] : '(无前缀)';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(name);
  }
  console.log('按前缀分组：');
  for (const [g, arr] of [...groups.entries()].sort((a, b) => b[1].length - a[1].length)) {
    console.log(`  ${g.padEnd(22)} ${String(arr.length).padStart(3)} 个`);
  }
  console.log('');
  for (const [name, r] of rows) {
    const params = [...r.params].sort().join(', ');
    console.log(`${name}${params ? '   (' + params + ')' : ''}`);
  }

  const sym = [...symbolic.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  if (sym.length) {
    console.log(`\n--- 符号形式（名字是模块表字段，需再跑一次探针取字符串值）---\n`);
    for (const [name, r] of sym) {
      const params = [...r.params].sort().join(', ');
      console.log(`@${name}${params ? '   (' + params + ')' : ''}   ← ${[...r.callers][0]}`);
    }
  }
}
