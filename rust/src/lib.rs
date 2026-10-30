pub mod bridge;
pub mod buffer;
pub mod core;
pub mod decoder;
pub mod dsp;
pub mod sync;

use std::ffi::{c_char, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;

pub use bridge::ffi::*;
pub use buffer::{BufferError, BufferRange, BufferState, TripartiteBuffer};
pub use core::*;
pub use dsp::analysis::*;

// Type aliases matching C headers
#[allow(non_camel_case_types)]
pub type miniaudio_player_t = core::PlayerCoordinator;

#[allow(non_camel_case_types)]
#[repr(C)]
pub struct miniaudio_player_config_t {
    pub sample_rate: u32,
    pub channels: u32,
    pub period_size_in_frames: u32,
    pub playback_device_id: *const c_char,
    pub on_completed: Option<CompletionCallback>,
    pub user_data: *mut c_void,
}

static LOG_LEVEL: AtomicI32 = AtomicI32::new(3); // MAP_LOG_LEVEL_INFO

/* ========================================================================= */
/* Public Lifecycle API                                                      */
/* ========================================================================= */

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_create(
    config: *const miniaudio_player_config_t,
    out_result: *mut i32,
) -> *mut miniaudio_player_t {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let (sr, ch, period, dev_id, cb, udata) = if !config.is_null() {
            let c = &*config;
            (
                c.sample_rate,
                c.channels,
                c.period_size_in_frames,
                c.playback_device_id,
                c.on_completed,
                c.user_data,
            )
        } else {
            (44100, 2, 1024, std::ptr::null(), None, std::ptr::null_mut())
        };

        match PlayerCoordinator::new(sr, ch, period, dev_id, cb, udata) {
            Ok(coordinator) => {
                if !out_result.is_null() {
                    *out_result = MAP_SUCCESS;
                }
                Box::into_raw(coordinator)
            }
            Err(code) => {
                if !out_result.is_null() {
                    *out_result = code;
                }
                std::ptr::null_mut()
            }
        }
    }));

    result.unwrap_or_else(|_| {
        if !out_result.is_null() {
            *out_result = MAP_ERROR_ENGINE_INIT;
        }
        std::ptr::null_mut()
    })
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_destroy(player: *mut miniaudio_player_t) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).telemetry.stop();
        if let Ok(mut cb) = (*player).completion_cb.write() {
            *cb = None;
        }
        drop(Box::from_raw(player));
        MAP_SUCCESS
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_event_callback(
    player: *mut miniaudio_player_t,
    callback: Option<sync::telemetry::EventCallback>,
    user_data: *mut c_void,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_event_callback(callback, user_data)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

/* ========================================================================= */
/* Media Loading                                                             */
/* ========================================================================= */

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_begin_open(player: *mut miniaudio_player_t) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).begin_open()
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_open_file(
    player: *mut miniaudio_player_t,
    file_path: *const c_char,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || file_path.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let c_str = CStr::from_ptr(file_path);
        let path = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return MAP_ERROR_INVALID_ARGS,
        };
        (*player).open_file(path)
    }));
    result.unwrap_or(MAP_ERROR_DECODE_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_open_memory(
    player: *mut miniaudio_player_t,
    data: *const c_void,
    size: usize,
    take_ownership: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || data.is_null() || size == 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let slice = std::slice::from_raw_parts(data as *const u8, size);
        let ret = (*player).open_memory(slice, take_ownership != 0);
        if take_ownership != 0 {
            libc_free(data as *mut c_void);
        }
        ret
    }));
    result.unwrap_or(MAP_ERROR_DECODE_FAILED)
}

unsafe fn libc_malloc(size: usize) -> *mut c_void {
    extern "C" {
        fn malloc(s: usize) -> *mut c_void;
    }
    malloc(size)
}

unsafe fn libc_free(ptr: *mut c_void) {
    extern "C" {
        fn free(p: *mut c_void);
    }
    if !ptr.is_null() {
        free(ptr);
    }
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_open_stream(
    player: *mut miniaudio_player_t,
    initial_data: *const u8,
    initial_data_size: usize,
    total_size: i64,
    is_live: i32,
    buffer_capacity_bytes: u32,
    encoding_format: i32,
) -> i32 {
    miniaudio_player_open_stream_ex(
        player,
        initial_data,
        initial_data_size,
        std::ptr::null(),
        0,
        total_size,
        is_live,
        buffer_capacity_bytes,
        encoding_format,
    )
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_open_stream_ex(
    player: *mut miniaudio_player_t,
    initial_data: *const u8,
    initial_data_size: usize,
    tail_data: *const u8,
    tail_data_size: usize,
    total_size: i64,
    is_live: i32,
    buffer_capacity_bytes: u32,
    encoding_format: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let initial_slice = if !initial_data.is_null() && initial_data_size > 0 {
            std::slice::from_raw_parts(initial_data, initial_data_size)
        } else {
            &[]
        };

        let tail_slice = if !tail_data.is_null() && tail_data_size > 0 {
            Some(std::slice::from_raw_parts(tail_data, tail_data_size))
        } else {
            None
        };

        (*player).open_stream_ex(
            initial_slice,
            tail_slice,
            total_size,
            is_live != 0,
            buffer_capacity_bytes as usize,
            encoding_format,
        )
    }));
    result.unwrap_or(MAP_ERROR_DECODE_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_feed(
    player: *mut miniaudio_player_t,
    data: *const u8,
    size: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || data.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let slice = std::slice::from_raw_parts(data, size);
        (*player).stream_feed(slice)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_flush(
    player: *mut miniaudio_player_t,
    new_stream_offset: i64,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).stream_flush(new_stream_offset)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_seek(
    player: *mut miniaudio_player_t,
    position_ms: i64,
    new_stream_offset: i64,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).stream_seek(position_ms, new_stream_offset)
    }));
    result.unwrap_or(MAP_ERROR_SEEK_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_get_seek_byte(
    player: *const miniaudio_player_t,
    position_ms: i64,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return -1;
        }
        (*player).stream_get_seek_byte(position_ms)
    }));
    result.unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_audio_data_offset(
    player: *const miniaudio_player_t,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).get_audio_data_offset()
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_end(player: *mut miniaudio_player_t) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).stream_end()
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_get_pinned_head_size(
    player: *const miniaudio_player_t,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).stream_get_pinned_head_size()
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_buffered_range(
    player: *const miniaudio_player_t,
    out_range: *mut MiniaudioBufferedRange,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_range.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).get_buffered_range(&mut *out_range)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_get_status(
    player: *mut miniaudio_player_t,
    out_status: *mut MiniaudioStreamStatus,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_status.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).stream_get_status(&mut *out_status)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_meta_bytes_version(
    player: *const miniaudio_player_t,
) -> u32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).get_meta_bytes_version()
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_meta_bytes_size(
    player: *const miniaudio_player_t,
) -> usize {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).get_meta_bytes_size()
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_copy_meta_bytes(
    player: *const miniaudio_player_t,
    out_buffer: *mut u8,
    max_len: usize,
) -> usize {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_buffer.is_null() || max_len == 0 {
            return 0;
        }
        let slice = std::slice::from_raw_parts_mut(out_buffer, max_len);
        (*player).copy_meta_bytes(slice)
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_icy_meta(
    player: *mut miniaudio_player_t,
    data: *const u8,
    size: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || data.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let slice = std::slice::from_raw_parts(data, size);
        (*player).set_icy_meta(slice)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_probe_tail(
    player: *mut miniaudio_player_t,
    tail_data: *const u8,
    tail_size: usize,
    tail_offset: i64,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || tail_data.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let slice = std::slice::from_raw_parts(tail_data, tail_size);
        (*player).probe_tail(slice, tail_offset)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_read_pcm_frames(
    player: *mut miniaudio_player_t,
    frames_out: *mut c_void,
    frame_count: u32,
    out_frames_read: *mut u32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || frames_out.is_null() || out_frames_read.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).read_pcm_frames(frames_out as *mut f32, frame_count, out_frames_read)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

/* ========================================================================= */
/* Playback Controls                                                         */
/* ========================================================================= */

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_play(player: *mut miniaudio_player_t) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).play()
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_pause(player: *mut miniaudio_player_t) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).pause()
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stop(player: *mut miniaudio_player_t) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).stop()
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_seek(
    player: *mut miniaudio_player_t,
    position_ms: i64,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).seek(position_ms)
    }));
    result.unwrap_or(MAP_ERROR_SEEK_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_volume(
    player: *mut miniaudio_player_t,
    volume: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_volume(volume)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_rate(
    player: *mut miniaudio_player_t,
    rate: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_rate(rate)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_pitch(
    player: *mut miniaudio_player_t,
    pitch: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_pitch(pitch)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_buffer_size(
    player: *mut miniaudio_player_t,
    buffer_size_in_frames: u32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_buffer_size(buffer_size_in_frames)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_buffer_size(
    player: *const miniaudio_player_t,
) -> u32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).get_buffer_size()
    }));
    result.unwrap_or(0)
}

/* ========================================================================= */
/* Audio Device Management                                                   */
/* ========================================================================= */

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_devices(
    out_devices: *mut *mut MapDeviceInfo,
    out_count: *mut u32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        map_device_enumerate_devices(out_devices, out_count)
    }));
    result.unwrap_or(MAP_ERROR_ENGINE_INIT)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_free_devices(
    devices: *mut MapDeviceInfo,
    _count: u32,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        map_device_free_devices(devices);
    }));
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_device(
    player: *mut miniaudio_player_t,
    device_id: *const c_char,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_device(device_id)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_current_device(
    player: *const miniaudio_player_t,
    out_device: *mut MapDeviceInfo,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_device.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).get_current_device(&mut *out_device)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_pause_on_device_change(
    player: *mut miniaudio_player_t,
    enabled: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_pause_on_device_change(enabled)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_pause_on_device_change(
    player: *const miniaudio_player_t,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).get_pause_on_device_change()
    }));
    result.unwrap_or(0)
}

pub type DeviceNotificationCallback = unsafe extern "C" fn(user_data: *mut c_void);

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_device_notification_callback(
    _on_device_notification: Option<DeviceNotificationCallback>,
    _user_data: *mut c_void,
) {
    // Delegado al canal de eventos de TelemetryDispatcher
}

/* ========================================================================= */
/* Equalizer & DSP Controls                                                  */
/* ========================================================================= */

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_equalizer(
    player: *mut miniaudio_player_t,
    equalizer: *const dsp::EqualizerParams,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || equalizer.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_equalizer(&*equalizer)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_equalizer_band(
    player: *mut miniaudio_player_t,
    band_index: u32,
    gain_db: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_equalizer_band(band_index, gain_db)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_equalizer(
    player: *const miniaudio_player_t,
    out_equalizer: *mut dsp::EqualizerParams,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_equalizer.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).get_equalizer(&mut *out_equalizer)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_replay_gain(
    player: *mut miniaudio_player_t,
    gain_db: f32,
    peak: f32,
    prevent_clipping: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_replay_gain(gain_db, peak, prevent_clipping)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_clear_replay_gain(
    player: *mut miniaudio_player_t,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).clear_replay_gain()
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_preamp(
    player: *mut miniaudio_player_t,
    preamp_db: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_preamp(preamp_db)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_balance(
    player: *mut miniaudio_player_t,
    pan: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_balance(pan)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_mono(
    player: *mut miniaudio_player_t,
    enabled: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_mono(enabled)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_crossfeed(
    player: *mut miniaudio_player_t,
    mode: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_crossfeed(mode)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_spatializer(
    player: *mut miniaudio_player_t,
    enabled: i32,
    width: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_spatializer(enabled, width)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_reverb(
    player: *mut miniaudio_player_t,
    enabled: i32,
    room_size: f32,
    damping: f32,
    width: f32,
    wet: f32,
    dry: f32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_reverb(enabled, room_size, damping, width, wet, dry)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_limiter(
    player: *mut miniaudio_player_t,
    enabled: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_limiter(enabled)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_silence_config(
    player: *mut miniaudio_player_t,
    config: *const dsp::SilenceConfig,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || config.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_silence_config(&*config)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_silence_config(
    player: *const miniaudio_player_t,
    out_config: *mut dsp::SilenceConfig,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_config.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).get_silence_config(&mut *out_config)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_silence_saved_ms(
    player: *const miniaudio_player_t,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).get_silence_saved_ms()
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_visualizer_enabled(
    player: *mut miniaudio_player_t,
    enabled: i32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).set_visualizer_enabled(enabled)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_is_visualizer_enabled(
    player: *const miniaudio_player_t,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).is_visualizer_enabled()
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_visualizer_data(
    player: *const miniaudio_player_t,
    out_data: *mut dsp::VisualizerData,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_data.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).get_visualizer_data(&mut *out_data)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

/* ========================================================================= */
/* Status & Query Inspection                                                 */
/* ========================================================================= */

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_status(
    player: *const miniaudio_player_t,
    out_status: *mut MiniaudioPlayerStatus,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() || out_status.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        (*player).get_status(&mut *out_status)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_position_ms(
    player: *const miniaudio_player_t,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).position_ms.load(Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_duration_ms(
    player: *const miniaudio_player_t,
) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).duration_ms.load(Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_is_playing(
    player: *const miniaudio_player_t,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        ((*player).state.load(Ordering::Relaxed) == STATE_PLAYING) as i32
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_is_completed(
    player: *const miniaudio_player_t,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        ((*player).state.load(Ordering::Relaxed) == STATE_COMPLETED) as i32
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_volume(
    player: *const miniaudio_player_t,
) -> f32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0.0;
        }
        f32::from_bits((*player).volume.load(Ordering::Relaxed))
    }));
    result.unwrap_or(0.0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_rate(
    player: *const miniaudio_player_t,
) -> f32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 1.0;
        }
        f32::from_bits((*player).rate.load(Ordering::Relaxed))
    }));
    result.unwrap_or(1.0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_pitch(
    player: *const miniaudio_player_t,
) -> f32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 1.0;
        }
        f32::from_bits((*player).pitch.load(Ordering::Relaxed))
    }));
    result.unwrap_or(1.0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_bitrate(
    player: *const miniaudio_player_t,
) -> u32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).bitrate.load(Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_sample_rate(
    player: *const miniaudio_player_t,
) -> u32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).sample_rate.load(Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_channels(
    player: *const miniaudio_player_t,
) -> u32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if player.is_null() {
            return 0;
        }
        (*player).channels.load(Ordering::Relaxed)
    }));
    result.unwrap_or(0)
}

/* ========================================================================= */
/* Unified Audio Analysis                                                    */
/* ========================================================================= */

pub type AnalysisCompletedCallback =
    unsafe extern "C" fn(result: *const AudioAnalysisResult, user_data: *mut c_void);

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_analyze_audio(
    file_path: *const c_char,
    config: *const AudioAnalysisConfig,
    out_result: *mut AudioAnalysisResult,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if file_path.is_null() || out_result.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let c_str = CStr::from_ptr(file_path);
        let path = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return MAP_ERROR_INVALID_ARGS,
        };
        let cfg = if !config.is_null() {
            *config
        } else {
            AudioAnalysisConfig::default()
        };

        match analyze_file(path, &cfg) {
            Ok(res) => {
                *out_result = res;
                MAP_SUCCESS
            }
            Err(code) => code,
        }
    }));
    result.unwrap_or(MAP_ERROR_DECODE_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_analyze_audio_memory(
    data: *const c_void,
    data_size: usize,
    config: *const AudioAnalysisConfig,
    out_result: *mut AudioAnalysisResult,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if data.is_null() || data_size == 0 || out_result.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let slice = std::slice::from_raw_parts(data as *const u8, data_size);
        let cfg = if !config.is_null() {
            *config
        } else {
            AudioAnalysisConfig::default()
        };

        match analyze_memory(slice, &cfg) {
            Ok(res) => {
                *out_result = res;
                MAP_SUCCESS
            }
            Err(code) => code,
        }
    }));
    result.unwrap_or(MAP_ERROR_DECODE_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_analyze_audio_async(
    file_path: *const c_char,
    config: *const AudioAnalysisConfig,
    on_completed: Option<AnalysisCompletedCallback>,
    user_data: *mut c_void,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if file_path.is_null() || on_completed.is_none() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let c_str = CStr::from_ptr(file_path);
        let path = match c_str.to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return MAP_ERROR_INVALID_ARGS,
        };
        let cfg = if !config.is_null() {
            *config
        } else {
            AudioAnalysisConfig::default()
        };

        let udata_addr = user_data as usize;
        let cb = on_completed.unwrap();

        thread::Builder::new()
            .name("map-analysis".to_string())
            .spawn(move || {
                let udata = udata_addr as *mut c_void;
                let res = match analyze_file(&path, &cfg) {
                    Ok(r) => r,
                    Err(code) => AudioAnalysisResult {
                        status: code,
                        ..Default::default()
                    },
                };
                unsafe {
                    let heap_result = libc_malloc(std::mem::size_of::<AudioAnalysisResult>()) as *mut AudioAnalysisResult;
                    if !heap_result.is_null() {
                        std::ptr::write(heap_result, res);
                        cb(heap_result, udata);
                    }
                }
            })
            .map(|_| MAP_SUCCESS)
            .unwrap_or(MAP_ERROR_GENERIC)
    }));
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_free_audio_analysis(
    result: *mut AudioAnalysisResult,
    free_struct: i32,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !result.is_null() {
            free_analysis_result(&mut *result);
            if free_struct != 0 {
                libc_free(result as *mut c_void);
            }
        }
    }));
}

/* ========================================================================= */
/* Logging Configuration                                                     */
/* ========================================================================= */

#[no_mangle]
pub extern "C" fn miniaudio_player_set_log_level(level: i32) {
    LOG_LEVEL.store(level, Ordering::Relaxed);
}

#[no_mangle]
pub extern "C" fn miniaudio_player_get_log_level() -> i32 {
    LOG_LEVEL.load(Ordering::Relaxed)
}
