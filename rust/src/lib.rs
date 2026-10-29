pub mod bridge;
pub mod buffer;
pub mod core;
pub mod decoder;
pub mod dsp;
pub mod sync;

use std::os::raw::c_char;
use std::panic::catch_unwind;

pub struct MiniaudioPlayerHandle {
    pub coordinator: core::PlayerCoordinator,
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_create(
    sample_rate: u32,
    channels: u32,
    period_size_in_frames: u32,
    _playback_device_id: *const c_char,
    out_result: *mut i32,
) -> *mut MiniaudioPlayerHandle {
    let result = catch_unwind(|| {
        let config = core::PlayerConfig {
            sample_rate: if sample_rate > 0 { sample_rate } else { 44100 },
            channels: if channels > 0 { channels } else { 2 },
            period_size: if period_size_in_frames > 0 { period_size_in_frames } else { 1024 },
        };
        let coordinator = core::PlayerCoordinator::new(config);
        Box::into_raw(Box::new(MiniaudioPlayerHandle { coordinator }))
    });

    match result {
        Ok(ptr) => {
            if !out_result.is_null() {
                *out_result = 0;
            }
            ptr
        }
        Err(_) => {
            if !out_result.is_null() {
                *out_result = -1;
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_destroy(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return -2; /* INVALID_ARGS */
        }
        drop(Box::from_raw(handle));
        0
    });
    result.unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_play(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return -2;
        }
        0
    });
    result.unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_pause(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return -2;
        }
        0
    });
    result.unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stop(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return -2;
        }
        0
    });
    result.unwrap_or(-1)
}
