//! Shared-memory SPSC protocol and response header wire codec shared between
//! the `wasm32` `ureq` shim and host unit tests.

use std::cell::UnsafeCell;
use std::sync::atomic::AtomicI32;

/// Ring buffer capacity per active `wasm32` HTTP stream (256 KiB).
pub const RING_CAP: usize = 256 * 1024;
/// Mirror-bit modulus (`2 * RING_CAP`) distinguishing full vs empty states without overflow.
pub const RING_MOD: u32 = (RING_CAP as u32) * 2;
/// Fixed UTF-8 scratch capacity for serialized HTTP response headers (8 KiB).
pub const HDR_CAP: usize = 8 * 1024;

pub const STATE_CONNECTING: i32 = 0;
pub const STATE_HEADERS_READY: i32 = 1;
pub const STATE_EOF: i32 = 2;
pub const STATE_ERROR: i32 = 3;

/// Synthetic `CTRL_STATUS` when a strict `Range` request is blocked by CORS or
/// short-circuited via the JS worker's `rangeBlockedHosts` cache.
pub const STATUS_CORS_RANGE_BLOCKED: i32 = -6;
/// Synthetic `CTRL_STATUS` when a strict `Icy-MetaData: 1` request is blocked
/// by CORS or short-circuited via the JS worker's `icyBlockedHosts` cache.
pub const STATUS_CORS_ICY_BLOCKED: i32 = -7;

/// Synthetic response header injected by the JS worker indicating whether the
/// response originated from a cross-origin CORS fetch (`"1"`) vs same-origin/local (`"0"`).
pub const HDR_CORS_RESPONSE: &str = "x-miniaudio-cors-response";
/// Internal request control header marking `Range` as optional (e.g. HLS `#EXT-X-BYTERANGE`).
pub const HDR_RANGE_OPTIONAL: &str = "x-miniaudio-range-optional";
/// Internal request control header disabling fallback to a plain GET when `Icy-MetaData: 1` fails.
pub const HDR_ICY_STRICT: &str = "x-miniaudio-icy-strict";

/// Canonical `ureq::Error::Transport` message mapped from [`STATUS_CORS_RANGE_BLOCKED`].
pub const ERR_CORS_RANGE_BLOCKED: &str = "cors_range_blocked";
/// Canonical `ureq::Error::Transport` message mapped from [`STATUS_CORS_ICY_BLOCKED`].
pub const ERR_CORS_ICY_BLOCKED: &str = "cors_icy_blocked";

pub const CTRL_STATE: usize = 0;
pub const CTRL_STATUS: usize = 1;
pub const CTRL_WRITE_POS: usize = 2;
pub const CTRL_READ_POS: usize = 3;
pub const CTRL_WAKE_RUST: usize = 4;
pub const CTRL_WAKE_JS: usize = 5;
pub const CTRL_ABORTED: usize = 6;
pub const CTRL_HDR_LEN: usize = 7;
pub const CTRL_JS_EXITED: usize = 8;
pub const CTRL_JS_WAIT_FALLBACK: usize = 9;
pub const CTRL_WORDS: usize = 10;

/// Shared linear-memory control block + SPSC byte ring pinned for a single JS `fetch` stream.
pub struct WasmStreamShared {
    pub id: u32,
    pub ctrl: Box<[AtomicI32; CTRL_WORDS]>,
    pub ring: Box<[UnsafeCell<u8>]>,
    pub hdr_buf: Box<[UnsafeCell<u8>]>,
}

// Safety: all cross-agent accesses to `ring` and `hdr_buf` follow strict Acquire/Release
// handshakes through `ctrl` atomics and pinned lifetime rules until `CTRL_JS_EXITED == 1`.
unsafe impl Send for WasmStreamShared {}
unsafe impl Sync for WasmStreamShared {}

impl WasmStreamShared {
    pub fn new(id: u32) -> Self {
        let ctrl: Box<[AtomicI32; CTRL_WORDS]> = Box::new(std::array::from_fn(|_| AtomicI32::new(0)));
        let ring: Box<[UnsafeCell<u8>]> = (0..RING_CAP)
            .map(|_| UnsafeCell::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let hdr_buf: Box<[UnsafeCell<u8>]> = (0..HDR_CAP)
            .map(|_| UnsafeCell::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        Self {
            id,
            ctrl,
            ring,
            hdr_buf,
        }
    }

    #[inline]
    pub fn ctrl_ptr(&self) -> u32 {
        self.ctrl.as_ptr() as usize as u32
    }

    #[inline]
    pub fn ring_ptr(&self) -> u32 {
        self.ring.as_ptr() as usize as u32
    }

    #[inline]
    pub fn hdr_ptr(&self) -> u32 {
        self.hdr_buf.as_ptr() as usize as u32
    }
}

/// Computes readable bytes inside the mirror-bit SPSC ring.
#[inline]
pub fn ring_available(write_pos: u32, read_pos: u32) -> usize {
    ((write_pos + RING_MOD - read_pos) % RING_MOD) as usize
}

/// Advances a mirror-bit ring cursor safely across wraps.
#[inline]
pub fn advance_ring_pos(pos: u32, count: usize) -> u32 {
    (pos + (count as u32)) % RING_MOD
}

/// Decodes serialized `key\0value\n` UTF-8 wire lines emitted by the JS Network Worker.
pub fn decode_header_wire_bytes(raw: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(raw);
    let mut out = Vec::new();
    for line in text.split('\n') {
        if line.is_empty() {
            continue;
        }
        if let Some((k, v)) = line.split_once('\0') {
            let key = k.trim();
            if !key.is_empty() {
                out.push((key.to_ascii_lowercase(), v.trim().to_string()));
            }
        }
    }
    out
}

