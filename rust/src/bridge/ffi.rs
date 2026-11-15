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
    use flutter_rust_bridge::for_generated::js_sys::{
        Array, Float32Array, Function, Uint8Array,
    };
    use flutter_rust_bridge::for_generated::wasm_bindgen;
    use flutter_rust_bridge::for_generated::wasm_bindgen::prelude::*;
    use flutter_rust_bridge::for_generated::wasm_bindgen::JsCast;
    use std::cell::RefCell;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};

    pub struct WasmDeviceState {
        channels: u32,
        user_data_addr: usize,
        alive: AtomicBool,
        active: AtomicBool,
        prebuffering: AtomicBool,
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

    thread_local! {
        static RENDER_BUFFERS: RefCell<(Vec<f32>, Vec<f32>)> = const {
            RefCell::new((Vec::new(), Vec::new()))
        };
        static SYNC_FETCH_FN: RefCell<Option<Function>> = const { RefCell::new(None) };
    }

    #[wasm_bindgen]
    pub fn wasm_render_web_audio(frames: u32) -> Float32Array {
        let safe_frames = frames.clamp(64, 16384);
        let devices = {
            let Ok(mut devs) = devices_registry().try_lock() else {
                return Float32Array::new_with_length((safe_frames * 2) as u32);
            };
            devs.retain(|d| d.is_alive());
            devs.clone()
        };

        let out_channels = devices
            .iter()
            .find(|d| d.is_active())
            .map(|d| d.channels)
            .unwrap_or(2)
            .clamp(1, 8);
        let total_samples = (safe_frames * out_channels) as usize;

        RENDER_BUFFERS.with(|cell| {
            let mut bufs = cell.borrow_mut();
            let (ref mut scratch_buf, ref mut mix_buf) = *bufs;
            mix_buf.clear();
            mix_buf.resize(total_samples, 0.0);

            for dev in &devices {
                if !dev.is_active() || dev.user_data_addr == 0 {
                    continue;
                }
                let ch = dev.channels.clamp(1, 8) as usize;
                let dev_samples = (safe_frames as usize) * ch;

                unsafe {
                    let renderer = &mut *(dev.user_data_addr
                        as *mut crate::core::output_manager::OutputDeviceRenderer);
                    let avail = renderer.consumer.slots();
                    let max_latency = 8192 * ch;
                    let target_cushion = 4096 * ch;
                    if avail > max_latency {
                        if let Ok(chunk) = renderer.consumer.read_chunk(avail - target_cushion) {
                            chunk.commit_all();
                        }
                    }
                    let avail = renderer.consumer.slots();
                    if dev.prebuffering.load(Ordering::Relaxed) {
                        if avail < dev_samples + (2048 * ch) {
                            continue;
                        }
                        dev.prebuffering.store(false, Ordering::Relaxed);
                    } else if avail < dev_samples {
                        dev.prebuffering.store(true, Ordering::Relaxed);
                        continue;
                    }

                    scratch_buf.clear();
                    scratch_buf.resize(dev_samples, 0.0);
                    rust_render_pcm_frames(
                        dev.user_data_addr as *mut c_void,
                        scratch_buf.as_mut_ptr(),
                        safe_frames,
                    );
                }

                if dev.channels == out_channels {
                    for (dst, src) in mix_buf.iter_mut().zip(scratch_buf.iter()) {
                        *dst = (*dst + *src).clamp(-1.0, 1.0);
                    }
                }
            }

            Float32Array::from(mix_buf.as_slice())
        })
    }

    /// Synchronously fetches an asset or HTTP audio source inside a Web Worker.
    pub fn wasm_fetch_source_bytes(
        source: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
    ) -> Result<Vec<u8>, i32> {
        let func = SYNC_FETCH_FN.with(|cell| {
            let mut slot = cell.borrow_mut();
            if slot.is_none() {
                let code = r#"
                    var raw = String(src || '').trim();
                    if (!raw) return -2;
                    if (raw.indexOf('data:') === 0) {
                        try {
                            var comma = raw.indexOf(',');
                            if (comma < 0) return -6;
                            var meta = raw.substring(0, comma);
                            var payload = raw.substring(comma + 1);
                            if (meta.indexOf(';base64') >= 0) {
                                var bin = atob(payload);
                                var out = new Uint8Array(bin.length);
                                for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
                                return out;
                            }
                            return new TextEncoder().encode(decodeURIComponent(payload));
                        } catch (_) {
                            return -6;
                        }
                    }
                    var origin = (self.location && self.location.origin && self.location.origin !== 'null')
                        ? self.location.origin
                        : '';
                    var resolveAssetUrl = function(rel) {
                        var clean = rel.replace(/^\/+/, '');
                        var encoded = clean.split('/').map(function(seg) {
                            return seg.replace(/#/g, '%23');
                        }).join('/');
                        return origin ? (origin + '/' + encoded) : encoded;
                    };
                    var candidates = [];
                    if (raw.indexOf('icy://') === 0) {
                        candidates.push('http://' + raw.substring(6));
                    } else if (raw.indexOf('http://') === 0 || raw.indexOf('https://') === 0 || raw.indexOf('blob:') === 0) {
                        candidates.push(raw);
                    } else {
                        var stripped = raw;
                        if (stripped.indexOf('asset:///') === 0) stripped = stripped.substring(9);
                        else if (stripped.indexOf('asset://') === 0) stripped = stripped.substring(8);
                        else if (stripped.indexOf('file:///') === 0) stripped = stripped.substring(8);
                        else if (stripped.indexOf('file://') === 0) stripped = stripped.substring(7);
                        stripped = stripped.replace(/^\/+/, '');
                        if (stripped.indexOf('assets/') === 0) {
                            candidates.push(resolveAssetUrl('assets/' + stripped));
                            candidates.push(resolveAssetUrl(stripped));
                        } else {
                            candidates.push(resolveAssetUrl(stripped));
                            candidates.push(resolveAssetUrl('assets/' + stripped));
                        }
                    }
                    for (var c = 0; c < candidates.length; c++) {
                        try {
                            var xhr = new XMLHttpRequest();
                            xhr.open('GET', candidates[c], false);
                            xhr.responseType = 'arraybuffer';
                            if (hdrs && hdrs.length) {
                                for (var h = 0; h < hdrs.length; h++) {
                                    var kv = hdrs[h];
                                    if (kv && kv.length >= 2) {
                                        var k = String(kv[0] || '');
                                        if (k.toLowerCase() !== 'icy-metadata') {
                                            try { xhr.setRequestHeader(k, String(kv[1] || '')); } catch (_) {}
                                        }
                                    }
                                }
                            }
                            xhr.send(null);
                            if (xhr.status >= 200 && xhr.status < 300 && xhr.response) {
                                var u8 = new Uint8Array(xhr.response);
                                if (u8.byteLength > 0) return u8;
                            }
                        } catch (_) {}
                    }
                    return -5;
                "#;
                *slot = Some(Function::new_with_args("src, hdrs", code));
            }
            slot.clone().unwrap()
        });

        let headers_arr = Array::new();
        if let Some(hdrs) = headers {
            for h in hdrs {
                let pair = Array::new();
                pair.push(&JsValue::from_str(&h.key));
                pair.push(&JsValue::from_str(&h.value));
                headers_arr.push(&pair);
            }
        }

        let res = func
            .call2(
                &JsValue::NULL,
                &JsValue::from_str(source),
                &headers_arr.into(),
            )
            .map_err(|_| MAP_ERROR_FILE_NOT_FOUND)?;

        if let Some(err_code) = res.as_f64() {
            let code = err_code as i32;
            return Err(if code < 0 {
                code
            } else {
                MAP_ERROR_FILE_NOT_FOUND
            });
        }

        if let Ok(u8_arr) = res.dyn_into::<Uint8Array>() {
            let vec = u8_arr.to_vec();
            if vec.is_empty() {
                Err(MAP_ERROR_FILE_NOT_FOUND)
            } else {
                Ok(vec)
            }
        } else {
            Err(MAP_ERROR_FILE_NOT_FOUND)
        }
    }

    pub unsafe fn map_device_create(
        _sample_rate: u32,
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
        let state = Arc::new(WasmDeviceState {
            channels: ch,
            user_data_addr: rust_user_data as usize,
            alive: AtomicBool::new(true),
            active: AtomicBool::new(false),
            prebuffering: AtomicBool::new(true),
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
        _sample_rate: u32,
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
            channels: channels.clamp(1, 8),
            user_data_addr: 0,
            alive: AtomicBool::new(false),
            active: AtomicBool::new(false),
            prebuffering: AtomicBool::new(true),
        });
        Arc::into_raw(state) as *mut MapDeviceContext
    }

    pub unsafe fn map_device_start(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let state = &*(ctx as *const WasmDeviceState);
            state.prebuffering.store(true, Ordering::Relaxed);
            state.active.store(true, Ordering::Relaxed);
        }
        MAP_SUCCESS
    }

    pub unsafe fn map_device_stop(ctx: *mut MapDeviceContext) -> i32 {
        if !ctx.is_null() {
            let state = &*(ctx as *const WasmDeviceState);
            state.active.store(false, Ordering::Relaxed);
            state.prebuffering.store(true, Ordering::Relaxed);
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
