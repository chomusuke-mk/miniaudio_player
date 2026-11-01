use std::os::raw::{c_char, c_void};

pub enum MapDeviceContextOpaque {}
pub type MapDeviceContext = MapDeviceContextOpaque;

/* Códigos de error canónicos de miniaudio_player */
pub const MAP_SUCCESS: i32 = 0;
pub const MAP_ERROR_GENERIC: i32 = -1;
pub const MAP_ERROR_INVALID_ARGS: i32 = -2;
pub const MAP_ERROR_OUT_OF_MEMORY: i32 = -3;
pub const MAP_ERROR_ENGINE_INIT: i32 = -4;
pub const MAP_ERROR_FILE_NOT_FOUND: i32 = -5;
pub const MAP_ERROR_DECODE_FAILED: i32 = -6;
pub const MAP_ERROR_INVALID_STATE: i32 = -7;
pub const MAP_ERROR_SEEK_FAILED: i32 = -8;
pub const MAP_ERROR_NODE_FAILED: i32 = -9;
pub const MAP_ERROR_UNSUPPORTED: i32 = -10;
pub const MAP_ERROR_ACCESS_DENIED: i32 = -11;
pub const MAP_ERROR_BUSY: i32 = -12;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MapDeviceInfo {
    pub id: [u8; 516],
    pub effective_id: [u8; 516],
    pub name: [u8; 256],
    pub is_default: i32,
    pub is_auto: i32,
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

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct MiniaudioBufferedRange {
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    pub fill_percentage: f32,
    pub stream_percentage: f32,
    pub is_buffering: i32,
    pub is_eof: i32,
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
    pub fn map_device_get_sample_rate(ctx: *const MapDeviceContext) -> u32;
    pub fn map_device_get_channels(ctx: *const MapDeviceContext) -> u32;
    pub fn map_device_set_device(ctx: *mut MapDeviceContext, device_id: *const c_char) -> i32;
    pub fn map_device_get_current_device_info(
        ctx: *const MapDeviceContext,
        out_device: *mut MapDeviceInfo,
    ) -> i32;

    pub fn map_device_enumerate_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;
    pub fn map_device_enumerate_capture_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;
    pub fn map_device_free_devices(devices: *mut MapDeviceInfo);
}

#[cfg(target_arch = "wasm32")]
mod wasm_device_bridge {
    use super::*;
    use flutter_rust_bridge::for_generated::js_sys::Float32Array;
    use flutter_rust_bridge::for_generated::wasm_bindgen;
    use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};

    pub struct WasmDeviceState {
        sample_rate: u32,
        channels: u32,
        info: MapDeviceInfo,
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

    /// Central flow coordinator for message-driven Web Worker audio decoding,
    /// PCM rendering, and dual-deck engine monitoring without `setTimeout`.
    struct WasmWorkerRuntime {
        decoder_tasks: Vec<Box<dyn FnMut() -> bool + Send>>,
        monitor_tasks: Vec<Box<dyn FnMut() -> bool + Send>>,
        devices: Vec<Arc<WasmDeviceState>>,
        scratch_buf: Vec<f32>,
        mix_buf: Vec<f32>,
    }

    impl WasmWorkerRuntime {
        fn new() -> Self {
            Self {
                decoder_tasks: Vec::new(),
                monitor_tasks: Vec::new(),
                devices: Vec::new(),
                scratch_buf: Vec::new(),
                mix_buf: Vec::new(),
            }
        }

        fn register_decoder(&mut self, task: Box<dyn FnMut() -> bool + Send>) {
            self.decoder_tasks.push(task);
        }

        fn register_monitor(&mut self, task: Box<dyn FnMut() -> bool + Send>) {
            self.monitor_tasks.push(task);
        }

        fn register_device(&mut self, device: Arc<WasmDeviceState>) {
            self.devices.retain(|d| d.is_alive());
            self.devices.push(device);
        }

        fn has_active_work(&mut self) -> bool {
            self.devices.retain(|d| d.is_alive());
            self.devices.iter().any(|d| d.is_active())
        }

        fn pump_quantum(&mut self, frames: u32) -> Float32Array {
            let safe_frames = frames.clamp(64, 16384);
            self.decoder_tasks.retain_mut(|task| task());
            self.devices.retain(|d| d.is_alive());

            let out_channels = self
                .devices
                .iter()
                .find(|d| d.is_active())
                .map(|d| d.channels)
                .unwrap_or(2)
                .clamp(1, 8);
            let total_samples = (safe_frames * out_channels) as usize;

            self.mix_buf.clear();
            self.mix_buf.resize(total_samples, 0.0);

            for dev in &self.devices {
                if !dev.is_active() || dev.user_data_addr == 0 {
                    continue;
                }
                let dev_samples = (safe_frames * dev.channels) as usize;
                self.scratch_buf.clear();
                self.scratch_buf.resize(dev_samples, 0.0);
                unsafe {
                    rust_render_pcm_frames(
                        dev.user_data_addr as *mut c_void,
                        self.scratch_buf.as_mut_ptr(),
                        safe_frames,
                    );
                }
                if dev.channels == out_channels {
                    for (dst, src) in self.mix_buf.iter_mut().zip(self.scratch_buf.iter()) {
                        *dst = (*dst + *src).clamp(-1.0, 1.0);
                    }
                }
            }

            self.monitor_tasks.retain_mut(|task| task());
            Float32Array::from(self.mix_buf.as_slice())
        }
    }

    static WORKER_RUNTIME: OnceLock<Mutex<WasmWorkerRuntime>> = OnceLock::new();

    fn runtime() -> &'static Mutex<WasmWorkerRuntime> {
        WORKER_RUNTIME.get_or_init(|| Mutex::new(WasmWorkerRuntime::new()))
    }

    pub fn wasm_register_decoder_task(task: Box<dyn FnMut() -> bool + Send>) {
        if let Ok(mut rt) = runtime().lock() {
            rt.register_decoder(task);
        }
    }

    pub fn wasm_register_monitor_task(task: Box<dyn FnMut() -> bool + Send>) {
        if let Ok(mut rt) = runtime().lock() {
            rt.register_monitor(task);
        }
    }

    #[wasm_bindgen]
    pub fn wasm_worker_has_active_work() -> bool {
        runtime()
            .lock()
            .map(|mut rt| rt.has_active_work())
            .unwrap_or(false)
    }

    #[wasm_bindgen]
    pub fn wasm_worker_pump_quantum(frames: u32) -> Float32Array {
        if let Ok(mut rt) = runtime().lock() {
            rt.pump_quantum(frames)
        } else {
            Float32Array::new_with_length(0)
        }
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
        let mut info = MapDeviceInfo::default();
        let name_bytes = b"WebAudio Worker";
        info.name[..name_bytes.len()].copy_from_slice(name_bytes);
        let id_bytes = b"auto";
        info.id[..id_bytes.len()].copy_from_slice(id_bytes);

        let sr = sample_rate.max(8000);
        let ch = channels.clamp(1, 8);
        let state = Arc::new(WasmDeviceState {
            sample_rate: sr,
            channels: ch,
            info,
            user_data_addr: rust_user_data as usize,
            alive: AtomicBool::new(true),
            active: AtomicBool::new(false),
        });

        if !rust_user_data.is_null() {
            if let Ok(mut rt) = runtime().lock() {
                rt.register_device(state.clone());
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
            sample_rate: sample_rate.max(8000),
            channels: channels.clamp(1, 8),
            info: MapDeviceInfo::default(),
            user_data_addr: 0,
            alive: AtomicBool::new(false),
            active: AtomicBool::new(false),
        });
        Arc::into_raw(state) as *mut MapDeviceContext
    }

    pub unsafe fn map_device_start(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            (*(ctx as *const WasmDeviceState))
                .active
                .store(true, Ordering::Relaxed);
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_stop(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            (*(ctx as *const WasmDeviceState))
                .active
                .store(false, Ordering::Relaxed);
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let state = Arc::from_raw(ctx as *const WasmDeviceState);
            state.active.store(false, Ordering::Relaxed);
            state.alive.store(false, Ordering::Relaxed);
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_get_sample_rate(ctx: *const MapDeviceContext) -> u32 {
        if ctx.is_null() {
            48000
        } else {
            (*(ctx as *const WasmDeviceState)).sample_rate
        }
    }

    pub unsafe fn map_device_get_channels(ctx: *const MapDeviceContext) -> u32 {
        if ctx.is_null() {
            2
        } else {
            (*(ctx as *const WasmDeviceState)).channels
        }
    }

    pub unsafe fn map_device_set_device(
        _ctx: *mut MapDeviceContext,
        _device_id: *const c_char,
    ) -> i32 {
        MAP_SUCCESS
    }

    pub unsafe fn map_device_get_current_device_info(
        ctx: *const MapDeviceContext,
        out_device: *mut MapDeviceInfo,
    ) -> i32 {
        if out_device.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        if ctx.is_null() {
            *out_device = MapDeviceInfo::default();
        } else {
            *out_device = (*(ctx as *const WasmDeviceState)).info;
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
}

#[cfg(target_arch = "wasm32")]
pub use wasm_device_bridge::*;

#[repr(C)]
pub struct PcmCaptureHeader {
    pub capture_fn: unsafe extern "C" fn(ptr: *mut c_void, input: *const f32, count: usize),
    pub notif_fn: unsafe extern "C" fn(ptr: *mut c_void, notif: i32),
}

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
