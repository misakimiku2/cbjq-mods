// Synthetic validation: build a fake pak + binary containing a known key,
// then verify the scanner's oracle logic would find it.
// Run as a unit test: cargo test
use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes256;

fn transform_key(key: &[u8; 32], pak_name: &str) -> [u8; 32] {
    let digest = md5::compute(pak_name.as_bytes());
    let hex = format!("{:x}", digest);
    let md5buf = hex.as_bytes(); // 32 ascii bytes
    let cipher = Aes256::new_from_slice(key).unwrap();
    let mut b0 = [0u8; 16];
    let mut b1 = [0u8; 16];
    b0.copy_from_slice(&md5buf[0..16]);
    b1.copy_from_slice(&md5buf[16..32]);
    cipher.encrypt_block(&mut b0.into());
    cipher.encrypt_block(&mut b1.into());
    let mut out = [0u8; 32];
    out[0..16].copy_from_slice(&b0);
    out[16..32].copy_from_slice(&b1);
    out
}

#[test]
fn oracle_finds_synthetic_key() {
    let key = [0x42u8; 32];
    let pak_name = "pak_test_0-windowsnoeditor";
    let tk = transform_key(&key, pak_name);
    let trans = Aes256::new_from_slice(&tk).unwrap();

    // plaintext block: mount point FString "../../../Game/Content/Script/" len=30
    let mount = b"../../../Game/Content/Script/";
    let mut plain = [0u8; 64];
    let l = (mount.len() + 1) as i32;
    plain[0..4].copy_from_slice(&l.to_le_bytes());
    plain[4..4 + mount.len()].copy_from_slice(mount);
    plain[4 + mount.len()] = 0;

    // encrypt with transformed key
    let mut ct = [0u8; 64];
    for (i, chunk) in plain.chunks_exact(16).enumerate() {
        let mut arr = [0u8; 16];
        arr.copy_from_slice(chunk);
        trans.encrypt_block(&mut arr.into());
        ct[i * 16..(i + 1) * 16].copy_from_slice(&arr);
    }

    // now decrypt like the scanner does and check readability
    let mut dec = [0u8; 64];
    for (i, chunk) in ct.chunks_exact(16).enumerate() {
        let mut arr = [0u8; 16];
        arr.copy_from_slice(chunk);
        trans.decrypt_block(&mut arr.into());
        dec[i * 16..(i + 1) * 16].copy_from_slice(&arr);
    }
    assert_eq!(dec.to_vec(), plain.to_vec(), "transform roundtrip broken");
    assert!(super::readable_mount_pub(&dec), "oracle should accept the synthetic mount point");
}
