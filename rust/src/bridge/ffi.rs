use std::os::raw::{c_char, c_void};

pub enum MapDeviceContextOpaque {}
pub type MapDeviceContext = MapDeviceContextOpaque;

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
