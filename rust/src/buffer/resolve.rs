//! Unified asynchronous Dart source resolution bridge (`DartResolveRegistry`).
//!
//! Used by Rust when a source requires Flutter/Dart platform services or bundle
//! access (`asset://`, `package:`, Android `content://`/`android.resource://`,
//! `ws://`/`wss://`, or Web debug asset probing).

use std::collections::HashMap;
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::api::types::{RustHttpHeader, RustResolvedSource};
#[cfg(not(unix))]
use crate::bridge::ffi::MAP_ERROR_UNSUPPORTED;
use crate::bridge::ffi::MAP_ERROR_FILE_NOT_FOUND;
use crate::buffer::source::FileByteSource;
use crate::core::dual_source::MAP_ERROR_ABORTED;
use crate::sync::{lock_unpoisoned, CancelToken, MonotonicInstant};

const DEFAULT_RESOLVE_TIMEOUT_MS: u64 = 30_000;
const CANCEL_POLL_INTERVAL_MS: u64 = 15;

static NEXT_RESOLVE_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

/// Request dispatched from Rust to Dart over `RustPlayerEvent::DartResolveRequest`.
#[derive(Debug, Clone)]
pub struct DartResolveRequest {
    pub request_id: u64,
    pub source: String,
    pub headers: Option<Vec<RustHttpHeader>>,
}

/// Result of opening a detached OS file descriptor: either an $O(1)$-RAM seekable
/// [`FileByteSource`] slice or fallback memory bytes when the underlying FD is a
/// non-seekable pipe/stream.
pub enum FdOpenOutcome {
    Seekable(FileByteSource),
    MemoryBytes(Vec<u8>),
}

/// Descriptive error returned when Dart source resolution or waiting fails.
#[derive(Debug, Clone)]
pub struct ResolveFailure {
    pub code: i32,
    pub message: String,
}

impl ResolveFailure {
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// Owned, RAII-safe resolution payload produced by Dart.
///
/// Any Unix `RawFd` inside [`RustResolvedSource::Fd`] is wrapped into an owned
/// [`std::fs::File`] immediately upon conversion so dropping or aborting this
/// payload never leaks an open file descriptor.
#[derive(Debug)]
pub enum ResolvedCoreSource {
    Path(String),
    Url(String),
    Fd {
        #[cfg(unix)]
        file: File,
        #[cfg(not(unix))]
        _fd: i32,
        offset: u64,
        length: Option<u64>,
        hint_ext: Option<String>,
    },
    Bytes {
        data: Vec<u8>,
        hint_ext: Option<String>,
    },
    CustomStream {
        stream_id: u32,
        total_bytes: Option<u64>,
        hint_ext: Option<String>,
    },
    Error {
        code: i32,
        message: String,
    },
}

impl ResolvedCoreSource {
    /// Converts the FRB wire enum into an RAII-managed core payload immediately,
    /// wrapping any POSIX `fd >= 0` in [`std::fs::File`] so it is always closed on drop.
    pub fn from_rust(src: RustResolvedSource) -> Self {
        match src {
            RustResolvedSource::Path { path } => Self::Path(path),
            RustResolvedSource::Url { url } => Self::Url(url),
            RustResolvedSource::Fd {
                fd,
                offset,
                length,
                hint_ext,
            } => {
                if fd < 0 {
                    return Self::Error {
                        code: MAP_ERROR_FILE_NOT_FOUND,
                        message: format!("Invalid file descriptor ({})", fd),
                    };
                }
                #[cfg(unix)]
                {
                    use std::os::unix::io::FromRawFd;
                    // SAFETY: Ownership of `fd` was explicitly transferred by Dart / Kotlin
                    // `ParcelFileDescriptor.detachFd()` for this single resolve response.
                    let file = unsafe { File::from_raw_fd(fd) };
                    Self::Fd {
                        file,
                        offset,
                        length,
                        hint_ext,
                    }
                }
                #[cfg(not(unix))]
                {
                    Self::Fd {
                        _fd: fd,
                        offset,
                        length,
                        hint_ext,
                    }
                }
            }
            RustResolvedSource::Bytes { data, hint_ext } => Self::Bytes { data, hint_ext },
            RustResolvedSource::CustomStream {
                stream_id,
                total_bytes,
                hint_ext,
            } => Self::CustomStream {
                stream_id,
                total_bytes,
                hint_ext,
            },
            RustResolvedSource::Error { code, message } => Self::Error { code, message },
        }
    }

    /// Consumes an `Fd` into a seekable [`FileByteSource`] slice or reads non-seekable
    /// pipe/FIFO FDs into memory.
    #[cfg(unix)]
    pub fn open_fd_slice(
        mut file: File,
        offset: u64,
        length: Option<u64>,
    ) -> Result<FdOpenOutcome, String> {
        use std::io::{Seek, SeekFrom};
        if let Ok(end) = file.seek(SeekFrom::End(0)) {
            let available = end.saturating_sub(offset);
            let effective_len = length.map(|l| l.min(available)).unwrap_or(available);
            match FileByteSource::from_file_slice_with_len(file, offset, effective_len) {
                Ok(src) => return Ok(FdOpenOutcome::Seekable(src)),
                Err(e) => return Err(format!("Failed to initialize file slice reader: {}", e)),
            }
        }

        // Fallback for non-seekable pipe FDs returned by virtual ContentProviders.
        if offset > 0 {
            let mut skip_left = offset;
            let mut scratch = [0u8; 4096];
            while skip_left > 0 {
                let want = scratch.len().min(skip_left as usize);
                let n = file
                    .read(&mut scratch[..want])
                    .map_err(|e| format!("Failed reading offset from stream FD: {}", e))?;
                if n == 0 {
                    break;
                }
                skip_left -= n as u64;
            }
        }
        let mut bytes = Vec::new();
        if let Some(limit) = length {
            file.take(limit)
                .read_to_end(&mut bytes)
                .map_err(|e| format!("Failed reading bounded pipe FD: {}", e))?;
        } else {
            file.read_to_end(&mut bytes)
                .map_err(|e| format!("Failed reading stream FD: {}", e))?;
        }
        Ok(FdOpenOutcome::MemoryBytes(bytes))
    }

    #[cfg(not(unix))]
    pub fn open_fd_slice_unsupported() -> ResolveFailure {
        ResolveFailure::new(
            MAP_ERROR_UNSUPPORTED,
            "POSIX file descriptors are only supported on Unix targets",
        )
    }
}

struct ResolveSlot {
    pair: Mutex<Option<ResolvedCoreSource>>,
    cvar: Condvar,
}

#[derive(Default)]
struct PendingResolveState {
    shutdown: bool,
    map: HashMap<u64, Arc<ResolveSlot>>,
}

/// Thread-safe asynchronous pull-resolution registry pairing Rust worker waits
/// with `RustMiniaudioPlayer::respond_dart_resolve_request`.
pub struct DartResolveRegistry {
    request_sender: Arc<dyn Fn(DartResolveRequest) + Send + Sync>,
    pending: Mutex<PendingResolveState>,
}

impl DartResolveRegistry {
    /// Creates a new registry emitting requests via `request_sender`.
    pub fn new(request_sender: Arc<dyn Fn(DartResolveRequest) + Send + Sync>) -> Self {
        Self {
            request_sender,
            pending: Mutex::new(PendingResolveState::default()),
        }
    }

    /// Requests resolution of `source` from Dart and blocks cleanly until
    /// answered, cancelled via `cancel`, shut down, or timed out.
    pub fn resolve(
        &self,
        source: &str,
        headers: Option<&[RustHttpHeader]>,
        cancel: Option<&CancelToken>,
    ) -> Result<ResolvedCoreSource, ResolveFailure> {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return Err(ResolveFailure::new(MAP_ERROR_ABORTED, "Resolution cancelled"));
        }

        let request_id = NEXT_RESOLVE_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let slot = Arc::new(ResolveSlot {
            pair: Mutex::new(None),
            cvar: Condvar::new(),
        });

        {
            let mut state = lock_unpoisoned(&self.pending);
            if state.shutdown {
                return Err(ResolveFailure::new(
                    MAP_ERROR_ABORTED,
                    "Player disposed while initiating Dart source resolution",
                ));
            }
            state.map.insert(request_id, slot.clone());
        }

        (self.request_sender)(DartResolveRequest {
            request_id,
            source: source.to_string(),
            headers: headers.map(|h| h.to_vec()),
        });

        let deadline = MonotonicInstant::now() + Duration::from_millis(DEFAULT_RESOLVE_TIMEOUT_MS);
        let mut guard = lock_unpoisoned(&slot.pair);
        loop {
            if let Some(resolved) = guard.take() {
                drop(guard);
                let mut state = lock_unpoisoned(&self.pending);
                state.map.remove(&request_id);
                return Ok(resolved);
            }

            if cancel.is_some_and(|c| c.is_cancelled()) {
                drop(guard);
                let mut state = lock_unpoisoned(&self.pending);
                state.map.remove(&request_id);
                return Err(ResolveFailure::new(MAP_ERROR_ABORTED, "Resolution cancelled"));
            }

            {
                let state = lock_unpoisoned(&self.pending);
                if state.shutdown {
                    drop(state);
                    drop(guard);
                    let mut st = lock_unpoisoned(&self.pending);
                    st.map.remove(&request_id);
                    return Err(ResolveFailure::new(
                        MAP_ERROR_ABORTED,
                        "Resolution aborted due to player shutdown",
                    ));
                }
            }

            let now = MonotonicInstant::now();
            if now >= deadline {
                drop(guard);
                let mut state = lock_unpoisoned(&self.pending);
                state.map.remove(&request_id);
                return Err(ResolveFailure::new(
                    MAP_ERROR_FILE_NOT_FOUND,
                    format!(
                        "Timed out after {}ms waiting for Dart to resolve source '{}'",
                        DEFAULT_RESOLVE_TIMEOUT_MS, source
                    ),
                ));
            }

            let remaining = deadline.saturating_duration_since(now);
            let wait_for = remaining.min(Duration::from_millis(CANCEL_POLL_INTERVAL_MS));
            let (next_guard, _) = slot
                .cvar
                .wait_timeout(guard, wait_for)
                .unwrap_or_else(|e| e.into_inner());
            guard = next_guard;
        }
    }

    /// Completes a pending resolution request from Dart.
    ///
    /// If `request_id` was already cancelled, timed out, or shut down, `resolved`
    /// (including any detached Unix `File` FD) is dropped immediately without leaking.
    pub fn resolve_request(&self, request_id: u64, resolved: RustResolvedSource) -> bool {
        let owned = ResolvedCoreSource::from_rust(resolved);
        let slot_opt = {
            let mut state = lock_unpoisoned(&self.pending);
            state.map.remove(&request_id)
        };
        if let Some(slot) = slot_opt {
            let mut guard = lock_unpoisoned(&slot.pair);
            *guard = Some(owned);
            slot.cvar.notify_all();
            true
        } else {
            // Dropped cleanly right here; any detached Unix File closes deterministically.
            drop(owned);
            false
        }
    }

    /// Aborts all pending resolution waiters cleanly on disposal/shutdown.
    pub fn cancel_all(&self) {
        let slots: Vec<Arc<ResolveSlot>> = {
            let mut state = lock_unpoisoned(&self.pending);
            state.shutdown = true;
            state.map.drain().map(|(_, s)| s).collect()
        };
        for slot in slots {
            slot.cvar.notify_all();
        }
    }
}
