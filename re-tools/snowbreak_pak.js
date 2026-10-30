#!/usr/bin/env node
'use strict';
/**
 * 尘白禁区 (Snowbreak) pak 索引读取 / AES key 验证
 *
 * 格式依据 unreal_tournament_4_0.4.27e_snowbreak.bms + 实测：
 *   footer  : goto -0xCC; magic(4) version(4) storedOffset(8) storedSize(8) hash(20) comp(160)
 *   indexOff: storedOffset ^ 0x1C1D1E1F
 *   indexLen: (EOF - 0xCC) - indexOff - 1        // footer 里的 size 字段不可信
 *   index   : AES-256-ECB，key = AES-ECB(masterKey, ascii(md5hex(pak名小写)))
 *           解密后是标准 UE4 索引：FString 挂载点 + 条目；文件名以 ASCII 内联存放
 *
 * 用法:
 *   node snowbreak_pak.js <key> verify <pak...> [--list=uasset,lua]
 *   node snowbreak_pak.js <key> sweep  <paksDir>
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const IDX_XOR = 0x1C1D1E1Fn;
const FOOTER_TAIL = 0xCC;
const MAGIC = 0x5A6F12E1;

function derivePakKey(masterKey, pakPath) {
  const base = path.basename(pakPath).replace(/\.pak$/i, '').toLowerCase();
  const md5hex = crypto.createHash('md5').update(base, 'utf8').digest('hex');
  const c = crypto.createCipheriv('aes-256-ecb', masterKey, null);
  c.setAutoPadding(false);
  return Buffer.concat([c.update(Buffer.from(md5hex, 'ascii')), c.final()]);
}

function decryptIndex(pakPath, masterKey) {
  const size = fs.statSync(pakPath).size;
  if (size < FOOTER_TAIL + 128) return { ok: false, reason: '文件过小' };
  const magicOff = size - FOOTER_TAIL;

  const fd = fs.openSync(pakPath, 'r');
  try {
    const f = Buffer.alloc(205);
    fs.readSync(fd, f, 0, 205, magicOff - 1); // f[0]=encrypted 标志, 之后是 footer
    if (f.readUInt32LE(1) !== MAGIC) return { ok: false, reason: 'magic 不匹配' };
    const version = f.readInt32LE(5);
    const indexOff = Number(f.readBigInt64LE(9) ^ IDX_XOR);
    const indexLen = magicOff - indexOff - 1;
    const encrypted = f[0] !== 0;

    if (indexLen <= 0 || indexOff <= 0 || indexOff + indexLen > size) {
      return { ok: false, reason: `索引区间异常 off=${indexOff} len=${indexLen}` };
    }
    if (!encrypted) {
      const raw = Buffer.alloc(indexLen);
      fs.readSync(fd, raw, 0, indexLen, indexOff);
      return { ok: true, version, indexOff, indexLen, encrypted: false, toc: raw };
    }
    const raw = Buffer.alloc(indexLen);
    fs.readSync(fd, raw, 0, indexLen, indexOff);
    const key = derivePakKey(masterKey, pakPath);
    const n = Math.floor(indexLen / 16) * 16;
    const d = crypto.createDecipheriv('aes-256-ecb', key, null);
    d.setAutoPadding(false);
    const toc = Buffer.concat([d.update(raw.subarray(0, n)), d.final()]);
    return { ok: true, version, indexOff, indexLen, encrypted: true, toc };
  } finally { fs.closeSync(fd); }
}

/** 读索引开头的 FString 挂载点，格式对不对一眼可见 */
function readMount(toc) {
  if (toc.length < 8) return null;
  const len = toc.readInt32LE(0);
  if (len <= 1 || len > 512 || 4 + len > toc.length) return null;
  const end = 4 + len - 1; // 去掉结尾 null
  for (let i = 4; i < end; i++) {
    const b = toc[i];
    if (b < 0x20 || b > 0x7e) return null;
  }
  const s = toc.subarray(4, end).toString('latin1');
  return /^(\.\.\/)+|^\//.test(s) ? s : null;
}

/** 从索引里抠出内联的文件名（ASCII FString） */
function listNames(toc, filterExt) {
  const out = [];
  let cur = '';
  for (let i = 0; i < toc.length; i++) {
    const ch = toc[i];
    if (ch >= 0x20 && ch < 0x7f) { cur += String.fromCharCode(ch); }
    else {
      if (cur.length >= 6 && /\.(uasset|uexp|ubulk|umap|lua|ini|json|png|bnk|wem|pcm)$/i.test(cur)) {
        if (!filterExt || filterExt.some(e => cur.toLowerCase().endsWith('.' + e))) out.push(cur);
      }
      cur = '';
    }
  }
  return out;
}

function verify(masterKey, pakPath, filterExt) {
  const r = decryptIndex(pakPath, masterKey);
  if (!r.ok) return { name: path.basename(pakPath), verdict: 'ERROR', detail: r.reason };
  const mount = readMount(r.toc);
  const result = {
    name: path.basename(pakPath),
    verdict: mount ? 'PASS' : 'FAIL',
    version: r.version,
    mount,
    indexKB: +(r.indexLen / 1024).toFixed(1),
  };
  if (mount && filterExt) {
    const names = listNames(r.toc, filterExt);
    result.matched = names.length;
    result.sample = names.slice(0, 12);
  }
  return result;
}

function sweep(masterKey, dir) {
  const paks = fs.readdirSync(dir).filter(f => /\.pak$/i.test(f));
  const stat = { total: paks.length, pass: 0, plain: 0, fail: 0, error: 0 };
  const fails = [];
  let indexBytes = 0;
  const mounts = new Map();
  for (const p of paks) {
    let r;
    try { r = decryptIndex(path.join(dir, p), masterKey); }
    catch (e) { stat.error++; fails.push([p, String(e.message || e)]); continue; }
    if (!r.ok) { stat.error++; fails.push([p, r.reason]); continue; }
    if (!r.encrypted) stat.plain++;
    const mount = readMount(r.toc);
    if (mount) { stat.pass++; indexBytes += r.indexLen; mounts.set(mount, (mounts.get(mount) || 0) + 1); }
    else { stat.fail++; fails.push([p, '挂载点不可读']); }
  }
  return {
    stat, indexMB: +(indexBytes / 1048576).toFixed(1),
    mounts: [...mounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12),
    failSamples: fails.slice(0, 8),
  };
}

function main() {
  const [, , keyHex, mode, ...rest] = process.argv;
  if (!keyHex || !/^[0-9a-fA-F]{64}$/.test(keyHex)) { console.error('需要 64 位十六进制主密钥'); process.exit(2); }
  const key = Buffer.from(keyHex, 'hex');
  const listArg = rest.find(a => a.startsWith('--list='));
  const filterExt = listArg ? listArg.slice(7).split(',').map(s => s.trim().toLowerCase()) : null;
  const args = rest.filter(a => !a.startsWith('--'));

  if (mode === 'sweep') { console.log(JSON.stringify(sweep(key, args[0]), null, 2)); return; }
  for (const p of args) console.log(JSON.stringify(verify(key, p, filterExt), null, 2));
}

main();
