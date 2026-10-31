pub mod crypto;
pub mod m3u8_parser;
pub mod mpegts;

pub use crypto::Aes128SegmentDecryptor;
pub use m3u8_parser::{EncryptionKeyInfo, M3u8Parser, ParsedHlsPlaylist, SegmentInfo, VariantStreamInfo};
pub use mpegts::{MpegTsDemuxResult, MpegTsDemuxer, TsAudioCodec};

/// C-ABI exports for native high-performance HLS parsing, TS demuxing, and AES-128 decryption.

#[no_mangle]
pub unsafe extern "C" fn map_hls_is_m3u8(data: *const u8, len: usize) -> i32 {
    if data.is_null() || len == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    if M3u8Parser::is_m3u8(slice) {
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_hls_is_mpeg_ts(data: *const u8, len: usize) -> i32 {
    if data.is_null() || len == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    if MpegTsDemuxer::is_mpeg_ts(slice) {
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_hls_demux_ts(
    ts_data: *const u8,
    ts_len: usize,
    out_audio_data: *mut *mut u8,
    out_audio_len: *mut usize,
    out_codec: *mut i32,
) -> i32 {
    if ts_data.is_null() || out_audio_data.is_null() || out_audio_len.is_null() || out_codec.is_null() {
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts(ts_data, ts_len) };
    let result = MpegTsDemuxer::demux_segment(slice);

    let codec_id = match result.codec {
        TsAudioCodec::AacAdts => 1,
        TsAudioCodec::Mp3 => 2,
        TsAudioCodec::Ac3 => 3,
        TsAudioCodec::Unknown(_) => 0,
    };
    unsafe {
        *out_codec = codec_id;
    }

    if result.audio_bytes.is_empty() {
        unsafe {
            *out_audio_data = std::ptr::null_mut();
            *out_audio_len = 0;
        }
        return 0;
    }

    let mut boxed_slice = result.audio_bytes.into_boxed_slice();
    let ptr = boxed_slice.as_mut_ptr();
    let len = boxed_slice.len();
    std::mem::forget(boxed_slice);

    unsafe {
        *out_audio_data = ptr;
        *out_audio_len = len;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn map_hls_free_buffer(buf: *mut u8, len: usize) {
    if !buf.is_null() && len > 0 {
        unsafe {
            let slice_ptr = std::ptr::slice_from_raw_parts_mut(buf, len);
            drop(Box::from_raw(slice_ptr));
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn map_hls_decrypt_aes128(
    encrypted_data: *const u8,
    data_len: usize,
    key_16: *const u8,
    iv_16: *const u8,
    out_decrypted_data: *mut *mut u8,
    out_decrypted_len: *mut usize,
) -> i32 {
    if encrypted_data.is_null()
        || key_16.is_null()
        || iv_16.is_null()
        || out_decrypted_data.is_null()
        || out_decrypted_len.is_null()
    {
        return -1;
    }

    let enc_slice = unsafe { std::slice::from_raw_parts(encrypted_data, data_len) };
    let key_arr: &[u8; 16] = unsafe { &*(key_16 as *const [u8; 16]) };
    let iv_arr: &[u8; 16] = unsafe { &*(iv_16 as *const [u8; 16]) };

    match Aes128SegmentDecryptor::decrypt_segment(enc_slice, key_arr, iv_arr) {
        Ok(decrypted) => {
            if decrypted.is_empty() {
                unsafe {
                    *out_decrypted_data = std::ptr::null_mut();
                    *out_decrypted_len = 0;
                }
                return 0;
            }
            let mut boxed_slice = decrypted.into_boxed_slice();
            let ptr = boxed_slice.as_mut_ptr();
            let len = boxed_slice.len();
            std::mem::forget(boxed_slice);

            unsafe {
                *out_decrypted_data = ptr;
                *out_decrypted_len = len;
            }
            0
        }
        Err(_) => -2,
    }
}
