#!/usr/bin/env node
'use strict';
/**
 * 尘白禁区 pak 文件提取
 *
 * 链路（实测验证）：
 *   TOC 头部: mount(FString) files(4) dummy(12) hashesOff(8) hashesSize(8) dummy(24)
 *             namesOff(8) namesSize(8) dummy(24) baseEntryOff
 *   hashes区: 每文件 12 字节 = hash(8) + entryRel(4)
 *   条目    : FLAGS(4) [chunk(4)] offset(4|8)        ← FLAGS>>28==0xE 时 4 字节
 *   数据区  : 每个文件区域起始处有一份内联 FPakEntry
 *             [0(8)] size(8) usize(8) method(4) hash(20) blockCount(4) blocks(8+8)*
 *             block 偏移相对区域起始
 *   解压    : 每块 AES-256-ECB(perPakKey) 解密 → zlib inflate
 *   文件偏移: offset ^ 0x1F1E1D1C
 *
 * 用法:
 *   node snowbreak_extract.js <pak> <outDir> [--grep=goodsList] [--limit=20] [--luaKey=...]
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');

const IDX_XOR = 0x1C1D1E1Fn;
const DATA_XOR = 0x1F1E1D1Cn;
const FOOTER_TAIL = 0xCC;

const pakPath = process.argv[2];
const outDir = process.argv[3] || path.join(process.cwd(), 'extracted');
const opt = Object.fromEntries(process.argv.slice(4).filter(a => a.startsWith('--')).map(a => {
  const [k, v] = a.replace(/^--/, '').split('='); return [k, v ?? true];
}));
// 主密钥来源：环境变量 SNOWBREAK_KEY 优先，其次同目录 .snowbreak-key 文件
const keyHex = (process.env.SNOWBREAK_KEY || '').trim()
  || (fs.existsSync(path.join(__dirname, '.snowbreak-key'))
      ? fs.readFileSync(path.join(__dirname, '.snowbreak-key'), 'utf8').trim()
      : '');
if (!/^[0-9a-fA-F]{64}$/.test(keyHex)) {
  console.error('缺少主密钥：设 SNOWBREAK_KEY 环境变量，或在脚本同目录放 .snowbreak-key（64 位 hex）');
  process.exit(2);
}
const MASTER = Buffer.from(keyHex, 'hex');
// 注意：Lua key 是按 ASCII 取 32 字节（与 build_both.js 一致），不是 hex 解码
const LUA_KEY = opt.luaKey ? Buffer.from(String(opt.luaKey), 'latin1') : null;
const LIMIT = opt.limit ? parseInt(opt.limit, 10) : Infinity;

const all = fs.readFileSync(pakPath);
const size = all.length;
const magicOff = size - FOOTER_TAIL;
const indexOff = Number(all.readBigInt64LE(magicOff + 8) ^ IDX_XOR);
const indexLen = magicOff - indexOff - 1;

const pakBase = path.basename(pakPath).replace(/\.pak$/i, '').toLowerCase();
const kk = crypto.createCipheriv('aes-256-ecb', MASTER, null);
kk.setAutoPadding(false);
const pakKey = Buffer.concat([kk.update(Buffer.from(crypto.createHash('md5').update(pakBase, 'utf8').digest('hex'), 'ascii')), kk.final()]);

function aesDec(key, buf) {
  const n = Math.floor(buf.length / 16) * 16;
  const d = crypto.createDecipheriv('aes-256-ecb', key, null);
  d.setAutoPadding(false);
  return Buffer.concat([d.update(buf.subarray(0, n)), d.final()]);
}

const rawIdx = all.subarray(indexOff, indexOff + indexLen);
const toc = aesDec(pakKey, rawIdx);

// ---- TOC 头 ----
const mountLen = toc.readInt32LE(0);
const mount = toc.subarray(4, 4 + mountLen - 1).toString('latin1');
let p = 4 + mountLen;
const files = toc.readInt32LE(p); p += 4 + 12;
const hashesOff = Number(toc.readBigInt64LE(p)) - indexOff; p += 16;
p += 24;
const namesOff = Number(toc.readBigInt64LE(p)) - indexOff; p += 16;
p += 24;
const baseEntry = p;

// ---- 名字表（2026-10-31 修正：结构化解析，替代旧的盲扫猜配对）----
// 实测结构：若干 [u32 dirLen][目录串(以/结尾)][u32 fileCount]
//           然后(fileCount 个) [u32 nameLen][文件名\0][u32 entryRel]
// 名字记录自带的 entryRel 才是名字↔条目的权威映射；旧版按顺序盲扫在带目录的包里会错位，
// 导致解出的文件名张冠李戴（内容本身没问题，数据区仍按 hash 记录取）。
function parseNames() {
  const region = toc.subarray(namesOff);
  const isDirStr = (q) => {
    if (q + 8 > region.length) return -1;
    const len = region.readUInt32LE(q);
    if (len < 3 || len > 200 || q + 4 + len > region.length) return -1;
    const s = region.subarray(q + 4, q + 4 + len).toString('latin1');
    if (s.charCodeAt(s.length - 1) !== 0) return -1;
    const c = s.slice(0, -1);
    return (/^[A-Za-z0-9_\-./]+$/.test(c) && c.endsWith('/') && c.includes('/')) ? len : -1;
  };
  const byRel = new Map();
  let i = 0;
  while (i < 0x100 && i + 8 <= region.length && isDirStr(i) < 0) i++;
  let dir = '';
  while (i + 8 <= region.length) {
    const dl = isDirStr(i);
    if (dl > 0) {
      dir = region.subarray(i + 4, i + 4 + dl - 1).toString('latin1');
      i += 4 + dl;
      if (i + 4 > region.length) break;
      const fileCount = region.readUInt32LE(i); i += 4;
      for (let k = 0; k < fileCount && i + 8 <= region.length; k++) {
        const nl = region.readUInt32LE(i); i += 4;
        if (nl < 5 || nl > 250 || i + nl + 4 > region.length) break;
        const nm = region.subarray(i, i + nl).toString('latin1');
        i += nl;
        const rel = region.readUInt32LE(i); i += 4;
        byRel.set(rel, { dir, name: nm.replace(/\0$/, '') });
      }
      continue;
    }
    i++;
  }
  // hash 记录 i 的 rel → 名字（名字区与 hash 区顺序不同，rel 是唯一桥梁）
  const out = new Array(files).fill(null);
  for (let r = 0; r < files; r++) {
    const rel = toc.readUInt32LE(hashesOff + 4 + r * 12 + 8);
    out[r] = byRel.get(rel) || null;
  }
  return out;
}
const names = parseNames();

// ---- 条目表 ----
function readEntry(rel) {
  let q = baseEntry + rel;
  const flags = toc.readUInt32LE(q); q += 4;
  if ((flags & 0x3f) === 0x3f) q += 4;
  const is64 = (flags >>> 28) === 0xe;
  const raw = is64 ? BigInt(toc.readUInt32LE(q)) : toc.readBigInt64LE(q);
  return { flags, dataOff: Number(raw ^ DATA_XOR), is64 };
}

function extractRegion(regionOff) {
  const sz = Number(all.readBigInt64LE(regionOff + 8));
  const usz = Number(all.readBigInt64LE(regionOff + 16));
  const method = all.readUInt32LE(regionOff + 24);
  const blockCount = all.readUInt32LE(regionOff + 48);
  if (blockCount > 200000) throw new Error('blockCount 异常 ' + blockCount);
  if (method === 0) {
    // 实测数据起点 = 区域起点 + 53（用头部 SHA1 反查确认）
    const body = all.subarray(regionOff + 53, regionOff + 53 + sz);
    return { data: body, usz, method };
  }
  const chunks = [];
  for (let i = 0; i < blockCount; i++) {
    const s = regionOff + Number(all.readBigInt64LE(regionOff + 52 + i * 16));
    const e = regionOff + Number(all.readBigInt64LE(regionOff + 60 + i * 16));
    if (e <= s || e > all.length) throw new Error(`块区间异常 ${s}-${e}`);
    const padded = Math.ceil((e - s) / 16) * 16;
    const dec = aesDec(pakKey, all.subarray(s, Math.min(s + padded, all.length)));
    let out;
    try { out = zlib.inflateSync(dec); }
    catch (err) { out = zlib.inflateSync(dec, { finishFlush: zlib.constants.Z_SYNC_FLUSH }); }
    chunks.push(out);
  }
  return { data: Buffer.concat(chunks), usz, method };
}

// ---- 主循环 ----
fs.mkdirSync(outDir, { recursive: true });
const grepList = opt.grep ? String(opt.grep).split(',').map(s => s.trim()).filter(Boolean) : null;
const matches = (buf) => {
  if (!grepList) return false;
  const s = buf.toString('latin1');
  return grepList.some(g => s.includes(g));
};
let ok = 0, fail = 0, hit = 0, luaOk = 0;
const fails = [];
const hits = [];
const manifest = [];

for (let i = 0; i < files && ok + fail < LIMIT; i++) {
  // 12 字节记录 = (u64 名字哈希, u32 条目相对偏移)，区首另有 4 字节计数
  const rec = hashesOff + 4 + i * 12;
  if (rec + 12 > toc.length) break;
  const rel = toc.readUInt32LE(rec + 8);
  let entry;
  try { entry = readEntry(rel); } catch (e) { fail++; fails.push([i, 'entry:' + e.message]); continue; }

  let res;
  try { res = extractRegion(entry.dataOff); }
  catch (e) { fail++; fails.push([i, 'region:' + e.message]); continue; }

  let data = res.data;
  // Lua 单文件加密：先按 pak 解开后仍是密文，用 Lua key 再解
  if (LUA_KEY && data.length >= 16) {
    const probe = aesDec(LUA_KEY, data.subarray(0, Math.min(data.length, 512)));
    const txt = probe.toString('latin1');
    if (/^[\s\xef\xbb\xbf]*(--|local |return |function |#!)/.test(txt) || /[\x20-\x7e]{6}/.test(txt) && !/^[\x00-\x08]/.test(txt)) {
      // 整块 AES-ECB + 末尾 <16 字节明文残留
      const fl = Math.floor(data.length / 16) * 16;
      const dec = Buffer.concat([aesDec(LUA_KEY, data.subarray(0, fl)), data.subarray(fl)]);
      // 只有解出来全是可打印/换行才认
      if (dec.length && dec.subarray(0, Math.min(dec.length, 200)).every(b => b === 9 || b === 10 || b === 13 || (b >= 0x20 && b < 0x7f))) {
        data = dec; luaOk++;
      }
    }
  }

  const nm = names[i];
  const name = nm ? (nm.dir ? nm.dir : '') + nm.name : `f${String(i).padStart(5, '0')}`;
  ok++;
  const info = { i, name, pak: path.basename(pakPath), dataOff: entry.dataOff, size: data.length, usz: res.usz, method: res.method };
  manifest.push(info);

  const isHit = matches(data);
  if (isHit || opt.write) {
    if (isHit) { hit++; hits.push(info); }
    const safe = name.replace(/[\\/:*?"<>|]/g, '_') || `f${String(i).padStart(5, '0')}`;
    fs.writeFileSync(path.join(outDir, `${String(i).padStart(5, '0')}_${safe}`), data);
  }
}

// 名字区/条目区 dump 供诊断
const diag = { pak: path.basename(pakPath), mount, files, baseEntry, hashesOff, namesOff, ok, fail, luaOk, hit };
if (opt.dump) {
  fs.writeFileSync(path.join(outDir, '_manifest.json'), JSON.stringify(manifest, null, 1));
  fs.writeFileSync(path.join(outDir, '_diag.json'), JSON.stringify({ ...diag, fails: fails.slice(0, 20) }, null, 1));
}
console.log(JSON.stringify({ ...diag, fails: fails.slice(0, 8), hits: hits.slice(0, 20) }, null, 2));
