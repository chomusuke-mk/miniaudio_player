//! Raw FFI declarations, C callbacks, WebAudio WASM runtime bindings, and safe enumeration wrappers.

use std::os::raw::{c_char, c_void};

/// Opaque marker type representing a miniaudio audio hardware device context.
pub enum MapDeviceContextOpaque {}
/// Type alias for the opaque device context pointer.
pub type MapDeviceContext = MapDeviceContextOpaque;

// Canonical error codes for miniaudio_player.

/// Operation completed successfully.
pub const MAP_SUCCESS: i32 = 0;
/// Generic unspecified error.
pub const MAP_ERROR_GENERIC: i32 = -1;
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
/// Resource busy or locked.
pub const MAP_ERROR_BUSY: i32 = -12;

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
    /// Pointer to the C-allocated array of playback [`MapDeviceInfo`] descriptors.
    pub playback_devices: *mut MapDeviceInfo,
    /// Number of valid entries in `playback_devices`.
    pub playback_count: u32,
    /// Pointer to the C-allocated array of capture [`MapDeviceInfo`] descriptors.
    pub capture_devices: *mut MapDeviceInfo,
    /// Number of valid entries in `capture_devices`.
    pub capture_count: u32,
}

impl Default for MapAllDevices {
    /// Returns an empty [`MapAllDevices`] with null pointers and zero counts.
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
    /// Returns a zeroed [`MapDeviceInfo`] marked as automatic OS default.
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
    /// Creates and initializes a native miniaudio playback device context.
    ///
    /// Configures the device for `sample_rate` Hz, `channels` channels, and `period_size_in_frames`
    /// frames per callback, targeting `playback_device_id` (or the default device if null/empty).
    /// Passes `rust_user_data` to audio/notification callbacks and stores the status code in `out_result`.
    ///
    /// # Safety
    ///
    /// `playback_device_id` (if non-null) must be a valid NUL-terminated C string, `rust_user_data`
    /// must remain valid for the device's lifetime, and `out_result` (if non-null) must be writable.
    pub fn map_device_create(
        sample_rate: u32,
        channels: u32,
        period_size_in_frames: u32,
        playback_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext;

    /// Creates and initializes a native miniaudio microphone capture device context.
    ///
    /// Configures the device for `sample_rate` Hz, `channels` channels, and `period_size_in_frames`
    /// frames per callback, targeting `capture_device_id` (or the default device if null/empty).
    /// Passes `rust_user_data` to capture callbacks and stores the status code in `out_result`.
    ///
    /// # Safety
    ///
    /// `capture_device_id` (if non-null) must be a valid NUL-terminated C string, `rust_user_data`
    /// must remain valid for the device's lifetime, and `out_result` (if non-null) must be writable.
    pub fn map_capture_device_create(
        sample_rate: u32,
        channels: u32,
        period_size_in_frames: u32,
        capture_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext;

    /// Starts audio callbacks on the native device context `ctx`.
    ///
    /// # Safety
    ///
    /// `ctx` must be a valid pointer returned by `map_device_create` or `map_capture_device_create`.
    pub fn map_device_start(ctx: *mut MapDeviceContext) -> i32;

    /// Stops audio callbacks on the native device context `ctx`.
    ///
    /// # Safety
    ///
    /// `ctx` must be a valid pointer returned by `map_device_create` or `map_capture_device_create`.
    pub fn map_device_stop(ctx: *mut MapDeviceContext) -> i32;

    /// Stops and destroys the native device context `ctx`, freeing its C-side resources.
    ///
    /// # Safety
    ///
    /// `ctx` must be a valid pointer (or null) and must not be used again after this call.
    pub fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32;

    /// Enumerates native playback devices into `out_devices` and writes the count to `out_count`.
    ///
    /// # Safety
    ///
    /// `out_devices` and `out_count` must be non-null writable pointers; the returned array must be
    /// freed via [`map_device_free_devices`].
    pub fn map_device_enumerate_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;

    /// Enumerates native capture devices into `out_devices` and writes the count to `out_count`.
    ///
    /// # Safety
    ///
    /// `out_devices` and `out_count` must be non-null writable pointers; the returned array must be
    /// freed via [`map_device_free_devices`].
    pub fn map_device_enumerate_capture_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;

    /// Frees a device descriptor array `devices` previously allocated by enumeration functions.
    ///
    /// # Safety
    ///
    /// `devices` must be null or a pointer returned by [`map_device_enumerate_devices`] or
    /// [`map_device_enumerate_capture_devices`].
    pub fn map_device_free_devices(devices: *mut MapDeviceInfo);

    /// Enumerates both playback and capture devices in one pass into `out_all`.
    ///
    /// # Safety
    ///
    /// `out_all` must be a non-null writable pointer to a [`MapAllDevices`] struct; results must be
    /// freed via [`map_device_free_all`].
    pub fn map_device_enumerate_all(out_all: *mut MapAllDevices) -> i32;

    /// Frees playback and capture arrays stored inside `all`.
    ///
    /// # Safety
    ///
    /// `all` must be null or a pointer previously populated by [`map_device_enumerate_all`].
    pub fn map_device_free_all(all: *mut MapAllDevices);
}

/// Target-independent lock-free Web Audio capture ring & linear resampler primitives
/// tested natively under `cargo test` and shared directly with `wasm32`.
pub mod wasm_audio_protocol {
    use std::cell::UnsafeCell;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

    /// Mono capture ring buffer capacity in samples (~341 ms at 48 kHz).
    pub const WEB_CAPTURE_CAP_SAMPLES: usize = 16384;
    /// Bitmask for fast power-of-two index wrapping within [`WEB_CAPTURE_CAP_SAMPLES`].
    pub const WEB_CAPTURE_MASK: usize = WEB_CAPTURE_CAP_SAMPLES - 1;
    /// Maximum number of concurrent Web Audio capture slots allocated in WASM memory.
    pub const MAX_WEB_CAPTURE_SLOTS: usize = 8;

    /// Interleaved multi-channel linear PCM resampler shared across Web playback and capture paths.
    pub struct LinearPcmResampler<const CH: usize> {
        /// Numerator (`in_sr`) of the last configured resampling ratio.
        last_ratio_num: u32,
        /// Denominator (`out_sr`) of the last configured resampling ratio.
        last_ratio_den: u32,
        /// Fractional input frame phase carried across consecutive [`Self::process`] calls.
        phase: f64,
        /// Last frame from the previous chunk used to interpolate the boundary sample.
        prev: [f32; CH],
        /// Whether [`Self::prev`] has been seeded with at least one input frame.
        initialized: bool,
    }

    impl<const CH: usize> LinearPcmResampler<CH> {
        /// Creates a new uninitialized [`LinearPcmResampler`] with zeroed history.
        pub const fn new() -> Self {
            Self {
                last_ratio_num: 44100,
                last_ratio_den: 44100,
                phase: 0.0,
                prev: [0.0; CH],
                initialized: false,
            }
        }

        /// Resamples interleaved `input` frames from `in_sr` Hz to `out_sr` Hz into `out`.
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

    /// Cache-line aligned shared-memory control header for a Web Audio microphone capture ring.
    #[repr(C, align(64))]
    pub struct WasmWebCaptureControl {
        /// Producer write cursor in samples (written by JS AudioWorklet/ScriptProcessor).
        pub write_pos: AtomicU32,
        /// Consumer read cursor in samples (written by the Rust capture pump).
        pub read_pos: AtomicU32,
        /// Browser `AudioContext.sampleRate` reported for this capture stream.
        pub host_sample_rate: AtomicU32,
        /// Channel count (always `1` mono).
        pub channels: AtomicU32,
        /// Ring capacity in samples ([`WEB_CAPTURE_CAP_SAMPLES`], power of 2).
        pub cap_samples: AtomicU32,
        /// Active flag (`1` while capturing, `0` otherwise).
        pub active: AtomicU32,
        /// Monotonic slot generation fence preventing stale JS writes after device teardown.
        pub generation: AtomicU32,
        /// Count of overflow drops encountered while pushing into the ring.
        pub overruns: AtomicU32,
    }

    /// Shared WASM linear-memory SPSC capture ring slot paired with a [`WasmWebCaptureControl`].
    #[repr(C, align(64))]
    pub struct WasmWebCaptureSlot {
        /// Atomic control header shared with JS capture worklets.
        pub ctrl: WasmWebCaptureControl,
        /// Mono PCM sample storage buffer.
        pub data: UnsafeCell<[f32; WEB_CAPTURE_CAP_SAMPLES]>,
        /// Reservation flag indicating whether this slot is currently assigned to a capture device.
        pub in_use: AtomicBool,
    }

    unsafe impl Sync for WasmWebCaptureSlot {}
    unsafe impl Send for WasmWebCaptureSlot {}

    impl WasmWebCaptureSlot {
        /// Allocates a new boxed [`WasmWebCaptureSlot`] initialized with `default_sr` Hz.
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

        /// Resets cursors and overrun counters for a new `generation` with sample rate `default_sr`.
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

        /// Pushes `mono` PCM samples into the ring if active and matching `generation`.
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

        /// Drains all currently queued mono samples into `out`.
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

/// WebAssembly device bridge hosting Web Audio output/capture SPSC rings and `wasm_bindgen` entrypoints.
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
    /// Channel count of the shared Web Audio output ring (stereo).
    pub const WEB_RING_CHANNELS: usize = 2;
    /// Total sample capacity of the shared Web Audio output ring.
    pub const WEB_RING_CAP_SAMPLES: usize = WEB_RING_CAP_FRAMES * WEB_RING_CHANNELS;
    /// Power-of-two bitmask for wrapping sample indices inside [`WEB_RING_CAP_SAMPLES`].
    const WEB_RING_MASK: usize = WEB_RING_CAP_SAMPLES - 1;
    /// Target ahead-of-consumer buffer depth (~93 ms at 44.1 kHz) to absorb Web Worker jitter.
    pub const WEB_RING_TARGET_CUSHION_FRAMES: u32 = 4096;
    /// Max pre-unlock silence retained while AudioContext is suspended.
    const PRE_UNLOCK_SILENCE_CAP_FRAMES: usize = 512;

    /// Shared-memory lock-free control block mirrored as `Int32Array(buf, ctrlPtr, 8)` in JS.
    #[repr(C, align(64))]
    pub struct WasmWebAudioControl {
        /// Producer write cursor in samples (wraps modulo 2^32).
        pub write_pos: AtomicU32,
        /// Consumer read cursor in samples (wraps modulo 2^32).
        pub read_pos: AtomicU32,
        /// Host `AudioContext` sample rate in Hz.
        pub sample_rate: AtomicU32,
        /// Channel count (always `2` stereo).
        pub channels: AtomicU32,
        /// Ring buffer capacity in samples ([`WEB_RING_CAP_SAMPLES`], power of 2).
        pub cap_samples: AtomicU32,
        /// Consumer underrun counter incremented during active playback.
        pub underruns: AtomicU32,
        /// Consumer render-quantum heartbeat counter.
        pub frames_consumed: AtomicU32,
        /// Flag (`1`) indicating non-silent audio is actively flowing.
        pub playing_hint: AtomicU32,
    }

    /// Static lock-free SPSC ring buffer inside shared WASM linear memory, read directly
    /// off the main UI thread by the `AudioWorklet` audio rendering thread.
    #[repr(C, align(64))]
    pub struct WasmWebAudioRing {
        /// Atomic control header mirrored into JS shared memory.
        ctrl: WasmWebAudioControl,
        /// Interleaved stereo PCM sample storage buffer.
        data: UnsafeCell<[f32; WEB_RING_CAP_SAMPLES]>,
    }

    unsafe impl Sync for WasmWebAudioRing {}
    unsafe impl Send for WasmWebAudioRing {}

    /// Singleton Web Audio SPSC output ring instance.
    static WEB_AUDIO_RING: OnceLock<Box<WasmWebAudioRing>> = OnceLock::new();
    /// Cached browser `AudioContext.sampleRate` in Hz.
    static HOST_AUDIO_SAMPLE_RATE: AtomicU32 = AtomicU32::new(44100);

    /// Returns a static reference to the lazily initialized [`WasmWebAudioRing`].
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
        /// Returns the number of interleaved stereo samples currently queued in the ring.
        #[inline]
        fn queued_samples(&self) -> usize {
            let w = self.ctrl.write_pos.load(Ordering::Acquire);
            let r = self.ctrl.read_pos.load(Ordering::Acquire);
            (w.wrapping_sub(r) as usize).min(WEB_RING_CAP_SAMPLES)
        }

        /// Pushes frame-aligned interleaved `stereo` samples into the ring, returning the sample count written.
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

        /// Pops stereo samples into `out`, zero-filling any shortfall and tracking underruns.
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

    /// Lifecycle and format metadata for an active Web Audio playback device handle.
    pub struct WasmDeviceState {
        /// Configured device sample rate in Hz.
        sample_rate: u32,
        /// Configured device channel count.
        channels: u32,
        /// Raw address of the associated `OutputDeviceRenderer` passed as `rust_user_data`.
        user_data_addr: usize,
        /// Whether this device has not yet been destroyed.
        alive: AtomicBool,
        /// Whether this device is currently started and rendering PCM.
        active: AtomicBool,
    }

    impl WasmDeviceState {
        /// Returns `true` if the device has not been destroyed.
        #[inline]
        fn is_alive(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
        }

        /// Returns `true` if the device is alive and actively started.
        #[inline]
        fn is_active(&self) -> bool {
            self.alive.load(Ordering::Relaxed) && self.active.load(Ordering::Relaxed)
        }
    }

    /// Registry of active Web Audio playback devices pumped into [`WEB_AUDIO_RING`].
    static DEVICES: OnceLock<Mutex<Vec<Arc<WasmDeviceState>>>> = OnceLock::new();

    /// Returns the lazily initialized playback device registry mutex.
    fn devices_registry() -> &'static Mutex<Vec<Arc<WasmDeviceState>>> {
        DEVICES.get_or_init(|| Mutex::new(Vec::new()))
    }

    /// Reusable scratch buffers and resampler state for [`pump_devices_locked`].
    struct PumpState {
        /// Scratch buffer receiving rendered frames from a single device.
        dev_scratch: Vec<f32>,
        /// Interleaved stereo accumulation buffer summing all active devices.
        mix_buf: Vec<f32>,
        /// Output buffer holding resampled stereo frames when `src_sr != host_sr`.
        resampled_buf: Vec<f32>,
        /// Fallback output buffer used by the legacy `ScriptProcessorNode` path.
        fallback_buf: Vec<f32>,
        /// Stereo linear PCM resampler adapting device sample rates to the host `AudioContext`.
        resampler: LinearPcmResampler<WEB_RING_CHANNELS>,
        /// Remaining pump iterations to keep `playing_hint` asserted after silence begins.
        activity_hangover: u32,
    }

    impl PumpState {
        /// Creates a zero-allocation [`PumpState`] ready for use in a static mutex.
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

    /// `BroadcastChannel` name used by background workers to forward Web capture commands to the main thread.
    const WEB_CAPTURE_CHANNEL_NAME: &str = "__miniaudio_web_capture_v1__";

    /// Pool of shared-memory Web capture ring slots indexed by `slot_idx`.
    static CAPTURE_SLOTS: OnceLock<Mutex<Vec<Box<WasmWebCaptureSlot>>>> = OnceLock::new();
    /// Monotonic generation counter assigned to newly acquired capture slots.
    static NEXT_CAPTURE_GENERATION: AtomicU32 = AtomicU32::new(1);

    /// Invokes closure `f` on the capture slot at `slot_idx`, returning `None` if unavailable.
    fn with_capture_slot<R>(slot_idx: usize, f: impl FnOnce(&WasmWebCaptureSlot) -> R) -> Option<R> {
        let slots = CAPTURE_SLOTS.get()?;
        let guard = slots.lock().ok()?;
        guard.get(slot_idx).map(|s| f(s))
    }

    /// Reserves or allocates a [`WasmWebCaptureSlot`] initialized with `default_sr`, returning
    /// `(slot_idx, generation, ctrl_ptr, data_ptr)`.
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

    /// Reusable scratch buffers and mono resampler owned by each [`WasmCaptureState`].
    struct WasmCapturePumpState {
        /// Mono linear PCM resampler adapting browser `AudioContext` rate to target capture rate.
        resampler: LinearPcmResampler<1>,
        /// Scratch buffer drained from the shared capture slot.
        scratch_in: Vec<f32>,
        /// Scratch buffer receiving resampled mono frames.
        scratch_resampled: Vec<f32>,
        /// Scratch buffer duplicating mono frames across multi-channel capture targets.
        scratch_interleaved: Vec<f32>,
    }

    impl WasmCapturePumpState {
        /// Creates an empty [`WasmCapturePumpState`].
        fn new() -> Self {
            Self {
                resampler: LinearPcmResampler::new(),
                scratch_in: Vec::new(),
                scratch_resampled: Vec::new(),
                scratch_interleaved: Vec::new(),
            }
        }
    }

    /// Lifecycle and routing state for an active Web Audio microphone capture device handle.
    pub struct WasmCaptureState {
        /// Index of the assigned slot inside [`CAPTURE_SLOTS`].
        slot_idx: usize,
        /// Monotonic generation fence matching the assigned capture slot.
        generation: u32,
        /// Shared WASM linear-memory address of [`WasmWebCaptureControl`].
        ctrl_ptr: u32,
        /// Shared WASM linear-memory address of the capture ring PCM data array.
        data_ptr: u32,
        /// Target capture sample rate in Hz expected by the Rust capture receiver.
        sample_rate: u32,
        /// Target capture channel count expected by the Rust capture receiver.
        channels: u32,
        /// Requested browser media device identifier (or `"AUTO"`).
        requested_device_id: String,
        /// Raw address of the associated `CaptureReceiver` header passed as `rust_user_data`.
        user_data_addr: usize,
        /// Whether this capture handle has not yet been destroyed.
        alive: AtomicBool,
        /// Whether capture is currently started.
        active: AtomicBool,
        /// Whether the JS capture pipeline reported an unrecoverable error.
        failed: AtomicBool,
        /// Per-device scratch buffers and resampler protected by a mutex.
        pump: Mutex<WasmCapturePumpState>,
    }

    impl WasmCaptureState {
        /// Returns `true` if the capture handle has not been destroyed.
        #[inline]
        fn is_alive(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
        }

        /// Returns `true` if the capture handle is alive, started, and has not failed.
        #[inline]
        fn is_active(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
                && self.active.load(Ordering::Relaxed)
                && !self.failed.load(Ordering::Relaxed)
        }
    }

    /// Polymorphic handle boxed as `MapDeviceContext` on `wasm32` for playback and capture devices.
    enum WasmDeviceHandle {
        /// Playback output device state.
        Output(Arc<WasmDeviceState>),
        /// Microphone capture input device state.
        Capture(Arc<WasmCaptureState>),
    }

    /// Registry of active Web Audio capture devices polled by [`wasm_pump_web_capture_rings`].
    static CAPTURE_DEVICES: OnceLock<Mutex<Vec<Arc<WasmCaptureState>>>> = OnceLock::new();

    /// Returns the lazily initialized capture device registry mutex.
    fn capture_devices_registry() -> &'static Mutex<Vec<Arc<WasmCaptureState>>> {
        CAPTURE_DEVICES.get_or_init(|| Mutex::new(Vec::new()))
    }

    /// Cached browser capture device entry populated from JS `navigator.mediaDevices.enumerateDevices()`.
    #[derive(Clone, PartialEq, Eq)]
    struct CachedWebDevice {
        /// Opaque browser `deviceId` string.
        id: String,
        /// Human-readable device label.
        name: String,
        /// Whether this entry is marked as the default input device.
        is_default: bool,
    }

    /// Snapshot cache of browser capture devices published by JS.
    static WEB_CAPTURE_DEVICES: OnceLock<Mutex<Vec<CachedWebDevice>>> = OnceLock::new();
    /// Registered hardware-watcher condition variables woken when Web capture state changes.
    static WEB_DEVICE_TRIGGERS: OnceLock<Mutex<Vec<Weak<(Mutex<bool>, Condvar)>>>> = OnceLock::new();
    /// Queue of error messages reported by [`wasm_notify_web_capture_failed`].
    static FAILED_CAPTURE_MESSAGES: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

    /// Returns the lazily initialized Web capture device cache mutex.
    fn web_capture_devices_cache() -> &'static Mutex<Vec<CachedWebDevice>> {
        WEB_CAPTURE_DEVICES.get_or_init(|| Mutex::new(Vec::new()))
    }

    /// Registers a hardware-watcher `trigger` pair to wake on Web capture device list or failure updates.
    pub fn register_web_device_trigger(trigger: Arc<(Mutex<bool>, Condvar)>) {
        let triggers = WEB_DEVICE_TRIGGERS.get_or_init(|| Mutex::new(Vec::new()));
        if let Ok(mut guard) = triggers.lock() {
            guard.retain(|w| w.strong_count() > 0);
            guard.push(Arc::downgrade(&trigger));
        }
    }

    /// Wakes all live registered Web device watcher triggers and prunes expired weak references.
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

    /// Posts a JS capture control command `obj` directly on the main thread or via `BroadcastChannel`.
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
                let _ = Function::new_with_args(
                    "channelName, msg",
                    "var ch = new BroadcastChannel(channelName); ch.postMessage(msg); ch.close();",
                )
                .call2(&JsValue::NULL, &JsValue::from_str(WEB_CAPTURE_CHANNEL_NAME), obj);
            }
        }
    }

    /// Posts a JS `startCapture` command describing `state` to the browser main thread.
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

    /// Posts a JS `stopCapture` command for `slot_idx` and `generation` to the browser main thread.
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

    /// Copies UTF-8 bytes of `s` into a zero-padded fixed-size NUL-terminated buffer `dst`.
    fn copy_str_to_fixed<const N: usize>(s: &str, dst: &mut [u8; N]) {
        dst.fill(0);
        let bytes = s.as_bytes();
        let max_copy = bytes.len().min(N.saturating_sub(1));
        dst[..max_copy].copy_from_slice(&bytes[..max_copy]);
    }

    /// Returns the currently cached browser microphone capture devices as [`MapDeviceInfo`] entries.
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

    /// Updates the cached browser capture device list from JS `ids`, `names`, and `defaults` arrays.
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

        let dev_count = next.len();
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
            crate::map_log!(
                3,
                "[WASM_CAP] Web capture device list updated ({} device(s))",
                dev_count
            );
            wake_web_device_watchers();
        }
    }

    /// Updates the browser `AudioContext.sampleRate` for capture slot `slot_idx` matching `generation` to `sample_rate`.
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

    /// Pushes mono PCM `samples` from JS (`sample_rate` Hz) into capture slot `slot_idx` if `generation` matches.
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

    /// Marks the capture device for `slot_idx` and `generation` as failed with `error_message` and wakes watchers.
    #[wasm_bindgen]
    pub fn wasm_notify_web_capture_failed(slot_idx: u32, generation: u32, error_message: String) {
        crate::map_log!(
            1,
            "[WASM_CAP] Web capture failed (slot={}, gen={}): {}",
            slot_idx,
            generation,
            error_message
        );
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

    /// Returns `true` if `ctx` points to a Web capture device whose JS pipeline reported failure.
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

    /// Returns `true` if any live Web capture device is currently in a failed state.
    pub fn wasm_has_failed_capture_devices() -> bool {
        let Ok(devs) = capture_devices_registry().try_lock() else {
            return false;
        };
        devs.iter()
            .any(|d| d.is_alive() && d.failed.load(Ordering::Acquire))
    }

    /// Drains and returns all queued Web capture failure messages.
    pub fn wasm_take_failed_capture_messages() -> Vec<String> {
        let Some(msgs) = FAILED_CAPTURE_MESSAGES.get() else {
            return Vec::new();
        };
        let Ok(mut guard) = msgs.lock() else {
            return Vec::new();
        };
        std::mem::take(&mut *guard)
    }

    /// Drains all active Web capture slots, resamples from host rate to target rate, and delivers frames to Rust.
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

    /// Singleton pump state mutex protecting reusable Web Audio output scratch buffers.
    static PUMP_STATE: OnceLock<Mutex<PumpState>> = OnceLock::new();

    /// Returns the lazily initialized [`PumpState`] mutex.
    fn pump_state() -> &'static Mutex<PumpState> {
        PUMP_STATE.get_or_init(|| Mutex::new(PumpState::new()))
    }

    /// Mixes available PCM from all active Web output devices `devs` into the shared SPSC Web Audio ring
    /// using `st`, capping pre-unlock silence when `consumer_active` is `false`.
    fn pump_devices_locked(
        devs: &[Arc<WasmDeviceState>],
        st: &mut PumpState,
        consumer_active: bool,
    ) {
        /// Maximum source frames mixed per iteration to bound stack/scratch work.
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
    /// Called from the dedicated `map-engine-clock` Web Worker thread with `consumer_active`
    /// indicating whether the browser `AudioWorklet` is actively draining frames.
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

    /// Records the actual browser `AudioContext.sampleRate` (`sample_rate`) so Web pumping matches it cleanly.
    #[wasm_bindgen]
    pub fn wasm_set_web_audio_sample_rate(sample_rate: u32) {
        let sr = sample_rate.clamp(8000, 192000);
        HOST_AUDIO_SAMPLE_RATE.store(sr, Ordering::Relaxed);
        web_audio_ring().ctrl.sample_rate.store(sr, Ordering::Relaxed);
        crate::map_log!(
            3,
            "[WASM_DEV] Web AudioContext sample rate set to {} Hz",
            sr
        );
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

    /// Legacy `ScriptProcessorNode` fallback consumer rendering `frames` stereo frames from
    /// `WasmWebAudioRing` without throwing away buffered audio via prebuffering snap-backs.
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

    /// Creates a WebAssembly playback device handle for `sample_rate` Hz and `channels` channels,
    /// storing `MAP_SUCCESS` into `out_result` (ignoring `_period_size_in_frames` and `_playback_device_id`)
    /// and binding `rust_user_data`.
    ///
    /// # Safety
    ///
    /// `out_result` (if non-null) must be aligned and writable, and `rust_user_data` must remain valid
    /// until [`map_device_destroy`] is called.
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

        crate::map_log!(
            3,
            "[WASM_DEV] Web playback device created (sr={}, ch={})",
            sr,
            ch
        );
        Box::into_raw(Box::new(WasmDeviceHandle::Output(state))) as *mut MapDeviceContext
    }

    /// Creates a WebAssembly capture device handle for `sample_rate` Hz, `channels` channels, and
    /// `capture_device_id` (ignoring `_period_size_in_frames`), binding `rust_user_data` and writing status
    /// into `out_result`.
    ///
    /// # Safety
    ///
    /// `capture_device_id` (if non-null) must be a valid NUL-terminated C string, `out_result` (if non-null)
    /// must be writable, and `rust_user_data` must remain valid until [`map_device_destroy`].
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
            crate::map_log!(
                1,
                "[WASM_CAP] Failed to acquire Web capture slot (limit={})",
                MAX_WEB_CAPTURE_SLOTS
            );
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

        let sr = sample_rate.clamp(8000, 192000);
        let ch = channels.clamp(1, 8);
        crate::map_log!(
            3,
            "[WASM_CAP] Web capture device created (slot={}, gen={}, sr={}, ch={}, id={})",
            slot_idx,
            generation,
            sr,
            ch,
            req_id
        );

        let state = Arc::new(WasmCaptureState {
            slot_idx,
            generation,
            ctrl_ptr,
            data_ptr,
            sample_rate: sr,
            channels: ch,
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

    /// Starts audio rendering or capture on the WebAssembly device context `ctx`.
    ///
    /// # Safety
    ///
    /// `ctx` must be null or a valid pointer returned by [`map_device_create`] or [`map_capture_device_create`].
    pub unsafe fn map_device_start(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            match &*(ctx as *const WasmDeviceHandle) {
                WasmDeviceHandle::Output(state) => {
                    state.active.store(true, Ordering::Release);
                    crate::map_log!(3, "[WASM_DEV] Started Web playback device");
                }
                WasmDeviceHandle::Capture(cap) => {
                    cap.failed.store(false, Ordering::Release);
                    cap.active.store(true, Ordering::Release);
                    let _ = with_capture_slot(cap.slot_idx, |slot| {
                        if slot.ctrl.generation.load(Ordering::Acquire) == cap.generation {
                            slot.ctrl.active.store(1, Ordering::Release);
                        }
                    });
                    crate::map_log!(
                        3,
                        "[WASM_CAP] Started Web capture device (slot={}, gen={})",
                        cap.slot_idx,
                        cap.generation
                    );
                    dispatch_start_capture_cmd(cap);
                }
            }
        }
        MAP_SUCCESS
    }

    /// Stops audio rendering or capture on the WebAssembly device context `ctx`.
    ///
    /// # Safety
    ///
    /// `ctx` must be null or a valid pointer returned by [`map_device_create`] or [`map_capture_device_create`].
    pub unsafe fn map_device_stop(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            match &*(ctx as *const WasmDeviceHandle) {
                WasmDeviceHandle::Output(state) => {
                    state.active.store(false, Ordering::Release);
                    crate::map_log!(3, "[WASM_DEV] Stopped Web playback device");
                }
                WasmDeviceHandle::Capture(cap) => {
                    cap.active.store(false, Ordering::Release);
                    let _ = with_capture_slot(cap.slot_idx, |slot| {
                        if slot.ctrl.generation.load(Ordering::Acquire) == cap.generation {
                            slot.ctrl.active.store(0, Ordering::Release);
                        }
                    });
                    crate::map_log!(
                        3,
                        "[WASM_CAP] Stopped Web capture device (slot={}, gen={})",
                        cap.slot_idx,
                        cap.generation
                    );
                    dispatch_stop_capture_cmd(cap.slot_idx, cap.generation);
                }
            }
        }
        MAP_SUCCESS
    }

    /// Destroys the WebAssembly device context `ctx`, releasing its slot and unregistering it.
    ///
    /// # Safety
    ///
    /// `ctx` must be null or a valid pointer returned by [`map_device_create`] or
    /// [`map_capture_device_create`] and must not be dereferenced again afterwards.
    pub unsafe fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let handle = Box::from_raw(ctx as *mut WasmDeviceHandle);
            match *handle {
                WasmDeviceHandle::Output(state) => {
                    crate::map_log!(3, "[WASM_DEV] Destroying Web playback device");
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
                    crate::map_log!(
                        3,
                        "[WASM_CAP] Destroying Web capture device (slot={}, gen={})",
                        cap.slot_idx,
                        cap.generation
                    );
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

    /// Polls up to `max_frames` of encoded PCM bytes from `tap_id` into caller-owned `dst` without heap allocations.
    #[wasm_bindgen]
    pub fn wasm_poll_audio_tap_bytes(
        tap_id: u32,
        dst: &js_sys::Uint8Array,
        max_frames: u32,
    ) -> u32 {
        let Some(handle) = crate::core::tap::lookup_pull_tap_nonblocking(tap_id) else {
            return 0;
        };
        let dst_len = dst.length() as usize;
        let bpf = handle.channels.max(1) * handle.format.bytes_per_sample();
        let wanted_bytes = ((dst_len / bpf).min(max_frames as usize)) * bpf;
        if wanted_bytes == 0 {
            return 0;
        }
        handle
            .with_scratch_poll(wanted_bytes, max_frames, |frames, bytes| {
                if !bytes.is_empty() {
                    let target = dst.subarray(0, bytes.len() as u32);
                    target.copy_from(bytes);
                }
                frames
            })
            .unwrap_or(0)
    }

    /// Returns cumulative dropped frames observed by Pull tap `tap_id` as an exact JS number (`<= 2^53`).
    #[wasm_bindgen]
    pub fn wasm_get_audio_tap_dropped_frames(tap_id: u32) -> f64 {
        crate::core::tap::lookup_pull_tap_nonblocking(tap_id)
            .map(|h| h.total_dropped_frames() as f64)
            .unwrap_or(0.0)
    }

    /// Closes Pull audio tap `tap_id` safely from Web JS (`try_read`/`try_write`, zero `Atomics.wait`).
    #[wasm_bindgen]
    pub fn wasm_close_pull_audio_tap(tap_id: u32) {
        crate::map_log!(4, "[WASM_TAP] Closing pull audio tap id={}", tap_id);
        crate::core::tap::close_global_pull_tap(tap_id);
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

/// Global C trampoline called by miniaudio to pull `frame_count` rendered audio frames into
/// `output_frames` using `user_data`.
///
/// # Safety
///
/// `user_data` must point to a valid [`crate::core::renderer::PcmRendererHeader`], and
/// `output_frames` must be writable for `frame_count * channels` floats.
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

/// Global C trampoline called by miniaudio to deliver `frame_count` captured microphone frames from
/// `input_frames` to Rust using `user_data`.
///
/// # Safety
///
/// `user_data` must point to a valid [`PcmCaptureHeader`], and `input_frames` must be readable
/// for `frame_count * channels` floats.
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

/// Global C trampoline notifying Rust with `notification_type` when audio device state changes
/// for `user_data`.
///
/// # Safety
///
/// `user_data` (if non-null) must point to a valid [`crate::core::renderer::PcmRendererHeader`].
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
///
/// # Errors
///
/// Returns the native `MAP_ERROR_*` code if device enumeration fails.
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
            crate::map_log!(
                2,
                "[FFI_DEV] map_device_enumerate_all failed with code {}",
                res
            );
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
        crate::map_log!(
            5,
            "[FFI_DEV] Enumerated {} playback and {} capture device(s)",
            playback.len(),
            capture.len()
        );
        Ok((playback, capture))
    }
}

/// Safely queries all playback output devices.
///
/// # Errors
///
/// Returns the native `MAP_ERROR_*` code if playback enumeration fails.
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
            crate::map_log!(
                2,
                "[FFI_DEV] map_device_enumerate_devices failed with code {}",
                res
            );
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
        crate::map_log!(
            5,
            "[FFI_DEV] Enumerated {} playback device(s)",
            devs.len()
        );
        Ok(devs)
    }
}

/// Safely queries all capture input devices.
///
/// # Errors
///
/// Returns the native `MAP_ERROR_*` code if capture enumeration fails.
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
            crate::map_log!(
                2,
                "[FFI_DEV] map_device_enumerate_capture_devices failed with code {}",
                res
            );
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
        crate::map_log!(
            5,
            "[FFI_DEV] Enumerated {} capture device(s)",
            devs.len()
        );
        Ok(devs)
    }
}

// =============================================================================
// Zero-Allocation Pull Audio Tap C-ABI Entrypoints (Native dart:ffi + Finalizer)
// =============================================================================

/// Native 8-byte aligned pinned byte buffer backing zero-allocation Pull audio tap reads in Dart FFI.
pub struct MapTapBuffer {
    /// 8-byte aligned heap backing storage exposed via [`map_tap_buffer_data_ptr`].
    words: Box<[u64]>,
}

/// Allocates a zeroed pinned buffer of at least `byte_len` bytes on the C/Rust heap (8-byte aligned).
///
/// # Safety
///
/// The returned opaque handle must eventually be freed via [`map_tap_free_buffer`] or the
/// [`map_tap_free_buffer_callback`] finalizer.
#[no_mangle]
pub unsafe extern "C" fn map_tap_alloc_buffer(byte_len: usize) -> *mut c_void {
    let clamped = byte_len.max(1);
    let word_count = (clamped + 7) / 8;
    let words = vec![0u64; word_count].into_boxed_slice();
    Box::into_raw(Box::new(MapTapBuffer { words })) as *mut c_void
}

/// Returns the writable 8-byte aligned raw byte pointer inside a [`MapTapBuffer`] handle `buf`.
///
/// # Safety
///
/// `buf` must be null or a valid pointer returned by [`map_tap_alloc_buffer`].
#[no_mangle]
pub unsafe extern "C" fn map_tap_buffer_data_ptr(buf: *mut c_void) -> *mut u8 {
    if buf.is_null() {
        return std::ptr::null_mut();
    }
    let inner = &mut *(buf as *mut MapTapBuffer);
    inner.words.as_mut_ptr() as *mut u8
}

/// Frees a [`MapTapBuffer`] `buf` allocated by [`map_tap_alloc_buffer`].
///
/// # Safety
///
/// `buf` must be null or a valid pointer returned by [`map_tap_alloc_buffer`] and not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn map_tap_free_buffer(buf: *mut c_void) {
    if !buf.is_null() {
        drop(Box::from_raw(buf as *mut MapTapBuffer));
    }
}

/// Returns the C finalizer function pointer for `dart:ffi` `NativeFinalizer`.
///
/// # Safety
///
/// The returned function pointer expects a single `*mut c_void` [`MapTapBuffer`] handle.
#[no_mangle]
pub unsafe extern "C" fn map_tap_free_buffer_callback() -> *mut c_void {
    map_tap_free_buffer as *const () as *mut c_void
}

/// Polls up to `max_frames` from Pull tap `tap_id` into `dst[..byte_len]` directly from the RT/fan-out
/// ring (0 heap allocs), writing cumulative dropped frames into `out_dropped` when non-null.
///
/// # Safety
///
/// If non-null, `dst` must be writable for `byte_len` bytes and `out_dropped` must be aligned and writable.
#[no_mangle]
pub unsafe extern "C" fn map_tap_poll_bytes(
    tap_id: u32,
    dst: *mut u8,
    byte_len: usize,
    max_frames: u32,
    out_dropped: *mut u64,
) -> u32 {
    if dst.is_null() || byte_len == 0 {
        if !out_dropped.is_null() {
            *out_dropped = 0;
        }
        return 0;
    }
    let Some(handle) = crate::core::tap::lookup_pull_tap_nonblocking(tap_id) else {
        if !out_dropped.is_null() {
            *out_dropped = 0;
        }
        return 0;
    };
    let slice = std::slice::from_raw_parts_mut(dst, byte_len);
    let (frames, dropped) = handle.poll_into_bytes(slice, max_frames);
    if !out_dropped.is_null() {
        *out_dropped = dropped;
    }
    frames
}

/// Queries cumulative dropped frames for Pull tap `tap_id`.
///
/// # Safety
///
/// Safe to call with any `tap_id`; returns `0` if the tap does not exist.
#[no_mangle]
pub unsafe extern "C" fn map_tap_get_dropped(tap_id: u32) -> u64 {
    crate::core::tap::lookup_pull_tap_nonblocking(tap_id)
        .map(|h| h.total_dropped_frames())
        .unwrap_or(0)
}

/// Explicitly closes Pull audio tap `tap_id` from Native Dart FFI.
///
/// # Safety
///
/// Safe to call with any `tap_id`; closing an already-closed tap is a no-op.
#[no_mangle]
pub unsafe extern "C" fn map_tap_close_pull(tap_id: u32) {
    crate::map_log!(4, "[TAP_FFI] Closing pull audio tap id={}", tap_id);
    crate::core::tap::close_global_pull_tap(tap_id);
}

/// GC `NativeFinalizer` callback taking the Pull `tap_id` encoded inside `token` as `Pointer.fromAddress(tapId)`.
///
/// # Safety
///
/// `token` must encode a `u32` Pull tap identifier via pointer address provenance.
#[no_mangle]
pub unsafe extern "C" fn map_tap_close_pull_token(token: *mut c_void) {
    let tap_id = token as usize as u32;
    crate::map_log!(
        4,
        "[TAP_FFI] Finalizer closing pull audio tap id={}",
        tap_id
    );
    crate::core::tap::close_global_pull_tap(tap_id);
}

/// Returns the `NativeFinalizer` callback address for automatic Pull handle cleanup.
///
/// # Safety
///
/// The returned function pointer expects a single `*mut c_void` token encoding a `tap_id`.
#[no_mangle]
pub unsafe extern "C" fn map_tap_close_pull_callback() -> *mut c_void {
    map_tap_close_pull_token as *const () as *mut c_void
}
