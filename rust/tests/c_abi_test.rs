use std::ffi::c_void;

use miniaudio_player::core::{MiniaudioPlayerStatus, STATE_PAUSED};
use miniaudio_player::dsp::analysis::{AudioAnalysisConfig, AudioAnalysisResult};
use miniaudio_player::dsp::equalizer::EqualizerParams;
use miniaudio_player::*;

fn generate_test_wav(sample_rate: u32, channels: u16, duration_ms: u32) -> Vec<u8> {
    let num_samples = (sample_rate * duration_ms / 1000) * (channels as u32);
    let mut data = Vec::with_capacity((num_samples * 2 + 44) as usize);

    data.extend_from_slice(b"RIFF");
    let riff_size = 36 + num_samples * 2;
    data.extend_from_slice(&riff_size.to_le_bytes());
    data.extend_from_slice(b"WAVE");

    data.extend_from_slice(b"fmt ");
    data.extend_from_slice(&16u32.to_le_bytes());
    data.extend_from_slice(&1u16.to_le_bytes()); // PCM
    data.extend_from_slice(&channels.to_le_bytes());
    data.extend_from_slice(&sample_rate.to_le_bytes());
    let byte_rate = sample_rate * (channels as u32) * 2;
    data.extend_from_slice(&byte_rate.to_le_bytes());
    let block_align = channels * 2;
    data.extend_from_slice(&block_align.to_le_bytes());
    data.extend_from_slice(&16u16.to_le_bytes()); // 16-bit

    data.extend_from_slice(b"data");
    let data_size = num_samples * 2;
    data.extend_from_slice(&data_size.to_le_bytes());

    for i in 0..num_samples {
        let t = i as f32 / sample_rate as f32;
        let sample = (t * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.5;
        let val = (sample * 32767.0) as i16;
        data.extend_from_slice(&val.to_le_bytes());
    }

    data
}

#[test]
fn test_c_abi_lifecycle_and_playback() {
    let mut result = -1;
    let player = unsafe { miniaudio_player_create(std::ptr::null(), &mut result) };
    assert_eq!(result, MAP_SUCCESS);
    assert!(!player.is_null());

    let wav = generate_test_wav(44100, 2, 500); // 500ms audio
    let open_res = unsafe {
        miniaudio_player_open_memory(player, wav.as_ptr() as *const c_void, wav.len(), 0)
    };
    assert_eq!(open_res, MAP_SUCCESS);

    let mut status = unsafe { std::mem::zeroed::<MiniaudioPlayerStatus>() };
    let status_res = unsafe { miniaudio_player_get_status(player, &mut status) };
    assert_eq!(status_res, MAP_SUCCESS);
    assert_eq!(status.sample_rate, 44100);
    assert_eq!(status.channels, 2);
    assert!(status.duration_ms >= 490 && status.duration_ms <= 510);
    assert_eq!(status.state, STATE_PAUSED);

    // Playback
    assert_eq!(unsafe { miniaudio_player_play(player) }, MAP_SUCCESS);
    assert_eq!(unsafe { miniaudio_player_is_playing(player) }, 1);

    // Render some frames
    let mut render_buf = [0.0f32; 1024];
    let mut frames_read = 0;
    let read_res = unsafe {
        miniaudio_player_read_pcm_frames(
            player,
            render_buf.as_mut_ptr() as *mut c_void,
            512,
            &mut frames_read,
        )
    };
    assert_eq!(read_res, MAP_SUCCESS);
    assert_eq!(frames_read, 512);

    // Volume & Pitch
    assert_eq!(unsafe { miniaudio_player_set_volume(player, 0.75) }, MAP_SUCCESS);
    assert!((unsafe { miniaudio_player_get_volume(player) } - 0.75).abs() < 1e-4);

    assert_eq!(unsafe { miniaudio_player_set_rate(player, 1.25) }, MAP_SUCCESS);
    assert!((unsafe { miniaudio_player_get_rate(player) } - 1.25).abs() < 1e-4);

    // Equalizer
    let mut eq_params = EqualizerParams::default();
    eq_params.hz1k = 3.5;
    assert_eq!(unsafe { miniaudio_player_set_equalizer(player, &eq_params) }, MAP_SUCCESS);

    let mut read_eq = EqualizerParams::default();
    assert_eq!(unsafe { miniaudio_player_get_equalizer(player, &mut read_eq) }, MAP_SUCCESS);
    assert!((read_eq.hz1k - 3.5).abs() < 1e-4);

    // Pause & Stop
    assert_eq!(unsafe { miniaudio_player_pause(player) }, MAP_SUCCESS);
    assert_eq!(unsafe { miniaudio_player_is_playing(player) }, 0);

    assert_eq!(unsafe { miniaudio_player_stop(player) }, MAP_SUCCESS);
    assert_eq!(unsafe { miniaudio_player_get_position_ms(player) }, 0);

    // Clean destruction
    assert_eq!(unsafe { miniaudio_player_destroy(player) }, MAP_SUCCESS);
}

#[test]
fn test_c_abi_analysis_memory() {
    let wav = generate_test_wav(44100, 2, 200); // 200ms audio
    let config = AudioAnalysisConfig::default();
    let mut result = AudioAnalysisResult::default();

    let res = unsafe {
        miniaudio_player_analyze_audio_memory(
            wav.as_ptr() as *const c_void,
            wav.len(),
            &config,
            &mut result,
        )
    };
    assert_eq!(res, MAP_SUCCESS);
    assert_eq!(result.status, 0);
    assert_eq!(result.sample_rate, 44100);
    assert_eq!(result.channels, 2);
    assert_eq!(result.has_replay_gain, 1);
    assert_eq!(result.has_waveform, 1);
    assert_eq!(result.waveform.point_count, 100);

    unsafe {
        miniaudio_player_free_audio_analysis(&mut result, 0);
    }
    assert_eq!(result.has_waveform, 0);
}
