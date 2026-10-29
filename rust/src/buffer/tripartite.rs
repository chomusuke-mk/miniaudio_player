use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

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

pub struct TripartiteBufferInner {
    pub state: BufferState,
    pub head_data: Vec<u8>,
    pub head_locked: bool,
    pub audio_start: u64,
    pub audio_end: Option<u64>,
    pub tail_locked: bool,
    pub tail_data: Vec<u8>,
    pub tail_start: u64,

    pub ring_data: Vec<u8>,
    pub ring_capacity: usize,
    pub range_start: u64,
    pub range_end: u64,
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
            head_data: Vec::with_capacity(Self::DEFAULT_HEAD_CAPACITY),
            head_locked: false,
            audio_start: 0,
            audio_end: None,
            tail_locked: false,
            tail_data: Vec::new(),
            tail_start: 0,
            ring_data: vec![0u8; ring_capacity],
            ring_capacity,
            range_start: 0,
            range_end: 0,
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
        b.head_data.clear();
        b.head_data.extend_from_slice(head);
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn set_tail(&self, tail: &[u8], tail_offset: Option<u64>) {
        let mut b = self.inner.lock().unwrap();
        b.tail_data.clear();
        b.tail_data.extend_from_slice(tail);
        if let Some(offset) = tail_offset {
            b.tail_start = offset;
        } else if let Some(tot) = b.total_size {
            b.tail_start = tot.saturating_sub(tail.len() as u64);
        }
        b.tail_locked = true;
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn probe_tail(&self, tail: &[u8], tail_offset: u64) {
        self.set_tail(tail, Some(tail_offset));
    }

    pub fn set_audio_start(&self, start: u64) {
        let mut b = self.inner.lock().unwrap();
        b.audio_start = start;
        b.head_locked = true;
        if b.range_end < start {
            b.range_start = start;
            b.range_end = start;
        }
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn set_audio_end(&self, end: u64) {
        let mut b = self.inner.lock().unwrap();
        b.audio_end = Some(end);
        b.tail_locked = true;
        b.meta_version = b.meta_version.wrapping_add(1);
        self.data_ready_cond.notify_all();
    }

    pub fn set_decoding_audio(&self, decoding: bool) {
        let mut b = self.inner.lock().unwrap();
        b.is_decoding_audio = decoding;
    }

    pub fn feed_chunk(&self, chunk: &[u8]) -> Result<usize, BufferError> {
        let mut b = self.inner.lock().unwrap();

        if b.should_abort || b.state == BufferState::Aborted {
            return Err(BufferError::Aborted);
        }
        if chunk.is_empty() {
            return Ok(0);
        }

        let write_offset = b.range_end;

        // Phase 1: Si head_locked es falso, acumular cabecera
        if !b.head_locked {
            b.head_data.extend_from_slice(chunk);
            b.range_end = b.head_data.len() as u64;

            // Detección inicial rápida de cabecera ID3v2
            if b.head_data.len() >= 10 && &b.head_data[0..3] == b"ID3" {
                let size_bytes = &b.head_data[6..10];
                let tag_size = ((size_bytes[0] as usize & 0x7F) << 21)
                    | ((size_bytes[1] as usize & 0x7F) << 14)
                    | ((size_bytes[2] as usize & 0x7F) << 7)
                    | (size_bytes[3] as usize & 0x7F);
                let full_id3_size = 10 + tag_size;
                if b.head_data.len() >= full_id3_size {
                    b.audio_start = full_id3_size as u64;
                    b.head_locked = true;
                    b.range_start = b.audio_start;
                    b.range_end = b.audio_start;
                    b.state = BufferState::Ready;
                    b.meta_version = b.meta_version.wrapping_add(1);

                    // Si hay audio extra después del ID3 en el chunk, copiar al ring
                    if b.head_data.len() > full_id3_size {
                        let audio_tail = &b.head_data[full_id3_size..].to_vec();
                        b.head_data.truncate(full_id3_size);
                        drop(b);
                        return self.feed_chunk(audio_tail);
                    }
                }
            } else if b.head_data.len() >= 4 {
                // No es ID3v2; el audio comienza en 0
                b.audio_start = 0;
                b.head_locked = true;
                b.range_start = 0;
                b.range_end = 0;
                b.state = BufferState::Ready;
                b.meta_version = b.meta_version.wrapping_add(1);
                let full_data = b.head_data.clone();
                drop(b);
                return self.feed_chunk(&full_data);
            }

            self.data_ready_cond.notify_all();
            return Ok(chunk.len());
        }

        // Phase 2: Head ya está bloqueado -> escritura en el Pure Audio Ring
        let ring_read_pos = if b.read_cursor > b.audio_start {
            b.read_cursor
        } else {
            b.audio_start
        };

        let write_end = write_offset + chunk.len() as u64;
        if write_end.saturating_sub(ring_read_pos) > b.ring_capacity as u64 {
            // Contrapresión reactiva: el lector no ha avanzado lo suficiente
            return Err(BufferError::Busy);
        }

        let cap = b.ring_capacity;
        let start_pos = (write_offset.saturating_sub(b.audio_start) as usize) % cap;
        let chunk1_len = (cap - start_pos).min(chunk.len());

        b.ring_data[start_pos..start_pos + chunk1_len].copy_from_slice(&chunk[..chunk1_len]);
        if chunk.len() > chunk1_len {
            let chunk2_len = chunk.len() - chunk1_len;
            b.ring_data[..chunk2_len].copy_from_slice(&chunk[chunk1_len..]);
        }

        b.range_end = write_end;
        if b.range_end.saturating_sub(b.range_start) > cap as u64 {
            b.range_start = b.range_end - cap as u64;
        }

        if b.state == BufferState::Buffering {
            b.state = BufferState::Ready;
        }

        self.data_ready_cond.notify_all();
        Ok(chunk.len())
    }

    pub fn write_at(&self, offset: u64, data: &[u8]) -> Result<usize, BufferError> {
        let mut b = self.inner.lock().unwrap();
        if b.should_abort || b.state == BufferState::Aborted {
            return Err(BufferError::Aborted);
        }
        if data.is_empty() {
            return Ok(0);
        }

        if !b.head_locked && offset < TripartiteBuffer::DEFAULT_HEAD_CAPACITY as u64 {
            let needed = (offset as usize) + data.len();
            if needed > b.head_data.len() {
                b.head_data.resize(needed, 0);
            }
            b.head_data[offset as usize..needed].copy_from_slice(data);
            self.data_ready_cond.notify_all();
            return Ok(data.len());
        }

        drop(b);
        self.feed_chunk(data)
    }

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
                return Ok(0); // EOF
            }
        }

        // TIER 1: Pinned Head
        if offset < b.head_data.len() as u64 {
            let head_avail = b.head_data.len() - (offset as usize);
            let head_copy = out.len().min(head_avail);
            out[..head_copy].copy_from_slice(&b.head_data[offset as usize..offset as usize + head_copy]);

            let mut total_copied = head_copy;
            // Si la lectura sobrepasa Head contiguamente hacia el Ring
            if b.head_locked && out.len() > head_copy && b.range_end > b.audio_start && b.range_start <= b.audio_start {
                let needed = out.len() - head_copy;
                let ring_avail = (b.range_end - b.audio_start) as usize;
                let ring_copy = needed.min(ring_avail).min(b.ring_capacity);
                if ring_copy > 0 {
                    out[head_copy..head_copy + ring_copy].copy_from_slice(&b.ring_data[..ring_copy]);
                    total_copied += ring_copy;
                }
            }
            return Ok(total_copied);
        }

        // TIER 2: Tail Buffer / EOF Protection
        if b.tail_locked {
            if let Some(audio_end) = b.audio_end {
                if offset >= audio_end {
                    if b.is_decoding_audio {
                        return Ok(0); // EOF de audio puro
                    }
                    if !b.tail_data.is_empty() && offset >= b.tail_start {
                        let rel = (offset - b.tail_start) as usize;
                        if rel < b.tail_data.len() {
                            let avail = b.tail_data.len() - rel;
                            let to_copy = out.len().min(avail);
                            out[..to_copy].copy_from_slice(&b.tail_data[rel..rel + to_copy]);
                            return Ok(to_copy);
                        }
                    }
                    return Ok(0);
                }
            }
        }

        // TIER 3: Pure Audio Ring Buffer
        if offset >= b.range_start && offset < b.range_end {
            let mut available = (b.range_end - offset) as usize;
            if b.tail_locked {
                if let Some(end) = b.audio_end {
                    if offset + available as u64 > end {
                        available = (end.saturating_sub(offset)) as usize;
                    }
                }
            }

            let to_copy = out.len().min(available);
            if to_copy == 0 {
                if b.is_eof {
                    return Ok(0);
                }
                return Err(BufferError::WouldBlock);
            }

            let cap = b.ring_capacity;
            let rel_pos = (offset.saturating_sub(b.audio_start) as usize) % cap;
            let chunk1_len = (cap - rel_pos).min(to_copy);

            out[..chunk1_len].copy_from_slice(&b.ring_data[rel_pos..rel_pos + chunk1_len]);
            if to_copy > chunk1_len {
                let chunk2_len = to_copy - chunk1_len;
                out[chunk1_len..to_copy].copy_from_slice(&b.ring_data[..chunk2_len]);
            }

            return Ok(to_copy);
        }

        // Si se solicitó después de range_end
        if offset >= b.range_end {
            if b.is_eof {
                return Ok(0);
            }
            return Err(BufferError::WouldBlock);
        }

        // Evicción previa a range_start
        if b.is_live {
            // En streaming en vivo, avanzar cursor al inicio del rango
            return Err(BufferError::WouldBlock);
        }

        Err(BufferError::InvalidArgs)
    }

    pub fn read_blocking(&self, offset: u64, out: &mut [u8], timeout: Option<Duration>) -> Result<usize, BufferError> {
        let mut remaining_timeout = timeout.unwrap_or(Duration::from_millis(50));

        loop {
            match self.read_at(offset, out) {
                Ok(bytes) => return Ok(bytes),
                Err(BufferError::WouldBlock) => {
                    let mut b = self.inner.lock().unwrap();
                    if b.is_eof {
                        return Ok(0);
                    }
                    b.state = BufferState::Buffering;

                    let start_wait = std::time::Instant::now();
                    let (new_guard, wait_res) = self
                        .data_ready_cond
                        .wait_timeout(b, remaining_timeout)
                        .unwrap();

                    if new_guard.should_abort || new_guard.state == BufferState::Aborted {
                        return Err(BufferError::Aborted);
                    }
                    drop(new_guard);

                    let elapsed = start_wait.elapsed();
                    if wait_res.timed_out() || elapsed >= remaining_timeout {
                        return Err(BufferError::WouldBlock);
                    }
                    remaining_timeout = remaining_timeout.saturating_sub(elapsed);
                }
                Err(e) => return Err(e),
            }
        }
    }

    pub fn flush(&self, new_stream_offset: u64) {
        let mut b = self.inner.lock().unwrap();
        b.range_start = new_stream_offset;
        b.range_end = new_stream_offset;
        b.read_cursor = new_stream_offset;
        b.state = BufferState::Buffering;
        self.data_ready_cond.notify_all();
    }

    pub fn seek(&self, target_offset: u64) -> Result<(), BufferError> {
        let mut b = self.inner.lock().unwrap();
        b.read_cursor = target_offset;
        if target_offset >= b.range_start && target_offset < b.range_end {
            b.state = BufferState::Ready;
        } else if !b.is_eof {
            b.state = BufferState::Buffering;
        }
        self.data_ready_cond.notify_all();
        Ok(())
    }

    pub fn try_seek_cached(&self, target_offset: u64) -> (bool, bool) {
        let mut b = self.inner.lock().unwrap();
        let is_hit = target_offset >= b.range_start && target_offset < b.range_end;
        if is_hit {
            b.read_cursor = target_offset;
            b.state = BufferState::Ready;
            let contiguous = b.range_start <= b.audio_start;
            (true, contiguous)
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
        !b.is_eof && (b.read_cursor >= b.range_end || b.state == BufferState::Buffering)
    }

    pub fn is_eof_and_exhausted(&self) -> bool {
        let b = self.inner.lock().unwrap();
        b.is_eof && b.read_cursor >= b.range_end
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
        let buffered_bytes = b.range_end.saturating_sub(b.range_start) as f32;
        let fill_pct = (buffered_bytes / b.ring_capacity as f32).clamp(0.0, 1.0);
        let stream_pct = if total > 0 {
            (b.range_end as f32 / total as f32).clamp(0.0, 1.0)
        } else {
            fill_pct
        };

        BufferRange {
            start_byte: b.range_start as i64,
            end_byte: b.range_end as i64,
            total_bytes: total,
            read_cursor_byte: b.read_cursor as i64,
            fill_percentage: fill_pct,
            stream_percentage: stream_pct,
            is_buffering: if b.state == BufferState::Buffering { 1 } else { 0 },
            is_eof: if b.is_eof { 1 } else { 0 },
        }
    }

    pub fn meta_version(&self) -> u32 {
        self.inner.lock().unwrap().meta_version
    }

    pub fn get_meta_bytes(&self) -> Vec<u8> {
        let b = self.inner.lock().unwrap();
        let mut out = Vec::new();
        out.extend_from_slice(&b.head_data);
        if !b.tail_data.is_empty() {
            out.extend_from_slice(&b.tail_data);
        }
        if !b.icy_meta_data.is_empty() {
            out.extend_from_slice(&b.icy_meta_data);
        }
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
        self.inner.lock().unwrap().audio_start
    }

    pub fn audio_end(&self) -> Option<u64> {
        self.inner.lock().unwrap().audio_end
    }

    pub fn is_live(&self) -> bool {
        self.inner.lock().unwrap().is_live
    }

    pub fn total_size(&self) -> Option<u64> {
        self.inner.lock().unwrap().total_size
    }

    pub fn create_reader(&self) -> super::stream_reader::BufferStreamReader {
        super::stream_reader::BufferStreamReader::new(self.clone())
    }
}
