//! Cross-platform Web OPFS path validation/sanitization and SharedArrayBuffer RPC protocol.
//!
//! Compiles on all targets so host `cargo test` validates path rules and 64-bit wire layout.

use std::cell::UnsafeCell;
use std::sync::atomic::AtomicI32;

use crate::bridge::ffi::{MAP_ERROR_INVALID_ARGS, MAP_ERROR_UNSUPPORTED};

/// Shared-memory RPC transfer payload capacity (256 KiB).
pub const OPFS_XFER_CAP: usize = 256 * 1024;
/// Shared-memory UTF-8 error message capacity (2 KiB).
pub const OPFS_ERR_CAP: usize = 2048;
/// Number of 32-bit atomic words in [`OpfsSlotShared::ctrl`].
pub const OPFS_CTRL_WORDS: usize = 12;
/// Maximum OPFS filename segment size in UTF-8 bytes.
pub const OPFS_MAX_SEGMENT_UTF8_BYTES: usize = 255;

pub const CTRL_STATE: usize = 0;
pub const CTRL_OP: usize = 1;
pub const CTRL_STATUS: usize = 2;
pub const CTRL_VFD: usize = 3;
pub const CTRL_ARG0_LO: usize = 4;
pub const CTRL_ARG0_HI: usize = 5;
pub const CTRL_ARG1_LEN: usize = 6;
pub const CTRL_RES0_LO: usize = 7;
pub const CTRL_RES0_HI: usize = 8;
pub const CTRL_ERR_LEN: usize = 9;
pub const CTRL_WAKE_RUST: usize = 10;
pub const CTRL_SEQ: usize = 11;

pub const STATE_IDLE: i32 = 0;
pub const STATE_PENDING: i32 = 1;
pub const STATE_DONE: i32 = 2;
pub const STATE_ERROR: i32 = 3;

pub const OP_OPEN_READ: i32 = 1;
pub const OP_READ_AT: i32 = 2;
pub const OP_OPEN_WRITE: i32 = 3;
pub const OP_WRITE_AT: i32 = 4;
pub const OP_TRUNCATE: i32 = 5;
pub const OP_FLUSH: i32 = 6;
pub const OP_CLOSE: i32 = 7;

const WINDOWS_RESERVED_NAMES: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// Packs a 64-bit unsigned integer into two 32-bit little-endian `i32` control words.
#[inline]
pub fn pack_u64(val: u64) -> (i32, i32) {
    ((val & 0xFFFF_FFFF) as i32, ((val >> 32) & 0xFFFF_FFFF) as i32)
}

/// Unpacks two 32-bit `i32` control words into a 64-bit unsigned integer.
#[inline]
pub fn unpack_u64(lo: i32, hi: i32) -> u64 {
    ((lo as u32) as u64) | (((hi as u32) as u64) << 32)
}

/// Shared linear-memory RPC slot exchanged between WASM worker threads and `miniaudio-opfs-worker`.
pub struct OpfsSlotShared {
    pub ctrl: Box<[AtomicI32; OPFS_CTRL_WORDS]>,
    pub data_buf: Box<[UnsafeCell<u8>]>,
    pub err_buf: Box<[UnsafeCell<u8>]>,
}

// Safety: access to `data_buf` and `err_buf` is exclusively owned by the active `OpfsSlotLease`
// on the Rust side during IDLE/DONE/ERROR and by the JS worker while `CTRL_STATE == STATE_PENDING`,
// synchronized via Acquire/Release atomic state transitions.
unsafe impl Send for OpfsSlotShared {}
unsafe impl Sync for OpfsSlotShared {}

impl Default for OpfsSlotShared {
    fn default() -> Self {
        Self::new()
    }
}

impl OpfsSlotShared {
    pub fn new() -> Self {
        let ctrl: Box<[AtomicI32; OPFS_CTRL_WORDS]> =
            Box::new(std::array::from_fn(|_| AtomicI32::new(0)));
        let data_buf: Box<[UnsafeCell<u8>]> = (0..OPFS_XFER_CAP)
            .map(|_| UnsafeCell::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let err_buf: Box<[UnsafeCell<u8>]> = (0..OPFS_ERR_CAP)
            .map(|_| UnsafeCell::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        Self {
            ctrl,
            data_buf,
            err_buf,
        }
    }

    #[inline]
    pub fn ctrl_ptr(&self) -> u32 {
        self.ctrl.as_ptr() as usize as u32
    }

    #[inline]
    pub fn data_ptr(&self) -> u32 {
        self.data_buf.as_ptr() as usize as u32
    }

    #[inline]
    pub fn err_ptr(&self) -> u32 {
        self.err_buf.as_ptr() as usize as u32
    }
}

/// Canonical OPFS path normalization result (never retains `opfs://` or leading `/`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedOpfsPath {
    pub canonical: String,
    pub had_opfs_prefix: bool,
}

/// Returns lowercase RFC 3986 URI scheme if present, ignoring Windows drive letters (`C:/...`).
pub fn extract_uri_scheme(raw: &str) -> Option<String> {
    let input = raw.trim_start();
    let bytes = input.as_bytes();
    if bytes.is_empty() {
        return None;
    }
    if bytes.len() >= 2
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes.len() == 2 || bytes[2] == b'/' || bytes[2] == b'\\')
    {
        return None;
    }
    let colon_idx = input.find(':')?;
    if colon_idx == 0 || !bytes[0].is_ascii_alphabetic() {
        return None;
    }
    if !bytes[1..colon_idx]
        .iter()
        .all(|&c| c.is_ascii_alphanumeric() || c == b'+' || c == b'-' || c == b'.')
    {
        return None;
    }
    Some(input[..colon_idx].to_ascii_lowercase())
}

#[inline]
fn is_opfs_forbidden_char(ch: char) -> bool {
    let code = ch as u32;
    code < 0x20
        || code == 0x7F
        || matches!(ch, '<' | '>' | ':' | '"' | '|' | '?' | '*' | '\\')
}

#[inline]
fn is_windows_reserved_segment(seg: &str) -> bool {
    let stem = seg.split('.').next().unwrap_or(seg);
    WINDOWS_RESERVED_NAMES
        .iter()
        .any(|res| res.eq_ignore_ascii_case(stem))
}

fn truncate_utf8_to_bytes(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let mut end = 0;
    for (idx, ch) in text.char_indices() {
        let next_end = idx + ch.len_utf8();
        if next_end > max_bytes {
            break;
        }
        end = next_end;
    }
    &text[..end]
}

fn sanitize_opfs_segment(raw_seg: &str, is_leaf: bool) -> String {
    let mut cleaned = String::with_capacity(raw_seg.len());
    for ch in raw_seg.chars() {
        if is_opfs_forbidden_char(ch) {
            cleaned.push('_');
        } else {
            cleaned.push(ch);
        }
    }
    let mut cleaned = cleaned.trim_end_matches(['.', ' ']).to_string();
    if cleaned.is_empty() {
        return String::new();
    }
    if is_windows_reserved_segment(&cleaned) {
        cleaned.insert(0, '_');
    }
    if cleaned.len() <= OPFS_MAX_SEGMENT_UTF8_BYTES {
        return cleaned;
    }
    if is_leaf {
        if let Some(last_dot) = cleaned.rfind('.') {
            if last_dot > 0 {
                let ext = &cleaned[last_dot..];
                if ext.len() > 1 && ext.len() <= 32 && ext.len() < OPFS_MAX_SEGMENT_UTF8_BYTES {
                    let budget = OPFS_MAX_SEGMENT_UTF8_BYTES - ext.len();
                    let stem_raw = truncate_utf8_to_bytes(&cleaned[..last_dot], budget);
                    let stem_clean = stem_raw.trim_end_matches(['.', ' ']);
                    let mut out = if stem_clean.is_empty() {
                        String::from("_")
                    } else {
                        stem_clean.to_string()
                    };
                    out.push_str(ext);
                    return out;
                }
            }
        }
    }
    truncate_utf8_to_bytes(&cleaned, OPFS_MAX_SEGMENT_UTF8_BYTES)
        .trim_end_matches(['.', ' '])
        .to_string()
}

fn extract_opfs_body<'a>(
    raw_path: &'a str,
    context_label: &str,
) -> Result<(&'a str, bool), (i32, String)> {
    let trimmed = raw_path.trim();
    if trimmed.is_empty() {
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!("{} path cannot be empty.", context_label),
        ));
    }
    if let Some(scheme) = extract_uri_scheme(trimmed) {
        if scheme != "opfs" {
            return Err((
                MAP_ERROR_UNSUPPORTED,
                format!(
                    "Unsupported URI scheme '{}://' in {} path '{}'.",
                    scheme, context_label, raw_path
                ),
            ));
        }
        if trimmed.len() < 7 || !trimmed[..7].eq_ignore_ascii_case("opfs://") {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "Malformed opfs URI '{}'. Expected 'opfs://<path>' or a plain relative/absolute path.",
                    raw_path
                ),
            ));
        }
        return Ok((&trimmed[7..], true));
    }
    Ok((trimmed, false))
}

/// Strictly validates a Web OPFS path for playback, analysis, and SFX without silently
/// rewriting invalid segment names (mirrors Dart `parseOpfsPathStrict`).
pub fn parse_opfs_path_strict(raw_path: &str) -> Result<ParsedOpfsPath, (i32, String)> {
    let (body, had_opfs_prefix) = extract_opfs_body(raw_path, "OPFS")?;
    if body.contains('\\') {
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!(
                "Invalid backslash '\\' in OPFS path '{}'. Use forward slashes '/'.",
                raw_path
            ),
        ));
    }
    let without_leading = body.trim_start_matches('/');
    if without_leading.is_empty() {
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!("OPFS path '{}' must name a file.", raw_path),
        ));
    }
    if without_leading.ends_with('/') {
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!(
                "OPFS path '{}' cannot end with '/' (missing file name).",
                raw_path
            ),
        ));
    }
    let segments: Vec<&str> = without_leading.split('/').collect();
    for seg in &segments {
        if seg.is_empty() {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "OPFS path '{}' contains empty '//' path segments.",
                    raw_path
                ),
            ));
        }
        if *seg == "." || *seg == ".." {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "OPFS path '{}' cannot contain '.' or '..' segments.",
                    raw_path
                ),
            ));
        }
        if seg.chars().any(is_opfs_forbidden_char) {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "Invalid character in OPFS segment '{}' of '{}'.",
                    seg, raw_path
                ),
            ));
        }
        if seg.ends_with('.') || seg.ends_with(' ') {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "OPFS path segment '{}' in '{}' cannot end with '.' or whitespace.",
                    seg, raw_path
                ),
            ));
        }
        if is_windows_reserved_segment(seg) {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "OPFS path segment '{}' in '{}' uses a reserved device name.",
                    seg, raw_path
                ),
            ));
        }
        if seg.len() > OPFS_MAX_SEGMENT_UTF8_BYTES {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "OPFS path segment '{}' in '{}' exceeds 255 UTF-8 bytes.",
                    seg, raw_path
                ),
            ));
        }
    }
    Ok(ParsedOpfsPath {
        canonical: segments.join("/"),
        had_opfs_prefix,
    })
}

/// Parses and sanitizes a Web OPFS recording path (mirrors Dart `sanitizeOpfsRecordingPath`).
pub fn sanitize_opfs_recording_path(raw_path: &str) -> Result<ParsedOpfsPath, (i32, String)> {
    let (body, had_opfs_prefix) = extract_opfs_body(raw_path, "OPFS recording")?;
    let slash_norm = body.replace('\\', "/");
    if slash_norm.is_empty() || slash_norm.ends_with('/') {
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!("OPFS recording path '{}' must specify a file name.", raw_path),
        ));
    }
    let mut non_empty = Vec::new();
    for part in slash_norm.trim_start_matches('/').split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "Path traversal '..' is not allowed in OPFS recording path '{}'.",
                    raw_path
                ),
            ));
        }
        non_empty.push(part);
    }
    if non_empty.is_empty() {
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!(
                "OPFS recording path '{}' does not contain a valid file name.",
                raw_path
            ),
        ));
    }
    let last_idx = non_empty.len() - 1;
    let mut out_segments = Vec::with_capacity(non_empty.len());
    for (idx, part) in non_empty.into_iter().enumerate() {
        let clean = sanitize_opfs_segment(part, idx == last_idx);
        if clean.is_empty() {
            return Err((
                MAP_ERROR_INVALID_ARGS,
                format!(
                    "OPFS recording segment '{}' in '{}' sanitizes to an empty name.",
                    part, raw_path
                ),
            ));
        }
        out_segments.push(clean);
    }
    Ok(ParsedOpfsPath {
        canonical: out_segments.join("/"),
        had_opfs_prefix,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn u64_pack_roundtrip_above_4gib() {
        let offsets = [0u64, 44, (1u64 << 32) + 80, u64::MAX - 1];
        for off in offsets {
            let (lo, hi) = pack_u64(off);
            assert_eq!(unpack_u64(lo, hi), off);
        }
    }

    #[test]
    fn strict_equivalence_and_distinction() {
        let abs = parse_opfs_path_strict("/temporal/sistema/test/1.wav").unwrap();
        let rel = parse_opfs_path_strict("temporal/sistema/test/1.wav").unwrap();
        let prefixed = parse_opfs_path_strict("OPFS:///temporal/sistema/test/1.wav").unwrap();
        assert_eq!(abs.canonical, "temporal/sistema/test/1.wav");
        assert_eq!(abs.canonical, rel.canonical);
        assert_eq!(abs.canonical, prefixed.canonical);
        assert!(!abs.had_opfs_prefix);
        assert!(prefixed.had_opfs_prefix);

        let root_a = parse_opfs_path_strict("1.wav").unwrap();
        let root_b = parse_opfs_path_strict("/1.wav").unwrap();
        assert_eq!(root_a.canonical, "1.wav");
        assert_eq!(root_a.canonical, root_b.canonical);
        assert_ne!(root_a.canonical, abs.canonical);
    }

    #[test]
    fn strict_rejects_invalid_names_without_sanitizing() {
        for bad in [
            "",
            "   ",
            "/",
            "opfs://",
            "opfs:///",
            "opfs:1.wav",
            "temporal/sistema/",
            "temporal//1.wav",
            "temporal/./1.wav",
            "../1.wav",
            "a\\b.wav",
            "temporal/bad:name.wav",
            "bad*name?.wav",
            "CON.wav",
            "temporal/aux.flac",
            "dir/file.",
            "dir /file.wav",
            "C:/audio.wav",
        ] {
            let err = parse_opfs_path_strict(bad).expect_err(&format!("expected error for {}", bad));
            assert_eq!(err.0, MAP_ERROR_INVALID_ARGS, "wrong code for {}", bad);
        }

        let long_seg = format!("{}.wav", "a".repeat(260));
        let err = parse_opfs_path_strict(&long_seg).unwrap_err();
        assert_eq!(err.0, MAP_ERROR_INVALID_ARGS);

        let wrong_scheme = parse_opfs_path_strict("https://example.com/1.wav").unwrap_err();
        assert_eq!(wrong_scheme.0, MAP_ERROR_UNSUPPORTED);
    }

    #[test]
    fn recording_sanitizer_cleans_invalid_names_and_rejects_traversal() {
        let r1 = sanitize_opfs_recording_path("/temporal/sistema/bad:name*?.wav").unwrap();
        assert_eq!(r1.canonical, "temporal/sistema/bad_name__.wav");
        assert!(!r1.had_opfs_prefix);

        let r2 = sanitize_opfs_recording_path("opfs://temporal/CON/aux.. /take .wav.").unwrap();
        assert_eq!(r2.canonical, "temporal/_CON/_aux/take .wav");
        assert!(r2.had_opfs_prefix);

        let long_in = format!("rec/{}.rf64", "日".repeat(120));
        let r3 = sanitize_opfs_recording_path(&long_in).unwrap();
        assert!(r3.canonical.ends_with(".rf64"));
        let leaf = r3.canonical.rsplit('/').next().unwrap();
        assert!(leaf.len() <= OPFS_MAX_SEGMENT_UTF8_BYTES);

        for rejected in ["", "   ", "/", "temporal/", "../escape.wav", "temporal/.../a.wav"] {
            let err = sanitize_opfs_recording_path(rejected).unwrap_err();
            assert_eq!(err.0, MAP_ERROR_INVALID_ARGS, "for {}", rejected);
        }
        let unsupported = sanitize_opfs_recording_path("https://example.com/1.wav").unwrap_err();
        assert_eq!(unsupported.0, MAP_ERROR_UNSUPPORTED);
    }
}
