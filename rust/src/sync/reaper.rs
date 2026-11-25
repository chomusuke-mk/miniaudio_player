//! Dedicated background Reaper thread for deterministic off-RT resource teardown.
//!
//! Ensures heavy destructors (`SoundBuffer` PCM buffers, `AudioRenderer`, device handles,
//! `LiveRecorder` WAV finalizers, and decoder thread joins) never execute on the real-time
//! audio thread or delay UI/control locks.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::core::voice_pool::{SoundBuffer, SoundBufferReaperFn};
use crate::sync::thread::{self, JoinHandle};

/// Bounded capacity of the background `map-reaper` teardown channel.
const REAPER_QUEUE_CAPACITY: usize = 1024;

/// Retired heavy resources queued for destruction by `map-reaper`.
pub enum ReaperTrash {
    /// Single retired PCM sound effect buffer pushed from real-time slots.
    SoundBuffer(SoundBuffer),
    /// Batch of retired PCM sound effect buffers displaced by catalog reloads or LRU eviction.
    SoundBuffers(Vec<SoundBuffer>),
    /// Generic deferred destructor closure (devices, renderers, decoder threads, recorders).
    Deferred(Box<dyn FnOnce() + Send>),
    /// Internal sentinel signalling `map-reaper` to exit cleanly after draining queued items.
    Shutdown,
}

/// Cloneable handle to the background `map-reaper` teardown thread.
#[derive(Clone)]
pub struct ReaperHandle {
    /// Bounded sender delivering [`ReaperTrash`] items to the background reaper thread.
    tx: Option<crossbeam_channel::Sender<ReaperTrash>>,
    /// Shared join handle for the `map-reaper` worker thread, taken on shutdown.
    worker: Option<Arc<std::sync::Mutex<Option<JoinHandle<()>>>>>,
    /// Flag indicating whether the reaper has stopped or is a no-op handle.
    stopped: Arc<AtomicBool>,
}

impl Default for ReaperHandle {
    /// Creates an inactive no-op [`ReaperHandle`].
    fn default() -> Self {
        Self::noop()
    }
}

impl ReaperHandle {
    /// Creates an inactive no-op reaper handle (used cleanly in unit/WASM environments).
    pub fn noop() -> Self {
        Self {
            tx: None,
            worker: None,
            stopped: Arc::new(AtomicBool::new(true)),
        }
    }

    /// Spawns the dedicated `map-reaper` background thread.
    pub fn spawn() -> Self {
        let (tx, rx) = crossbeam_channel::bounded::<ReaperTrash>(REAPER_QUEUE_CAPACITY);
        let stopped = Arc::new(AtomicBool::new(false));
        let spawn_res = thread::Builder::new()
            .name("map-reaper".to_string())
            .spawn(move || {
                while let Ok(item) = rx.recv() {
                    match item {
                        ReaperTrash::SoundBuffer(buf) => drop(buf),
                        ReaperTrash::SoundBuffers(bufs) => drop(bufs),
                        ReaperTrash::Deferred(task) => task(),
                        ReaperTrash::Shutdown => {
                            crate::map_log!(
                                4,
                                "[REAPER] Received shutdown sentinel; exiting map-reaper thread"
                            );
                            break;
                        }
                    }
                }
            });

        match spawn_res {
            Ok(jh) => {
                crate::map_log!(3, "[REAPER] Spawned background map-reaper thread");
                Self {
                    tx: Some(tx),
                    worker: Some(Arc::new(std::sync::Mutex::new(Some(jh)))),
                    stopped,
                }
            }
            Err(e) => {
                crate::map_log!(
                    1,
                    "[REAPER] Failed to spawn map-reaper thread ({}); falling back to noop",
                    e
                );
                Self::noop()
            }
        }
    }

    /// Non-blocking submission of `item` safe to invoke from real-time audio paths.
    #[inline]
    pub fn push_from_rt(&self, item: ReaperTrash) {
        if let Some(ref tx) = self.tx {
            if !self.stopped.load(Ordering::Acquire) {
                let _ = tx.try_send(item);
                return;
            }
        }
        drop(item);
    }

    /// Submits a heavy `value` for off-thread destruction, dropping inline if shut down.
    pub fn reap_value<T: Send + 'static>(&self, value: T) {
        if let Some(ref tx) = self.tx {
            if !self.stopped.load(Ordering::Acquire) {
                let task: Box<dyn FnOnce() + Send> = Box::new(move || drop(value));
                if let Err(err) = tx.try_send(ReaperTrash::Deferred(task)) {
                    crate::map_log!(
                        2,
                        "[REAPER] Reaper queue full or disconnected; dropping deferred value inline"
                    );
                    drop(err);
                }
                return;
            }
        }
        drop(value);
    }

    /// Submits displaced PCM sound effect `buffers` for off-thread destruction.
    #[inline]
    pub fn reap_sound_buffers(&self, buffers: Vec<SoundBuffer>) {
        if buffers.is_empty() {
            return;
        }
        if let Some(ref tx) = self.tx {
            if !self.stopped.load(Ordering::Acquire) {
                if let Err(err) = tx.try_send(ReaperTrash::SoundBuffers(buffers)) {
                    crate::map_log!(
                        2,
                        "[REAPER] Reaper queue full or disconnected; dropping sound buffers inline"
                    );
                    drop(err);
                }
                return;
            }
        }
        drop(buffers);
    }

    /// Creates a real-time safe callback closure for [`crate::core::voice_pool::VoicePoolRt`].
    pub fn sound_buffer_reaper_fn(&self) -> SoundBufferReaperFn {
        let handle = self.clone();
        Box::new(move |buf: SoundBuffer| {
            handle.push_from_rt(ReaperTrash::SoundBuffer(buf));
        })
    }

    /// Signals `map-reaper` to drain any pending work and joins cleanly (idempotent).
    pub fn shutdown(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        crate::map_log!(3, "[REAPER] Shutting down map-reaper background thread");
        if let Some(ref tx) = self.tx {
            if let Err(e) = tx.send(ReaperTrash::Shutdown) {
                crate::map_log!(2, "[REAPER] Failed to send shutdown sentinel: {}", e);
            }
        }
        if let Some(ref worker) = self.worker {
            let jh_opt = crate::sync::lock_unpoisoned(worker).take();
            if let Some(jh) = jh_opt {
                let _ = jh.join();
                crate::map_log!(4, "[REAPER] map-reaper thread joined cleanly");
            }
        }
    }
}
