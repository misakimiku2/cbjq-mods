#!/usr/bin/env node
'use strict';
/**
 * Lua 5.4 字节码解析 / 反汇编
 *
 * 用途：分析 ShopProbe 从游戏运行时 dump 出来的 .luac（string.dump 的产物）。
 * 只依赖 Node，不需要 JVM 或反编译器。
 *
 * 用法:
 *   node tools/luac54.js <file.luac...>            # 概览：函数树 + 常量
 *   node tools/luac54.js <file.luac...> --disasm   # 追加线性反汇编
 *   node tools/luac54.js <file.luac...> --grep=goods   # 只展开常量命中的函数
 */
const fs = require('fs');

const F = {
  NIL: 0, FALSE: 1, TRUE: 17, NUMINT: 3, NUMFLT: 19, SHRSTR: 4, LNGSTR: 20,
};

const OPS = ['MOVE', 'LOADI', 'LOADF', 'LOADK', 'LOADKX', 'LOADFALSE', 'LFALSESKIP', 'LOADTRUE',
  'LOADNIL', 'GETUPVAL', 'SETUPVAL', 'GETTABUP', 'GETTABLE', 'GETI', 'GETFIELD', 'SETTABUP',
  'SETTABLE', 'SETI', 'SETFIELD', 'NEWTABLE', 'SELF', 'ADDI', 'ADDK', 'SUBK', 'MULK', 'MODK',
  'POWK', 'DIVK', 'IDIVK', 'BANDK', 'BORK', 'BXORK', 'SHRI', 'SHLI', 'ADD', 'SUB', 'MUL', 'MOD',
  'POW', 'DIV', 'IDIV', 'BAND', 'BOR', 'BXOR', 'SHL', 'SHR', 'MMBIN', 'MMBINI', 'MMBINK', 'UNM',
  'BNOT', 'NOT', 'LEN', 'CONCAT', 'CLOSE', 'TBC', 'JMP', 'EQ', 'LT', 'LE', 'EQK', 'EQI', 'LTI',
  'LEI', 'GTI', 'GEI', 'TEST', 'TESTSET', 'CALL', 'TAILCALL', 'RETURN', 'RETURN0', 'RETURN1',
  'FORLOOP', 'FORPREP', 'TFORPREP', 'TFORCALL', 'TFORLOOP', 'SETLIST', 'CLOSURE', 'VARARG',
  'VARARGPREP', 'EXTRAARG'];

class Reader {
  constructor(buf) { this.b = buf; this.p = 0; }
  byte() { return this.b[this.p++]; }
  bytes(n) { const s = this.b.subarray(this.p, this.p + n); this.p += n; return s; }
  int64() { const v = this.b.readBigInt64LE(this.p); this.p += 8; return v; }
  uint32() { const v = this.b.readUInt32LE(this.p); this.p += 4; return v; }
  double() { const v = this.b.readDoubleLE(this.p); this.p += 8; return v; }
  // Lua 5.4 的 size 编码：大端、高位为 0 表示继续，高位为 1 表示结束
  varint() {
    let x = 0, b;
    do { b = this.b[this.p++]; x = (x << 7) | (b & 0x7f); } while ((b & 0x80) === 0);
    return x >>> 0;
  }
  string() {
    const n = this.varint();
    if (n === 0) return null;
    // n 含结尾 NUL，实际只写 n-1 字节
    const s = this.b.subarray(this.p, this.p + n - 1).toString('utf8');
    this.p += n - 1;
    return s;
  }
}

function parseProto(r) {
  const p = {};
  p.source = r.string();
  p.linedefined = r.varint();
  p.lastlinedefined = r.varint();
  p.numparams = r.byte();
  p.is_vararg = r.byte();
  p.maxstacksize = r.byte();

  const ncode = r.varint();
  p.code = [];
  for (let i = 0; i < ncode; i++) p.code.push(r.uint32());

  const nk = r.varint();
  p.consts = [];
  for (let i = 0; i < nk; i++) {
    const t = r.byte();
    if (t === F.NIL) p.consts.push(null);
    else if (t === F.FALSE) p.consts.push(false);
    else if (t === F.TRUE) p.consts.push(true);
    else if (t === F.NUMINT) p.consts.push(Number(r.int64()));
    else if (t === F.NUMFLT) p.consts.push(r.double());
    else if ((t & 0x0f) === 4) p.consts.push(r.string());
    else throw new Error('未知常量类型 0x' + t.toString(16) + ' @' + (r.p - 1));
  }

  const nup = r.varint();
  p.upvals = [];
  for (let i = 0; i < nup; i++) p.upvals.push({ instack: r.byte(), idx: r.byte(), kind: r.byte() });

  const np = r.varint();
  p.protos = [];
  for (let i = 0; i < np; i++) p.protos.push(parseProto(r));

  // debug
  const nline = r.varint();
  p.lineinfo = [];
  for (let i = 0; i < nline; i++) p.lineinfo.push(r.byte());
  const nabs = r.varint();
  p.abslineinfo = [];
  for (let i = 0; i < nabs; i++) p.abslineinfo.push({ pc: r.varint(), line: r.varint() });
  const nloc = r.varint();
  p.locvars = [];
  for (let i = 0; i < nloc; i++) p.locvars.push({ name: r.string(), startpc: r.varint(), endpc: r.varint() });
  const nupn = r.varint();
  p.upvalnames = [];
  for (let i = 0; i < nupn; i++) p.upvalnames.push(r.string());
  return p;
}

function load(buf) {
  const r = new Reader(buf);
  const sig = r.bytes(4).toString('hex');
  if (sig !== '1b4c7561') throw new Error('不是 Lua 字节码: ' + sig);
  const ver = r.byte();
  const fmt = r.byte();
  r.bytes(6);           // LUAC_DATA
  const szInstr = r.byte(), szInt = r.byte(), szNum = r.byte();
  r.int64(); r.double();
  const sizeUpvalCount = r.byte(); // 5.4 header 末尾：upvalue 计数字段的字节宽度
  return { version: ver, format: fmt, szInstr, szInt, szNum, sizeUpvalCount, main: parseProto(r) };
}

// ---- 反汇编 ----
function kstr(p, idx) {
  if (idx < 0 || idx >= p.consts.length) return 'K?' + idx;
  const c = p.consts[idx];
  if (typeof c === 'string') return JSON.stringify(c);
  return String(c);
}

function disasm(p, upnames, out) {
  for (let pc = 0; pc < p.code.length; pc++) {
    const i = p.code[pc];
    const op = i & 0x7f;
    const A = (i >>> 7) & 0xff;
    const k = (i >>> 15) & 1;
    const B = (i >>> 16) & 0xff;
    const C = (i >>> 24) & 0xff;
    const Bx = (i >>> 15) & 0x1ffff;
    const sBx = Bx - 65535;
    const Ax = (i >>> 7) & 0x1ffffff;
    const name = OPS[op] || ('OP' + op);
    let desc = '';
    switch (name) {
      case 'GETFIELD': desc = `R${A} = R${B}.${kstr(p, C)}`; break;
      case 'SETFIELD': desc = `R${A}.${kstr(p, B)} = R${C}`; break;
      case 'GETTABLE': desc = `R${A} = R${B}[R${C}]`; break;
      case 'SETTABLE': desc = `R${A}[R${B}] = R${C}`; break;
      case 'GETTABUP': desc = `R${A} = U${B}.${kstr(p, C)}`; break;
      case 'SETTABUP': desc = `U${A}.${kstr(p, B)} = R${C}`; break;
      case 'SELF': desc = `R${A + 1}=R${B}; R${A}=R${B}.${kstr(p, C)}`; break;
      case 'LOADK': desc = `R${A} = ${kstr(p, Bx)}`; break;
      case 'LOADI': desc = `R${A} = ${sBx}`; break;
      case 'LOADF': desc = `R${A} = ${sBx}`; break;
      case 'GETUPVAL': desc = `R${A} = U${B} (${upnames[B] || '?'})`; break;
      case 'SETUPVAL': desc = `U${B} = R${A}`; break;
      case 'NEWTABLE': desc = `R${A} = {} (b=${B} c=${C})`; break;
      case 'CALL': desc = `R${A}.. = call(R${A}) nargs=${B - 1} nret=${C - 1}`; break;
      case 'TAILCALL': desc = `tailcall R${A} nargs=${B - 1}`; break;
      case 'RETURN': desc = `return R${A}..${A + B - 2} (n=${B - 1})`; break;
      case 'RETURN0': desc = 'return'; break;
      case 'RETURN1': desc = `return R${A}`; break;
      case 'JMP': desc = `pc += ${sBx + 1} -> ${pc + 1 + sBx + 1}`; break;
      case 'EQ': case 'LT': case 'LE': desc = `if (${k ? 'K' : 'R'}${B} ${name} ${k ? 'K' : 'R'}${C}) ~= ${A ? 0 : 1} then pc++`; break;
      case 'TEST': desc = `if R${A} ~= ${C} then pc++`; break;
      case 'TESTSET': desc = `if R${B} ~= ${C} then R${A}=R${B} else pc++`; break;
      case 'FORPREP': desc = `prep R${A} -> ${pc + 1 + sBx}`; break;
      case 'FORLOOP': desc = `loop R${A} -> ${pc + 1 + sBx}`; break;
      case 'TFORPREP': desc = `tforprep R${A} -> ${pc + 1 + sBx}`; break;
      case 'TFORCALL': desc = `tforcall R${A} n=${C}`; break;
      case 'TFORLOOP': desc = `tforloop R${A + 2} -> ${pc + 1 + sBx}`; break;
      case 'SETLIST': desc = `R${A}[${C}..] = R${A + 1}.. n=${B}`; break;
      case 'CLOSURE': desc = `R${A} = closure(K${Bx})`; break;
      case 'VARARG': desc = `R${A}.. = vararg n=${C - 1}`; break;
      case 'EXTRAARG': desc = `extra=${Ax}`; break;
      default: desc = `A=${A} B=${B} C=${C}`;
    }
    out.push(`  ${String(pc).padStart(4)}  ${name.padEnd(11)} ${desc}`);
  }
}

// ---- 遍历 ----
const GREP = (process.argv.find(a => a.startsWith('--grep=')) || '').slice(7).toLowerCase();
const DISASM = process.argv.includes('--disasm');

function walk(p, path, out, depth) {
  const consts = p.consts.filter(c => typeof c === 'string');
  const hit = !GREP || consts.some(c => c.toLowerCase().includes(GREP));
  const label = path.join('.');
  if (hit) {
    out.push(`\n=== ${label}  (行 ${p.linedefined}-${p.lastlinedefined}, 参数 ${p.numparams}, 栈 ${p.maxstacksize}, 指令 ${p.code.length}) ===`);
    if (consts.length) {
      const shown = consts.slice(0, 400).map(c => JSON.stringify(c));
      out.push('  常量: ' + shown.join(' '));
    }
    const up = p.upvalnames.filter(Boolean);
    if (up.length) out.push('  upvalue: ' + up.join(', '));
    if (DISASM) disasm(p, p.upvalnames, out);
  }
  p.protos.forEach((q, i) => {
    const nm = (q.upvalnames && q.upvalnames[0]) || ('sub' + i);
    walk(q, [...path, nm], out, depth + 1);
  });
}

function mainCli() {
for (const file of process.argv.slice(2).filter(a => !a.startsWith('--'))) {
  const buf = fs.readFileSync(file);
  const mod = load(buf);
  const out = [`\n########## ${require('path').basename(file)}  (Lua 5.${mod.version - 0x50}, ${buf.length} 字节) ##########`];
  walk(mod.main, [require('path').basename(file, '.luac')], out, 0);
  console.log(out.join('\n'));
}
}

if (require.main === module) mainCli();
module.exports = { load, disasm, OPS };
