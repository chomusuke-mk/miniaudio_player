//! Core Domain Invariants, Typestate Transitions, Real-Time Renderer, Recording, and Player Lifecycle Tests.

mod common;

use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering,
};
use std::sync::Arc;
use std::time::Duration;

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::buffer::MemoryByteSource;
use miniaudio_player::core::config::PlayerConfig;
use miniaudio_player::core::dual_source::{StreamingDeck, STATE_PLAYING};
use miniaudio_player::core::recording::{offline_bounce_to_wav, LiveRecorder, WavFormat};
use miniaudio_player::core::renderer::{
    audio_renderer_notif_trampoline, audio_renderer_render_trampoline, AudioRenderer,
    PcmRendererHeader,
};
use miniaudio_player::core::types::{Decibels, PlayerError, SampleRate, Volume};
use miniaudio_player::core::typestate::Player;
use miniaudio_player::dsp::chain::DspChain;
use miniaudio_player::dsp::sonic::SonicStream;
use miniaudio_player::dsp::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor};
use miniaudio_player::dsp::visualizer::VisualizerData;
use miniaudio_player::sync::ring_buffer::AudioRingBuffer;
use miniaudio_player::sync::seqlock::CachePaddedSeqlock;

#[test]
fn test_domain_types_and_typestate_transitions() {
    assert!(SampleRate::new(44100).is_ok());
    assert!(SampleRate::new(48000).is_ok());
    assert_eq!(SampleRate::new(0), Err(PlayerError::InvalidArgs));
    assert_eq!(SampleRate::new(500000), Err(PlayerError::InvalidArgs));

    assert!(Volume::new(1.0).is_ok());
    assert_eq!(Volume::new(-0.1), Err(PlayerError::InvalidArgs));
    assert_eq!(Volume::new(f32::NAN), Err(PlayerError::InvalidArgs));
    assert_eq!(Volume::clamp(3.5).get(), 3.5);

    let unity = Volume::new(1.0).unwrap();
    let zero_db = Decibels::from_linear(unity);
    assert!((zero_db.get() - 0.0).abs() < 0.001);
    assert!((zero_db.to_linear().get() - 1.0).abs() < 0.001);

    let config = PlayerConfig {
        sample_rate: 44100,
        channels: 2,
        period_size: 1024,
    };
    let player = Player::new(config);
    let open_player = player.open(MemoryByteSource::new(vec![0u8; 1024])).unwrap();
    let mut active_player = open_player.play().unwrap();
    active_player.set_volume(Volume::new(1.5).unwrap());
    let paused_player = active_player.pause();
    let active_player2 = paused_player.resume();
    let stopped_player = active_player2.stop();
    let closed_player = stopped_player.close();
    assert_eq!(closed_player.config().channels, 2);
}

#[test]
fn test_audio_renderer_instant_rate_and_pitch_response() {
    let dev_sr = 48000u32;
    let dev_ch = 2usize;
    let (mut producer, consumer) = AudioRingBuffer::create(dev_sr as usize * dev_ch * 2);

    let pcm = SignalGenerator::sine_wave_f32(48000, dev_sr, dev_ch, 440.0);
    producer.write_chunk(&pcm);

    let (_, cmd_consumer) = rtrb::RingBuffer::new(64);
    let state = Arc::new(AtomicI32::new(STATE_PLAYING));
    let rate = Arc::new(AtomicU32::new(1.0f32.to_bits()));
    let position_ms = Arc::new(AtomicI64::new(0));

    let mut renderer = AudioRenderer {
        deck_id: 1,
        header: PcmRendererHeader {
            render_fn: audio_renderer_render_trampoline,
            notif_fn: audio_renderer_notif_trampoline,
        },
        consumer,
        cmd_consumer,
        state: state.clone(),
        sample_rate: Arc::new(AtomicU32::new(dev_sr)),
        channels: Arc::new(AtomicU32::new(dev_ch as u32)),
        device_sample_rate: Arc::new(AtomicU32::new(dev_sr)),
        device_channels: Arc::new(AtomicU32::new(dev_ch as u32)),
        volume: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        rate: rate.clone(),
        pitch: Arc::new(AtomicU32::new(1.0f32.to_bits())),
        position_frames: Arc::new(AtomicI64::new(0)),
        position_ms: position_ms.clone(),
        duration_ms: Arc::new(AtomicI64::new(10000)),
        decoder_eof: Arc::new(AtomicBool::new(false)),
        seek_request_ms: Arc::new(AtomicI64::new(-1)),
        is_stream: Arc::new(AtomicBool::new(false)),
        flush_generation: Arc::new(AtomicU64::new(0)),
        flush_acknowledged: Arc::new(AtomicU64::new(0)),
        local_flush_gen: 0,
        completed_flag: Arc::new(AtomicBool::new(false)),
        buffering_flag: Arc::new(AtomicBool::new(false)),
        buffering_resumed_flag: Arc::new(AtomicBool::new(false)),
        dsp: DspChain::new(dev_ch, dev_sr),
        sonic: SonicStream::new(dev_sr, dev_ch),
        sonic_in_buf: vec![0.0f32; 16384],
        visualizer_seqlock: Arc::new(CachePaddedSeqlock::new(VisualizerData::default())),
        visualizer_enabled: Arc::new(AtomicBool::new(false)),
        spatial: SpatialProcessor::default(),
        listener: SpatialListener::default(),
        emitter: SpatialEmitter::default(),
        notification_callback: None,
    };

    let frame_count = 480usize; // 10 ms at 48 kHz
    let mut out_slice = vec![0.0f32; frame_count * dev_ch];

    renderer.render_pcm(out_slice.as_mut_ptr(), frame_count);
    assert_eq!(position_ms.load(Ordering::Relaxed), 10);

    rate.store(2.0f32.to_bits(), Ordering::Relaxed);
    renderer.render_pcm(out_slice.as_mut_ptr(), frame_count);
    let pos_after_2x = position_ms.load(Ordering::Relaxed);
    assert!(pos_after_2x >= 28 && pos_after_2x <= 32);
}

#[test]
fn test_offline_bounce_and_live_recorder_wav_writer() {
    let bounce_path = FixtureResolver::scratch_file_path("test_bounce.wav");
    let bounce_str = bounce_path.to_str().unwrap();

    let samples = vec![0.5f32, -0.5f32, 0.25f32, -0.25f32];
    let bytes_written =
        offline_bounce_to_wav(bounce_str, &samples, 48000, 2, WavFormat::Pcm16).unwrap();
    assert_eq!(bytes_written, 8);
    assert_eq!(std::fs::metadata(&bounce_path).unwrap().len(), 52);
    let _ = std::fs::remove_file(&bounce_path);

    let live_path = FixtureResolver::scratch_file_path("test_live_rec.wav");
    let live_str = live_path.to_str().unwrap();

    let (mut producer, consumer) = rtrb::RingBuffer::new(1024);
    let mut recorder = LiveRecorder::new(44100, 2, WavFormat::Pcm16);
    recorder.start(live_str, consumer).unwrap();
    assert!(recorder.is_recording());

    let frames = [0.1f32, -0.1f32, 0.2f32, -0.2f32];
    if let Ok(mut chunk) = producer.write_chunk(frames.len()) {
        let (s1, s2) = chunk.as_mut_slices();
        s1.copy_from_slice(&frames[..s1.len()]);
        if !s2.is_empty() {
            s2.copy_from_slice(&frames[s1.len()..]);
        }
        chunk.commit_all();
    }

    std::thread::sleep(Duration::from_millis(50));
    let recorded_bytes = recorder.stop().unwrap();
    assert_eq!(recorded_bytes, 8);
    assert!(!recorder.is_recording());
    assert_eq!(std::fs::metadata(&live_path).unwrap().len(), 52);
    let _ = std::fs::remove_file(&live_path);
}

#[test]
fn test_player_coordinator_lifecycle_on_manifest_fixtures() {
    let files = [
        "salida.flac",
        "cbr_noxing.mp3",
        "salida.wv",
        "salida.webm",
        "salida.mka",
        "salida.dsf",
        "salida.ape",
    ];

    let coordinator_res = StreamingDeck::new(
        48000,
        2,
        1024,
    );

    if let Ok(mut player) = coordinator_res {
        for file_name in &files {
            let path = FixtureResolver::resolve_str(file_name);
            let ret = player.open_file(&path);
            assert_eq!(ret, 0, "open_file failed for {}: {}", file_name, ret);
            assert!(player.channels.load(Ordering::Relaxed) > 0);
            assert!(player.sample_rate.load(Ordering::Relaxed) > 0);

            assert_eq!(player.play(), 0);
            assert_eq!(player.seek(2000), 0);
            player.pause();
            player.stop();
        }
    }
}

#[test]
fn test_dual_source_set_queue_universal_play_and_crossfade_target_id_abort() {
    use miniaudio_player::core::dual_source::{
        AudioSourceCore, DualSource, ENGINE_PHASE_AUTO_CROSSFADING,
    };

    if let Ok(mut dual) = DualSource::new(48000, 2, 1024) {
        let wav_path = FixtureResolver::resolve_str("salida.wav");
        let items = vec![
            AudioSourceCore {
                id: 101,
                source: wav_path.clone(),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
            },
            AudioSourceCore {
                id: 102,
                source: wav_path.clone(),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
            },
            AudioSourceCore {
                id: 103,
                source: wav_path,
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
            },
        ];

        dual.set_queue(items);
        // Before play(), current_index is -1 (null on Dart side)
        assert_eq!(dual.current_index.load(Ordering::SeqCst), -1);
        let q_ids: Vec<i64> = dual.queue.read().unwrap().iter().map(|i| i.id).collect();
        assert_eq!(q_ids, vec![101, 102, 103]);

        // Universal play by id = 102
        assert!(dual.play(Some(102), None, None, Some(500)).is_ok());
        assert_eq!(dual.current_index.load(Ordering::SeqCst), 1);

        // Simulate active auto-crossfade targeting id 103, then mutate queue to remove index 2 (id 103)
        dual.crossfade_target_id.store(103, Ordering::SeqCst);
        dual.crossfade.begin(0, 1, 48000, 0);
        dual.phase
            .store(ENGINE_PHASE_AUTO_CROSSFADING, Ordering::SeqCst);
        assert!(dual.remove_item_at(2).is_some());
        // Removing target track must abort active crossfade and reset crossfade_target_id
        assert!(!dual.crossfade.is_active.load(Ordering::SeqCst));
        assert_eq!(dual.crossfade_target_id.load(Ordering::SeqCst), -1);

        dual.deck_a.stop();
        dual.deck_b.stop();
    }
}
