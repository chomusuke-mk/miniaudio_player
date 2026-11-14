//! Universal `StreamBuffer` Primitive (`Linear`, `Circular`, `Sparse`) and `StreamSession`.
//!
//! Replaces legacy heterogeneous buffer segments with a unified, thread-safe,
//! deadlock-free reactive buffer architecture:
//! - `BufferBackend::Linear`: Non-circular, dynamically growing memory for container headers (`Head`).
//! - `BufferBackend::Circular`: Bounded circular ring buffer with proactive watermark prefetching
//!   and on-demand `ByteFetchTask` (`getRealBytes`) for pure audio payloads (`Body`).
//! - `BufferBackend::Sparse`: Offset-indexed virtual address space for metadata tags, cover art,
//!   chapters, and live ICY updates (`Metadata`).

use std::collections::BTreeMap;
use std::io::Result as IoResult;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::sync::{lock_unpoisoned, wait_timeout_unpoisoned, MonotonicInstant};

/// Operational states for a [`StreamBuffer`] or [`StreamSession`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferState {
    /// Buffer has not yet been initialized.
    Uninitialized = 0,
    /// Header segment is being probed for container and codec configuration.
    ProbingHead = 1,
    /// Buffer contains playable data.
    Ready = 2,
    /// Buffer is stalled awaiting asynchronous byte delivery.
    Buffering = 3,
    /// End of stream reached.
    Eof = 4,
    /// Stream operation was aborted.
    Aborted = 5,
}

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
}

impl SlidingWindowState {
    /// Creates a new `SlidingWindowState` and resolves byte dimensions for `capacity`.
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
        data: Vec<u8>,
        min_growth: usize,
    },
    /// Non-circular sparse virtual address space (used for `Metadata`).
    Sparse {
        chunks: BTreeMap<u64, Vec<u8>>,
        virtual_size: Option<u64>,
        min_growth: usize,
        icy_override: Vec<u8>,
    },
    /// Circular bidirectional sliding window (`[Back | Ahead]`) with progressive block coalescing (used for `Body`).
    Circular {
        storage: Vec<u8>,
        capacity: usize,
        anchor_offset: u64,
        range_start: u64,
        range_end: u64,
        audio_end: Option<u64>,
        window: SlidingWindowState,
        push_streaming: bool,
        fetcher: Option<ByteFetchTask>,
    },
}

/// Coalesces `(offset, data)` into a sparse `BTreeMap<u64, Vec<u8>>`, merging overlapping or adjacent ranges.
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
    backend: Mutex<BufferBackend>,
    data_signal: Condvar,
    read_cursor: AtomicU64,
    is_circular: bool,
    is_buffering: AtomicBool,
    is_producer_waiting: AtomicBool,
    is_eof: AtomicBool,
    should_abort: AtomicBool,
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

    /// Creates a non-circular linear `StreamBuffer` (used for `Head`).
    pub fn new_linear(initial_size: usize, min_growth: usize) -> Arc<Self> {
        let cap = initial_size.max(1024);
        let growth = min_growth.max(1024);
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

    /// Creates a non-circular sparse `StreamBuffer` (used for `Metadata`).
    pub fn new_sparse(
        initial_size: usize,
        min_growth: usize,
        virtual_size: Option<u64>,
    ) -> Arc<Self> {
        let _ = initial_size;
        Arc::new(Self {
            backend: Mutex::new(BufferBackend::Sparse {
                chunks: BTreeMap::new(),
                virtual_size,
                min_growth: min_growth.max(4096),
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

    /// Creates a circular bidirectional sliding-window `StreamBuffer` (used for `Body`).
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

    /// Pure deterministic evaluator for the 3-phase progressive block-coalescing scheduler.
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

        let (phase, raw_req_len) = if ahead_bytes < win_size {
            // Phase 1 (UrgentBootstrap): ahead < 1 window -> request 1 base window (5s)
            (BlockFetchPhase::UrgentBootstrap, win_size)
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

            if window.window_filled && deficit < coalesce_threshold && !can_finish_eof {
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

        if phase == BlockFetchPhase::CoalescedCruise
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

    /// Updates `window.window_filled` and `is_eof` after bytes are written into a `Circular` buffer.
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

    /// Configures the temporal sliding window parameters, stream byte rate, and playback rate.
    pub fn configure_sliding_window(
        &self,
        config: SlidingWindowConfig,
        byte_rate_per_sec: u64,
        playback_rate: f32,
    ) {
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

    /// Updates the stream byte rate (bytes/sec) and recalculates sliding-window byte dimensions.
    pub fn set_stream_byte_rate(&self, byte_rate_per_sec: u64) {
        if byte_rate_per_sec == 0 {
            return;
        }
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
                window.byte_rate_per_sec = byte_rate_per_sec;
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

    /// Updates the playback speed multiplier and dynamically scales forward prefetch/window sizes.
    pub fn set_playback_rate(&self, playback_rate: f32) {
        if !playback_rate.is_finite() || playback_rate <= 0.0 {
            return;
        }
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

    /// Returns the number of retained backward bytes (`Back`) currently buffered behind `read_cursor`.
    pub fn back_buffered_bytes(&self) -> u64 {
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
                .clamp(anchor_offset, range_end);
            cursor.saturating_sub(range_start)
        } else {
            0
        }
    }

    /// Whether this buffer operates as a circular ring buffer.
    #[inline]
    pub fn is_circular(&self) -> bool {
        self.is_circular
    }

    /// Current read cursor offset.
    #[inline]
    pub fn cursor(&self) -> u64 {
        self.read_cursor.load(Ordering::Acquire)
    }

    /// Updates the read cursor offset and wakes any waiting producer thread.
    #[inline]
    pub fn set_cursor(&self, offset: u64) {
        self.read_cursor.store(offset, Ordering::Release);
        if self.is_circular && self.is_producer_waiting.load(Ordering::Acquire) {
            self.data_signal.notify_all();
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
        self.is_eof.store(true, Ordering::Release);
        self.is_buffering.store(false, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Aborts pending reads/writes and wakes all waiting threads.
    pub fn abort(&self) {
        self.should_abort.store(true, Ordering::Release);
        self.is_buffering.store(false, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Clears the abort flag.
    pub fn clear_abort(&self) {
        self.should_abort.store(false, Ordering::Release);
    }

    /// Attaches or updates the on-demand `ByteFetchTask` (`getRealBytes`).
    pub fn set_fetcher(&self, fetcher: Option<ByteFetchTask>) {
        let mut guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Circular {
            fetcher: ref mut f, ..
        } = *guard
        {
            *f = fetcher;
        }
    }

    /// Configures whether a background push streamer thread is actively feeding this circular buffer.
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

    /// Configures the circular buffer anchor offset (`audio_start`) and resets its window if empty.
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

    /// Sets the upper byte boundary of the audio payload (`audio_end`).
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

    /// Sets the virtual stream size for a `Sparse` buffer.
    pub fn set_virtual_size(&self, size: Option<u64>) {
        let mut guard = lock_unpoisoned(&self.backend);
        if let BufferBackend::Sparse {
            ref mut virtual_size,
            ..
        } = *guard
        {
            *virtual_size = size;
        }
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

    /// Commits a chunk at an explicit `stream_offset`.
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

    /// Appends sequential stream bytes into a `Circular` buffer, enforcing backpressure
    /// against `eviction_floor = max(anchor_offset, floor_cursor - back_retention_bytes)`.
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

    /// Non-blocking read at `offset`.
    ///
    /// - If `is_circular == false` and `offset` is not in memory (and no sync fetcher resolves it),
    ///   returns `Err(BufferError::WouldBlock)` immediately so metadata parsers never stall.
    /// - If `is_circular == true`, evaluates progressive block prefetching and on-demand `fetcher` (`getRealBytes`).
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
                            if let Ok(bytes) = fetch_fn(f_pos, f_len) {
                                if !bytes.is_empty() {
                                    let _ = self.commit_chunk(f_pos, &bytes);
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
                Err(_) => {
                    return Err(BufferError::WouldBlock);
                }
            }
        }

        Err(BufferError::WouldBlock)
    }

    /// Blocking read at `offset` with reactive `Condvar` suspension while awaiting stream bytes.
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

    /// Updates dynamic ICY stream metadata bytes in a `Sparse` metadata buffer.
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
}

impl StreamSession {
    /// Default circular audio ring capacity (8 MB).
    pub const DEFAULT_RING_CAPACITY: usize = StreamBuffer::DEFAULT_BODY_CAPACITY;

    /// Creates a new three-buffer `StreamSession`.
    pub fn new(capacity_bytes: usize, total_size: Option<u64>, is_live: bool) -> Self {
        Self::with_config(
            capacity_bytes,
            total_size,
            is_live,
            SlidingWindowConfig::default(),
            None,
        )
    }

    /// Creates a new three-buffer `StreamSession` with an on-demand `ByteFetchTask` (`getRealBytes`).
    pub fn with_fetcher(
        capacity_bytes: usize,
        total_size: Option<u64>,
        is_live: bool,
        fetcher: Option<ByteFetchTask>,
    ) -> Self {
        Self::with_config(
            capacity_bytes,
            total_size,
            is_live,
            SlidingWindowConfig::default(),
            fetcher,
        )
    }

    /// Creates a new three-buffer `StreamSession` with custom [`SlidingWindowConfig`] and optional `ByteFetchTask`.
    pub fn with_config(
        capacity_bytes: usize,
        total_size: Option<u64>,
        is_live: bool,
        config: SlidingWindowConfig,
        fetcher: Option<ByteFetchTask>,
    ) -> Self {
        let head = StreamBuffer::new_linear(
            StreamBuffer::DEFAULT_HEAD_INITIAL_SIZE,
            StreamBuffer::DEFAULT_MIN_GROWTH,
        );
        let body = StreamBuffer::new_circular(capacity_bytes, config, fetcher);
        let metadata = StreamBuffer::new_sparse(
            StreamBuffer::DEFAULT_HEAD_INITIAL_SIZE,
            StreamBuffer::DEFAULT_MIN_GROWTH,
            total_size,
        );

        let session = Self {
            head,
            body,
            metadata,
            audio_start: Arc::new(AtomicU64::new(0)),
            audio_end: Arc::new(AtomicU64::new(u64::MAX)),
            total_size,
            is_live,
            is_decoding_audio: Arc::new(AtomicBool::new(false)),
        };
        if let Some(tot) = total_size {
            session.body.set_audio_end(Some(tot));
        }
        session
    }

    /// Configures the temporal sliding-window parameters, stream byte rate, and playback rate on `Body`.
    pub fn configure_sliding_window(
        &self,
        config: SlidingWindowConfig,
        byte_rate_per_sec: u64,
        playback_rate: f32,
    ) {
        self.body
            .configure_sliding_window(config, byte_rate_per_sec, playback_rate);
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

        let cfg = self
            .body
            .sliding_window_state()
            .map(|s| s.config)
            .unwrap_or_default();
        self.body
            .configure_sliding_window(cfg, byte_rate, playback_rate);
    }

    /// Updates the playback speed multiplier on `Body` to dynamically scale forward prefetch/window sizes.
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

    /// Unread forward bytes (`Ahead`) currently buffered ahead of `read_cursor` in `Body`.
    pub fn ahead_bytes(&self) -> u64 {
        self.body.ahead_bytes()
    }

    /// Retained backward bytes (`Back`) currently buffered behind `read_cursor` in `Body`.
    pub fn back_buffered_bytes(&self) -> u64 {
        self.body.back_buffered_bytes()
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

    /// Classifies `initial_data` and optional `tail_data` via [`crate::decoder::classifier::StreamClassifier::classify_initial_stream`]
    /// and populates `Head`, `Body`, and `Metadata` in a single unified pass.
    pub fn ingest_classified(
        &self,
        initial_data: &[u8],
        tail_data: Option<(&[u8], Option<u64>)>,
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
                    let _ = self.write_at(boundary.audio_start as u64, audio_bytes);
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

    /// Populates the `Head` linear buffer and mirrors header metadata into the `Metadata` sparse buffer.
    pub fn set_head(&self, head_bytes: &[u8]) {
        self.head.set_linear_bytes(head_bytes);
        let _ = self.metadata.commit_chunk(0, head_bytes);
    }

    /// Populates trailing metadata at `tail_offset` in the `Metadata` sparse buffer
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

    /// Configures the byte offset where the audio payload begins in the stream.
    pub fn set_audio_start(&self, start: u64) {
        self.audio_start.store(start, Ordering::Release);
        self.body.set_circular_anchor(start);
    }

    /// Configures the byte offset where the audio payload ends in the stream.
    pub fn set_audio_end(&self, end: u64) {
        self.audio_end.store(end, Ordering::Release);
        self.body.set_audio_end(Some(end));
    }

    /// Configures whether the consumer is actively decoding audio frames.
    pub fn set_decoding_audio(&self, decoding: bool) {
        self.is_decoding_audio.store(decoding, Ordering::Release);
    }

    /// Whether the consumer is actively decoding audio frames.
    #[inline]
    pub fn is_decoding_audio(&self) -> bool {
        self.is_decoding_audio.load(Ordering::Acquire)
    }

    /// Feeds a sequential audio chunk into the circular `Body` buffer.
    pub fn feed_chunk(&self, chunk: &[u8]) -> Result<usize, BufferError> {
        let cursor = self.body.cursor();
        self.body.feed_sequential(cursor, chunk)
    }

    /// Suspends the producer thread until `min_free_bytes` are available in the circular `Body` buffer.
    pub fn wait_for_free_space(&self, min_free_bytes: usize, timeout: Duration) -> bool {
        self.body.wait_for_free_space(min_free_bytes, timeout)
    }

    /// Suspends the calling thread until signaled or `timeout` elapses.
    pub fn wait_signal(&self, timeout: Duration) {
        self.body.wait_signal(timeout);
    }

    /// Writes `bytes` at an explicit `offset` into the appropriate tier (`Head` or `Body`).
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

    /// Non-blocking composite read across `Head`, `Body`, and (when probing) `Metadata`.
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
        match self.body.read_at(offset, out) {
            Ok(0) if !decoding && audio_end != u64::MAX && offset < audio_end => {
                // During container probing, zero-fill unbuffered mdat gap up to trailing moov atom
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
                if !decoding && audio_end != u64::MAX && offset < audio_end =>
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

    /// Blocking composite read across `Head` and `Body` with `Condvar` suspension.
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
                    if self.body.should_abort.load(Ordering::Acquire) {
                        return Err(BufferError::Aborted);
                    }
                    if self.body.is_eof() {
                        return Ok(0);
                    }
                    let elapsed = start_time.elapsed();
                    if elapsed >= max_wait {
                        return Err(BufferError::WouldBlock);
                    }
                    let slice_wait = (max_wait - elapsed).min(Duration::from_millis(20));
                    let guard = lock_unpoisoned(&self.body.backend);
                    if self.body.should_abort.load(Ordering::Acquire) {
                        return Err(BufferError::Aborted);
                    }
                    let _ = self.body.data_signal.wait_timeout(guard, slice_wait);
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Advances the active read cursor on `Body`.
    pub fn advance_read_cursor(&self, cursor: u64) {
        self.body.set_cursor(cursor);
    }

    /// Flushes `Body` to `new_stream_offset` after an uncached seek.
    pub fn flush(&self, new_stream_offset: u64) {
        self.body.flush_circular(new_stream_offset);
    }

    /// Updates the read cursor to `target_offset`, serving from `[Back | Ahead]` on a cache hit
    /// or re-anchoring the circular window (`flush_circular`) on an uncached seek during audio decoding.
    pub fn seek(&self, target_offset: u64) -> Result<(), BufferError> {
        let head_len = self.head.linear_len() as u64;
        let audio_start = self.audio_start.load(Ordering::Acquire);
        let (r_start, r_end, _) = self.body.circular_metrics();
        let is_eof = self.body.is_eof();

        let in_head = target_offset < head_len;
        let in_body = target_offset >= r_start
            && (target_offset < r_end || (is_eof && target_offset <= r_end));

        if in_head || in_body {
            self.body.set_cursor(target_offset);
            self.body.is_buffering.store(false, Ordering::Release);
            self.body.data_signal.notify_all();
        } else if self.is_decoding_audio.load(Ordering::Acquire) && target_offset >= audio_start {
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
        self.head.mark_eof();
        self.body.mark_eof();
        self.metadata.mark_eof();
    }

    /// Aborts pending operations on `Head`, `Body`, and `Metadata`.
    pub fn abort(&self) {
        self.head.abort();
        self.body.abort();
        self.metadata.abort();
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

    /// Synthesizes a contiguous metadata byte vector from `Metadata` (or initial probe bytes).
    pub fn get_meta_bytes(&self) -> Vec<u8> {
        let bytes = self.metadata.synthesize_meta_bytes();
        if !bytes.is_empty() {
            return bytes;
        }
        let mut probe = [0u8; 64];
        let start = self.audio_start.load(Ordering::Acquire);
        if let Ok(n) = self.body.read_at(start, &mut probe) {
            return probe[..n].to_vec();
        }
        Vec::new()
    }

    /// Copies synthesized metadata bytes into `out`.
    pub fn copy_meta_bytes(&self, out: &mut [u8]) -> usize {
        let bytes = self.get_meta_bytes();
        let to_copy = out.len().min(bytes.len());
        out[..to_copy].copy_from_slice(&bytes[..to_copy]);
        to_copy
    }

    /// Updates dynamic ICY stream metadata in `Metadata`.
    pub fn set_icy_meta(&self, data: &[u8]) {
        self.metadata.set_icy_meta(data);
    }

    /// Audio start offset in bytes.
    #[inline]
    pub fn audio_start(&self) -> u64 {
        self.audio_start.load(Ordering::Acquire)
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

    /// Circular audio body capacity in bytes.
    #[inline]
    pub fn ring_capacity(&self) -> usize {
        self.body.circular_metrics().2
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

    /// Whether `audio_end` boundary has been locked.
    #[inline]
    pub fn is_tail_locked(&self) -> bool {
        self.audio_end.load(Ordering::Acquire) != u64::MAX
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

    /// Creates a [`DemuxedStreamReader`] over this `StreamSession`.
    pub fn create_reader(&self) -> super::demux_reader::DemuxedStreamReader {
        super::demux_reader::DemuxedStreamReader::new(self.clone())
    }
}
