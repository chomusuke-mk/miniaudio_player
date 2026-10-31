//! Rust-Native Byte Provider Subsystem & Dart Custom Source Bridge.
//!
//! Provides a unified `ByteSource` trait hierarchy across:
//! - `FileByteSource`: Zero-overhead buffered local filesystem access.
//! - `MemoryByteSource`: In-memory cursor access.
//! - `TripartiteByteSource`: Advanced progressive HTTP streaming with sliding cache.
//! - `CustomDartByteSource`: Asynchronous Pull-with-Prefetch bridge for Dart DRM/decryption.

use std::fs::File;
use std::io::{
    BufReader, Cursor, Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom,
};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use symphonia::core::io::MediaSource;

use super::stream_reader::BufferStreamReader;
use super::tripartite::TripartiteBuffer;

/// Discriminator for source kinds for telemetry, logging, and metrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    File,
    Memory,
    HttpVod,
    HttpLive,
    CustomDart,
}

/// Unified abstraction for all byte streams consumed by the Symphonia decoding engine.
pub trait ByteSource: Read + Seek + Send + Sync + 'static {
    /// Total stream length in bytes, or None for live/indeterminate streams.
    fn total_bytes(&self) -> Option<u64>;

    /// Whether random-access seeking is supported.
    fn is_seekable(&self) -> bool;

    /// Source kind for diagnostics and telemetry.
    fn source_kind(&self) -> SourceKind;

    /// Non-destructive probe of trailing bytes (ID3v1, MP4 moov atoms).
    fn probe_tail(&mut self, tail_offset: u64, len: usize) -> IoResult<Vec<u8>> {
        let saved_pos = self.stream_position()?;
        self.seek(SeekFrom::Start(tail_offset))?;
        let mut buf = vec![0u8; len];
        let bytes_read = self.read(&mut buf)?;
        buf.truncate(bytes_read);
        self.seek(SeekFrom::Start(saved_pos))?;
        Ok(buf)
    }

    /// Abort active downloads or connections.
    fn abort(&mut self) -> IoResult<()> {
        Ok(())
    }
}

/// Adapts any `ByteSource` into a Symphonia `MediaSource`.
pub struct ByteSourceStream<S: ByteSource>(pub S);

impl<S: ByteSource> Read for ByteSourceStream<S> {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        self.0.read(buf)
    }
}

impl<S: ByteSource> Seek for ByteSourceStream<S> {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.0.seek(pos)
    }
}

impl<S: ByteSource> MediaSource for ByteSourceStream<S> {
    #[inline]
    fn is_seekable(&self) -> bool {
        self.0.is_seekable()
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        self.0.total_bytes()
    }
}

impl MediaSource for FileByteSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        true
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        Some(self.size)
    }
}

impl MediaSource for MemoryByteSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        true
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        Some(self.size)
    }
}

impl MediaSource for TripartiteByteSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        !self.reader.buffer().is_live()
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        self.reader.buffer().total_size()
    }
}

impl MediaSource for CustomDartByteSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        self.seekable
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        self.total_size
    }
}

// ----------------------------------------------------------------------------
// 1. FileByteSource
// ----------------------------------------------------------------------------

pub struct FileByteSource {
    reader: BufReader<File>,
    size: u64,
}

impl FileByteSource {
    pub fn new(file: File) -> IoResult<Self> {
        let size = file.metadata()?.len();
        Ok(Self {
            reader: BufReader::with_capacity(64 * 1024, file),
            size,
        })
    }

    pub fn open(path: &std::path::Path) -> IoResult<Self> {
        let file = File::open(path)?;
        Self::new(file)
    }

    pub fn size(&self) -> u64 {
        self.size
    }
}

impl Read for FileByteSource {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        self.reader.read(buf)
    }
}

impl Seek for FileByteSource {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.reader.seek(pos)
    }
}

impl ByteSource for FileByteSource {
    fn total_bytes(&self) -> Option<u64> {
        Some(self.size)
    }

    fn is_seekable(&self) -> bool {
        true
    }

    fn source_kind(&self) -> SourceKind {
        SourceKind::File
    }
}

// ----------------------------------------------------------------------------
// 2. MemoryByteSource
// ----------------------------------------------------------------------------

pub struct MemoryByteSource {
    cursor: Cursor<Vec<u8>>,
    size: u64,
}

impl MemoryByteSource {
    pub fn new(data: Vec<u8>) -> Self {
        let size = data.len() as u64;
        Self {
            cursor: Cursor::new(data),
            size,
        }
    }
}

impl Read for MemoryByteSource {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        self.cursor.read(buf)
    }
}

impl Seek for MemoryByteSource {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.cursor.seek(pos)
    }
}

impl ByteSource for MemoryByteSource {
    fn total_bytes(&self) -> Option<u64> {
        Some(self.size)
    }

    fn is_seekable(&self) -> bool {
        true
    }

    fn source_kind(&self) -> SourceKind {
        SourceKind::Memory
    }
}

// ----------------------------------------------------------------------------
// 3. TripartiteByteSource (Progressive HTTP & Sliding Buffer)
// ----------------------------------------------------------------------------

pub struct TripartiteByteSource {
    reader: BufferStreamReader,
}

impl TripartiteByteSource {
    pub fn new(buffer: TripartiteBuffer) -> Self {
        Self {
            reader: BufferStreamReader::new(buffer),
        }
    }

    pub fn buffer(&self) -> &TripartiteBuffer {
        self.reader.buffer()
    }
}

impl Read for TripartiteByteSource {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        self.reader.read(buf)
    }
}

impl Seek for TripartiteByteSource {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.reader.seek(pos)
    }
}

impl ByteSource for TripartiteByteSource {
    fn total_bytes(&self) -> Option<u64> {
        self.reader.buffer().total_size()
    }

    fn is_seekable(&self) -> bool {
        !self.reader.buffer().is_live()
    }

    fn source_kind(&self) -> SourceKind {
        if self.reader.buffer().is_live() {
            SourceKind::HttpLive
        } else {
            SourceKind::HttpVod
        }
    }

    fn abort(&mut self) -> IoResult<()> {
        self.reader.buffer().abort();
        Ok(())
    }
}

// ----------------------------------------------------------------------------
// 4. CustomDartByteSource (Asynchronous Pull-with-Prefetch Bridge)
// ----------------------------------------------------------------------------

/// Read request dispatched from Rust to Dart over FRB event stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DartReadRequest {
    pub stream_id: u32,
    pub request_id: u64,
    pub offset: u64,
    pub length: u32,
}

struct CustomSharedState {
    pending_request_id: u64,
    received_data: Option<Result<Vec<u8>, String>>,
    is_eof: bool,
    aborted: bool,
}

/// Thread-safe controller handle for supplying bytes or error notifications to a `CustomDartByteSource`.
#[derive(Clone)]
pub struct CustomByteSourceHandle {
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
}

impl CustomByteSourceHandle {
    pub fn supply_bytes(&self, request_id: u64, data: Vec<u8>, is_eof: bool) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        if guard.pending_request_id == request_id || guard.pending_request_id == 0 {
            guard.received_data = Some(Ok(data));
            guard.is_eof = is_eof;
            cvar.notify_all();
        }
    }

    pub fn notify_error(&self, request_id: u64, err_msg: String) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        if guard.pending_request_id == request_id || guard.pending_request_id == 0 {
            guard.received_data = Some(Err(err_msg));
            cvar.notify_all();
        }
    }
}

/// Asynchronous Pull-with-Prefetch byte source interfacing with Dart DRM or custom decoders.
pub struct CustomDartByteSource {
    stream_id: u32,
    total_size: Option<u64>,
    seekable: bool,
    cursor: u64,
    request_counter: u64,
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
    request_sender: Arc<dyn Fn(DartReadRequest) + Send + Sync>,
}

impl CustomDartByteSource {
    pub fn new(
        stream_id: u32,
        total_size: Option<u64>,
        seekable: bool,
        initial_data: Vec<u8>,
        request_sender: Arc<dyn Fn(DartReadRequest) + Send + Sync>,
    ) -> (Self, CustomByteSourceHandle) {
        let initial_len = initial_data.len();
        let initial_eof = if let Some(tot) = total_size {
            initial_len as u64 >= tot
        } else {
            false
        };

        let shared = Arc::new((
            Mutex::new(CustomSharedState {
                pending_request_id: 0,
                received_data: if !initial_data.is_empty() {
                    Some(Ok(initial_data))
                } else {
                    None
                },
                is_eof: initial_eof,
                aborted: false,
            }),
            Condvar::new(),
        ));

        let handle = CustomByteSourceHandle {
            shared: shared.clone(),
        };

        let source = Self {
            stream_id,
            total_size,
            seekable,
            cursor: 0,
            request_counter: 0,
            shared,
            request_sender,
        };

        (source, handle)
    }

    pub fn handle(&self) -> CustomByteSourceHandle {
        CustomByteSourceHandle {
            shared: self.shared.clone(),
        }
    }
}

impl Read for CustomDartByteSource {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let (lock, cvar) = &*self.shared;

        // Check if there is already data buffered in received_data
        {
            let mut guard = lock.lock().unwrap();
            if guard.aborted {
                return Err(IoError::new(ErrorKind::Interrupted, "custom stream aborted"));
            }

            if let Some(ref mut res) = guard.received_data {
                match res {
                    Ok(data) if !data.is_empty() => {
                        let to_copy = data.len().min(buf.len());
                        buf[..to_copy].copy_from_slice(&data[..to_copy]);
                        data.drain(..to_copy);
                        self.cursor += to_copy as u64;
                        let is_now_empty = data.is_empty();
                        if is_now_empty && !guard.is_eof {
                            guard.received_data = None;
                        }
                        return Ok(to_copy);
                    }
                    Ok(_) => {
                        if guard.is_eof {
                            return Ok(0);
                        }
                        guard.received_data = None;
                    }
                    Err(err) => {
                        let msg = err.clone();
                        return Err(IoError::new(ErrorKind::Other, msg));
                    }
                }
            }
        }

        // Need to request bytes from Dart
        self.request_counter += 1;
        let req_id = self.request_counter;
        let req_len = buf.len().max(32 * 1024) as u32;

        {
            let mut guard = lock.lock().unwrap();
            guard.pending_request_id = req_id;
            guard.received_data = None;
        }

        // Dispatch request to Dart
        (self.request_sender)(DartReadRequest {
            stream_id: self.stream_id,
            request_id: req_id,
            offset: self.cursor,
            length: req_len,
        });

        // Wait for Dart response with timeout
        let mut guard = lock.lock().unwrap();
        let timeout = Duration::from_secs(10);
        let start = std::time::Instant::now();

        while guard.received_data.is_none() && !guard.aborted {
            let elapsed = start.elapsed();
            if elapsed >= timeout {
                return Err(IoError::new(ErrorKind::TimedOut, "timed out waiting for Dart bytes"));
            }
            let remaining = timeout - elapsed;
            let (new_guard, wait_res) = cvar.wait_timeout(guard, remaining).unwrap();
            guard = new_guard;
            if wait_res.timed_out() && guard.received_data.is_none() {
                return Err(IoError::new(ErrorKind::TimedOut, "timed out waiting for Dart bytes"));
            }
        }

        if guard.aborted {
            return Err(IoError::new(ErrorKind::Interrupted, "custom stream aborted"));
        }

        match guard.received_data.take() {
            Some(Ok(mut data)) => {
                if data.is_empty() {
                    return Ok(0);
                }
                let to_copy = data.len().min(buf.len());
                buf[..to_copy].copy_from_slice(&data[..to_copy]);
                data.drain(..to_copy);
                self.cursor += to_copy as u64;
                if !data.is_empty() {
                    guard.received_data = Some(Ok(data));
                }
                Ok(to_copy)
            }
            Some(Err(err)) => Err(IoError::new(ErrorKind::Other, err)),
            None => Ok(0),
        }
    }
}

impl Seek for CustomDartByteSource {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        if !self.seekable {
            return Err(IoError::new(
                ErrorKind::Unsupported,
                "custom stream does not support seeking",
            ));
        }

        let new_cursor = match pos {
            SeekFrom::Start(off) => off,
            SeekFrom::Current(off) => {
                let target = (self.cursor as i64) + off;
                if target < 0 {
                    return Err(IoError::new(ErrorKind::InvalidInput, "negative seek cursor"));
                }
                target as u64
            }
            SeekFrom::End(off) => {
                let Some(tot) = self.total_size else {
                    return Err(IoError::new(
                        ErrorKind::Unsupported,
                        "cannot seek from end without total size",
                    ));
                };
                let target = (tot as i64) + off;
                if target < 0 {
                    return Err(IoError::new(ErrorKind::InvalidInput, "negative seek cursor"));
                }
                target as u64
            }
        };

        // If seek target changed position, clear any pre-buffered chunks
        if new_cursor != self.cursor {
            let (lock, _) = &*self.shared;
            let mut guard = lock.lock().unwrap();
            guard.received_data = None;
            self.cursor = new_cursor;
        }

        Ok(self.cursor)
    }
}

impl ByteSource for CustomDartByteSource {
    fn total_bytes(&self) -> Option<u64> {
        self.total_size
    }

    fn is_seekable(&self) -> bool {
        self.seekable
    }

    fn source_kind(&self) -> SourceKind {
        SourceKind::CustomDart
    }

    fn abort(&mut self) -> IoResult<()> {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        guard.aborted = true;
        cvar.notify_all();
        Ok(())
    }
}
