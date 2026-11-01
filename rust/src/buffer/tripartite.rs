//! Deterministic Three-Tier Media Buffer (`HeadSegment`, `RingSegment`, `TailSegment`).
//!
//! Strictly separates byte storage and sliding-window backpressure from format sniffing.

use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferState {
    Uninitialized = 0,
    ProbingHead = 1,
    Ready = 2,
    Buffering = 3,
    Eof = 4,
    Aborted = 5,
}

#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct BufferRange {
    pub start_byte: i64,
    pub end_byte: i64,
    pub total_bytes: i64,
    pub read_cursor_byte: i64,
    pub fill_percentage: f32,
    pub stream_percentage: f32,
    pub is_buffering: i32,
    pub is_eof: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferError {
    InvalidArgs,
    Busy,
    Aborted,
    Eof,
    OutOfMemory,
    WouldBlock,
}

/// Tier 1: Pinned header bytes `[0..data.len())` and audio payload start offset.
pub struct HeadSegment {
    pub data: Vec<u8>,
    pub locked: bool,
    pub audio_start: u64,
}

impl HeadSegment {
    fn new(capacity: usize) -> Self {
        Self {
            data: Vec::with_capacity(capacity),
            locked: false,
            audio_start: 0,
        }
    }

    fn set_bytes(&mut self, head: &[u8]) {
        self.data.clear();
        self.data.extend_from_slice(head);
        self.locked = true;
    }

    fn read_at(&self, offset: u64, out: &mut [u8]) -> usize {
        if offset >= self.data.len() as u64 {
            return 0;
        }
        let rel = offset as usize;
        let avail = self.data.len() - rel;
        let to_copy = out.len().min(avail);
        out[..to_copy].copy_from_slice(&self.data[rel..rel + to_copy]);
        to_copy
    }
}

/// Tier 2: Pinned trailing metadata/index bytes `[start..start + data.len())`.
#[derive(Default)]
pub struct TailSegment {
    pub data: Vec<u8>,
    pub locked: bool,
    pub start: u64,
    pub audio_end: Option<u64>,
}

impl TailSegment {
    fn set_bytes(&mut self, tail: &[u8], start_offset: u64) {
        self.data.clear();
        self.data.extend_from_slice(tail);
        self.start = start_offset;
        self.locked = true;
    }

    fn read_at(&self, offset: u64, out: &mut [u8]) -> Option<usize> {
        if !self.locked || self.data.is_empty() || offset < self.start {
            return None;
        }
        let rel = (offset - self.start) as usize;
        if rel >= self.data.len() {
            return Some(0);
        }
        let avail = self.data.len() - rel;
        let to_copy = out.len().min(avail);
        out[..to_copy].copy_from_slice(&self.data[rel..rel + to_copy]);
        Some(to_copy)
    }
}

/// Tier 3: Sliding circular byte buffer `[range_start..range_end)`.
pub struct RingSegment {
    pub data: Vec<u8>,
    pub capacity: usize,
    pub range_start: u64,
    pub range_end: u64,
}

impl RingSegment {
    fn new(capacity: usize) -> Self {
        Self {
            data: vec![0u8; capacity],
            capacity,
            range_start: 0,
            range_end: 0,
        }
    }

    fn reset(&mut self, offset: u64) {
        self.range_start = offset;
        self.range_end = offset;
    }

    fn append(
        &mut self,
        audio_start: u64,
        read_cursor: u64,
        chunk: &[u8],
    ) -> Result<usize, BufferError> {
        let floor_pos = read_cursor.max(audio_start);
        let write_offset = self.range_end;
        let write_end = write_offset + chunk.len() as u64;

        if write_end.saturating_sub(floor_pos) > self.capacity as u64 {
            return Err(BufferError::Busy);
        }

        self.write_raw(audio_start, write_offset, chunk);
        self.range_end = write_end;
        if self.range_end.saturating_sub(self.range_start) > self.capacity as u64 {
            self.range_start = self.range_end - self.capacity as u64;
        }
        Ok(chunk.len())
    }

    fn write_raw(&mut self, audio_start: u64, offset: u64, bytes: &[u8]) {
        let start_pos = (offset.saturating_sub(audio_start) as usize) % self.capacity;
        let first_len = (self.capacity - start_pos).min(bytes.len());
        self.data[start_pos..start_pos + first_len].copy_from_slice(&bytes[..first_len]);
        if bytes.len() > first_len {
            let second_len = bytes.len() - first_len;
            self.data[..second_len].copy_from_slice(&bytes[first_len..]);
        }
    }

    fn read_at(
        &self,
        audio_start: u64,
        offset: u64,
        max_end: Option<u64>,
        out: &mut [u8],
    ) -> usize {
        if offset < self.range_start || offset >= self.range_end {
            return 0;
        }
        let effective_end = max_end.map(|e| self.range_end.min(e)).unwrap_or(self.range_end);
        if offset >= effective_end {
            return 0;
        }
        let available = (effective_end - offset) as usize;
        let to_copy = out.len().min(available);
        if to_copy == 0 {
            return 0;
        }

        let rel_pos = (offset.saturating_sub(audio_start) as usize) % self.capacity;
        let first_len = (self.capacity - rel_pos).min(to_copy);
        out[..first_len].copy_from_slice(&self.data[rel_pos..rel_pos + first_len]);
        if to_copy > first_len {
            let second_len = to_copy - first_len;
            out[first_len..to_copy].copy_from_slice(&self.data[..second_len]);
        }
        to_copy
    }
}

pub struct TripartiteBufferInner {
    pub state: BufferState,
    pub head: HeadSegment,
    pub tail: TailSegment,
    pub ring: RingSegment,
    pub read_cursor: u64,
    pub total_size: Option<u64>,
    pub is_live: bool,
    pub is_eof: bool,
    pub should_abort: bool,
    pub is_decoding_audio: bool,
    pub icy_meta_data: Vec<u8>,
    pub meta_version: u32,
}

#[derive(Clone)]
pub struct TripartiteBuffer {
    inner: Arc<Mutex<TripartiteBufferInner>>,
    data_ready_cond: Arc<Condvar>,
}

impl TripartiteBuffer {
    pub const DEFAULT_HEAD_CAPACITY: usize = 256 * 1024;
    pub const DEFAULT_RING_CAPACITY: usize = 8 * 1024 * 1024;

    pub fn new(capacity_bytes: usize, total_size: Option<u64>, is_live: bool) -> Self {
        let ring_capacity = if capacity_bytes > 0 {
            capacity_bytes
        } else {
            Self::DEFAULT_RING_CAPACITY
        };

        let inner = TripartiteBufferInner {
            state: BufferState::ProbingHead,
            head: HeadSegment::new(Self::DEFAULT_HEAD_CAPACITY),
            tail: TailSegment::default(),
            ring: RingSegment::new(ring_capacity),
            read_cursor: 0,
            total_size,
            is_live,
            is_eof: false,
            should_abort: false,
            is_decoding_audio: false,
            icy_meta_data: Vec::new(),
            meta_version: 0,
        };

        Self {
            inner: Arc::new(Mutex::new(inner)),
            data_ready_cond: Arc::new(Condvar::new()),
        }
    }

    pub fn set_head(&self, head: &[u8]) {
        let mut b = self.inner.lock().unwrap();
        b.head.set_bytes(head);
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn set_tail(&self, tail: &[u8], tail_offset: Option<u64>) {
        let mut b = self.inner.lock().unwrap();
        let resolved_offset = tail_offset
            .or_else(|| b.total_size.map(|tot| tot.saturating_sub(tail.len() as u64)))
            .unwrap_or(0);
        b.tail.set_bytes(tail, resolved_offset);
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn probe_tail(&self, tail: &[u8], tail_offset: u64) {
        self.set_tail(tail, Some(tail_offset));
    }

    pub fn tail_data(&self) -> Vec<u8> {
        self.inner.lock().unwrap().tail.data.clone()
    }

    pub fn set_audio_start(&self, start: u64) {
        let mut b = self.inner.lock().unwrap();
        b.head.audio_start = start;
        b.head.locked = true;
        if b.ring.range_end < start {
            b.ring.reset(start);
        }
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn set_audio_end(&self, end: u64) {
        let mut b = self.inner.lock().unwrap();
        b.tail.audio_end = Some(end);
        b.tail.locked = true;
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn set_decoding_audio(&self, decoding: bool) {
        self.inner.lock().unwrap().is_decoding_audio = decoding;
    }

    /// Deterministically appends `chunk` into the circular ring tier.
    pub fn feed_chunk(&self, chunk: &[u8]) -> Result<usize, BufferError> {
        let mut b = self.inner.lock().unwrap();
        if b.should_abort || b.state == BufferState::Aborted {
            return Err(BufferError::Aborted);
        }
        if chunk.is_empty() {
            return Ok(0);
        }

        if !b.head.locked {
            b.head.locked = true;
        }

        let audio_start = b.head.audio_start;
        let read_cursor = b.read_cursor;
        let written = b.ring.append(audio_start, read_cursor, chunk)?;

        if b.state == BufferState::ProbingHead || b.state == BufferState::Buffering {
            b.state = BufferState::Ready;
        }

        self.data_ready_cond.notify_all();
        Ok(written)
    }

    /// Deterministically writes `data` at an exact stream `offset`.
    pub fn write_at(&self, offset: u64, data: &[u8]) -> Result<usize, BufferError> {
        let mut b = self.inner.lock().unwrap();
        if b.should_abort || b.state == BufferState::Aborted {
            return Err(BufferError::Aborted);
        }
        if data.is_empty() {
            return Ok(0);
        }

        if offset == b.ring.range_end {
            if !b.head.locked {
                b.head.locked = true;
            }
            let audio_start = b.head.audio_start;
            let read_cursor = b.read_cursor;
            let written = b.ring.append(audio_start, read_cursor, data)?;
            if b.state == BufferState::ProbingHead || b.state == BufferState::Buffering {
                b.state = BufferState::Ready;
            }
            self.data_ready_cond.notify_all();
            return Ok(written);
        }

        if offset >= b.ring.range_start && offset + (data.len() as u64) <= b.ring.range_end {
            let audio_start = b.head.audio_start;
            b.ring.write_raw(audio_start, offset, data);
            self.data_ready_cond.notify_all();
            return Ok(data.len());
        }

        if !b.head.locked && offset < Self::DEFAULT_HEAD_CAPACITY as u64 {
            let end = (offset as usize) + data.len();
            if end > b.head.data.len() {
                b.head.data.resize(end, 0);
            }
            b.head.data[offset as usize..end].copy_from_slice(data);
            self.data_ready_cond.notify_all();
            return Ok(data.len());
        }

        Err(BufferError::InvalidArgs)
    }

    /// Deterministic black-box read across Head, Tail, and Ring tiers.
    pub fn read_at(&self, offset: u64, out: &mut [u8]) -> Result<usize, BufferError> {
        let b = self.inner.lock().unwrap();
        if b.should_abort || b.state == BufferState::Aborted {
            return Err(BufferError::Aborted);
        }
        if out.is_empty() {
            return Ok(0);
        }
        if let Some(total) = b.total_size {
            if offset >= total {
                return Ok(0);
            }
        }

        // Tier 1: Pinned Head Segment (with contiguous spillover into Ring)
        if offset < b.head.data.len() as u64 {
            let head_copied = b.head.read_at(offset, out);
            let mut total_copied = head_copied;
            if b.head.locked && out.len() > head_copied {
                let next_offset = offset + head_copied as u64;
                total_copied += b.ring.read_at(
                    b.head.audio_start,
                    next_offset,
                    b.tail.audio_end,
                    &mut out[head_copied..],
                );
            }
            return Ok(total_copied);
        }

        // Tier 2: Pinned Tail Segment & Audio End Boundary
        if b.tail.locked {
            if let Some(audio_end) = b.tail.audio_end {
                if offset >= audio_end && b.is_decoding_audio {
                    return Ok(0);
                }
            }
            if let Some(tail_copied) = b.tail.read_at(offset, out) {
                return Ok(tail_copied);
            }
        }

        // Tier 3: Sliding Circular Ring Segment
        if offset >= b.ring.range_start && offset < b.ring.range_end {
            let max_end = if b.tail.locked { b.tail.audio_end } else { None };
            let copied = b.ring.read_at(b.head.audio_start, offset, max_end, out);
            if copied > 0 {
                return Ok(copied);
            }
            return if b.is_eof { Ok(0) } else { Err(BufferError::WouldBlock) };
        }

        if offset >= b.ring.range_end {
            let reached_total = b.total_size.map(|tot| b.ring.range_end >= tot).unwrap_or(false);
            return if b.is_eof || reached_total {
                Ok(0)
            } else {
                Err(BufferError::WouldBlock)
            };
        }

        if b.is_live {
            return Err(BufferError::WouldBlock);
        }

        Err(BufferError::InvalidArgs)
    }

    pub fn read_blocking(
        &self,
        offset: u64,
        out: &mut [u8],
        timeout: Option<Duration>,
    ) -> Result<usize, BufferError> {
        let mut remaining = timeout.unwrap_or(Duration::from_millis(2000));

        loop {
            match self.read_at(offset, out) {
                Ok(bytes) => return Ok(bytes),
                Err(BufferError::WouldBlock) => {
                    let mut b = self.inner.lock().unwrap();
                    if b.is_eof {
                        return Ok(0);
                    }
                    b.state = BufferState::Buffering;

                    let start_wait = Instant::now();
                    let (guard, wait_res) = self.data_ready_cond.wait_timeout(b, remaining).unwrap();
                    if guard.should_abort || guard.state == BufferState::Aborted {
                        return Err(BufferError::Aborted);
                    }
                    drop(guard);

                    let elapsed = start_wait.elapsed();
                    if wait_res.timed_out() || elapsed >= remaining {
                        return Err(BufferError::WouldBlock);
                    }
                    remaining = remaining.saturating_sub(elapsed);
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Updates the read cursor for ring backpressure without altering EOF state.
    pub fn advance_read_cursor(&self, cursor: u64) {
        let mut b = self.inner.lock().unwrap();
        b.read_cursor = cursor;
    }

    pub fn flush(&self, new_stream_offset: u64) {
        let mut b = self.inner.lock().unwrap();
        b.ring.reset(new_stream_offset);
        b.read_cursor = new_stream_offset;
        b.is_eof = false;
        b.state = BufferState::Buffering;
        self.data_ready_cond.notify_all();
    }

    pub fn seek(&self, target_offset: u64) -> Result<(), BufferError> {
        let mut b = self.inner.lock().unwrap();
        b.read_cursor = target_offset;
        if target_offset < b.head.data.len() as u64
            || (target_offset >= b.ring.range_start && target_offset < b.ring.range_end)
        {
            if !b.is_eof {
                b.state = BufferState::Ready;
            }
        } else if !b.is_eof {
            b.state = BufferState::Buffering;
        }
        self.data_ready_cond.notify_all();
        Ok(())
    }

    pub fn try_seek_cached(&self, target_offset: u64) -> (bool, bool) {
        let mut b = self.inner.lock().unwrap();
        let effective_audio_start = b.head.audio_start;
        let effective_audio_end = b.tail.audio_end.or(b.total_size).unwrap_or(0);
        let audio_target = target_offset.max(effective_audio_start);

        let in_ring = audio_target >= b.ring.range_start
            && (audio_target < b.ring.range_end
                || (b.is_eof && audio_target <= b.ring.range_end)
                || (effective_audio_end > 0
                    && b.ring.range_end >= effective_audio_end
                    && audio_target <= effective_audio_end));
        let contiguous_from_start = b.ring.range_start <= effective_audio_start;
        let full_file_in_ram = b
            .total_size
            .map(|tot| {
                tot > 0
                    && contiguous_from_start
                    && (b.is_eof
                        || (effective_audio_end > 0 && b.ring.range_end >= effective_audio_end))
            })
            .unwrap_or(false);

        if in_ring || full_file_in_ram {
            let seek_from_start = full_file_in_ram || contiguous_from_start;
            b.read_cursor = if seek_from_start && target_offset == 0 {
                0
            } else {
                audio_target
            };
            b.should_abort = false;
            b.state = if full_file_in_ram || (b.is_eof && in_ring) {
                BufferState::Eof
            } else {
                BufferState::Ready
            };
            if full_file_in_ram {
                b.is_eof = true;
            }
            self.data_ready_cond.notify_all();
            (true, contiguous_from_start)
        } else {
            (false, false)
        }
    }

    pub fn mark_eof(&self) {
        let mut b = self.inner.lock().unwrap();
        b.is_eof = true;
        b.state = BufferState::Eof;
        self.data_ready_cond.notify_all();
    }

    pub fn abort(&self) {
        let mut b = self.inner.lock().unwrap();
        b.should_abort = true;
        b.state = BufferState::Aborted;
        self.data_ready_cond.notify_all();
    }

    pub fn clear_abort(&self) {
        let mut b = self.inner.lock().unwrap();
        b.should_abort = false;
        if b.state == BufferState::Aborted {
            b.state = if b.is_eof {
                BufferState::Eof
            } else {
                BufferState::Ready
            };
        }
    }

    pub fn is_starving(&self) -> bool {
        let b = self.inner.lock().unwrap();
        !b.is_eof && (b.read_cursor >= b.ring.range_end || b.state == BufferState::Buffering)
    }

    pub fn is_eof_and_exhausted(&self) -> bool {
        let b = self.inner.lock().unwrap();
        b.is_eof && b.read_cursor >= b.ring.range_end
    }

    pub fn set_buffering(&self, buffering: bool) {
        let mut b = self.inner.lock().unwrap();
        if buffering {
            b.state = BufferState::Buffering;
        } else if b.state == BufferState::Buffering {
            b.state = BufferState::Ready;
        }
    }

    pub fn get_range(&self) -> BufferRange {
        let b = self.inner.lock().unwrap();
        let total = b.total_size.map(|v| v as i64).unwrap_or(-1);
        let buffered_bytes = b.ring.range_end.saturating_sub(b.ring.range_start) as f32;
        let fill_pct = (buffered_bytes / b.ring.capacity as f32).clamp(0.0, 1.0);
        let stream_pct = if total > 0 {
            (b.ring.range_end as f32 / total as f32).clamp(0.0, 1.0)
        } else {
            fill_pct
        };

        BufferRange {
            start_byte: b.ring.range_start as i64,
            end_byte: b.ring.range_end as i64,
            total_bytes: total,
            read_cursor_byte: b.read_cursor as i64,
            fill_percentage: fill_pct,
            stream_percentage: stream_pct,
            is_buffering: i32::from(b.state == BufferState::Buffering),
            is_eof: i32::from(b.is_eof),
        }
    }

    pub fn meta_version(&self) -> u32 {
        self.inner.lock().unwrap().meta_version
    }

    pub fn get_meta_bytes(&self) -> Vec<u8> {
        let b = self.inner.lock().unwrap();
        let mut out = Vec::with_capacity(
            b.head.data.len() + b.tail.data.len() + b.icy_meta_data.len(),
        );
        out.extend_from_slice(&b.head.data);
        out.extend_from_slice(&b.tail.data);
        out.extend_from_slice(&b.icy_meta_data);
        out
    }

    pub fn copy_meta_bytes(&self, out: &mut [u8]) -> usize {
        let bytes = self.get_meta_bytes();
        let to_copy = out.len().min(bytes.len());
        out[..to_copy].copy_from_slice(&bytes[..to_copy]);
        to_copy
    }

    pub fn set_icy_meta(&self, data: &[u8]) {
        let mut b = self.inner.lock().unwrap();
        b.icy_meta_data.clear();
        b.icy_meta_data.extend_from_slice(data);
        b.meta_version = b.meta_version.wrapping_add(1);
    }

    pub fn audio_start(&self) -> u64 {
        self.inner.lock().unwrap().head.audio_start
    }

    pub fn audio_end(&self) -> Option<u64> {
        self.inner.lock().unwrap().tail.audio_end
    }

    pub fn is_live(&self) -> bool {
        self.inner.lock().unwrap().is_live
    }

    pub fn range_start(&self) -> u64 {
        self.inner.lock().unwrap().ring.range_start
    }

    pub fn range_end(&self) -> u64 {
        self.inner.lock().unwrap().ring.range_end
    }

    pub fn is_tail_locked(&self) -> bool {
        let b = self.inner.lock().unwrap();
        b.tail.locked && !b.tail.data.is_empty()
    }

    pub fn is_fully_buffered(&self) -> bool {
        let b = self.inner.lock().unwrap();
        b.total_size.map(|tot| b.ring.range_end >= tot || b.is_eof).unwrap_or(false)
    }

    pub fn is_eof(&self) -> bool {
        let b = self.inner.lock().unwrap();
        b.is_eof || b.total_size.map(|tot| b.ring.range_end >= tot).unwrap_or(false)
    }

    pub fn head_size(&self) -> usize {
        self.inner.lock().unwrap().head.data.len()
    }

    pub fn ring_capacity(&self) -> usize {
        self.inner.lock().unwrap().ring.capacity
    }

    pub fn total_size(&self) -> Option<u64> {
        self.inner.lock().unwrap().total_size
    }

    pub fn create_reader(&self) -> super::stream_reader::BufferStreamReader {
        super::stream_reader::BufferStreamReader::new(self.clone())
    }
}
