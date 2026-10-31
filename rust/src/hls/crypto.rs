use aes::Aes128;
use cbc::cipher::block_padding::Pkcs7;
use cbc::cipher::{BlockDecryptMut, KeyIvInit};

type Aes128CbcDec = cbc::Decryptor<Aes128>;

pub struct Aes128SegmentDecryptor;

impl Aes128SegmentDecryptor {
    /// Parses a 16-byte IV from a hex string (e.g., "0x00000000000000000000000000000001" or without "0x").
    pub fn parse_iv_hex(hex_str: &str) -> Result<[u8; 16], String> {
        let clean = hex_str.trim().strip_prefix("0x").unwrap_or(hex_str.trim());
        let clean = clean.strip_prefix("0X").unwrap_or(clean);

        if clean.len() > 32 {
            return Err(format!("IV hex string too long: {}", clean.len()));
        }

        // Left-pad with zeros if fewer than 32 characters
        let mut padded = String::with_capacity(32);
        for _ in 0..(32 - clean.len()) {
            padded.push('0');
        }
        padded.push_str(clean);

        let mut iv = [0u8; 16];
        for i in 0..16 {
            let byte_hex = &padded[i * 2..i * 2 + 2];
            iv[i] = u8::from_str_radix(byte_hex, 16)
                .map_err(|e| format!("Invalid hex byte in IV: {}", e))?;
        }
        Ok(iv)
    }

    /// Derives default HLS IV from sequence number (128-bit big-endian unsigned integer).
    pub fn iv_from_sequence(seq: u64) -> [u8; 16] {
        let mut iv = [0u8; 16];
        let bytes = seq.to_be_bytes();
        // The last 8 bytes store the 64-bit sequence number in big-endian
        iv[8..16].copy_from_slice(&bytes);
        iv
    }

    /// Decrypts an AES-128-CBC encrypted HLS segment in-place or returning a new buffer.
    pub fn decrypt_segment(
        encrypted_data: &[u8],
        key: &[u8; 16],
        iv: &[u8; 16],
    ) -> Result<Vec<u8>, String> {
        if encrypted_data.is_empty() {
            return Ok(Vec::new());
        }
        if encrypted_data.len() % 16 != 0 {
            return Err(format!(
                "Encrypted data length ({}) is not a multiple of 16 bytes",
                encrypted_data.len()
            ));
        }

        let mut buf = encrypted_data.to_vec();
        let decryptor = Aes128CbcDec::new(key.into(), iv.into());

        // Try PKCS7 unpadding first
        match decryptor.decrypt_padded_mut::<Pkcs7>(&mut buf) {
            Ok(unpadded) => Ok(unpadded.to_vec()),
            Err(_) => {
                // If standard unpadding fails (some HLS servers don't pad or pad with zeros),
                // fall back to unpadded block decryption.
                let mut fallback_buf = encrypted_data.to_vec();
                let fallback_dec = Aes128CbcDec::new(key.into(), iv.into());
                for chunk in fallback_buf.chunks_exact_mut(16) {
                    let block = chunk.into();
                    fallback_dec.clone().decrypt_block_mut(block);
                }
                Ok(fallback_buf)
            }
        }
    }
}
