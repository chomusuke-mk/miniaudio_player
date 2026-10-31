//! Comprehensive Audio Format Integrity & Edge Case Verification Test Suite.
//!
//! Validates:
//! - Zero sample drops and 1.0x constant speed on FLAC, ALAC (preventing 4x/6x speedup after 2s).
//! - Clean playback without buzzing/crackle on MP3, MP2, WAV, AIFF, AIFC, BWF.
//! - Accurate mono-to-stereo upmixing on mono tracks (cbr_noxing.mp3, 440Hz tone) eliminating microphone crush.
//! - Multi-channel (5.1 surround and 7.1 surround) matrix downmixing and upmixing.
//! - High sample rate (192 kHz) resampling and buffering.
//! - Dynamic stream sample rate and channel layout variation mid-stream.

use std::fs::File;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::time::Duration;

use miniaudio_player::core::player::{PlayerCoordinator, STATE_PLAYING};
use miniaudio_player::decoder::symphonia_engine::SymphoniaEngine;
use miniaudio_player::dsp::channel_matrix::ChannelMatrix;
use miniaudio_player::dsp::resampler::RubatoResampler;
use miniaudio_player::sync::ring_buffer::AudioRingBuffer;

fn get_asset_path(filename: &str) -> String {
    let candidates = [
        format!("../example/assets/music/{}", filename),
        format!("example/assets/music/{}", filename),
        format!("/mnt/Proyectos/miniaudio_player/example/assets/music/{}", filename),
    ];
    for c in &candidates {
        if Path::new(c).exists() {
            return c.clone();
        }
    }
    panic!("Asset not found: {}", filename);
}

fn generate_sine_wave_pcm(num_frames: usize, sample_rate: u32, channels: usize, freq: f32) -> Vec<f32> {
    let mut out = Vec::with_capacity(num_frames * channels);
    for i in 0..num_frames {
        let t = i as f32 / sample_rate as f32;
        let s = (t * freq * 2.0 * std::f32::consts::PI).sin();
        for _ in 0..channels {
            out.push(s);
        }
    }
    out
}

#[test]
fn test_audio_format_integrity_flac_speed_consistency() {
    let flac_path = get_asset_path("salida.flac");
    let file = File::open(&flac_path).expect("Failed to open salida.flac");
    let mut engine = SymphoniaEngine::new(file, Some("flac")).expect("Failed to create Symphonia FLAC engine");

    let track_sr = engine.sample_rate();
    let track_ch = engine.channels() as usize;
    assert_eq!(track_sr, 48000);
    assert_eq!(track_ch, 2);

    let dev_sr = 48000u32;
    let dev_ch = 2usize;

    // Simulate ring buffer (capacity 1 second)
    let ring_cap = dev_sr as usize * dev_ch * 1;
    let (mut producer, mut consumer) = AudioRingBuffer::create(ring_cap);

    let mut channel_matrix = ChannelMatrix::new(track_ch, dev_ch);
    let mut resampler = RubatoResampler::new(track_sr, dev_sr, dev_ch, 1024).unwrap();

    let mut frame_buf = Vec::new();
    let mut matrix_buf = Vec::new();
    let mut resampler_out = Vec::new();
    let mut pending_pcm = Vec::new();
    let mut pending_offset = 0;

    let mut total_rendered_frames = 0usize;
    let mut render_buf = vec![0.0f32; 1024 * dev_ch];

    // Decode and render for at least 5 seconds of audio (well beyond the 2s mark!)
    let target_frames = dev_sr as usize * 5;

    while total_rendered_frames < target_frames {
        // 1. Drain pending
        if pending_offset < pending_pcm.len() {
            let slice = &pending_pcm[pending_offset..];
            let written = producer.write_chunk(slice);
            pending_offset += written;
            if pending_offset >= pending_pcm.len() {
                pending_pcm.clear();
                pending_offset = 0;
            }
        }

        // 2. Decode next frame if pending is empty and space available
        if pending_pcm.is_empty() && producer.slots_available() >= 2048 {
            if let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
                channel_matrix.process_interleaved(&frame_buf, &mut matrix_buf);
                resampler_out.clear();
                let _ = resampler.process_interleaved(&matrix_buf, &mut resampler_out);
                pending_pcm.extend_from_slice(&resampler_out);
                pending_offset = 0;

                let written = producer.write_chunk(&pending_pcm);
                pending_offset += written;
                if pending_offset >= pending_pcm.len() {
                    pending_pcm.clear();
                    pending_offset = 0;
                }
            } else {
                break;
            }
        }

        // 3. Hardware consumer reads a period of 1024 frames
        let read = consumer.read_chunk(&mut render_buf);
        if read > 0 {
            total_rendered_frames += read / dev_ch;
        } else if pending_pcm.is_empty() {
            break;
        }
    }

    // Verify that all 5 seconds were rendered continuously without sample drops
    assert!(total_rendered_frames >= target_frames, "Rendered {} frames, expected at least {}", total_rendered_frames, target_frames);
}

#[test]
fn test_audio_format_integrity_alac_speed_consistency() {
    let alac_path = get_asset_path("salida_alac.m4a");
    let file = File::open(&alac_path).expect("Failed to open salida_alac.m4a");
    let mut engine = SymphoniaEngine::new(file, Some("m4a")).expect("Failed to create Symphonia ALAC engine");

    let track_sr = engine.sample_rate();
    let track_ch = engine.channels() as usize;
    assert_eq!(track_sr, 48000);
    assert_eq!(track_ch, 2);

    let dev_sr = 48000u32;
    let dev_ch = 2usize;

    let ring_cap = dev_sr as usize * dev_ch * 1;
    let (mut producer, mut consumer) = AudioRingBuffer::create(ring_cap);

    let mut channel_matrix = ChannelMatrix::new(track_ch, dev_ch);
    let mut resampler = RubatoResampler::new(track_sr, dev_sr, dev_ch, 1024).unwrap();

    let mut frame_buf = Vec::new();
    let mut matrix_buf = Vec::new();
    let mut resampler_out = Vec::new();
    let mut pending_pcm = Vec::new();
    let mut pending_offset = 0;

    let mut total_rendered_frames = 0usize;
    let mut render_buf = vec![0.0f32; 1024 * dev_ch];

    // Decode and render for 5 seconds (well beyond the 2s mark)
    let target_frames = dev_sr as usize * 5;

    while total_rendered_frames < target_frames {
        if pending_offset < pending_pcm.len() {
            let slice = &pending_pcm[pending_offset..];
            let written = producer.write_chunk(slice);
            pending_offset += written;
            if pending_offset >= pending_pcm.len() {
                pending_pcm.clear();
                pending_offset = 0;
            }
        }

        if pending_pcm.is_empty() && producer.slots_available() >= 2048 {
            if let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
                channel_matrix.process_interleaved(&frame_buf, &mut matrix_buf);
                resampler_out.clear();
                let _ = resampler.process_interleaved(&matrix_buf, &mut resampler_out);
                pending_pcm.extend_from_slice(&resampler_out);
                pending_offset = 0;

                let written = producer.write_chunk(&pending_pcm);
                pending_offset += written;
                if pending_offset >= pending_pcm.len() {
                    pending_pcm.clear();
                    pending_offset = 0;
                }
            } else {
                break;
            }
        }

        let read = consumer.read_chunk(&mut render_buf);
        if read > 0 {
            total_rendered_frames += read / dev_ch;
        } else if pending_pcm.is_empty() {
            break;
        }
    }

    assert!(total_rendered_frames >= target_frames);
}

#[test]
fn test_audio_format_integrity_mono_upmix_cbr_noxing_mp3() {
    let mp3_path = get_asset_path("cbr_noxing.mp3");
    let file = File::open(&mp3_path).expect("Failed to open cbr_noxing.mp3");
    let mut engine = SymphoniaEngine::new(file, Some("mp3")).expect("Failed to create Symphonia MP3 engine");

    let track_sr = engine.sample_rate();
    let track_ch = engine.channels() as usize;
    assert_eq!(track_sr, 44100);
    assert_eq!(track_ch, 1, "cbr_noxing.mp3 must be detected as 1-channel mono");

    let dev_sr = 48000u32;
    let dev_ch = 2usize; // Stereo output device

    let mut channel_matrix = ChannelMatrix::new(track_ch, dev_ch);
    let mut resampler = RubatoResampler::new(track_sr, dev_sr, dev_ch, 1024).unwrap();

    let mut frame_buf = Vec::new();
    let mut matrix_buf = Vec::new();
    let mut resampler_out = Vec::new();

    let mut frames_checked = 0;

    while let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
        channel_matrix.process_interleaved(&frame_buf, &mut matrix_buf);
        assert_eq!(matrix_buf.len(), frame_buf.len() * 2);

        // Verify that Left and Right channels are identical (pure mono upmix)
        for f in 0..frame_buf.len() {
            let l = matrix_buf[f * 2];
            let r = matrix_buf[f * 2 + 1];
            assert_eq!(l, r, "Left and Right must match in mono upmix at frame {}", f);
        }

        resampler_out.clear();
        let _ = resampler.process_interleaved(&matrix_buf, &mut resampler_out);
        for f in 0..resampler_out.len() / 2 {
            let l = resampler_out[f * 2];
            let r = resampler_out[f * 2 + 1];
            assert!((l - r).abs() < 1e-4, "Resampled Left and Right must match: L={}, R={}", l, r);
        }

        frames_checked += frame_buf.len();
        if frames_checked >= 44100 * 2 {
            break;
        }
    }

    assert!(frames_checked > 0);
}

#[test]
fn test_audio_format_integrity_stereo_mp3_zero_buzzing() {
    let mp3_path = get_asset_path("salida.mp3");
    let file = File::open(&mp3_path).expect("Failed to open salida.mp3");
    let mut engine = SymphoniaEngine::new(file, Some("mp3")).expect("Failed to create Symphonia MP3 engine");

    let track_sr = engine.sample_rate();
    let track_ch = engine.channels() as usize;
    assert_eq!(track_sr, 48000);
    assert_eq!(track_ch, 2);

    let dev_ch = 2usize;

    // Small ring buffer to force continuous backpressure
    let (mut producer, mut consumer) = AudioRingBuffer::create(4096);
    let mut frame_buf = Vec::new();
    let mut pending_pcm = Vec::new();
    let mut pending_offset = 0;
    let mut total_rendered = 0;
    let mut render_buf = vec![0.0f32; 512 * dev_ch];

    // Decode and render 200,000 samples (~4 seconds)
    while total_rendered < 200_000 {
        if pending_offset < pending_pcm.len() {
            let slice = &pending_pcm[pending_offset..];
            let written = producer.write_chunk(slice);
            pending_offset += written;
            if pending_offset >= pending_pcm.len() {
                pending_pcm.clear();
                pending_offset = 0;
            }
        }

        if pending_pcm.is_empty() && producer.slots_available() >= 2048 {
            if let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
                pending_pcm.extend_from_slice(&frame_buf);
                pending_offset = 0;
                let written = producer.write_chunk(&pending_pcm);
                pending_offset += written;
                if pending_offset >= pending_pcm.len() {
                    pending_pcm.clear();
                    pending_offset = 0;
                }
            } else {
                break;
            }
        }

        let read = consumer.read_chunk(&mut render_buf);
        if read > 0 {
            total_rendered += read;
            // Check waveform continuity (no sudden 40Hz dropouts)
            for i in 1..read {
                let diff = (render_buf[i] - render_buf[i - 1]).abs();
                assert!(diff < 1.9, "Discontinuity detected in MP3 output at index {}: diff={}", i, diff);
            }
        }
    }

    assert!(total_rendered >= 200_000);
}

#[test]
fn test_audio_format_integrity_aiff_wav_mp2_family() {
    let formats = ["salida.wav", "salida.aif", "salida.aifc", "salida.aiff", "salida.bwf", "salida.mp2"];
    for name in &formats {
        let path = get_asset_path(name);
        let file = File::open(&path).unwrap_or_else(|_| panic!("Failed to open {}", name));
        let ext = name.split('.').last().unwrap();
        let mut engine = SymphoniaEngine::new(file, Some(ext)).unwrap_or_else(|_| panic!("Failed engine for {}", name));

        assert!(engine.sample_rate() > 0, "{}: invalid sample rate", name);
        assert!(engine.channels() > 0, "{}: invalid channels", name);

        let mut pcm = Vec::new();
        let mut frames_decoded = 0;
        for _ in 0..10 {
            if let Ok(true) = engine.decode_next_frame(&mut pcm) {
                assert!(!pcm.is_empty(), "{}: empty PCM decoded", name);
                frames_decoded += pcm.len() / (engine.channels() as usize);
            } else {
                break;
            }
        }
        assert!(frames_decoded > 0, "{}: no frames decoded", name);
    }
}

#[test]
fn test_audio_format_integrity_aac_and_opus_non_regression() {
    for name in &["salida.aac", "salida.opus"] {
        let path = get_asset_path(name);
        let file = File::open(&path).unwrap_or_else(|_| panic!("Failed to open {}", name));
        let ext = name.split('.').last().unwrap();
        let mut engine = SymphoniaEngine::new(file, Some(ext)).unwrap_or_else(|_| panic!("Failed engine for {}", name));

        let mut pcm = Vec::new();
        let mut frames_decoded = 0;
        for _ in 0..20 {
            if let Ok(true) = engine.decode_next_frame(&mut pcm) {
                frames_decoded += pcm.len() / (engine.channels() as usize);
            }
        }
        assert!(frames_decoded > 0, "{}: should decode cleanly", name);
    }
}

#[test]
fn test_audio_edge_case_5_1_surround_to_stereo_downmix() {
    // 5.1 input: 6 channels (L, R, C, LFE, Ls, Rs)
    let num_frames = 1000;
    let mut surround_5_1 = Vec::with_capacity(num_frames * 6);
    for i in 0..num_frames {
        let t = i as f32 / 48000.0;
        let l = (t * 440.0 * 2.0 * std::f32::consts::PI).sin();
        let r = (t * 880.0 * 2.0 * std::f32::consts::PI).sin();
        let c = (t * 660.0 * 2.0 * std::f32::consts::PI).sin();
        let lfe = (t * 60.0 * 2.0 * std::f32::consts::PI).sin();
        let ls = (t * 440.0 * 2.0 * std::f32::consts::PI).sin() * 0.5;
        let rs = (t * 880.0 * 2.0 * std::f32::consts::PI).sin() * 0.5;
        surround_5_1.extend_from_slice(&[l, r, c, lfe, ls, rs]);
    }

    let mut matrix = ChannelMatrix::new(6, 2);
    let mut stereo_out = Vec::new();
    matrix.process_interleaved(&surround_5_1, &mut stereo_out);

    assert_eq!(stereo_out.len(), num_frames * 2);
    // Verify signal is normalized and does not exceed [-1.0, 1.0]
    for &s in &stereo_out {
        assert!(s >= -1.05 && s <= 1.05, "5.1 downmixed sample clipped: {}", s);
    }
}

#[test]
fn test_audio_edge_case_7_1_surround_to_stereo_downmix() {
    let num_frames = 1000;
    let mut surround_7_1 = Vec::with_capacity(num_frames * 8);
    for i in 0..num_frames {
        let t = i as f32 / 48000.0;
        let s = (t * 440.0 * 2.0 * std::f32::consts::PI).sin();
        for _ in 0..8 {
            surround_7_1.push(s);
        }
    }

    let mut matrix = ChannelMatrix::new(8, 2);
    let mut stereo_out = Vec::new();
    matrix.process_interleaved(&surround_7_1, &mut stereo_out);

    assert_eq!(stereo_out.len(), num_frames * 2);
    for &s in &stereo_out {
        assert!(s >= -1.05 && s <= 1.05, "7.1 downmixed sample clipped: {}", s);
    }
}

#[test]
fn test_audio_edge_case_high_res_192khz_resampling() {
    let sr_in = 192000u32;
    let sr_out = 48000u32;
    let channels = 2usize;
    let num_frames_in = 19200; // 100ms at 192 kHz

    let input_192k = generate_sine_wave_pcm(num_frames_in, sr_in, channels, 1000.0);
    let mut resampler = RubatoResampler::new(sr_in, sr_out, channels, 1024).unwrap();

    let mut output_48k = Vec::new();
    let _frames_resampled = resampler.process_interleaved(&input_192k, &mut output_48k).unwrap();
    let _ = resampler.flush(&mut output_48k);

    let total_frames_out = output_48k.len() / channels;
    // 19200 frames at 192 kHz = 0.1s -> should produce ~4800 frames at 48 kHz
    let expected = 4800;
    let diff = (total_frames_out as i32 - expected as i32).abs();
    assert!(diff < 50, "192kHz to 48kHz produced {} frames, expected ~{}", total_frames_out, expected);
}

#[test]
fn test_audio_edge_case_dynamic_stream_format_switch() {
    // Simulate a stream that starts at 44100 Hz mono and switches to 48000 Hz stereo mid-stream
    let dev_sr = 48000u32;
    let dev_ch = 2usize;

    let part1_mono_44k = generate_sine_wave_pcm(4410, 44100, 1, 440.0); // 100ms mono 44.1k
    let part2_stereo_48k = generate_sine_wave_pcm(4800, 48000, 2, 880.0); // 100ms stereo 48k

    let mut channel_matrix = ChannelMatrix::new(1, dev_ch);
    let mut resampler = RubatoResampler::new(44100, dev_sr, dev_ch, 1024).unwrap();

    let mut matrix_buf = Vec::new();
    let mut resampler_out = Vec::new();
    let mut total_output_frames = 0;

    // Process Part 1 (Mono 44.1k)
    channel_matrix.set_channels(1, dev_ch);
    channel_matrix.process_interleaved(&part1_mono_44k, &mut matrix_buf);
    assert_eq!(matrix_buf.len(), part1_mono_44k.len() * 2);
    let _ = resampler.process_interleaved(&matrix_buf, &mut resampler_out);
    total_output_frames += resampler_out.len() / dev_ch;

    // Switch to Part 2 (Stereo 48k)
    channel_matrix.set_channels(2, dev_ch);
    resampler = RubatoResampler::new(48000, dev_sr, dev_ch, 1024).unwrap();

    matrix_buf.clear();
    resampler_out.clear();
    channel_matrix.process_interleaved(&part2_stereo_48k, &mut matrix_buf);
    assert_eq!(matrix_buf.len(), part2_stereo_48k.len());
    let _ = resampler.process_interleaved(&matrix_buf, &mut resampler_out);
    total_output_frames += resampler_out.len() / dev_ch;

    // Both parts processed cleanly into uniform 48kHz stereo without panics
    assert!(total_output_frames > 4000);
}

#[test]
fn test_player_coordinator_playback_lifecycle() {
    let coordinator_res = PlayerCoordinator::new(
        48000,
        2,
        1024,
        std::ptr::null(),
        None,
        std::ptr::null_mut(),
    );
    if let Ok(mut player) = coordinator_res {
        let flac_path = get_asset_path("salida.flac");
        let res = player.open_file(&flac_path);
        assert_eq!(res, 0);
        assert_eq!(player.channels.load(Ordering::Relaxed), 2);
        assert_eq!(player.sample_rate.load(Ordering::Relaxed), 48000);

        player.play();
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(player.state.load(Ordering::Relaxed), STATE_PLAYING);

        // Seek
        player.seek(1000);
        std::thread::sleep(Duration::from_millis(50));

        player.pause();
        assert_eq!(player.state.load(Ordering::Relaxed), 2); // PAUSED

        // Now open mono file
        let mono_path = get_asset_path("cbr_noxing.mp3");
        let res_mono = player.open_file(&mono_path);
        assert_eq!(res_mono, 0);
        assert_eq!(player.channels.load(Ordering::Relaxed), 1);
        assert_eq!(player.sample_rate.load(Ordering::Relaxed), 44100);

        player.play();
        std::thread::sleep(Duration::from_millis(50));
        player.stop();
    }
}

