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
    pub fn map_device_get_current_device_info(
        ctx: *const MapDeviceContext,
        out_device: *mut MapDeviceInfo,
    ) -> i32;

    pub fn map_device_enumerate_devices(
        out_devices: *mut *mut MapDeviceInfo,
        out_count: *mut u32,
    ) -> i32;
    pub fn map_device_free_devices(devices: *mut MapDeviceInfo);
}

#[no_mangle]
pub unsafe extern "C" fn rust_render_pcm_frames(
    user_data: *mut c_void,
    output_frames: *mut f32,
    frame_count: u32,
) {
    if !user_data.is_null() && !output_frames.is_null() && frame_count > 0 {
        let player = &mut *(user_data as *mut crate::core::PlayerCoordinator);
        player.render_pcm(output_frames, frame_count as usize);
    }
}

#[no_mangle]
pub unsafe extern "C" fn rust_on_device_notification(
    user_data: *mut c_void,
    notification_type: i32,
) {
    if !user_data.is_null() {
        let player = &mut *(user_data as *mut crate::core::PlayerCoordinator);
        player.on_device_notification(notification_type);
    }
}
