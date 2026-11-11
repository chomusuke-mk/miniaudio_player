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

#[cfg(not(target_arch = "wasm32"))]
use crate::sync::MonotonicInstant;

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
    /// Circular sliding window with reactive watermark prefetching (used for `Body`).
    Circular {
        storage: Vec<u8>,
        capacity: usize,
        anchor_offset: u64,
        range_start: u64,
        range_end: u64,
        audio_end: Option<u64>,
        prefetch_watermark_pct: f32,
        last_prefetch_trigger: u64,
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
            let prev_data = chunks.remove(&prev_start).unwrap();
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

    // Merge any subsequent chunks that overlap or are contiguous with `new_end`
    loop {
        let next_key = chunks.range(new_start..=new_end).next().map(|(&k, _)| k);
        let Some(k) = next_key else {
            break;
        };
        let next_data = chunks.remove(&k).unwrap();
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
    /// Default proactive consumption watermark (70%).
    pub const DEFAULT_WATERMARK_PCT: f32 = 0.70;

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
            is_eof: AtomicBool::new(false),
            should_abort: AtomicBool::new(false),
            version: AtomicU32::new(0),
        })
    }

    /// Creates a circular sliding-window `StreamBuffer` (used for `Body`).
    pub fn new_circular(
        capacity: usize,
        prefetch_watermark_pct: f32,
        fetcher: Option<ByteFetchTask>,
    ) -> Arc<Self> {
        let cap = if capacity > 0 {
            capacity
        } else {
            Self::DEFAULT_BODY_CAPACITY
        };
        Arc::new(Self {
            backend: Mutex::new(BufferBackend::Circular {
                storage: vec![0u8; cap],
                capacity: cap,
                anchor_offset: 0,
                range_start: 0,
                range_end: 0,
                audio_end: None,
                prefetch_watermark_pct: prefetch_watermark_pct.clamp(0.1, 0.95),
                last_prefetch_trigger: 0,
                push_streaming: false,
                fetcher,
            }),
            data_signal: Condvar::new(),
            read_cursor: AtomicU64::new(0),
            is_circular: true,
            is_buffering: AtomicBool::new(false),
            is_eof: AtomicBool::new(false),
            should_abort: AtomicBool::new(false),
            version: AtomicU32::new(0),
        })
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

    /// Updates the read cursor offset.
    #[inline]
    pub fn set_cursor(&self, offset: u64) {
        self.read_cursor.store(offset, Ordering::Release);
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
        let mut guard = self.backend.lock().unwrap();
        if let BufferBackend::Circular {
            fetcher: ref mut f, ..
        } = *guard
        {
            *f = fetcher;
        }
    }

    /// Configures whether a background push streamer thread is actively feeding this circular buffer.
    pub fn set_push_streaming(&self, active: bool) {
        let mut guard = self.backend.lock().unwrap();
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
        let mut guard = self.backend.lock().unwrap();
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
        let mut guard = self.backend.lock().unwrap();
        if let BufferBackend::Circular {
            ref mut audio_end, ..
        } = *guard
        {
            *audio_end = end;
        }
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
    }

    /// Sets the virtual stream size for a `Sparse` buffer.
    pub fn set_virtual_size(&self, size: Option<u64>) {
        let mut guard = self.backend.lock().unwrap();
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
        let guard = self.backend.lock().unwrap();
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
            let mut guard = self.backend.lock().unwrap();
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
        let guard = self.backend.lock().unwrap();
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
            let mut guard = self.backend.lock().unwrap();
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
                }
            }
        }

        self.is_buffering.store(false, Ordering::Release);
        self.version.fetch_add(1, Ordering::Release);
        self.data_signal.notify_all();
        Ok(chunk.len())
    }

    /// Appends sequential stream bytes into a `Circular` buffer, enforcing backpressure against `floor_cursor`.
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
            let mut guard = self.backend.lock().unwrap();
            match *guard {
                BufferBackend::Circular {
                    ref mut storage,
                    capacity,
                    anchor_offset,
                    ref mut range_start,
                    ref mut range_end,
                    ..
                } => {
                    let floor_pos = floor_cursor.max(anchor_offset);
                    let write_offset = *range_end;
                    let write_end = write_offset + chunk.len() as u64;

                    if write_end.saturating_sub(floor_pos) > capacity as u64 {
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
            let mut guard = self.backend.lock().unwrap();
            if let BufferBackend::Circular {
                ref mut anchor_offset,
                ref mut range_start,
                ref mut range_end,
                ref mut last_prefetch_trigger,
                ..
            } = *guard
            {
                *anchor_offset = new_stream_offset;
                *range_start = new_stream_offset;
                *range_end = new_stream_offset;
                *last_prefetch_trigger = 0;
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
    /// - If `is_circular == true`, evaluates watermark prefetching and on-demand `fetcher` (`getRealBytes`).
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
            let mut guard = self.backend.lock().unwrap();
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
                    prefetch_watermark_pct,
                    ref mut last_prefetch_trigger,
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

                        // Proactive consumption watermark check (when in pull mode without active push thread)
                        let new_cursor = offset + to_copy as u64;
                        let unread_ahead = range_end.saturating_sub(new_cursor);
                        let ahead_ratio = unread_ahead as f32 / capacity as f32;
                        let reached_end = audio_end.map(|e| range_end >= e).unwrap_or(false)
                            || self.is_eof.load(Ordering::Acquire);

                        if !push_streaming
                            && !reached_end
                            && ahead_ratio <= (1.0 - prefetch_watermark_pct)
                            && *last_prefetch_trigger < range_end
                        {
                            if let Some(ref f) = fetcher {
                                *last_prefetch_trigger = range_end;
                                let fetch_len = (capacity / 2).max(32768);
                                pending_prefetch = Some((f.clone(), range_end, fetch_len));
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

                    let is_far_jump = offset < range_start || offset > range_end.saturating_add(262144);
                    if let Some(ref f) = fetcher {
                        if !push_streaming || is_far_jump {
                            self.is_buffering.store(true, Ordering::Release);
                            cache_miss_fetch = Some((f.clone(), offset, capacity.min(524288)));
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
                    let guard = self.backend.lock().unwrap();
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
        #[cfg(target_arch = "wasm32")]
        let _ = timeout;
        #[cfg(not(target_arch = "wasm32"))]
        let max_wait = timeout.unwrap_or(Duration::from_millis(2000));
        #[cfg(not(target_arch = "wasm32"))]
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

                    #[cfg(target_arch = "wasm32")]
                    {
                        return Err(BufferError::WouldBlock);
                    }

                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        let elapsed = start_time.elapsed();
                        if elapsed >= max_wait {
                            return Err(BufferError::WouldBlock);
                        }
                        let remaining = max_wait - elapsed;
                        let slice_wait = remaining.min(Duration::from_millis(20));
                        let guard = self.backend.lock().unwrap();
                        if self.should_abort.load(Ordering::Acquire) {
                            return Err(BufferError::Aborted);
                        }
                        let _ = self.data_signal.wait_timeout(guard, slice_wait);
                    }
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Updates dynamic ICY stream metadata bytes in a `Sparse` metadata buffer.
    pub fn set_icy_meta(&self, data: &[u8]) {
        {
            let mut guard = self.backend.lock().unwrap();
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
        let guard = self.backend.lock().unwrap();
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
        let guard = self.backend.lock().unwrap();
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
        Self::with_fetcher(capacity_bytes, total_size, is_live, None)
    }

    /// Creates a new three-buffer `StreamSession` with an on-demand `ByteFetchTask` (`getRealBytes`).
    pub fn with_fetcher(
        capacity_bytes: usize,
        total_size: Option<u64>,
        is_live: bool,
        fetcher: Option<ByteFetchTask>,
    ) -> Self {
        let head = StreamBuffer::new_linear(
            StreamBuffer::DEFAULT_HEAD_INITIAL_SIZE,
            StreamBuffer::DEFAULT_MIN_GROWTH,
        );
        let body = StreamBuffer::new_circular(
            capacity_bytes,
            StreamBuffer::DEFAULT_WATERMARK_PCT,
            fetcher,
        );
        let metadata = StreamBuffer::new_sparse(
            StreamBuffer::DEFAULT_HEAD_INITIAL_SIZE,
            StreamBuffer::DEFAULT_MIN_GROWTH,
            total_size,
        );

        Self {
            head,
            body,
            metadata,
            audio_start: Arc::new(AtomicU64::new(0)),
            audio_end: Arc::new(AtomicU64::new(u64::MAX)),
            total_size,
            is_live,
            is_decoding_audio: Arc::new(AtomicBool::new(false)),
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
                    let _ = self.feed_chunk(audio_bytes);
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
        let guard = self.metadata.backend.lock().unwrap();
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

        // 3. When probing containers (not decoding audio), allow reading trailing metadata (e.g. MP4 moov)
        if !decoding && audio_end != u64::MAX && offset >= audio_end {
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
        #[cfg(target_arch = "wasm32")]
        let _ = timeout;
        #[cfg(not(target_arch = "wasm32"))]
        let max_wait = timeout.unwrap_or(Duration::from_millis(2000));
        #[cfg(not(target_arch = "wasm32"))]
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
                    #[cfg(target_arch = "wasm32")]
                    {
                        return Err(BufferError::WouldBlock);
                    }
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        let elapsed = start_time.elapsed();
                        if elapsed >= max_wait {
                            return Err(BufferError::WouldBlock);
                        }
                        let slice_wait = (max_wait - elapsed).min(Duration::from_millis(20));
                        let guard = self.body.backend.lock().unwrap();
                        if self.body.should_abort.load(Ordering::Acquire) {
                            return Err(BufferError::Aborted);
                        }
                        let _ = self.body.data_signal.wait_timeout(guard, slice_wait);
                    }
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

    /// Updates the read cursor to `target_offset` and updates buffering state.
    pub fn seek(&self, target_offset: u64) -> Result<(), BufferError> {
        self.body.set_cursor(target_offset);
        let head_len = self.head.linear_len() as u64;
        let (r_start, r_end, _) = self.body.circular_metrics();
        if target_offset < head_len || (target_offset >= r_start && target_offset < r_end) {
            self.body.is_buffering.store(false, Ordering::Release);
        } else if !self.body.is_eof() {
            self.body.is_buffering.store(true, Ordering::Release);
        }
        self.body.data_signal.notify_all();
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
