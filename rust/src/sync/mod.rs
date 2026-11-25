//! Real-time lock-free synchronization and telemetry primitives.
//!
//! Provides single-producer single-consumer (SPSC) ring buffers, cache-padded seqlocks
//! for lockless reader-writer synchronization, and a zero-allocation telemetry dispatcher.

/// Cooperative hierarchical cancellation tokens and RAII abort hook guards.
pub mod cancel;
/// Dedicated background reaper thread for off-RT resource teardown.
pub mod reaper;
/// Lock-free single-producer single-consumer (SPSC) audio sample ring buffers.
pub mod ring_buffer;
/// Cache-line padded seqlock for wait-free reader snapshots.
pub mod seqlock;
/// Reactive telemetry event types and background dispatcher pipeline.
pub mod telemetry;

pub use cancel::{CancelHookGuard, CancelToken};
pub use reaper::{ReaperHandle, ReaperTrash};
pub use ring_buffer::{AudioConsumer, AudioProducer, AudioRingBuffer};
pub use seqlock::CachePaddedSeqlock;
pub use telemetry::{
    EventType, MapEventData, MonotonicInstant, TelemetryDispatcher, TelemetryEvent,
    TypedEventCallback,
};

use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Acquires a guard on mutex `m` even if a previous holder panicked (poison recovery).
#[inline]
pub fn lock_unpoisoned<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Waits on condition variable `cvar` using mutex `guard` for up to `dur`, recovering if poisoned.
#[inline]
pub fn wait_timeout_unpoisoned<'a, T>(
    cvar: &std::sync::Condvar,
    guard: MutexGuard<'a, T>,
    dur: std::time::Duration,
) -> (MutexGuard<'a, T>, std::sync::WaitTimeoutResult) {
    cvar.wait_timeout(guard, dur).unwrap_or_else(|e| e.into_inner())
}

/// Outcome of waiting with a timeout on a [`WakeQueue`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WakeRecvError {
    /// No item arrived before the requested timeout elapsed.
    Timeout,
    /// The queue was closed and has no remaining queued items.
    Disconnected,
}

/// Internal FIFO buffer and closure state protected by [`WakeQueue`].
struct WakeQueueInner<T> {
    /// Queued wakeup items awaiting consumption in FIFO order.
    items: std::collections::VecDeque<T>,
    /// Flag indicating that [`WakeQueue::close`] has been called.
    closed: bool,
}

/// Cross-platform MPSC wakeup queue using `Condvar::wait_timeout` instead of
/// `crossbeam_channel::Receiver::recv_timeout` (whose deadline math calls
/// `std::time::Instant::now()` and panics on `wasm32`).
pub struct WakeQueue<T> {
    /// Mutex guarding the item queue and closed state.
    lock: Mutex<WakeQueueInner<T>>,
    /// Condition variable signalled on enqueue and queue closure.
    cvar: std::sync::Condvar,
}

impl<T> WakeQueue<T> {
    /// Creates an open empty [`WakeQueue`].
    pub fn new() -> Self {
        Self {
            lock: Mutex::new(WakeQueueInner {
                items: std::collections::VecDeque::new(),
                closed: false,
            }),
            cvar: std::sync::Condvar::new(),
        }
    }

    /// Pushes `item` and wakes one waiting consumer. Returns `false` if closed.
    pub fn send(&self, item: T) -> bool {
        let mut guard = lock_unpoisoned(&self.lock);
        if guard.closed {
            return false;
        }
        guard.items.push_back(item);
        drop(guard);
        self.cvar.notify_one();
        true
    }

    /// Closes the queue and wakes all waiting consumers.
    pub fn close(&self) {
        let mut guard = lock_unpoisoned(&self.lock);
        guard.closed = true;
        drop(guard);
        self.cvar.notify_all();
    }

    /// Attempts to pop the next item without blocking.
    pub fn try_pop(&self) -> Option<T> {
        lock_unpoisoned(&self.lock).items.pop_front()
    }

    /// Waits up to `timeout` for an item, avoiding `std::time::Instant::now()`.
    ///
    /// # Errors
    ///
    /// Returns [`WakeRecvError::Timeout`] if `timeout` elapses (or the thread cannot block),
    /// or [`WakeRecvError::Disconnected`] if the queue is closed and empty.
    pub fn wait_pop_timeout(&self, timeout: std::time::Duration) -> Result<T, WakeRecvError> {
        let mut guard = lock_unpoisoned(&self.lock);
        if let Some(item) = guard.items.pop_front() {
            return Ok(item);
        }
        if guard.closed {
            return Err(WakeRecvError::Disconnected);
        }
        if timeout.is_zero() || !can_block_current_thread() {
            return Err(WakeRecvError::Timeout);
        }
        let (mut guard, _) = wait_timeout_unpoisoned(&self.cvar, guard, timeout);
        if let Some(item) = guard.items.pop_front() {
            Ok(item)
        } else if guard.closed {
            Err(WakeRecvError::Disconnected)
        } else {
            Err(WakeRecvError::Timeout)
        }
    }

    /// Waits up to `timeout` when empty, then drains all available items into `out`.
    /// Returns `false` once the queue is closed and completely empty.
    pub fn wait_drain_timeout(&self, timeout: std::time::Duration, out: &mut Vec<T>) -> bool {
        let mut guard = lock_unpoisoned(&self.lock);
        if guard.items.is_empty()
            && !guard.closed
            && !timeout.is_zero()
            && can_block_current_thread()
        {
            let (g, _) = wait_timeout_unpoisoned(&self.cvar, guard, timeout);
            guard = g;
        }
        out.extend(guard.items.drain(..));
        !(guard.closed && out.is_empty())
    }
}

impl<T> Default for WakeQueue<T> {
    /// Creates an open empty [`WakeQueue`].
    fn default() -> Self {
        Self::new()
    }
}

/// Acquires a read lock on `rw`, recovering gracefully from poisoning.
#[inline]
pub fn read_unpoisoned<T>(rw: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    rw.read().unwrap_or_else(|e| e.into_inner())
}

/// Acquires a write lock on `rw`, recovering gracefully from poisoning.
#[inline]
pub fn write_unpoisoned<T>(rw: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    rw.write().unwrap_or_else(|e| e.into_inner())
}

/// Returns `true` if the current thread is allowed to block on `Atomics.wait` / futexes.
#[inline]
pub fn can_block_current_thread() -> bool {
    #[cfg(target_arch = "wasm32")]
    {
        !thread::is_web_main_thread()
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        true
    }
}

/// Initializes the main-thread Web Worker spawner on `wasm32` (no-op on native targets).
#[inline]
pub fn init_wasm_thread_spawner() {
    #[cfg(target_arch = "wasm32")]
    {
        crate::map_log!(3, "[WASM_THREAD] Initializing Web Worker thread spawner");
        thread::ensure_main_thread_spawner();
        crate::net::ureq::ensure_network_worker();
        crate::opfs::ensure_opfs_worker();
    }
}

/// Cross-platform threading module re-exporting `std::thread` on native targets.
#[cfg(not(target_arch = "wasm32"))]
pub mod thread {
    pub use std::thread::*;
}

/// Web Worker-backed threading shim mirroring `std::thread` APIs on `wasm32`.
#[cfg(target_arch = "wasm32")]
pub mod thread {
    use std::cell::RefCell;
    use std::io;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Condvar, Mutex, OnceLock};
    use std::time::Duration;

    use flutter_rust_bridge::for_generated::js_sys::{self, Function, Reflect};
    use flutter_rust_bridge::for_generated::wasm_bindgen;
    use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;

    pub use std::thread::{Result, yield_now};

    /// `BroadcastChannel` identifier used by background workers to request main-thread spawns.
    const SPAWNER_CHANNEL_NAME: &str = "__miniaudio_wasm_thread_spawner__";
    /// Cached URL of the `miniaudio_player.js` glue script loaded inside spawned Web Workers.
    static SCRIPT_SRC: OnceLock<String> = OnceLock::new();
    /// Atomic flag set once the main-thread `BroadcastChannel` spawner is active.
    static MAIN_SPAWNER_READY: AtomicBool = AtomicBool::new(false);

    thread_local! {
        /// Cached JS function dispatching a boxed task pointer to a pooled Web Worker.
        static DISPATCH_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
        /// Cached JS function installing the main-thread `BroadcastChannel` worker spawner.
        static SPAWNER_SETUP_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
        /// Cached JS function posting a spawn request pointer to the main thread over `BroadcastChannel`.
        static POST_CHANNEL_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
    }

    /// Returns `true` when executing on the browser's main UI thread (`window` and `document` present).
    #[inline]
    pub fn is_web_main_thread() -> bool {
        let global = js_sys::global();
        Reflect::has(&global, &JsValue::from_str("window")).unwrap_or(false)
            && Reflect::has(&global, &JsValue::from_str("document")).unwrap_or(false)
    }

    /// Suspends the current worker thread for `dur` via `Condvar::wait_timeout` (no-op on the main thread).
    #[inline]
    pub fn sleep(dur: Duration) {
        if dur.is_zero() || is_web_main_thread() {
            return;
        }
        let lock = Mutex::new(());
        let cvar = Condvar::new();
        let guard = super::lock_unpoisoned(&lock);
        let _ = super::wait_timeout_unpoisoned(&cvar, guard, dur);
    }

    /// Resolves and caches the script URL for `miniaudio_player.js` so Web Workers can `importScripts` it.
    fn resolve_script_src() -> String {
        SCRIPT_SRC
            .get_or_init(|| {
                if let Ok(val) = js_sys::eval(
                    r#"(() => {
                        if (typeof document !== 'undefined') {
                            const scripts = document.getElementsByTagName('script');
                            for (let i = scripts.length - 1; i >= 0; i--) {
                                if (scripts[i].src && scripts[i].src.indexOf('miniaudio_player') !== -1) {
                                    return scripts[i].src;
                                }
                            }
                        }
                        try {
                            throw new Error();
                        } catch (e) {
                            const m = e.stack && e.stack.match(/(?:\(|@)(https?:\/\/[^\s:)"]+\.js):\d+:\d+/);
                            if (m) return m[1];
                        }
                        const rel = 'assets/packages/miniaudio_player/assets/web/miniaudio_player.js';
                        if (typeof URL !== 'undefined') {
                            const base = (typeof document !== 'undefined' && document.baseURI)
                                || (typeof location !== 'undefined' ? location.href : '');
                            if (base) {
                                return new URL(rel, base).href;
                            }
                        }
                        if (typeof location !== 'undefined' && location.origin) {
                            return location.origin + '/' + rel;
                        }
                        return rel;
                    })()"#,
                ) {
                    if let Some(s) = val.as_string() {
                        if !s.is_empty() {
                            return s;
                        }
                    }
                }
                "assets/packages/miniaudio_player/assets/web/miniaudio_player.js".to_string()
            })
            .clone()
    }

    /// Installs the main-thread `BroadcastChannel` worker spawner listener when running on the UI thread.
    pub fn ensure_main_thread_spawner() {
        if !is_web_main_thread() {
            return;
        }
        let script_src = resolve_script_src();
        let func = SPAWNER_SETUP_FN.with(|slot| {
            let mut borrow = slot.borrow_mut();
            if borrow.is_none() {
                let code = r#"
                    if (self.__miniaudioSpawnerChannel) return true;
                    try {
                        var ch = new BroadcastChannel(channelName);
                        ch.onmessage = function(ev) {
                            var ptr = ev.data | 0;
                            if (ptr !== 0 && typeof self.__miniaudioDispatchWorkerTask === 'function') {
                                self.__miniaudioDispatchWorkerTask(ptr, scriptSrc, mod, mem);
                            }
                        };
                        self.__miniaudioSpawnerChannel = ch;
                        return true;
                    } catch (_) {
                        return false;
                    }
                "#;
                *borrow = Some(Function::new_with_args(
                    "channelName, scriptSrc, mod, mem",
                    code,
                ));
            }
            borrow.clone().unwrap()
        });
        let _ = dispatch_task_to_worker(0);
        match func.call4(
            &JsValue::NULL,
            &JsValue::from_str(SPAWNER_CHANNEL_NAME),
            &JsValue::from_str(&script_src),
            &wasm_bindgen::module(),
            &wasm_bindgen::memory(),
        ) {
            Ok(ok) if ok.as_bool() == Some(true) => {
                if !MAIN_SPAWNER_READY.swap(true, Ordering::Release) {
                    crate::map_log!(
                        3,
                        "[WASM_THREAD] Main-thread BroadcastChannel worker spawner ready (src={})",
                        script_src
                    );
                }
            }
            Ok(_) => {
                crate::map_log!(
                    2,
                    "[WASM_THREAD] Main-thread BroadcastChannel worker spawner returned false"
                );
            }
            Err(err) => {
                crate::map_log!(
                    2,
                    "[WASM_THREAD] Failed to initialize main-thread worker spawner: {:?}",
                    err
                );
            }
        }
    }

    /// Dispatches a boxed [`ThreadTask`] pointer `task_ptr` to an idle or newly created Web Worker.
    ///
    /// # Errors
    ///
    /// Returns a [`JsValue`] exception if evaluating or invoking the JS worker dispatcher fails.
    fn dispatch_task_to_worker(task_ptr: u32) -> std::result::Result<(), JsValue> {
        let script_src = resolve_script_src();
        let func = DISPATCH_FN.with(|slot| {
            let mut borrow = slot.borrow_mut();
            if borrow.is_none() {
                let code = r#"
                    if (!self.__miniaudioDispatchWorkerTask) {
                        self.__miniaudioIdleWorkers = self.__miniaudioIdleWorkers || [];
                        self.__miniaudioDispatchWorkerTask = function(ptr, src, wasmMod, wasmMem) {
                            if (ptr === 0) return true;
                            var pool = self.__miniaudioIdleWorkers;
                            var worker = pool.pop();
                            if (!worker) {
                                var workerCode = "importScripts('" + src + "');\n" +
                                    "onmessage = function(e) {\n" +
                                    "  var d = e.data;\n" +
                                    "  var initP = wasm_bindgen({ module_or_path: d[0], memory: d[1] });\n" +
                                    "  onmessage = async function(ev) {\n" +
                                    "    await initP;\n" +
                                    "    try { wasm_bindgen.wasm_thread_entry_point(ev.data); postMessage(0); }\n" +
                                    "    catch (err) { postMessage(1); throw err; }\n" +
                                    "  };\n" +
                                    "};";
                                var blob = new Blob([workerCode], { type: 'text/javascript' });
                                var url = URL.createObjectURL(blob);
                                worker = new Worker(url);
                                URL.revokeObjectURL(url);
                                worker.postMessage([wasmMod, wasmMem]);
                            }
                            worker.onmessage = function(ev) {
                                if (ev && ev.data === 0) {
                                    pool.push(worker);
                                } else {
                                    try { worker.terminate(); } catch (_) {}
                                }
                            };
                            worker.postMessage(ptr);
                            return true;
                        };
                    }
                    return self.__miniaudioDispatchWorkerTask(taskPtr, scriptSrc, mod, mem);
                "#;
                *borrow = Some(Function::new_with_args(
                    "taskPtr, scriptSrc, mod, mem",
                    code,
                ));
            }
            borrow.clone().unwrap()
        });
        func.call4(
            &JsValue::NULL,
            &JsValue::from_f64(task_ptr as f64),
            &JsValue::from_str(&script_src),
            &wasm_bindgen::module(),
            &wasm_bindgen::memory(),
        )?;
        Ok(())
    }

    /// Forwards a boxed [`ThreadTask`] pointer `task_ptr` from a worker thread to the main thread's spawner.
    ///
    /// # Errors
    ///
    /// Returns a [`JsValue`] exception if posting to the `BroadcastChannel` fails.
    fn post_spawn_to_main_thread(task_ptr: u32) -> std::result::Result<(), JsValue> {
        let func = POST_CHANNEL_FN.with(|slot| {
            let mut borrow = slot.borrow_mut();
            if borrow.is_none() {
                let code = r#"
                    var ch = new BroadcastChannel(channelName);
                    ch.postMessage(taskPtr);
                    ch.close();
                    return true;
                "#;
                *borrow = Some(Function::new_with_args("channelName, taskPtr", code));
            }
            borrow.clone().unwrap()
        });
        func.call2(
            &JsValue::NULL,
            &JsValue::from_str(SPAWNER_CHANNEL_NAME),
            &JsValue::from_f64(task_ptr as f64),
        )?;
        Ok(())
    }

    /// Heap-allocated closure payload transferred across shared WASM memory to a Web Worker.
    pub struct ThreadTask {
        /// Flag flipped to `true` once the target Web Worker enters [`wasm_thread_entry_point`].
        started: Arc<AtomicBool>,
        /// Boxed entry closure executed on the worker thread.
        func: Box<dyn FnOnce() + Send + 'static>,
    }

    /// Entry point invoked by spawned Web Workers to execute a boxed [`ThreadTask`] at `task_ptr`.
    #[wasm_bindgen]
    pub fn wasm_thread_entry_point(task_ptr: u32) {
        if task_ptr == 0 {
            return;
        }
        let task = unsafe { Box::from_raw(task_ptr as *mut ThreadTask) };
        task.started.store(true, Ordering::Release);
        (task.func)();
    }

    /// Synchronization state shared between a spawned Web Worker and its [`JoinHandle`].
    struct SharedJoinState<T> {
        /// Captured return value or panic payload produced by the worker closure.
        result: Mutex<Option<Result<T>>>,
        /// Completion flag set after storing `result`.
        done: AtomicBool,
        /// Condition variable notified when the worker finishes.
        cvar: Condvar,
    }

    /// Join handle for a task spawned onto a Web Worker via [`Builder::spawn`].
    pub struct JoinHandle<T> {
        /// Shared flag indicating whether the worker started executing the task.
        started: Arc<AtomicBool>,
        /// Shared completion state holding the worker result.
        state: Arc<SharedJoinState<T>>,
    }

    impl<T> JoinHandle<T> {
        /// Waits briefly (off the main thread) for the worker task to complete and returns its result.
        ///
        /// # Errors
        ///
        /// Returns an `Err` panic payload if the worker panicked or if joining timed out / was deferred.
        pub fn join(self) -> Result<T> {
            if !self.state.done.load(Ordering::Acquire)
                && !is_web_main_thread()
                && self.started.load(Ordering::Acquire)
            {
                let mut guard = super::lock_unpoisoned(&self.state.result);
                while guard.is_none() && !self.state.done.load(Ordering::Acquire) {
                    let (g, timeout_res) = super::wait_timeout_unpoisoned(
                        &self.state.cvar,
                        guard,
                        Duration::from_millis(250),
                    );
                    guard = g;
                    if timeout_res.timed_out() {
                        break;
                    }
                }
            }
            if let Some(res) = super::lock_unpoisoned(&self.state.result).take() {
                res
            } else {
                Err(Box::new("wasm worker join deferred"))
            }
        }
    }

    /// Thread builder configuring and spawning background Web Worker tasks on `wasm32`.
    #[derive(Default)]
    pub struct Builder {
        /// Optional diagnostic name assigned to the spawned worker task.
        name: Option<String>,
    }

    impl Builder {
        /// Creates a new [`Builder`] with default settings.
        pub fn new() -> Self {
            Self { name: None }
        }

        /// Sets the diagnostic `name` of the thread to be spawned.
        pub fn name(mut self, name: String) -> Self {
            self.name = Some(name);
            self
        }

        /// Spawns closure `f` onto a Web Worker and returns a [`JoinHandle`].
        ///
        /// # Errors
        ///
        /// Returns an `io::Error` if dispatching the task to a Web Worker fails.
        pub fn spawn<F, T>(self, f: F) -> io::Result<JoinHandle<T>>
        where
            F: FnOnce() -> T + Send + 'static,
            T: Send + 'static,
        {
            let thread_name = self.name.as_deref().unwrap_or("unnamed");
            crate::map_log!(4, "[WASM_THREAD] Spawning Web Worker task '{}'", thread_name);
            let started = Arc::new(AtomicBool::new(false));
            let state = Arc::new(SharedJoinState {
                result: Mutex::new(None),
                done: AtomicBool::new(false),
                cvar: Condvar::new(),
            });

            let state_for_worker = state.clone();
            let task = Box::new(ThreadTask {
                started: started.clone(),
                func: Box::new(move || {
                    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
                    if let Ok(mut slot) = state_for_worker.result.lock() {
                        *slot = Some(res);
                    }
                    state_for_worker.done.store(true, Ordering::Release);
                    state_for_worker.cvar.notify_all();
                }),
            });
            let task_ptr = Box::into_raw(task) as usize as u32;

            if is_web_main_thread() {
                ensure_main_thread_spawner();
                if dispatch_task_to_worker(task_ptr).is_err() {
                    unsafe {
                        drop(Box::from_raw(task_ptr as *mut ThreadTask));
                    }
                    crate::map_log!(
                        1,
                        "[WASM_THREAD] Failed to dispatch Web Worker task '{}' from main thread",
                        thread_name
                    );
                    return Err(io::Error::other("failed to dispatch wasm worker task"));
                }
            } else if MAIN_SPAWNER_READY.load(Ordering::Acquire) {
                let sent = post_spawn_to_main_thread(task_ptr);
                if sent.is_err() && dispatch_task_to_worker(task_ptr).is_err() {
                    unsafe {
                        drop(Box::from_raw(task_ptr as *mut ThreadTask));
                    }
                    crate::map_log!(
                        1,
                        "[WASM_THREAD] Failed to post Web Worker spawn request '{}'",
                        thread_name
                    );
                    return Err(io::Error::other("failed to post wasm worker spawn request"));
                }
            } else if dispatch_task_to_worker(task_ptr).is_err() {
                unsafe {
                    drop(Box::from_raw(task_ptr as *mut ThreadTask));
                }
                crate::map_log!(
                    1,
                    "[WASM_THREAD] Failed to spawn nested Web Worker task '{}'",
                    thread_name
                );
                return Err(io::Error::other("failed to spawn nested wasm worker"));
            }

            Ok(JoinHandle { started, state })
        }
    }
}
