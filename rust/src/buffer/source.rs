//! Rust-Native Byte Provider Subsystem & Dart Custom Source Bridge.
//!
//! Provides `MediaSource` implementations across:
//! - `FileByteSource`: Buffered local filesystem access.
//! - `CustomDartByteSource`: Asynchronous Pull-with-Prefetch bridge for Dart DRM/decryption.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;
use symphonia::core::io::MediaSource;

use crate::sync::MonotonicInstant;

// ----------------------------------------------------------------------------
// 1. FileByteSource
// ----------------------------------------------------------------------------

/// Buffered byte source for reading local audio files or detached FD slices.
pub struct FileByteSource {
    reader: BufReader<File>,
    base_offset: u64,
    size: u64,
    rel_pos: u64,
}

impl FileByteSource {
    /// Read buffer capacity in bytes (64 KB).
    pub const BUFFER_CAPACITY: usize = 64 * 1024;

    /// Wraps an open `File` handle into a `FileByteSource`.
    pub fn new(file: File) -> IoResult<Self> {
        let size = file.metadata()?.len();
        Self::from_file_slice_with_len(file, 0, size)
    }

    /// Wraps a seekable `File` starting at `base_offset` with a strict logical
    /// length `size` (used for APK `android.resource://` and `content://` FDs).
    pub fn from_file_slice_with_len(
        mut file: File,
        base_offset: u64,
        size: u64,
    ) -> IoResult<Self> {
        file.seek(SeekFrom::Start(base_offset))?;
        Ok(Self {
            reader: BufReader::with_capacity(Self::BUFFER_CAPACITY, file),
            base_offset,
            size,
            rel_pos: 0,
        })
    }

    /// Opens the file at `path` and creates a `FileByteSource`.
    pub fn open(path: &std::path::Path) -> IoResult<Self> {
        let file = File::open(path)?;
        Self::new(file)
    }
}

impl Read for FileByteSource {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        let remaining = self.size.saturating_sub(self.rel_pos);
        if remaining == 0 {
            return Ok(0);
        }
        let max_read = buf.len().min(remaining as usize);
        let n = self.reader.read(&mut buf[..max_read])?;
        self.rel_pos += n as u64;
        Ok(n)
    }
}

impl Seek for FileByteSource {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let target_rel: i128 = match pos {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(delta) => (self.size as i128).saturating_add(delta as i128),
            SeekFrom::Current(delta) => (self.rel_pos as i128).saturating_add(delta as i128),
        };
        if target_rel < 0 {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "Invalid seek before start of bounded file slice",
            ));
        }
        let target_u64 = target_rel as u64;
        let abs_target = self.base_offset.saturating_add(target_u64);
        self.reader.seek(SeekFrom::Start(abs_target))?;
        self.rel_pos = target_u64;
        Ok(target_u64)
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
// 2. CustomDartByteSource (Asynchronous Pull-with-Prefetch Bridge)
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
    received_data: Option<Vec<u8>>,
    is_eof: bool,
    aborted: bool,
}

#[inline]
fn custom_aborted_error() -> IoError {
    IoError::new(ErrorKind::ConnectionAborted, "custom stream aborted")
}

impl CustomSharedState {
    fn drain_into(&mut self, out: &mut [u8]) -> Option<IoResult<usize>> {
        if self.aborted {
            return Some(Err(custom_aborted_error()));
        }
        let data = self.received_data.as_mut()?;
        if !data.is_empty() {
            let to_copy = data.len().min(out.len());
            out[..to_copy].copy_from_slice(&data[..to_copy]);
            data.drain(..to_copy);
            if data.is_empty() && !self.is_eof {
                self.received_data = None;
            }
            Some(Ok(to_copy))
        } else if self.is_eof {
            Some(Ok(0))
        } else {
            self.received_data = None;
            None
        }
    }
}

/// Global monotonic counter ensuring `DartReadRequest.request_id` never collides across
/// concurrent custom streams (active deck, standby pre-warm, or acoustic analysis).
static NEXT_CUSTOM_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

/// Lock-poisoning safe mutex acquisition helper.
#[inline]
fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

/// Decoupled registry routing asynchronous Dart byte responses directly to the originating
/// `CustomByteSourceHandle` by `request_id`, eliminating global single-handle races and locks.
#[derive(Clone, Default)]
pub struct CustomSourceRegistry {
    inner: Arc<Mutex<CustomRegistryState>>,
}

#[derive(Default)]
struct CustomRegistryState {
    by_request: HashMap<u64, CustomByteSourceHandle>,
    active_handles: Vec<Weak<(Mutex<CustomSharedState>, Condvar)>>,
}

impl CustomSourceRegistry {
    /// Creates an empty `CustomSourceRegistry`.
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers an active `CustomByteSourceHandle` for bulk abort on shutdown.
    pub fn register_handle(&self, handle: &CustomByteSourceHandle) {
        let mut guard = lock_unpoisoned(&self.inner);
        guard.active_handles.retain(|w| w.strong_count() > 0);
        guard.active_handles.push(Arc::downgrade(&handle.shared));
    }

    /// Associates a pending `request_id` with its owning `CustomByteSourceHandle` prior to dispatch.
    pub fn register_request(&self, request_id: u64, handle: &CustomByteSourceHandle) {
        let mut guard = lock_unpoisoned(&self.inner);
        guard.by_request.insert(request_id, handle.clone());
    }

    /// Delivers bytes and EOF status to the handle awaiting `request_id`, removing the entry.
    pub fn resolve_request(&self, request_id: u64, data: Vec<u8>, is_eof: bool) -> bool {
        let handle = {
            let mut guard = lock_unpoisoned(&self.inner);
            guard.by_request.remove(&request_id)
        };
        if let Some(h) = handle {
            h.supply_bytes(request_id, data, is_eof);
            true
        } else {
            false
        }
    }

    /// Removes an expired, timed-out, or aborted `request_id` mapping.
    pub fn unregister_request(&self, request_id: u64) {
        let mut guard = lock_unpoisoned(&self.inner);
        guard.by_request.remove(&request_id);
    }

    /// Immediately aborts all live custom streams registered with this registry.
    pub fn abort_all(&self) {
        let (requests, handles) = {
            let mut guard = lock_unpoisoned(&self.inner);
            let reqs: Vec<CustomByteSourceHandle> = guard.by_request.drain().map(|(_, v)| v).collect();
            let weak_handles: Vec<Arc<(Mutex<CustomSharedState>, Condvar)>> = guard
                .active_handles
                .drain(..)
                .filter_map(|w| w.upgrade())
                .collect();
            (reqs, weak_handles)
        };
        for h in requests {
            h.abort();
        }
        for shared in handles {
            CustomByteSourceHandle { shared }.abort();
        }
    }
}

/// Thread-safe controller handle for supplying bytes or abort notifications to a `CustomDartByteSource`.
#[derive(Clone)]
pub struct CustomByteSourceHandle {
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
}

impl CustomByteSourceHandle {
    /// Delivers requested byte data and EOF status to the awaiting reader thread.
    pub fn supply_bytes(&self, request_id: u64, data: Vec<u8>, is_eof: bool) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock_unpoisoned(lock);
        if guard.pending_request_id == request_id || guard.pending_request_id == 0 {
            guard.received_data = Some(data);
            guard.is_eof = is_eof;
            cvar.notify_all();
        }
    }

    /// Aborts any pending or subsequent read operation immediately.
    pub fn abort(&self) {
        let (lock, cvar) = &*self.shared;
        let mut guard = lock_unpoisoned(lock);
        guard.aborted = true;
        cvar.notify_all();
    }
}

/// Asynchronous Pull-with-Prefetch byte source interfacing with Dart DRM or custom decoders.
pub struct CustomDartByteSource {
    stream_id: u32,
    total_size: Option<u64>,
    seekable: bool,
    cursor: u64,
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
    request_sender: Arc<dyn Fn(DartReadRequest) + Send + Sync>,
    registry: Option<CustomSourceRegistry>,
    last_request_id: u64,
}

impl CustomDartByteSource {
    /// Minimum prefetch chunk size in bytes (32 KB).
    pub const MIN_PREFETCH_BYTES: usize = 32 * 1024;
    /// Maximum duration to wait for a Dart read response before timing out (10s).
    pub const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);

    /// Creates a new `CustomDartByteSource` registered against an optional [`CustomSourceRegistry`].
    pub fn with_registry(
        stream_id: u32,
        total_size: Option<u64>,
        seekable: bool,
        request_sender: Arc<dyn Fn(DartReadRequest) + Send + Sync>,
        registry: Option<CustomSourceRegistry>,
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
        if let Some(ref reg) = registry {
            reg.register_handle(&handle);
        }

        let source = Self {
            stream_id,
            total_size,
            seekable,
            cursor: 0,
            shared,
            request_sender,
            registry,
            last_request_id: 0,
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
        let req_id = NEXT_CUSTOM_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        self.last_request_id = req_id;
        let req_len = min_len.max(Self::MIN_PREFETCH_BYTES) as u32;

        let (lock, cvar) = &*self.shared;
        {
            let mut guard = lock_unpoisoned(lock);
            if guard.aborted {
                return Err(custom_aborted_error());
            }
            guard.pending_request_id = req_id;
            guard.received_data = None;
        }

        if let Some(ref reg) = self.registry {
            reg.register_request(req_id, &self.handle());
        }

        (self.request_sender)(DartReadRequest {
            stream_id: self.stream_id,
            request_id: req_id,
            offset: self.cursor,
            length: req_len,
        });

        let mut guard = lock_unpoisoned(lock);
        let start = MonotonicInstant::now();
        while guard.received_data.is_none() && !guard.aborted {
            let elapsed = start.elapsed();
            if elapsed >= Self::RESPONSE_TIMEOUT {
                if let Some(ref reg) = self.registry {
                    reg.unregister_request(req_id);
                }
                return Err(IoError::new(
                    ErrorKind::TimedOut,
                    "timed out waiting for Dart bytes",
                ));
            }
            let remaining = Self::RESPONSE_TIMEOUT - elapsed;
            let (new_guard, wait_res) = cvar
                .wait_timeout(guard, remaining)
                .unwrap_or_else(|e| e.into_inner());
            guard = new_guard;
            if wait_res.timed_out() && guard.received_data.is_none() {
                if let Some(ref reg) = self.registry {
                    reg.unregister_request(req_id);
                }
                return Err(IoError::new(
                    ErrorKind::TimedOut,
                    "timed out waiting for Dart bytes",
                ));
            }
        }

        if guard.aborted {
            if let Some(ref reg) = self.registry {
                reg.unregister_request(req_id);
            }
            return Err(custom_aborted_error());
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
            let mut guard = lock_unpoisoned(lock);
            if let Some(result) = guard.drain_into(buf) {
                let bytes = result?;
                self.cursor += bytes as u64;
                return Ok(bytes);
            }
        }

        self.request_and_await_chunk(buf.len())?;

        let (lock, _) = &*self.shared;
        let mut guard = lock_unpoisoned(lock);
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
        let (lock, _) = &*self.shared;
        let mut guard = lock_unpoisoned(lock);
        if guard.aborted {
            return Err(custom_aborted_error());
        }
        if new_cursor != self.cursor {
            guard.received_data = None;
            self.cursor = new_cursor;
        }
        Ok(self.cursor)
    }
}

impl Drop for CustomDartByteSource {
    fn drop(&mut self) {
        if let Some(ref reg) = self.registry {
            if self.last_request_id != 0 {
                reg.unregister_request(self.last_request_id);
            }
        }
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

impl CustomDartByteSource {
    /// Overrides seekability (e.g. live unseekable WebSocket streams).
    #[inline]
    pub fn set_seekable(&mut self, seekable: bool) {
        self.seekable = seekable;
    }
}
