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

extern "C" {
    pub fn map_device_create(
        sample_rate: u32,
        channels: u32,
        period_size_in_frames: u32,
        playback_device_id: *const c_char,
        rust_user_data: *mut c_void,
        out_result: *mut i32,
    ) -> *mut MapDeviceContext;

    pub fn map_device_start(ctx: *mut MapDeviceContext) -> i32;
    pub fn map_device_stop(ctx: *mut MapDeviceContext) -> i32;
    pub fn map_device_destroy(ctx: *mut MapDeviceContext) -> i32;
    pub fn map_device_get_sample_rate(ctx: *const MapDeviceContext) -> u32;
    pub fn map_device_get_channels(ctx: *const MapDeviceContext) -> u32;
    pub fn map_device_set_device(ctx: *mut MapDeviceContext, device_id: *const c_char) -> i32;
}

#[no_mangle]
pub unsafe extern "C" fn rust_render_pcm_frames(
    _user_data: *mut c_void,
    _output_frames: *mut f32,
    _frame_count: u32,
) {
    // Renderizado implementado en etapas posteriores
}

#[no_mangle]
pub unsafe extern "C" fn rust_on_device_notification(
    _user_data: *mut c_void,
    _notification_type: i32,
) {
    // Notificaciones de hardware implementadas en etapas posteriores
}
