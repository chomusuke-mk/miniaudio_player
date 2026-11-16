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

#[cfg(target_arch = "wasm32")]
mod wasm_device_bridge {
    use super::*;
    use flutter_rust_bridge::for_generated::js_sys::{Float32Array, Object, Reflect};
    use flutter_rust_bridge::for_generated::wasm_bindgen;
    use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;
    use std::cell::UnsafeCell;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};

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

    struct LinearStereoResampler {
        last_ratio_num: u32,
        last_ratio_den: u32,
        phase: f64,
        prev_l: f32,
        prev_r: f32,
        initialized: bool,
    }

    impl LinearStereoResampler {
        const fn new() -> Self {
            Self {
                last_ratio_num: 44100,
                last_ratio_den: 44100,
                phase: 0.0,
                prev_l: 0.0,
                prev_r: 0.0,
                initialized: false,
            }
        }

        fn process(&mut self, input: &[f32], in_sr: u32, out_sr: u32, out: &mut Vec<f32>) {
            out.clear();
            let in_frames = input.len() / WEB_RING_CHANNELS;
            if in_frames == 0 {
                return;
            }
            if in_sr == out_sr || in_sr == 0 || out_sr == 0 {
                out.extend_from_slice(&input[..in_frames * WEB_RING_CHANNELS]);
                let last_base = (in_frames - 1) * WEB_RING_CHANNELS;
                self.prev_l = input[last_base];
                self.prev_r = input[last_base + 1];
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
                self.prev_l = input[0];
                self.prev_r = input[1];
                self.initialized = true;
            }

            let step = (in_sr as f64) / (out_sr as f64);
            let est_out = ((in_frames as f64 / step).ceil() as usize + 4) * WEB_RING_CHANNELS;
            out.reserve(est_out);

            // Emit interpolated samples spanning [prev, input[0]] and input[i-1..i].
            let mut pos = self.phase;
            let limit = in_frames as f64;
            while pos < limit {
                let idx = pos.floor() as isize;
                let frac = (pos - (idx as f64)) as f32;
                let (l0, r0) = if idx <= 0 {
                    (self.prev_l, self.prev_r)
                } else {
                    let base = ((idx - 1) as usize) * WEB_RING_CHANNELS;
                    (input[base], input[base + 1])
                };
                let cur_idx = (idx.max(0) as usize).min(in_frames - 1);
                let cur_base = cur_idx * WEB_RING_CHANNELS;
                let (l1, r1) = (input[cur_base], input[cur_base + 1]);
                out.push(l0 + (l1 - l0) * frac);
                out.push(r0 + (r1 - r0) * frac);
                pos += step;
            }
            self.phase = pos - limit;
            let last_base = (in_frames - 1) * WEB_RING_CHANNELS;
            self.prev_l = input[last_base];
            self.prev_r = input[last_base + 1];
        }
    }

    struct PumpState {
        dev_scratch: Vec<f32>,
        mix_buf: Vec<f32>,
        resampled_buf: Vec<f32>,
        fallback_buf: Vec<f32>,
        resampler: LinearStereoResampler,
        activity_hangover: u32,
    }

    impl PumpState {
        const fn new() -> Self {
            Self {
                dev_scratch: Vec::new(),
                mix_buf: Vec::new(),
                resampled_buf: Vec::new(),
                fallback_buf: Vec::new(),
                resampler: LinearStereoResampler::new(),
                activity_hangover: 0,
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

        Arc::into_raw(state) as *mut MapDeviceContext
    }

    pub unsafe fn map_capture_device_create(
        sample_rate: u32,
        channels: u32,
        _period_size_in_frames: u32,
        _capture_device_id: *const c_char,
        _rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext {
        if !out_result.is_null() {
            *out_result = MAP_SUCCESS;
        }
        let state = Arc::new(WasmDeviceState {
            sample_rate: sample_rate.clamp(8000, 192000),
            channels: channels.clamp(1, 8),
            user_data_addr: 0,
            alive: AtomicBool::new(false),
            active: AtomicBool::new(false),
        });
        Arc::into_raw(state) as *mut MapDeviceContext
    }

    pub unsafe fn map_device_start(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let state = &*(ctx as *const WasmDeviceState);
            state.active.store(true, Ordering::Release);
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_stop(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let state = &*(ctx as *const WasmDeviceState);
            state.active.store(false, Ordering::Release);
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let state = Arc::from_raw(ctx as *const WasmDeviceState);
            if let Ok(mut devs) = devices_registry().lock() {
                state.active.store(false, Ordering::Release);
                state.alive.store(false, Ordering::Release);
                devs.retain(|d| d.is_alive());
            } else {
                state.active.store(false, Ordering::Release);
                state.alive.store(false, Ordering::Release);
            }
        }
        MAP_SUCCESS
    }

    pub unsafe extern "C" fn map_device_enumerate_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32 {
        if !out_devices.is_null() {
            *out_devices = std::ptr::null_mut();
        }
        if !out_count.is_null() {
            *out_count = 0;
        }
        MAP_SUCCESS
    }

    pub unsafe extern "C" fn map_device_enumerate_capture_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32 {
        map_device_enumerate_devices(out_devices, out_count)
    }

    pub unsafe fn map_device_free_devices(_devices: *mut MapDeviceInfo) {}

    pub unsafe extern "C" fn map_device_enumerate_all(out_all: *mut MapAllDevices) -> i32 {
        if !out_all.is_null() {
            *out_all = MapAllDevices::default();
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_free_all(_all: *mut MapAllDevices) {}
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
    let mut all = MapAllDevices::default();
    let res = unsafe { map_device_enumerate_all(&mut all) };
    if res != 0 {
        return Err(res);
    }

    let playback = if !all.playback_devices.is_null() && all.playback_count > 0 {
        let slice = unsafe { std::slice::from_raw_parts(all.playback_devices, all.playback_count as usize) };
        slice.to_vec()
    } else {
        Vec::new()
    };

    let capture = if !all.capture_devices.is_null() && all.capture_count > 0 {
        let slice = unsafe { std::slice::from_raw_parts(all.capture_devices, all.capture_count as usize) };
        slice.to_vec()
    } else {
        Vec::new()
    };

    unsafe { map_device_free_all(&mut all) };
    Ok((playback, capture))
}

/// Safely queries all playback output devices.
pub fn safe_enumerate_playback_devices() -> Result<Vec<MapDeviceInfo>, i32> {
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

/// Safely queries all capture input devices.
pub fn safe_enumerate_capture_devices() -> Result<Vec<MapDeviceInfo>, i32> {
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
