//! Rust-Native Byte Provider Subsystem & Dart Custom Source Bridge.
//!
//! Provides a unified `ByteSource` trait hierarchy across:
//! - `FileByteSource`: Buffered local filesystem access.
//! - `MemoryByteSource`: In-memory cursor access.
//! - `StreamByteSource`: Progressive HTTP streaming over `StreamSession` (`Head` + `Body`).
//! - `CustomDartByteSource`: Asynchronous Pull-with-Prefetch bridge for Dart DRM/decryption.

use std::fs::File;
use std::io::{
    BufReader, Cursor, Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom,
};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use symphonia::core::io::MediaSource;

#[cfg(not(target_arch = "wasm32"))]
use crate::sync::MonotonicInstant;

use super::demux_reader::DemuxedStreamReader;
use super::stream_buffer::StreamSession;

/// Discriminator for source kinds for telemetry, logging, and metrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    File,
    Memory,
    HttpVod,
    HttpLive,
    CustomDart,
}

/// Unified black-box abstraction for all byte streams consumed by the decoding engine.
pub trait ByteSource: Read + Seek + Send + Sync + 'static {
    /// Total stream length in bytes, or `None` for live/indeterminate streams.
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

// ----------------------------------------------------------------------------
// 1. FileByteSource
// ----------------------------------------------------------------------------

/// Buffered byte source for reading local audio files from the filesystem.
pub struct FileByteSource {
    reader: BufReader<File>,
    size: u64,
}

impl FileByteSource {
    /// Read buffer capacity in bytes (64 KB).
    pub const BUFFER_CAPACITY: usize = 64 * 1024;

    /// Wraps an open `File` handle into a `FileByteSource`.
    pub fn new(file: File) -> IoResult<Self> {
        let size = file.metadata()?.len();
        Ok(Self {
            reader: BufReader::with_capacity(Self::BUFFER_CAPACITY, file),
            size,
        })
    }

    /// Opens the file at `path` and creates a `FileByteSource`.
    pub fn open(path: &std::path::Path) -> IoResult<Self> {
        let file = File::open(path)?;
        Self::new(file)
    }

    /// Returns the total size of the file in bytes.
    #[inline]
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

// ----------------------------------------------------------------------------
// 2. MemoryByteSource
// ----------------------------------------------------------------------------

/// Byte source reading from an in-memory byte buffer via `Cursor`.
pub struct MemoryByteSource {
    cursor: Cursor<Vec<u8>>,
    size: u64,
}

impl MemoryByteSource {
    /// Creates a new `MemoryByteSource` wrapping raw byte data.
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

// ----------------------------------------------------------------------------
// 3. StreamByteSource (Progressive HTTP & Sliding Buffer)
// ----------------------------------------------------------------------------

/// Byte source reading progressively downloaded stream data from a `StreamSession`.
pub struct StreamByteSource {
    reader: DemuxedStreamReader,
}

impl StreamByteSource {
    /// Creates a new `StreamByteSource` wrapping the `StreamSession`.
    pub fn new(session: StreamSession) -> Self {
        Self {
            reader: DemuxedStreamReader::new(session),
        }
    }

    /// Returns a reference to the underlying `StreamSession`.
    #[inline]
    pub fn session(&self) -> &StreamSession {
        self.reader.session()
    }
}

impl Read for StreamByteSource {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        self.reader.read(buf)
    }
}

impl Seek for StreamByteSource {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.reader.seek(pos)
    }
}

impl ByteSource for StreamByteSource {
    fn total_bytes(&self) -> Option<u64> {
        self.reader.session().total_size()
    }

    fn is_seekable(&self) -> bool {
        !self.reader.session().is_live()
    }

    fn source_kind(&self) -> SourceKind {
        if self.reader.session().is_live() {
            SourceKind::HttpLive
        } else {
            SourceKind::HttpVod
        }
    }

    fn abort(&mut self) -> IoResult<()> {
        self.reader.session().abort();
        Ok(())
    }
}

impl MediaSource for StreamByteSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        !self.reader.session().is_live()
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        self.reader.session().total_size()
    }
}

// ----------------------------------------------------------------------------
// 4. CustomDartByteSource (Asynchronous Pull-with-Prefetch Bridge)
// ----------------------------------------------------------------------------

/// Read request dispatched from Rust to Dart over the FRB event stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DartReadRequest {
    /// Unique identifier for the custom byte stream.
    pub stream_id: u32,
    /// Monotonically increasing request identifier.
    pub request_id: u64,
    /// Absolute byte offset in the stream to read from.
    pub offset: u64,
    /// Number of bytes requested.
    pub length: u32,
}

struct CustomSharedState {
    pending_request_id: u64,
    received_data: Option<Result<Vec<u8>, String>>,
    is_eof: bool,
    aborted: bool,
}

impl CustomSharedState {
    fn drain_into(&mut self, out: &mut [u8]) -> Option<IoResult<usize>> {
        if self.aborted {
            return Some(Err(IoError::new(
                ErrorKind::Interrupted,
                "custom stream aborted",
            )));
        }
        let res = self.received_data.as_mut()?;
        match res {
            Ok(data) if !data.is_empty() => {
                let to_copy = data.len().min(out.len());
                out[..to_copy].copy_from_slice(&data[..to_copy]);
                data.drain(..to_copy);
                if data.is_empty() && !self.is_eof {
                    self.received_data = None;
                }
                Some(Ok(to_copy))
            }
            Ok(_) => {
                if self.is_eof {
                    Some(Ok(0))
                } else {
                    self.received_data = None;
                    None
                }
            }
            Err(err) => Some(Err(IoError::new(ErrorKind::Other, err.clone()))),
        }
    }
}

/// Thread-safe controller handle for supplying bytes or error notifications to a `CustomDartByteSource`.
#[derive(Clone)]
pub struct CustomByteSourceHandle {
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
}

impl CustomByteSourceHandle {
    /// Delivers requested byte data and EOF status to the awaiting reader thread.
    pub fn supply_bytes(&self, request_id: u64, data: Vec<u8>, is_eof: bool) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        if guard.pending_request_id == request_id || guard.pending_request_id == 0 {
            guard.received_data = Some(Ok(data));
            guard.is_eof = is_eof;
            cvar.notify_all();
        }
    }

    /// Notifies the awaiting reader thread that a custom stream read operation failed.
    pub fn notify_error(&self, request_id: u64, err_msg: String) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        if guard.pending_request_id == request_id || guard.pending_request_id == 0 {
            guard.received_data = Some(Err(err_msg));
            cvar.notify_all();
        }
    }

    /// Aborts any pending read operation immediately.
    pub fn abort(&self) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        guard.received_data = Some(Err("Aborted".to_string()));
        cvar.notify_all();
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
    /// Minimum prefetch chunk size in bytes (32 KB).
    pub const MIN_PREFETCH_BYTES: usize = 32 * 1024;
    /// Maximum duration to wait for a Dart read response before timing out (10s).
    pub const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);

    /// Creates a new `CustomDartByteSource` and its accompanying response controller handle.
    pub fn new(
        stream_id: u32,
        total_size: Option<u64>,
        seekable: bool,
        request_sender: Arc<dyn Fn(DartReadRequest) + Send + Sync>,
    ) -> (Self, CustomByteSourceHandle) {
        let shared = Arc::new((
            Mutex::new(CustomSharedState {
                pending_request_id: 0,
                received_data: None,
                is_eof: false,
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

    /// Obtains a new thread-safe controller handle for this source.
    pub fn handle(&self) -> CustomByteSourceHandle {
        CustomByteSourceHandle {
            shared: self.shared.clone(),
        }
    }

    fn request_and_await_chunk(&mut self, min_len: usize) -> IoResult<()> {
        self.request_counter += 1;
        let req_id = self.request_counter;
        let req_len = min_len.max(Self::MIN_PREFETCH_BYTES) as u32;

        let (lock, cvar) = &*self.shared;
        {
            let mut guard = lock.lock().unwrap();
            guard.pending_request_id = req_id;
            guard.received_data = None;
        }

        (self.request_sender)(DartReadRequest {
            stream_id: self.stream_id,
            request_id: req_id,
            offset: self.cursor,
            length: req_len,
        });

        #[allow(unused_mut)]
        let mut guard = lock.lock().unwrap();
        #[cfg(target_arch = "wasm32")]
        {
            let _ = cvar;
            if guard.received_data.is_none() && !guard.aborted {
                return Err(IoError::new(
                    ErrorKind::WouldBlock,
                    "waiting for Dart bytes",
                ));
            }
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let start = MonotonicInstant::now();
            while guard.received_data.is_none() && !guard.aborted {
                let elapsed = start.elapsed();
                if elapsed >= Self::RESPONSE_TIMEOUT {
                    return Err(IoError::new(
                        ErrorKind::TimedOut,
                        "timed out waiting for Dart bytes",
                    ));
                }
                let remaining = Self::RESPONSE_TIMEOUT - elapsed;
                let (new_guard, wait_res) = cvar.wait_timeout(guard, remaining).unwrap();
                guard = new_guard;
                if wait_res.timed_out() && guard.received_data.is_none() {
                    return Err(IoError::new(
                        ErrorKind::TimedOut,
                        "timed out waiting for Dart bytes",
                    ));
                }
            }
        }

        if guard.aborted {
            return Err(IoError::new(
                ErrorKind::Interrupted,
                "custom stream aborted",
            ));
        }
        Ok(())
    }

    fn resolve_seek_target(&self, pos: SeekFrom) -> IoResult<u64> {
        match pos {
            SeekFrom::Start(off) => Ok(off),
            SeekFrom::Current(off) => {
                let target = (self.cursor as i64) + off;
                if target < 0 {
                    return Err(IoError::new(
                        ErrorKind::InvalidInput,
                        "negative seek cursor",
                    ));
                }
                Ok(target as u64)
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
                    return Err(IoError::new(
                        ErrorKind::InvalidInput,
                        "negative seek cursor",
                    ));
                }
                Ok(target as u64)
            }
        }
    }
}

impl Read for CustomDartByteSource {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        {
            let (lock, _) = &*self.shared;
            let mut guard = lock.lock().unwrap();
            if let Some(result) = guard.drain_into(buf) {
                let bytes = result?;
                self.cursor += bytes as u64;
                return Ok(bytes);
            }
        }

        self.request_and_await_chunk(buf.len())?;

        let (lock, _) = &*self.shared;
        let mut guard = lock.lock().unwrap();
        match guard.drain_into(buf) {
            Some(Ok(bytes)) => {
                self.cursor += bytes as u64;
                Ok(bytes)
            }
            Some(Err(e)) => Err(e),
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

        let new_cursor = self.resolve_seek_target(pos)?;
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
