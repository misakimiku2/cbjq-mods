// Brute-force search for the Snowbreak pak AES main key inside binaries.
// Oracle: decrypt pak index block 0..N with candidate key (raw, and transformed
// via AES-ECB(key, md5hex_ascii(pakname))) and look for a readable mount point.
use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes256;
use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;

const INDEX_MAGIC: [u8; 4] = 0x5A6F12E1u32.to_le_bytes();
const XOR_OFF: u64 = 0x1C1D1E1F;

fn md5_hex_ascii_lower(data: &[u8]) -> [u8; 32] {
    // minimal MD5 implementation (public domain algorithm)
    let digest = md5::compute(data);
    let hex = format!("{:x}", digest);
    let mut out = [0u8; 32];
    out.copy_from_slice(hex.as_bytes());
    out
}

struct Candidate<'a> {
    key: &'a [u8; 32],
    label: String,
}

fn try_key(cipher_raw: &Aes256, transformed: &Aes256, idx_block: &[u8; 64]) -> Option<&'static str> {
    // raw
    let mut block = *idx_block;
    for chunk in block.chunks_exact_mut(16) {
        let mut arr = [0u8; 16];
        arr.copy_from_slice(chunk);
        cipher_raw.decrypt_block(&mut arr.into());
        chunk.copy_from_slice(&arr);
    }
    if readable_mount(&block) {
        return Some("RAW");
    }
    // transformed
    let mut tblock = *idx_block;
    for chunk in tblock.chunks_exact_mut(16) {
        let mut arr = [0u8; 16];
        arr.copy_from_slice(chunk);
        transformed.decrypt_block(&mut arr.into());
        chunk.copy_from_slice(&arr);
    }
    if readable_mount(&tblock) {
        return Some("TRANSFORMED");
    }
    None
}

fn readable_mount(b: &[u8; 64]) -> bool {
    let len = i32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    if !(-512..=512).contains(&len) || len == 0 {
        return false;
    }
    let ulen = len.unsigned_abs() as usize;
    if ulen < 4 || ulen > 60 || 4 + ulen > 64 {
        return false;
    }
    let start = 4;
    let end = 4 + if len < 0 { ulen * 2 } else { ulen };
    if len < 0 {
        // utf16: check that odd bytes are 0 and even bytes printable
        let mut ok = 0;
        for i in (start..end).step_by(2) {
            if b[i] >= 0x20 && b[i] < 0x7f && b[i + 1] == 0 {
                ok += 1;
            }
        }
        ok >= 4 && ok * 2 >= (end - start) - 2
    } else {
        let mut ok = 0;
        for &c in &b[start..end] {
            if c >= 0x20 && c < 0x7f {
                ok += 1;
            }
        }
        // allow the trailing null
        ok + 1 >= (end - start) && (end - start) >= 8
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: pakkeyscan <pakfile> <binary1> [binary2...]");
        std::process::exit(1);
    }
    let pak_path = &args[1];
    let pak = fs::read(pak_path).expect("read pak");

    // locate footer
    let mut foot = None;
    let start = pak.len().saturating_sub(4096);
    for i in start..pak.len().saturating_sub(4) {
        if pak[i] == INDEX_MAGIC[0] && pak[i + 1] == INDEX_MAGIC[1] && pak[i + 2] == INDEX_MAGIC[2] && pak[i + 3] == INDEX_MAGIC[3] {
            foot = Some(i);
            break;
        }
    }
    let foot = foot.expect("footer magic not found");
    let idx_off = (u64::from_le_bytes(pak[foot + 8..foot + 16].try_into().unwrap()) ^ XOR_OFF) as usize;
    let idx_size = u64::from_le_bytes(pak[foot + 16..foot + 24].try_into().unwrap()) as usize;
    eprintln!("pak: idxOff={} idxSize={}", idx_off, idx_size);
    let idx_block: [u8; 64] = pak[idx_off..idx_off + 64].try_into().unwrap();

    // pak name for transform
    let pak_name = Path::new(pak_path)
        .file_stem()
        .unwrap()
        .to_string_lossy()
        .to_lowercase();
    let md5hex = md5_hex_ascii_lower(pak_name.as_bytes());
    eprintln!("pakname={} md5ascii={}", pak_name, String::from_utf8_lossy(&md5hex));

    let mut out = fs::File::create("pakkeyscan_hits.txt").unwrap();

    for bin_path in &args[2..] {
        let data = match fs::read(bin_path) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("skip {}: {}", bin_path, e);
                continue;
            }
        };
        eprintln!("scanning {} ({} MB)", bin_path, data.len() / 1024 / 1024);
        let mut found = 0u32;
        for off in 0..data.len().saturating_sub(32) {
            let key: &[u8; 32] = match data[off..off + 32].try_into() {
                Ok(k) => k,
                Err(_) => continue,
            };
            let raw = Aes256::new_from_slice(key).unwrap();
            // transformed: AES-ECB-encrypt(key, md5ascii32)
            let mut t0 = [0u8; 16];
            let mut t1 = [0u8; 16];
            t0.copy_from_slice(&md5hex[0..16]);
            t1.copy_from_slice(&md5hex[16..32]);
            raw.encrypt_block(&mut t0.into());
            raw.encrypt_block(&mut t1.into());
            let mut tk = [0u8; 32];
            tk[0..16].copy_from_slice(&t0);
            tk[16..32].copy_from_slice(&t1);
            let trans = Aes256::new_from_slice(&tk).unwrap();
            if let Some(kind) = try_key(&raw, &trans, &idx_block) {
                println!("HIT {} @{}:{} key={}", bin_path, off, kind, hex(key));
                writeln!(out, "{}\t{}\t{}\t{}", bin_path, off, kind, hex(key)).unwrap();
                found += 1;
            }
            if off % 0x4000000 == 0 && off > 0 {
                eprintln!("  ...at {} MB", off / 1024 / 1024);
            }
        }
        eprintln!("done {}: {} hits", bin_path, found);
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}
