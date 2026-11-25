//! Direct `wasm32` OPFS I/O backend communicating with a dedicated pure-JS Worker
//! (`miniaudio-opfs-worker`) over `SharedArrayBuffer`, `BroadcastChannel`, and `Atomics`.

use std::cell::RefCell;
use std::io::{BufReader, Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

use flutter_rust_bridge::for_generated::js_sys::{Array, Function, Object, Reflect};
use flutter_rust_bridge::for_generated::wasm_bindgen;
use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;
use symphonia::core::io::MediaSource;

use crate::bridge::ffi::{
    MAP_ERROR_ACCESS_DENIED, MAP_ERROR_FILE_NOT_FOUND, MAP_ERROR_GENERIC,
    MAP_ERROR_INVALID_ARGS, MAP_ERROR_UNSUPPORTED,
};
use crate::sync::{lock_unpoisoned, wait_timeout_unpoisoned, MonotonicInstant};

use super::protocol::{
    pack_u64, unpack_u64, OpfsSlotShared, CTRL_ARG0_HI, CTRL_ARG0_LO, CTRL_ARG1_LEN, CTRL_ERR_LEN,
    CTRL_OP, CTRL_RES0_HI, CTRL_RES0_LO, CTRL_SEQ, CTRL_STATE, CTRL_STATUS, CTRL_VFD,
    CTRL_WAKE_RUST, OPFS_CTRL_WORDS, OPFS_ERR_CAP, OPFS_XFER_CAP, OP_CLOSE, OP_FLUSH, OP_OPEN_READ,
    OP_OPEN_WRITE, OP_READ_AT, OP_TRUNCATE, OP_WRITE_AT, STATE_DONE, STATE_ERROR, STATE_IDLE,
    STATE_PENDING,
};

/// `BroadcastChannel` name shared between WASM threads and `miniaudio-opfs-worker`.
const OPFS_CHANNEL_NAME: &str = "__miniaudio_wasm_opfs_v1__";
/// Maximum number of concurrent shared-memory OPFS RPC slots in the pool.
const MAX_OPFS_SLOTS: usize = 4;

/// Guard ensuring only one thread spawns the singleton JS OPFS Worker.
static WORKER_SPAWN_STARTED: AtomicBool = AtomicBool::new(false);
/// Readiness word notified by JS via `Atomics.notify` (`0` = booting, `1` = ready, `-1` = failed).
static WORKER_READY: AtomicI32 = AtomicI32::new(0);
/// Monotonic RPC sequence counter embedded in `CTRL_SEQ`.
static NEXT_OPFS_SEQ: AtomicU32 = AtomicU32::new(1);

thread_local! {
    /// Cached JS trampoline posting RPC payloads over `BroadcastChannel`.
    static POST_OPFS_CMD_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
    /// Cached JS trampoline invoking `Atomics.wait` on an OPFS control word.
    static ATOMICS_WAIT_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
}

/// Internal state of the reusable [`OpfsSlotPool`].
#[derive(Default)]
struct SlotPoolState {
    /// Available idle RPC slots ready for immediate lease.
    idle: Vec<Box<OpfsSlotShared>>,
    /// Total number of slots allocated so far (bounded by `MAX_OPFS_SLOTS`).
    created: usize,
}

/// Bounded pool of pinned [`OpfsSlotShared`] RPC slots shared across WASM worker threads.
struct OpfsSlotPool {
    /// Mutex-protected pool inventory.
    state: Mutex<SlotPoolState>,
    /// Condition variable signaled when an [`OpfsSlotLease`] returns its slot to `idle`.
    cvar: Condvar,
}

/// Global singleton [`OpfsSlotPool`] instance.
static OPFS_SLOT_POOL: OnceLock<OpfsSlotPool> = OnceLock::new();

/// Returns the global [`OpfsSlotPool`] singleton, initializing it on first access.
fn slot_pool() -> &'static OpfsSlotPool {
    OPFS_SLOT_POOL.get_or_init(|| OpfsSlotPool {
        state: Mutex::new(SlotPoolState::default()),
        cvar: Condvar::new(),
    })
}

/// RAII lease granting exclusive ownership of an [`OpfsSlotShared`] slot for one RPC call.
struct OpfsSlotLease {
    /// Leased slot returned to the pool on drop.
    slot: Option<Box<OpfsSlotShared>>,
}

impl OpfsSlotLease {
    /// Acquires an [`OpfsSlotShared`] slot from [`OPFS_SLOT_POOL`], blocking if all `MAX_OPFS_SLOTS` are busy.
    fn acquire() -> Self {
        let pool = slot_pool();
        let mut guard = lock_unpoisoned(&pool.state);
        loop {
            if let Some(slot) = guard.idle.pop() {
                return Self { slot: Some(slot) };
            }
            if guard.created < MAX_OPFS_SLOTS {
                guard.created += 1;
                drop(guard);
                return Self {
                    slot: Some(Box::new(OpfsSlotShared::new())),
                };
            }
            let (next_guard, _) =
                wait_timeout_unpoisoned(&pool.cvar, guard, Duration::from_millis(25));
            guard = next_guard;
        }
    }

    /// Returns a shared reference to the leased [`OpfsSlotShared`].
    #[inline]
    fn inner(&self) -> &OpfsSlotShared {
        self.slot.as_deref().expect("OpfsSlotLease missing slot")
    }
}

impl Drop for OpfsSlotLease {
    fn drop(&mut self) {
        if let Some(slot) = self.slot.take() {
            slot.ctrl[CTRL_STATE].store(STATE_IDLE, Ordering::Release);
            let pool = slot_pool();
            let mut guard = lock_unpoisoned(&pool.state);
            guard.idle.push(slot);
            pool.cvar.notify_one();
        }
    }
}

/// Sends an OPFS command object `cmd_obj` to `miniaudio-opfs-worker` over `BroadcastChannel`.
fn post_opfs_command(cmd_obj: &Object) -> std::result::Result<(), JsValue> {
    let func = POST_OPFS_CMD_FN.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            let code = r#"
                if (!self.__miniaudioWasmOpfsCh) {
                    self.__miniaudioWasmOpfsCh = new BroadcastChannel(channelName);
                }
                self.__miniaudioWasmOpfsCh.postMessage(payload);
            "#;
            *slot = Some(Function::new_with_args("channelName, payload", code));
        }
        slot.clone().unwrap()
    });
    func.call2(
        &JsValue::NULL,
        &JsValue::from_str(OPFS_CHANNEL_NAME),
        cmd_obj,
    )?;
    Ok(())
}

/// Blocks the current worker thread on `ctrl_ptr[word_idx]` while its value equals `expected`, up to `timeout_ms`.
fn wasm_atomics_wait(ctrl_ptr: u32, word_idx: usize, expected: i32, timeout_ms: u64) {
    if !crate::sync::can_block_current_thread() {
        std::hint::spin_loop();
        return;
    }
    let func = ATOMICS_WAIT_FN.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            let code = r#"
                try {
                    var view = new Int32Array(mem.buffer, ptr, words);
                    Atomics.wait(view, idx, expected, timeoutMs);
                } catch (_) {}
            "#;
            *slot = Some(Function::new_with_args(
                "mem, ptr, words, idx, expected, timeoutMs",
                code,
            ));
        }
        slot.clone().unwrap()
    });
    let args = Array::new();
    args.push(&wasm_bindgen::memory());
    args.push(&JsValue::from_f64(ctrl_ptr as f64));
    args.push(&JsValue::from_f64(OPFS_CTRL_WORDS as f64));
    args.push(&JsValue::from_f64(word_idx as f64));
    args.push(&JsValue::from_f64(expected as f64));
    args.push(&JsValue::from_f64(timeout_ms as f64));
    let _ = func.apply(&JsValue::NULL, &args);
}

/// Inline JavaScript source executed inside the dedicated pure-JS OPFS Worker.
const OPFS_WORKER_JS: &str = r#"
'use strict';
var wasmMem = null;
var opfsCh = null;
var handles = new Map();
var nextVfd = 1;

var OPFS_XFER_CAP = 256 * 1024;
var OPFS_ERR_CAP = 2048;
var OPFS_CTRL_WORDS = 12;

var CTRL_STATE = 0;
var CTRL_OP = 1;
var CTRL_STATUS = 2;
var CTRL_VFD = 3;
var CTRL_ARG0_LO = 4;
var CTRL_ARG0_HI = 5;
var CTRL_ARG1_LEN = 6;
var CTRL_RES0_LO = 7;
var CTRL_RES0_HI = 8;
var CTRL_ERR_LEN = 9;
var CTRL_WAKE_RUST = 10;

var STATE_DONE = 2;
var STATE_ERROR = 3;

var OP_OPEN_READ = 1;
var OP_READ_AT = 2;
var OP_OPEN_WRITE = 3;
var OP_WRITE_AT = 4;
var OP_TRUNCATE = 5;
var OP_FLUSH = 6;
var OP_CLOSE = 7;

var scratch = new Uint8Array(OPFS_XFER_CAP);
var textDecoder = new TextDecoder();
var textEncoder = new TextEncoder();

function getCtrl(ptr) {
    return new Int32Array(wasmMem.buffer, ptr, OPFS_CTRL_WORDS);
}
function getBuf(ptr, len) {
    return new Uint8Array(wasmMem.buffer, ptr, len);
}
function readU64(c) {
    var lo = Atomics.load(c, CTRL_ARG0_LO) >>> 0;
    var hi = Atomics.load(c, CTRL_ARG0_HI) >>> 0;
    return lo + hi * 4294967296;
}
function storeResU64(c, val) {
    var safe = val > 0 ? val : 0;
    var lo = (safe >>> 0) | 0;
    var hi = (Math.floor(safe / 4294967296) >>> 0) | 0;
    Atomics.store(c, CTRL_RES0_LO, lo);
    Atomics.store(c, CTRL_RES0_HI, hi);
}
function wakeRustDone(ctrlPtr, vfd, resU64) {
    var c = getCtrl(ctrlPtr);
    Atomics.store(c, CTRL_VFD, vfd | 0);
    storeResU64(c, resU64);
    Atomics.store(c, CTRL_STATUS, 0);
    Atomics.store(c, CTRL_ERR_LEN, 0);
    Atomics.store(c, CTRL_STATE, STATE_DONE);
    Atomics.store(c, CTRL_WAKE_RUST, 1);
    Atomics.notify(c, CTRL_WAKE_RUST);
}
function mapOpfsErrorCode(err) {
    if (err && typeof err.mapCode === 'number') {
        return err.mapCode;
    }
    var name = err && err.name ? String(err.name) : '';
    var msg = err && err.message ? String(err.message) : String(err || 'OPFS error');
    var lower = (name + ' ' + msg).toLowerCase();
    if (name === 'NotFoundError' || lower.indexOf('notfounderror') !== -1) {
        return -5; // MAP_ERROR_FILE_NOT_FOUND
    }
    if (name === 'NotAllowedError') {
        return -11; // MAP_ERROR_ACCESS_DENIED
    }
    if (name === 'NoModificationAllowedError' || lower.indexOf('nomodificationallowederror') !== -1) {
        return -12; // MAP_ERROR_BUSY
    }
    if (name === 'TypeMismatchError' || lower.indexOf('invalidname') !== -1) {
        return -2; // MAP_ERROR_INVALID_ARGS
    }
    if (
        name === 'SecurityError' ||
        name === 'NotSupportedError' ||
        lower.indexOf('getdirectory') !== -1
    ) {
        return -10; // MAP_ERROR_UNSUPPORTED
    }
    return -1; // MAP_ERROR_GENERIC
}
function wakeRustError(ctrlPtr, errPtr, code, err) {
    var msg = (err && err.message) ? String(err.message) : String(err || 'OPFS error');
    var encoded = textEncoder.encode(msg);
    var copyLen = Math.min(encoded.byteLength, OPFS_ERR_CAP);
    if (copyLen > 0) {
        getBuf(errPtr, copyLen).set(encoded.subarray(0, copyLen));
    }
    var c = getCtrl(ctrlPtr);
    Atomics.store(c, CTRL_ERR_LEN, copyLen);
    Atomics.store(c, CTRL_STATUS, code | 0);
    Atomics.store(c, CTRL_STATE, STATE_ERROR);
    Atomics.store(c, CTRL_WAKE_RUST, 1);
    Atomics.notify(c, CTRL_WAKE_RUST);
}
async function resolveOpfsFileHandle(canonicalPath, create) {
    if (!navigator.storage || typeof navigator.storage.getDirectory !== 'function') {
        var u = new Error('Origin Private File System (navigator.storage.getDirectory) is unsupported in this browser or context.');
        u.mapCode = -10;
        throw u;
    }
    var segments = String(canonicalPath).split('/').filter(Boolean);
    if (segments.length === 0) {
        var iv = new Error('OPFS path cannot be empty.');
        iv.mapCode = -2;
        throw iv;
    }
    var dir = await navigator.storage.getDirectory();
    for (var i = 0; i < segments.length - 1; i++) {
        dir = await dir.getDirectoryHandle(segments[i], { create: create });
    }
    return await dir.getFileHandle(segments[segments.length - 1], { create: create });
}
async function processOp(d) {
    var c0 = getCtrl(d.ctrlPtr);
    var op = Atomics.load(c0, CTRL_OP);
    var vfd = Atomics.load(c0, CTRL_VFD) >>> 0;
    var argLen = Atomics.load(c0, CTRL_ARG1_LEN) >>> 0;
    var offset = readU64(c0);

    try {
        if (op === OP_OPEN_READ) {
            var pathLen = Math.min(argLen, OPFS_XFER_CAP);
            if (pathLen > 0) {
                scratch.set(getBuf(d.dataPtr, pathLen), 0);
            }
            var canonicalPath = textDecoder.decode(scratch.subarray(0, pathLen));
            var fh = await resolveOpfsFileHandle(canonicalPath, false);
            var file = await fh.getFile();
            var newVfd = nextVfd++;
            handles.set(newVfd, { kind: 'read', file: file });
            wakeRustDone(d.ctrlPtr, newVfd, file.size);
            return;
        }

        if (op === OP_READ_AT) {
            var rEntry = handles.get(vfd);
            if (!rEntry || rEntry.kind !== 'read') {
                var re = new Error('Invalid OPFS read descriptor ' + vfd);
                re.mapCode = -2;
                throw re;
            }
            var toRead = Math.min(argLen, OPFS_XFER_CAP);
            if (toRead === 0 || offset >= rEntry.file.size) {
                wakeRustDone(d.ctrlPtr, vfd, 0);
                return;
            }
            var end = Math.min(rEntry.file.size, offset + toRead);
            var ab = await rEntry.file.slice(offset, end).arrayBuffer();
            var bytes = new Uint8Array(ab);
            var copied = Math.min(bytes.byteLength, toRead);
            if (copied > 0) {
                getBuf(d.dataPtr, copied).set(bytes.subarray(0, copied));
            }
            wakeRustDone(d.ctrlPtr, vfd, copied);
            return;
        }

        if (op === OP_OPEN_WRITE) {
            var wPathLen = Math.min(argLen, OPFS_XFER_CAP);
            if (wPathLen > 0) {
                scratch.set(getBuf(d.dataPtr, wPathLen), 0);
            }
            var wCanonical = textDecoder.decode(scratch.subarray(0, wPathLen));
            var wfh = await resolveOpfsFileHandle(wCanonical, true);
            var ah = null;
            var writable = null;
            if (typeof wfh.createSyncAccessHandle === 'function') {
                ah = await wfh.createSyncAccessHandle();
                ah.truncate(0);
            } else if (typeof wfh.createWritable === 'function') {
                writable = await wfh.createWritable({ keepExistingData: false });
            } else {
                var wu = new Error('OPFS file writing APIs are unsupported in this browser.');
                wu.mapCode = -10;
                throw wu;
            }
            var wVfd = nextVfd++;
            handles.set(wVfd, { kind: 'write', ah: ah, writable: writable, length: 0 });
            wakeRustDone(d.ctrlPtr, wVfd, 0);
            return;
        }

        if (op === OP_WRITE_AT) {
            var wEntry = handles.get(vfd);
            if (!wEntry || wEntry.kind !== 'write') {
                var we = new Error('Invalid OPFS write descriptor ' + vfd);
                we.mapCode = -2;
                throw we;
            }
            var toWrite = Math.min(argLen, OPFS_XFER_CAP);
            if (toWrite === 0) {
                wakeRustDone(d.ctrlPtr, vfd, 0);
                return;
            }
            if (wEntry.ah) {
                scratch.set(getBuf(d.dataPtr, toWrite), 0);
                var written = wEntry.ah.write(scratch.subarray(0, toWrite), { at: offset });
                if (offset + written > wEntry.length) {
                    wEntry.length = offset + written;
                }
                wakeRustDone(d.ctrlPtr, vfd, written);
                return;
            }
            var asyncCopy = new Uint8Array(toWrite);
            asyncCopy.set(getBuf(d.dataPtr, toWrite));
            await wEntry.writable.seek(offset);
            await wEntry.writable.write(asyncCopy);
            if (offset + toWrite > wEntry.length) {
                wEntry.length = offset + toWrite;
            }
            wakeRustDone(d.ctrlPtr, vfd, toWrite);
            return;
        }

        if (op === OP_TRUNCATE) {
            var tEntry = handles.get(vfd);
            if (!tEntry || tEntry.kind !== 'write') {
                var te = new Error('Invalid OPFS write descriptor ' + vfd);
                te.mapCode = -2;
                throw te;
            }
            if (tEntry.ah) {
                tEntry.ah.truncate(offset);
            } else if (tEntry.writable) {
                await tEntry.writable.truncate(offset);
            }
            tEntry.length = offset;
            wakeRustDone(d.ctrlPtr, vfd, offset);
            return;
        }

        if (op === OP_FLUSH) {
            var fEntry = handles.get(vfd);
            if (fEntry && fEntry.kind === 'write' && fEntry.ah) {
                fEntry.ah.flush();
            }
            wakeRustDone(d.ctrlPtr, vfd, 0);
            return;
        }

        if (op === OP_CLOSE) {
            var cEntry = handles.get(vfd);
            handles.delete(vfd);
            if (cEntry) {
                if (cEntry.ah) {
                    try { cEntry.ah.flush(); } finally { cEntry.ah.close(); }
                } else if (cEntry.writable) {
                    await cEntry.writable.close();
                }
            }
            wakeRustDone(d.ctrlPtr, vfd, 0);
            return;
        }

        var unknown = new Error('Unknown OPFS opcode ' + op);
        unknown.mapCode = -2;
        throw unknown;
    } catch (err) {
        wakeRustError(d.ctrlPtr, d.errPtr, mapOpfsErrorCode(err), err);
    }
}

onmessage = function(ev) {
    var d = ev.data;
    if (!d || !d.mem || opfsCh) return;
    wasmMem = d.mem;
    opfsCh = new BroadcastChannel(d.channel);
    opfsCh.onmessage = function(cev) {
        var cmd = cev.data;
        if (!cmd || !wasmMem) return;
        if (cmd.cmd === 'close_async') {
            var v = cmd.vfd >>> 0;
            var ent = handles.get(v);
            handles.delete(v);
            if (ent) {
                try {
                    if (ent.ah) {
                        try { ent.ah.flush(); } finally { ent.ah.close(); }
                    } else if (ent.writable) {
                        ent.writable.close();
                    }
                } catch (_) {}
            }
            return;
        }
        processOp(cmd);
    };
    var rArr = new Int32Array(wasmMem.buffer, d.readyPtr, 1);
    Atomics.store(rArr, 0, 1);
    Atomics.notify(rArr, 0);
};
"#;

/// Fires an asynchronous best-effort close notification for `vfd` when `Drop` runs on a non-blocking thread.
fn post_opfs_close_async(vfd: u32) {
    if vfd == 0 {
        return;
    }
    let cmd = Object::new();
    let _ = Reflect::set(&cmd, &JsValue::from_str("cmd"), &JsValue::from_str("close_async"));
    let _ = Reflect::set(&cmd, &JsValue::from_str("vfd"), &JsValue::from_f64(vfd as f64));
    let _ = post_opfs_command(&cmd);
}

/// Eagerly boots the singleton pure-JS OPFS Worker from the browser main thread.
pub fn ensure_opfs_worker() {
    if WORKER_READY.load(Ordering::Acquire) == 1 {
        return;
    }
    if WORKER_SPAWN_STARTED
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }

    let boot = Function::new_with_args(
        "workerCode, mem, readyPtr, channelName",
        r#"
            try {
                var blob = new Blob([workerCode], { type: 'text/javascript' });
                var url = URL.createObjectURL(blob);
                var w = new Worker(url);
                URL.revokeObjectURL(url);
                self.__miniaudioOpfsWorker = w;
                w.postMessage({ mem: mem, readyPtr: readyPtr, channel: channelName });
                return true;
            } catch (_) {
                return false;
            }
        "#,
    );

    let args = Array::new();
    args.push(&JsValue::from_str(OPFS_WORKER_JS));
    args.push(&wasm_bindgen::memory());
    args.push(&JsValue::from_f64(
        ((&WORKER_READY) as *const AtomicI32 as usize) as f64,
    ));
    args.push(&JsValue::from_str(OPFS_CHANNEL_NAME));

    crate::map_log!(3, "[OPFS] Spawning pure-JS OPFS Worker");
    let spawned_ok = boot
        .apply(&JsValue::NULL, &args)
        .ok()
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if !spawned_ok {
        crate::map_log!(1, "[OPFS] Failed to spawn pure-JS OPFS Worker");
        WORKER_READY.store(-1, Ordering::Release);
    }
}

/// Ensures the calling thread can block and waits up to 5 seconds for `miniaudio-opfs-worker` readiness.
fn ensure_opfs_worker_ready() -> std::result::Result<(), (i32, String)> {
    if !crate::sync::can_block_current_thread() {
        crate::map_log!(
            1,
            "[OPFS] Synchronous OPFS op rejected on browser main thread"
        );
        return Err((
            MAP_ERROR_UNSUPPORTED,
            "Synchronous OPFS operations cannot run on the browser main thread because Atomics.wait is prohibited (code: -10)".to_string(),
        ));
    }
    ensure_opfs_worker();
    let ready_ptr = (&WORKER_READY) as *const AtomicI32 as usize as u32;
    let deadline = MonotonicInstant::now();
    loop {
        match WORKER_READY.load(Ordering::Acquire) {
            1 => return Ok(()),
            -1 => {
                crate::map_log!(1, "[OPFS] OPFS worker unavailable");
                return Err((
                    MAP_ERROR_UNSUPPORTED,
                    "WASM OPFS worker unavailable in this browser context (code: -10)".to_string(),
                ));
            }
            _ => {
                if deadline.elapsed() >= Duration::from_secs(5) {
                    crate::map_log!(1, "[OPFS] Timed out booting OPFS worker");
                    return Err((
                        MAP_ERROR_UNSUPPORTED,
                        "Timed out booting WASM OPFS worker (code: -10)".to_string(),
                    ));
                }
                wasm_atomics_wait(ready_ptr, 0, 0, 25);
            }
        }
    }
}

/// Converts a `MAP_ERROR_*` `code` and error `msg` into a `std::io::Error` with an appropriate `ErrorKind`.
fn opfs_error_to_io(code: i32, msg: String) -> IoError {
    let kind = match code {
        MAP_ERROR_FILE_NOT_FOUND => ErrorKind::NotFound,
        MAP_ERROR_ACCESS_DENIED => ErrorKind::PermissionDenied,
        MAP_ERROR_INVALID_ARGS => ErrorKind::InvalidInput,
        MAP_ERROR_UNSUPPORTED => ErrorKind::Unsupported,
        _ => ErrorKind::Other,
    };
    let formatted = if msg.contains("(code:") {
        msg
    } else {
        format!("{} (code: {})", msg, code)
    };
    IoError::new(kind, formatted)
}

/// Successful RPC reply payload returned by [`run_opfs_rpc`].
struct OpfsRpcReply {
    /// Virtual file descriptor returned or operated on by the JS OPFS worker.
    vfd: u32,
    /// 64-bit unsigned result (file size, byte count, or truncated length).
    res_u64: u64,
}

/// Executes a synchronous shared-memory OPFS RPC (`op`, `vfd`, `arg0_u64`, `arg1_len`, `payload`)
/// and invokes `on_done_copy` with `(slot, res_u64 as usize)` before releasing the slot lease.
fn run_opfs_rpc<F>(
    op: i32,
    vfd: u32,
    arg0_u64: u64,
    arg1_len: usize,
    payload: &[u8],
    on_done_copy: F,
) -> std::result::Result<OpfsRpcReply, (i32, String)>
where
    F: FnOnce(&OpfsSlotShared, usize),
{
    ensure_opfs_worker_ready()?;
    if payload.len() > OPFS_XFER_CAP {
        crate::map_log!(
            1,
            "[OPFS] RPC payload ({} bytes) exceeds {} byte cap",
            payload.len(),
            OPFS_XFER_CAP
        );
        return Err((
            MAP_ERROR_INVALID_ARGS,
            format!(
                "OPFS RPC payload ({} bytes) exceeds {} byte slot cap (code: -2)",
                payload.len(),
                OPFS_XFER_CAP
            ),
        ));
    }

    let lease = OpfsSlotLease::acquire();
    let slot = lease.inner();

    if !payload.is_empty() {
        // Safety: this slot lease owns `data_buf` exclusively until `STATE_PENDING` is stored.
        unsafe {
            let dst = slot.data_buf.as_ptr() as *mut u8;
            std::ptr::copy_nonoverlapping(payload.as_ptr(), dst, payload.len());
        }
    }

    let (arg0_lo, arg0_hi) = pack_u64(arg0_u64);
    let seq = NEXT_OPFS_SEQ.fetch_add(1, Ordering::Relaxed) as i32;
    slot.ctrl[CTRL_OP].store(op, Ordering::Relaxed);
    slot.ctrl[CTRL_STATUS].store(0, Ordering::Relaxed);
    slot.ctrl[CTRL_VFD].store(vfd as i32, Ordering::Relaxed);
    slot.ctrl[CTRL_ARG0_LO].store(arg0_lo, Ordering::Relaxed);
    slot.ctrl[CTRL_ARG0_HI].store(arg0_hi, Ordering::Relaxed);
    slot.ctrl[CTRL_ARG1_LEN].store(arg1_len as i32, Ordering::Relaxed);
    slot.ctrl[CTRL_RES0_LO].store(0, Ordering::Relaxed);
    slot.ctrl[CTRL_RES0_HI].store(0, Ordering::Relaxed);
    slot.ctrl[CTRL_ERR_LEN].store(0, Ordering::Relaxed);
    slot.ctrl[CTRL_SEQ].store(seq, Ordering::Relaxed);
    slot.ctrl[CTRL_WAKE_RUST].store(0, Ordering::Release);
    slot.ctrl[CTRL_STATE].store(STATE_PENDING, Ordering::Release);

    let cmd = Object::new();
    let _ = Reflect::set(&cmd, &JsValue::from_str("cmd"), &JsValue::from_str("op"));
    let _ = Reflect::set(
        &cmd,
        &JsValue::from_str("ctrlPtr"),
        &JsValue::from_f64(slot.ctrl_ptr() as f64),
    );
    let _ = Reflect::set(
        &cmd,
        &JsValue::from_str("dataPtr"),
        &JsValue::from_f64(slot.data_ptr() as f64),
    );
    let _ = Reflect::set(
        &cmd,
        &JsValue::from_str("errPtr"),
        &JsValue::from_f64(slot.err_ptr() as f64),
    );
    if let Err(e) = post_opfs_command(&cmd) {
        crate::map_log!(
            1,
            "[OPFS] Failed to post OPFS command op={} vfd={}: {:?}",
            op,
            vfd,
            e
        );
        return Err((
            MAP_ERROR_GENERIC,
            format!("Failed to post OPFS command: {:?} (code: -1)", e),
        ));
    }

    loop {
        let state = slot.ctrl[CTRL_STATE].load(Ordering::Acquire);
        if state == STATE_DONE {
            let out_vfd = slot.ctrl[CTRL_VFD].load(Ordering::Acquire) as u32;
            let lo = slot.ctrl[CTRL_RES0_LO].load(Ordering::Acquire);
            let hi = slot.ctrl[CTRL_RES0_HI].load(Ordering::Acquire);
            let res_u64 = unpack_u64(lo, hi);
            on_done_copy(slot, res_u64 as usize);
            return Ok(OpfsRpcReply {
                vfd: out_vfd,
                res_u64,
            });
        }
        if state == STATE_ERROR {
            let code = slot.ctrl[CTRL_STATUS].load(Ordering::Acquire);
            let err_len = (slot.ctrl[CTRL_ERR_LEN].load(Ordering::Acquire) as usize).min(OPFS_ERR_CAP);
            let msg = if err_len > 0 {
                let mut raw = vec![0u8; err_len];
                unsafe {
                    let src = slot.err_buf.as_ptr() as *const u8;
                    std::ptr::copy_nonoverlapping(src, raw.as_mut_ptr(), err_len);
                }
                String::from_utf8_lossy(&raw).into_owned()
            } else {
                format!("OPFS operation failed (code: {})", code)
            };
            crate::map_log!(
                1,
                "[OPFS] RPC op={} vfd={} failed (code={}): {}",
                op,
                vfd,
                code,
                msg
            );
            return Err((code, format!("{} (code: {})", msg, code)));
        }
        wasm_atomics_wait(slot.ctrl_ptr(), CTRL_WAKE_RUST, 0, 50);
    }
}

/// Low-level random-access reader over a Virtual FD in `miniaudio-opfs-worker`.
pub struct OpfsRawReader {
    /// Virtual file descriptor assigned by `miniaudio-opfs-worker`.
    vfd: u32,
    /// Total file size in bytes captured on open.
    size: u64,
    /// Current read cursor offset in bytes.
    pos: u64,
}

impl OpfsRawReader {
    /// Opens an existing OPFS file at `canonical_path` for random-access reading.
    ///
    /// # Errors
    /// Returns `(MAP_ERROR_*, message)` if the worker is unavailable or the file cannot be opened.
    pub fn open(canonical_path: &str) -> std::result::Result<Self, (i32, String)> {
        let bytes = canonical_path.as_bytes();
        let reply = run_opfs_rpc(OP_OPEN_READ, 0, 0, bytes.len(), bytes, |_, _| {})?;
        crate::map_log!(
            4,
            "[OPFS] Opened read handle path='{}' vfd={} size={}",
            canonical_path,
            reply.vfd,
            reply.res_u64
        );
        Ok(Self {
            vfd: reply.vfd,
            size: reply.res_u64,
            pos: 0,
        })
    }

    /// Returns the total byte length of the opened OPFS file.
    #[inline]
    pub fn byte_len(&self) -> u64 {
        self.size
    }
}

impl Drop for OpfsRawReader {
    fn drop(&mut self) {
        if self.vfd != 0 {
            let vfd = self.vfd;
            self.vfd = 0;
            if crate::sync::can_block_current_thread() {
                let _ = run_opfs_rpc(OP_CLOSE, vfd, 0, 0, &[], |_, _| {});
            } else {
                post_opfs_close_async(vfd);
            }
        }
    }
}

impl Read for OpfsRawReader {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        if buf.is_empty() || self.pos >= self.size {
            return Ok(0);
        }
        let max_req = buf
            .len()
            .min(OPFS_XFER_CAP)
            .min((self.size - self.pos).min(usize::MAX as u64) as usize);
        if max_req == 0 {
            return Ok(0);
        }
        let mut read_count = 0usize;
        let reply = run_opfs_rpc(OP_READ_AT, self.vfd, self.pos, max_req, &[], |slot, got| {
            let n = got.min(max_req);
            if n > 0 {
                unsafe {
                    let src = slot.data_buf.as_ptr() as *const u8;
                    std::ptr::copy_nonoverlapping(src, buf.as_mut_ptr(), n);
                }
            }
            read_count = n;
        })
        .map_err(|(code, msg)| opfs_error_to_io(code, msg))?;
        let actual = (reply.res_u64 as usize).min(read_count);
        self.pos = self.pos.saturating_add(actual as u64);
        Ok(actual)
    }
}

impl Seek for OpfsRawReader {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let target: i128 = match pos {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(delta) => (self.size as i128).saturating_add(delta as i128),
            SeekFrom::Current(delta) => (self.pos as i128).saturating_add(delta as i128),
        };
        if target < 0 {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "Invalid seek before start of OPFS file",
            ));
        }
        self.pos = target as u64;
        Ok(self.pos)
    }
}

/// Seekable $O(1)$-RAM OPFS media source backed by a 128 KiB `BufReader`.
pub struct OpfsByteSource {
    /// Buffered wrapper around [`OpfsRawReader`].
    reader: BufReader<OpfsRawReader>,
    /// Cached total length of the file in bytes.
    size: u64,
    /// Current logical read position in bytes.
    pos: u64,
}

impl OpfsByteSource {
    /// Read buffer capacity in bytes (128 KiB, matching `FileByteSource`).
    pub const BUFFER_CAPACITY: usize = 128 * 1024;

    /// Opens an OPFS file at `canonical_path` wrapped in a 128 KiB [`BufReader`].
    ///
    /// # Errors
    /// Returns `(MAP_ERROR_*, message)` if opening the underlying [`OpfsRawReader`] fails.
    pub fn open(canonical_path: &str) -> std::result::Result<Self, (i32, String)> {
        let raw = OpfsRawReader::open(canonical_path)?;
        let size = raw.byte_len();
        Ok(Self {
            reader: BufReader::with_capacity(Self::BUFFER_CAPACITY, raw),
            size,
            pos: 0,
        })
    }
}

impl Read for OpfsByteSource {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        let remaining = self.size.saturating_sub(self.pos);
        if remaining == 0 {
            return Ok(0);
        }
        let max_read = buf.len().min(remaining as usize);
        let n = self.reader.read(&mut buf[..max_read])?;
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for OpfsByteSource {
    #[inline]
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let target_rel: i128 = match pos {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(delta) => (self.size as i128).saturating_add(delta as i128),
            SeekFrom::Current(delta) => (self.pos as i128).saturating_add(delta as i128),
        };
        if target_rel < 0 {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "Invalid seek before start of OPFS source",
            ));
        }
        let target_u64 = target_rel as u64;
        if target_u64 == self.pos {
            return Ok(target_u64);
        }
        let delta = target_rel - (self.pos as i128);
        if let Ok(rel_i64) = i64::try_from(delta) {
            self.reader.seek_relative(rel_i64)?;
        } else {
            self.reader.seek(SeekFrom::Start(target_u64))?;
        }
        self.pos = target_u64;
        Ok(self.pos)
    }
}

impl MediaSource for OpfsByteSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        true
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        Some(self.size)
    }
}

/// Random-access OPFS writer used by `LiveRecorder` and `AudioStreamWriter` across 11 formats.
pub struct OpfsFileWriter {
    /// Virtual file descriptor assigned by `miniaudio-opfs-worker`.
    vfd: u32,
    /// Current write cursor offset in bytes.
    pos: u64,
    /// Highest byte offset written or truncated so far.
    length: u64,
    /// Whether this writer has already been closed.
    closed: bool,
}

impl OpfsFileWriter {
    /// Opens or creates/truncates an OPFS file at `canonical_path` for random-access writing.
    ///
    /// # Errors
    /// Returns a formatted I/O error string if the worker is unavailable or opening the handle fails.
    pub fn open(canonical_path: &str) -> std::result::Result<Self, String> {
        let bytes = canonical_path.as_bytes();
        let reply = run_opfs_rpc(OP_OPEN_WRITE, 0, 0, bytes.len(), bytes, |_, _| {})
            .map_err(|(code, msg)| opfs_error_to_io(code, msg).to_string())?;
        crate::map_log!(
            3,
            "[OPFS] Opened write handle path='{}' vfd={}",
            canonical_path,
            reply.vfd
        );
        Ok(Self {
            vfd: reply.vfd,
            pos: 0,
            length: 0,
            closed: false,
        })
    }

    /// Truncates or extends the open OPFS file to `len` bytes.
    ///
    /// # Errors
    /// Returns an `std::io::Error` if the `OP_TRUNCATE` RPC fails.
    pub fn truncate(&mut self, len: u64) -> IoResult<()> {
        crate::map_log!(4, "[OPFS] Truncate vfd={} len={}", self.vfd, len);
        run_opfs_rpc(OP_TRUNCATE, self.vfd, len, 0, &[], |_, _| {})
            .map_err(|(code, msg)| opfs_error_to_io(code, msg))?;
        self.length = len;
        if self.pos > len {
            self.pos = len;
        }
        Ok(())
    }

    /// Flushes and closes the underlying OPFS write handle cleanly, propagating any error.
    ///
    /// # Errors
    /// Returns an `std::io::Error` if the `OP_CLOSE` RPC fails.
    pub fn finish_and_close(mut self) -> IoResult<()> {
        if self.closed || self.vfd == 0 {
            return Ok(());
        }
        self.closed = true;
        let vfd = self.vfd;
        self.vfd = 0;
        crate::map_log!(
            3,
            "[OPFS] Closing write handle vfd={} length={}",
            vfd,
            self.length
        );
        run_opfs_rpc(OP_CLOSE, vfd, 0, 0, &[], |_, _| {})
            .map(|_| ())
            .map_err(|(code, msg)| opfs_error_to_io(code, msg))
    }
}

impl Drop for OpfsFileWriter {
    fn drop(&mut self) {
        if !self.closed && self.vfd != 0 {
            self.closed = true;
            let vfd = self.vfd;
            self.vfd = 0;
            if crate::sync::can_block_current_thread() {
                let _ = run_opfs_rpc(OP_CLOSE, vfd, 0, 0, &[], |_, _| {});
            } else {
                post_opfs_close_async(vfd);
            }
        }
    }
}

impl Write for OpfsFileWriter {
    fn write(&mut self, buf: &[u8]) -> IoResult<usize> {
        if self.closed {
            return Err(IoError::new(ErrorKind::BrokenPipe, "OPFS writer is closed"));
        }
        if buf.is_empty() {
            return Ok(0);
        }
        let chunk = &buf[..buf.len().min(OPFS_XFER_CAP)];
        let reply = run_opfs_rpc(OP_WRITE_AT, self.vfd, self.pos, chunk.len(), chunk, |_, _| {})
            .map_err(|(code, msg)| opfs_error_to_io(code, msg))?;
        let written = (reply.res_u64 as usize).min(chunk.len());
        self.pos = self.pos.saturating_add(written as u64);
        self.length = self.length.max(self.pos);
        Ok(written)
    }

    fn flush(&mut self) -> IoResult<()> {
        if self.closed {
            return Ok(());
        }
        run_opfs_rpc(OP_FLUSH, self.vfd, 0, 0, &[], |_, _| {})
            .map(|_| ())
            .map_err(|(code, msg)| opfs_error_to_io(code, msg))
    }
}

impl Seek for OpfsFileWriter {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        let target: i128 = match pos {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(delta) => (self.length as i128).saturating_add(delta as i128),
            SeekFrom::Current(delta) => (self.pos as i128).saturating_add(delta as i128),
        };
        if target < 0 {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "Invalid seek before start of OPFS recording file",
            ));
        }
        self.pos = target as u64;
        Ok(self.pos)
    }
}

/// Reads an OPFS file at `canonical_path` (up to `max_bytes`) completely for small manifests like `.m3u8` playlists.
///
/// # Errors
/// Returns `(MAP_ERROR_*, message)` if opening or reading the OPFS file fails.
pub fn opfs_read_all_bytes(
    canonical_path: &str,
    max_bytes: usize,
) -> std::result::Result<Vec<u8>, (i32, String)> {
    let mut reader = OpfsRawReader::open(canonical_path)?;
    let target_len = (reader.byte_len().min(max_bytes as u64)) as usize;
    let mut out = vec![0u8; target_len];
    let mut read_total = 0usize;
    while read_total < target_len {
        match reader.read(&mut out[read_total..]) {
            Ok(0) => break,
            Ok(n) => read_total += n,
            Err(e) => {
                crate::map_log!(1, "[OPFS] Read error on '{}': {}", canonical_path, e);
                return Err((MAP_ERROR_GENERIC, e.to_string()));
            }
        }
    }
    out.truncate(read_total);
    crate::map_log!(
        4,
        "[OPFS] Read {} bytes from '{}'",
        read_total,
        canonical_path
    );
    Ok(out)
}

/// Reads an entire OPFS segment at `canonical_path` or bounded `EXT-X-BYTERANGE` slice `byte_range` (`(length, offset)`).
pub fn opfs_read_range(
    canonical_path: &str,
    byte_range: Option<(u64, u64)>,
) -> Option<Vec<u8>> {
    let mut reader = match OpfsRawReader::open(canonical_path) {
        Ok(r) => r,
        Err((code, msg)) => {
            crate::map_log!(
                2,
                "[OPFS] opfs_read_range open failed for '{}' (code={}): {}",
                canonical_path,
                code,
                msg
            );
            return None;
        }
    };
    let size = reader.byte_len();
    let (start, target_len) = match byte_range {
        Some((length, offset)) => {
            if offset >= size {
                crate::map_log!(
                    2,
                    "[OPFS] opfs_read_range offset {} >= size {} for '{}'",
                    offset,
                    size,
                    canonical_path
                );
                return None;
            }
            let avail = size - offset;
            (offset, avail.min(length).min(64 * 1024 * 1024) as usize)
        }
        None => (0, size.min(64 * 1024 * 1024) as usize),
    };
    if start > 0 {
        if let Err(e) = reader.seek(SeekFrom::Start(start)) {
            crate::map_log!(
                2,
                "[OPFS] opfs_read_range seek failed for '{}' offset={}: {}",
                canonical_path,
                start,
                e
            );
            return None;
        }
    }
    let mut out = vec![0u8; target_len];
    let mut got = 0usize;
    while got < target_len {
        match reader.read(&mut out[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) => {
                crate::map_log!(
                    1,
                    "[OPFS] opfs_read_range read error on '{}': {}",
                    canonical_path,
                    e
                );
                return None;
            }
        }
    }
    out.truncate(got);
    Some(out)
}
