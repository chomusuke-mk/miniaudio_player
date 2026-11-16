//! Drop-in `ureq` compatibility shim for `wasm32-unknown-unknown` backed by a
//! dedicated pure-JS Network Worker running `fetch()` + `ReadableStream` into
//! per-stream `SharedArrayBuffer`-backed SPSC rings in WASM linear memory.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::io::{Error as IoError, ErrorKind, Read, Result as IoResult};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use flutter_rust_bridge::for_generated::js_sys::{Array, Function, Object, Reflect};
use flutter_rust_bridge::for_generated::wasm_bindgen;
use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;

use super::wasm_ureq_protocol::{
    advance_ring_pos, decode_header_wire_bytes, ring_available, WasmStreamShared, CTRL_ABORTED,
    CTRL_HDR_LEN, CTRL_JS_EXITED, CTRL_JS_WAIT_FALLBACK, CTRL_READ_POS, CTRL_STATE, CTRL_STATUS,
    CTRL_WAKE_JS, CTRL_WAKE_RUST, CTRL_WORDS, CTRL_WRITE_POS, HDR_CAP, RING_CAP, STATE_CONNECTING,
    STATE_EOF, STATE_ERROR,
};
use crate::sync::{lock_unpoisoned, MonotonicInstant};

const NET_CHANNEL_NAME: &str = "__miniaudio_wasm_net_v1__";

static WORKER_SPAWN_STARTED: AtomicBool = AtomicBool::new(false);
static WORKER_READY: AtomicI32 = AtomicI32::new(0);
static NEXT_STREAM_ID: AtomicU32 = AtomicU32::new(1);
static ACTIVE_STREAMS: OnceLock<Mutex<HashMap<u32, Arc<WasmStreamShared>>>> = OnceLock::new();

thread_local! {
    static POST_NET_CMD_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
    static ATOMICS_WAIT_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
    static ATOMICS_NOTIFY_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
}

fn streams_registry() -> &'static Mutex<HashMap<u32, Arc<WasmStreamShared>>> {
    ACTIVE_STREAMS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn reap_exited_streams() {
    if let Ok(mut map) = streams_registry().try_lock() {
        map.retain(|_, shared| {
            Arc::strong_count(shared) > 1
                || shared.ctrl[CTRL_JS_EXITED].load(Ordering::Acquire) == 0
        });
    }
}

fn post_net_command(cmd_obj: &Object) -> std::result::Result<(), JsValue> {
    let func = POST_NET_CMD_FN.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            let code = r#"
                if (!self.__miniaudioWasmNetCh) {
                    self.__miniaudioWasmNetCh = new BroadcastChannel(channelName);
                }
                self.__miniaudioWasmNetCh.postMessage(payload);
            "#;
            *slot = Some(Function::new_with_args("channelName, payload", code));
        }
        slot.clone().unwrap()
    });
    func.call2(
        &JsValue::NULL,
        &JsValue::from_str(NET_CHANNEL_NAME),
        cmd_obj,
    )?;
    Ok(())
}

fn wasm_atomics_notify(ctrl_ptr: u32, word_idx: usize) {
    let func = ATOMICS_NOTIFY_FN.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            let code = r#"
                try {
                    var view = new Int32Array(mem.buffer, ptr, words);
                    Atomics.notify(view, idx);
                } catch (_) {}
            "#;
            *slot = Some(Function::new_with_args("mem, ptr, words, idx", code));
        }
        slot.clone().unwrap()
    });
    let _ = func.call4(
        &JsValue::NULL,
        &wasm_bindgen::memory(),
        &JsValue::from_f64(ctrl_ptr as f64),
        &JsValue::from_f64(CTRL_WORDS as f64),
        &JsValue::from_f64(word_idx as f64),
    );
}

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
    args.push(&JsValue::from_f64(CTRL_WORDS as f64));
    args.push(&JsValue::from_f64(word_idx as f64));
    args.push(&JsValue::from_f64(expected as f64));
    args.push(&JsValue::from_f64(timeout_ms as f64));
    let _ = func.apply(&JsValue::NULL, &args);
}

const NETWORK_WORKER_JS: &str = r#"
'use strict';
var wasmMem = null;
var netCh = null;
var streams = new Map();

var STATE_HEADERS_READY = 1;
var STATE_EOF = 2;
var STATE_ERROR = 3;

var CTRL_STATE = 0;
var CTRL_STATUS = 1;
var CTRL_WRITE_POS = 2;
var CTRL_READ_POS = 3;
var CTRL_WAKE_RUST = 4;
var CTRL_WAKE_JS = 5;
var CTRL_ABORTED = 6;
var CTRL_HDR_LEN = 7;
var CTRL_JS_EXITED = 8;
var CTRL_JS_WAIT_FALLBACK = 9;
var CTRL_WORDS = 10;

var FORBIDDEN = {
    'user-agent': true,
    'host': true,
    'content-length': true,
    'connection': true,
    'keep-alive': true,
    'accept-encoding': true,
    'origin': true,
    'referer': true,
    'icy-metadata': true
};

function getCtrl(ptr) {
    return new Int32Array(wasmMem.buffer, ptr, CTRL_WORDS);
}
function getBuf(ptr, len) {
    return new Uint8Array(wasmMem.buffer, ptr, len);
}
function wakeRust(ctrlPtr) {
    var c = getCtrl(ctrlPtr);
    Atomics.add(c, CTRL_WAKE_RUST, 1);
    Atomics.notify(c, CTRL_WAKE_RUST);
}
function writeResponseHeaders(res, ctrlPtr, hdrPtr, hdrCap) {
    var enc = new TextEncoder();
    var buf = getBuf(hdrPtr, hdrCap);
    var off = 0;
    res.headers.forEach(function(v, k) {
        var cleanK = String(k).toLowerCase().replace(/[\r\n\0]/g, '');
        var cleanV = String(v).replace(/[\r\n\0]/g, ' ');
        var b = enc.encode(cleanK + '\0' + cleanV + '\n');
        if (off + b.byteLength <= hdrCap) {
            buf.set(b, off);
            off += b.byteLength;
        }
    });
    Atomics.store(getCtrl(ctrlPtr), CTRL_HDR_LEN, off);
}
function buildFetchHeaders(hdrPairs, includeRange) {
    var h = new Headers();
    if (hdrPairs && hdrPairs.length) {
        for (var i = 0; i < hdrPairs.length; i++) {
            var k = String(hdrPairs[i][0] || '');
            var low = k.toLowerCase();
            if (FORBIDDEN[low]) continue;
            if (!includeRange && low === 'range') continue;
            try { h.append(k, String(hdrPairs[i][1] || '')); } catch (_) {}
        }
    }
    return h;
}
async function fetchWithRangeFallback(url, hdrPairs, ac) {
    var hasRange = false;
    if (hdrPairs && hdrPairs.length) {
        for (var i = 0; i < hdrPairs.length; i++) {
            if (String(hdrPairs[i][0] || '').toLowerCase() === 'range') {
                hasRange = true;
                break;
            }
        }
    }
    var useRangeAttempts = (hasRange && url.indexOf('blob:') !== 0 && url.indexOf('data:') !== 0)
        ? [true, false]
        : [false];
    var lastErr = null;
    for (var a = 0; a < useRangeAttempts.length; a++) {
        try {
            var res = await fetch(url, {
                headers: buildFetchHeaders(hdrPairs, useRangeAttempts[a]),
                signal: ac.signal
            });
            if (res.status === 0) continue;
            return { ok: true, res: res };
        } catch (err) {
            if (ac.signal.aborted) throw err;
            lastErr = err;
        }
    }
    return { ok: false, res: null, error: lastErr };
}
async function waitRingSpace(entry) {
    var ctrlPtr = entry.ctrlPtr;
    var cap = entry.ringCap;
    var mod = cap * 2;
    while (true) {
        var c = getCtrl(ctrlPtr);
        if (entry.aborted || Atomics.load(c, CTRL_ABORTED) !== 0) return -1;
        var w = Atomics.load(c, CTRL_WRITE_POS);
        var r = Atomics.load(c, CTRL_READ_POS);
        var avail = (w + mod - r) % mod;
        var free = cap - avail;
        if (free > 0) return free;

        var seq = Atomics.load(c, CTRL_WAKE_JS);
        if (typeof Atomics.waitAsync === 'function') {
            var waitRes = Atomics.waitAsync(c, CTRL_WAKE_JS, seq, 50);
            if (waitRes && waitRes.async) {
                await waitRes.value;
            }
        } else {
            Atomics.store(c, CTRL_JS_WAIT_FALLBACK, 1);
            await new Promise(function(resolve) {
                entry.drainResolve = resolve;
                setTimeout(function() {
                    if (entry.drainResolve === resolve) {
                        entry.drainResolve = null;
                        resolve();
                    }
                }, 25);
            });
        }
    }
}
async function pumpStream(d) {
    var ac = new AbortController();
    var entry = {
        id: d.id,
        ctrlPtr: d.ctrlPtr,
        ringCap: d.ringCap,
        ac: ac,
        aborted: false,
        drainResolve: null
    };
    streams.set(d.id, entry);
    var reader = null;
    try {
        if (Atomics.load(getCtrl(d.ctrlPtr), CTRL_ABORTED) !== 0) {
            return;
        }
        var url = d.url || '';
        if (!url) {
            var cEmpty = getCtrl(d.ctrlPtr);
            Atomics.store(cEmpty, CTRL_STATUS, -2);
            Atomics.store(cEmpty, CTRL_STATE, STATE_ERROR);
            wakeRust(d.ctrlPtr);
            return;
        }
        var attempt = await fetchWithRangeFallback(url, d.headers, ac);
        var chosenRes = attempt.ok ? attempt.res : null;
        if (!chosenRes) {
            var cFail = getCtrl(d.ctrlPtr);
            Atomics.store(cFail, CTRL_STATUS, -5);
            Atomics.store(cFail, CTRL_STATE, STATE_ERROR);
            wakeRust(d.ctrlPtr);
            return;
        }

        writeResponseHeaders(chosenRes, d.ctrlPtr, d.hdrPtr, d.hdrCap);
        var cHdr = getCtrl(d.ctrlPtr);
        Atomics.store(cHdr, CTRL_STATUS, chosenRes.status);

        if (chosenRes.status >= 400 || !chosenRes.body) {
            if (chosenRes.body) { try { chosenRes.body.cancel(); } catch (_) {} }
            Atomics.store(cHdr, CTRL_STATE, STATE_EOF);
            wakeRust(d.ctrlPtr);
            return;
        }

        Atomics.store(cHdr, CTRL_STATE, STATE_HEADERS_READY);
        wakeRust(d.ctrlPtr);

        reader = chosenRes.body.getReader();
        var cap = d.ringCap;
        var mod = cap * 2;
        while (true) {
            if (entry.aborted || Atomics.load(getCtrl(d.ctrlPtr), CTRL_ABORTED) !== 0) break;
            var chunkRes = await reader.read();
            if (chunkRes.done) {
                Atomics.store(getCtrl(d.ctrlPtr), CTRL_STATE, STATE_EOF);
                wakeRust(d.ctrlPtr);
                break;
            }
            var chunk = chunkRes.value;
            if (!chunk || chunk.byteLength === 0) continue;
            var off = 0;
            while (off < chunk.byteLength) {
                var free = await waitRingSpace(entry);
                if (free <= 0) {
                    off = chunk.byteLength;
                    break;
                }
                var n = Math.min(free, chunk.byteLength - off);
                var cW = getCtrl(d.ctrlPtr);
                var ring = getBuf(d.ringPtr, cap);
                var w = Atomics.load(cW, CTRL_WRITE_POS);
                var wRing = w % cap;
                var first = Math.min(n, cap - wRing);
                ring.set(chunk.subarray(off, off + first), wRing);
                if (n > first) {
                    ring.set(chunk.subarray(off + first, off + n), 0);
                }
                Atomics.store(cW, CTRL_WRITE_POS, (w + n) % mod);
                wakeRust(d.ctrlPtr);
                off += n;
            }
        }
    } catch (_) {
        var cErr = getCtrl(d.ctrlPtr);
        if (Atomics.load(cErr, CTRL_STATE) < STATE_EOF) {
            if (!entry.aborted && Atomics.load(cErr, CTRL_ABORTED) === 0) {
                Atomics.store(cErr, CTRL_STATUS, -5);
                Atomics.store(cErr, CTRL_STATE, STATE_ERROR);
            } else {
                Atomics.store(cErr, CTRL_STATE, STATE_EOF);
            }
            wakeRust(d.ctrlPtr);
        }
    } finally {
        if (reader) {
            try { await reader.cancel(); } catch (_) {}
        }
        streams.delete(d.id);
        var cEnd = getCtrl(d.ctrlPtr);
        Atomics.store(cEnd, CTRL_JS_EXITED, 1);
        Atomics.notify(cEnd, CTRL_JS_EXITED);
        wakeRust(d.ctrlPtr);
    }
}
function handleCommand(ev) {
    var d = ev.data;
    if (!d || !wasmMem) return;
    if (d.cmd === 'open') {
        pumpStream(d);
    } else if (d.cmd === 'abort') {
        var eAbort = streams.get(d.id);
        if (eAbort) {
            eAbort.aborted = true;
            try { eAbort.ac.abort(); } catch (_) {}
            if (eAbort.drainResolve) {
                var rA = eAbort.drainResolve;
                eAbort.drainResolve = null;
                rA();
            }
        }
    } else if (d.cmd === 'drain') {
        var eDrain = streams.get(d.id);
        if (eDrain && eDrain.drainResolve) {
            var rD = eDrain.drainResolve;
            eDrain.drainResolve = null;
            rD();
        }
    }
}
onmessage = function(ev) {
    var d = ev.data;
    if (!d || !d.mem || netCh) return;
    wasmMem = d.mem;
    netCh = new BroadcastChannel(d.channel);
    netCh.onmessage = handleCommand;
    var rArr = new Int32Array(wasmMem.buffer, d.readyPtr, 1);
    Atomics.store(rArr, 0, 1);
    Atomics.notify(rArr, 0);
};
"#;

/// Eagerly boots the singleton pure-JS Network Worker (`fetch` + `ReadableStream` pump).
pub fn ensure_network_worker() {
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
                self.__miniaudioNetWorker = w;
                w.postMessage({ mem: mem, readyPtr: readyPtr, channel: channelName });
                return true;
            } catch (_) {
                return false;
            }
        "#,
    );

    let args = Array::new();
    args.push(&JsValue::from_str(NETWORK_WORKER_JS));
    args.push(&wasm_bindgen::memory());
    args.push(&JsValue::from_f64(
        ((&WORKER_READY) as *const AtomicI32 as usize) as f64,
    ));
    args.push(&JsValue::from_str(NET_CHANNEL_NAME));

    let spawned_ok = boot
        .apply(&JsValue::NULL, &args)
        .ok()
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    if !spawned_ok {
        WORKER_READY.store(-1, Ordering::Release);
    }
}

fn ensure_network_worker_ready() -> Result<(), Error> {
    ensure_network_worker();
    let ready_ptr = (&WORKER_READY) as *const AtomicI32 as usize as u32;
    let deadline = MonotonicInstant::now();
    loop {
        match WORKER_READY.load(Ordering::Acquire) {
            1 => return Ok(()),
            -1 => {
                return Err(Error::Transport(
                    "wasm network worker unavailable".to_string(),
                ))
            }
            _ => {
                if deadline.elapsed() >= Duration::from_secs(5) {
                    return Err(Error::Transport(
                        "timed out booting wasm network worker".to_string(),
                    ));
                }
                wasm_atomics_wait(ready_ptr, 0, 0, 25);
            }
        }
    }
}

fn post_stream_cmd(cmd: &str, id: u32) {
    let obj = Object::new();
    let _ = Reflect::set(&obj, &JsValue::from_str("cmd"), &JsValue::from_str(cmd));
    let _ = Reflect::set(&obj, &JsValue::from_str("id"), &JsValue::from_f64(id as f64));
    let _ = post_net_command(&obj);
}

fn abort_shared_stream(shared: &WasmStreamShared) {
    let was_aborted = shared.ctrl[CTRL_ABORTED].swap(1, Ordering::AcqRel);
    let state = shared.ctrl[CTRL_STATE].load(Ordering::Acquire);
    if was_aborted == 0 && state < STATE_EOF {
        shared.ctrl[CTRL_WAKE_JS].fetch_add(1, Ordering::AcqRel);
        shared.ctrl[CTRL_WAKE_RUST].fetch_add(1, Ordering::AcqRel);
        wasm_atomics_notify(shared.ctrl_ptr(), CTRL_WAKE_JS);
        wasm_atomics_notify(shared.ctrl_ptr(), CTRL_WAKE_RUST);
        post_stream_cmd("abort", shared.id);
    }
}

// =========================================================================
// Public `ureq`-Compatible Surface
// =========================================================================

pub mod typestate {
    /// Request builder typestate matching `ureq::typestate::WithoutBody`.
    pub struct WithoutBody;
}

pub mod http {
    /// HTTP status code wrapper compatible with `ureq::http::StatusCode`.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct StatusCode(pub(super) u16);

    impl StatusCode {
        #[inline]
        pub fn as_u16(self) -> u16 {
            self.0
        }
    }

    /// Error returned by `HeaderValue::to_str`.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct ToStrError;

    impl std::fmt::Display for ToStrError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("invalid header value")
        }
    }

    impl std::error::Error for ToStrError {}

    /// HTTP header value wrapper compatible with `ureq::http::HeaderValue`.
    #[derive(Debug, Clone)]
    pub struct HeaderValue(pub(super) String);

    impl HeaderValue {
        #[inline]
        pub fn to_str(&self) -> Result<&str, ToStrError> {
            Ok(&self.0)
        }
    }

    /// Case-insensitive response header map.
    #[derive(Debug, Clone, Default)]
    pub struct HeaderMap(pub(super) Vec<(String, HeaderValue)>);

    impl HeaderMap {
        #[inline]
        pub fn get(&self, name: &str) -> Option<&HeaderValue> {
            self.0
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v)
        }
    }

    /// HTTP response wrapper compatible with `ureq::http::Response<B>`.
    pub struct Response<B> {
        pub(super) status: StatusCode,
        pub(super) headers: HeaderMap,
        pub(super) body: B,
    }

    impl<B> Response<B> {
        #[inline]
        pub fn status(&self) -> StatusCode {
            self.status
        }

        #[inline]
        pub fn headers(&self) -> &HeaderMap {
            &self.headers
        }

        #[inline]
        pub fn into_body(self) -> B {
            self.body
        }
    }
}

/// Transport or HTTP status error matching `ureq::Error`.
#[derive(Debug, Clone)]
pub enum Error {
    StatusCode(u16),
    Transport(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::StatusCode(code) => write!(f, "HTTP status {}", code),
            Self::Transport(msg) => write!(f, "HTTP transport error: {}", msg),
        }
    }
}

impl std::error::Error for Error {}

/// Agent configuration matching `ureq::Agent`.
#[derive(Clone, Debug)]
pub struct AgentConfig {
    connect_timeout: Duration,
    recv_timeout: Duration,
    per_read_timeout: Duration,
}

#[derive(Clone, Debug)]
pub struct AgentConfigBuilder {
    connect_timeout: Duration,
    recv_timeout: Duration,
    per_read_timeout: Duration,
}

impl AgentConfigBuilder {
    pub fn user_agent(self, _ua: &str) -> Self {
        self
    }

    pub fn timeout_connect(mut self, timeout: Option<Duration>) -> Self {
        self.connect_timeout = timeout.unwrap_or_else(|| Duration::from_secs(10));
        self
    }

    pub fn timeout_recv_response(mut self, timeout: Option<Duration>) -> Self {
        self.recv_timeout = timeout.unwrap_or_else(|| Duration::from_secs(15));
        self
    }

    pub fn timeout_per_read(mut self, timeout: Option<Duration>) -> Self {
        self.per_read_timeout = timeout.unwrap_or_else(|| Duration::from_secs(15));
        self
    }

    pub fn max_idle_connections(self, _max: usize) -> Self {
        self
    }

    pub fn build(self) -> AgentConfig {
        AgentConfig {
            connect_timeout: self.connect_timeout,
            recv_timeout: self.recv_timeout,
            per_read_timeout: self.per_read_timeout,
        }
    }
}

impl From<AgentConfig> for Agent {
    fn from(cfg: AgentConfig) -> Self {
        Self { cfg }
    }
}

/// Cross-thread cloneable `ureq::Agent` equivalent for `wasm32`.
#[derive(Clone, Debug)]
pub struct Agent {
    cfg: AgentConfig,
}

impl Agent {
    pub fn config_builder() -> AgentConfigBuilder {
        AgentConfigBuilder {
            connect_timeout: Duration::from_secs(5),
            recv_timeout: Duration::from_secs(15),
            per_read_timeout: Duration::from_secs(15),
        }
    }

    pub fn get(&self, url: &str) -> RequestBuilder<typestate::WithoutBody> {
        RequestBuilder {
            cfg: self.cfg.clone(),
            url: url.to_string(),
            headers: Vec::new(),
            _state: std::marker::PhantomData,
        }
    }
}

/// Request builder matching `ureq::RequestBuilder<WithoutBody>`.
pub struct RequestBuilder<S> {
    cfg: AgentConfig,
    url: String,
    headers: Vec<(String, String)>,
    _state: std::marker::PhantomData<S>,
}

impl<S> RequestBuilder<S> {
    pub fn header<K: AsRef<str>, V: AsRef<str>>(mut self, key: K, value: V) -> Self {
        self.headers
            .push((key.as_ref().to_string(), value.as_ref().to_string()));
        self
    }

    pub fn call(self) -> Result<http::Response<Body>, Error> {
        reap_exited_streams();
        ensure_network_worker_ready()?;

        let id = NEXT_STREAM_ID.fetch_add(1, Ordering::Relaxed);
        let shared = Arc::new(WasmStreamShared::new(id));
        {
            let mut reg = lock_unpoisoned(streams_registry());
            reg.insert(id, shared.clone());
        }

        let headers_arr = Array::new();
        for (k, v) in &self.headers {
            let pair = Array::new();
            pair.push(&JsValue::from_str(k));
            pair.push(&JsValue::from_str(v));
            headers_arr.push(&pair);
        }

        let cmd = Object::new();
        let fields: [(&str, JsValue); 9] = [
            ("cmd", JsValue::from_str("open")),
            ("id", JsValue::from_f64(id as f64)),
            ("url", JsValue::from_str(&self.url)),
            ("headers", headers_arr.into()),
            ("ctrlPtr", JsValue::from_f64(shared.ctrl_ptr() as f64)),
            ("ringPtr", JsValue::from_f64(shared.ring_ptr() as f64)),
            ("ringCap", JsValue::from_f64(RING_CAP as f64)),
            ("hdrPtr", JsValue::from_f64(shared.hdr_ptr() as f64)),
            ("hdrCap", JsValue::from_f64(HDR_CAP as f64)),
        ];
        for (k, v) in fields {
            if Reflect::set(&cmd, &JsValue::from_str(k), &v).is_err() {
                abort_shared_stream(&shared);
                return Err(Error::Transport("failed to build open command".to_string()));
            }
        }

        if post_net_command(&cmd).is_err() {
            abort_shared_stream(&shared);
            return Err(Error::Transport(
                "failed to post open command to wasm network worker".to_string(),
            ));
        }

        let open_timeout = self
            .cfg
            .connect_timeout
            .saturating_add(self.cfg.recv_timeout);
        let start = MonotonicInstant::now();

        loop {
            let wake_seq = shared.ctrl[CTRL_WAKE_RUST].load(Ordering::Acquire);
            let state = shared.ctrl[CTRL_STATE].load(Ordering::Acquire);
            if state != STATE_CONNECTING {
                break;
            }
            let elapsed = start.elapsed();
            if elapsed >= open_timeout {
                abort_shared_stream(&shared);
                return Err(Error::Transport(format!(
                    "connect/response timeout after {:?}",
                    open_timeout
                )));
            }
            let rem_ms = (open_timeout - elapsed).as_millis().clamp(1, 100) as u64;
            wasm_atomics_wait(shared.ctrl_ptr(), CTRL_WAKE_RUST, wake_seq, rem_ms);
        }

        let final_state = shared.ctrl[CTRL_STATE].load(Ordering::Acquire);
        let status = shared.ctrl[CTRL_STATUS].load(Ordering::Acquire);

        if final_state == STATE_ERROR || status <= 0 {
            abort_shared_stream(&shared);
            drop(shared);
            reap_exited_streams();
            return Err(Error::Transport(format!(
                "fetch failed for '{}' (code {})",
                self.url, status
            )));
        }

        if status >= 400 {
            abort_shared_stream(&shared);
            drop(shared);
            reap_exited_streams();
            return Err(Error::StatusCode(status as u16));
        }

        let hdr_len =
            (shared.ctrl[CTRL_HDR_LEN].load(Ordering::Acquire).max(0) as usize).min(HDR_CAP);
        let mut hdr_raw = vec![0u8; hdr_len];
        if hdr_len > 0 {
            // Safety: JS completed writing `hdr_buf[..hdr_len]` before Release-storing `STATE >= HEADERS_READY`,
            // and never mutates `hdr_buf` afterwards.
            unsafe {
                std::ptr::copy_nonoverlapping(
                    shared.hdr_buf.as_ptr() as *const u8,
                    hdr_raw.as_mut_ptr(),
                    hdr_len,
                );
            }
        }
        let header_pairs = decode_header_wire_bytes(&hdr_raw)
            .into_iter()
            .map(|(k, v)| (k, http::HeaderValue(v)))
            .collect();

        Ok(http::Response {
            status: http::StatusCode(status as u16),
            headers: http::HeaderMap(header_pairs),
            body: Body {
                shared: Some(shared),
                per_read_timeout: self.cfg.per_read_timeout,
            },
        })
    }
}

/// Streaming response body matching `ureq::Body`.
pub struct Body {
    shared: Option<Arc<WasmStreamShared>>,
    per_read_timeout: Duration,
}

impl Body {
    pub fn into_reader(mut self) -> WasmHttpReader {
        let shared = self
            .shared
            .take()
            .expect("Body::into_reader called on consumed body");
        WasmHttpReader {
            shared,
            per_read_timeout: self.per_read_timeout,
        }
    }
}

impl Drop for Body {
    fn drop(&mut self) {
        if let Some(shared) = self.shared.take() {
            abort_shared_stream(&shared);
            drop(shared);
            reap_exited_streams();
        }
    }
}

/// Progressive blocking `Read + Send` adapter draining a JS `ReadableStream` SPSC ring.
pub struct WasmHttpReader {
    shared: Arc<WasmStreamShared>,
    per_read_timeout: Duration,
}

impl Read for WasmHttpReader {
    fn read(&mut self, out: &mut [u8]) -> IoResult<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        let start = MonotonicInstant::now();

        loop {
            let wake_seq = self.shared.ctrl[CTRL_WAKE_RUST].load(Ordering::Acquire);
            let w = self.shared.ctrl[CTRL_WRITE_POS].load(Ordering::Acquire) as u32;
            let r = self.shared.ctrl[CTRL_READ_POS].load(Ordering::Relaxed) as u32;
            let avail = ring_available(w, r);

            if avail > 0 {
                let to_copy = avail.min(out.len());
                let r_ring = (r as usize) % RING_CAP;
                let first = to_copy.min(RING_CAP - r_ring);
                // Safety: `w` loaded with Acquire guarantees JS finished writing `[r_ring..]` slots
                // and will not overwrite unread slots until we Release-store `CTRL_READ_POS`.
                unsafe {
                    let ring_ptr = self.shared.ring.as_ptr() as *const u8;
                    std::ptr::copy_nonoverlapping(ring_ptr.add(r_ring), out.as_mut_ptr(), first);
                    if to_copy > first {
                        std::ptr::copy_nonoverlapping(
                            ring_ptr,
                            out.as_mut_ptr().add(first),
                            to_copy - first,
                        );
                    }
                }
                let next_r = advance_ring_pos(r, to_copy);
                self.shared.ctrl[CTRL_READ_POS].store(next_r as i32, Ordering::Release);

                if avail >= RING_CAP / 2 {
                    self.shared.ctrl[CTRL_WAKE_JS].fetch_add(1, Ordering::AcqRel);
                    wasm_atomics_notify(self.shared.ctrl_ptr(), CTRL_WAKE_JS);
                    if self.shared.ctrl[CTRL_JS_WAIT_FALLBACK].swap(0, Ordering::AcqRel) != 0 {
                        post_stream_cmd("drain", self.shared.id);
                    }
                }
                return Ok(to_copy);
            }

            let state = self.shared.ctrl[CTRL_STATE].load(Ordering::Acquire);
            if state == STATE_EOF {
                let w2 = self.shared.ctrl[CTRL_WRITE_POS].load(Ordering::Acquire) as u32;
                if w2 != r {
                    continue;
                }
                return Ok(0);
            }
            if state == STATE_ERROR {
                return Err(IoError::other("wasm fetch stream error"));
            }
            if self.shared.ctrl[CTRL_ABORTED].load(Ordering::Acquire) != 0 {
                return Err(IoError::new(
                    ErrorKind::ConnectionAborted,
                    "wasm fetch stream aborted",
                ));
            }

            let elapsed = start.elapsed();
            if elapsed >= self.per_read_timeout {
                return Err(IoError::new(
                    ErrorKind::TimedOut,
                    "wasm fetch stream read timeout",
                ));
            }
            let rem_ms = (self.per_read_timeout - elapsed).as_millis().clamp(1, 100) as u64;
            wasm_atomics_wait(self.shared.ctrl_ptr(), CTRL_WAKE_RUST, wake_seq, rem_ms);
        }
    }
}

impl Drop for WasmHttpReader {
    fn drop(&mut self) {
        abort_shared_stream(&self.shared);
    }
}
