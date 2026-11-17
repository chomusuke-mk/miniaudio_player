//! Raw FFI declarations, C callbacks, WebAudio WASM runtime bindings, and safe enumeration wrappers.

use std::os::raw::{c_char, c_void};

/// Opaque marker type representing a miniaudio audio hardware device context.
pub enum MapDeviceContextOpaque {}
/// Type alias for the opaque device context pointer.
pub type MapDeviceContext = MapDeviceContextOpaque;

/// Canonical error codes for miniaudio_player.
/// Operation completed successfully.
pub const MAP_SUCCESS: i32 = 0;
/// Invalid arguments supplied.
pub const MAP_ERROR_INVALID_ARGS: i32 = -2;
/// File or resource not found.
pub const MAP_ERROR_FILE_NOT_FOUND: i32 = -5;
/// Audio decoding failed.
pub const MAP_ERROR_DECODE_FAILED: i32 = -6;
/// Requested feature is unsupported on this platform.
pub const MAP_ERROR_UNSUPPORTED: i32 = -10;
/// Hardware access permission denied.
pub const MAP_ERROR_ACCESS_DENIED: i32 = -11;

/// Low-level audio device descriptor for C interop.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct MapDeviceInfo {
    /// Raw unique hardware device identifier bytes.
    pub id: [u8; 516],
    /// Effective device identifier bytes.
    pub effective_id: [u8; 516],
    /// Human-readable device name bytes.
    pub name: [u8; 256],
    /// Whether this device is the operating system default.
    pub is_default: i32,
    /// Whether this represents automatic default device routing.
    pub is_auto: i32,
}

/// Consolidated device collection holding both playback and capture devices in a single pass.
#[repr(C)]
pub struct MapAllDevices {
    pub playback_devices: *mut MapDeviceInfo,
    pub playback_count: u32,
    pub capture_devices: *mut MapDeviceInfo,
    pub capture_count: u32,
}

impl Default for MapAllDevices {
    fn default() -> Self {
        Self {
            playback_devices: std::ptr::null_mut(),
            playback_count: 0,
            capture_devices: std::ptr::null_mut(),
            capture_count: 0,
        }
    }
}

impl Default for MapDeviceInfo {
    fn default() -> Self {
        Self {
            id: [0; 516],
            effective_id: [0; 516],
            name: [0; 256],
            is_default: 1,
            is_auto: 1,
        }
    }
}

/// C-compatible representation of buffered playback time boundaries.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct MiniaudioBufferedRange {
    /// Start timestamp of buffered audio in milliseconds.
    pub start_ms: i64,
    /// End timestamp of buffered audio in milliseconds.
    pub end_ms: i64,
    /// Non-zero if actively waiting for buffer refill.
    pub is_buffering: i32,
}

#[cfg(not(target_arch = "wasm32"))]
extern "C" {
    pub fn map_device_create(
        sample_rate: u32,
        channels: u32,
        period_size_in_frames: u32,
        playback_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext;

    pub fn map_capture_device_create(
        sample_rate: u32,
        channels: u32,
        period_size_in_frames: u32,
        capture_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext;

    pub fn map_device_start(ctx: *mut MapDeviceContext) -> i32;
    pub fn map_device_stop(ctx: *mut MapDeviceContext) -> i32;
    pub fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32;

    pub fn map_device_enumerate_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;
    pub fn map_device_enumerate_capture_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;
    pub fn map_device_free_devices(devices: *mut MapDeviceInfo);
    pub fn map_device_enumerate_all(out_all: *mut MapAllDevices) -> i32;
    pub fn map_device_free_all(all: *mut MapAllDevices);
}

/// Target-independent lock-free Web Audio capture ring & linear resampler primitives
/// tested natively under `cargo test` and shared directly with `wasm32`.
pub mod wasm_audio_protocol {
    use std::cell::UnsafeCell;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

    /// Mono capture ring buffer capacity in samples (~341 ms at 48 kHz).
    pub const WEB_CAPTURE_CAP_SAMPLES: usize = 16384;
    pub const WEB_CAPTURE_MASK: usize = WEB_CAPTURE_CAP_SAMPLES - 1;
    pub const MAX_WEB_CAPTURE_SLOTS: usize = 8;

    /// Interleaved multi-channel linear PCM resampler shared across Web playback and capture paths.
    pub struct LinearPcmResampler<const CH: usize> {
        last_ratio_num: u32,
        last_ratio_den: u32,
        phase: f64,
        prev: [f32; CH],
        initialized: bool,
    }

    impl<const CH: usize> LinearPcmResampler<CH> {
        pub const fn new() -> Self {
            Self {
                last_ratio_num: 44100,
                last_ratio_den: 44100,
                phase: 0.0,
                prev: [0.0; CH],
                initialized: false,
            }
        }

        pub fn process(&mut self, input: &[f32], in_sr: u32, out_sr: u32, out: &mut Vec<f32>) {
            out.clear();
            let in_frames = input.len() / CH;
            if in_frames == 0 {
                return;
            }
            if in_sr == out_sr || in_sr == 0 || out_sr == 0 {
                out.extend_from_slice(&input[..in_frames * CH]);
                let last_base = (in_frames - 1) * CH;
                self.prev.copy_from_slice(&input[last_base..last_base + CH]);
                self.phase = 0.0;
                self.initialized = true;
                return;
            }
            if self.last_ratio_num != in_sr || self.last_ratio_den != out_sr {
                self.last_ratio_num = in_sr;
                self.last_ratio_den = out_sr;
                self.phase = 0.0;
            }
            if !self.initialized {
                self.prev.copy_from_slice(&input[..CH]);
                self.initialized = true;
            }

            let step = (in_sr as f64) / (out_sr as f64);
            let est_out = ((in_frames as f64 / step).ceil() as usize + 4) * CH;
            out.reserve(est_out);

            let mut pos = self.phase;
            let limit = in_frames as f64;
            while pos < limit {
                let idx = pos.floor() as isize;
                let frac = (pos - (idx as f64)) as f32;
                let cur_base = (idx.max(0) as usize).min(in_frames - 1) * CH;
                let prev_base = if idx <= 0 {
                    None
                } else {
                    Some(((idx - 1) as usize) * CH)
                };
                for c in 0..CH {
                    let s0 = match prev_base {
                        Some(b) => input[b + c],
                        None => self.prev[c],
                    };
                    let s1 = input[cur_base + c];
                    out.push(s0 + (s1 - s0) * frac);
                }
                pos += step;
            }
            self.phase = pos - limit;
            let last_base = (in_frames - 1) * CH;
            self.prev.copy_from_slice(&input[last_base..last_base + CH]);
        }
    }

    #[repr(C, align(64))]
    pub struct WasmWebCaptureControl {
        pub write_pos: AtomicU32,        // [0] Written by JS AudioWorklet/ScriptProcessor
        pub read_pos: AtomicU32,         // [1] Written by Rust capture pump
        pub host_sample_rate: AtomicU32, // [2] Browser AudioContext.sampleRate
        pub channels: AtomicU32,         // [3] 1 (mono)
        pub cap_samples: AtomicU32,      // [4] WEB_CAPTURE_CAP_SAMPLES (power of 2)
        pub active: AtomicU32,           // [5] 1 while actively capturing, 0 otherwise
        pub generation: AtomicU32,       // [6] Monotonic slot generation fence
        pub overruns: AtomicU32,         // [7] Ring overflow drops in JS worklet
    }

    #[repr(C, align(64))]
    pub struct WasmWebCaptureSlot {
        pub ctrl: WasmWebCaptureControl,
        pub data: UnsafeCell<[f32; WEB_CAPTURE_CAP_SAMPLES]>,
        pub in_use: AtomicBool,
    }

    unsafe impl Sync for WasmWebCaptureSlot {}
    unsafe impl Send for WasmWebCaptureSlot {}

    impl WasmWebCaptureSlot {
        pub fn new_boxed(default_sr: u32) -> Box<Self> {
            Box::new(Self {
                ctrl: WasmWebCaptureControl {
                    write_pos: AtomicU32::new(0),
                    read_pos: AtomicU32::new(0),
                    host_sample_rate: AtomicU32::new(default_sr.clamp(8000, 192000)),
                    channels: AtomicU32::new(1),
                    cap_samples: AtomicU32::new(WEB_CAPTURE_CAP_SAMPLES as u32),
                    active: AtomicU32::new(0),
                    generation: AtomicU32::new(0),
                    overruns: AtomicU32::new(0),
                },
                data: UnsafeCell::new([0.0f32; WEB_CAPTURE_CAP_SAMPLES]),
                in_use: AtomicBool::new(false),
            })
        }

        pub fn reset_for_generation(&self, generation: u32, default_sr: u32) {
            self.ctrl.active.store(0, Ordering::Release);
            self.ctrl.generation.store(generation, Ordering::Release);
            self.ctrl.write_pos.store(0, Ordering::Release);
            self.ctrl.read_pos.store(0, Ordering::Release);
            self.ctrl
                .host_sample_rate
                .store(default_sr.clamp(8000, 192000), Ordering::Release);
            self.ctrl.overruns.store(0, Ordering::Release);
        }

        pub fn push_mono(&self, generation: u32, mono: &[f32]) {
            if mono.is_empty()
                || self.ctrl.active.load(Ordering::Acquire) == 0
                || self.ctrl.generation.load(Ordering::Acquire) != generation
            {
                return;
            }
            let r = self.ctrl.read_pos.load(Ordering::Acquire);
            let w = self.ctrl.write_pos.load(Ordering::Relaxed);
            let used = (w.wrapping_sub(r) as usize).min(WEB_CAPTURE_CAP_SAMPLES);
            let free = WEB_CAPTURE_CAP_SAMPLES - used;
            let to_write = mono.len().min(free);
            if to_write == 0 {
                self.ctrl.overruns.fetch_add(1, Ordering::Relaxed);
                return;
            }
            let start = (w as usize) & WEB_CAPTURE_MASK;
            let first = to_write.min(WEB_CAPTURE_CAP_SAMPLES - start);
            let second = to_write - first;
            unsafe {
                let dst = (*self.data.get()).as_mut_ptr();
                std::ptr::copy_nonoverlapping(mono.as_ptr(), dst.add(start), first);
                if second > 0 {
                    std::ptr::copy_nonoverlapping(mono.as_ptr().add(first), dst, second);
                }
            }
            self.ctrl
                .write_pos
                .store(w.wrapping_add(to_write as u32), Ordering::Release);
        }

        pub fn pop_mono_all(&self, out: &mut Vec<f32>) {
            out.clear();
            let w = self.ctrl.write_pos.load(Ordering::Acquire);
            let r = self.ctrl.read_pos.load(Ordering::Relaxed);
            let avail = (w.wrapping_sub(r) as usize).min(WEB_CAPTURE_CAP_SAMPLES);
            if avail == 0 {
                return;
            }
            out.resize(avail, 0.0);
            let start = (r as usize) & WEB_CAPTURE_MASK;
            let first = avail.min(WEB_CAPTURE_CAP_SAMPLES - start);
            let second = avail - first;
            unsafe {
                let src = (*self.data.get()).as_ptr();
                std::ptr::copy_nonoverlapping(src.add(start), out.as_mut_ptr(), first);
                if second > 0 {
                    std::ptr::copy_nonoverlapping(src, out.as_mut_ptr().add(first), second);
                }
            }
            self.ctrl
                .read_pos
                .store(r.wrapping_add(avail as u32), Ordering::Release);
        }
    }
}

#[cfg(target_arch = "wasm32")]
mod wasm_device_bridge {
    use super::wasm_audio_protocol::*;
    use super::*;
    use flutter_rust_bridge::for_generated::js_sys::{
        self, Array, Float32Array, Function, Object, Reflect,
    };
    use flutter_rust_bridge::for_generated::wasm_bindgen;
    use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;
    use std::cell::UnsafeCell;
    use std::ffi::CStr;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};

    /// Power-of-two ring capacity in stereo frames (~371 ms at 44.1 kHz).
    pub const WEB_RING_CAP_FRAMES: usize = 16384;
    pub const WEB_RING_CHANNELS: usize = 2;
    pub const WEB_RING_CAP_SAMPLES: usize = WEB_RING_CAP_FRAMES * WEB_RING_CHANNELS;
    const WEB_RING_MASK: usize = WEB_RING_CAP_SAMPLES - 1;
    /// Target ahead-of-consumer buffer depth (~93 ms at 44.1 kHz) to absorb Web Worker jitter.
    pub const WEB_RING_TARGET_CUSHION_FRAMES: u32 = 4096;
    /// Max pre-unlock silence retained while AudioContext is suspended.
    const PRE_UNLOCK_SILENCE_CAP_FRAMES: usize = 512;

    /// Shared-memory lock-free control block mirrored as `Int32Array(buf, ctrlPtr, 8)` in JS.
    #[repr(C, align(64))]
    pub struct WasmWebAudioControl {
        write_pos: AtomicU32,       // [0] Producer cursor (samples, wraps mod 2^32)
        read_pos: AtomicU32,        // [1] Consumer cursor (samples, wraps mod 2^32)
        sample_rate: AtomicU32,     // [2] Host AudioContext sample rate
        channels: AtomicU32,        // [3] Always 2 (stereo)
        cap_samples: AtomicU32,     // [4] WEB_RING_CAP_SAMPLES (power of 2)
        underruns: AtomicU32,       // [5] Consumer underrun counter during active playback
        frames_consumed: AtomicU32, // [6] Consumer render-quantum heartbeat counter
        playing_hint: AtomicU32,    // [7] 1 while non-silent audio is actively flowing
    }

    /// Static lock-free SPSC ring buffer inside shared WASM linear memory, read directly
    /// off the main UI thread by the `AudioWorklet` audio rendering thread.
    #[repr(C, align(64))]
    pub struct WasmWebAudioRing {
        ctrl: WasmWebAudioControl,
        data: UnsafeCell<[f32; WEB_RING_CAP_SAMPLES]>,
    }

    unsafe impl Sync for WasmWebAudioRing {}
    unsafe impl Send for WasmWebAudioRing {}

    static WEB_AUDIO_RING: OnceLock<Box<WasmWebAudioRing>> = OnceLock::new();
    static HOST_AUDIO_SAMPLE_RATE: AtomicU32 = AtomicU32::new(44100);

    fn web_audio_ring() -> &'static WasmWebAudioRing {
        WEB_AUDIO_RING.get_or_init(|| {
            Box::new(WasmWebAudioRing {
                ctrl: WasmWebAudioControl {
                    write_pos: AtomicU32::new(0),
                    read_pos: AtomicU32::new(0),
                    sample_rate: AtomicU32::new(HOST_AUDIO_SAMPLE_RATE.load(Ordering::Relaxed)),
                    channels: AtomicU32::new(WEB_RING_CHANNELS as u32),
                    cap_samples: AtomicU32::new(WEB_RING_CAP_SAMPLES as u32),
                    underruns: AtomicU32::new(0),
                    frames_consumed: AtomicU32::new(0),
                    playing_hint: AtomicU32::new(0),
                },
                data: UnsafeCell::new([0.0f32; WEB_RING_CAP_SAMPLES]),
            })
        })
    }

    impl WasmWebAudioRing {
        #[inline]
        fn queued_samples(&self) -> usize {
            let w = self.ctrl.write_pos.load(Ordering::Acquire);
            let r = self.ctrl.read_pos.load(Ordering::Acquire);
            (w.wrapping_sub(r) as usize).min(WEB_RING_CAP_SAMPLES)
        }

        #[inline]
        fn push_stereo(&self, stereo: &[f32]) -> usize {
            if stereo.is_empty() {
                return 0;
            }
            let r = self.ctrl.read_pos.load(Ordering::Acquire);
            let w = self.ctrl.write_pos.load(Ordering::Relaxed);
            let used = (w.wrapping_sub(r) as usize).min(WEB_RING_CAP_SAMPLES);
            let free = WEB_RING_CAP_SAMPLES - used;
            // Keep sample writes stereo-frame aligned.
            let to_write = ((stereo.len().min(free)) / WEB_RING_CHANNELS) * WEB_RING_CHANNELS;
            if to_write == 0 {
                return 0;
            }

            let start = (w as usize) & WEB_RING_MASK;
            let first = to_write.min(WEB_RING_CAP_SAMPLES - start);
            let second = to_write - first;
            unsafe {
                let dst_base = (*self.data.get()).as_mut_ptr();
                std::ptr::copy_nonoverlapping(stereo.as_ptr(), dst_base.add(start), first);
                if second > 0 {
                    std::ptr::copy_nonoverlapping(
                        stereo.as_ptr().add(first),
                        dst_base,
                        second,
                    );
                }
            }
            self.ctrl
                .write_pos
                .store(w.wrapping_add(to_write as u32), Ordering::Release);
            to_write
        }

        #[inline]
        fn pop_stereo(&self, out: &mut [f32]) -> usize {
            let w = self.ctrl.write_pos.load(Ordering::Acquire);
            let r = self.ctrl.read_pos.load(Ordering::Relaxed);
            let avail = (w.wrapping_sub(r) as usize).min(WEB_RING_CAP_SAMPLES);
            let wanted = (out.len() / WEB_RING_CHANNELS) * WEB_RING_CHANNELS;
            let to_read = ((avail.min(wanted)) / WEB_RING_CHANNELS) * WEB_RING_CHANNELS;
            if to_read > 0 {
                let start = (r as usize) & WEB_RING_MASK;
                let first = to_read.min(WEB_RING_CAP_SAMPLES - start);
                let second = to_read - first;
                unsafe {
                    let src_base = (*self.data.get()).as_ptr();
                    std::ptr::copy_nonoverlapping(src_base.add(start), out.as_mut_ptr(), first);
                    if second > 0 {
                        std::ptr::copy_nonoverlapping(
                            src_base,
                            out.as_mut_ptr().add(first),
                            second,
                        );
                    }
                }
                self.ctrl
                    .read_pos
                    .store(r.wrapping_add(to_read as u32), Ordering::Release);
            }
            self.ctrl.frames_consumed.fetch_add(1, Ordering::Relaxed);
            if to_read < out.len() {
                if self.ctrl.playing_hint.load(Ordering::Relaxed) != 0 {
                    self.ctrl.underruns.fetch_add(1, Ordering::Relaxed);
                }
                out[to_read..].fill(0.0);
            }
            to_read
        }
    }

    pub struct WasmDeviceState {
        sample_rate: u32,
        channels: u32,
        user_data_addr: usize,
        alive: AtomicBool,
        active: AtomicBool,
    }

    impl WasmDeviceState {
        #[inline]
        fn is_alive(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
        }

        #[inline]
        fn is_active(&self) -> bool {
            self.alive.load(Ordering::Relaxed) && self.active.load(Ordering::Relaxed)
        }
    }

    static DEVICES: OnceLock<Mutex<Vec<Arc<WasmDeviceState>>>> = OnceLock::new();

    fn devices_registry() -> &'static Mutex<Vec<Arc<WasmDeviceState>>> {
        DEVICES.get_or_init(|| Mutex::new(Vec::new()))
    }

    struct PumpState {
        dev_scratch: Vec<f32>,
        mix_buf: Vec<f32>,
        resampled_buf: Vec<f32>,
        fallback_buf: Vec<f32>,
        resampler: LinearPcmResampler<WEB_RING_CHANNELS>,
        activity_hangover: u32,
    }

    impl PumpState {
        const fn new() -> Self {
            Self {
                dev_scratch: Vec::new(),
                mix_buf: Vec::new(),
                resampled_buf: Vec::new(),
                fallback_buf: Vec::new(),
                resampler: LinearPcmResampler::new(),
                activity_hangover: 0,
            }
        }
    }

    // =========================================================================
    // Web Audio Capture Slot Registry & Device Cache (Shared WASM Linear Memory)
    // =========================================================================

    const WEB_CAPTURE_CHANNEL_NAME: &str = "__miniaudio_web_capture_v1__";

    static CAPTURE_SLOTS: OnceLock<Mutex<Vec<Box<WasmWebCaptureSlot>>>> = OnceLock::new();
    static NEXT_CAPTURE_GENERATION: AtomicU32 = AtomicU32::new(1);

    fn with_capture_slot<R>(slot_idx: usize, f: impl FnOnce(&WasmWebCaptureSlot) -> R) -> Option<R> {
        let slots = CAPTURE_SLOTS.get()?;
        let guard = slots.lock().ok()?;
        guard.get(slot_idx).map(|s| f(s))
    }

    fn acquire_capture_slot(default_sr: u32) -> Option<(usize, u32, u32, u32)> {
        let slots_mtx = CAPTURE_SLOTS.get_or_init(|| Mutex::new(Vec::new()));
        let mut slots = slots_mtx.lock().ok()?;
        let gen = NEXT_CAPTURE_GENERATION.fetch_add(1, Ordering::AcqRel).max(1);

        if let Some((idx, slot)) = slots
            .iter()
            .enumerate()
            .find(|(_, s)| !s.in_use.swap(true, Ordering::AcqRel))
        {
            slot.reset_for_generation(gen, default_sr);
            let ctrl_ptr = (&slot.ctrl as *const WasmWebCaptureControl) as usize as u32;
            let data_ptr = slot.data.get() as usize as u32;
            return Some((idx, gen, ctrl_ptr, data_ptr));
        }

        if slots.len() >= MAX_WEB_CAPTURE_SLOTS {
            return None;
        }

        let slot = WasmWebCaptureSlot::new_boxed(default_sr);
        slot.in_use.store(true, Ordering::Release);
        slot.reset_for_generation(gen, default_sr);
        let ctrl_ptr = (&slot.ctrl as *const WasmWebCaptureControl) as usize as u32;
        let data_ptr = slot.data.get() as usize as u32;
        let idx = slots.len();
        slots.push(slot);
        Some((idx, gen, ctrl_ptr, data_ptr))
    }

    struct WasmCapturePumpState {
        resampler: LinearPcmResampler<1>,
        scratch_in: Vec<f32>,
        scratch_resampled: Vec<f32>,
        scratch_interleaved: Vec<f32>,
    }

    impl WasmCapturePumpState {
        fn new() -> Self {
            Self {
                resampler: LinearPcmResampler::new(),
                scratch_in: Vec::new(),
                scratch_resampled: Vec::new(),
                scratch_interleaved: Vec::new(),
            }
        }
    }

    pub struct WasmCaptureState {
        slot_idx: usize,
        generation: u32,
        ctrl_ptr: u32,
        data_ptr: u32,
        sample_rate: u32,
        channels: u32,
        requested_device_id: String,
        user_data_addr: usize,
        alive: AtomicBool,
        active: AtomicBool,
        failed: AtomicBool,
        pump: Mutex<WasmCapturePumpState>,
    }

    impl WasmCaptureState {
        #[inline]
        fn is_alive(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
        }

        #[inline]
        fn is_active(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
                && self.active.load(Ordering::Relaxed)
                && !self.failed.load(Ordering::Relaxed)
        }
    }

    enum WasmDeviceHandle {
        Output(Arc<WasmDeviceState>),
        Capture(Arc<WasmCaptureState>),
    }

    static CAPTURE_DEVICES: OnceLock<Mutex<Vec<Arc<WasmCaptureState>>>> = OnceLock::new();

    fn capture_devices_registry() -> &'static Mutex<Vec<Arc<WasmCaptureState>>> {
        CAPTURE_DEVICES.get_or_init(|| Mutex::new(Vec::new()))
    }

    #[derive(Clone, PartialEq, Eq)]
    struct CachedWebDevice {
        id: String,
        name: String,
        is_default: bool,
    }

    static WEB_CAPTURE_DEVICES: OnceLock<Mutex<Vec<CachedWebDevice>>> = OnceLock::new();
    static WEB_DEVICE_TRIGGERS: OnceLock<Mutex<Vec<Weak<(Mutex<bool>, Condvar)>>>> = OnceLock::new();
    static FAILED_CAPTURE_MESSAGES: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

    fn web_capture_devices_cache() -> &'static Mutex<Vec<CachedWebDevice>> {
        WEB_CAPTURE_DEVICES.get_or_init(|| Mutex::new(Vec::new()))
    }

    pub fn register_web_device_trigger(trigger: Arc<(Mutex<bool>, Condvar)>) {
        let triggers = WEB_DEVICE_TRIGGERS.get_or_init(|| Mutex::new(Vec::new()));
        if let Ok(mut guard) = triggers.lock() {
            guard.retain(|w| w.strong_count() > 0);
            guard.push(Arc::downgrade(&trigger));
        }
    }

    fn wake_web_device_watchers() {
        let Some(triggers) = WEB_DEVICE_TRIGGERS.get() else {
            return;
        };
        if let Ok(mut guard) = triggers.lock() {
            guard.retain(|w| {
                if let Some(arc) = w.upgrade() {
                    let (lock, cvar) = &*arc;
                    if let Ok(mut triggered) = lock.lock() {
                        *triggered = true;
                        cvar.notify_all();
                    }
                    true
                } else {
                    false
                }
            });
        }
    }

    fn post_web_capture_cmd(obj: &Object) {
        let global = js_sys::global();
        if let Ok(val) = Reflect::get(&global, &JsValue::from_str("__miniaudioWebCaptureCmd")) {
            if let Some(func) = val.dyn_ref::<Function>() {
                let _ = func.call1(&JsValue::NULL, obj);
                return;
            }
        }
        // Background Web Worker path: forward command to window main thread via BroadcastChannel.
        if let Ok(bc_ctor) = Reflect::get(&global, &JsValue::from_str("BroadcastChannel")) {
            if bc_ctor.is_function() {
                if let Ok(poster) = Function::new_with_args(
                    "channelName, msg",
                    "var ch = new BroadcastChannel(channelName); ch.postMessage(msg); ch.close();",
                )
                .call2(&JsValue::NULL, &JsValue::from_str(WEB_CAPTURE_CHANNEL_NAME), obj)
                {
                    let _ = poster;
                }
            }
        }
    }

    fn dispatch_start_capture_cmd(state: &WasmCaptureState) {
        let obj = Object::new();
        let _ = Reflect::set(&obj, &JsValue::from_str("cmd"), &JsValue::from_str("startCapture"));
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("slotIdx"),
            &JsValue::from_f64(state.slot_idx as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("generation"),
            &JsValue::from_f64(state.generation as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("deviceId"),
            &JsValue::from_str(&state.requested_device_id),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("sampleRate"),
            &JsValue::from_f64(state.sample_rate as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("channels"),
            &JsValue::from_f64(state.channels as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("ctrlPtr"),
            &JsValue::from_f64(state.ctrl_ptr as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("dataPtr"),
            &JsValue::from_f64(state.data_ptr as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("capSamples"),
            &JsValue::from_f64(WEB_CAPTURE_CAP_SAMPLES as f64),
        );
        post_web_capture_cmd(&obj);
    }

    fn dispatch_stop_capture_cmd(slot_idx: usize, generation: u32) {
        let obj = Object::new();
        let _ = Reflect::set(&obj, &JsValue::from_str("cmd"), &JsValue::from_str("stopCapture"));
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("slotIdx"),
            &JsValue::from_f64(slot_idx as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("generation"),
            &JsValue::from_f64(generation as f64),
        );
        post_web_capture_cmd(&obj);
    }

    fn copy_str_to_fixed<const N: usize>(s: &str, dst: &mut [u8; N]) {
        dst.fill(0);
        let bytes = s.as_bytes();
        let max_copy = bytes.len().min(N.saturating_sub(1));
        dst[..max_copy].copy_from_slice(&bytes[..max_copy]);
    }

    pub fn cached_capture_device_infos() -> Vec<MapDeviceInfo> {
        let Ok(guard) = web_capture_devices_cache().lock() else {
            return Vec::new();
        };
        guard
            .iter()
            .map(|d| {
                let mut info = MapDeviceInfo {
                    id: [0; 516],
                    effective_id: [0; 516],
                    name: [0; 256],
                    is_default: if d.is_default { 1 } else { 0 },
                    is_auto: 0,
                };
                copy_str_to_fixed(&d.id, &mut info.id);
                copy_str_to_fixed(&d.id, &mut info.effective_id);
                copy_str_to_fixed(&d.name, &mut info.name);
                info
            })
            .collect()
    }

    #[wasm_bindgen]
    pub fn wasm_set_web_capture_devices(ids: JsValue, names: JsValue, defaults: JsValue) {
        let ids_arr = Array::from(&ids);
        let names_arr = Array::from(&names);
        let defaults_arr = Array::from(&defaults);
        let len = ids_arr.length().min(names_arr.length()).min(defaults_arr.length());

        let mut next = Vec::with_capacity(len as usize);
        for i in 0..len {
            let id = ids_arr.get(i).as_string().unwrap_or_default();
            if id.is_empty() {
                continue;
            }
            let name = names_arr.get(i).as_string().unwrap_or_else(|| id.clone());
            let is_default = defaults_arr.get(i).as_bool().unwrap_or(false);
            next.push(CachedWebDevice {
                id,
                name,
                is_default,
            });
        }

        let changed = if let Ok(mut guard) = web_capture_devices_cache().lock() {
            if *guard != next {
                *guard = next;
                true
            } else {
                false
            }
        } else {
            false
        };

        if changed {
            wake_web_device_watchers();
        }
    }

    #[wasm_bindgen]
    pub fn wasm_set_web_capture_sample_rate(slot_idx: u32, generation: u32, sample_rate: u32) {
        let _ = with_capture_slot(slot_idx as usize, |slot| {
            if slot.ctrl.generation.load(Ordering::Acquire) == generation {
                slot.ctrl
                    .host_sample_rate
                    .store(sample_rate.clamp(8000, 192000), Ordering::Release);
            }
        });
    }

    #[wasm_bindgen]
    pub fn wasm_push_web_capture_pcm(
        slot_idx: u32,
        generation: u32,
        samples: &Float32Array,
        sample_rate: u32,
    ) {
        let mut buf = vec![0.0f32; samples.length() as usize];
        samples.copy_to(&mut buf);
        let _ = with_capture_slot(slot_idx as usize, |slot| {
            if slot.ctrl.generation.load(Ordering::Acquire) == generation {
                if sample_rate >= 8000 {
                    slot.ctrl
                        .host_sample_rate
                        .store(sample_rate.clamp(8000, 192000), Ordering::Release);
                }
                slot.push_mono(generation, &buf);
            }
        });
    }

    #[wasm_bindgen]
    pub fn wasm_notify_web_capture_failed(slot_idx: u32, generation: u32, error_message: String) {
        if let Ok(devs) = capture_devices_registry().lock() {
            for dev in devs.iter() {
                if dev.slot_idx == slot_idx as usize && dev.generation == generation {
                    dev.failed.store(true, Ordering::Release);
                    dev.active.store(false, Ordering::Release);
                    let _ = with_capture_slot(dev.slot_idx, |slot| {
                        if slot.ctrl.generation.load(Ordering::Acquire) == generation {
                            slot.ctrl.active.store(0, Ordering::Release);
                        }
                    });
                    break;
                }
            }
        }
        let msgs = FAILED_CAPTURE_MESSAGES.get_or_init(|| Mutex::new(Vec::new()));
        if let Ok(mut guard) = msgs.lock() {
            guard.push(error_message);
        }
        wake_web_device_watchers();
    }

    pub fn wasm_is_capture_device_failed(ctx: *mut MapDeviceContext) -> bool {
        if ctx.is_null() {
            return false;
        }
        unsafe {
            match &*(ctx as *const WasmDeviceHandle) {
                WasmDeviceHandle::Capture(cap) => cap.failed.load(Ordering::Acquire),
                WasmDeviceHandle::Output(_) => false,
            }
        }
    }

    pub fn wasm_has_failed_capture_devices() -> bool {
        let Ok(devs) = capture_devices_registry().try_lock() else {
            return false;
        };
        devs.iter()
            .any(|d| d.is_alive() && d.failed.load(Ordering::Acquire))
    }

    pub fn wasm_take_failed_capture_messages() -> Vec<String> {
        let Some(msgs) = FAILED_CAPTURE_MESSAGES.get() else {
            return Vec::new();
        };
        let Ok(mut guard) = msgs.lock() else {
            return Vec::new();
        };
        std::mem::take(&mut *guard)
    }

    pub fn wasm_pump_web_capture_rings() {
        let Ok(mut devs) = capture_devices_registry().try_lock() else {
            return;
        };
        devs.retain(|d| d.is_alive());
        for dev in devs.iter() {
            if !dev.is_active() || dev.user_data_addr == 0 {
                continue;
            }
            let Ok(mut pump) = dev.pump.try_lock() else {
                continue;
            };
            let pump_state = &mut *pump;
            let host_sr_opt = with_capture_slot(dev.slot_idx, |slot| {
                if slot.ctrl.generation.load(Ordering::Acquire) != dev.generation {
                    return 0;
                }
                slot.pop_mono_all(&mut pump_state.scratch_in);
                slot.ctrl.host_sample_rate.load(Ordering::Acquire)
            });
            let Some(host_sr) = host_sr_opt else {
                continue;
            };
            if host_sr == 0 || pump_state.scratch_in.is_empty() {
                continue;
            }

            let target_sr = dev.sample_rate.max(8000);
            let target_ch = dev.channels.clamp(1, 8) as usize;
            pump_state.resampler.process(
                &pump_state.scratch_in,
                host_sr,
                target_sr,
                &mut pump_state.scratch_resampled,
            );
            let out_frames = pump_state.scratch_resampled.len();
            if out_frames == 0 {
                continue;
            }

            let deliver_ptr = if target_ch == 1 {
                pump_state.scratch_resampled.as_ptr()
            } else {
                pump_state.scratch_interleaved.clear();
                pump_state.scratch_interleaved.reserve(out_frames * target_ch);
                for &s in &pump_state.scratch_resampled {
                    for _ in 0..target_ch {
                        pump_state.scratch_interleaved.push(s);
                    }
                }
                pump_state.scratch_interleaved.as_ptr()
            };

            unsafe {
                rust_capture_pcm_frames(
                    dev.user_data_addr as *mut c_void,
                    deliver_ptr,
                    out_frames as u32,
                );
            }
        }
    }

    static PUMP_STATE: OnceLock<Mutex<PumpState>> = OnceLock::new();

    fn pump_state() -> &'static Mutex<PumpState> {
        PUMP_STATE.get_or_init(|| Mutex::new(PumpState::new()))
    }

    /// Mixes available PCM from all active Web output devices into the shared SPSC Web Audio ring.
    fn pump_devices_locked(
        devs: &[Arc<WasmDeviceState>],
        st: &mut PumpState,
        consumer_active: bool,
    ) {
        const MAX_BATCH_FRAMES: usize = 2048;
        let ring = web_audio_ring();
        let host_sr = HOST_AUDIO_SAMPLE_RATE.load(Ordering::Relaxed).max(8000);
        ring.ctrl.sample_rate.store(host_sr, Ordering::Relaxed);

        loop {
            let mut max_dev_frames = 0usize;
            let mut src_sr = host_sr;
            for dev in devs {
                if !dev.is_active() || dev.user_data_addr == 0 {
                    continue;
                }
                let ch = dev.channels.clamp(1, 8) as usize;
                let avail_frames = unsafe {
                    let renderer = &*(dev.user_data_addr
                        as *const crate::core::output_manager::OutputDeviceRenderer);
                    renderer.consumer.slots() / ch
                };
                if avail_frames > max_dev_frames {
                    max_dev_frames = avail_frames;
                    src_sr = dev.sample_rate.max(8000);
                }
            }

            if max_dev_frames == 0 {
                break;
            }

            let free_ring_frames =
                (WEB_RING_CAP_SAMPLES.saturating_sub(ring.queued_samples())) / WEB_RING_CHANNELS;
            let max_src_frames = if src_sr == host_sr || src_sr == 0 || host_sr == 0 {
                free_ring_frames
            } else {
                ((free_ring_frames.saturating_sub(2) as u64 * src_sr as u64) / host_sr as u64)
                    as usize
            };
            if max_src_frames == 0 {
                break;
            }

            let batch_frames = max_dev_frames.min(MAX_BATCH_FRAMES).min(max_src_frames);
            let mix_samples = batch_frames * WEB_RING_CHANNELS;
            st.mix_buf.clear();
            st.mix_buf.resize(mix_samples, 0.0);

            for dev in devs {
                if !dev.is_active() || dev.user_data_addr == 0 {
                    continue;
                }
                let ch = dev.channels.clamp(1, 8) as usize;
                let avail_samples = unsafe {
                    let renderer = &*(dev.user_data_addr
                        as *const crate::core::output_manager::OutputDeviceRenderer);
                    renderer.consumer.slots()
                };
                let dev_frames = (avail_samples / ch).min(batch_frames);
                if dev_frames == 0 {
                    continue;
                }
                let dev_samples = dev_frames * ch;
                st.dev_scratch.clear();
                st.dev_scratch.resize(dev_samples, 0.0);
                unsafe {
                    rust_render_pcm_frames(
                        dev.user_data_addr as *mut c_void,
                        st.dev_scratch.as_mut_ptr(),
                        dev_frames as u32,
                    );
                }

                for i in 0..dev_frames {
                    let base_src = i * ch;
                    let (l, r) = if ch == 1 {
                        let s = st.dev_scratch[base_src];
                        (s, s)
                    } else {
                        (st.dev_scratch[base_src], st.dev_scratch[base_src + 1])
                    };
                    let base_dst = i * WEB_RING_CHANNELS;
                    st.mix_buf[base_dst] = (st.mix_buf[base_dst] + l).clamp(-1.0, 1.0);
                    st.mix_buf[base_dst + 1] = (st.mix_buf[base_dst + 1] + r).clamp(-1.0, 1.0);
                }
            }

            let has_signal = st.mix_buf.iter().any(|&s| s.abs() > 1e-6);
            if has_signal {
                st.activity_hangover = 20;
                ring.ctrl.playing_hint.store(1, Ordering::Relaxed);
            } else if st.activity_hangover > 0 {
                st.activity_hangover -= 1;
                if st.activity_hangover == 0 {
                    ring.ctrl.playing_hint.store(0, Ordering::Relaxed);
                }
            }

            if !consumer_active && !has_signal {
                let queued_frames = ring.queued_samples() / WEB_RING_CHANNELS;
                if queued_frames >= PRE_UNLOCK_SILENCE_CAP_FRAMES {
                    // Drain redundant pre-unlock silence so unlocking AudioContext has minimal latency.
                    continue;
                }
            }

            if src_sr != host_sr {
                st.resampler
                    .process(&st.mix_buf, src_sr, host_sr, &mut st.resampled_buf);
                let _ = ring.push_stereo(&st.resampled_buf);
            } else {
                let _ = ring.push_stereo(&st.mix_buf);
            }
        }
    }

    /// Pumps all active Web output devices into the shared SPSC `WasmWebAudioRing`.
    /// Called from the dedicated `map-engine-clock` Web Worker thread.
    pub fn wasm_pump_web_audio_ring(consumer_active: bool) {
        let Ok(mut devs_guard) = devices_registry().lock() else {
            return;
        };
        devs_guard.retain(|d| d.is_alive());
        let Ok(mut st) = pump_state().lock() else {
            return;
        };
        pump_devices_locked(&devs_guard, &mut st, consumer_active);
    }

    /// Returns the number of stereo frames currently buffered in `WasmWebAudioRing`.
    #[inline]
    pub fn wasm_web_audio_queued_frames() -> u32 {
        (web_audio_ring().queued_samples() / WEB_RING_CHANNELS) as u32
    }

    /// Returns the monotonic render-quantum callback counter updated by the Web Audio consumer.
    #[inline]
    pub fn wasm_web_audio_frames_consumed() -> u32 {
        web_audio_ring().ctrl.frames_consumed.load(Ordering::Relaxed)
    }

    /// Returns the target steady-state Web Audio ring cushion in frames.
    #[inline]
    pub const fn wasm_web_audio_target_cushion_frames() -> u32 {
        WEB_RING_TARGET_CUSHION_FRAMES
    }

    /// Returns the browser `AudioContext.sampleRate` reported by the Web Audio bridge.
    #[inline]
    pub fn wasm_get_web_audio_host_sample_rate() -> u32 {
        HOST_AUDIO_SAMPLE_RATE.load(Ordering::Relaxed).max(8000)
    }

    /// Returns whether at least one active Web playback device is open.
    #[inline]
    pub fn wasm_has_active_output_devices() -> bool {
        let Ok(devs) = devices_registry().try_lock() else {
            return false;
        };
        devs.iter().any(|d| d.is_active() && d.user_data_addr != 0)
    }

    /// Returns the preferred output sample rate for initializing the Web `AudioContext`.
    #[wasm_bindgen]
    pub fn wasm_get_sample_rate() -> u32 {
        if let Ok(devs) = devices_registry().try_lock() {
            if let Some(dev) = devs.iter().find(|d| d.is_active()) {
                if dev.sample_rate >= 8000 {
                    return dev.sample_rate;
                }
            }
        }
        HOST_AUDIO_SAMPLE_RATE.load(Ordering::Relaxed).max(8000)
    }

    /// Records the actual browser `AudioContext.sampleRate` so Web pumping matches it cleanly.
    #[wasm_bindgen]
    pub fn wasm_set_web_audio_sample_rate(sample_rate: u32) {
        let sr = sample_rate.clamp(8000, 192000);
        HOST_AUDIO_SAMPLE_RATE.store(sr, Ordering::Relaxed);
        web_audio_ring().ctrl.sample_rate.store(sr, Ordering::Relaxed);
    }

    /// Returns the number of stereo frames currently queued for Web Audio output.
    #[wasm_bindgen]
    pub fn wasm_get_web_audio_queued_frames() -> u32 {
        wasm_web_audio_queued_frames()
    }

    /// Returns the cumulative number of Web Audio consumer underrun callbacks during playback.
    #[wasm_bindgen]
    pub fn wasm_get_web_audio_underruns() -> u32 {
        web_audio_ring().ctrl.underruns.load(Ordering::Relaxed)
    }

    /// Returns the monotonic render-quantum heartbeat incremented by the Web Audio consumer.
    #[wasm_bindgen]
    pub fn wasm_get_web_audio_frames_consumed() -> u32 {
        wasm_web_audio_frames_consumed()
    }

    /// Returns cumulative mono capture samples written across active Web microphone slots.
    #[wasm_bindgen]
    pub fn wasm_get_web_capture_samples_written() -> u32 {
        let Some(slots) = CAPTURE_SLOTS.get() else {
            return 0;
        };
        let Ok(guard) = slots.try_lock() else {
            return 0;
        };
        guard
            .iter()
            .filter(|s| s.in_use.load(Ordering::Relaxed))
            .fold(0u32, |acc, s| acc.wrapping_add(s.ctrl.write_pos.load(Ordering::Relaxed)))
    }

    /// Returns the descriptor object allowing `AudioWorklet` to read `WasmWebAudioRing` directly
    /// from shared WASM linear memory without involving the browser main UI thread.
    #[wasm_bindgen]
    pub fn wasm_get_web_audio_ring_descriptor() -> JsValue {
        let ring = web_audio_ring();
        let ctrl_ptr = (&ring.ctrl as *const WasmWebAudioControl) as usize as u32;
        let data_ptr = ring.data.get() as usize as u32;
        let obj = Object::new();
        let _ = Reflect::set(&obj, &JsValue::from_str("memory"), &wasm_bindgen::memory());
        let _ = Reflect::set(&obj, &JsValue::from_str("ctrlPtr"), &JsValue::from_f64(ctrl_ptr as f64));
        let _ = Reflect::set(&obj, &JsValue::from_str("dataPtr"), &JsValue::from_f64(data_ptr as f64));
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("capSamples"),
            &JsValue::from_f64(WEB_RING_CAP_SAMPLES as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("channels"),
            &JsValue::from_f64(WEB_RING_CHANNELS as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("sampleRate"),
            &JsValue::from_f64(HOST_AUDIO_SAMPLE_RATE.load(Ordering::Relaxed) as f64),
        );
        let _ = Reflect::set(
            &obj,
            &JsValue::from_str("targetCushionFrames"),
            &JsValue::from_f64(WEB_RING_TARGET_CUSHION_FRAMES as f64),
        );
        obj.into()
    }

    /// Legacy `ScriptProcessorNode` fallback consumer reading from `WasmWebAudioRing` without
    /// throwing away buffered audio via prebuffering snap-backs.
    #[wasm_bindgen]
    pub fn wasm_render_web_audio(frames: u32) -> Float32Array {
        let safe_frames = frames.clamp(64, 16384) as usize;
        let needed_samples = safe_frames * WEB_RING_CHANNELS;
        let ring = web_audio_ring();

        if let Ok(mut devs) = devices_registry().try_lock() {
            devs.retain(|d| d.is_alive());
            if let Ok(mut st) = pump_state().try_lock() {
                pump_devices_locked(&devs, &mut st, true);
                st.fallback_buf.clear();
                st.fallback_buf.resize(needed_samples, 0.0);
                let _ = ring.pop_stereo(&mut st.fallback_buf);
                return Float32Array::from(st.fallback_buf.as_slice());
            }
        }

        let mut out = vec![0.0f32; needed_samples];
        let _ = ring.pop_stereo(&mut out);
        Float32Array::from(out.as_slice())
    }

    pub unsafe fn map_device_create(
        sample_rate: u32,
        channels: u32,
        _period_size_in_frames: u32,
        _playback_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext {
        if !out_result.is_null() {
            *out_result = MAP_SUCCESS;
        }
        let ch = channels.clamp(1, 8);
        let sr = sample_rate.clamp(8000, 192000);
        let state = Arc::new(WasmDeviceState {
            sample_rate: sr,
            channels: ch,
            user_data_addr: rust_user_data as usize,
            alive: AtomicBool::new(true),
            active: AtomicBool::new(false),
        });

        if !rust_user_data.is_null() {
            if let Ok(mut devs) = devices_registry().lock() {
                devs.retain(|d| d.is_alive());
                devs.push(state.clone());
            }
        }

        Box::into_raw(Box::new(WasmDeviceHandle::Output(state))) as *mut MapDeviceContext
    }

    pub unsafe fn map_capture_device_create(
        sample_rate: u32,
        channels: u32,
        _period_size_in_frames: u32,
        capture_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext {
        let host_sr = HOST_AUDIO_SAMPLE_RATE.load(Ordering::Relaxed).max(8000);
        let Some((slot_idx, generation, ctrl_ptr, data_ptr)) = acquire_capture_slot(host_sr) else {
            if !out_result.is_null() {
                *out_result = MAP_ERROR_UNSUPPORTED;
            }
            return std::ptr::null_mut();
        };

        let req_id = if capture_device_id.is_null() {
            "AUTO".to_string()
        } else {
            CStr::from_ptr(capture_device_id)
                .to_str()
                .unwrap_or("AUTO")
                .to_string()
        };

        if !out_result.is_null() {
            *out_result = MAP_SUCCESS;
        }

        let state = Arc::new(WasmCaptureState {
            slot_idx,
            generation,
            ctrl_ptr,
            data_ptr,
            sample_rate: sample_rate.clamp(8000, 192000),
            channels: channels.clamp(1, 8),
            requested_device_id: req_id,
            user_data_addr: rust_user_data as usize,
            alive: AtomicBool::new(true),
            active: AtomicBool::new(false),
            failed: AtomicBool::new(false),
            pump: Mutex::new(WasmCapturePumpState::new()),
        });

        if let Ok(mut devs) = capture_devices_registry().lock() {
            devs.retain(|d| d.is_alive());
            devs.push(state.clone());
        }

        Box::into_raw(Box::new(WasmDeviceHandle::Capture(state))) as *mut MapDeviceContext
    }

    pub unsafe fn map_device_start(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            match &*(ctx as *const WasmDeviceHandle) {
                WasmDeviceHandle::Output(state) => {
                    state.active.store(true, Ordering::Release);
                }
                WasmDeviceHandle::Capture(cap) => {
                    cap.failed.store(false, Ordering::Release);
                    cap.active.store(true, Ordering::Release);
                    let _ = with_capture_slot(cap.slot_idx, |slot| {
                        if slot.ctrl.generation.load(Ordering::Acquire) == cap.generation {
                            slot.ctrl.active.store(1, Ordering::Release);
                        }
                    });
                    dispatch_start_capture_cmd(cap);
                }
            }
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_stop(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            match &*(ctx as *const WasmDeviceHandle) {
                WasmDeviceHandle::Output(state) => {
                    state.active.store(false, Ordering::Release);
                }
                WasmDeviceHandle::Capture(cap) => {
                    cap.active.store(false, Ordering::Release);
                    let _ = with_capture_slot(cap.slot_idx, |slot| {
                        if slot.ctrl.generation.load(Ordering::Acquire) == cap.generation {
                            slot.ctrl.active.store(0, Ordering::Release);
                        }
                    });
                    dispatch_stop_capture_cmd(cap.slot_idx, cap.generation);
                }
            }
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let handle = Box::from_raw(ctx as *mut WasmDeviceHandle);
            match *handle {
                WasmDeviceHandle::Output(state) => {
                    if let Ok(mut devs) = devices_registry().lock() {
                        state.active.store(false, Ordering::Release);
                        state.alive.store(false, Ordering::Release);
                        devs.retain(|d| d.is_alive());
                    } else {
                        state.active.store(false, Ordering::Release);
                        state.alive.store(false, Ordering::Release);
                    }
                }
                WasmDeviceHandle::Capture(cap) => {
                    cap.active.store(false, Ordering::Release);
                    cap.alive.store(false, Ordering::Release);
                    let _ = with_capture_slot(cap.slot_idx, |slot| {
                        if slot.ctrl.generation.load(Ordering::Acquire) == cap.generation {
                            slot.ctrl.active.store(0, Ordering::Release);
                            slot.ctrl.generation.fetch_add(1, Ordering::AcqRel);
                            slot.in_use.store(false, Ordering::Release);
                        }
                    });
                    if let Ok(mut devs) = capture_devices_registry().lock() {
                        devs.retain(|d| d.is_alive());
                    }
                    dispatch_stop_capture_cmd(cap.slot_idx, cap.generation);
                }
            }
        }
        MAP_SUCCESS
    }
}

#[cfg(target_arch = "wasm32")]
pub use wasm_device_bridge::*;

/// Function pointer vtable header for microphone capture callbacks from C to Rust.
#[repr(C)]
pub struct PcmCaptureHeader {
    /// C callback delivering captured PCM float samples.
    pub capture_fn: unsafe extern "C" fn(ptr: *mut c_void, input: *const f32, count: usize),
    /// C callback notifying device state transitions.
    pub notif_fn: unsafe extern "C" fn(ptr: *mut c_void, notif: i32),
}

/// Global C trampoline called by miniaudio to pull rendered audio frames from Rust.
#[no_mangle]
pub unsafe extern "C" fn rust_render_pcm_frames(
    user_data: *mut c_void,
    output_frames: *mut f32,
    frame_count: u32,
) {
    if !user_data.is_null() && !output_frames.is_null() && frame_count > 0 {
        let header = &*(user_data as *const crate::core::renderer::PcmRendererHeader);
        (header.render_fn)(user_data, output_frames, frame_count as usize);
    }
}

/// Global C trampoline called by miniaudio to deliver captured microphone frames to Rust.
#[no_mangle]
pub unsafe extern "C" fn rust_capture_pcm_frames(
    user_data: *mut c_void,
    input_frames: *const f32,
    frame_count: u32,
) {
    if !user_data.is_null() && !input_frames.is_null() && frame_count > 0 {
        let header = &*(user_data as *const PcmCaptureHeader);
        (header.capture_fn)(user_data, input_frames, frame_count as usize);
    }
}

/// Global C trampoline notifying Rust when audio device state changes.
#[no_mangle]
pub unsafe extern "C" fn rust_on_device_notification(
    user_data: *mut c_void,
    notification_type: i32,
) {
    if !user_data.is_null() {
        let header = &*(user_data as *const crate::core::renderer::PcmRendererHeader);
        (header.notif_fn)(user_data, notification_type);
    }
}

// =========================================================================
// Safe RAII and Device Enumeration Wrappers
// =========================================================================

/// Safely queries all playback and capture audio devices from the OS in a single pass.
pub fn safe_enumerate_all_devices() -> Result<(Vec<MapDeviceInfo>, Vec<MapDeviceInfo>), i32> {
    #[cfg(target_arch = "wasm32")]
    {
        Ok((Vec::new(), wasm_device_bridge::cached_capture_device_infos()))
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut all = MapAllDevices::default();
        let res = unsafe { map_device_enumerate_all(&mut all) };
        if res != 0 {
            return Err(res);
        }

        let playback = if !all.playback_devices.is_null() && all.playback_count > 0 {
            let slice = unsafe {
                std::slice::from_raw_parts(all.playback_devices, all.playback_count as usize)
            };
            slice.to_vec()
        } else {
            Vec::new()
        };

        let capture = if !all.capture_devices.is_null() && all.capture_count > 0 {
            let slice = unsafe {
                std::slice::from_raw_parts(all.capture_devices, all.capture_count as usize)
            };
            slice.to_vec()
        } else {
            Vec::new()
        };

        unsafe { map_device_free_all(&mut all) };
        Ok((playback, capture))
    }
}

/// Safely queries all playback output devices.
pub fn safe_enumerate_playback_devices() -> Result<Vec<MapDeviceInfo>, i32> {
    #[cfg(target_arch = "wasm32")]
    {
        Ok(Vec::new())
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut count = 0;
        let mut ptr = std::ptr::null_mut();
        let res = unsafe { map_device_enumerate_devices(&mut ptr, &mut count) };
        if res != 0 {
            return Err(res);
        }
        let devs = if !ptr.is_null() && count > 0 {
            let slice = unsafe { std::slice::from_raw_parts(ptr, count as usize) };
            slice.to_vec()
        } else {
            Vec::new()
        };
        if !ptr.is_null() {
            unsafe { map_device_free_devices(ptr) };
        }
        Ok(devs)
    }
}

/// Safely queries all capture input devices.
pub fn safe_enumerate_capture_devices() -> Result<Vec<MapDeviceInfo>, i32> {
    #[cfg(target_arch = "wasm32")]
    {
        Ok(wasm_device_bridge::cached_capture_device_infos())
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut count = 0;
        let mut ptr = std::ptr::null_mut();
        let res = unsafe { map_device_enumerate_capture_devices(&mut ptr, &mut count) };
        if res != 0 {
            return Err(res);
        }
        let devs = if !ptr.is_null() && count > 0 {
            let slice = unsafe { std::slice::from_raw_parts(ptr, count as usize) };
            slice.to_vec()
        } else {
            Vec::new()
        };
        if !ptr.is_null() {
            unsafe { map_device_free_devices(ptr) };
        }
        Ok(devs)
    }
}
