pub mod bridge;
pub mod buffer;
pub mod core;
pub mod decoder;
pub mod dsp;
pub mod sync;

use std::os::raw::c_char;
use std::panic::catch_unwind;

pub use bridge::ffi::*;
pub use buffer::{BufferError, BufferRange, BufferState, TripartiteBuffer};

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
                *out_result = MAP_SUCCESS;
            }
            ptr
        }
        Err(_) => {
            if !out_result.is_null() {
                *out_result = MAP_ERROR_ENGINE_INIT;
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_destroy(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        drop(Box::from_raw(handle));
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_open_stream_ex(
    handle: *mut MiniaudioPlayerHandle,
    initial_data: *const u8,
    initial_data_size: usize,
    tail_data: *const u8,
    tail_data_size: usize,
    total_size: i64,
    is_live: i32,
    buffer_capacity_bytes: u32,
    _encoding_format: i32,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || initial_data.is_null() || initial_data_size == 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        let tot = if total_size > 0 { Some(total_size as u64) } else { None };
        let live = is_live != 0;
        let cap = if buffer_capacity_bytes > 0 { buffer_capacity_bytes as usize } else { TripartiteBuffer::DEFAULT_RING_CAPACITY };

        let buf = TripartiteBuffer::new(cap, tot, live);
        let head_slice = std::slice::from_raw_parts(initial_data, initial_data_size);
        let _ = buf.feed_chunk(head_slice);

        if !tail_data.is_null() && tail_data_size > 0 {
            let tail_slice = std::slice::from_raw_parts(tail_data, tail_data_size);
            buf.set_tail(tail_slice, None);
        }

        player.coordinator.buffer = buf;
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_DECODE_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_feed(
    handle: *mut MiniaudioPlayerHandle,
    data: *const u8,
    size: usize,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || data.is_null() || size == 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        let slice = std::slice::from_raw_parts(data, size);
        match player.coordinator.buffer.feed_chunk(slice) {
            Ok(_) => MAP_SUCCESS,
            Err(BufferError::Busy) => MAP_ERROR_BUSY,
            Err(_) => MAP_ERROR_INVALID_STATE,
        }
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_flush(
    handle: *mut MiniaudioPlayerHandle,
    new_stream_offset: i64,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || new_stream_offset < 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        player.coordinator.buffer.flush(new_stream_offset as u64);
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_seek(
    handle: *mut MiniaudioPlayerHandle,
    _position_ms: i64,
    new_stream_offset: i64,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || new_stream_offset < 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        let (is_hit, contiguous) = player.coordinator.buffer.try_seek_cached(new_stream_offset as u64);
        if is_hit {
            if contiguous { 1 /* CACHE_HIT */ } else { 2 /* CACHE_HIT_PREFETCH */ }
        } else {
            player.coordinator.buffer.flush(new_stream_offset as u64);
            0 /* CACHE_MISS */
        }
    });
    result.unwrap_or(MAP_ERROR_SEEK_FAILED)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_get_seek_byte(
    handle: *const MiniaudioPlayerHandle,
    _position_ms: i64,
) -> i64 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return -1;
        }
        let player = &*handle;
        player.coordinator.buffer.audio_start() as i64
    });
    result.unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_audio_data_offset(
    handle: *const MiniaudioPlayerHandle,
) -> i64 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return 0;
        }
        let player = &*handle;
        player.coordinator.buffer.audio_start() as i64
    });
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_end(
    handle: *mut MiniaudioPlayerHandle,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        player.coordinator.buffer.mark_eof();
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stream_get_pinned_head_size(
    handle: *const MiniaudioPlayerHandle,
) -> i64 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return 0;
        }
        let player = &*handle;
        player.coordinator.buffer.audio_start() as i64
    });
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_buffered_range(
    handle: *const MiniaudioPlayerHandle,
    out_range: *mut MiniaudioBufferedRange,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || out_range.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &*handle;
        let r = player.coordinator.buffer.get_range();
        let target = &mut *out_range;
        target.start_ms = r.start_byte;
        target.end_ms = r.end_byte;
        target.duration_ms = r.total_bytes;
        target.fill_percentage = r.fill_percentage;
        target.stream_percentage = r.stream_percentage;
        target.is_buffering = r.is_buffering;
        target.is_eof = r.is_eof;
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_meta_bytes_version(
    handle: *const MiniaudioPlayerHandle,
) -> u32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return 0;
        }
        let player = &*handle;
        player.coordinator.buffer.meta_version()
    });
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_meta_bytes_size(
    handle: *const MiniaudioPlayerHandle,
) -> usize {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return 0;
        }
        let player = &*handle;
        player.coordinator.buffer.get_meta_bytes().len()
    });
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_copy_meta_bytes(
    handle: *const MiniaudioPlayerHandle,
    out_buffer: *mut u8,
    max_len: usize,
) -> usize {
    let result = catch_unwind(|| {
        if handle.is_null() || out_buffer.is_null() || max_len == 0 {
            return 0;
        }
        let player = &*handle;
        let slice = std::slice::from_raw_parts_mut(out_buffer, max_len);
        player.coordinator.buffer.copy_meta_bytes(slice)
    });
    result.unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_set_icy_meta(
    handle: *mut MiniaudioPlayerHandle,
    data: *const u8,
    size: usize,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || data.is_null() || size == 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        let slice = std::slice::from_raw_parts(data, size);
        player.coordinator.buffer.set_icy_meta(slice);
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_probe_tail(
    handle: *mut MiniaudioPlayerHandle,
    tail_data: *const u8,
    tail_size: usize,
    tail_offset: i64,
) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() || tail_data.is_null() || tail_size == 0 || tail_offset < 0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        let player = &mut *handle;
        let slice = std::slice::from_raw_parts(tail_data, tail_size);
        player.coordinator.buffer.probe_tail(slice, tail_offset as u64);
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_play(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_pause(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_stop(handle: *mut MiniaudioPlayerHandle) -> i32 {
    let result = catch_unwind(|| {
        if handle.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        MAP_SUCCESS
    });
    result.unwrap_or(MAP_ERROR_GENERIC)
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_duration_ms(_handle: *const MiniaudioPlayerHandle) -> i64 {
    0
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_get_bitrate(_handle: *const MiniaudioPlayerHandle) -> i32 {
    0
}

#[no_mangle]
pub unsafe extern "C" fn miniaudio_player_is_completed(_handle: *const MiniaudioPlayerHandle) -> i32 {
    0
}
