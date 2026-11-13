//! Cooperative hierarchical cancellation tokens with abort hooks for blocking I/O.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::sync::lock_unpoisoned;

type AbortHook = Box<dyn FnOnce() + Send + Sync>;

struct CancelInner {
    cancelled: AtomicBool,
    next_hook_id: AtomicU64,
    hooks: Mutex<Vec<(u64, AbortHook)>>,
}

/// RAII guard that unregisters a cancel hook or child link when dropped.
pub struct CancelHookGuard {
    inner: Arc<CancelInner>,
    hook_id: u64,
}

impl Drop for CancelHookGuard {
    fn drop(&mut self) {
        if self.hook_id == 0 {
            return;
        }
        let mut guard = lock_unpoisoned(&self.inner.hooks);
        if let Some(pos) = guard.iter().position(|(id, _)| *id == self.hook_id) {
            let _ = guard.swap_remove(pos);
        }
    }
}

/// Thread-safe cooperative cancellation token with synchronous abort callbacks.
///
/// Used across `IoWorkerPool`, `ControlCoordinator`, HTTP pre-fetch loops, and
/// `CustomByteSourceHandle` so superseded track opens abort promptly.
#[derive(Clone)]
pub struct CancelToken {
    inner: Arc<CancelInner>,
}

impl Default for CancelToken {
    fn default() -> Self {
        Self::new()
    }
}

impl CancelToken {
    /// Creates an active, uncancelled token.
    pub fn new() -> Self {
        Self {
            inner: Arc::new(CancelInner {
                cancelled: AtomicBool::new(false),
                next_hook_id: AtomicU64::new(1),
                hooks: Mutex::new(Vec::new()),
            }),
        }
    }

    /// Returns `true` if `cancel()` has been invoked on any clone of this token.
    #[inline]
    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::Acquire)
    }

    /// Cancels this token and synchronously executes all registered abort hooks.
    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::Release);
        let hooks = {
            let mut guard = lock_unpoisoned(&self.inner.hooks);
            std::mem::take(&mut *guard)
        };
        for (_id, hook) in hooks {
            hook();
        }
    }

    /// Registers a one-shot callback invoked immediately if cancelled, or on `cancel()`.
    pub fn on_cancel<F>(&self, hook: F) -> CancelHookGuard
    where
        F: FnOnce() + Send + Sync + 'static,
    {
        let mut guard = lock_unpoisoned(&self.inner.hooks);
        if self.inner.cancelled.load(Ordering::Acquire) {
            drop(guard);
            hook();
            return CancelHookGuard {
                inner: Arc::clone(&self.inner),
                hook_id: 0,
            };
        }
        let hook_id = self.inner.next_hook_id.fetch_add(1, Ordering::Relaxed);
        guard.push((hook_id, Box::new(hook)));
        CancelHookGuard {
            inner: Arc::clone(&self.inner),
            hook_id,
        }
    }

    /// Links a child token so cancelling `self` automatically cancels `child` until guard drop.
    pub fn link_child(&self, child: &CancelToken) -> CancelHookGuard {
        let child_clone = child.clone();
        self.on_cancel(move || child_clone.cancel())
    }

    /// Sleeps up to `total`, returning `true` early if the token is cancelled.
    pub fn sleep_interruptible(&self, total: Duration) -> bool {
        let start = Instant::now();
        while !self.is_cancelled() {
            let elapsed = start.elapsed();
            if elapsed >= total {
                return false;
            }
            let step = (total - elapsed).min(Duration::from_millis(5));
            std::thread::sleep(step);
        }
        true
    }
}
