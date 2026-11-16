//! Real-time lock-free synchronization and telemetry primitives.
//!
//! Provides single-producer single-consumer (SPSC) ring buffers, cache-padded seqlocks
//! for lockless reader-writer synchronization, and a zero-allocation telemetry dispatcher.

pub mod cancel;
pub mod reaper;
pub mod ring_buffer;
pub mod seqlock;
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

/// Acquires a `Mutex` guard even if a previous holder panicked (poison recovery).
#[inline]
pub fn lock_unpoisoned<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Waits on a condition variable with a timeout, recovering the guard if poisoned.
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
    Timeout,
    Disconnected,
}

struct WakeQueueInner<T> {
    items: std::collections::VecDeque<T>,
    closed: bool,
}

/// Cross-platform MPSC wakeup queue using `Condvar::wait_timeout` instead of
/// `crossbeam_channel::Receiver::recv_timeout` (whose deadline math calls
/// `std::time::Instant::now()` and panics on `wasm32`).
pub struct WakeQueue<T> {
    lock: Mutex<WakeQueueInner<T>>,
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

    /// Pushes an item and wakes one waiting consumer. Returns `false` if closed.
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
    fn default() -> Self {
        Self::new()
    }
}

/// Acquires a read lock on an `RwLock`, recovering gracefully from poisoning.
#[inline]
pub fn read_unpoisoned<T>(rw: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    rw.read().unwrap_or_else(|e| e.into_inner())
}

/// Acquires a write lock on an `RwLock`, recovering gracefully from poisoning.
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
        thread::ensure_main_thread_spawner();
        crate::net::ureq::ensure_network_worker();
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub mod thread {
    pub use std::thread::*;
}

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

    const SPAWNER_CHANNEL_NAME: &str = "__miniaudio_wasm_thread_spawner__";
    static SCRIPT_SRC: OnceLock<String> = OnceLock::new();
    static MAIN_SPAWNER_READY: AtomicBool = AtomicBool::new(false);

    thread_local! {
        static DISPATCH_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
        static SPAWNER_SETUP_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
        static POST_CHANNEL_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
    }

    #[inline]
    pub fn is_web_main_thread() -> bool {
        let global = js_sys::global();
        Reflect::has(&global, &JsValue::from_str("window")).unwrap_or(false)
            && Reflect::has(&global, &JsValue::from_str("document")).unwrap_or(false)
    }

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
        if let Ok(ok) = func.call4(
            &JsValue::NULL,
            &JsValue::from_str(SPAWNER_CHANNEL_NAME),
            &JsValue::from_str(&script_src),
            &wasm_bindgen::module(),
            &wasm_bindgen::memory(),
        ) {
            if ok.as_bool() == Some(true) {
                MAIN_SPAWNER_READY.store(true, Ordering::Release);
            }
        }
    }

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
                                    "    try { wasm_bindgen.wasm_thread_entry_point(ev.data); }\n" +
                                    "    finally { postMessage(0); }\n" +
                                    "  };\n" +
                                    "};";
                                var blob = new Blob([workerCode], { type: 'text/javascript' });
                                var url = URL.createObjectURL(blob);
                                worker = new Worker(url);
                                URL.revokeObjectURL(url);
                                worker.postMessage([wasmMod, wasmMem]);
                            }
                            worker.onmessage = function() {
                                pool.push(worker);
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

    pub struct ThreadTask {
        started: Arc<AtomicBool>,
        func: Box<dyn FnOnce() + Send + 'static>,
    }

    #[wasm_bindgen]
    pub fn wasm_thread_entry_point(task_ptr: u32) {
        if task_ptr == 0 {
            return;
        }
        let task = unsafe { Box::from_raw(task_ptr as *mut ThreadTask) };
        task.started.store(true, Ordering::Release);
        (task.func)();
    }

    struct SharedJoinState<T> {
        result: Mutex<Option<Result<T>>>,
        done: AtomicBool,
        cvar: Condvar,
    }

    pub struct JoinHandle<T> {
        started: Arc<AtomicBool>,
        state: Arc<SharedJoinState<T>>,
    }

    impl<T> JoinHandle<T> {
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

    #[derive(Default)]
    pub struct Builder {
        name: Option<String>,
    }

    impl Builder {
        pub fn new() -> Self {
            Self { name: None }
        }

        pub fn name(mut self, name: String) -> Self {
            self.name = Some(name);
            self
        }

        pub fn spawn<F, T>(self, f: F) -> io::Result<JoinHandle<T>>
        where
            F: FnOnce() -> T + Send + 'static,
            T: Send + 'static,
        {
            let _ = &self.name;
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
                    return Err(io::Error::other("failed to dispatch wasm worker task"));
                }
            } else if MAIN_SPAWNER_READY.load(Ordering::Acquire) {
                let sent = post_spawn_to_main_thread(task_ptr);
                if sent.is_err() && dispatch_task_to_worker(task_ptr).is_err() {
                    unsafe {
                        drop(Box::from_raw(task_ptr as *mut ThreadTask));
                    }
                    return Err(io::Error::other("failed to post wasm worker spawn request"));
                }
            } else if dispatch_task_to_worker(task_ptr).is_err() {
                unsafe {
                    drop(Box::from_raw(task_ptr as *mut ThreadTask));
                }
                return Err(io::Error::other("failed to spawn nested wasm worker"));
            }

            Ok(JoinHandle { started, state })
        }
    }
}
