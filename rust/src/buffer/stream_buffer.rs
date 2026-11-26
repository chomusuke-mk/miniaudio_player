//! Universal `StreamBuffer` Primitive (`Linear`, `Circular`, `Sparse`) and `StreamSession`.
//!
//! Replaces legacy heterogeneous buffer segments with a unified, thread-safe,
//! deadlock-free reactive buffer architecture:
//! - `BufferBackend::Linear`: Non-circular, dynamically growing memory for container headers (`Head`).
//! - `BufferBackend::Circular`: Bounded circular ring buffer with proactive watermark prefetching
//!   and on-demand `ByteFetchTask` (`getRealBytes`) for pure audio payloads (`Body`).
//! - `BufferBackend::Sparse`: Offset-indexed virtual address space for metadata tags, cover art,
//!   chapters, and live ICY updates (`Metadata`).

use std::collections::{BTreeMap, VecDeque};
use std::io::Result as IoResult;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::time::Duration;

use super::byte_time_map::ByteTimeMap;
use crate::sync::{lock_unpoisoned, read_unpoisoned, wait_timeout_unpoisoned, write_unpoisoned, MonotonicInstant};

/// Contiguous byte range and fullness telemetry snapshot.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct BufferRange {
    /// Starting byte offset cached in the sliding window.
    pub start_byte: i64,
    /// Furthest byte offset cached in the sliding window.
    pub end_byte: i64,
    /// Total known stream length in bytes, or -1 if unbounded.
    pub total_bytes: i64,
    /// Current read cursor byte offset.
    pub read_cursor_byte: i64,
    /// Buffer fill percentage of target window capacity.
    pub fill_percentage: f32,
    /// Overall stream download percentage.
    pub stream_percentage: f32,
    /// Non-zero if reader is stalled waiting for data.
    pub is_buffering: i32,
    /// Non-zero if end of stream reached.
    pub is_eof: i32,
}

/// Buffer operation error conditions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferError {
    /// Invalid arguments supplied.
    InvalidArgs,
    /// Circular ring buffer is full and applying backpressure.
    Busy,
    /// Operation was aborted.
    Aborted,
    /// End of stream reached.
    Eof,
    /// Memory allocation failed.
    OutOfMemory,
    /// Requested offset is not currently cached (`null` / awaiting data).
    WouldBlock,
    /// Blocking or probe read was preempted by a newer seek request.
    SeekInterrupted,
}

/// Asynchronous or on-demand byte provider callback (`getRealBytes(position, size)`).
///
/// Invoked outside any buffer mutex lock to prevent deadlocks and I/O priority inversion.
pub type ByteFetchTask = Arc<dyn Fn(u64, usize) -> IoResult<Vec<u8>> + Send + Sync>;

/// Temporal sliding-window and progressive block-coalescing configuration for a circular [`StreamBuffer`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SlidingWindowConfig {
    /// Backward retention duration in milliseconds (default: `10_000` ms = 10s).
    /// Bytes within `[read_cursor - B_back .. read_cursor]` are protected from circular overwrite.
    pub back_duration_ms: u32,
    /// Forward prefetch target duration in milliseconds (default: `30_000` ms = 30s).
    /// The block scheduler prefetches ahead up to `read_cursor + B_ahead` (or `audio_end`).
    pub ahead_duration_ms: u32,
    /// Base block window duration in milliseconds (default: `5_000` ms = 5s).
    pub window_duration_ms: u32,
    /// Number of base windows to accumulate/consume before coalescing into a super-block
    /// (default: `3` windows = 15s).
    pub coalesce_windows: usize,
}

impl SlidingWindowConfig {
    /// Default backward retention duration (10 seconds).
    pub const DEFAULT_BACK_DURATION_MS: u32 = 10_000;
    /// Default forward prefetch target duration (30 seconds).
    pub const DEFAULT_AHEAD_DURATION_MS: u32 = 30_000;
    /// Default single block window duration (5 seconds).
    pub const DEFAULT_WINDOW_DURATION_MS: u32 = 5_000;
    /// Default number of windows to coalesce in Phase 3 (3 windows = 15 seconds).
    pub const DEFAULT_COALESCE_WINDOWS: usize = 3;
    /// Default initial stream byte rate estimate before codec probing (32 KB/s = 256 kbps).
    pub const DEFAULT_BYTE_RATE_PER_SEC: u64 = 32 * 1024;
}

impl Default for SlidingWindowConfig {
    /// Returns the default sliding-window configuration.
    fn default() -> Self {
        Self {
            back_duration_ms: Self::DEFAULT_BACK_DURATION_MS,
            ahead_duration_ms: Self::DEFAULT_AHEAD_DURATION_MS,
            window_duration_ms: Self::DEFAULT_WINDOW_DURATION_MS,
            coalesce_windows: Self::DEFAULT_COALESCE_WINDOWS,
        }
    }
}

/// Progressive block-fetching phase of the temporal sliding-window scheduler.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockFetchPhase {
    /// Phase 1 (Bootstrap / Post-Seek Urgent): `ahead < 1 window`.
    /// Requests a single base window (`1 * B_win`) for immediate playback startup.
    UrgentBootstrap,
    /// Phase 2 (Stabilization): `1 window <= ahead < coalesce_windows * B_win`.
    /// Requests single base windows (`1 * B_win`) until the coalescing threshold is reached.
    Stabilization,
    /// Phase 3 (Coalesced Cruise): `ahead >= coalesce_windows * B_win`.
    /// Waits until consumption opens a deficit of at least `coalesce_windows * B_win`
    /// (or the remaining bytes before `audio_end`), then requests a coalesced super-block.
    CoalescedCruise,
}

/// Deterministic block fetch instruction computed by the sliding-window scheduler.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockFetchOrder {
    /// Absolute stream byte offset to fetch from (`range_end`).
    pub offset: u64,
    /// Number of bytes to fetch in this block or coalesced super-block.
    pub length: usize,
    /// Active progressive phase that produced this order.
    pub phase: BlockFetchPhase,
    /// True if this block reaches `audio_end` (meaning the stream reaches EOF upon completion).
    pub reaches_eof: bool,
}

/// Resolved byte-level sliding-window state inside `BufferBackend::Circular`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SlidingWindowState {
    /// Temporal configuration parameters.
    pub config: SlidingWindowConfig,
    /// Stream byte rate in bytes/sec (estimated or exact from `AudioInfo`).
    pub byte_rate_per_sec: u64,
    /// Current playback rate multiplier (e.g., `1.0`, `3.0`, `0.25`).
    pub playback_rate: f32,
    /// Protected backward retention bytes (`B_back`).
    pub back_retention_bytes: usize,
    /// Target forward prefetch bytes (`B_ahead`).
    pub ahead_target_bytes: usize,
    /// Scaled single base window size in bytes (`B_win`).
    pub base_window_bytes: usize,
    /// True once the forward prefetch window has filled to `ahead_target_bytes` (enabling Phase 3 hysteresis).
    pub window_filled: bool,
    /// Last `range_end` at which a pull-mode prefetch was triggered.
    pub last_pull_trigger_end: u64,
    /// True for unbounded live streams so incoming TCP bursts drain whenever ring space allows.
    pub is_live: bool,
}

impl SlidingWindowState {
    /// Creates a new `SlidingWindowState` from `config`, `byte_rate_per_sec`, and `playback_rate`,
    /// resolving initial byte dimensions for `capacity`.
    pub fn new(
        config: SlidingWindowConfig,
        byte_rate_per_sec: u64,
        playback_rate: f32,
        capacity: usize,
    ) -> Self {
        let mut state = Self {
            config,
            byte_rate_per_sec: byte_rate_per_sec.max(1),
            playback_rate: if playback_rate.is_finite() && playback_rate > 0.0 {
                playback_rate
            } else {
                1.0
            },
            back_retention_bytes: 0,
            ahead_target_bytes: 0,
            base_window_bytes: 0,
            window_filled: false,
            last_pull_trigger_end: 0,
            is_live: false,
        };
        state.recalculate(capacity);
        state
    }

    /// Recomputes `back_retention_bytes`, `ahead_target_bytes`, and `base_window_bytes`
    /// from `(config, byte_rate_per_sec, playback_rate, capacity)`.
    pub fn recalculate(&mut self, capacity: usize) {
        let cap = capacity.max(1);
        let rate_scale = (self.playback_rate.clamp(1.0, 3.0)) as f64;
        let byte_rate = self.byte_rate_per_sec.max(1) as f64;

        let raw_back = (byte_rate * (self.config.back_duration_ms as f64 / 1000.0)).round() as usize;
        let max_back = if cap < 1024 { cap / 8 } else { cap / 3 };
        self.back_retention_bytes = raw_back.min(max_back);

        let max_ahead_cap = cap.saturating_sub(self.back_retention_bytes).max(1);
        let raw_ahead =
            (byte_rate * (self.config.ahead_duration_ms as f64 / 1000.0) * rate_scale).round() as usize;
        self.ahead_target_bytes = raw_ahead.clamp(1, max_ahead_cap);

        let coalesce_n = self.config.coalesce_windows.max(1);
        let max_win = (self.ahead_target_bytes / coalesce_n).max(1);
        let raw_win =
            (byte_rate * (self.config.window_duration_ms as f64 / 1000.0) * rate_scale).round() as usize;
        self.base_window_bytes = raw_win.clamp(1, max_win);
    }
}

/// Internal storage strategy for a [`StreamBuffer`].
pub enum BufferBackend {
    /// Non-circular linear storage with configurable minimum growth step (used for `Head`).
    Linear {
        /// Contiguous linear byte storage.
        data: Vec<u8>,
        /// Minimum allocation growth step in bytes when expanding `data`.
        min_growth: usize,
    },
    /// Non-circular sparse virtual address space (used for `Metadata`).
    Sparse {
        /// Offset-indexed contiguous metadata chunks stored in ascending order.
        chunks: BTreeMap<u64, Vec<u8>>,
        /// Known virtual length of the sparse stream in bytes, if bounded.
        virtual_size: Option<u64>,
        /// Minimum growth step hint in bytes configured at construction.
        min_growth: usize,
        /// Optional live ICY metadata override payload replacing sparse chunk reads.
        icy_override: Vec<u8>,
    },
    /// Circular bidirectional sliding window (`[Back | Ahead]`) with progressive block coalescing (used for `Body`).
    Circular {
        /// Fixed-size ring backing array of length `capacity`.
        storage: Vec<u8>,
        /// Total capacity of the circular ring buffer in bytes.
        capacity: usize,
        /// Stream byte offset anchored at ring index `0`.
        anchor_offset: u64,
        /// Lowest valid stream byte offset currently retained in the ring.
        range_start: u64,
        /// Exclusive upper stream byte offset currently buffered in the ring.
        range_end: u64,
        /// Known upper byte boundary of the audio payload, if bounded.
        audio_end: Option<u64>,
        /// Resolved temporal sliding-window dimensions and phase state.
        window: SlidingWindowState,
        /// True while an active background push-streaming thread feeds this ring.
        push_streaming: bool,
        /// Optional on-demand range fetcher invoked outside the buffer lock on pull/cache-miss reads.
        fetcher: Option<ByteFetchTask>,
    },
}

/// Coalesces `data` at `offset` into the sparse `chunks` map, merging overlapping or adjacent ranges.
fn insert_and_coalesce_sparse(chunks: &mut BTreeMap<u64, Vec<u8>>, offset: u64, data: &[u8]) {
    if data.is_empty() {
        return;
    }
    let mut new_start = offset;
    let mut new_end = offset + data.len() as u64;
    let mut merged = data.to_vec();

    // Check if an existing chunk immediately precedes or overlaps `new_start`
    if let Some((&prev_start, prev_vec)) = chunks.range(..=new_start).next_back() {
        let prev_end = prev_start + prev_vec.len() as u64;
        if prev_end >= new_start {
            if let Some(prev_data) = chunks.remove(&prev_start) {
                let prefix_len = (new_start - prev_start) as usize;
                let mut combined = Vec::with_capacity(
                    (prev_end.max(new_end) - prev_start) as usize,
                );
                combined.extend_from_slice(&prev_data[..prefix_len]);
                combined.extend_from_slice(&merged);
                if prev_end > new_end {
                    let tail_start = (new_end - prev_start) as usize;
                    combined.extend_from_slice(&prev_data[tail_start..]);
                }
                new_start = prev_start;
                new_end = new_start + combined.len() as u64;
                merged = combined;
            }
        }
    }

    // Merge any subsequent chunks that overlap or are contiguous with `new_end`
    loop {
        let next_key = chunks.range(new_start..=new_end).next().map(|(&k, _)| k);
        let Some(k) = next_key else {
            break;
        };
        let Some(next_data) = chunks.remove(&k) else {
            break;
        };
        let next_end = k + next_data.len() as u64;
        if next_end > new_end {
            let overlap = (new_end - k) as usize;
            merged.extend_from_slice(&next_data[overlap..]);
            new_end = next_end;
        }
    }

    chunks.insert(new_start, merged);
}

/// Universal seekable memory buffer primitive.
///
/// Concurrency & Deadlock Guarantees:
/// - Single `Mutex<BufferBackend>` paired directly with `Condvar` (`data_signal`), eliminating
///   split-lock race windows and lost wakeups.
/// - `ByteFetchTask` (`getRealBytes`) is always cloned as an `Arc` and executed **outside** the
///   mutex guard, strictly upholding the rule of never holding locks across I/O.
pub struct StreamBuffer {
    /// Mutex-guarded backing storage variant (`Linear`, `Sparse`, or `Circular`).
    backend: Mutex<BufferBackend>,
    /// Condition variable signaled on writes, cursor movement, EOF, abort, or config updates.
    data_signal: Condvar,
    /// Atomic current byte read cursor offset.
    read_cursor: AtomicU64,
    /// True when `backend` is `BufferBackend::Circular`.
    is_circular: bool,
    /// True while a reader is stalled awaiting asynchronous data arrival.
    is_buffering: AtomicBool,
    /// True while a producer thread is suspended in `wait_for_next_block` or `wait_for_free_space`.
    is_producer_waiting: AtomicBool,
    /// True once end-of-stream has been reached or explicitly marked.
    is_eof: AtomicBool,
    /// True once `abort` has been called to unblock waiting readers/producers.
    should_abort: AtomicBool,
    /// Monotonic mutation counter incremented whenever buffer contents or boundaries change.
    version: AtomicU32,
}

impl StreamBuffer {
    /// Default initial capacity for linear header buffers (64 KB).
    pub const DEFAULT_HEAD_INITIAL_SIZE: usize = 64 * 1024;
    /// Default minimum growth increment for linear/sparse buffers (32 KB).
    pub const DEFAULT_MIN_GROWTH: usize = 32 * 1024;
    /// Default capacity for circular audio body buffers (8 MB).
    pub const DEFAULT_BODY_CAPACITY: usize = 8 * 1024 * 1024;
    /// Default free-space hysteresis threshold (256 KB) before waking a throttled producer.
    pub const DEFAULT_FREE_SPACE_RESUME_BYTES: usize = 256 * 1024;

    /// Creates a non-circular linear `StreamBuffer` (used for `Head`) with `initial_size`
    /// capacity and `min_growth` expansion increment.
    pub fn new_linear(initial_size: usize, min_growth: usize) -> Arc<Self> {
        let cap = initial_size.max(1024);
        let growth = min_growth.max(1024);
        crate::map_log!(
            4,
            "[BUFFER] StreamBuffer::new_linear initial_size={}, min_growth={}",
            cap,
            growth
        );
        Arc::new(Self {
            backend: Mutex::new(BufferBackend::Linear {
                data: Vec::with_capacity(cap),
                min_growth: growth,
            }),
            data_signal: Condvar::new(),
            read_cursor: AtomicU64::new(0),
            is_circular: false,
            is_buffering: AtomicBool::new(false),
            is_producer_waiting: AtomicBool::new(false),
            is_eof: AtomicBool::new(false),
            should_abort: AtomicBool::new(false),
            version: AtomicU32::new(0),
        })
    }

    /// Creates a non-circular sparse `StreamBuffer` (used for `Metadata`) with `min_growth`
    /// step hint and optional bounded `virtual_size`.
    pub fn new_sparse(min_growth: usize, virtual_size: Option<u64>) -> Arc<Self> {
        let growth = min_growth.max(4096);
        crate::map_log!(
            4,
            "[BUFFER] StreamBuffer::new_sparse min_growth={}, virtual_size={:?}",
            growth,
            virtual_size
        );
        Arc::new(Self {
            backend: Mutex::new(BufferBackend::Sparse {
                chunks: BTreeMap::new(),
                virtual_size,
                min_growth: growth,
                icy_override: Vec::new(),
            }),
            data_signal: Condvar::new(),
            read_cursor: AtomicU64::new(0),
            is_circular: false,
            is_buffering: AtomicBool::new(false),
            is_producer_waiting: AtomicBool::new(false),
            is_eof: AtomicBool::new(false),
            should_abort: AtomicBool::new(false),
            version: AtomicU32::new(0),
        })
    }

    /// Creates a circular bidirectional sliding-window `StreamBuffer` (used for `Body`)
    /// with `capacity` bytes, sliding-window `config`, and optional pull-mode `fetcher`.
    pub fn new_circular(
        capacity: usize,
        config: SlidingWindowConfig,
        fetcher: Option<ByteFetchTask>,
    ) -> Arc<Self> {
        let cap = if capacity > 0 {
            capacity
        } else {
            Self::DEFAULT_BODY_CAPACITY
        };
        crate::map_log!(4, "[BUFFER] StreamBuffer::new_circular capacity={}", cap);
        let window = SlidingWindowState::new(
            config,
            SlidingWindowConfig::DEFAULT_BYTE_RATE_PER_SEC,
            1.0,
            cap,
        );
        Arc::new(Self {
            backend: Mutex::new(BufferBackend::Circular {
                storage: vec![0u8; cap],
                capacity: cap,
                anchor_offset: 0,
                range_start: 0,
                range_end: 0,
                audio_end: None,
                window,
                push_streaming: false,
                fetcher,
            }),
            data_signal: Condvar::new(),
            read_cursor: AtomicU64::new(0),
            is_circular: true,
            is_buffering: AtomicBool::new(false),
            is_producer_waiting: AtomicBool::new(false),
            is_eof: AtomicBool::new(false),
            should_abort: AtomicBool::new(false),
            version: AtomicU32::new(0),
        })
    }

    /// Pure deterministic evaluator for the 3-phase progressive block-coalescing scheduler,
    /// computing the next fetch order from `cursor`, `capacity`, `anchor_offset`, `range_start`,
    /// `range_end`, `audio_end`, `is_eof`, and `window`.
    #[allow(clippy::too_many_arguments)]
    fn compute_next_block_order_locked(
        cursor: u64,
        capacity: usize,
        anchor_offset: u64,
        range_start: u64,
        range_end: u64,
        audio_end: Option<u64>,
        is_eof: bool,
        window: &SlidingWindowState,
    ) -> Option<BlockFetchOrder> {
        if is_eof {
            return None;
        }
        if let Some(end) = audio_end {
            if range_end >= end {
                return None;
            }
        }

        let effective_cursor = cursor.max(anchor_offset).max(range_start);
        let ahead_bytes = range_end.saturating_sub(effective_cursor) as usize;

        let eviction_floor = cursor
            .max(anchor_offset)
            .saturating_sub(window.back_retention_bytes as u64)
            .max(anchor_offset);
        let used_in_ring = range_end.saturating_sub(eviction_floor) as usize;
        let free_ring_space = capacity.saturating_sub(used_in_ring);

        if free_ring_space == 0 || ahead_bytes >= window.ahead_target_bytes {
            return None;
        }

        let win_size = window.base_window_bytes.max(1);
        let coalesce_n = window.config.coalesce_windows.max(1);
        let coalesce_threshold = win_size.saturating_mul(coalesce_n);
        let deficit = window.ahead_target_bytes.saturating_sub(ahead_bytes);
        let remaining_to_eof = audio_end.map(|end| end.saturating_sub(range_end) as usize);

        /// Maximum byte size of an urgent Phase-1 bootstrap request.
        const MAX_URGENT_BOOTSTRAP_BYTES: usize = 256 * 1024;
        let (phase, raw_req_len) = if ahead_bytes < win_size {
            // Phase 1 (UrgentBootstrap): ahead < 1 window -> request up to 1 base window,
            // capped at 256 KiB so high-bitrate streams (CAF/DSF) wake the first post-seek frame fast.
            (
                BlockFetchPhase::UrgentBootstrap,
                win_size.min(MAX_URGENT_BOOTSTRAP_BYTES),
            )
        } else if ahead_bytes < coalesce_threshold {
            // Phase 2 (Stabilization): 1 <= ahead < coalesce_n windows -> request 1 base window (5s)
            (BlockFetchPhase::Stabilization, win_size)
        } else {
            // Phase 3 (CoalescedCruise): ahead >= coalesce_n windows
            // During initial fill (!window_filled), top up to ahead_target_bytes in coalesced batches.
            // Once window_filled is true, hold until consumption opens a deficit >= coalesce_threshold
            // (or enough deficit to fetch the remaining bytes up to audio_end).
            let can_finish_eof = remaining_to_eof
                .map(|rem| rem <= deficit && rem <= free_ring_space)
                .unwrap_or(false);

            if !window.is_live && window.window_filled && deficit < coalesce_threshold && !can_finish_eof {
                return None;
            }
            let batch = deficit.min(coalesce_threshold);
            (BlockFetchPhase::CoalescedCruise, batch)
        };

        let mut length = raw_req_len.min(deficit).min(free_ring_space);
        let mut reaches_eof = false;

        if let Some(rem_eof) = remaining_to_eof {
            if rem_eof <= length {
                length = rem_eof;
                reaches_eof = true;
            }
        }

        if length == 0 {
            return None;
        }

        if !window.is_live
            && phase == BlockFetchPhase::CoalescedCruise
            && window.window_filled
            && !reaches_eof
            && length < coalesce_threshold.min(window.ahead_target_bytes)
        {
            return None;
        }

        Some(BlockFetchOrder {
            offset: range_end,
            length,
            phase,
            reaches_eof,
        })
    }

    /// Updates `window.window_filled` and `is_eof` after bytes are written into a `Circular`
    /// buffer bounded by `anchor_offset`, `range_start`, `range_end`, and `audio_end`.
    #[inline]
    fn refresh_circular_window_fill_locked(
        &self,
        anchor_offset: u64,
        range_start: u64,
        range_end: u64,
        audio_end: Option<u64>,
        window: &mut SlidingWindowState,
    ) {
        let cursor = self.read_cursor.load(Ordering::Acquire);
        let effective_cursor = cursor.max(anchor_offset).max(range_start);
        let ahead_bytes = range_end.saturating_sub(effective_cursor) as usize;
        let reached_eof = audio_end.map(|end| range_end >= end).unwrap_or(false);
        let coalesce_threshold = window
            .base_window_bytes
            .max(1)
            .saturating_mul(window.config.coalesce_windows.max(1));

        if ahead_bytes >= window.ahead_target_bytes || reached_eof {
            window.window_filled = true;
        } else if ahead_bytes < coalesce_threshold {
            window.window_filled = false;
        }

        if reached_eof {
            self.is_eof.store(true, Ordering::Release);
        }
    }

    /// Configures the temporal sliding-window `config`, stream `byte_rate_per_sec`, and `playback_rate`.
    pub fn configure_sliding_window(
        &self,
        config: SlidingWindowConfig,
        byte_rate_per_sec: u64,
        playback_rate: f32,
    ) {
        crate::map_log!(
            4,
            "[BUFFER] configure_sliding_window byte_rate={}, playback_rate={:.2}, back_ms={}, ahead_ms={}, win_ms={}, coalesce={}",
            byte_rate_per_sec,
            playback_rate,
            config.back_duration_ms,
            config.ahead_duration_ms,
            config.window_duration_ms,
            config.coalesce_windows
        );
        {
            let mut guard = lock_unpoisoned(&self.backend);
            if let BufferBackend::Circular {
                capacity,
                anchor_offset,
                range_start,
                range_end,
                audio_end,
                ref mut window,
                ..
            } = *guard
            {
                window.config = config;
                if byte_rate_per_sec > 0 {
                    window.byte_rate_per_sec = byte_rate_per_sec;
                }
                if playback_rate.is_finite() && playback_rate > 0.0 {
                    window.playback_rate = playback_rate;
                }
                window.recalculate(capacity);
                self.refresh_circular_window_fill_locked(
                    anchor_offset,
                    range_start,
                    range_end,
                    audio_end,
                    window,
                );
            }
        }
        self.data_signal.notify_all();
    }

    /// Updates the `playback_rate` multiplier and dynamically scales forward prefetch/window sizes.
    pub fn set_playback_rate(&self, playback_rate: f32) {
        if !playback_rate.is_finite() || playback_rate <= 0.0 {
            crate::map_log!(
                2,
                "[BUFFER] set_playback_rate ignored invalid rate={}",
                playback_rate
            );
            return;
        }
        crate::map_log!(4, "[BUFFER] set_playback_rate rate={:.2}", playback_rate);
        {
            let mut guard = lock_unpoisoned(&self.backend);
            if let BufferBackend::Circular {
                capacity,
                anchor_offset,
                range_start,
                range_end,
                audio_end,
                ref mut window,
                ..
            } = *guard
            {
                window.playback_rate = playback_rate;
                window.recalculate(capacity);
                self.refresh_circular_window_fill_locked(
                    anchor_offset,
                    range_start,
                    range_end,
                    audio_end,
                    window,
                );
            }
        }
        self.data_signal.notify_all();
    }

    /// Returns a snapshot of the resolved [`SlidingWindowState`] if this buffer is `Circular`.
    pub fn sliding_window_state(&self) -> Option<SlidingWindowState> {
        let guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular { window, .. } = *guard {
            Some(window)
        } else {
            None
        }
    }

    /// Computes the next [`BlockFetchOrder`] according to the 3-phase progressive block-coalescing heuristic.
    pub fn next_block_request(&self) -> Option<BlockFetchOrder> {
        if !self.is_circular || self.should_abort.load(Ordering::Acquire) {
            return None;
        }
        let guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            capacity,
            anchor_offset,
            range_start,
            range_end,
            audio_end,
            ref window,
            ..
        } = *guard
        {
            let cursor = self.read_cursor.load(Ordering::Acquire);
            let is_eof = self.is_eof.load(Ordering::Acquire);
            Self::compute_next_block_order_locked(
                cursor,
                capacity,
                anchor_offset,
                range_start,
                range_end,
                audio_end,
                is_eof,
                window,
            )
        } else {
            None
        }
    }

    /// Suspends the producer thread on `data_signal` until the sliding-window scheduler
    /// produces a [`BlockFetchOrder`], or until `timeout` elapses, EOF is reached, or the buffer is aborted.
    pub fn wait_for_next_block(&self, timeout: Duration) -> Option<BlockFetchOrder> {
        if !self.is_circular {
            return None;
        }
        let start_time = MonotonicInstant::now();
        let mut guard = lock_unpoisoned(&self.backend);
        self.is_producer_waiting.store(true, Ordering::Release);
        let result = loop {
            if self.should_abort.load(Ordering::Acquire) || self.is_eof.load(Ordering::Acquire) {
                break None;
            }
            if let BufferBackend::Circular {
                capacity,
                anchor_offset,
                range_start,
                range_end,
                audio_end,
                ref window,
                ..
            } = *guard
            {
                let cursor = self.read_cursor.load(Ordering::Acquire);
                let is_eof = self.is_eof.load(Ordering::Acquire);
                if let Some(order) = Self::compute_next_block_order_locked(
                    cursor,
                    capacity,
                    anchor_offset,
                    range_start,
                    range_end,
                    audio_end,
                    is_eof,
                    window,
                ) {
                    break Some(order);
                }
            } else {
                break None;
            }

            let elapsed = start_time.elapsed();
            if elapsed >= timeout {
                break None;
            }
            let wait_slice = (timeout - elapsed).min(Duration::from_millis(50));
            let (new_guard, _) = wait_timeout_unpoisoned(&self.data_signal, guard, wait_slice);
            guard = new_guard;
        };
        self.is_producer_waiting.store(false, Ordering::Release);
        result
    }

    /// Returns the number of unread forward bytes (`Ahead`) currently buffered ahead of `read_cursor`.
    pub fn ahead_bytes(&self) -> u64 {
        let guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            anchor_offset,
            range_start,
            range_end,
            ..
        } = *guard
        {
            let cursor = self
                .read_cursor
                .load(Ordering::Acquire)
                .max(anchor_offset)
                .max(range_start);
            range_end.saturating_sub(cursor)
        } else {
            0
        }
    }

    /// Current read cursor offset.
    #[inline]
    pub fn cursor(&self) -> u64 {
        self.read_cursor.load(Ordering::Acquire)
    }

    /// Updates the read cursor to `offset`, clearing `window_filled` when remaining lookahead
    /// drops below the coalesce threshold, and wakes any waiting producer thread.
    #[inline]
    pub fn set_cursor(&self, offset: u64) {
        self.read_cursor.store(offset, Ordering::Release);
        if self.is_circular {
            let mut guard = lock_unpoisoned(&self.backend);
            if let BufferBackend::Circular {
                anchor_offset,
                range_start,
                range_end,
                ref mut window,
                ..
            } = *guard
            {
                let effective_cursor = offset.max(anchor_offset).max(range_start);
                let ahead_bytes = range_end.saturating_sub(effective_cursor) as usize;
                let coalesce_threshold = window
                    .base_window_bytes
                    .max(1)
                    .saturating_mul(window.config.coalesce_windows.max(1));
                if ahead_bytes < coalesce_threshold {
                    window.window_filled = false;
                }
            }
            if self.is_producer_waiting.load(Ordering::Acquire) {
                self.data_signal.notify_all();
            }
        }
    }

    /// Suspends the producer thread on `data_signal` until at least `min_free_bytes`
    /// (respecting `back_retention_bytes` backward protection) are available in the circular buffer,
    /// or until `timeout` elapses or the buffer is aborted.
    pub fn wait_for_free_space(&self, min_free_bytes: usize, timeout: Duration) -> bool {
        if !self.is_circular {
            return true;
        }
        let start_time = MonotonicInstant::now();
        let mut guard = lock_unpoisoned(&self.backend);
        self.is_producer_waiting.store(true, Ordering::Release);
        let result = loop {
            if self.should_abort.load(Ordering::Acquire) {
                break false;
            }
            if let BufferBackend::Circular {
                capacity,
                anchor_offset,
                range_end,
                ref window,
                ..
            } = *guard
            {
                let cursor = self.read_cursor.load(Ordering::Acquire).max(anchor_offset);
                let eviction_floor = cursor
                    .saturating_sub(window.back_retention_bytes as u64)
                    .max(anchor_offset);
                let used = range_end.saturating_sub(eviction_floor) as usize;
                let free_space = capacity.saturating_sub(used);
                let target_free = min_free_bytes
                    .max((capacity / 16).min(Self::DEFAULT_FREE_SPACE_RESUME_BYTES))
                    .min(capacity.saturating_sub(window.back_retention_bytes).max(1));
                if free_space >= target_free {
                    break true;
                }
            } else {
                break true;
            }

            let elapsed = start_time.elapsed();
            if elapsed >= timeout {
                break false;
            }
            let wait_slice = (timeout - elapsed).min(Duration::from_millis(50));
            let (new_guard, _) = wait_timeout_unpoisoned(&self.data_signal, guard, wait_slice);
            guard = new_guard;
        };
        self.is_producer_waiting.store(false, Ordering::Release);
        result
    }

    /// Suspends the calling thread on `data_signal` until signaled or `timeout` elapses.
    pub fn wait_signal(&self, timeout: Duration) {
        let guard = lock_unpoisoned(&self.backend);
        let _ = self.data_signal.wait_timeout(guard, timeout);
    }

    /// Current mutation version counter.
    #[inline]
    pub fn version(&self) -> u32 {
        self.version.load(Ordering::Acquire)
    }

    /// Whether the buffer is currently waiting for asynchronous data arrival.
    #[inline]
    pub fn is_buffering(&self) -> bool {
        self.is_buffering.load(Ordering::Acquire)
    }

    /// Whether end-of-stream has been marked on this buffer.
    #[inline]
    pub fn is_eof(&self) -> bool {
        self.is_eof.load(Ordering::Acquire)
    }

    /// Marks end-of-stream and wakes any waiting readers.
    pub fn mark_eof(&self) {
        crate::map_log!(
            4,
            "[BUFFER] StreamBuffer::mark_eof is_circular={}",
            self.is_circular
        );
        self.is_eof.store(true, Ordering::Release);
        self.is_buffering.store(false, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Aborts pending reads/writes and wakes all waiting threads.
    pub fn abort(&self) {
        crate::map_log!(
            3,
            "[BUFFER] StreamBuffer::abort is_circular={}",
            self.is_circular
        );
        self.should_abort.store(true, Ordering::Release);
        self.is_buffering.store(false, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Clears the abort flag.
    pub fn clear_abort(&self) {
        self.should_abort.store(false, Ordering::Release);
    }

    /// Sets `active` to indicate whether a background push streamer thread feeds this circular buffer.
    pub fn set_push_streaming(&self, active: bool) {
        let mut guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            ref mut push_streaming,
            ..
        } = *guard
        {
            *push_streaming = active;
        }
    }

    /// Configures the circular buffer `anchor` offset (`audio_start`) and resets its window if empty.
    pub fn set_circular_anchor(&self, anchor: u64) {
        let mut guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            ref mut anchor_offset,
            ref mut range_start,
            ref mut range_end,
            ..
        } = *guard
        {
            *anchor_offset = anchor;
            if *range_end <= anchor {
                *range_start = anchor;
                *range_end = anchor;
            }
        }
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Sets the upper byte boundary `end` of the audio payload (`audio_end`).
    pub fn set_audio_end(&self, end: Option<u64>) {
        let mut guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            anchor_offset,
            range_start,
            range_end,
            ref mut audio_end,
            ref mut window,
            ..
        } = *guard
        {
            *audio_end = end;
            self.refresh_circular_window_fill_locked(
                anchor_offset,
                range_start,
                range_end,
                *audio_end,
                window,
            );
        }
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Returns the virtual size for a `Sparse` buffer, or the current length for `Linear`.
    pub fn virtual_size(&self) -> Option<u64> {
        let guard = lock_unpoisoned(&self.backend);
        match *guard {
            BufferBackend::Linear { ref data, .. } => Some(data.len() as u64),
            BufferBackend::Sparse {
                virtual_size,
                ref chunks,
                ref icy_override,
                ..
            } => {
                if !icy_override.is_empty() {
                    Some(icy_override.len() as u64)
                } else {
                    virtual_size.or_else(|| chunks.iter().map(|(&s, d)| s + d.len() as u64).max())
                }
            }
            BufferBackend::Circular {
                audio_end,
                range_end,
                ..
            } => audio_end.or(Some(range_end)),
        }
    }

    /// Replaces the linear buffer contents with `bytes` or writes at offset 0.
    pub fn set_linear_bytes(&self, bytes: &[u8]) {
        {
            let mut guard = lock_unpoisoned(&self.backend);
            if let BufferBackend::Linear {
                ref mut data,
                min_growth,
            } = *guard
            {
                data.clear();
                if bytes.len() > data.capacity() {
                    let reserve_len = (bytes.len() - data.capacity()).max(min_growth);
                    data.reserve(reserve_len);
                }
                data.extend_from_slice(bytes);
            }
        }
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Returns the byte length of a `Linear` buffer.
    pub fn linear_len(&self) -> usize {
        let guard = lock_unpoisoned(&self.backend);
        match *guard {
            BufferBackend::Linear { ref data, .. } => data.len(),
            _ => 0,
        }
    }

    /// Commits `chunk` at an explicit `stream_offset`.
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if the buffer has been aborted.
    pub fn commit_chunk(&self, stream_offset: u64, chunk: &[u8]) -> Result<usize, BufferError> {
        if self.should_abort.load(Ordering::Acquire) {
            return Err(BufferError::Aborted);
        }
        if chunk.is_empty() {
            return Ok(0);
        }

        {
            let mut guard = lock_unpoisoned(&self.backend);
            match *guard {
                BufferBackend::Linear {
                    ref mut data,
                    min_growth,
                } => {
                    let end = stream_offset as usize + chunk.len();
                    if end > data.len() {
                        if end > data.capacity() {
                            let needed = (end - data.len()).max(min_growth);
                            data.reserve(needed);
                        }
                        data.resize(end, 0);
                    }
                    data[stream_offset as usize..end].copy_from_slice(chunk);
                }
                BufferBackend::Sparse { ref mut chunks, .. } => {
                    insert_and_coalesce_sparse(chunks, stream_offset, chunk);
                }
                BufferBackend::Circular {
                    ref mut storage,
                    capacity,
                    ref mut anchor_offset,
                    ref mut range_start,
                    ref mut range_end,
                    audio_end,
                    ref mut window,
                    ..
                } => {
                    if *range_start == *range_end {
                        *anchor_offset = stream_offset;
                        *range_start = stream_offset;
                        *range_end = stream_offset;
                    } else if stream_offset < *range_start || stream_offset > *range_end {
                        // Non-contiguous jump: re-anchor circular window
                        *anchor_offset = stream_offset;
                        *range_start = stream_offset;
                        *range_end = stream_offset;
                        window.window_filled = false;
                    }

                    let write_end = stream_offset + chunk.len() as u64;
                    if write_end.saturating_sub(*range_start) > capacity as u64
                        && chunk.len() <= capacity
                    {
                        *range_start = write_end - capacity as u64;
                    }

                    let effective_chunk = if chunk.len() > capacity {
                        let skip = chunk.len() - capacity;
                        *range_start = stream_offset + skip as u64;
                        &chunk[skip..]
                    } else {
                        chunk
                    };
                    let write_pos = if chunk.len() > capacity {
                        *range_start
                    } else {
                        stream_offset
                    };

                    let start_idx =
                        (write_pos.saturating_sub(*anchor_offset) as usize) % capacity;
                    let first_len = (capacity - start_idx).min(effective_chunk.len());
                    storage[start_idx..start_idx + first_len]
                        .copy_from_slice(&effective_chunk[..first_len]);
                    if effective_chunk.len() > first_len {
                        let second_len = effective_chunk.len() - first_len;
                        storage[..second_len].copy_from_slice(&effective_chunk[first_len..]);
                    }

                    if write_end > *range_end {
                        *range_end = write_end;
                    }
                    self.refresh_circular_window_fill_locked(
                        *anchor_offset,
                        *range_start,
                        *range_end,
                        audio_end,
                        window,
                    );
                }
            }
        }

        self.is_buffering.store(false, Ordering::Release);
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
        Ok(chunk.len())
    }

    /// Appends sequential `chunk` bytes into a `Circular` buffer (or linear/sparse backend),
    /// enforcing backpressure against `eviction_floor = max(anchor_offset, floor_cursor - back_retention_bytes)`.
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if aborted or [`BufferError::Busy`] if writing `chunk`
    /// would overwrite protected backward-retention data.
    pub fn feed_sequential(
        &self,
        floor_cursor: u64,
        chunk: &[u8],
    ) -> Result<usize, BufferError> {
        if self.should_abort.load(Ordering::Acquire) {
            return Err(BufferError::Aborted);
        }
        if chunk.is_empty() {
            return Ok(0);
        }

        {
            let mut guard = lock_unpoisoned(&self.backend);
            match *guard {
                BufferBackend::Circular {
                    ref mut storage,
                    capacity,
                    anchor_offset,
                    ref mut range_start,
                    ref mut range_end,
                    audio_end,
                    ref mut window,
                    ..
                } => {
                    let cursor = floor_cursor.max(anchor_offset);
                    let eviction_floor = cursor
                        .saturating_sub(window.back_retention_bytes as u64)
                        .max(anchor_offset);
                    let write_offset = *range_end;
                    let write_end = write_offset + chunk.len() as u64;

                    if write_end.saturating_sub(eviction_floor) > capacity as u64 {
                        return Err(BufferError::Busy);
                    }

                    let start_pos =
                        (write_offset.saturating_sub(anchor_offset) as usize) % capacity;
                    let first_len = (capacity - start_pos).min(chunk.len());
                    storage[start_pos..start_pos + first_len]
                        .copy_from_slice(&chunk[..first_len]);
                    if chunk.len() > first_len {
                        let second_len = chunk.len() - first_len;
                        storage[..second_len].copy_from_slice(&chunk[first_len..]);
                    }

                    *range_end = write_end;
                    if range_end.saturating_sub(*range_start) > capacity as u64 {
                        *range_start = *range_end - capacity as u64;
                    }
                    self.refresh_circular_window_fill_locked(
                        anchor_offset,
                        *range_start,
                        *range_end,
                        audio_end,
                        window,
                    );
                }
                BufferBackend::Linear {
                    ref mut data,
                    min_growth,
                } => {
                    if data.len() + chunk.len() > data.capacity() {
                        data.reserve(chunk.len().max(min_growth));
                    }
                    data.extend_from_slice(chunk);
                }
                BufferBackend::Sparse { ref mut chunks, .. } => {
                    let end = chunks
                        .iter()
                        .map(|(&s, d)| s + d.len() as u64)
                        .max()
                        .unwrap_or(0);
                    insert_and_coalesce_sparse(chunks, end, chunk);
                }
            }
        }

        self.is_buffering.store(false, Ordering::Release);
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
        Ok(chunk.len())
    }

    /// Flushes the circular buffer and re-anchors it at `new_stream_offset`, marking `is_buffering = true`.
    pub fn flush_circular(&self, new_stream_offset: u64) {
        crate::map_log!(
            4,
            "[BUFFER] flush_circular new_stream_offset={}",
            new_stream_offset
        );
        {
            let mut guard = lock_unpoisoned(&self.backend);
            if let BufferBackend::Circular {
                ref mut anchor_offset,
                ref mut range_start,
                ref mut range_end,
                ref mut window,
                ..
            } = *guard
            {
                *anchor_offset = new_stream_offset;
                *range_start = new_stream_offset;
                *range_end = new_stream_offset;
                window.window_filled = false;
                window.last_pull_trigger_end = 0;
            }
        }
        self.read_cursor.store(new_stream_offset, Ordering::Release);
        self.is_eof.store(false, Ordering::Release);
        self.is_buffering.store(true, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Non-blocking read at `offset` into `out`.
    ///
    /// - If `is_circular == false` and `offset` is not in memory (and no sync fetcher resolves it),
    ///   returns `Err(BufferError::WouldBlock)` immediately so metadata parsers never stall.
    /// - If `is_circular == true`, evaluates progressive block prefetching and on-demand `fetcher` (`getRealBytes`).
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if aborted or [`BufferError::WouldBlock`] if the requested
    /// range is not currently cached and cannot be fetched synchronously.
    pub fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize, BufferError> {
        if self.should_abort.load(Ordering::Acquire) {
            return Err(BufferError::Aborted);
        }
        if out.is_empty() {
            return Ok(0);
        }

        let mut pending_prefetch: Option<(ByteFetchTask, u64, usize)> = None;
        let cache_miss_fetch: Option<(ByteFetchTask, u64, usize)>;

        {
            let mut guard = lock_unpoisoned(&self.backend);
            match *guard {
                BufferBackend::Linear { ref data, .. } => {
                    if offset < data.len() as u64 {
                        let rel = offset as usize;
                        let avail = data.len() - rel;
                        let to_copy = out.len().min(avail);
                        out[..to_copy].copy_from_slice(&data[rel..rel + to_copy]);
                        return Ok(to_copy);
                    }
                    return if self.is_eof.load(Ordering::Acquire) {
                        Ok(0)
                    } else {
                        Err(BufferError::WouldBlock)
                    };
                }
                BufferBackend::Sparse {
                    ref chunks,
                    virtual_size,
                    ref icy_override,
                    ..
                } => {
                    if !icy_override.is_empty() {
                        if offset >= icy_override.len() as u64 {
                            return Ok(0);
                        }
                        let rel = offset as usize;
                        let avail = icy_override.len() - rel;
                        let to_copy = out.len().min(avail);
                        out[..to_copy].copy_from_slice(&icy_override[rel..rel + to_copy]);
                        return Ok(to_copy);
                    }
                    if let Some(vsize) = virtual_size {
                        if offset >= vsize {
                            return Ok(0);
                        }
                    }
                    if let Some((&start, data)) = chunks.range(..=offset).next_back() {
                        let end = start + data.len() as u64;
                        if offset < end {
                            let rel = (offset - start) as usize;
                            let avail = data.len() - rel;
                            let to_copy = out.len().min(avail);
                            out[..to_copy].copy_from_slice(&data[rel..rel + to_copy]);
                            return Ok(to_copy);
                        }
                    }
                    return Err(BufferError::WouldBlock);
                }
                BufferBackend::Circular {
                    ref storage,
                    capacity,
                    anchor_offset,
                    range_start,
                    range_end,
                    audio_end,
                    ref mut window,
                    push_streaming,
                    ref fetcher,
                } => {
                    if let Some(end) = audio_end {
                        if offset >= end {
                            return Ok(0);
                        }
                    }

                    if offset >= range_start && offset < range_end {
                        let effective_end = audio_end.map(|e| range_end.min(e)).unwrap_or(range_end);
                        if offset >= effective_end {
                            return Ok(0);
                        }
                        let avail = (effective_end - offset) as usize;
                        let to_copy = out.len().min(avail);
                        let rel_pos = (offset.saturating_sub(anchor_offset) as usize) % capacity;
                        let first_len = (capacity - rel_pos).min(to_copy);
                        out[..first_len]
                            .copy_from_slice(&storage[rel_pos..rel_pos + first_len]);
                        if to_copy > first_len {
                            let second_len = to_copy - first_len;
                            out[first_len..to_copy].copy_from_slice(&storage[..second_len]);
                        }

                        // Proactive progressive block prefetch (when in pull mode without active push thread)
                        let new_cursor = offset + to_copy as u64;
                        let is_eof = self.is_eof.load(Ordering::Acquire);
                        if !push_streaming && window.last_pull_trigger_end < range_end {
                            if let Some(ref f) = fetcher {
                                if let Some(order) = Self::compute_next_block_order_locked(
                                    new_cursor,
                                    capacity,
                                    anchor_offset,
                                    range_start,
                                    range_end,
                                    audio_end,
                                    is_eof,
                                    window,
                                ) {
                                    window.last_pull_trigger_end = range_end;
                                    pending_prefetch =
                                        Some((f.clone(), order.offset, order.length));
                                }
                            }
                        }

                        drop(guard);
                        if let Some((fetch_fn, f_pos, f_len)) = pending_prefetch {
                            match fetch_fn(f_pos, f_len) {
                                Ok(bytes) if !bytes.is_empty() => {
                                    let _ = self.commit_chunk(f_pos, &bytes);
                                }
                                Ok(_) => {}
                                Err(e) => {
                                    crate::map_log!(
                                        2,
                                        "[BUFFER] read_at prefetch fetch error at offset={}, len={}: {}",
                                        f_pos,
                                        f_len,
                                        e
                                    );
                                }
                            }
                        }
                        return Ok(to_copy);
                    }

                    if self.is_eof.load(Ordering::Acquire) && offset >= range_end {
                        return Ok(0);
                    }

                    let is_far_jump =
                        offset < range_start || offset > range_end.saturating_add(262144);
                    if let Some(ref f) = fetcher {
                        if !push_streaming || is_far_jump {
                            self.is_buffering.store(true, Ordering::Release);
                            let mut fetch_len =
                                window.base_window_bytes.max(out.len()).min(capacity);
                            if let Some(end) = audio_end {
                                fetch_len = fetch_len.min(end.saturating_sub(offset) as usize);
                            }
                            cache_miss_fetch = Some((f.clone(), offset, fetch_len));
                        } else {
                            self.is_buffering.store(true, Ordering::Release);
                            return Err(BufferError::WouldBlock);
                        }
                    } else {
                        self.is_buffering.store(true, Ordering::Release);
                        return Err(BufferError::WouldBlock);
                    }
                }
            }
        }

        // Execute cache-miss `getRealBytes(position, size)` completely outside the lock
        if let Some((fetch_fn, f_pos, f_len)) = cache_miss_fetch {
            crate::map_log!(
                4,
                "[BUFFER] read_at cache-miss fetch offset={}, len={}",
                f_pos,
                f_len
            );
            match fetch_fn(f_pos, f_len) {
                Ok(bytes) if !bytes.is_empty() => {
                    let _ = self.commit_chunk(f_pos, &bytes);
                    // Re-read now that data is committed
                    let guard = lock_unpoisoned(&self.backend);
                    if let BufferBackend::Circular {
                        ref storage,
                        capacity,
                        anchor_offset,
                        range_start,
                        range_end,
                        audio_end,
                        ..
                    } = *guard
                    {
                        if offset >= range_start && offset < range_end {
                            let effective_end =
                                audio_end.map(|e| range_end.min(e)).unwrap_or(range_end);
                            if offset >= effective_end {
                                return Ok(0);
                            }
                            let avail = (effective_end - offset) as usize;
                            let to_copy = out.len().min(avail);
                            let rel_pos =
                                (offset.saturating_sub(anchor_offset) as usize) % capacity;
                            let first_len = (capacity - rel_pos).min(to_copy);
                            out[..first_len]
                                .copy_from_slice(&storage[rel_pos..rel_pos + first_len]);
                            if to_copy > first_len {
                                let second_len = to_copy - first_len;
                                out[first_len..to_copy]
                                    .copy_from_slice(&storage[..second_len]);
                            }
                            return Ok(to_copy);
                        }
                    }
                }
                Ok(_) => {
                    if !self.is_circular {
                        return Ok(0);
                    }
                }
                Err(e) => {
                    crate::map_log!(
                        2,
                        "[BUFFER] read_at cache-miss fetch error at offset={}, len={}: {}",
                        f_pos,
                        f_len,
                        e
                    );
                    return Err(BufferError::WouldBlock);
                }
            }
        }

        Err(BufferError::WouldBlock)
    }

    /// Blocking read at `offset` into `out` with reactive `Condvar` suspension up to `timeout`
    /// while awaiting stream bytes.
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if aborted or [`BufferError::WouldBlock`] if `timeout`
    /// elapses (or immediately on non-circular buffers when uncached).
    pub fn read_blocking(
        &self,
        offset: u64,
        out: &mut [u8],
        timeout: Option<Duration>,
    ) -> Result<usize, BufferError> {
        let max_wait = timeout.unwrap_or(Duration::from_millis(2000));
        let start_time = MonotonicInstant::now();

        loop {
            match self.read_at(offset, out) {
                Ok(n) => return Ok(n),
                Err(BufferError::WouldBlock) => {
                    if !self.is_circular {
                        return Err(BufferError::WouldBlock);
                    }
                    if self.should_abort.load(Ordering::Acquire) {
                        return Err(BufferError::Aborted);
                    }
                    if self.is_eof.load(Ordering::Acquire) {
                        return Ok(0);
                    }

                    let elapsed = start_time.elapsed();
                    if elapsed >= max_wait {
                        crate::map_log!(
                            2,
                            "[BUFFER] StreamBuffer::read_blocking timed out at offset={} after {:?}",
                            offset,
                            max_wait
                        );
                        return Err(BufferError::WouldBlock);
                    }
                    let remaining = max_wait - elapsed;
                    let slice_wait = remaining.min(Duration::from_millis(20));
                    let guard = lock_unpoisoned(&self.backend);
                    if self.should_abort.load(Ordering::Acquire) {
                        return Err(BufferError::Aborted);
                    }
                    let _ = self.data_signal.wait_timeout(guard, slice_wait);
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Updates dynamic ICY stream metadata `data` in a `Sparse` metadata buffer.
    pub fn set_icy_meta(&self, data: &[u8]) {
        {
            let mut guard = lock_unpoisoned(&self.backend);
            if let BufferBackend::Sparse {
                ref mut icy_override,
                ..
            } = *guard
            {
                icy_override.clear();
                icy_override.extend_from_slice(data);
            }
        }
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Synthesizes a contiguous metadata byte snapshot from a `Sparse` metadata buffer.
    pub fn synthesize_meta_bytes(&self) -> Vec<u8> {
        let guard = lock_unpoisoned(&self.backend);
        match *guard {
            BufferBackend::Sparse {
                ref chunks,
                ref icy_override,
                ..
            } => {
                if !icy_override.is_empty() {
                    return icy_override.clone();
                }
                let total_cap: usize = chunks.values().map(|v| v.len()).sum();
                if total_cap == 0 {
                    return Vec::new();
                }
                let mut out = Vec::with_capacity(total_cap);
                /// Sony Wave64 RIFF container GUID (`riff....`).
                const W64_RIFF_GUID: [u8; 16] = [
                    0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04,
                    0xc1, 0x00, 0x00,
                ];
                /// Sony Wave64 `data` chunk GUID.
                const W64_DATA_GUID: [u8; 16] = [
                    0x64, 0x61, 0x74, 0x61, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04,
                    0xc1, 0x00, 0x00,
                ];
                for (&offset, chunk) in chunks.iter() {
                    if offset == 0 {
                        out.extend_from_slice(chunk);
                        let head_len = out.len();
                        if head_len >= 12
                            && (out.starts_with(b"RIFF") || out.starts_with(b"RF64"))
                            && &out[8..12] == b"WAVE"
                            && &out[head_len - 8..head_len - 4] == b"data"
                        {
                            out[head_len - 4..head_len].copy_from_slice(&0u32.to_le_bytes());
                        } else if head_len >= 12
                            && out.starts_with(b"RIFX")
                            && &out[8..12] == b"WAVE"
                            && &out[head_len - 8..head_len - 4] == b"data"
                        {
                            out[head_len - 4..head_len].copy_from_slice(&0u32.to_be_bytes());
                        } else if head_len >= 64
                            && out[0..16] == W64_RIFF_GUID
                            && out[head_len - 24..head_len - 8] == W64_DATA_GUID
                        {
                            out[head_len - 8..head_len].copy_from_slice(&24u64.to_le_bytes());
                        } else if head_len >= 20
                            && out.starts_with(b"FORM")
                            && (&out[8..12] == b"AIFF" || &out[8..12] == b"AIFC")
                            && &out[head_len - 8..head_len - 4] == b"SSND"
                        {
                            out[head_len - 4..head_len].copy_from_slice(&0u32.to_be_bytes());
                        } else if head_len >= 16 && &out[4..8] == b"ftyp" {
                            if &out[head_len - 4..head_len] == b"mdat" {
                                out[head_len - 8..head_len - 4]
                                    .copy_from_slice(&8u32.to_be_bytes());
                            } else if &out[head_len - 12..head_len - 8] == b"mdat" {
                                out[head_len - 8..head_len]
                                    .copy_from_slice(&16u64.to_be_bytes());
                            }
                        }
                    } else {
                        out.extend_from_slice(chunk);
                    }
                }
                if out.len() >= 12
                    && out.starts_with(b"FORM")
                    && (&out[8..12] == b"AIFF" || &out[8..12] == b"AIFC")
                {
                    let form_sz = (out.len().saturating_sub(8) as u32).to_be_bytes();
                    out[4..8].copy_from_slice(&form_sz);
                }
                out
            }
            BufferBackend::Linear { ref data, .. } => data.clone(),
            BufferBackend::Circular { .. } => Vec::new(),
        }
    }

    /// Returns `(range_start, range_end, capacity)` for a `Circular` buffer.
    pub fn circular_metrics(&self) -> (u64, u64, usize) {
        let guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            range_start,
            range_end,
            capacity,
            ..
        } = *guard
        {
            (range_start, range_end, capacity)
        } else {
            (0, 0, 1)
        }
    }
}

/// RAII guard enabling isolated container/seek probe reads without flushing the `Body` ring.
pub struct ProbeGuard {
    /// Shared active probe nesting depth counter decremented when this guard is dropped.
    depth: Arc<AtomicUsize>,
}

impl Drop for ProbeGuard {
    /// Decrements the active probe depth counter upon leaving the probe scope.
    fn drop(&mut self) {
        self.depth.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Callback fetching up to `len` bytes starting at `offset` for isolated probe/seek reads.
pub type ProbeFetcherFn = Arc<dyn Fn(u64, usize) -> Option<Vec<u8>> + Send + Sync>;

/// Single cached byte page stored in [`ProbePageCache`].
struct ProbePage {
    /// Absolute stream byte offset where `data` starts.
    offset: u64,
    /// Cached byte slice fetched at `offset`.
    data: Vec<u8>,
}

/// Bounded FIFO page cache backing isolated container/seek probe reads without disturbing `Body`.
#[derive(Default)]
struct ProbePageCache {
    /// Cached pages ordered from oldest (`front`) to most recently inserted (`back`).
    pages: VecDeque<ProbePage>,
}

impl ProbePageCache {
    /// Default page size (64 KB) aligned for probe/seek range fetches.
    const PAGE_SIZE: usize = 64 * 1024;
    /// Maximum number of pages retained in the cache before FIFO eviction.
    const MAX_PAGES: usize = 48;

    /// Copies cached bytes starting at `offset` into `out`, returning the byte count copied (`0` on miss).
    fn read_cached(&self, offset: u64, out: &mut [u8]) -> usize {
        if out.is_empty() {
            return 0;
        }
        for page in &self.pages {
            let page_end = page.offset.saturating_add(page.data.len() as u64);
            if offset >= page.offset && offset < page_end {
                let start = (offset - page.offset) as usize;
                let avail = page.data.len() - start;
                let to_copy = avail.min(out.len());
                out[..to_copy].copy_from_slice(&page.data[start..start + to_copy]);
                return to_copy;
            }
        }
        0
    }

    /// Inserts `data` at `offset`, replacing any existing page at `offset` and evicting the oldest page if full.
    fn insert(&mut self, offset: u64, data: Vec<u8>) {
        if data.is_empty() {
            return;
        }
        self.pages.retain(|p| p.offset != offset);
        if self.pages.len() >= Self::MAX_PAGES {
            self.pages.pop_front();
        }
        self.pages.push_back(ProbePage { offset, data });
    }

    /// Removes all cached probe pages.
    fn clear(&mut self) {
        self.pages.clear();
    }
}

/// Container-specific framing parameters for exact in-RAM buffered range scanning.
#[derive(Debug, Clone)]
pub enum BufferedBoundaryKind {
    /// No container-specific frame snapping; uses raw `ByteTimeMap` interpolation.
    None,
    /// Ogg bitstream framing parameters for page-boundary scanning.
    Ogg {
        /// Logical bitstream serial number to match during Ogg page scans.
        serial: u32,
        /// Audio sample rate in Hz used to convert granule positions to milliseconds.
        sample_rate: u32,
        /// Initial codec pre-skip samples subtracted from granule positions.
        pre_skip: u64,
    },
    /// Native FLAC framing parameters for frame-header scanning.
    Flac {
        /// Stream sample rate in Hz.
        sample_rate: u32,
        /// Minimum block size in samples from `STREAMINFO`.
        min_bs: u16,
        /// Maximum block size in samples from `STREAMINFO`.
        max_bs: u16,
    },
    /// WavPack block framing parameters for block-header scanning.
    WavPack {
        /// Stream sample rate in Hz.
        sample_rate: u32,
    },
    /// Matroska/WebM container framing parameters for Cluster scanning.
    Mkv {
        /// Matroska `TimecodeScale` in nanoseconds per tick.
        timecode_scale_ns: u64,
    },
    /// MP3 stream with Xing/LAME VBR timing, applying a conservative tail safety margin.
    Mp3Xing,
    /// Sorted exact frame boundaries `(byte_offset, start_ms)` with terminal `(end_byte, dur_ms)`.
    ExactFrames(Vec<(u64, i64)>),
}

/// Coordinates the three independent [`StreamBuffer`] instances (`Head`, `Body`, `Metadata`)
/// for an active media stream.
#[derive(Clone)]
pub struct StreamSession {
    /// Non-circular linear buffer holding minimal container & codec setup headers.
    pub head: Arc<StreamBuffer>,
    /// Circular ring buffer holding framed audio clusters/packets with watermark prefetch.
    pub body: Arc<StreamBuffer>,
    /// Non-circular sparse virtual buffer holding metadata tags, artwork, and ICY updates.
    pub metadata: Arc<StreamBuffer>,
    /// Stream byte offset where audio payload begins.
    audio_start: Arc<AtomicU64>,
    /// Stream byte offset where audio payload ends (`u64::MAX` if unbounded).
    audio_end: Arc<AtomicU64>,
    /// Total stream byte length, if known.
    total_size: Option<u64>,
    /// Whether this session represents an unbounded live broadcast.
    is_live: bool,
    /// Whether the active consumer is currently decoding audio frames.
    is_decoding_audio: Arc<AtomicBool>,
    /// Whether the byte source honors random-access range requests (`HTTP 206`).
    supports_range: Arc<AtomicBool>,
    /// Active reentrant probe depth (container open or demuxer seek-table inspection).
    probe_depth: Arc<AtomicUsize>,
    /// Nesting depth temporarily suspending isolated probe mode for sequential `Body` streaming.
    probe_suspend_depth: Arc<AtomicUsize>,
    /// Optional on-demand range fetcher for isolated probe/seek reads.
    probe_fetcher: Arc<RwLock<Option<ProbeFetcherFn>>>,
    /// Bounded page cache backing isolated probe/seek reads without disturbing the `Body` ring.
    probe_cache: Arc<Mutex<ProbePageCache>>,
    /// Whether end-of-audio tags live inside the container tail (`moov`) rather than stripped tags.
    has_container_tail: Arc<AtomicBool>,
    /// Piecewise monotonic byte-to-millisecond anchor map for accurate buffered telemetry.
    byte_time_map: Arc<RwLock<ByteTimeMap>>,
    /// Accumulated FLAC `(file_byte_offset, sample_number)` points for synthetic SEEKTABLE generation.
    flac_seek_points: Arc<Mutex<Vec<(u64, u64)>>>,
    /// True when original container header already contained a native FLAC `SEEKTABLE` block.
    has_native_flac_seektable: Arc<AtomicBool>,
    /// Most recent `flush_circular` stream byte offset.
    last_flush_target: Arc<AtomicU64>,
    /// Monotonic counter incremented every time `flush_circular` executes on this session.
    last_flush_seq: Arc<AtomicU64>,
    /// Most recent seek target byte observed while in `probe_mode` (`u64::MAX` if unset).
    probe_seek_target: Arc<AtomicU64>,
    /// Cursor position following the most recent probe seek read.
    probe_read_end: Arc<AtomicU64>,
    /// Latest seek generation published by the engine dispatcher.
    latest_seek_gen: Arc<AtomicU64>,
    /// Highest seek generation already dequeued/acknowledged by `DecoderWorker`.
    ack_seek_gen: Arc<AtomicU64>,
    /// Optional HLS VOD lookahead & segment-jump controller.
    hls_vod: Arc<RwLock<Option<Arc<HlsVodState>>>>,
    /// Container framing configuration used to snap `[start_ms, end_ms]` to complete in-RAM units.
    boundary_kind: Arc<RwLock<BufferedBoundaryKind>>,
    /// Cached `(r_start, r_end, is_eof, start_ms, end_ms)` from the most recent boundary scan.
    last_mapped_window: Arc<Mutex<Option<(u64, u64, bool, i64, i64)>>>,
    /// When `true`, non-Range streams that fit in `Body` disable the 30s lookahead cap so the full track stays in RAM.
    full_file_prefetch: Arc<AtomicBool>,
    /// Monotonic counter incremented on non-Range forward/backward HTTP stream drain chunks so `read_blocking` stays alive while draining.
    drain_progress_seq: Arc<AtomicU64>,
}

/// Segment metadata descriptor for bounded-lookahead HLS VOD streaming and instant segment seek.
#[derive(Debug, Clone)]
pub struct HlsVodSegment {
    /// Resolved segment URL or local path.
    pub url: String,
    /// Optional explicit HTTP byte range `(offset, len)`.
    pub byte_range: Option<(u64, u64)>,
    /// Cumulative start timestamp in milliseconds inside the VOD playlist.
    pub start_ms: i64,
    /// Segment duration in milliseconds.
    pub duration_ms: i64,
}

/// Action returned to the HLS VOD background streamer loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VodAction {
    /// A pending seek jump must be accepted before fetching any more segments.
    JumpPending,
    /// Fetch segment index `0` under jump epoch `1`.
    FetchSegment(usize, u64),
    /// Lookahead target is satisfied; wait until cursor advances or a jump arrives.
    Sleep,
    /// Reached end of playlist for `current_epoch`.
    Eof {
        /// Whether `session.mark_eof()` was already called for this run.
        already_marked: bool,
        /// Active jump epoch at EOF.
        current_epoch: u64,
    },
}

/// Mutex-protected mutable state of an [`HlsVodState`] prefetch and seek coordinator.
struct HlsVodInner {
    /// Index of the next playlist segment to fetch sequentially.
    next_fetch_idx: usize,
    /// End timestamp in milliseconds of the furthest fetched segment in the current epoch.
    loaded_end_ms: i64,
    /// Cumulative byte offset in the body ring reached by segments committed in the current epoch.
    cum_bytes: u64,
    /// Cumulative media timestamp in milliseconds reached by segments committed in the current epoch.
    cum_ms: i64,
    /// Active jump epoch currently being fetched by the background streamer.
    current_epoch: u64,
    /// Highest jump epoch whose ring flush and window reset have completed.
    accepted_epoch: u64,
    /// Queued `(segment_index, epoch)` jump waiting for the streamer to acknowledge.
    pending_jump: Option<(usize, u64)>,
    /// True once EOF has been dispatched for `current_epoch`.
    eof_marked: bool,
    /// Ordered `(seg_idx, byte_start, byte_end, start_ms, end_ms)` spans fed into the ring.
    fed_spans: Vec<(usize, u64, u64, i64, i64)>,
    /// Bounded FIFO cache of `(seg_idx, raw_bytes)` for fast backward segment seeks.
    cached_segments: VecDeque<(usize, Vec<u8>)>,
}

/// Shared synchronization controller coordinating bounded HLS VOD prefetching and segment-level seeks.
pub struct HlsVodState {
    /// Ordered list of media segments in the VOD playlist.
    segments: Vec<HlsVodSegment>,
    /// Total VOD playlist duration in milliseconds.
    total_duration_ms: i64,
    /// Initial stream byte offset where demuxed audio payload starts.
    audio_start_offset: u64,
    /// Bounded forward lookahead window target in milliseconds.
    lookahead_ms: i64,
    /// Current playback cursor position in milliseconds.
    cursor_ms: AtomicI64,
    /// Atomic mirror of `inner.loaded_end_ms` for lock-free lookahead checks.
    loaded_end_ms_atomic: AtomicI64,
    /// Monotonic counter incremented on each requested segment jump.
    jump_epoch: AtomicU64,
    /// Mutex-protected HLS VOD fetch and jump state.
    inner: Mutex<HlsVodInner>,
    /// Condition variable waking the streamer and seek waiters.
    wake: Condvar,
}

impl HlsVodState {
    /// Default bounded forward prefetch window in milliseconds (`30s`, ~3 segments on 10s HLS).
    pub const DEFAULT_LOOKAHEAD_MS: i64 = 30_000;
    /// Maximum number of downloaded HLS segments retained in the in-memory FIFO cache.
    const MAX_CACHED_SEGMENTS: usize = 8;

    /// Initializes HLS VOD state from `segments`, `total_duration_ms`, and `audio_start_offset`
    /// right after segment `0` (`first_segment_bytes`, ending at `first_body_end` with `first_dur_ms`)
    /// has been pushed into the session.
    pub fn new(
        segments: Vec<HlsVodSegment>,
        total_duration_ms: i64,
        audio_start_offset: u64,
        first_segment_bytes: Vec<u8>,
        first_body_end: u64,
        first_dur_ms: i64,
    ) -> Arc<Self> {
        crate::map_log!(
            3,
            "[HLS_VOD] HlsVodState::new segments={}, total_duration_ms={}, audio_start={}",
            segments.len(),
            total_duration_ms,
            audio_start_offset
        );
        let mut cached = VecDeque::with_capacity(Self::MAX_CACHED_SEGMENTS);
        cached.push_back((0, first_segment_bytes));
        let fed_spans = vec![(0, audio_start_offset, first_body_end, 0, first_dur_ms)];
        Arc::new(Self {
            segments,
            total_duration_ms: total_duration_ms.max(first_dur_ms),
            audio_start_offset,
            lookahead_ms: Self::DEFAULT_LOOKAHEAD_MS,
            cursor_ms: AtomicI64::new(0),
            loaded_end_ms_atomic: AtomicI64::new(first_dur_ms),
            jump_epoch: AtomicU64::new(0),
            inner: Mutex::new(HlsVodInner {
                next_fetch_idx: 1,
                loaded_end_ms: first_dur_ms,
                cum_bytes: first_body_end,
                cum_ms: first_dur_ms,
                current_epoch: 0,
                accepted_epoch: 0,
                pending_jump: None,
                eof_marked: false,
                fed_spans,
                cached_segments: cached,
            }),
            wake: Condvar::new(),
        })
    }

    /// Returns total VOD playlist duration in milliseconds.
    #[inline]
    pub fn total_duration_ms(&self) -> i64 {
        self.total_duration_ms
    }

    /// Returns configured initial audio start offset.
    #[inline]
    pub fn audio_start_offset(&self) -> u64 {
        self.audio_start_offset
    }

    /// Returns segment index whose `[start_ms, end_ms)` contains `target_ms`.
    pub fn segment_for_ms(&self, target_ms: i64) -> usize {
        if self.segments.is_empty() {
            return 0;
        }
        let clamped = target_ms.max(0);
        let idx = self
            .segments
            .partition_point(|s| s.start_ms <= clamped)
            .saturating_sub(1);
        idx.min(self.segments.len() - 1)
    }

    /// Returns the segment descriptor at `idx`, if in bounds.
    #[inline]
    pub fn segment(&self, idx: usize) -> Option<&HlsVodSegment> {
        self.segments.get(idx)
    }

    /// Updates playback cursor timestamp `ms` and wakes the streamer when lookahead falls below target.
    pub fn update_cursor_ms(&self, ms: i64) {
        let clamped = ms.max(0);
        self.cursor_ms.store(clamped, Ordering::Release);
        if clamped.saturating_add(self.lookahead_ms)
            > self.loaded_end_ms_atomic.load(Ordering::Acquire)
        {
            let _guard = lock_unpoisoned(&self.inner);
            self.wake.notify_all();
        }
    }

    /// Checks whether `seg_idx` already resides cleanly inside `[r_start, r_end)` of the body ring.
    pub fn find_in_ring_span(&self, seg_idx: usize, r_start: u64, r_end: u64) -> Option<(u64, i64)> {
        let guard = lock_unpoisoned(&self.inner);
        guard
            .fed_spans
            .iter()
            .find(|&&(idx, b_start, b_end, _, _)| {
                idx == seg_idx && b_start >= r_start && b_end <= r_end
            })
            .map(|&(_, b_start, _, s_ms, _)| (b_start, s_ms))
    }

    /// Returns conservative `(start_ms, end_ms)` across all HLS VOD segments whose complete bytes
    /// reside inside `[r_start, r_end)`.
    pub fn resident_ms_bounds(&self, r_start: u64, r_end: u64) -> Option<(i64, i64)> {
        let guard = lock_unpoisoned(&self.inner);
        let mut first_ms: Option<i64> = None;
        let mut last_ms: Option<i64> = None;
        for &(_, b_start, b_end, s_ms, e_ms) in &guard.fed_spans {
            if b_start >= r_start && b_end <= r_end {
                if first_ms.is_none() {
                    first_ms = Some(s_ms);
                }
                last_ms = Some(e_ms);
            }
        }
        match (first_ms, last_ms) {
            (Some(s), Some(e)) if e > s => Some((s, e)),
            _ => None,
        }
    }

    /// Requests jumping the HLS VOD download window to `seg_idx`. Returns the new monotonic jump epoch.
    pub fn request_jump(&self, seg_idx: usize) -> u64 {
        let clamped_idx = seg_idx.min(self.segments.len().saturating_sub(1));
        let mut guard = lock_unpoisoned(&self.inner);
        let epoch = self.jump_epoch.fetch_add(1, Ordering::AcqRel) + 1;
        guard.pending_jump = Some((clamped_idx, epoch));
        crate::map_log!(
            4,
            "[HLS_VOD] request_jump seg_idx={}, epoch={}",
            clamped_idx,
            epoch
        );
        self.wake.notify_all();
        epoch
    }

    /// Waits in short slices until `streamer` has flushed and accepted `epoch`, or `is_aborted()` triggers.
    pub fn wait_jump_accepted<F: Fn() -> bool>(&self, epoch: u64, is_aborted: F) -> bool {
        let mut guard = lock_unpoisoned(&self.inner);
        loop {
            if guard.accepted_epoch >= epoch {
                return true;
            }
            if is_aborted() {
                return false;
            }
            let (g, _) = wait_timeout_unpoisoned(&self.wake, guard, Duration::from_millis(10));
            guard = g;
        }
    }

    /// Returns true once a newer jump epoch has been issued after `epoch`.
    #[inline]
    pub fn is_epoch_stale(&self, epoch: u64) -> bool {
        self.jump_epoch.load(Ordering::Acquire) != epoch
    }

    /// Pops any pending jump target and reinitializes VOD cursor/window metadata prior to flushing `session`.
    pub fn take_pending_jump(&self) -> Option<(usize, u64, i64)> {
        let mut guard = lock_unpoisoned(&self.inner);
        let (seg_idx, epoch) = guard.pending_jump.take()?;
        let start_ms = self.segments.get(seg_idx).map(|s| s.start_ms).unwrap_or(0);
        guard.current_epoch = epoch;
        guard.next_fetch_idx = seg_idx;
        guard.loaded_end_ms = start_ms;
        guard.cum_bytes = self.audio_start_offset;
        guard.cum_ms = start_ms;
        guard.eof_marked = false;
        guard.fed_spans.clear();
        self.loaded_end_ms_atomic.store(start_ms, Ordering::Release);
        self.cursor_ms.store(start_ms, Ordering::Release);
        crate::map_log!(
            4,
            "[HLS_VOD] take_pending_jump seg_idx={}, epoch={}, start_ms={}",
            seg_idx,
            epoch,
            start_ms
        );
        Some((seg_idx, epoch, start_ms))
    }

    /// Marks `epoch` accepted after `session.flush` and `reset_hls_vod_window` complete, waking `DecoderWorker`.
    pub fn mark_jump_accepted(&self, epoch: u64) {
        let mut guard = lock_unpoisoned(&self.inner);
        guard.accepted_epoch = guard.accepted_epoch.max(epoch);
        crate::map_log!(4, "[HLS_VOD] mark_jump_accepted epoch={}", epoch);
        self.wake.notify_all();
    }

    /// Determines the next action for the HLS VOD background streamer thread.
    pub fn next_action(&self) -> VodAction {
        let guard = lock_unpoisoned(&self.inner);
        if guard.pending_jump.is_some() {
            return VodAction::JumpPending;
        }
        if guard.next_fetch_idx < self.segments.len() {
            let cursor = self.cursor_ms.load(Ordering::Acquire);
            if guard.loaded_end_ms < cursor.saturating_add(self.lookahead_ms) {
                return VodAction::FetchSegment(guard.next_fetch_idx, guard.current_epoch);
            }
            return VodAction::Sleep;
        }
        VodAction::Eof {
            already_marked: guard.eof_marked,
            current_epoch: guard.current_epoch,
        }
    }

    /// Marks EOF dispatched for `epoch` so repeated loop wakes do not spam `mark_eof`.
    pub fn mark_eof_sent(&self, epoch: u64) {
        let mut guard = lock_unpoisoned(&self.inner);
        if guard.current_epoch == epoch {
            guard.eof_marked = true;
        }
    }

    /// Returns a cloned copy of `seg_idx` audio bytes if already cached in memory.
    pub fn get_cached_segment(&self, seg_idx: usize) -> Option<Vec<u8>> {
        let guard = lock_unpoisoned(&self.inner);
        guard
            .cached_segments
            .iter()
            .find(|(idx, _)| *idx == seg_idx)
            .map(|(_, bytes)| bytes.clone())
    }

    /// Stores downloaded segment `bytes` for `seg_idx` in a bounded FIFO cache so local backward
    /// seeks avoid HTTP fetches.
    pub fn put_cached_segment(&self, seg_idx: usize, bytes: Vec<u8>) {
        let mut guard = lock_unpoisoned(&self.inner);
        if guard.cached_segments.iter().any(|(idx, _)| *idx == seg_idx) {
            return;
        }
        if guard.cached_segments.len() >= Self::MAX_CACHED_SEGMENTS {
            guard.cached_segments.pop_front();
        }
        guard.cached_segments.push_back((seg_idx, bytes));
    }

    /// Records a newly fetched `seg_idx` of `payload_len` bytes and `duration_ms` under `epoch`,
    /// returning `(end_byte, end_ms)` when `epoch` is still current.
    pub fn commit_segment_span(
        &self,
        epoch: u64,
        seg_idx: usize,
        payload_len: usize,
        duration_ms: i64,
    ) -> Option<(u64, i64)> {
        let mut guard = lock_unpoisoned(&self.inner);
        if guard.current_epoch != epoch || self.jump_epoch.load(Ordering::Acquire) != epoch {
            return None;
        }
        let byte_start = guard.cum_bytes;
        let byte_end = byte_start.saturating_add(payload_len as u64);
        let start_ms = guard.cum_ms;
        let end_ms = start_ms.saturating_add(duration_ms.max(0));
        guard.cum_bytes = byte_end;
        guard.cum_ms = end_ms;
        guard.loaded_end_ms = end_ms;
        guard.next_fetch_idx = seg_idx + 1;
        guard
            .fed_spans
            .push((seg_idx, byte_start, byte_end, start_ms, end_ms));
        self.loaded_end_ms_atomic.store(end_ms, Ordering::Release);
        Some((byte_end, end_ms))
    }

    /// Sleeps up to `timeout` waiting for playback lookahead demand, a jump request, or wake notification.
    pub fn wait_for_demand(&self, timeout: Duration) {
        let guard = lock_unpoisoned(&self.inner);
        if guard.pending_jump.is_some() {
            return;
        }
        let _ = wait_timeout_unpoisoned(&self.wake, guard, timeout);
    }

    /// Wakes any waiters on this controller (used on abort/stop).
    pub fn notify_all(&self) {
        let _guard = lock_unpoisoned(&self.inner);
        self.wake.notify_all();
    }
}

impl StreamSession {
    /// Default circular audio ring capacity (8 MB).
    pub const DEFAULT_RING_CAPACITY: usize = StreamBuffer::DEFAULT_BODY_CAPACITY;

    /// Creates a new three-buffer `StreamSession` with `capacity_bytes`, optional `total_size`,
    /// and `is_live` flag using the default sliding-window configuration.
    pub fn new(capacity_bytes: usize, total_size: Option<u64>, is_live: bool) -> Self {
        Self::with_config(
            capacity_bytes,
            total_size,
            is_live,
            SlidingWindowConfig::default(),
            None,
        )
    }

    /// Creates a new three-buffer `StreamSession` with `capacity_bytes`, optional `total_size`,
    /// `is_live` mode, custom sliding-window `config`, and optional pull-mode `fetcher`.
    pub fn with_config(
        capacity_bytes: usize,
        total_size: Option<u64>,
        is_live: bool,
        config: SlidingWindowConfig,
        fetcher: Option<ByteFetchTask>,
    ) -> Self {
        crate::map_log!(
            3,
            "[SESSION] StreamSession::with_config capacity={}, total_size={:?}, is_live={}",
            capacity_bytes,
            total_size,
            is_live
        );
        let head = StreamBuffer::new_linear(
            StreamBuffer::DEFAULT_HEAD_INITIAL_SIZE,
            StreamBuffer::DEFAULT_MIN_GROWTH,
        );
        let body = StreamBuffer::new_circular(capacity_bytes, config, fetcher);
        {
            let mut guard = lock_unpoisoned(&body.backend);
            if let BufferBackend::Circular { ref mut window, .. } = *guard {
                window.is_live = is_live;
            }
        }
        let metadata = StreamBuffer::new_sparse(StreamBuffer::DEFAULT_MIN_GROWTH, total_size);

        let session = Self {
            head,
            body,
            metadata,
            audio_start: Arc::new(AtomicU64::new(0)),
            audio_end: Arc::new(AtomicU64::new(u64::MAX)),
            total_size,
            is_live,
            is_decoding_audio: Arc::new(AtomicBool::new(false)),
            supports_range: Arc::new(AtomicBool::new(false)),
            probe_depth: Arc::new(AtomicUsize::new(0)),
            probe_suspend_depth: Arc::new(AtomicUsize::new(0)),
            probe_fetcher: Arc::new(RwLock::new(None)),
            probe_cache: Arc::new(Mutex::new(ProbePageCache::default())),
            has_container_tail: Arc::new(AtomicBool::new(false)),
            byte_time_map: Arc::new(RwLock::new(ByteTimeMap::new(
                0,
                total_size.unwrap_or(0),
                0,
            ))),
            flac_seek_points: Arc::new(Mutex::new(Vec::new())),
            has_native_flac_seektable: Arc::new(AtomicBool::new(false)),
            last_flush_target: Arc::new(AtomicU64::new(0)),
            last_flush_seq: Arc::new(AtomicU64::new(0)),
            probe_seek_target: Arc::new(AtomicU64::new(u64::MAX)),
            probe_read_end: Arc::new(AtomicU64::new(0)),
            latest_seek_gen: Arc::new(AtomicU64::new(0)),
            ack_seek_gen: Arc::new(AtomicU64::new(0)),
            hls_vod: Arc::new(RwLock::new(None)),
            boundary_kind: Arc::new(RwLock::new(BufferedBoundaryKind::None)),
            last_mapped_window: Arc::new(Mutex::new(None)),
            full_file_prefetch: Arc::new(AtomicBool::new(false)),
            drain_progress_seq: Arc::new(AtomicU64::new(0)),
        };
        if let Some(tot) = total_size {
            session.body.set_audio_end(Some(tot));
        }
        session
    }

    /// Returns the sliding-window configuration used when full-file RAM prefetch is active.
    #[inline]
    fn full_file_prefetch_window_config() -> SlidingWindowConfig {
        SlidingWindowConfig {
            back_duration_ms: 0,
            ahead_duration_ms: 3_600_000,
            window_duration_ms: 5_000,
            coalesce_windows: 1,
        }
    }

    /// Marks active drain progress during non-Range stream repositioning so `read_blocking`
    /// resets its idle timeout while bytes are steadily discarded toward a seek target.
    #[inline]
    pub fn note_drain_progress(&self) {
        self.drain_progress_seq.fetch_add(1, Ordering::Release);
    }

    /// Returns the monotonic non-Range drain progress sequence counter.
    #[inline]
    pub fn drain_progress_seq(&self) -> u64 {
        self.drain_progress_seq.load(Ordering::Acquire)
    }

    /// Disables the 30s lookahead cap when `!supports_range()` and the entire audio payload
    /// fits inside `Body`, allowing all `<= 8 MiB` non-Range tracks to cache completely in RAM.
    pub fn enable_full_file_prefetch_if_fits(&self) {
        if self.is_live || self.supports_range() {
            return;
        }
        let start = self.audio_start.load(Ordering::Acquire);
        let payload_bytes = self
            .audio_end_offset()
            .unwrap_or(0)
            .saturating_sub(start);
        let cap = self.body.circular_metrics().2;
        if payload_bytes > 0 && payload_bytes <= cap as u64 {
            crate::map_log!(
                3,
                "[SESSION] enable_full_file_prefetch_if_fits enabled (payload_bytes={}, capacity={})",
                payload_bytes,
                cap
            );
            self.full_file_prefetch.store(true, Ordering::Release);
            let (byte_rate, playback_rate) = self
                .body
                .sliding_window_state()
                .map(|s| (s.byte_rate_per_sec, s.playback_rate))
                .unwrap_or((SlidingWindowConfig::DEFAULT_BYTE_RATE_PER_SEC, 1.0));
            self.body.configure_sliding_window(
                Self::full_file_prefetch_window_config(),
                byte_rate,
                playback_rate,
            );
        }
    }

    /// Computes exact stream byte rate from `bitrate_bps` (or `audio_payload_bytes / duration_ms`)
    /// and updates the `Body` sliding window for `playback_rate`.
    pub fn configure_stream_timing(&self, bitrate_bps: u32, duration_ms: i64, playback_rate: f32) {
        let byte_rate = if bitrate_bps > 0 {
            ((bitrate_bps as u64) / 8).max(1024)
        } else if duration_ms > 0 {
            let start = self.audio_start.load(Ordering::Acquire);
            let end = self.audio_end_offset().unwrap_or(start);
            let payload_bytes = end.saturating_sub(start);
            if payload_bytes > 0 {
                ((payload_bytes * 1000) / duration_ms as u64).max(1024)
            } else {
                SlidingWindowConfig::DEFAULT_BYTE_RATE_PER_SEC
            }
        } else {
            SlidingWindowConfig::DEFAULT_BYTE_RATE_PER_SEC
        };

        crate::map_log!(
            4,
            "[SESSION] configure_stream_timing bitrate_bps={}, duration_ms={}, playback_rate={:.2}, resolved_byte_rate={}",
            bitrate_bps,
            duration_ms,
            playback_rate,
            byte_rate
        );

        let cfg = if self.full_file_prefetch.load(Ordering::Acquire) {
            Self::full_file_prefetch_window_config()
        } else {
            self.body
                .sliding_window_state()
                .map(|s| s.config)
                .unwrap_or_default()
        };
        self.body
            .configure_sliding_window(cfg, byte_rate, playback_rate);
    }

    /// Updates the `playback_rate` multiplier on `Body` to dynamically scale forward prefetch/window sizes.
    pub fn set_playback_rate(&self, playback_rate: f32) {
        self.body.set_playback_rate(playback_rate);
    }

    /// Computes the next [`BlockFetchOrder`] for `Body` using the 3-phase progressive coalescing scheduler.
    pub fn next_block_request(&self) -> Option<BlockFetchOrder> {
        self.body.next_block_request()
    }

    /// Suspends the producer thread until `Body` requires the next [`BlockFetchOrder`] or `timeout` elapses.
    pub fn wait_for_next_block(&self, timeout: Duration) -> Option<BlockFetchOrder> {
        self.body.wait_for_next_block(timeout)
    }

    /// Returns `true` when this is a live stream and the accumulated `Ahead` time-shift buffer
    /// is at or below a single base window (`<= 1 * B_win`, i.e., at the real-time live edge).
    pub fn is_at_live_edge(&self) -> bool {
        if !self.is_live {
            return false;
        }
        let ahead = self.body.ahead_bytes() as usize;
        let win_bytes = self
            .body
            .sliding_window_state()
            .map(|s| s.base_window_bytes)
            .unwrap_or(65536);
        ahead <= win_bytes
    }

    /// Upper audio boundary byte offset, if known (`audio_end` or `total_size`).
    pub fn audio_end_offset(&self) -> Option<u64> {
        let ae = self.audio_end.load(Ordering::Acquire);
        if ae != u64::MAX {
            Some(ae)
        } else {
            self.total_size
        }
    }

    /// Sets `has_tail` indicating whether the tail region past `audio_end` contains required
    /// container atoms (e.g. non-faststart MP4 `moov`).
    #[inline]
    pub fn set_has_container_tail(&self, has_tail: bool) {
        self.has_container_tail.store(has_tail, Ordering::Release);
    }

    /// Returns the logical container end offset for `SeekFrom::End` and `MediaSource::byte_len`.
    #[inline]
    pub fn logical_end_offset(&self) -> Option<u64> {
        if self.has_container_tail.load(Ordering::Acquire) {
            self.total_size.or_else(|| self.audio_end_offset())
        } else {
            self.audio_end_offset()
        }
    }

    /// Classifies `initial_data` and optional `tail_data` via [`crate::decoder::classifier::StreamClassifier::classify_initial_stream`]
    /// and populates `Head`, `Body`, and `Metadata` in a single unified pass.
    pub fn ingest_classified(
        &self,
        initial_data: &[u8],
        tail_data: Option<(&[u8], Option<u64>)>,
    ) -> crate::decoder::classifier::BoundaryInfo {
        self.ingest_classified_with_options(initial_data, tail_data, false)
    }

    /// Variant of [`Self::ingest_classified`] ingesting `initial_data` and optional `tail_data`,
    /// with `skip_body_payload` allowing offline analysis decks to skip populating `Body` RAM.
    pub fn ingest_classified_with_options(
        &self,
        initial_data: &[u8],
        tail_data: Option<(&[u8], Option<u64>)>,
        skip_body_payload: bool,
    ) -> crate::decoder::classifier::BoundaryInfo {
        use crate::decoder::classifier::{ClassifiedSlice, StreamClassifier};

        let total_size_i64 = self.total_size.map(|s| s as i64).unwrap_or(-1);
        let resolved_tail = tail_data.and_then(|(bytes, maybe_off)| {
            if bytes.is_empty() {
                None
            } else {
                let off = maybe_off
                    .or_else(|| {
                        self.total_size
                            .map(|tot| tot.saturating_sub(bytes.len() as u64))
                    })
                    .unwrap_or(0);
                Some((bytes, off))
            }
        });

        let (boundary, slices) =
            StreamClassifier::classify_initial_stream(initial_data, resolved_tail, total_size_i64);

        crate::map_log!(
            4,
            "[SESSION] ingest_classified initial_len={}, audio_start={}, audio_end={}, skip_body={}",
            initial_data.len(),
            boundary.audio_start,
            boundary.audio_end,
            skip_body_payload
        );

        if boundary.audio_start > 0 {
            self.set_audio_start(boundary.audio_start as u64);
        } else {
            self.set_audio_start(0);
        }
        if boundary.audio_end > 0 {
            self.set_audio_end(boundary.audio_end as u64);
        }

        for slice in slices {
            match slice {
                ClassifiedSlice::DecoderHead(head_bytes) => {
                    self.head.set_linear_bytes(head_bytes);
                }
                ClassifiedSlice::AudioPayload(audio_bytes) => {
                    if !skip_body_payload {
                        let safe_start = boundary.audio_start.max(0) as u64;
                        let _ = self.write_at(safe_start, audio_bytes);
                    }
                }
                ClassifiedSlice::MetadataChunk { offset, data } => {
                    let _ = self.metadata.commit_chunk(offset, data);
                    if offset > 0 && self.audio_end.load(Ordering::Acquire) == u64::MAX {
                        self.set_audio_end(offset);
                    }
                }
            }
        }

        boundary
    }

    /// Populates trailing metadata `tail_bytes` at `tail_offset` in the `Metadata` sparse buffer
    /// and sets `audio_end` on the `Body` buffer to prevent EOF decoder chirps.
    pub fn set_tail(&self, tail_bytes: &[u8], tail_offset: Option<u64>) {
        let resolved_offset = tail_offset
            .or_else(|| {
                self.total_size
                    .map(|tot| tot.saturating_sub(tail_bytes.len() as u64))
            })
            .unwrap_or(0);
        let _ = self.metadata.commit_chunk(resolved_offset, tail_bytes);
        if self.audio_end.load(Ordering::Acquire) == u64::MAX && resolved_offset > 0 {
            self.set_audio_end(resolved_offset);
        }
    }

    /// Returns a copy of trailing metadata bytes if present after `audio_start`.
    pub fn tail_data(&self) -> Vec<u8> {
        let guard = lock_unpoisoned(&self.metadata.backend);
        if let BufferBackend::Sparse { ref chunks, .. } = *guard {
            let start_floor = self.audio_start.load(Ordering::Acquire).max(1);
            if let Some((_, data)) = chunks.range(start_floor..).next_back() {
                return data.clone();
            }
        }
        Vec::new()
    }

    /// Configures the byte offset `start` where the audio payload begins in the stream.
    pub fn set_audio_start(&self, start: u64) {
        self.audio_start.store(start, Ordering::Release);
        self.body.set_circular_anchor(start);
    }

    /// Returns the byte offset where the audio payload begins in the stream.
    #[inline]
    pub fn audio_start_offset(&self) -> u64 {
        self.audio_start.load(Ordering::Acquire)
    }

    /// Configures the byte offset `end` where the audio payload ends in the stream.
    pub fn set_audio_end(&self, end: u64) {
        self.audio_end.store(end, Ordering::Release);
        self.body.set_audio_end(Some(end));
    }

    /// Sets `decoding` to indicate whether the consumer is actively decoding audio frames.
    pub fn set_decoding_audio(&self, decoding: bool) {
        self.is_decoding_audio.store(decoding, Ordering::Release);
    }

    /// Whether the consumer is actively decoding audio frames.
    #[inline]
    pub fn is_decoding_audio(&self) -> bool {
        self.is_decoding_audio.load(Ordering::Acquire)
    }

    /// Feeds a sequential audio `chunk` into the circular `Body` buffer.
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if aborted or [`BufferError::Busy`] if the ring cannot
    /// accept `chunk` without overwriting protected backward-retention data.
    pub fn feed_chunk(&self, chunk: &[u8]) -> Result<usize, BufferError> {
        let cursor = self.body.cursor();
        self.body.feed_sequential(cursor, chunk)
    }

    /// Suspends the producer thread until `min_free_bytes` are available in the circular `Body`
    /// buffer, or until `timeout` elapses or the session is aborted.
    pub fn wait_for_free_space(&self, min_free_bytes: usize, timeout: Duration) -> bool {
        self.body.wait_for_free_space(min_free_bytes, timeout)
    }

    /// Suspends the calling thread until signaled or `timeout` elapses.
    pub fn wait_signal(&self, timeout: Duration) {
        self.body.wait_signal(timeout);
    }

    /// Writes `bytes` at an explicit `offset` into the appropriate tier (`Head` or `Body`).
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if the target buffer has been aborted.
    pub fn write_at(&self, offset: u64, bytes: &[u8]) -> Result<usize, BufferError> {
        if bytes.is_empty() {
            return Ok(0);
        }
        let audio_start = self.audio_start.load(Ordering::Acquire);
        if offset < audio_start {
            let head_part = ((audio_start - offset) as usize).min(bytes.len());
            self.head.commit_chunk(offset, &bytes[..head_part])?;
            let _ = self.metadata.commit_chunk(offset, &bytes[..head_part]);
            if bytes.len() > head_part {
                self.body
                    .commit_chunk(audio_start, &bytes[head_part..])?;
            }
            Ok(bytes.len())
        } else {
            self.body.commit_chunk(offset, bytes)
        }
    }

    /// Non-blocking composite read at `offset` into `out` across `Head`, `Body`, and (when probing) `Metadata`.
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if aborted or [`BufferError::WouldBlock`] if the requested
    /// range is not currently cached.
    pub fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize, BufferError> {
        if out.is_empty() {
            return Ok(0);
        }
        let audio_start = self.audio_start.load(Ordering::Acquire);
        let head_len = self.head.linear_len() as u64;

        // 1. Read from Head if within header range
        if offset < head_len {
            let n = self.head.read_at(offset, out)?;
            let mut total = n;
            let next_offset = offset + n as u64;
            if out.len() > n && next_offset >= audio_start {
                if let Ok(body_n) = self.body.read_at(next_offset, &mut out[n..]) {
                    total += body_n;
                }
            }
            return Ok(total);
        }

        // 2. Enforce audio_end EOF when actively decoding audio frames
        let audio_end = self.audio_end.load(Ordering::Acquire);
        let decoding = self.is_decoding_audio.load(Ordering::Acquire);
        if decoding && audio_end != u64::MAX && offset >= audio_end {
            return Ok(0);
        }

        // 3. When probing containers (not decoding audio), allow reading metadata / tail chunks from sparse metadata buffer
        if !decoding {
            if let Ok(meta_n) = self.metadata.read_at(offset, out) {
                if meta_n > 0 {
                    return Ok(meta_n);
                }
            }
        }

        // 4. Read from Circular Body
        let use_probe_fetcher = self.has_probe_fetcher();
        match self.body.read_at(offset, out) {
            Ok(0)
                if !decoding
                    && !use_probe_fetcher
                    && audio_end != u64::MAX
                    && offset < audio_end =>
            {
                // During container probing without random-access fetchers, zero-fill unbuffered mdat gap up to trailing moov atom
                let (_r_start, r_end, _) = self.body.circular_metrics();
                if offset >= r_end && !self.tail_data().is_empty() {
                    let gap = (audio_end - offset) as usize;
                    let zero_len = out.len().min(gap);
                    out[..zero_len].fill(0);
                    let mut total = zero_len;
                    if out.len() > zero_len {
                        if let Ok(tail_n) = self.metadata.read_at(audio_end, &mut out[zero_len..]) {
                            total += tail_n;
                        }
                    }
                    return Ok(total);
                }
                Ok(0)
            }
            Err(BufferError::WouldBlock)
                if !decoding
                    && !use_probe_fetcher
                    && audio_end != u64::MAX
                    && offset < audio_end =>
            {
                let (_r_start, r_end, _) = self.body.circular_metrics();
                if offset >= r_end && !self.tail_data().is_empty() {
                    let gap = (audio_end - offset) as usize;
                    let zero_len = out.len().min(gap);
                    out[..zero_len].fill(0);
                    let mut total = zero_len;
                    if out.len() > zero_len {
                        if let Ok(tail_n) = self.metadata.read_at(audio_end, &mut out[zero_len..]) {
                            total += tail_n;
                        }
                    }
                    return Ok(total);
                }
                Err(BufferError::WouldBlock)
            }
            res => res,
        }
    }

    /// Publishes a newly dispatched seek generation `gen` and wakes any blocked reader thread.
    pub fn publish_seek_gen(&self, gen: u64) {
        self.latest_seek_gen.fetch_max(gen, Ordering::SeqCst);
        let _guard = lock_unpoisoned(&self.body.backend);
        self.body.data_signal.notify_all();
    }

    /// Marks `gen` (and earlier seeks) as dequeued by `DecoderWorker`.
    #[inline]
    pub fn acknowledge_seek_gen(&self, gen: u64) {
        self.ack_seek_gen.fetch_max(gen, Ordering::AcqRel);
    }

    /// Returns the most recently published seek generation on this session.
    #[inline]
    pub fn latest_seek_gen(&self) -> u64 {
        self.latest_seek_gen.load(Ordering::SeqCst)
    }

    /// Returns `true` when a newer seek generation has been dispatched than `DecoderWorker` has picked up.
    #[inline]
    pub fn has_pending_seek_preempt(&self) -> bool {
        self.latest_seek_gen.load(Ordering::Acquire) > self.ack_seek_gen.load(Ordering::Acquire)
    }

    /// Blocking composite read at `offset` into `out` across `Head` and `Body` with `Condvar`
    /// suspension bounded by idle `timeout`.
    ///
    /// # Errors
    /// Returns [`BufferError::Aborted`] if aborted, [`BufferError::SeekInterrupted`] if preempted
    /// by a newer seek generation, or [`BufferError::WouldBlock`] on idle/hard timeout.
    pub fn read_blocking(
        &self,
        offset: u64,
        out: &mut [u8],
        timeout: Option<Duration>,
    ) -> Result<usize, BufferError> {
        let max_wait = timeout.unwrap_or(Duration::from_millis(2000));
        let mut last_drain_seq = self.drain_progress_seq();
        let mut idle_start = MonotonicInstant::now();
        let hard_start = MonotonicInstant::now();
        let hard_cap = max_wait.max(Duration::from_secs(30));

        loop {
            if self.has_pending_seek_preempt() {
                crate::map_log!(
                    4,
                    "[SESSION] read_blocking preempted by pending seek at offset={}",
                    offset
                );
                return Err(BufferError::SeekInterrupted);
            }
            match self.read_at(offset, out) {
                Ok(n) => return Ok(n),
                Err(BufferError::WouldBlock) => {
                    if self.body.should_abort.load(Ordering::Acquire) {
                        return Err(BufferError::Aborted);
                    }
                    if self.has_pending_seek_preempt() {
                        crate::map_log!(
                            4,
                            "[SESSION] read_blocking preempted by pending seek at offset={}",
                            offset
                        );
                        return Err(BufferError::SeekInterrupted);
                    }
                    let (r_start, r_end, _) = self.body.circular_metrics();
                    if !self.in_probe_mode()
                        && self.supports_range()
                        && (offset < r_start || offset > r_end.saturating_add(256 * 1024))
                    {
                        // Post-probe sequential read landed outside the circular window (e.g. cue scan
                        // during ProbeMode moved cursor far ahead/behind): reposition stream download.
                        if self.seek(offset).is_ok() {
                            continue;
                        }
                    }
                    if self.body.is_eof() && offset >= r_end {
                        return Ok(0);
                    }
                    let cur_drain_seq = self.drain_progress_seq();
                    if cur_drain_seq != last_drain_seq {
                        last_drain_seq = cur_drain_seq;
                        idle_start = MonotonicInstant::now();
                    }
                    let idle_elapsed = idle_start.elapsed();
                    let hard_elapsed = hard_start.elapsed();
                    if idle_elapsed >= max_wait || hard_elapsed >= hard_cap {
                        crate::map_log!(
                            2,
                            "[SESSION] read_blocking timed out at offset={} (idle={:?}, hard={:?})",
                            offset,
                            idle_elapsed,
                            hard_elapsed
                        );
                        return Err(BufferError::WouldBlock);
                    }
                    let slice_wait = (max_wait - idle_elapsed)
                        .min(hard_cap - hard_elapsed)
                        .min(Duration::from_millis(20));
                    let guard = lock_unpoisoned(&self.body.backend);
                    if self.body.should_abort.load(Ordering::Acquire) {
                        return Err(BufferError::Aborted);
                    }
                    if self.has_pending_seek_preempt() {
                        return Err(BufferError::SeekInterrupted);
                    }
                    let _ = self.body.data_signal.wait_timeout(guard, slice_wait);
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Advances the active read `cursor` on `Body` and notifies any bounded HLS VOD lookahead controller.
    pub fn advance_read_cursor(&self, cursor: u64) {
        self.body.set_cursor(cursor);
        if let Some(ref vod) = *read_unpoisoned(&self.hls_vod) {
            let ms = self.mapped_byte_to_ms(cursor, false);
            vod.update_cursor_ms(ms);
        }
    }

    /// Attaches an [`HlsVodState`] controller `vod` for bounded-lookahead streaming and segment seeks.
    pub fn set_hls_vod(&self, vod: Arc<HlsVodState>) {
        let mut guard = write_unpoisoned(&self.hls_vod);
        *guard = Some(vod);
    }

    /// Returns a cloned handle to the active [`HlsVodState`] if this session backs an HLS VOD track.
    pub fn hls_vod(&self) -> Option<Arc<HlsVodState>> {
        read_unpoisoned(&self.hls_vod).clone()
    }

    /// Wakes threads sleeping on `Body::data_signal` (used to preempt chunk feeds on HLS VOD jump).
    pub fn notify_data_signal(&self) {
        let _guard = lock_unpoisoned(&self.body.backend);
        self.body.data_signal.notify_all();
    }

    /// Resets [`ByteTimeMap`] anchors for a fresh HLS VOD segment window starting at
    /// `(audio_start, start_ms)` with length `duration_ms`.
    pub fn reset_hls_vod_window(&self, audio_start: u64, start_ms: i64, duration_ms: i64) {
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.reset_window(audio_start, start_ms, duration_ms);
    }

    /// Flushes `Body` to `new_stream_offset` after an uncached seek.
    pub fn flush(&self, new_stream_offset: u64) {
        crate::map_log!(
            4,
            "[SESSION] flush new_stream_offset={}",
            new_stream_offset
        );
        self.last_flush_target
            .store(new_stream_offset, Ordering::Release);
        self.last_flush_seq.fetch_add(1, Ordering::AcqRel);
        self.body.flush_circular(new_stream_offset);
    }

    /// Monotonic sequence counter incremented each time `flush` or `seek` re-anchors the circular buffer.
    #[inline]
    pub fn flush_seq(&self) -> u64 {
        self.last_flush_seq.load(Ordering::Acquire)
    }

    /// Byte offset passed to the most recent `flush_circular`.
    #[inline]
    pub fn last_flush_target(&self) -> u64 {
        self.last_flush_target.load(Ordering::Acquire)
    }

    /// Resets per-seek probe cursor tracking before dispatching a demuxer seek.
    #[inline]
    pub fn reset_probe_seek_tracking(&self) {
        self.probe_seek_target.store(u64::MAX, Ordering::Release);
        self.probe_read_end.store(0, Ordering::Release);
    }

    /// Records a demuxer seek target byte `offset` encountered while in probe mode and resets the
    /// sequential post-seek probe read cursor so earlier bisection jumps don't pollute it.
    #[inline]
    pub fn note_probe_seek_target(&self, offset: u64) {
        self.probe_seek_target.store(offset, Ordering::Release);
        self.probe_read_end.store(offset, Ordering::Release);
    }

    /// Records the cursor offset `end_offset` after a sequential probe read.
    #[inline]
    pub fn note_probe_read_end(&self, end_offset: u64) {
        self.probe_read_end.store(end_offset, Ordering::Release);
    }

    /// Returns `(last_probe_seek_target, furthest_probe_read_end)`.
    #[inline]
    pub fn probe_seek_tracking(&self) -> (Option<u64>, u64) {
        let tgt = self.probe_seek_target.load(Ordering::Acquire);
        let end = self.probe_read_end.load(Ordering::Acquire);
        (if tgt == u64::MAX { None } else { Some(tgt) }, end)
    }

    /// Re-anchors the circular `Body` window directly to `anchor_byte` right after a seek whose
    /// probing reads came from `ProbePageCache` rather than triggering `flush_circular`, seeding
    /// any cached bytes up to `resume_cursor` so `MediaSourceStream` continues cleanly with zero shift.
    pub fn reanchor_circular_after_probe_seek(&self, anchor_byte: u64, resume_cursor: u64) {
        crate::map_log!(
            4,
            "[SESSION] reanchor_circular_after_probe_seek anchor_byte={}, resume_cursor={}",
            anchor_byte,
            resume_cursor
        );
        let audio_start = self.audio_start.load(Ordering::Acquire);
        if anchor_byte < audio_start {
            return;
        }
        let (r_start, r_end, cap) = self.body.circular_metrics();
        if anchor_byte >= r_start && anchor_byte < r_end {
            let max_seed = (cap / 2).max(65_536);
            let mut seeded = 0usize;
            let mut cur = r_end;
            let mut tmp = [0u8; 32 * 1024];
            while seeded < max_seed {
                let n = {
                    let cache = lock_unpoisoned(&self.probe_cache);
                    cache.read_cached(cur, &mut tmp)
                };
                if n == 0 || self.body.feed_sequential(cur, &tmp[..n]).is_err() {
                    break;
                }
                cur = cur.saturating_add(n as u64);
                seeded += n;
            }
            if resume_cursor > anchor_byte {
                self.body.set_cursor(resume_cursor.min(cur));
            }
            return;
        }
        self.flush(anchor_byte);
        let max_seed = (cap / 2).max(65_536);
        let mut seeded = 0usize;
        let mut cur = anchor_byte;
        let mut tmp = [0u8; 32 * 1024];
        while seeded < max_seed {
            let n = {
                let cache = lock_unpoisoned(&self.probe_cache);
                cache.read_cached(cur, &mut tmp)
            };
            if n == 0 {
                break;
            }
            if self.body.feed_sequential(cur, &tmp[..n]).is_err() {
                break;
            }
            cur = cur.saturating_add(n as u64);
            seeded += n;
        }
        if resume_cursor > anchor_byte {
            self.body.set_cursor(resume_cursor);
        }
    }

    /// Updates the read cursor to `target_offset`, serving from `[Back | Ahead]` on a cache hit
    /// or re-anchoring the circular window (`flush_circular`) on an uncached seek during audio decoding.
    ///
    /// # Errors
    /// Currently infallible (`Ok(())`), returning `Result` for seek API compatibility.
    pub fn seek(&self, target_offset: u64) -> Result<(), BufferError> {
        let head_len = self.head.linear_len() as u64;
        let audio_start = self.audio_start.load(Ordering::Acquire);
        let (r_start, r_end, _) = self.body.circular_metrics();
        let is_eof = self.body.is_eof();

        let in_head = target_offset < head_len;
        let in_body = target_offset >= r_start && target_offset < r_end;
        let at_stream_edge =
            target_offset >= r_start && target_offset <= r_end.saturating_add(65536);

        if in_head || in_body {
            self.body.set_cursor(target_offset);
            self.body.is_buffering.store(false, Ordering::Release);
            self.body.data_signal.notify_all();
        } else if at_stream_edge {
            // Sequential decode caught up with the active download edge: wait for incoming chunks
            // without flushing the already buffered `[r_start .. r_end)` back-retention window.
            self.body.set_cursor(target_offset);
            if !is_eof {
                self.body.is_buffering.store(true, Ordering::Release);
            }
            self.body.data_signal.notify_all();
        } else if self.is_decoding_audio.load(Ordering::Acquire) && target_offset >= audio_start {
            crate::map_log!(
                4,
                "[SESSION] StreamSession::seek flush_circular target={} (r_start={}, r_end={}, head={}, eof={}, probe={})",
                target_offset,
                r_start,
                r_end,
                head_len,
                is_eof,
                self.in_probe_mode()
            );
            self.last_flush_target
                .store(target_offset, Ordering::Release);
            self.last_flush_seq.fetch_add(1, Ordering::AcqRel);
            self.body.flush_circular(target_offset);
        } else {
            self.body.set_cursor(target_offset);
            if !is_eof {
                self.body.is_buffering.store(true, Ordering::Release);
            }
            self.body.data_signal.notify_all();
        }
        Ok(())
    }

    /// Evaluates whether `target_offset` resides in the cached window (`Head` or `Body`).
    /// Returns `(in_cache, contiguous_from_start)`.
    pub fn try_seek_cached(&self, target_offset: u64) -> (bool, bool) {
        let effective_audio_start = self.audio_start.load(Ordering::Acquire);
        let audio_end_raw = self.audio_end.load(Ordering::Acquire);
        let effective_audio_end = if audio_end_raw != u64::MAX {
            audio_end_raw
        } else {
            self.total_size.unwrap_or(0)
        };
        let audio_target = target_offset.max(effective_audio_start);
        let (r_start, r_end, _) = self.body.circular_metrics();
        let is_eof = self.body.is_eof();

        let in_ring = audio_target >= r_start
            && (audio_target < r_end
                || (is_eof && audio_target <= r_end)
                || (effective_audio_end > 0
                    && r_end >= effective_audio_end
                    && audio_target <= effective_audio_end));
        let contiguous_from_start = r_start <= effective_audio_start;

        if in_ring {
            self.body.set_cursor(target_offset);
            self.body.is_buffering.store(false, Ordering::Release);
            (true, contiguous_from_start)
        } else {
            (false, false)
        }
    }

    /// Marks EOF on `Head`, `Body`, and `Metadata`.
    pub fn mark_eof(&self) {
        crate::map_log!(4, "[SESSION] StreamSession::mark_eof");
        self.head.mark_eof();
        self.body.mark_eof();
        self.metadata.mark_eof();
    }

    /// Aborts pending operations on `Head`, `Body`, and `Metadata`.
    pub fn abort(&self) {
        crate::map_log!(3, "[SESSION] StreamSession::abort");
        self.head.abort();
        self.body.abort();
        self.metadata.abort();
        lock_unpoisoned(&self.probe_cache).clear();
        if let Some(ref vod) = *read_unpoisoned(&self.hls_vod) {
            vod.notify_all();
        }
    }

    /// Clears abort status on `Head`, `Body`, and `Metadata`.
    pub fn clear_abort(&self) {
        self.head.clear_abort();
        self.body.clear_abort();
        self.metadata.clear_abort();
    }

    /// Computes a telemetry `BufferRange` snapshot.
    pub fn get_range(&self) -> BufferRange {
        let (r_start, r_end, cap) = self.body.circular_metrics();
        let total = self.total_size.map(|v| v as i64).unwrap_or(-1);
        let buffered_bytes = r_end.saturating_sub(r_start) as f32;
        let fill_pct = (buffered_bytes / cap.max(1) as f32).clamp(0.0, 1.0);
        let stream_pct = if total > 0 {
            (r_end as f32 / total as f32).clamp(0.0, 1.0)
        } else {
            fill_pct
        };

        BufferRange {
            start_byte: r_start as i64,
            end_byte: r_end as i64,
            total_bytes: total,
            read_cursor_byte: self.body.cursor() as i64,
            fill_percentage: fill_pct,
            stream_percentage: stream_pct,
            is_buffering: i32::from(self.body.is_buffering()),
            is_eof: i32::from(self.body.is_eof()),
        }
    }

    /// Metadata mutation version counter.
    #[inline]
    pub fn meta_version(&self) -> u32 {
        self.metadata.version()
    }

    /// Updates dynamic ICY stream metadata `data` in `Metadata`.
    pub fn set_icy_meta(&self, data: &[u8]) {
        self.metadata.set_icy_meta(data);
    }

    /// Whether this session is a live stream.
    #[inline]
    pub fn is_live(&self) -> bool {
        self.is_live
    }

    /// Total stream length in bytes, if known.
    #[inline]
    pub fn total_size(&self) -> Option<u64> {
        self.total_size
    }

    /// Pinned header length in bytes.
    #[inline]
    pub fn head_size(&self) -> usize {
        self.head.linear_len()
    }

    /// Current cached audio window start byte offset.
    #[inline]
    pub fn range_start(&self) -> u64 {
        self.body.circular_metrics().0
    }

    /// Current cached audio window end byte offset.
    #[inline]
    pub fn range_end(&self) -> u64 {
        self.body.circular_metrics().1
    }

    /// Whether end-of-stream has been reached.
    #[inline]
    pub fn is_eof(&self) -> bool {
        self.body.is_eof()
    }

    /// Whether the entire stream has been buffered from `audio_start` to `total_size`.
    pub fn is_fully_buffered(&self) -> bool {
        let Some(tot) = self.total_size else {
            return false;
        };
        let (r_start, r_end, _) = self.body.circular_metrics();
        let a_start = self.audio_start.load(Ordering::Acquire);
        let a_end = self.audio_end.load(Ordering::Acquire);
        let target_end = if a_end != u64::MAX { a_end } else { tot };
        r_start <= a_start && r_end >= target_end
    }

    /// Returns whether the underlying stream source supports HTTP Range (`206`) random access.
    #[inline]
    pub fn supports_range(&self) -> bool {
        self.supports_range.load(Ordering::Acquire)
    }

    /// Sets `supported` indicating whether the underlying stream source supports HTTP Range (`206`) random access.
    #[inline]
    pub fn set_supports_range(&self, supported: bool) {
        self.supports_range.store(supported, Ordering::Release);
    }

    /// Returns a shared handle to the atomic `supports_range` flag without cloning the full [`StreamSession`].
    #[inline]
    pub fn supports_range_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.supports_range)
    }

    /// Enters isolated probe mode (container open or demuxer seek-table inspection),
    /// returning an RAII guard that decrements the active depth on drop.
    #[inline]
    pub fn enter_probe(&self) -> ProbeGuard {
        self.probe_depth.fetch_add(1, Ordering::AcqRel);
        ProbeGuard {
            depth: Arc::clone(&self.probe_depth),
        }
    }

    /// Temporarily suspends isolated probe mode so sequential reads stream directly from `Body`
    /// without issuing per-page `ProbePageCache` HTTP Range requests, restoring on drop.
    #[inline]
    pub fn suspend_probe_mode(&self) -> ProbeGuard {
        self.probe_suspend_depth.fetch_add(1, Ordering::AcqRel);
        ProbeGuard {
            depth: Arc::clone(&self.probe_suspend_depth),
        }
    }

    /// Returns whether one or more probe/seek scopes are currently active.
    #[inline]
    pub fn in_probe_mode(&self) -> bool {
        self.probe_depth.load(Ordering::Acquire) > 0
            && self.probe_suspend_depth.load(Ordering::Acquire) == 0
    }

    /// Attaches or clears the on-demand range `fetcher` used during isolated probe/seek reads.
    pub fn set_probe_fetcher(&self, fetcher: Option<ProbeFetcherFn>) {
        crate::map_log!(
            4,
            "[SESSION] set_probe_fetcher active={}",
            fetcher.is_some()
        );
        let mut slot = write_unpoisoned(&self.probe_fetcher);
        *slot = fetcher;
    }

    /// Returns true if random-access range support is enabled and a probe fetcher is attached.
    #[inline]
    pub fn has_probe_fetcher(&self) -> bool {
        self.supports_range() && read_unpoisoned(&self.probe_fetcher).is_some()
    }

    /// Returns a cloned handle to the configured random-access probe fetcher, if active.
    pub fn probe_fetcher(&self) -> Option<ProbeFetcherFn> {
        if !self.supports_range() {
            return None;
        }
        read_unpoisoned(&self.probe_fetcher).clone()
    }

    /// Seeds an already-fetched byte slice into `probe_cache` so subsequent demuxer probes reuse it.
    pub fn seed_probe_cache(&self, offset: u64, data: Vec<u8>) {
        if data.is_empty() {
            return;
        }
        lock_unpoisoned(&self.probe_cache).insert(offset, data);
    }

    /// Serves an isolated probe/seek read at `offset` into `out` from the bounded probe cache
    /// or via HTTP Range without mutating or flushing the circular `Body` ring buffer.
    ///
    /// Returns `None` when random-access probing is unavailable (caller should fall back
    /// to standard streaming wait).
    pub fn read_via_probe_cache(
        &self,
        offset: u64,
        out: &mut [u8],
    ) -> Option<Result<usize, BufferError>> {
        if out.is_empty() {
            return Some(Ok(0));
        }
        if self.body.should_abort.load(Ordering::Acquire) {
            return Some(Err(BufferError::Aborted));
        }
        if self.has_pending_seek_preempt() {
            return Some(Err(BufferError::SeekInterrupted));
        }
        if let Some(tot) = self.total_size {
            if offset >= tot {
                return Some(Ok(0));
            }
        }
        let decoding = self.is_decoding_audio.load(Ordering::Acquire);
        if decoding {
            let audio_end = self.audio_end.load(Ordering::Acquire);
            if audio_end != u64::MAX && offset >= audio_end {
                return Some(Ok(0));
            }
        }
        let logical_end = if decoding {
            self.audio_end_offset().or(self.total_size)
        } else {
            self.total_size.or_else(|| self.audio_end_offset())
        };
        let desired_end = match logical_end {
            Some(lim) => offset.saturating_add(out.len() as u64).min(lim),
            None => offset.saturating_add(out.len() as u64),
        };
        if desired_end <= offset {
            return Some(Ok(0));
        }
        let required_len = (desired_end - offset) as usize;

        let head_len = self.head.linear_len() as u64;
        if desired_end <= head_len {
            if let Ok(n) = self.head.read_at(offset, out) {
                if n > 0 {
                    return Some(Ok(n));
                }
            }
        }
        if !decoding {
            if let Ok(n) = self.metadata.read_at(offset, out) {
                if n >= required_len {
                    return Some(Ok(n));
                }
            }
        }
        let (r_start, r_end, _) = self.body.circular_metrics();
        if offset >= r_start && (desired_end <= r_end || (self.body.is_eof() && offset < r_end)) {
            if let Ok(n) = self.body.read_at(offset, out) {
                if n > 0 {
                    return Some(Ok(n));
                }
            }
        }

        if !self.supports_range() {
            return None;
        }
        let fetcher = read_unpoisoned(&self.probe_fetcher).clone()?;

        {
            let cache = lock_unpoisoned(&self.probe_cache);
            let n = cache.read_cached(offset, out);
            if n > 0 {
                return Some(Ok(n));
            }
        }

        let page_align: u64 = 16 * 1024;
        let mut fetch_start = if out.len() <= 16 * 1024 {
            offset & !(page_align - 1)
        } else {
            offset
        };
        if offset >= head_len && fetch_start < head_len {
            fetch_start = head_len;
        }
        let min_end = offset.saturating_add(out.len().min(512 * 1024) as u64);
        let target_end = fetch_start
            .saturating_add(ProbePageCache::PAGE_SIZE as u64)
            .max(min_end);
        let clamped_end = match self.total_size {
            Some(tot) => target_end.min(tot),
            None => target_end,
        };
        if clamped_end <= offset {
            return Some(Ok(0));
        }
        let fetch_len = (clamped_end - fetch_start) as usize;

        let mut page_offset = fetch_start;
        crate::map_log!(
            5,
            "[SESSION] read_via_probe_cache fetch offset={}, len={}",
            fetch_start,
            fetch_len
        );
        let mut data = fetcher(fetch_start, fetch_len);
        // If aligned page ended before requested offset (short read), retry directly at offset.
        if let Some(ref bytes) = data {
            if offset >= page_offset && (offset - page_offset) >= bytes.len() as u64 {
                page_offset = offset;
                let direct_end = match self.total_size {
                    Some(tot) => offset.saturating_add(out.len().max(ProbePageCache::PAGE_SIZE) as u64).min(tot),
                    None => offset.saturating_add(out.len().max(ProbePageCache::PAGE_SIZE) as u64),
                };
                if direct_end <= offset {
                    return Some(Ok(0));
                }
                data = fetcher(offset, (direct_end - offset) as usize);
            }
        }

        if self.body.should_abort.load(Ordering::Acquire) {
            return Some(Err(BufferError::Aborted));
        }
        if self.has_pending_seek_preempt() {
            return Some(Err(BufferError::SeekInterrupted));
        }

        let Some(bytes) = data else {
            crate::map_log!(
                2,
                "[SESSION] read_via_probe_cache probe fetcher returned None at offset={}, len={}",
                page_offset,
                fetch_len
            );
            return None;
        };
        if bytes.is_empty() {
            return Some(Ok(0));
        }

        let start_in_page = (offset - page_offset) as usize;
        if start_in_page >= bytes.len() {
            return Some(Ok(0));
        }
        let to_copy = (bytes.len() - start_in_page).min(out.len());
        out[..to_copy].copy_from_slice(&bytes[start_in_page..start_in_page + to_copy]);

        {
            let mut cache = lock_unpoisoned(&self.probe_cache);
            cache.insert(page_offset, bytes);
        }
        Some(Ok(to_copy))
    }

    /// Returns a linear copy of the pinned `Head` container bytes (`0..head.linear_len()`).
    pub fn head_bytes_copy(&self) -> Vec<u8> {
        let len = self.head.linear_len();
        if len == 0 {
            return Vec::new();
        }
        let mut buf = vec![0u8; len];
        let got = self.head.read_at(0, &mut buf).unwrap_or(0);
        buf.truncate(got);
        buf
    }

    /// Returns circular body ring metrics `(range_start, range_end, capacity)`.
    #[inline]
    pub fn body_metrics(&self) -> (u64, u64, usize) {
        self.body.circular_metrics()
    }

    /// Returns bytes currently available ahead of `Body`'s read cursor inside RAM without waiting on HTTP.
    #[inline]
    pub fn body_unread_ahead(&self) -> u64 {
        let cur = self.body.cursor();
        let (r_start, r_end, _) = self.body.circular_metrics();
        if cur < r_start || cur >= r_end {
            0
        } else {
            r_end - cur
        }
    }

    /// Installs container framing rules `kind` for exact decodable buffered range snapping.
    pub fn set_buffered_boundary_kind(&self, kind: BufferedBoundaryKind) {
        crate::map_log!(4, "[SESSION] set_buffered_boundary_kind");
        *write_unpoisoned(&self.boundary_kind) = kind;
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Reads bytes directly from the in-RAM circular `Body` cache at `offset` into `out` without HTTP I/O.
    pub fn read_cached_body_at(&self, offset: u64, out: &mut [u8]) -> usize {
        self.body.read_at(offset, out).unwrap_or(0)
    }

    /// Configures stream payload bounds (`audio_start`, `audio_end`) and `duration_ms` on the internal [`ByteTimeMap`].
    pub fn configure_byte_time_map(&self, audio_start: u64, audio_end: u64, duration_ms: i64) {
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.set_bounds(audio_start, audio_end, duration_ms);
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Refines the logical start byte offset `first_audio_byte` where `t = 0 ms` begins on [`ByteTimeMap`].
    pub fn refine_byte_time_audio_start(&self, first_audio_byte: u64) {
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.refine_audio_start(first_audio_byte);
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Installs pre-extracted container index `(byte_offset, time_ms)` anchors `pts`.
    pub fn set_byte_time_anchors(&self, pts: Vec<(u64, i64)>) {
        if pts.is_empty() {
            return;
        }
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.set_anchors(pts);
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Merges newly discovered anchors `pts` with any existing runtime/seek anchors cleanly.
    pub fn merge_byte_time_anchors(&self, pts: Vec<(u64, i64)>) {
        if pts.is_empty() {
            return;
        }
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.merge_anchors(pts);
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Returns a cloned copy of the sorted `(byte_offset, ms)` anchors currently known.
    pub fn byte_time_anchors(&self) -> Vec<(u64, i64)> {
        read_unpoisoned(&self.byte_time_map).anchors().to_vec()
    }

    /// Estimates the timestamp in milliseconds for an arbitrary `byte_offset` via [`ByteTimeMap`],
    /// using conservative clamping when `is_range_start` is true.
    pub fn mapped_byte_to_ms(&self, byte_offset: u64, is_range_start: bool) -> i64 {
        read_unpoisoned(&self.byte_time_map).byte_to_ms(byte_offset, is_range_start)
    }

    /// Estimates the file byte offset for `time_ms` using [`ByteTimeMap`].
    pub fn estimate_byte_for_ms(&self, time_ms: i64) -> Option<u64> {
        read_unpoisoned(&self.byte_time_map).estimate_byte_for_ms(time_ms)
    }

    /// Returns the largest anchor byte offset whose timestamp precedes `time_ms` via [`ByteTimeMap`].
    pub fn floor_anchor_byte_for_ms(&self, time_ms: i64) -> Option<u64> {
        read_unpoisoned(&self.byte_time_map).floor_anchor_byte_for_ms(time_ms)
    }

    /// Returns true when [`ByteTimeMap`] already holds container, segment, or probed anchors.
    pub fn has_byte_time_anchors(&self) -> bool {
        read_unpoisoned(&self.byte_time_map).has_anchors()
    }

    /// Records an authoritative seek/frame anchor `(byte_offset, time_ms)`, overriding
    /// conflicting nearby coarse probe anchors so `mapped_buffered_range` matches the actual seek.
    pub fn record_verified_byte_time_anchor(&self, byte_offset: u64, time_ms: i64) {
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.record_verified_anchor(byte_offset, time_ms);
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Sets `present` indicating whether the open FLAC stream already carried an embedded `SEEKTABLE` block.
    #[inline]
    pub fn set_has_native_flac_seektable(&self, present: bool) {
        self.has_native_flac_seektable.store(present, Ordering::Release);
    }

    /// Returns whether the stream carries a native FLAC `SEEKTABLE` block.
    #[inline]
    pub fn has_native_flac_seektable(&self) -> bool {
        self.has_native_flac_seektable.load(Ordering::Acquire)
    }

    /// Records verified `(file_byte_offset, sample_number)` FLAC frame seek points `pts` for synthetic
    /// `SEEKTABLE` synthesis on seektable-less streams.
    pub fn record_flac_seek_points(&self, pts: &[(u64, u64)]) {
        if pts.is_empty() {
            return;
        }
        let mut guard = lock_unpoisoned(&self.flac_seek_points);
        guard.extend_from_slice(pts);
        guard.sort_by_key(|&(off, smp)| (off, smp));
        guard.dedup_by(|a, b| a.0 == b.0 || a.1 == b.1);
    }

    /// Returns a cloned sorted snapshot of discovered `(file_byte_offset, sample_number)` FLAC points.
    pub fn flac_seek_points(&self) -> Vec<(u64, u64)> {
        lock_unpoisoned(&self.flac_seek_points).clone()
    }

    /// Appends an HLS VOD segment end boundary `(byte_offset, time_ms)` into [`ByteTimeMap`].
    pub fn push_segment_anchor(&self, byte_offset: u64, time_ms: i64) {
        let mut map = write_unpoisoned(&self.byte_time_map);
        map.push_segment_anchor(byte_offset, time_ms);
        *lock_unpoisoned(&self.last_mapped_window) = None;
    }

    /// Maps the active circular `[start_byte, end_byte]` cache window into conservative `[start_ms, end_ms]`
    /// clamped against `duration_ms`, snapping endpoints to 100% complete decodable container units inside RAM with zero HTTP I/O.
    pub fn mapped_buffered_range(&self, duration_ms: i64) -> (i64, i64) {
        let (r_start, r_end, _cap) = self.body.circular_metrics();
        if r_end <= r_start {
            return (0, 0);
        }
        let is_eof = self.body.is_eof();
        if let Some((cs, ce, ceof, s_ms, e_ms)) = *lock_unpoisoned(&self.last_mapped_window) {
            if cs == r_start && ce == r_end && ceof == is_eof {
                return (s_ms, e_ms);
            }
        }

        if let Some(vod) = self.hls_vod() {
            if !is_eof {
                if let Some((hs, he)) = vod.resident_ms_bounds(r_start, r_end) {
                    let e = if duration_ms > 0 { he.clamp(0, duration_ms) } else { he.max(0) };
                    let s = hs.clamp(0, e);
                    *lock_unpoisoned(&self.last_mapped_window) = Some((r_start, r_end, is_eof, s, e));
                    return (s, e);
                }
            }
        }

        let audio_start = self.audio_start.load(Ordering::Acquire);
        let boundary_kind = read_unpoisoned(&self.boundary_kind).clone();
        let mut discovered_anchors: Vec<(u64, i64)> = Vec::new();
        let mut discovered_flac_pts: Vec<(u64, u64)> = Vec::new();
        let mut override_start: Option<i64> = if r_start <= audio_start { Some(0) } else { None };
        let mut override_end: Option<i64> = if is_eof && duration_ms > 0 {
            Some(duration_ms)
        } else {
            None
        };

        if !is_eof {
            match boundary_kind {
                BufferedBoundaryKind::None => {}
                BufferedBoundaryKind::Mp3Xing => {
                    let cur_end = read_unpoisoned(&self.byte_time_map).byte_to_ms(r_end, false);
                    let cur_start = override_start
                        .unwrap_or_else(|| read_unpoisoned(&self.byte_time_map).byte_to_ms(r_start, true));
                    if cur_end.saturating_sub(cur_start) > 1_500 {
                        override_end = Some(cur_end.saturating_sub(750).max(cur_start));
                    } else if cur_end.saturating_sub(cur_start) > 800 {
                        override_end = Some(cur_end.saturating_sub(300).max(cur_start));
                    }
                }
                BufferedBoundaryKind::ExactFrames(ref frames) => {
                    // APE requires `end_byte + seek_remainder(<=3) + 4 <= r_end` per frame.
                    let j = if r_start <= audio_start {
                        0
                    } else {
                        frames.partition_point(|&(b, _)| b < r_start)
                    };
                    if override_start.is_none() {
                        if let Some(&(_, ms)) = frames.get(j) {
                            override_start = Some(ms);
                        }
                    }
                    let k = frames
                        .partition_point(|&(b, _)| b.saturating_add(8) <= r_end)
                        .saturating_sub(1);
                    if k >= j.saturating_add(2) && k < frames.len() {
                        // Keep 1 complete ~1.66s APE frame in RAM beyond `end_ms` so 96% seeks
                        // never stall waiting for the next monolithic ~190 KB APE frame on slow links.
                        override_end = Some(frames[k - 1].1);
                    } else if k > j && k < frames.len() {
                        override_end = Some(frames[k].1);
                    }
                }
                BufferedBoundaryKind::Ogg {
                    serial,
                    sample_rate,
                    pre_skip,
                } => {
                    let tail_off = r_end.saturating_sub(64 * 1024).max(r_start);
                    let tail_len = (r_end - tail_off).min(64 * 1024) as usize;
                    if tail_len >= 28 {
                        let mut buf = vec![0u8; tail_len];
                        let got = self.read_cached_body_at(tail_off, &mut buf);
                        let pages = ByteTimeMap::scan_ogg_pages_in_slice(
                            &buf[..got],
                            tail_off,
                            serial,
                            sample_rate,
                            pre_skip,
                        );
                        if let Some(last) = pages.last() {
                            let target_end = last.end_ms.saturating_sub(600);
                            let safe_pg = pages
                                .iter()
                                .rev()
                                .find(|p| p.end_ms <= target_end)
                                .or_else(|| {
                                    if pages.len() >= 2 {
                                        Some(&pages[pages.len() - 2])
                                    } else {
                                        None
                                    }
                                })
                                .unwrap_or(last);
                            override_end = Some(safe_pg.end_ms);
                        }
                        for pg in pages {
                            discovered_anchors.push((pg.offset.saturating_add(pg.len as u64), pg.end_ms));
                        }
                    }
                    if override_start.is_none() {
                        let head_len = (r_end - r_start).min(32 * 1024) as usize;
                        if head_len >= 28 {
                            let mut buf = vec![0u8; head_len];
                            let got = self.read_cached_body_at(r_start, &mut buf);
                            let pages = ByteTimeMap::scan_ogg_pages_in_slice(
                                &buf[..got],
                                r_start,
                                serial,
                                sample_rate,
                                pre_skip,
                            );
                            for pg in &pages {
                                discovered_anchors.push((pg.offset.saturating_add(pg.len as u64), pg.end_ms));
                            }
                            if let Some(first_pg) = pages.iter().find(|p| !p.is_continuation) {
                                if first_pg.offset > r_start {
                                    // `r_start` sits mid-page; postpone anchor eval to `first_pg.offset`.
                                    override_start = Some(
                                        read_unpoisoned(&self.byte_time_map)
                                            .byte_to_ms(first_pg.offset, true),
                                    );
                                }
                            }
                        }
                    }
                }
                BufferedBoundaryKind::Flac {
                    sample_rate,
                    min_bs,
                    max_bs,
                } => {
                    let tail_off = r_end.saturating_sub(64 * 1024).max(r_start);
                    let tail_len = (r_end - tail_off).min(64 * 1024) as usize;
                    if tail_len >= 16 {
                        let mut buf = vec![0u8; tail_len];
                        let got = self.read_cached_body_at(tail_off, &mut buf);
                        let frames = ByteTimeMap::scan_flac_frames_in_slice(
                            &buf[..got],
                            tail_off,
                            sample_rate,
                            min_bs,
                            max_bs,
                            duration_ms,
                        );
                        if frames.len() >= 2 {
                            override_end = Some(frames[frames.len() - 2].2);
                        }
                        for (off, smp, ms) in frames {
                            discovered_anchors.push((off, ms));
                            discovered_flac_pts.push((off, smp));
                        }
                    }
                    if override_start.is_none() {
                        let head_len = (r_end - r_start).min(32 * 1024) as usize;
                        if head_len >= 16 {
                            let mut buf = vec![0u8; head_len];
                            let got = self.read_cached_body_at(r_start, &mut buf);
                            let frames = ByteTimeMap::scan_flac_frames_in_slice(
                                &buf[..got],
                                r_start,
                                sample_rate,
                                min_bs,
                                max_bs,
                                duration_ms,
                            );
                            if let Some(&(first_off, _, first_ms)) = frames.first() {
                                if first_off >= r_start {
                                    override_start = Some(first_ms);
                                }
                            }
                            for (off, smp, ms) in frames {
                                discovered_anchors.push((off, ms));
                                discovered_flac_pts.push((off, smp));
                            }
                        }
                    }
                }
                BufferedBoundaryKind::WavPack { sample_rate } => {
                    let tail_off = r_end.saturating_sub(112 * 1024).max(r_start);
                    let tail_len = (r_end - tail_off).min(112 * 1024) as usize;
                    if tail_len >= 32 {
                        let mut buf = vec![0u8; tail_len];
                        let got = self.read_cached_body_at(tail_off, &mut buf);
                        let blocks = ByteTimeMap::extract_wavpack_blocks_in_slice(
                            &buf[..got],
                            tail_off,
                            sample_rate,
                            duration_ms,
                        );
                        if let Some(&(off, blen, blk_idx, blk_samples)) = blocks.last() {
                            if off + blen as u64 <= r_end {
                                let end_smp = blk_idx.saturating_add(blk_samples as u64);
                                let end_block_ms =
                                    ((end_smp as u128 * 1000) / sample_rate.max(1) as u128) as i64;
                                override_end = Some(end_block_ms);
                                discovered_anchors.push((off + blen as u64, end_block_ms));
                            }
                        }
                        for (off, _, blk_idx, _) in blocks {
                            let start_block_ms =
                                ((blk_idx as u128 * 1000) / sample_rate.max(1) as u128) as i64;
                            discovered_anchors.push((off, start_block_ms));
                        }
                    }
                    if override_start.is_none() {
                        let head_len = (r_end - r_start).min(96 * 1024) as usize;
                        if head_len >= 32 {
                            let mut buf = vec![0u8; head_len];
                            let got = self.read_cached_body_at(r_start, &mut buf);
                            let blocks = ByteTimeMap::extract_wavpack_blocks_in_slice(
                                &buf[..got],
                                r_start,
                                sample_rate,
                                duration_ms,
                            );
                            if let Some(&(off, _, blk_idx, _)) = blocks.first() {
                                if off >= r_start {
                                    let sms = ((blk_idx as u128 * 1000)
                                        / sample_rate.max(1) as u128)
                                        as i64;
                                    override_start = Some(sms);
                                }
                            }
                            for (off, _, blk_idx, _) in blocks {
                                let sms = ((blk_idx as u128 * 1000)
                                    / sample_rate.max(1) as u128)
                                    as i64;
                                discovered_anchors.push((off, sms));
                            }
                        }
                    }
                }
                BufferedBoundaryKind::Mkv { timecode_scale_ns } => {
                    let tail_off = r_end.saturating_sub(96 * 1024).max(r_start);
                    let tail_len = (r_end - tail_off).min(96 * 1024) as usize;
                    if tail_len >= 16 {
                        let mut buf = vec![0u8; tail_len];
                        let got = self.read_cached_body_at(tail_off, &mut buf);
                        let clusters = ByteTimeMap::scan_mkv_clusters_in_slice(
                            &buf[..got],
                            tail_off,
                            timecode_scale_ns,
                            duration_ms,
                        );
                        discovered_anchors.extend(clusters);
                    }
                    let safe_end_byte = if r_end.saturating_sub(r_start) > 48 * 1024 {
                        r_end.saturating_sub(24 * 1024)
                    } else {
                        r_end.saturating_sub(8 * 1024).max(r_start)
                    };
                    if override_start.is_none() {
                        let head_len = (r_end - r_start).min(64 * 1024) as usize;
                        if head_len >= 16 {
                            let mut buf = vec![0u8; head_len];
                            let got = self.read_cached_body_at(r_start, &mut buf);
                            let clusters = ByteTimeMap::scan_mkv_clusters_in_slice(
                                &buf[..got],
                                r_start,
                                timecode_scale_ns,
                                duration_ms,
                            );
                            if let Some(&(cl_off, cl_ms)) = clusters.first() {
                                if cl_off >= r_start {
                                    override_start = Some(cl_ms);
                                }
                            }
                            discovered_anchors.extend(clusters);
                        }
                    }
                    if !discovered_anchors.is_empty() {
                        write_unpoisoned(&self.byte_time_map).merge_anchors(std::mem::take(&mut discovered_anchors));
                    }
                    override_end = Some(
                        read_unpoisoned(&self.byte_time_map).byte_to_ms(safe_end_byte, false),
                    );
                }
            }
        }

        if !discovered_anchors.is_empty() {
            write_unpoisoned(&self.byte_time_map).merge_anchors(discovered_anchors);
        }
        if !discovered_flac_pts.is_empty() {
            self.record_flac_seek_points(&discovered_flac_pts);
        }

        let map = read_unpoisoned(&self.byte_time_map);
        let raw_end = override_end.unwrap_or_else(|| map.byte_to_ms(r_end, false));
        let end_ms = if duration_ms > 0 {
            raw_end.clamp(0, duration_ms)
        } else {
            raw_end.max(0)
        };
        let raw_start = override_start.unwrap_or_else(|| map.byte_to_ms(r_start, true));
        let start_ms = raw_start.clamp(0, end_ms);
        *lock_unpoisoned(&self.last_mapped_window) = Some((r_start, r_end, is_eof, start_ms, end_ms));
        (start_ms, end_ms)
    }

    /// Creates a [`DemuxedStreamReader`] over this `StreamSession`.
    pub fn create_reader(&self) -> super::demux_reader::DemuxedStreamReader {
        super::demux_reader::DemuxedStreamReader::new(self.clone())
    }

    /// Creates a [`DemuxedStreamReader`] rooted at physical stream offset `base_offset`.
    pub fn create_reader_at(&self, base_offset: u64) -> super::demux_reader::DemuxedStreamReader {
        super::demux_reader::DemuxedStreamReader::new_at(self.clone(), base_offset)
    }

    /// Returns byte length currently pinned in the non-circular `Head` buffer.
    #[inline]
    pub fn head_len(&self) -> usize {
        self.head.linear_len()
    }
}
