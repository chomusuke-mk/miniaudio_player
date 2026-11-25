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

use crate::sync::{lock_unpoisoned, MonotonicInstant};

// ----------------------------------------------------------------------------
// 1. FileByteSource
// ----------------------------------------------------------------------------

/// Buffered byte source for reading local audio files or detached FD slices.
pub struct FileByteSource {
    /// Buffered reader over the underlying OS file handle.
    reader: BufReader<File>,
    /// Starting physical byte offset of this logical slice within the file.
    base_offset: u64,
    /// Logical byte length exposed by this source.
    size: u64,
    /// Current logical read position relative to `base_offset`.
    rel_pos: u64,
}

impl FileByteSource {
    /// Read buffer capacity in bytes (128 KB).
    pub const BUFFER_CAPACITY: usize = 128 * 1024;

    /// Wraps an open `file` handle into a [`FileByteSource`] covering its full metadata length.
    ///
    /// # Errors
    /// Returns an `std::io::Error` if querying `file` metadata or seeking to byte `0` fails.
    pub fn new(file: File) -> IoResult<Self> {
        let size = file.metadata()?.len();
        Self::from_file_slice_with_len(file, 0, size)
    }

    /// Wraps a seekable `file` starting at `base_offset` with a strict logical
    /// length `size` (used for APK `android.resource://` and `content://` FDs).
    ///
    /// # Errors
    /// Returns an `std::io::Error` if seeking `file` to `base_offset` fails.
    pub fn from_file_slice_with_len(
        mut file: File,
        base_offset: u64,
        size: u64,
    ) -> IoResult<Self> {
        if let Err(err) = file.seek(SeekFrom::Start(base_offset)) {
            crate::map_log!(
                1,
                "[SOURCE] FileByteSource::from_file_slice_with_len seek to base_offset={} failed: {}",
                base_offset,
                err
            );
            return Err(err);
        }
        Ok(Self {
            reader: BufReader::with_capacity(Self::BUFFER_CAPACITY, file),
            base_offset,
            size,
            rel_pos: 0,
        })
    }

    /// Opens the file at `path` and creates a [`FileByteSource`].
    ///
    /// # Errors
    /// Returns an `std::io::Error` if opening `path` or reading its metadata fails.
    pub fn open(path: &std::path::Path) -> IoResult<Self> {
        let file = match File::open(path) {
            Ok(f) => f,
            Err(err) => {
                crate::map_log!(
                    1,
                    "[SOURCE] FileByteSource::open failed for '{}': {}",
                    path.display(),
                    err
                );
                return Err(err);
            }
        };
        let src = Self::new(file)?;
        crate::map_log!(
            4,
            "[SOURCE] FileByteSource::open succeeded for '{}' (size={})",
            path.display(),
            src.size
        );
        Ok(src)
    }

    /// Creates an offset-isolated `pread`-backed reopener sharing the same underlying OS FD.
    #[cfg(unix)]
    pub fn try_make_pread_reopener(
        &self,
    ) -> Option<Arc<dyn Fn() -> Option<Box<dyn MediaSource>> + Send + Sync>> {
        let cloned = match self.reader.get_ref().try_clone() {
            Ok(f) => f,
            Err(err) => {
                crate::map_log!(
                    2,
                    "[SOURCE] FileByteSource::try_make_pread_reopener try_clone failed: {}",
                    err
                );
                return None;
            }
        };
        let shared = Arc::new(cloned);
        let base_offset = self.base_offset;
        let size = self.size;
        Some(Arc::new(move || {
            Some(Box::new(PreadFileByteSource::new(
                Arc::clone(&shared),
                base_offset,
                size,
            )) as Box<dyn MediaSource>)
        }))
    }
}

impl Read for FileByteSource {
    /// Reads available bytes into `buf`, clamped to the bounded file slice length.
    ///
    /// # Errors
    /// Propagates any underlying file read error.
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
    /// Seeks to `pos` within the bounded slice relative to `base_offset`.
    ///
    /// # Errors
    /// Returns [`ErrorKind::InvalidInput`] if `pos` resolves before byte `0`, or propagates underlying seek errors.
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
        if target_u64 == self.rel_pos {
            return Ok(target_u64);
        }
        let delta = target_rel - (self.rel_pos as i128);
        if let Ok(rel_i64) = i64::try_from(delta) {
            self.reader.seek_relative(rel_i64)?;
        } else {
            let abs_target = self.base_offset.saturating_add(target_u64);
            self.reader.seek(SeekFrom::Start(abs_target))?;
        }
        self.rel_pos = target_u64;
        Ok(target_u64)
    }
}

impl MediaSource for FileByteSource {
    /// Returns `true` since local files and sliced descriptors support random seeking.
    #[inline]
    fn is_seekable(&self) -> bool {
        true
    }

    /// Returns the logical byte length of this file or slice.
    #[inline]
    fn byte_len(&self) -> Option<u64> {
        Some(self.size)
    }
}

/// Stateless positional `pread` reader sharing an OS [`File`] without mutating the shared kernel file offset.
#[cfg(unix)]
struct PreadFileReader {
    /// Shared underlying POSIX file handle.
    file: Arc<File>,
    /// Starting physical byte offset of this logical slice within `file`.
    base_offset: u64,
    /// Logical byte length exposed by this reader.
    size: u64,
    /// Current logical read cursor relative to `base_offset`.
    rel_pos: u64,
}

#[cfg(unix)]
impl Read for PreadFileReader {
    /// Reads available bytes into `buf` via `FileExt::read_at` without touching the shared file offset.
    ///
    /// # Errors
    /// Propagates any underlying `pread` I/O error.
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        use std::os::unix::fs::FileExt;
        let remaining = self.size.saturating_sub(self.rel_pos);
        if remaining == 0 || buf.is_empty() {
            return Ok(0);
        }
        let max_read = buf.len().min(remaining as usize);
        let abs_off = self.base_offset.saturating_add(self.rel_pos);
        let n = self.file.read_at(&mut buf[..max_read], abs_off)?;
        self.rel_pos += n as u64;
        Ok(n)
    }
}

#[cfg(unix)]
impl Seek for PreadFileReader {
    /// Updates the in-memory relative cursor to `pos` without issuing a syscall.
    ///
    /// # Errors
    /// Returns [`ErrorKind::InvalidInput`] if `pos` resolves before byte `0`.
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
                "Invalid seek before start of bounded pread file slice",
            ));
        }
        self.rel_pos = target_rel as u64;
        Ok(self.rel_pos)
    }
}

/// Buffered `MediaSource` wrapping [`PreadFileReader`] for independent concurrent re-opening of a shared FD.
#[cfg(unix)]
struct PreadFileByteSource {
    /// Buffered positional reader over the shared file slice.
    reader: BufReader<PreadFileReader>,
    /// Logical byte length exposed by this source.
    size: u64,
}

#[cfg(unix)]
impl PreadFileByteSource {
    /// Creates a buffered positional reader over `file` starting at `base_offset` with length `size`.
    fn new(file: Arc<File>, base_offset: u64, size: u64) -> Self {
        Self {
            reader: BufReader::with_capacity(
                FileByteSource::BUFFER_CAPACITY,
                PreadFileReader {
                    file,
                    base_offset,
                    size,
                    rel_pos: 0,
                },
            ),
            size,
        }
    }
}

#[cfg(unix)]
impl Read for PreadFileByteSource {
    /// Reads buffered bytes into `buf` from the underlying positional reader.
    ///
    /// # Errors
    /// Propagates any underlying `pread` read error.
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        self.reader.read(buf)
    }
}

#[cfg(unix)]
impl Seek for PreadFileByteSource {
    /// Seeks within the buffered positional reader to `pos`.
    ///
    /// # Errors
    /// Returns an `std::io::Error` if `pos` resolves before byte `0`.
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.reader.seek(pos)
    }
}

#[cfg(unix)]
impl MediaSource for PreadFileByteSource {
    /// Returns `true` since positional `pread` sources always support random seeking.
    #[inline]
    fn is_seekable(&self) -> bool {
        true
    }

    /// Returns the logical byte length of this file slice.
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

/// Shared synchronization state between [`CustomDartByteSource`] and [`CustomByteSourceHandle`].
struct CustomSharedState {
    /// Identifier of the currently awaited request, or `0` if none is active.
    pending_request_id: u64,
    /// Most recently delivered chunk buffer awaiting consumption by `Read::read`.
    received_data: Option<Vec<u8>>,
    /// Whether Dart reported EOF alongside `received_data`.
    is_eof: bool,
    /// Whether this custom stream has been aborted.
    aborted: bool,
}

/// Constructs the standard `ConnectionAborted` error returned when a custom stream is aborted.
#[inline]
fn custom_aborted_error() -> IoError {
    IoError::new(ErrorKind::ConnectionAborted, "custom stream aborted")
}

impl CustomSharedState {
    /// Drains buffered bytes from `received_data` into `out`, returning `None` when a fresh fetch is needed.
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

/// Decoupled registry routing asynchronous Dart byte responses directly to the originating
/// `CustomByteSourceHandle` by `request_id`, eliminating global single-handle races and locks.
#[derive(Clone, Default)]
pub struct CustomSourceRegistry {
    /// Mutex-guarded map of pending requests and weak references to active stream handles.
    inner: Arc<Mutex<CustomRegistryState>>,
}

/// Internal state stored inside [`CustomSourceRegistry`].
#[derive(Default)]
struct CustomRegistryState {
    /// Pending read handles indexed by [`DartReadRequest::request_id`].
    by_request: HashMap<u64, CustomByteSourceHandle>,
    /// Weak references to all registered custom source handles for bulk abort on shutdown.
    active_handles: Vec<Weak<(Mutex<CustomSharedState>, Condvar)>>,
}

impl CustomSourceRegistry {
    /// Creates an empty [`CustomSourceRegistry`].
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers an active `handle` for bulk abort on shutdown.
    pub fn register_handle(&self, handle: &CustomByteSourceHandle) {
        let mut guard = lock_unpoisoned(&self.inner);
        guard.active_handles.retain(|w| w.strong_count() > 0);
        guard.active_handles.push(Arc::downgrade(&handle.shared));
    }

    /// Associates a pending `request_id` with its owning `handle` prior to dispatch.
    pub fn register_request(&self, request_id: u64, handle: &CustomByteSourceHandle) {
        let mut guard = lock_unpoisoned(&self.inner);
        guard.by_request.insert(request_id, handle.clone());
    }

    /// Delivers `data` and `is_eof` status to the handle awaiting `request_id`, removing the entry.
    pub fn resolve_request(&self, request_id: u64, data: Vec<u8>, is_eof: bool) -> bool {
        let handle = {
            let mut guard = lock_unpoisoned(&self.inner);
            guard.by_request.remove(&request_id)
        };
        if let Some(h) = handle {
            h.supply_bytes(request_id, data, is_eof);
            true
        } else {
            crate::map_log!(
                4,
                "[SOURCE] CustomSourceRegistry::resolve_request ignored stale request_id={}",
                request_id
            );
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
        if !requests.is_empty() || !handles.is_empty() {
            crate::map_log!(
                3,
                "[SOURCE] CustomSourceRegistry::abort_all cancelling {} pending request(s) and {} active handle(s)",
                requests.len(),
                handles.len()
            );
        }
        for h in requests {
            h.abort();
        }
        for shared in handles {
            CustomByteSourceHandle { shared }.abort();
        }
    }
}

/// Thread-safe controller handle for supplying bytes or abort notifications to a [`CustomDartByteSource`].
#[derive(Clone)]
pub struct CustomByteSourceHandle {
    /// Shared mutex and condition variable synchronizing Dart responses with the reader thread.
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
}

impl CustomByteSourceHandle {
    /// Delivers requested byte `data` and `is_eof` status for `request_id` to the awaiting reader thread.
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
    /// Stream identifier included in emitted [`DartReadRequest`] events.
    stream_id: u32,
    /// Known total byte length of the custom stream, if finite and provided.
    total_size: Option<u64>,
    /// Whether this custom stream supports random-access seeking.
    seekable: bool,
    /// Current logical byte cursor within the stream.
    cursor: u64,
    /// Shared synchronization state paired with [`CustomByteSourceHandle`].
    shared: Arc<(Mutex<CustomSharedState>, Condvar)>,
    /// Callback emitting [`DartReadRequest`] events to Dart.
    request_sender: Arc<dyn Fn(DartReadRequest) + Send + Sync>,
    /// Optional registry tracking in-flight request IDs and active handles.
    registry: Option<CustomSourceRegistry>,
    /// Most recently dispatched request ID for cleanup on `Drop`.
    last_request_id: u64,
}

impl CustomDartByteSource {
    /// Minimum prefetch chunk size in bytes (32 KB).
    pub const MIN_PREFETCH_BYTES: usize = 32 * 1024;
    /// Maximum duration to wait for a Dart read response before timing out (10s).
    pub const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);

    /// Creates a new [`CustomDartByteSource`] with identifier `stream_id`, optional `total_size`,
    /// `seekable` capability flag, and `request_sender` callback, registered against an optional `registry`.
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

        crate::map_log!(
            4,
            "[SOURCE] CustomDartByteSource::with_registry stream_id={} total_size={:?} seekable={}",
            stream_id,
            total_size,
            seekable
        );

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

    /// Dispatches a Dart read request of at least `min_len` bytes at `self.cursor` and blocks until fulfilled, aborted, or timed out.
    ///
    /// # Errors
    /// Returns [`ErrorKind::ConnectionAborted`] if aborted or [`ErrorKind::TimedOut`] if Dart does not reply within [`Self::RESPONSE_TIMEOUT`].
    fn request_and_await_chunk(&mut self, min_len: usize) -> IoResult<()> {
        let req_id = NEXT_CUSTOM_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        self.last_request_id = req_id;
        let req_len = min_len.max(Self::MIN_PREFETCH_BYTES) as u32;

        let (lock, cvar) = &*self.shared;
        {
            let mut guard = lock_unpoisoned(lock);
            if guard.aborted {
                crate::map_log!(
                    2,
                    "[SOURCE] CustomDartByteSource aborted before request stream_id={} cursor={}",
                    self.stream_id,
                    self.cursor
                );
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
                crate::map_log!(
                    1,
                    "[SOURCE] CustomDartByteSource timed out waiting for request_id={} stream_id={} offset={}",
                    req_id,
                    self.stream_id,
                    self.cursor
                );
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
                crate::map_log!(
                    1,
                    "[SOURCE] CustomDartByteSource wait timed out for request_id={} stream_id={} offset={}",
                    req_id,
                    self.stream_id,
                    self.cursor
                );
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
            crate::map_log!(
                2,
                "[SOURCE] CustomDartByteSource aborted while awaiting request_id={} stream_id={}",
                req_id,
                self.stream_id
            );
            return Err(custom_aborted_error());
        }
        Ok(())
    }

    /// Resolves a [`SeekFrom`] `pos` into an absolute byte offset within this custom stream.
    ///
    /// # Errors
    /// Returns [`ErrorKind::InvalidInput`] for negative targets or [`ErrorKind::Unsupported`] when seeking from end without `total_size`.
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
    /// Reads buffered or newly fetched Dart stream bytes into `buf` and advances `self.cursor`.
    ///
    /// # Errors
    /// Returns an `std::io::Error` if the stream is aborted or a Dart chunk fetch times out.
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
    /// Seeks the stream cursor to `pos`, discarding any buffered lookahead bytes when the offset changes.
    ///
    /// # Errors
    /// Returns [`ErrorKind::Unsupported`] when non-seekable, [`ErrorKind::ConnectionAborted`] if aborted, or [`ErrorKind::InvalidInput`] on negative targets.
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
    /// Unregisters any lingering `last_request_id` from the associated [`CustomSourceRegistry`].
    fn drop(&mut self) {
        if let Some(ref reg) = self.registry {
            if self.last_request_id != 0 {
                reg.unregister_request(self.last_request_id);
            }
        }
    }
}

impl MediaSource for CustomDartByteSource {
    /// Returns whether this custom byte stream supports random-access seeking.
    #[inline]
    fn is_seekable(&self) -> bool {
        self.seekable
    }

    /// Returns the total byte length of the custom stream if known.
    #[inline]
    fn byte_len(&self) -> Option<u64> {
        self.total_size
    }
}

impl CustomDartByteSource {
    /// Overrides whether this source is `seekable` (e.g. live unseekable WebSocket streams).
    #[inline]
    pub fn set_seekable(&mut self, seekable: bool) {
        crate::map_log!(
            4,
            "[SOURCE] CustomDartByteSource::set_seekable stream_id={} seekable={}",
            self.stream_id,
            seekable
        );
        self.seekable = seekable;
    }
}
