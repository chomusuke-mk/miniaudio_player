//! Real-time decoupled live recording across WAV, RF64, W64, AIFF, CAF, and WavPack containers.
//!
//! Features:
//! - 100% Lock-Free audio callback tapping via wait-free SPSC ring buffer (`rtrb`).
//! - Support for 16-bit PCM and 32-bit IEEE Float across standard and >4 GiB containers plus lossless WavPack (`.wv`).
//! - Automatic container header back-patching with payload and frame counts on completion.

use std::fs::File;
#[cfg(not(target_arch = "wasm32"))]
use std::fs::OpenOptions;
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use crate::sync::lock_unpoisoned;
use crate::sync::thread::{self, JoinHandle};

/// Maximum WAV data chunk payload allowed by 32-bit RIFF (`u32::MAX - 36`).
pub const MAX_RIFF_DATA_BYTES: u64 = (u32::MAX as u64) - 36;

/// Maximum AIFF sound payload allowed by 32-bit IFF (`u32::MAX - 46`).
pub const MAX_AIFF_DATA_BYTES: u64 = (u32::MAX as u64) - 46;

/// Frames per block for streaming lossless WavPack (`.wv`) recording (`wavicle::encode`).
pub const WAVPACK_BLOCK_FRAMES: usize = 32_768;

/// Sony Wave64 top-level `riff` chunk GUID.
const W64_RIFF_GUID: [u8; 16] = [
    0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00, 0x00,
];
/// Sony Wave64 `wave` form-type GUID.
const W64_WAVE_GUID: [u8; 16] = [
    0x77, 0x61, 0x76, 0x65, 0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0x00, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a,
];
/// Sony Wave64 `fmt ` chunk GUID.
const W64_FMT_GUID: [u8; 16] = [
    0x66, 0x6d, 0x74, 0x20, 0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0x00, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a,
];
/// Sony Wave64 `data` chunk GUID.
const W64_DATA_GUID: [u8; 16] = [
    0x64, 0x61, 0x74, 0x61, 0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0x00, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a,
];

/// Decodes a `file://` `uri` into a local OS filesystem path.
///
/// # Errors
///
/// Returns an error string if `uri` is not a local `file://` URI, contains invalid percent-encoding
/// or non-UTF-8 sequences, or resolves to an empty path.
pub fn resolve_file_uri_to_local_path(uri: &str) -> Result<String, String> {
    let rest = uri
        .strip_prefix("file://")
        .or_else(|| uri.strip_prefix("FILE://"))
        .ok_or_else(|| format!("Invalid file:// URI '{}' (code: -2)", uri))?;

    let raw_path = if rest.starts_with('/') {
        rest
    } else if let Some(after_host) = rest.strip_prefix("localhost/") {
        let _ = after_host;
        &rest["localhost".len()..]
    } else if rest.len() >= 2 && rest.as_bytes()[1] == b':' {
        rest
    } else {
        return Err(format!(
            "Unsupported non-local file:// host in recording path '{}' (code: -9)",
            uri
        ));
    };

    let without_qf = raw_path.split(['?', '#']).next().unwrap_or(raw_path);
    let decoded = percent_decode_utf8(without_qf)?;

    #[cfg(windows)]
    let normalized = {
        let b = decoded.as_bytes();
        if b.len() >= 3 && b[0] == b'/' && b[2] == b':' {
            decoded[1..].to_string()
        } else {
            decoded
        }
    };
    #[cfg(not(windows))]
    let normalized = decoded;

    if normalized.trim().is_empty() {
        return Err(format!("Empty local path in file:// URI '{}' (code: -2)", uri));
    }
    Ok(normalized)
}

/// Decodes percent-encoded UTF-8 byte escapes within `input`.
///
/// # Errors
///
/// Returns an error string if `input` contains truncated `%` escapes, invalid hex digits, or non-UTF-8 bytes.
fn percent_decode_utf8(input: &str) -> Result<String, String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err(format!("Invalid percent-encoding in URI '{}' (code: -2)", input));
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3])
                .map_err(|_| format!("Invalid UTF-8 percent-encoding in '{}' (code: -2)", input))?;
            let val = u8::from_str_radix(hex, 16)
                .map_err(|_| format!("Invalid hex escape '%{}' in '{}' (code: -2)", hex, input))?;
            out.push(val);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out)
        .map_err(|_| format!("Non-UTF-8 characters in file:// URI '{}' (code: -2)", input))
}

/// Validates and normalizes `raw` as a filesystem path, `file://` URI, or Web OPFS path for recording.
///
/// # Errors
///
/// Returns an error string if `raw` is empty, uses an unsupported URI scheme, or fails Web OPFS sanitization.
pub fn normalize_recording_path(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Recording path cannot be empty (code: -2)".to_string());
    }

    #[cfg(target_arch = "wasm32")]
    {
        let parsed = crate::opfs::sanitize_opfs_recording_path(trimmed)
            .map_err(|(code, msg)| format!("{} (code: {})", msg, code))?;
        if parsed.had_opfs_prefix {
            crate::map_log!(
                3,
                "[RECORDING] The 'opfs://' prefix in '{}' is unnecessary on Web: relative and \
                 absolute paths resolve automatically to OPFS ('{}')",
                trimmed,
                parsed.canonical
            );
        }
        Ok(parsed.canonical)
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        let lower = trimmed.to_ascii_lowercase();
        if lower.starts_with("file://") {
            return resolve_file_uri_to_local_path(trimmed);
        }
        if crate::opfs::extract_uri_scheme(trimmed)
            .is_some_and(|s| s.eq_ignore_ascii_case("opfs"))
        {
            return Err(format!(
                "URI scheme 'opfs://' ('{}') is only supported on Web (code: -10)",
                raw
            ));
        }

        if let Some(colon_idx) = trimmed.find("://") {
            let scheme = &trimmed[..colon_idx];
            if !scheme.is_empty()
                && scheme
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
            {
                return Err(format!(
                    "Unsupported URI scheme '{}://' for recording path '{}' (code: -9)",
                    scheme, raw
                ));
            }
        }
        if lower.starts_with("package:") {
            return Err(format!(
                "Unsupported URI scheme 'package:' for recording path '{}' (code: -9)",
                raw
            ));
        }

        Ok(raw.to_string())
    }
}

/// Sink trait unifying local OS files, Android FDs, and Web OPFS handles for [`LiveRecorder`].
pub trait RecordingSink: Write + Seek + Send + 'static {
    /// Finalizes and closes the underlying recording sink after container headers are flushed.
    ///
    /// # Errors
    ///
    /// Returns an [`std::io::Error`] if finalizing or closing the sink fails.
    fn finalize_sink(self) -> std::io::Result<()>;
}

impl RecordingSink for File {
    #[inline]
    fn finalize_sink(self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(target_arch = "wasm32")]
impl RecordingSink for crate::opfs::OpfsFileWriter {
    #[inline]
    fn finalize_sink(self) -> std::io::Result<()> {
        self.finish_and_close()
    }
}

/// Maps an OS file open [`std::io::Error`] `err` for `path` into a formatted message with numeric error code.
#[cfg(not(target_arch = "wasm32"))]
fn map_open_io_error(path: &str, err: std::io::Error) -> String {
    let code = match err.kind() {
        std::io::ErrorKind::PermissionDenied => -10,
        std::io::ErrorKind::NotFound => -5,
        std::io::ErrorKind::InvalidInput => -2,
        _ => -1,
    };
    format!(
        "Failed to open recording destination '{}': {} (code: {})",
        path, err, code
    )
}

/// Supported WAV PCM encoding formats for live recording.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WavFormat {
    /// 16-bit signed integer linear PCM.
    #[default]
    Pcm16,
    /// 32-bit floating point linear PCM.
    Float32,
}

impl WavFormat {
    /// Returns the bit depth per sample for this encoding.
    #[inline]
    pub const fn bits_per_sample(self) -> u16 {
        match self {
            WavFormat::Pcm16 => 16,
            WavFormat::Float32 => 32,
        }
    }

    /// Returns the RIFF `wFormatTag` code.
    #[inline]
    pub const fn audio_format_code(self) -> u16 {
        match self {
            WavFormat::Pcm16 => 1,   // WAVE_FORMAT_PCM
            WavFormat::Float32 => 3, // WAVE_FORMAT_IEEE_FLOAT
        }
    }
}

/// Complete set of real-time recording container/sample encodings supported natively
/// across desktop, mobile, and WebAssembly using existing pure-Rust crates.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RecordingEncoding {
    /// Standard 16-bit integer PCM WAV (`RIFF`/`WAVE`).
    #[default]
    WavPcm16 = 0,
    /// Standard 32-bit IEEE float PCM WAV (`RIFF`/`WAVE`).
    WavFloat32 = 1,
    /// 64-bit extended WAV (`RF64` + `ds64`), 16-bit integer PCM (>4 GiB safe).
    Rf64Pcm16 = 2,
    /// 64-bit extended WAV (`RF64` + `ds64`), 32-bit IEEE float PCM (>4 GiB safe).
    Rf64Float32 = 3,
    /// Sony Wave64 (`w64` GUID chunks), 16-bit integer PCM (>4 GiB safe).
    W64Pcm16 = 4,
    /// Sony Wave64 (`w64` GUID chunks), 32-bit IEEE float PCM (>4 GiB safe).
    W64Float32 = 5,
    /// Audio Interchange File Format (`FORM`/`AIFF`), big-endian 16-bit integer PCM.
    AiffPcm16 = 6,
    /// Apple Core Audio Format (`caff`/`lpcm`), big-endian 16-bit integer PCM (>4 GiB safe).
    CafPcm16 = 7,
    /// Apple Core Audio Format (`caff`/`lpcm`), big-endian 32-bit IEEE float PCM (>4 GiB safe).
    CafFloat32 = 8,
    /// Lossless compressed WavPack (`.wv`) 16-bit integer PCM via `wavicle`.
    WavPackPcm16 = 9,
    /// Lossless compressed WavPack (`.wv`) 32-bit IEEE float via `wavicle`.
    WavPackFloat32 = 10,
}

impl From<WavFormat> for RecordingEncoding {
    fn from(fmt: WavFormat) -> Self {
        match fmt {
            WavFormat::Pcm16 => Self::WavPcm16,
            WavFormat::Float32 => Self::WavFloat32,
        }
    }
}

impl RecordingEncoding {
    /// Parses the stable integer wire `code` sent over FFI / FRB into a [`RecordingEncoding`].
    ///
    /// # Errors
    ///
    /// Returns an error string if `code` corresponds to an unsupported or unimplemented encoding.
    pub fn from_wire_code(code: i32) -> Result<Self, String> {
        match code {
            0 => Ok(Self::WavPcm16),
            1 => Ok(Self::WavFloat32),
            2 => Ok(Self::Rf64Pcm16),
            3 => Ok(Self::Rf64Float32),
            4 => Ok(Self::W64Pcm16),
            5 => Ok(Self::W64Float32),
            6 => Ok(Self::AiffPcm16),
            7 => Ok(Self::CafPcm16),
            8 => Ok(Self::CafFloat32),
            9 => Ok(Self::WavPackPcm16),
            10 => Ok(Self::WavPackFloat32),
            -1 => Err(
                "Requested recording format (MP3/FLAC) has no encoder in current dependencies (code: -9)"
                    .to_string(),
            ),
            _ => Err(format!("Unsupported recording format code {} (code: -9)", code)),
        }
    }

    /// Returns `true` when this encoding stores 32-bit IEEE floating-point samples.
    #[inline]
    pub const fn is_float(self) -> bool {
        matches!(
            self,
            Self::WavFloat32
                | Self::Rf64Float32
                | Self::W64Float32
                | Self::CafFloat32
                | Self::WavPackFloat32
        )
    }

    /// Returns `true` when this container stores multi-byte PCM samples in big-endian byte order.
    #[inline]
    pub const fn is_big_endian(self) -> bool {
        matches!(self, Self::AiffPcm16 | Self::CafPcm16 | Self::CafFloat32)
    }

    /// Returns `true` when this encoding produces a streaming WavPack (`.wv`) bitstream.
    #[inline]
    pub const fn is_wavpack(self) -> bool {
        matches!(self, Self::WavPackPcm16 | Self::WavPackFloat32)
    }

    /// Maps this encoding's sample representation to [`WavFormat`].
    #[inline]
    pub const fn wav_sample_format(self) -> WavFormat {
        if self.is_float() {
            WavFormat::Float32
        } else {
            WavFormat::Pcm16
        }
    }

    /// Returns the bit depth per sample (`16` or `32`) for this encoding.
    #[inline]
    pub const fn bits_per_sample(self) -> u16 {
        if self.is_float() { 32 } else { 16 }
    }

    /// Returns the 32-bit container payload byte limit, or `None` for >4 GiB capable formats.
    #[inline]
    pub const fn max_payload_bytes(self) -> Option<u64> {
        match self {
            Self::WavPcm16 | Self::WavFloat32 => Some(MAX_RIFF_DATA_BYTES),
            Self::AiffPcm16 => Some(MAX_AIFF_DATA_BYTES),
            _ => None,
        }
    }
}

/// Converts a normalized floating-point `sample` in `[-1.0, 1.0]` to a clamped `i16`.
#[inline]
fn f32_to_i16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32767.0).round() as i16
}

/// Encodes `sample_rate` as an unsigned 80-bit IEEE 754 extended precision float (big-endian).
fn encode_aiff_extended_f80(sample_rate: u32) -> [u8; 10] {
    if sample_rate == 0 {
        return [0u8; 10];
    }
    let shift = sample_rate.leading_zeros();
    let exp = (16383 + 31 - shift) as u16;
    let mantissa = (sample_rate as u64) << (shift + 32);
    let mut out = [0u8; 10];
    out[0..2].copy_from_slice(&exp.to_be_bytes());
    out[2..10].copy_from_slice(&mantissa.to_be_bytes());
    out
}

/// Appends a little-endian 16-byte WAVE `fmt ` chunk body to `out` for sample rate `sr`, channel count `ch`, and `wav_fmt`.
fn push_wave_fmt_body_le(out: &mut Vec<u8>, sr: u32, ch: u16, wav_fmt: WavFormat) {
    let bps = wav_fmt.bits_per_sample();
    let block_align = ch * (bps / 8);
    let byte_rate = sr * block_align as u32;
    out.extend_from_slice(&wav_fmt.audio_format_code().to_le_bytes());
    out.extend_from_slice(&ch.to_le_bytes());
    out.extend_from_slice(&sr.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&bps.to_le_bytes());
}

/// Builds a complete container header for `enc`, `sample_rate`, and `channels` with `data_bytes` and `total_frames` populated.
pub fn build_container_header(
    enc: RecordingEncoding,
    sample_rate: u32,
    channels: u16,
    data_bytes: u64,
    total_frames: u64,
) -> Vec<u8> {
    let ch = channels.max(1);
    let sr = sample_rate.max(8000);
    let wav_fmt = enc.wav_sample_format();
    let mut out = Vec::with_capacity(104);

    match enc {
        RecordingEncoding::WavPcm16 | RecordingEncoding::WavFloat32 => {
            let clamped = data_bytes.min(MAX_RIFF_DATA_BYTES) as u32;
            out.extend_from_slice(b"RIFF");
            out.extend_from_slice(&(if data_bytes == 0 { 0u32 } else { clamped + 36 }).to_le_bytes());
            out.extend_from_slice(b"WAVEfmt ");
            out.extend_from_slice(&16u32.to_le_bytes());
            push_wave_fmt_body_le(&mut out, sr, ch, wav_fmt);
            out.extend_from_slice(b"data");
            out.extend_from_slice(&clamped.to_le_bytes());
        }
        RecordingEncoding::Rf64Pcm16 | RecordingEncoding::Rf64Float32 => {
            let riff32 = if data_bytes == 0 {
                0u32
            } else {
                u32::try_from(data_bytes + 72).unwrap_or(u32::MAX)
            };
            let data32 = u32::try_from(data_bytes).unwrap_or(u32::MAX);
            out.extend_from_slice(b"RF64");
            out.extend_from_slice(&riff32.to_le_bytes());
            out.extend_from_slice(b"WAVE");
            out.extend_from_slice(b"ds64");
            out.extend_from_slice(&28u32.to_le_bytes());
            out.extend_from_slice(&(data_bytes + 72).to_le_bytes());
            out.extend_from_slice(&data_bytes.to_le_bytes());
            out.extend_from_slice(&total_frames.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(b"fmt ");
            out.extend_from_slice(&16u32.to_le_bytes());
            push_wave_fmt_body_le(&mut out, sr, ch, wav_fmt);
            out.extend_from_slice(b"data");
            out.extend_from_slice(&data32.to_le_bytes());
        }
        RecordingEncoding::W64Pcm16 | RecordingEncoding::W64Float32 => {
            out.extend_from_slice(&W64_RIFF_GUID);
            out.extend_from_slice(&(data_bytes + 104).to_le_bytes());
            out.extend_from_slice(&W64_WAVE_GUID);
            out.extend_from_slice(&W64_FMT_GUID);
            out.extend_from_slice(&40u64.to_le_bytes());
            push_wave_fmt_body_le(&mut out, sr, ch, wav_fmt);
            out.extend_from_slice(&W64_DATA_GUID);
            out.extend_from_slice(&(data_bytes + 24).to_le_bytes());
        }
        RecordingEncoding::AiffPcm16 => {
            let clamped = data_bytes.min(MAX_AIFF_DATA_BYTES) as u32;
            let padded = clamped + (clamped & 1);
            let frames32 = total_frames.min(u32::MAX as u64) as u32;
            out.extend_from_slice(b"FORM");
            out.extend_from_slice(&(if data_bytes == 0 { 0u32 } else { padded + 46 }).to_be_bytes());
            out.extend_from_slice(b"AIFFCOMM");
            out.extend_from_slice(&18u32.to_be_bytes());
            out.extend_from_slice(&ch.to_be_bytes());
            out.extend_from_slice(&frames32.to_be_bytes());
            out.extend_from_slice(&16u16.to_be_bytes());
            out.extend_from_slice(&encode_aiff_extended_f80(sr));
            out.extend_from_slice(b"SSND");
            out.extend_from_slice(&(clamped + 8).to_be_bytes());
            out.extend_from_slice(&0u32.to_be_bytes());
            out.extend_from_slice(&0u32.to_be_bytes());
        }
        RecordingEncoding::CafPcm16 | RecordingEncoding::CafFloat32 => {
            let bps = enc.bits_per_sample() as u32;
            let bytes_per_packet = (ch as u32) * (bps / 8);
            let flags: u32 = if enc.is_float() { 1 } else { 0 };
            let data_chunk_size = (data_bytes as i64).saturating_add(4);
            out.extend_from_slice(b"caff");
            out.extend_from_slice(&1u16.to_be_bytes());
            out.extend_from_slice(&0u16.to_be_bytes());
            out.extend_from_slice(b"desc");
            out.extend_from_slice(&32i64.to_be_bytes());
            out.extend_from_slice(&(sr as f64).to_be_bytes());
            out.extend_from_slice(b"lpcm");
            out.extend_from_slice(&flags.to_be_bytes());
            out.extend_from_slice(&bytes_per_packet.to_be_bytes());
            out.extend_from_slice(&1u32.to_be_bytes());
            out.extend_from_slice(&(ch as u32).to_be_bytes());
            out.extend_from_slice(&bps.to_be_bytes());
            out.extend_from_slice(b"data");
            out.extend_from_slice(&data_chunk_size.to_be_bytes());
            out.extend_from_slice(&0u32.to_be_bytes()); // edit_count
        }
        RecordingEncoding::WavPackPcm16 | RecordingEncoding::WavPackFloat32 => {
            // 4-byte startup seek probe; overwritten when block 0 is written.
            out.extend_from_slice(b"wvpk");
        }
    }
    out
}

/// Encodes one self-contained lossless WavPack block (`<= WAVPACK_BLOCK_FRAMES` frames)
/// at `sample_rate` and `channels` (16-bit integer or 32-bit float when `is_float` is true)
/// from interleaved `pcm_f32` samples, stamping streaming `block_index`.
///
/// # Errors
///
/// Returns an error string if `channels` is not `1` or `2`, or if `wavicle` encoding fails.
pub fn encode_wavpack_block_f32(
    sample_rate: u32,
    channels: u16,
    is_float: bool,
    block_index: u64,
    pcm_f32: &[f32],
) -> Result<Vec<u8>, String> {
    if channels != 1 && channels != 2 {
        return Err(format!(
            "WavPack encoder supports 1 or 2 channels (got {}) (code: -9)",
            channels
        ));
    }
    if pcm_f32.is_empty() {
        return Ok(Vec::new());
    }
    let mut block = if is_float {
        wavicle::encode::encode_float(channels as u32, sample_rate, pcm_f32)
            .map_err(|e| format!("WavPack float encode error: {} (code: -1)", e))?
    } else {
        let pcm_i32: Vec<i32> = pcm_f32.iter().map(|&s| f32_to_i16(s) as i32).collect();
        wavicle::encode::encode_int(
            wavicle::encode::EncodeParams {
                channels: channels as u32,
                sample_rate,
                bits_per_sample: 16,
            },
            &pcm_i32,
        )
        .map_err(|e| format!("WavPack int16 encode error: {} (code: -1)", e))?
    };

    patch_wavpack_block_header(&mut block, block_index);
    Ok(block)
}

/// Encodes one WavPack block at `sample_rate` and `channels` (`is_float` selects `f32`-LE vs `i16`-LE)
/// directly from interleaved little-endian wire `pcm_bytes`, stamping `block_index`.
///
/// # Errors
///
/// Returns an error string if `channels` is not `1` or `2`, `pcm_bytes` is unaligned to frame size,
/// or `wavicle` encoding fails.
pub fn encode_wavpack_block_wire_bytes(
    sample_rate: u32,
    channels: u16,
    is_float: bool,
    block_index: u64,
    pcm_bytes: &[u8],
) -> Result<Vec<u8>, String> {
    if channels != 1 && channels != 2 {
        return Err(format!(
            "WavPack encoder supports 1 or 2 channels (got {}) (code: -9)",
            channels
        ));
    }
    if pcm_bytes.is_empty() {
        return Ok(Vec::new());
    }
    let mut block = if is_float {
        if !pcm_bytes.len().is_multiple_of(4 * channels as usize) {
            return Err("Unaligned Float32 WavPack block buffer (code: -2)".to_string());
        }
        let samples: Vec<f32> = pcm_bytes
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();
        wavicle::encode::encode_float(channels as u32, sample_rate, &samples)
            .map_err(|e| format!("WavPack float encode error: {} (code: -1)", e))?
    } else {
        if !pcm_bytes.len().is_multiple_of(2 * channels as usize) {
            return Err("Unaligned PCM16 WavPack block buffer (code: -2)".to_string());
        }
        let samples: Vec<i32> = pcm_bytes
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]) as i32)
            .collect();
        wavicle::encode::encode_int(
            wavicle::encode::EncodeParams {
                channels: channels as u32,
                sample_rate,
                bits_per_sample: 16,
            },
            &samples,
        )
        .map_err(|e| format!("WavPack int16 encode error: {} (code: -1)", e))?
    };

    patch_wavpack_block_header(&mut block, block_index);
    Ok(block)
}

/// Patches the WavPack `block` header's streaming `block_index` and unknown-total-samples sentinel.
fn patch_wavpack_block_header(block: &mut [u8], block_index: u64) {
    if block.len() >= 32 {
        block[10] = (block_index >> 32) as u8;
        block[11] = 0u8;
        block[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
        block[16..20].copy_from_slice(&(block_index as u32).to_le_bytes());
    }
}

/// Streaming audio sample encoder supporting WAV, RF64, W64, AIFF, CAF, and lossless WavPack.
pub struct AudioStreamWriter<W: Write + Seek> {
    /// Destination seekable byte writer.
    writer: W,
    /// Target container and sample encoding format.
    encoding: RecordingEncoding,
    /// Sample rate in Hertz.
    sample_rate: u32,
    /// Interleaved channel count.
    channels: usize,
    /// Total encoded audio payload bytes written so far.
    data_bytes: u64,
    /// Total encoded audio frames written so far.
    total_frames: u64,
    /// Reusable byte encoding buffer for non-WavPack formats.
    scratch_bytes: Vec<u8>,
    /// Interleaved `f32` accumulation buffer for block-based WavPack encoding.
    wv_accum: Vec<f32>,
    /// Whether the first WavPack block has overwritten the startup seek probe.
    wv_block0_written: bool,
}

impl<W: Write + Seek> AudioStreamWriter<W> {
    /// Writes the initial container header or seek probe to `writer` and prepares buffered encoding
    /// at `sample_rate`, `channels`, and `encoding`.
    ///
    /// # Errors
    ///
    /// Returns an [`std::io::Error`] if `encoding` is WavPack with unsupported channel count or if
    /// writing/seeking the initial header fails.
    pub fn new(
        mut writer: W,
        sample_rate: u32,
        channels: u16,
        encoding: RecordingEncoding,
    ) -> std::io::Result<Self> {
        let ch = channels.max(1) as usize;
        if encoding.is_wavpack() && ch != 1 && ch != 2 {
            crate::map_log!(
                1,
                "[RECORDING] AudioStreamWriter rejected WavPack channel count={}",
                ch
            );
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("WavPack supports 1 or 2 channels (got {})", ch),
            ));
        }
        let header = build_container_header(encoding, sample_rate, ch as u16, 0, 0);
        writer.write_all(&header)?;
        writer.flush()?;
        if encoding.is_wavpack() {
            writer.seek(SeekFrom::Start(0))?;
        }
        Ok(Self {
            writer,
            encoding,
            sample_rate,
            channels: ch,
            data_bytes: 0,
            total_frames: 0,
            scratch_bytes: Vec::with_capacity(8192),
            wv_accum: if encoding.is_wavpack() {
                Vec::with_capacity(WAVPACK_BLOCK_FRAMES * ch)
            } else {
                Vec::new()
            },
            wv_block0_written: false,
        })
    }

    /// Encodes and writes `sample_count` interleaved samples from `wv_accum` as a WavPack block.
    ///
    /// # Errors
    ///
    /// Returns an [`std::io::Error`] if block encoding, seeking, or writing fails.
    fn flush_wavpack_block(&mut self, sample_count: usize) -> std::io::Result<()> {
        if sample_count == 0 {
            return Ok(());
        }
        let block = encode_wavpack_block_f32(
            self.sample_rate,
            self.channels as u16,
            self.encoding.is_float(),
            self.total_frames,
            &self.wv_accum[..sample_count],
        )
        .map_err(std::io::Error::other)?;
        if !self.wv_block0_written {
            self.writer.seek(SeekFrom::Start(0))?;
            self.wv_block0_written = true;
        }
        self.writer.write_all(&block)?;
        self.data_bytes = self.data_bytes.saturating_add(block.len() as u64);
        self.total_frames = self
            .total_frames
            .saturating_add((sample_count / self.channels) as u64);
        self.wv_accum.drain(..sample_count);
        Ok(())
    }

    /// Encodes a slice of interleaved `f32` `samples` (frame-aligned) to the active container.
    ///
    /// # Errors
    ///
    /// Returns an [`std::io::Error`] if a 32-bit container exceeds its 4 GiB payload limit or if writing fails.
    pub fn write_samples(&mut self, samples: &[f32]) -> std::io::Result<()> {
        if samples.is_empty() {
            return Ok(());
        }
        if self.encoding.is_wavpack() {
            let block_samples = WAVPACK_BLOCK_FRAMES * self.channels;
            self.wv_accum.extend_from_slice(samples);
            while self.wv_accum.len() >= block_samples {
                self.flush_wavpack_block(block_samples)?;
            }
            return Ok(());
        }

        let bps_bytes = (self.encoding.bits_per_sample() / 8) as u64;
        let add_bytes = (samples.len() as u64).saturating_mul(bps_bytes);
        if let Some(limit) = self.encoding.max_payload_bytes() {
            if self.data_bytes.saturating_add(add_bytes) > limit {
                crate::map_log!(
                    1,
                    "[RECORDING] 4 GiB payload limit reached for {:?} (written={} add={})",
                    self.encoding,
                    self.data_bytes,
                    add_bytes
                );
                return Err(std::io::Error::other(
                    "Container 4 GiB maximum file size limit reached; use RF64, W64, CAF, or WavPack for >4 GiB recordings (code: -1)",
                ));
            }
        }

        self.scratch_bytes.clear();
        self.scratch_bytes.reserve(add_bytes as usize);
        match (self.encoding.is_float(), self.encoding.is_big_endian()) {
            (false, false) => {
                for &s in samples {
                    self.scratch_bytes.extend_from_slice(&f32_to_i16(s).to_le_bytes());
                }
            }
            (false, true) => {
                for &s in samples {
                    self.scratch_bytes.extend_from_slice(&f32_to_i16(s).to_be_bytes());
                }
            }
            (true, false) => {
                for &s in samples {
                    self.scratch_bytes.extend_from_slice(&s.to_le_bytes());
                }
            }
            (true, true) => {
                for &s in samples {
                    self.scratch_bytes.extend_from_slice(&s.to_be_bytes());
                }
            }
        }

        self.writer.write_all(&self.scratch_bytes)?;
        self.data_bytes = self.data_bytes.saturating_add(add_bytes);
        self.total_frames = self
            .total_frames
            .saturating_add((samples.len() / self.channels) as u64);
        Ok(())
    }

    /// Drains all currently available frame-aligned samples from `consumer` and writes them.
    ///
    /// Returns `Ok(true)` if samples were consumed, or `Ok(false)` if fewer than one full frame was available.
    ///
    /// # Errors
    ///
    /// Returns an [`std::io::Error`] if encoding or writing the drained samples fails.
    pub fn drain_consumer_checked(
        &mut self,
        consumer: &mut rtrb::Consumer<f32>,
    ) -> std::io::Result<bool> {
        let ch = self.channels.max(1);
        let avail = (consumer.slots() / ch) * ch;
        if avail == 0 {
            return Ok(false);
        }
        let Ok(chunk) = consumer.read_chunk(avail) else {
            return Ok(false);
        };
        let (s1, s2) = chunk.as_slices();
        let res = if let Err(e) = self.write_samples(s1) {
            Err(e)
        } else {
            self.write_samples(s2)
        };
        chunk.commit_all();
        res?;
        Ok(true)
    }

    /// Finalizes streaming blocks and container headers, flushes output, and returns `(writer, bytes_written)`.
    ///
    /// # Errors
    ///
    /// Returns an [`std::io::Error`] if flushing trailing blocks, seeking, patching headers, or flushing fails.
    pub fn finish(mut self) -> std::io::Result<(W, u64)> {
        if self.encoding.is_wavpack() {
            let block_samples = WAVPACK_BLOCK_FRAMES * self.channels;
            while self.wv_accum.len() >= block_samples {
                self.flush_wavpack_block(block_samples)?;
            }
            if !self.wv_accum.is_empty() {
                let aligned = (self.wv_accum.len() / self.channels) * self.channels;
                self.flush_wavpack_block(aligned)?;
            }
            let reported_bytes = self.data_bytes;
            if !self.wv_block0_written {
                // Ensure zero-frame recordings still produce a valid decodable 1-frame WavPack file.
                self.wv_accum.resize(self.channels, 0.0);
                self.flush_wavpack_block(self.channels)?;
            }
            let mut total_patch = [0u8; 5];
            total_patch[0] = (self.total_frames >> 32) as u8;
            total_patch[1..5].copy_from_slice(&(self.total_frames as u32).to_le_bytes());
            self.writer.seek(SeekFrom::Start(11))?;
            self.writer.write_all(&total_patch)?;
            self.writer.flush()?;
            return Ok((self.writer, reported_bytes));
        }

        if self.encoding == RecordingEncoding::AiffPcm16 && (self.data_bytes & 1) == 1 {
            self.writer.write_all(&[0u8])?;
        }
        let final_header = build_container_header(
            self.encoding,
            self.sample_rate,
            self.channels as u16,
            self.data_bytes,
            self.total_frames,
        );
        self.writer.seek(SeekFrom::Start(0))?;
        self.writer.write_all(&final_header)?;
        self.writer.flush()?;
        Ok((self.writer, self.data_bytes))
    }
}

/// Real-time live audio recording manager running on a dedicated disk writer thread.
pub struct LiveRecorder {
    /// Atomic flag indicating whether the background writer loop is currently active.
    is_recording: Arc<AtomicBool>,
    /// Atomic stop signal set by [`LiveRecorder::stop`] or [`Drop`] to terminate the writer thread.
    stop_signal: Arc<AtomicBool>,
    /// Atomic flag indicating an asynchronous write or finalization error occurred.
    has_error: Arc<AtomicBool>,
    /// Last asynchronous error message produced on the background writer thread.
    async_error: Arc<Mutex<Option<String>>>,
    /// Join handle for the active background disk writer thread.
    writer_thread: Option<JoinHandle<Result<u64, String>>>,
    /// Target sample rate in Hertz.
    sample_rate: u32,
    /// Interleaved channel count.
    channels: usize,
    /// Target container and sample encoding format.
    encoding: RecordingEncoding,
}

impl Drop for LiveRecorder {
    fn drop(&mut self) {
        if self.writer_thread.is_some() {
            crate::map_log!(
                3,
                "[RECORDING] LiveRecorder dropped while active; finalizing recording"
            );
            let _ = self.stop();
        }
    }
}

impl LiveRecorder {
    /// Creates a new [`LiveRecorder`] configured with `sample_rate`, `channels`, and `format`.
    pub fn new(sample_rate: u32, channels: usize, format: impl Into<RecordingEncoding>) -> Self {
        Self {
            is_recording: Arc::new(AtomicBool::new(false)),
            stop_signal: Arc::new(AtomicBool::new(false)),
            has_error: Arc::new(AtomicBool::new(false)),
            async_error: Arc::new(Mutex::new(None)),
            writer_thread: None,
            sample_rate: sample_rate.max(8000),
            channels: channels.max(1),
            encoding: format.into(),
        }
    }

    /// Returns whether a background disk recording session is active.
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Acquire)
    }

    /// Wait-free poll for any asynchronous background disk or finalization error during recording.
    #[inline]
    pub fn poll_async_error(&self) -> Option<String> {
        if !self.has_error.load(Ordering::Acquire) {
            return None;
        }
        lock_unpoisoned(&self.async_error).clone()
    }

    /// Normalizes `raw_path` and opens/truncates a local [`File`] ready for recording.
    ///
    /// # Errors
    ///
    /// Returns a formatted error string if path normalization or file creation fails.
    #[cfg(not(target_arch = "wasm32"))]
    fn open_recording_file(raw_path: &str) -> Result<File, String> {
        let local_path = normalize_recording_path(raw_path)?;
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&local_path)
            .map_err(|e| map_open_io_error(&local_path, e))
    }

    /// Opens the destination at `path` (or OPFS handle on Web), allocates the SPSC ring buffer
    /// for `sample_rate`, `channels`, and `format`, and spawns the background disk writer thread
    /// outside any real-time critical section.
    ///
    /// # Errors
    ///
    /// Returns an error string if opening `path`, writing the initial header, or spawning the thread fails.
    pub fn prepare_start(
        sample_rate: u32,
        channels: usize,
        format: impl Into<RecordingEncoding>,
        path: &str,
    ) -> Result<(Self, rtrb::Producer<f32>), String> {
        #[cfg(target_arch = "wasm32")]
        {
            let canonical = normalize_recording_path(path)?;
            Self::prepare_start_opfs(sample_rate, channels, format, &canonical)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let sr = sample_rate.max(8000);
            let ch = channels.max(1);
            let (prod, cons) = rtrb::RingBuffer::new(sr as usize * ch * 4);
            let mut rec = Self::new(sr, ch, format);
            rec.start(path, cons)?;
            Ok((rec, prod))
        }
    }

    /// Opens a writable Web OPFS handle at `canonical_opfs_path`, writes the initial header for
    /// `sample_rate`, `channels`, and `format`, and spawns the background writer thread.
    ///
    /// # Errors
    ///
    /// Returns an error string if OPFS file creation, header initialization, or thread spawn fails.
    #[cfg(target_arch = "wasm32")]
    pub fn prepare_start_opfs(
        sample_rate: u32,
        channels: usize,
        format: impl Into<RecordingEncoding>,
        canonical_opfs_path: &str,
    ) -> Result<(Self, rtrb::Producer<f32>), String> {
        let enc = format.into();
        crate::map_log!(
            3,
            "[RECORDING] Starting OPFS recording path='{}' sr={} ch={} enc={:?}",
            canonical_opfs_path,
            sample_rate,
            channels,
            enc
        );
        let writer = crate::opfs::OpfsFileWriter::open(canonical_opfs_path).map_err(|e| {
            crate::map_log!(
                1,
                "[RECORDING] Failed to open OPFS recording handle '{}': {}",
                canonical_opfs_path,
                e
            );
            e
        })?;
        let sr = sample_rate.max(8000);
        let ch = channels.max(1);
        let (prod, cons) = rtrb::RingBuffer::new(sr as usize * ch * 4);
        let mut rec = Self::new(sr, ch, enc);
        rec.start_with_writer(writer, cons)?;
        Ok((rec, prod))
    }

    /// Validates a caller-supplied POSIX `raw_fd` (`content://` SAF / MediaStore on Android),
    /// writes the initial container header for `sample_rate`, `channels`, and `format`, and spawns
    /// the background disk writer thread.
    ///
    /// # Errors
    ///
    /// Returns an error string if `raw_fd` is negative, non-seekable, or fails initialization.
    #[cfg(unix)]
    pub fn prepare_start_fd(
        sample_rate: u32,
        channels: usize,
        format: impl Into<RecordingEncoding>,
        raw_fd: std::os::unix::io::RawFd,
    ) -> Result<(Self, rtrb::Producer<f32>), String> {
        use std::os::unix::io::FromRawFd;
        if raw_fd < 0 {
            crate::map_log!(1, "[RECORDING] Rejected negative recording fd={}", raw_fd);
            return Err("Invalid native file descriptor for recording (code: -2)".to_string());
        }
        let enc = format.into();
        crate::map_log!(
            3,
            "[RECORDING] Starting FD recording fd={} sr={} ch={} enc={:?}",
            raw_fd,
            sample_rate,
            channels,
            enc
        );
        // Take ownership immediately so any subsequent error closes `raw_fd` cleanly (RAII).
        let mut file = unsafe { File::from_raw_fd(raw_fd) };
        file.seek(SeekFrom::Start(0)).map_err(|e| {
            let msg = format!(
                "Recording descriptor must support seeking to finalize header: {} (code: -9)",
                e
            );
            crate::map_log!(1, "[RECORDING] {}", msg);
            msg
        })?;
        let _ = file.set_len(0);
        file.seek(SeekFrom::Start(0)).map_err(|e| {
            let msg = format!(
                "Failed to rewind recording descriptor after truncation: {} (code: -1)",
                e
            );
            crate::map_log!(1, "[RECORDING] {}", msg);
            msg
        })?;

        let sr = sample_rate.max(8000);
        let ch = channels.max(1);
        let (prod, cons) = rtrb::RingBuffer::new(sr as usize * ch * 4);
        let mut rec = Self::new(sr, ch, enc);
        rec.start_with_writer(file, cons)?;
        Ok((rec, prod))
    }

    /// Starts writing audio to `path` using the `consumer` end of an SPSC ring buffer.
    ///
    /// # Errors
    ///
    /// Returns an error string if a session is already active or opening `path` fails.
    pub fn start(&mut self, path: &str, consumer: rtrb::Consumer<f32>) -> Result<(), String> {
        if self.is_recording() || self.writer_thread.is_some() {
            crate::map_log!(2, "[RECORDING] start() called while recording is already active");
            return Err("Recording session is already active (code: -6)".to_string());
        }
        crate::map_log!(
            3,
            "[RECORDING] Starting recording path='{}' sr={} ch={} enc={:?}",
            path,
            self.sample_rate,
            self.channels,
            self.encoding
        );
        #[cfg(target_arch = "wasm32")]
        {
            let canonical = normalize_recording_path(path)?;
            let writer = crate::opfs::OpfsFileWriter::open(&canonical).map_err(|e| {
                crate::map_log!(
                    1,
                    "[RECORDING] Failed to open OPFS recording handle '{}': {}",
                    canonical,
                    e
                );
                e
            })?;
            self.start_with_writer(writer, consumer)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let file = Self::open_recording_file(path).map_err(|e| {
                crate::map_log!(1, "[RECORDING] {}", e);
                e
            })?;
            self.start_with_writer(file, consumer)
        }
    }

    /// Initializes the container header on `writer_sink` and spawns the background disk writer
    /// thread draining `consumer`.
    ///
    /// # Errors
    ///
    /// Returns an error string if already active, container initialization fails, or thread spawn fails.
    fn start_with_writer<W: RecordingSink>(
        &mut self,
        writer_sink: W,
        mut consumer: rtrb::Consumer<f32>,
    ) -> Result<(), String> {
        if self.is_recording() || self.writer_thread.is_some() {
            crate::map_log!(
                2,
                "[RECORDING] start_with_writer() called while recording is already active"
            );
            return Err("Recording session is already active (code: -6)".to_string());
        }

        let sr = self.sample_rate;
        let ch = self.channels as u16;
        let enc = self.encoding;

        let buf_writer = BufWriter::with_capacity(65536, writer_sink);
        let mut stream_writer = AudioStreamWriter::new(buf_writer, sr, ch, enc).map_err(|e| {
            let msg = format!("Failed to initialize recording container: {} (code: -1)", e);
            crate::map_log!(1, "[RECORDING] {}", msg);
            msg
        })?;

        self.stop_signal.store(false, Ordering::Release);
        self.has_error.store(false, Ordering::Release);
        *lock_unpoisoned(&self.async_error) = None;
        self.is_recording.store(true, Ordering::Release);

        let is_rec = self.is_recording.clone();
        let stop_sig = self.stop_signal.clone();
        let has_err = self.has_error.clone();
        let err_slot = self.async_error.clone();

        let handle = thread::Builder::new()
            .name("miniaudio-rec-writer".to_string())
            .spawn(move || {
                crate::map_log!(
                    4,
                    "[RECORDING] Writer thread started (sr={} ch={} enc={:?})",
                    sr,
                    ch,
                    enc
                );
                let mut write_failure: Option<String> = None;

                while !stop_sig.load(Ordering::Acquire) || consumer.slots() > 0 {
                    match stream_writer.drain_consumer_checked(&mut consumer) {
                        Ok(true) => {}
                        Ok(false) => thread::sleep(std::time::Duration::from_millis(10)),
                        Err(e) => {
                            let msg = format!("Recording write failed: {} (code: -1)", e);
                            crate::map_log!(1, "[RECORDING] {}", msg);
                            *lock_unpoisoned(&err_slot) = Some(msg.clone());
                            has_err.store(true, Ordering::Release);
                            write_failure = Some(msg);
                            break;
                        }
                    }
                }

                let finalize_res = stream_writer
                    .finish()
                    .and_then(|(buf_w, total)| {
                        let sink = buf_w.into_inner().map_err(|e| e.into_error())?;
                        sink.finalize_sink()?;
                        Ok(total)
                    })
                    .map_err(|e| format!("Failed to finalize recording container: {} (code: -1)", e));

                is_rec.store(false, Ordering::Release);

                if let Some(err_msg) = write_failure {
                    return Err(err_msg);
                }
                match finalize_res {
                    Ok(bytes) => {
                        crate::map_log!(
                            3,
                            "[RECORDING] Writer thread finalized successfully (payload_bytes={})",
                            bytes
                        );
                        Ok(bytes)
                    }
                    Err(e) => {
                        crate::map_log!(1, "[RECORDING] {}", e);
                        *lock_unpoisoned(&err_slot) = Some(e.clone());
                        has_err.store(true, Ordering::Release);
                        Err(e)
                    }
                }
            })
            .map_err(|e| {
                self.is_recording.store(false, Ordering::Release);
                let msg = format!("Failed to spawn disk writer thread: {} (code: -1)", e);
                crate::map_log!(1, "[RECORDING] {}", msg);
                msg
            })?;

        self.writer_thread = Some(handle);
        Ok(())
    }

    /// Stops the live recording session, flushes all remaining samples, updates the container header,
    /// and returns total payload bytes written.
    ///
    /// # Errors
    ///
    /// Returns an error string if no session is active, the writer thread panicked, or writing/finalizing failed.
    pub fn stop(&mut self) -> Result<u64, String> {
        if !self.is_recording() && self.writer_thread.is_none() {
            crate::map_log!(2, "[RECORDING] stop() called with no active recording session");
            return Err("No active recording session to stop (code: -6)".to_string());
        }

        crate::map_log!(3, "[RECORDING] Stopping live recording session");
        self.stop_signal.store(true, Ordering::Release);

        if let Some(handle) = self.writer_thread.take() {
            match handle.join() {
                Ok(res) => {
                    if let Ok(bytes) = &res {
                        crate::map_log!(
                            3,
                            "[RECORDING] Recording stopped cleanly (payload_bytes={})",
                            bytes
                        );
                    }
                    res
                }
                Err(_) => {
                    crate::map_log!(1, "[RECORDING] Disk writer thread panicked during stop()");
                    Err("Disk writer thread panicked (code: -1)".to_string())
                }
            }
        } else if let Some(err) = self.poll_async_error() {
            crate::map_log!(2, "[RECORDING] stop() returning async error: {}", err);
            Err(err)
        } else {
            Ok(0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_file_uris_and_rejects_invalid_schemes() {
        assert_eq!(
            normalize_recording_path("file:///tmp/my%20mix.wav").unwrap(),
            if cfg!(windows) { "/tmp/my mix.wav" } else { "/tmp/my mix.wav" }
        );
        assert_eq!(
            normalize_recording_path("file://localhost/tmp/test.wav").unwrap(),
            "/tmp/test.wav"
        );
        assert!(normalize_recording_path("").is_err());
        assert!(normalize_recording_path("   ").is_err());
        assert!(normalize_recording_path("https://example.com/out.wav").is_err());
        assert!(normalize_recording_path("asset://audio/a.wav").is_err());
        assert!(normalize_recording_path("package:app/a.wav").is_err());
        assert!(normalize_recording_path("content://media/external/1").is_err());
    }

    #[test]
    fn wav_writer_float32_header_and_riff_limit_guard() {
        let mut cursor = std::io::Cursor::new(Vec::<u8>::new());
        let mut writer =
            AudioStreamWriter::new(&mut cursor, 48_000, 2, RecordingEncoding::WavFloat32).unwrap();
        writer.write_samples(&[0.5, -0.5]).unwrap();
        writer.data_bytes = MAX_RIFF_DATA_BYTES - 2;
        assert!(writer.write_samples(&[0.25, -0.25]).is_err());

        let (done_cursor, _) = writer.finish().unwrap();
        let bytes = done_cursor.get_ref();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(u16::from_le_bytes(bytes[20..22].try_into().unwrap()), 3); // IEEE float
        assert_eq!(u16::from_le_bytes(bytes[34..36].try_into().unwrap()), 32); // bits/sample
    }

    #[test]
    fn drop_finalizes_wav_header_even_without_explicit_stop() {
        let path = std::env::temp_dir().join(format!(
            "miniaudio_drop_finalize_{}.wav",
            std::process::id()
        ));
        let path_str = path.to_string_lossy().into_owned();
        let _ = std::fs::remove_file(&path);

        let (mut prod, cons) = rtrb::RingBuffer::new(1024);
        {
            let mut rec = LiveRecorder::new(48_000, 2, WavFormat::Float32);
            rec.start(&path_str, cons).unwrap();
            let samples = [0.25f32, -0.25f32, 0.5f32, -0.5f32];
            if let Ok(mut chunk) = prod.write_chunk(samples.len()) {
                chunk.as_mut_slices().0.copy_from_slice(&samples);
                chunk.commit_all();
            }
            std::thread::sleep(std::time::Duration::from_millis(30));
            drop(prod);
            // `rec` dropped here without calling stop() -> Drop must finalize RIFF header!
        }

        let bytes = std::fs::read(&path).expect("output wav exists");
        assert_eq!(bytes.len(), 44 + 16);
        let riff_size = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
        let data_size = u32::from_le_bytes(bytes[40..44].try_into().unwrap());
        assert_eq!(data_size, 16);
        assert_eq!(riff_size, 16 + 36);
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(unix)]
    #[test]
    fn prepare_start_fd_writes_valid_wav_on_seekable_file() {
        use std::os::unix::io::IntoRawFd;
        let path = std::env::temp_dir().join(format!(
            "miniaudio_fd_rec_{}.wav",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .unwrap();
        let raw_fd = file.into_raw_fd();

        let (mut rec, mut prod) =
            LiveRecorder::prepare_start_fd(48_000, 2, WavFormat::Pcm16, raw_fd).unwrap();
        let samples = [0.5f32, -0.5f32, 0.25f32, -0.25f32];
        if let Ok(mut chunk) = prod.write_chunk(samples.len()) {
            chunk.as_mut_slices().0.copy_from_slice(&samples);
            chunk.commit_all();
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
        let data_bytes = rec.stop().unwrap();
        assert_eq!(data_bytes, 8);

        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes.len(), 52);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 8);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn encodes_all_supported_formats_and_round_trips_through_decoders() {
        use crate::api::types::RustAnalysisConfig;
        use crate::core::dual_source::AudioSourceCore;
        use crate::dsp::analysis::analyze_audio_source;

        let sr = 44_100u32;
        let ch = 2u16;
        // 40,000 stereo frames (> WAVPACK_BLOCK_FRAMES = 32,768) exercises multi-block streaming.
        let frames = 40_000usize;
        let mut samples = Vec::with_capacity(frames * ch as usize);
        for f in 0..frames {
            let phase = (f as f32 * 440.0 * 2.0 * std::f32::consts::PI) / sr as f32;
            samples.push(0.4 * phase.sin());
            samples.push(0.4 * phase.cos());
        }

        let cases = [
            (RecordingEncoding::WavPcm16, "wav", "WAV", false),
            (RecordingEncoding::WavFloat32, "wav", "WAV", true),
            (RecordingEncoding::Rf64Pcm16, "rf64", "RF64", false),
            (RecordingEncoding::Rf64Float32, "rf64", "RF64", true),
            (RecordingEncoding::W64Pcm16, "w64", "W64", false),
            (RecordingEncoding::W64Float32, "w64", "W64", true),
            (RecordingEncoding::AiffPcm16, "aiff", "AIFF", false),
            (RecordingEncoding::CafPcm16, "caf", "CAF", false),
            (RecordingEncoding::CafFloat32, "caf", "CAF", true),
            (RecordingEncoding::WavPackPcm16, "wv", "WavPack", false),
            (RecordingEncoding::WavPackFloat32, "wv", "WavPack", true),
        ];

        for (idx, (enc, ext, expected_container, is_float)) in cases.into_iter().enumerate() {
            let mut cursor = std::io::Cursor::new(Vec::<u8>::new());
            let mut writer = AudioStreamWriter::new(&mut cursor, sr, ch, enc).unwrap();
            for chunk in samples.chunks(1024 * ch as usize) {
                writer.write_samples(chunk).unwrap();
            }
            let (_done_cursor, reported_bytes) = writer.finish().unwrap();
            assert!(reported_bytes > 0, "format {enc:?} wrote 0 bytes");

            let out_bytes = cursor.into_inner();
            let tmp = std::env::temp_dir().join(format!(
                "miniaudio_enc_roundtrip_{}_{}.{}",
                std::process::id(),
                idx,
                ext
            ));
            std::fs::write(&tmp, &out_bytes).unwrap();
            let res = analyze_audio_source(
                AudioSourceCore {
                    id: 0,
                    source: tmp.to_string_lossy().into_owned(),
                    headers: None,
                    data_bytes: None,
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
                RustAnalysisConfig {
                    replay_gain: false,
                    waveform: false,
                    metadata: false,
                    chromaprint: false,
                    waveform_points: 8,
                    ..Default::default()
                },
            );
            let _ = std::fs::remove_file(&tmp);

            let info = res.unwrap_or_else(|e| panic!("failed to decode {enc:?} (.{ext}): {e}"));
            assert_eq!(info.audio_info.sample_rate, sr, "sr mismatch for {enc:?}");
            assert_eq!(info.audio_info.channels, ch as u32, "ch mismatch for {enc:?}");
            assert_eq!(
                info.audio_info.bits_per_sample,
                Some(if is_float { 32 } else { 16 }),
                "bps mismatch for {enc:?}"
            );
            assert!(
                info.audio_info.container_format == expected_container
                    || info.audio_info.container_format.contains(expected_container),
                "expected container matching {expected_container} for {enc:?}, got {}",
                info.audio_info.container_format
            );
            let dur_ms = info.audio_info.duration_ms.expect("duration_ms") as u64;
            let expected_ms = (frames as u64 * 1000) / sr as u64;
            assert!(
                dur_ms.abs_diff(expected_ms) <= 10,
                "duration mismatch for {enc:?}: got {dur_ms}ms expected ~{expected_ms}ms"
            );
        }
    }
}
