//! Deterministic AES-128-CBC segment decryption for HLS (RFC 8216 Section 4.3.2.4).

use aes::Aes128;
use cbc::cipher::block_padding::{NoPadding, Pkcs7};
use cbc::cipher::{BlockDecryptMut, KeyIvInit};

type Aes128CbcDec = cbc::Decryptor<Aes128>;

pub struct Aes128SegmentDecryptor;

impl Aes128SegmentDecryptor {
    pub const BLOCK_SIZE: usize = 16;

    /// Parses a 16-byte IV from a hex string (with or without `0x`/`0X` prefix).
    pub fn parse_iv_hex(hex_str: &str) -> Result<[u8; 16], String> {
        let trimmed = hex_str.trim();
        let clean = trimmed
            .strip_prefix("0x")
            .or_else(|| trimmed.strip_prefix("0X"))
            .unwrap_or(trimmed);

        if clean.is_empty() {
            return Err("IV hex string is empty".to_string());
        }
        if clean.len() > 32 {
            return Err(format!("IV hex string too long: {}", clean.len()));
        }

        let padded = format!("{:0>32}", clean);
        let mut iv = [0u8; 16];
        for (i, slot) in iv.iter_mut().enumerate() {
            let byte_hex = &padded[i * 2..i * 2 + 2];
            *slot = u8::from_str_radix(byte_hex, 16)
                .map_err(|e| format!("Invalid hex byte in IV: {}", e))?;
        }
        Ok(iv)
    }

    /// Derives the default HLS 128-bit big-endian IV from a media sequence number.
    #[inline]
    pub fn iv_from_sequence(seq: u64) -> [u8; 16] {
        let mut iv = [0u8; 16];
        iv[8..16].copy_from_slice(&seq.to_be_bytes());
        iv
    }

    /// Validates that the encrypted payload is a non-empty multiple of the 16-byte AES block size.
    fn validate_ciphertext_alignment(encrypted_data: &[u8]) -> Result<(), String> {
        if encrypted_data.len() % Self::BLOCK_SIZE != 0 {
            return Err(format!(
                "Encrypted data length ({}) is not a multiple of 16 bytes",
                encrypted_data.len()
            ));
        }
        Ok(())
    }

    /// Deterministically decrypts an AES-128-CBC encrypted HLS segment with RFC 8216 PKCS#7 padding.
    pub fn decrypt_segment(
        encrypted_data: &[u8],
        key: &[u8; 16],
        iv: &[u8; 16],
    ) -> Result<Vec<u8>, String> {
        if encrypted_data.is_empty() {
            return Ok(Vec::new());
        }
        Self::validate_ciphertext_alignment(encrypted_data)?;

        let mut buf = encrypted_data.to_vec();
        let decryptor = Aes128CbcDec::new(key.into(), iv.into());
        let unpadded = decryptor
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(|_| "AES-128-CBC PKCS#7 unpadding failed".to_string())?;
        Ok(unpadded.to_vec())
    }

    /// Deterministically decrypts an unpadded AES-128-CBC payload when the caller explicitly knows no PKCS#7 padding is present.
    pub fn decrypt_segment_no_padding(
        encrypted_data: &[u8],
        key: &[u8; 16],
        iv: &[u8; 16],
    ) -> Result<Vec<u8>, String> {
        if encrypted_data.is_empty() {
            return Ok(Vec::new());
        }
        Self::validate_ciphertext_alignment(encrypted_data)?;

        let mut buf = encrypted_data.to_vec();
        let decryptor = Aes128CbcDec::new(key.into(), iv.into());
        let plain = decryptor
            .decrypt_padded_mut::<NoPadding>(&mut buf)
            .map_err(|_| "AES-128-CBC raw block decryption failed".to_string())?;
        Ok(plain.to_vec())
    }
}
