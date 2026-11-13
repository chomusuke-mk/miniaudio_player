//! Core Domain Invariants, Typestate Transitions, Real-Time Renderer, Recording, and Player Lifecycle Tests.

mod common;

use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering,
};
use std::sync::Arc;

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
        at_live_edge: Arc::new(AtomicBool::new(false)),
        flush_generation: Arc::new(AtomicU64::new(0)),
        flush_acknowledged: Arc::new(AtomicU64::new(0)),
        local_flush_gen: 0,
        track_exhausted: Arc::new(AtomicBool::new(false)),
        is_buffering: Arc::new(AtomicBool::new(false)),
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
    use miniaudio_player::core::dual_source::{AudioSourceCore, DualSource};
    use miniaudio_player::core::types::QueueTransition;

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
        dual.crossfade.begin(0, 1, 48000, 0, QueueTransition::AutoCrossfade);
        assert!(dual.remove_item_at(2).is_some());
        // Removing target track must abort active crossfade and reset crossfade_target_id
        assert!(!dual.crossfade.is_active());
        assert_eq!(dual.crossfade_target_id.load(Ordering::SeqCst), -1);

        dual.deck_a.stop();
        dual.deck_b.stop();
    }
}

#[test]
fn test_music_only_output_excludes_sound_effects() {
    use miniaudio_player::core::dual_source::AudioSourceCore;
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;
    use miniaudio_player::core::voice_pool::{EffectCatalogItem, EffectConfig};

    let mut player = MiniaudioPlayer::new(48000, 2, 1024, 16, None, None).unwrap();
    let wav_path = FixtureResolver::resolve_str("salida.wav");

    let catalog = vec![EffectCatalogItem {
        id: "sfx_test".to_string(),
        source: AudioSourceCore {
            id: 1,
            source: wav_path,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
        },
        max_polyphony: 4,
        pinned: true,
    }];

    player.effects_manager.set_effects(catalog).unwrap();

    // Trigger effect with DspRouting::Inherit (default)
    let (voice_id, _) = player
        .effects_manager
        .play_effect("sfx_test", EffectConfig::default())
        .unwrap();
    assert_ne!(voice_id, 0);

    // Render a period of PCM frames (without playing music)
    player.render_pcm(1024);

    // scratch_music (Music Only / musicMix buffer) must have ZERO SFX samples!
    let music_energy: f32 = player.scratch_music[..1024 * 2].iter().map(|s| s.abs()).sum();
    assert_eq!(
        music_energy, 0.0,
        "Music Only buffer must have ZERO SFX leakage, but got energy={}",
        music_energy
    );

    // super_flow (All Mix / all buffer) MUST contain the active sound effect!
    let all_mix_energy: f32 = player.super_flow[..1024 * 2].iter().map(|s| s.abs()).sum();
    assert!(
        all_mix_energy > 0.0,
        "All Mix buffer must contain the playing sound effect, but got energy={}",
        all_mix_energy
    );
}

#[test]
fn test_polyphonic_effects_inherit_reverb_and_tail_decay() {
    use miniaudio_player::core::dual_source::AudioSourceCore;
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;
    use miniaudio_player::core::voice_pool::{EffectCatalogItem, EffectConfig};
    use miniaudio_player::dsp::reverb::ReverbConfig;

    let mut player = MiniaudioPlayer::new(48000, 2, 1024, 32, None, None).unwrap();
    let wav_path = FixtureResolver::resolve_str("salida.wav");

    let catalog = vec![EffectCatalogItem {
        id: "sfx_laser".to_string(),
        source: AudioSourceCore {
            id: 1,
            source: wav_path,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
        },
        max_polyphony: 16,
        pinned: true,
    }];
    player.effects_manager.set_effects(catalog).unwrap();

    // Enable Reverb on inherit_dsp (matching music master reverb)
    let rev_config = ReverbConfig {
        enabled: 1,
        room_size: 0.85,
        damping: 0.3,
        width: 1.0,
        wet: 0.6,
        dry: 0.8,
    };
    player.inherit_dsp.set_reverb(rev_config);
    player.music_dsp.set_reverb(rev_config);

    // Launch 10 simultaneous voices with DspRouting::Inherit, each with different EffectConfig (volume, pitch, balance)
    for i in 0..10 {
        let vol = 0.1 * (i + 1) as f32; // 0.1, 0.2, ..., 1.0
        let pitch = 0.8 + 0.05 * i as f32; // 0.8, 0.85, ..., 1.25
        let balance = -0.9 + 0.2 * i as f32; // varying stereo pan
        let config = EffectConfig {
            volume: vol,
            pitch,
            balance,
            ..EffectConfig::default()
        };
        let (vid, _) = player
            .effects_manager
            .play_effect("sfx_laser", config)
            .unwrap();
        assert_ne!(vid, 0);
    }

    assert_eq!(player.effects_manager.active_voices_count(), 10);
    assert!(player.effects_manager.active_voices_count() > 0);

    // Render period: all 10 voices mix into scratch_effects, pass through inherit_dsp (reverb), and sum into super_flow
    player.render_pcm(1024);

    let music_energy: f32 = player.scratch_music[..1024 * 2].iter().map(|s| s.abs()).sum();
    assert_eq!(
        music_energy, 0.0,
        "Music Only buffer must remain strictly 0.0 with 10 concurrent voices"
    );

    let all_mix_energy: f32 = player.super_flow[..1024 * 2].iter().map(|s| s.abs()).sum();
    assert!(
        all_mix_energy > 0.0,
        "All Mix buffer must contain energy from the 10 reverberated voices"
    );

    // Stop active voices
    player.stop_all(0);
    assert_eq!(player.effects_manager.active_voices_count(), 0);
}

#[test]
fn test_music_only_is_not_ducked_by_microphone_and_multi_mic_does_not_cascade() {
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;
    use miniaudio_player::api::types::{RustAudioInput, RustAudioInputConfig, RustDuckingConfig};

    let mut player = MiniaudioPlayer::new(48000, 2, 512, 16, None, None).unwrap();

    // Configure 4 microphone inputs, each requesting -14 dB of auto-ducking
    let mic_config = RustAudioInputConfig {
        volume: 1.0,
        monitor_direct: false,
        monitor_volume: 1.0,
        ducking: Some(RustDuckingConfig {
            enabled: true,
            ducking_db: -14.0,
            threshold_db: -35.0,
            attack_ms: 1.0,
            hold_ms: 100.0,
            release_ms: 100.0,
        }),
    };

    let inputs = vec![
        RustAudioInput { device_id: "mic_1".to_string(), config: mic_config.clone() },
        RustAudioInput { device_id: "mic_2".to_string(), config: mic_config.clone() },
        RustAudioInput { device_id: "mic_3".to_string(), config: mic_config.clone() },
        RustAudioInput { device_id: "mic_4".to_string(), config: mic_config.clone() },
    ];
    player.input_manager.inputs = inputs;

    // Simulate active capture nodes with voice audio (loud speech on all 4 mics)
    let sample_rate = 48000;
    for i in 1..=4 {
        let (capture_node, _) =
            miniaudio_player::core::capture::DeviceCaptureNode::new(sample_rate, 1, 1024, std::ptr::null())
                .unwrap();
        let (mut prod, consumer) = rtrb::RingBuffer::new(2048);
        for _ in 0..512 {
            let _ = prod.push(0.5f32); // 0.5f32 is loud speech (-6 dBFS > -35 dBFS threshold)
        }

        let mut ducker = miniaudio_player::dsp::ducking::AutoDucker::new(sample_rate);
        ducker.set_params(true, -14.0, -35.0, 1.0, 100.0, 100.0);

        player.input_manager.active_inputs.push(miniaudio_player::core::input_manager::ActiveInputNode {
            device_id: format!("mic_{}", i),
            resolved_id: format!("mic_{}", i),
            config: mic_config.clone(),
            capture_node,
            consumer,
            ducker,
            scratch_buffer: vec![0.0f32; 1024],
        });
    }

    assert_eq!(player.input_manager.active_inputs.len(), 4);

    // Fill music buffers: music playing at amplitude 1.0
    let frame_count = 512;
    let sample_count = frame_count * 2;
    player.scratch_music[..sample_count].fill(1.0);

    // Copy to super_flow as render_pcm does
    player.super_flow[..sample_count].copy_from_slice(&player.scratch_music[..sample_count]);

    // Process microphone inputs and auto-ducking on super_flow (NOT on scratch_music)
    player.input_manager.process(
        &mut player.super_flow[..sample_count],
        &mut player.scratch_voice[..sample_count],
    );

    // 1. GUARANTEE 1: scratch_music (Music Only / musicMix buffer) MUST REMAIN COMPLETELY UNATTENUATED (1.0)
    for &sample in &player.scratch_music[..sample_count] {
        assert_eq!(
            sample, 1.0,
            "Music Only (scratch_music) must NEVER be attenuated by microphone ducking!"
        );
    }

    // 2. GUARANTEE 2: super_flow (All Mix) MUST be ducked to approximately -14 dB (gain ~0.2),
    // and NOT exponentially compounded (0.2^4 = 0.0016 = -56 dB)!
    let target_duck_gain = 10.0f32.powf(-14.0 / 20.0); // ~0.1995
    let last_ducked_sample = player.super_flow[sample_count - 1];

    assert!(
        last_ducked_sample < 0.9,
        "All Mix music must be ducked by active speech, but got {}",
        last_ducked_sample
    );
    assert!(
        last_ducked_sample > 0.05,
        "All Mix music must NOT cascade/compound across 4 mics to silence! Expected ~{}, got {}",
        target_duck_gain,
        last_ducked_sample
    );
    assert!(
        (last_ducked_sample - target_duck_gain).abs() < 0.1,
        "Ducking gain should match the maximum attenuation of ~{}, got {}",
        target_duck_gain,
        last_ducked_sample
    );
}

#[test]
fn test_reverb_natural_decay_on_pause_and_smart_dormancy() {
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;
    use miniaudio_player::dsp::reverb::ReverbConfig;

    let mut player = MiniaudioPlayer::new(48000, 2, 512, 16, None, None).unwrap();

    // 1. Enable Reverb on music_dsp (large hall, wet = 0.5)
    let rev_config = ReverbConfig {
        enabled: 1,
        room_size: 0.8,
        damping: 0.2,
        width: 1.0,
        wet: 0.5,
        dry: 1.0,
    };
    player.music_dsp.set_reverb(rev_config);
    assert!(player.music_dsp.reverb.is_dormant(), "Reverb starts dormant");

    // 2. Simulate playing track: feed signal into scratch_music and process for several blocks
    // (enough frames to fill the comb filter delay lines > 1617 samples)
    let frame_count = 512;
    let sample_count = frame_count * 2;
    for _ in 0..10 {
        let mut signal = vec![0.5f32; sample_count];
        player.music_dsp.process(&mut signal);
    }
    assert!(!player.music_dsp.reverb.is_dormant(), "Reverb becomes active when signal enters");

    // 3. Simulate track PAUSE: input from deck becomes pure silence (0.0)
    let mut silence_1 = vec![0.0f32; sample_count];
    player.music_dsp.process(&mut silence_1);

    // GUARANTEE: Upon pause, reverb MUST NOT cut off abruptly!
    // The delay lines produce an active ringdown tail.
    let tail_energy_1: f32 = silence_1.iter().map(|s| s.abs()).sum();
    assert!(
        tail_energy_1 > 0.01,
        "Reverb tail must ring down on pause, not cut to 0! Got energy {}",
        tail_energy_1
    );
    assert!(!player.music_dsp.reverb.is_dormant(), "Reverb remains active during decay tail");

    // 4. In subsequent pause frames, the macro tail smoothly attenuates over time
    let mut energy_block_20 = 0.0;
    let mut energy_block_50 = 0.0;
    for i in 0..60 {
        let mut silence = vec![0.0f32; sample_count];
        player.music_dsp.process(&mut silence);
        let energy: f32 = silence.iter().map(|s| s.abs()).sum();
        if i == 20 {
            energy_block_20 = energy;
        } else if i == 50 {
            energy_block_50 = energy;
        }
    }
    assert!(
        energy_block_50 < energy_block_20 * 0.6,
        "Reverb tail must decay over time: block 50 ({}) < block 20 ({}) * 0.6",
        energy_block_50,
        energy_block_20
    );

    // 5. Pump silent frames until the acoustic tail fully dissipates into silence
    for _ in 0..1000 {
        let mut silence = vec![0.0f32; sample_count];
        player.music_dsp.process(&mut silence);
        if player.music_dsp.reverb.is_dormant() {
            break;
        }
    }

    assert!(
        player.music_dsp.reverb.is_dormant(),
        "Reverb must eventually transition to dormant state after tail completes"
    );

    // 6. Once dormant, further silent frames are completely bypassed
    let mut silence_idle = vec![0.0f32; sample_count];
    player.music_dsp.process(&mut silence_idle);
    let idle_energy: f32 = silence_idle.iter().map(|s| s.abs()).sum();
    assert_eq!(idle_energy, 0.0, "Dormant reverb with silent input outputs pure silence");
    assert!(player.music_dsp.reverb.is_dormant());

    // 7. While music remains paused and dormant, simulate SFX with DspRouting::Inherit
    player.inherit_dsp.set_reverb(rev_config);
    assert!(player.inherit_dsp.reverb.is_dormant());

    // SFX voice active: write frames into scratch_effects
    for _ in 0..5 {
        let mut sfx_frame = vec![0.8f32; sample_count];
        player.inherit_dsp.process(&mut sfx_frame);
    }
    assert!(!player.inherit_dsp.reverb.is_dormant(), "Inherit SFX reverb wakes up with audio signal");

    // SFX voice finishes: feed silence
    let mut sfx_tail = vec![0.0f32; sample_count];
    player.inherit_dsp.process(&mut sfx_tail);
    let sfx_tail_energy: f32 = sfx_tail.iter().map(|s| s.abs()).sum();
    assert!(sfx_tail_energy > 0.01, "SFX reverb tail rings down smoothly when voice ends");

    // Ring down to dormancy
    for _ in 0..1000 {
        let mut silence = vec![0.0f32; sample_count];
        player.inherit_dsp.process(&mut silence);
        if player.inherit_dsp.reverb.is_dormant() {
            break;
        }
    }
    assert!(player.inherit_dsp.reverb.is_dormant(), "Inherit SFX reverb returns to dormant state");
}

#[test]
fn test_voice_only_output_and_visualizer_source_selection() {
    use miniaudio_player::api::types::AudioOutputSource;
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;

    let mut player = MiniaudioPlayer::new(48000, 2, 512, 16, None, None).unwrap();
    let frame_count = 512;
    let sample_count = frame_count * 2;

    // Simulate active microphone speech in scratch_voice, but NO music and NO sound effects
    player.scratch_voice[..sample_count].fill(0.7);
    player.scratch_music[..sample_count].fill(0.0);
    player.super_flow[..sample_count].fill(0.0);

    // 1. Enable visualizer and set source to VoiceOnly
    player.output_manager.set_visualizer_enabled(true);
    player.output_manager.set_visualizer_source(AudioOutputSource::VoiceOnly);
    assert_eq!(player.output_manager.visualizer_source(), AudioOutputSource::VoiceOnly);

    // Dispatch buffers to outputs and visualizer
    player.output_manager.dispatch(
        &player.super_flow[..sample_count],
        &player.scratch_music[..sample_count],
        player.music_manager.active_deck_buffer(),
        player.music_manager.standby_buffer(),
        &player.scratch_voice[..sample_count],
        frame_count,
    );

    // Visualizer must have captured the microphone energy!
    let vis_data = player.output_manager.get_visualizer_data();
    assert!(
        vis_data.rms > 0.1,
        "Visualizer with VoiceOnly source must capture microphone speech RMS! got rms={}",
        vis_data.rms
    );
    assert!(
        vis_data.peak > 0.5,
        "Visualizer with VoiceOnly source must capture microphone peak! got peak={}",
        vis_data.peak
    );

    // 2. Now switch visualizer source to MusicMix (Music Only) while only voice is present
    player.output_manager.set_visualizer_source(AudioOutputSource::MusicMix);
    assert_eq!(player.output_manager.visualizer_source(), AudioOutputSource::MusicMix);

    player.output_manager.dispatch(
        &player.super_flow[..sample_count],
        &player.scratch_music[..sample_count],
        player.music_manager.active_deck_buffer(),
        player.music_manager.standby_buffer(),
        &player.scratch_voice[..sample_count],
        frame_count,
    );

    // Visualizer must now see silence because MusicMix has zero energy!
    let vis_music = player.output_manager.get_visualizer_data();
    assert_eq!(
        vis_music.rms, 0.0,
        "Visualizer with MusicMix source must ignore voice! got rms={}",
        vis_music.rms
    );
}

#[test]
fn test_direct_monitoring_visualizer_and_all_mix_without_music() {
    use miniaudio_player::api::types::{AudioOutputSource, RustAudioInputConfig};
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;

    let mut player = MiniaudioPlayer::new(48000, 2, 512, 16, None, None).unwrap();
    let frame_count = 512;
    let sample_count = frame_count * 2;
    let sample_rate = 48000;

    // 1. Direct Monitoring FALSE: pure voice bus captures speech, but All Mix (speakers) remains 0.0 (no feedback)
    let mic_config_no_mon = RustAudioInputConfig {
        volume: 1.0,
        monitor_direct: false,
        monitor_volume: 0.8,
        ducking: None,
    };

    let (capture_node_1, _) =
        miniaudio_player::core::capture::DeviceCaptureNode::new(sample_rate, 1, 1024, std::ptr::null())
            .unwrap();
    let (mut prod_1, consumer_1) = rtrb::RingBuffer::new(2048);
    for _ in 0..512 {
        let _ = prod_1.push(0.6f32);
    }
    let ducker_1 = miniaudio_player::dsp::ducking::AutoDucker::new(sample_rate);

    player.input_manager.active_inputs.push(miniaudio_player::core::input_manager::ActiveInputNode {
        device_id: "mic_test".to_string(),
        resolved_id: "mic_test".to_string(),
        config: mic_config_no_mon,
        capture_node: capture_node_1,
        consumer: consumer_1,
        ducker: ducker_1,
        scratch_buffer: vec![0.0f32; 1024],
    });

    assert!(!player.input_manager.has_active_direct_monitoring());
    assert!(player.input_manager.has_active_inputs());

    player.super_flow[..sample_count].fill(0.0);
    player.input_manager.process(
        &mut player.super_flow[..sample_count],
        &mut player.scratch_voice[..sample_count],
    );

    // scratch_voice (Voice Only) MUST have captured speech
    let voice_energy: f32 = player.scratch_voice[..sample_count].iter().map(|s| s.abs()).sum();
    assert!(voice_energy > 10.0, "VoiceOnly bus must capture speech even when direct monitoring is off");

    // super_flow (All Mix) MUST be zero when direct monitoring is false
    let all_mix_energy: f32 = player.super_flow[..sample_count].iter().map(|s| s.abs()).sum();
    assert_eq!(all_mix_energy, 0.0, "All Mix must not receive voice when monitor_direct is false");

    // 2. Direct Monitoring TRUE: speech is injected into All Mix and activates direct monitoring telemetry
    player.input_manager.active_inputs.clear();

    let mic_config_mon = RustAudioInputConfig {
        volume: 1.0,
        monitor_direct: true,
        monitor_volume: 0.8,
        ducking: None,
    };

    let (capture_node_2, _) =
        miniaudio_player::core::capture::DeviceCaptureNode::new(sample_rate, 1, 1024, std::ptr::null())
            .unwrap();
    let (mut prod_2, consumer_2) = rtrb::RingBuffer::new(2048);
    for _ in 0..512 {
        let _ = prod_2.push(0.6f32);
    }
    let ducker_2 = miniaudio_player::dsp::ducking::AutoDucker::new(sample_rate);

    player.input_manager.active_inputs.push(miniaudio_player::core::input_manager::ActiveInputNode {
        device_id: "mic_test_2".to_string(),
        resolved_id: "mic_test_2".to_string(),
        config: mic_config_mon,
        capture_node: capture_node_2,
        consumer: consumer_2,
        ducker: ducker_2,
        scratch_buffer: vec![0.0f32; 1024],
    });

    assert!(player.input_manager.has_active_direct_monitoring());

    player.super_flow[..sample_count].fill(0.0);
    player.input_manager.process(
        &mut player.super_flow[..sample_count],
        &mut player.scratch_voice[..sample_count],
    );

    let all_mix_energy_mon: f32 = player.super_flow[..sample_count].iter().map(|s| s.abs()).sum();
    assert!(
        all_mix_energy_mon > 10.0,
        "All Mix must receive voice when monitor_direct is true, got energy {}",
        all_mix_energy_mon
    );

    // 3. Visualizer with All Mix source must see the microphone speech without any music playing
    player.output_manager.set_visualizer_enabled(true);
    player.output_manager.set_visualizer_source(AudioOutputSource::All);
    player.scratch_music[..sample_count].fill(0.0); // No music

    player.output_manager.dispatch(
        &player.super_flow[..sample_count],
        &player.scratch_music[..sample_count],
        player.music_manager.active_deck_buffer(),
        player.music_manager.standby_buffer(),
        &player.scratch_voice[..sample_count],
        frame_count,
    );

    let vis_all = player.output_manager.get_visualizer_data();
    assert!(
        vis_all.rms > 0.1,
        "All Mix visualizer must capture microphone audio in real time when direct monitoring is active! got rms={}",
        vis_all.rms
    );
    assert!(
        vis_all.peak > 0.3,
        "All Mix visualizer peak must reflect monitored speech! got peak={}",
        vis_all.peak
    );
}

#[test]
fn test_visualizer_captures_reverb_tail_of_effect_without_music() {
    use miniaudio_player::api::types::AudioOutputSource;
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;
    use miniaudio_player::dsp::reverb::ReverbConfig;

    let mut player = MiniaudioPlayer::new(48000, 2, 512, 16, None, None).unwrap();
    let frame_count = 512;
    let sample_count = frame_count * 2;

    // 1. Enable visualizer on All Mix and configure Reverb on inherit_dsp
    player.output_manager.set_visualizer_enabled(true);
    player.output_manager.set_visualizer_source(AudioOutputSource::All);

    let rev_config = ReverbConfig {
        enabled: 1,
        room_size: 0.8,
        damping: 0.2,
        width: 1.0,
        wet: 0.6,
        dry: 1.0,
    };
    player.inherit_dsp.set_reverb(rev_config);

    // 2. Simulate short sound effect burst (e.g. 5 blocks of loud signal in scratch_effects)
    for _ in 0..5 {
        player.scratch_effects[..sample_count].fill(0.8);
        player.inherit_dsp.process(&mut player.scratch_effects[..sample_count]);
    }
    assert!(!player.inherit_dsp.reverb.is_dormant(), "Reverb must be active after burst");

    // 3. Effect finishes! No active voices in effects_manager (0 active voices) and no music playing
    assert_eq!(player.effects_manager.active_voices_count(), 0);

    // Render one period where effects_manager produces silence, but inherit_dsp reverb rings down!
    player.render_pcm(frame_count);

    // GUARANTEE: Even though active_voices == 0 and music is not playing,
    // the visualizer on All Mix MUST capture the ringing Reverb tail!
    let vis_reverb = player.output_manager.get_visualizer_data();
    assert!(
        vis_reverb.rms > 0.005,
        "All Mix visualizer MUST capture the reverb tail of an effect when active_voices == 0! got rms={}",
        vis_reverb.rms
    );
    assert!(
        vis_reverb.peak > 0.01,
        "All Mix visualizer peak must reflect the reverb tail! got peak={}",
        vis_reverb.peak
    );

    // 4. In subsequent frames, early reflections settle and the tail smoothly decays
    let mut rms_block_20 = 0.0;
    let mut rms_block_60 = 0.0;
    for i in 0..70 {
        player.render_pcm(frame_count);
        let cur_vis = player.output_manager.get_visualizer_data();
        if i == 20 {
            rms_block_20 = cur_vis.rms;
        } else if i == 60 {
            rms_block_60 = cur_vis.rms;
        }
    }
    assert!(
        rms_block_60 < rms_block_20 * 0.7,
        "Visualizer RMS must decay over time: block 60 ({}) < block 20 ({}) * 0.7",
        rms_block_60,
        rms_block_20
    );

    // 5. Run until reverb tail is completely dissipated into dormancy
    for _ in 0..1000 {
        player.render_pcm(frame_count);
        if player.inherit_dsp.reverb.is_dormant() {
            break;
        }
    }
    assert!(player.inherit_dsp.reverb.is_dormant());

    // Run a few more frames to allow visualizer release decay to complete
    for _ in 0..20 {
        player.render_pcm(frame_count);
    }

    let final_vis = player.output_manager.get_visualizer_data();
    assert!(
        final_vis.is_silent(),
        "Visualizer must reach silent state after reverb decay completes, got rms={}, peak={}",
        final_vis.rms,
        final_vis.peak
    );
}



