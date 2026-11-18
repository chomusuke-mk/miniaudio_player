//! Core Domain Invariants, Typestate Transitions, Real-Time Renderer, Recording, and Player Lifecycle Tests.

mod common;

use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering,
};
use std::sync::Arc;

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::core::dual_source::{StreamingDeck, STATE_PLAYING};
use miniaudio_player::core::recording::{LiveRecorder, WavFormat};
use miniaudio_player::core::renderer::{
    audio_renderer_notif_trampoline, audio_renderer_render_trampoline, AudioRenderer,
    PcmRendererHeader,
};
use miniaudio_player::dsp::chain::DspChain;
use miniaudio_player::dsp::sonic::SonicStream;
use miniaudio_player::dsp::visualizer::VisualizerData;
use miniaudio_player::sync::ring_buffer::AudioRingBuffer;
use miniaudio_player::sync::seqlock::CachePaddedSeqlock;


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
fn test_live_recorder_wav_writer() {
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
        "04_Belaya_Tishina.flac",
        "03_Before_The_Dawn_cbr_noxing.mp3",
        "09_Flesh_and_Chrome.wv",
        "13_Overture_for_the_Floor.webm",
        "11_Mar_de_cristal.mka",
        "29_駆け抜けて、この空を.dsf",
        "25_Velocity_of_One.ape",
    ];

    let coordinator_res = StreamingDeck::new_deck(
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
        let wav_path = FixtureResolver::resolve_str("17_Running_To_Meet_The_Sun.wav");
        let items = vec![
            AudioSourceCore {
                id: 101,
                source: wav_path.clone(),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            AudioSourceCore {
                id: 102,
                source: wav_path.clone(),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            AudioSourceCore {
                id: 103,
                source: wav_path,
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
        ];

        dual.append_items(items);
        // Before playback commit, current_index is -1 (null on Dart side)
        assert_eq!(dual.current_index.load(Ordering::SeqCst), -1);
        let q_ids: Vec<i64> = dual.queue.read().unwrap().iter().map(|i| i.id).collect();
        assert_eq!(q_ids, vec![101, 102, 103]);

        // Commit transition to id = 102
        let item_102 = dual.queue.read().unwrap()[1].clone();
        let mut deck_102 = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut deck_102,
                &item_102,
                None,
                None,
            ),
            0
        );
        let displaced = dual.commit_transition_internal(
            Some(deck_102),
            &item_102,
            None,
            miniaudio_player::core::dual_source_control::TransitionCommitMode::Manual {
                manual_crossfade_ms: Some(500),
                force_play: true,
            },
        );
        drop(displaced);
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
    let wav_path = FixtureResolver::resolve_str("17_Running_To_Meet_The_Sun.wav");

    let catalog = vec![EffectCatalogItem {
        id: "sfx_test".to_string(),
        source: AudioSourceCore {
            id: 1,
            source: wav_path,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
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

    // Render across initial 0.6s so real untrimmed intros register active SFX energy
    let mut music_energy = 0.0f32;
    let mut all_mix_energy = 0.0f32;
    for _ in 0..30 {
        player.render_pcm(1024);
        music_energy += player.scratch_music[..1024 * 2].iter().map(|s| s.abs()).sum::<f32>();
        all_mix_energy += player.super_flow[..1024 * 2].iter().map(|s| s.abs()).sum::<f32>();
    }

    // scratch_music (Music Only / musicMix buffer) must have ZERO SFX samples!
    assert_eq!(
        music_energy, 0.0,
        "Music Only buffer must have ZERO SFX leakage, but got energy={}",
        music_energy
    );

    // super_flow (All Mix / all buffer) MUST contain the active sound effect!
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
    let wav_path = FixtureResolver::resolve_str("17_Running_To_Meet_The_Sun.wav");

    let catalog = vec![EffectCatalogItem {
        id: "sfx_laser".to_string(),
        source: AudioSourceCore {
            id: 1,
            source: wav_path,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
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

    // Render across initial 0.6s: all 10 voices mix into scratch_effects, pass through inherit_dsp (reverb), and sum into super_flow
    let mut music_energy = 0.0f32;
    let mut all_mix_energy = 0.0f32;
    for _ in 0..30 {
        player.render_pcm(1024);
        music_energy += player.scratch_music[..1024 * 2].iter().map(|s| s.abs()).sum::<f32>();
        all_mix_energy += player.super_flow[..1024 * 2].iter().map(|s| s.abs()).sum::<f32>();
    }

    assert_eq!(
        music_energy, 0.0,
        "Music Only buffer must remain strictly 0.0 with 10 concurrent voices"
    );

    assert!(
        all_mix_energy > 0.0,
        "All Mix buffer must contain energy from the 10 reverberated voices"
    );

    // Stop active voices
    player.effects_manager.stop_all_effects(0);
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
            miniaudio_player::core::capture::DeviceCaptureNode::new(sample_rate, 1, 1024, None)
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
        miniaudio_player::core::capture::DeviceCaptureNode::new(sample_rate, 1, 1024, None)
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

    assert!(!player.input_manager.active_inputs.iter().any(|n| n.config.monitor_direct));
    assert!(!player.input_manager.active_inputs.is_empty());

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
        miniaudio_player::core::capture::DeviceCaptureNode::new(sample_rate, 1, 1024, None)
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

    assert!(player.input_manager.active_inputs.iter().any(|n| n.config.monitor_direct));

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

/// Measures the exact peak amplitude of a single sine frequency component on channel 0
/// from an interleaved stereo PCM slice using quadrature (cos/sin) correlation.
fn measure_tone_amplitude_ch0(samples: &[f32], sample_rate: u32, freq_hz: f32) -> f32 {
    let frames = samples.len() / 2;
    if frames == 0 {
        return 0.0;
    }
    let mut re = 0.0f64;
    let mut im = 0.0f64;
    for i in 0..frames {
        let s = samples[i * 2] as f64;
        let phase = 2.0 * std::f64::consts::PI * (freq_hz as f64) * (i as f64) / (sample_rate as f64);
        re += s * phase.cos();
        im += s * phase.sin();
    }
    let n = frames as f64;
    (2.0 * (re * re + im * im).sqrt() / n) as f32
}

/// Renders until the decoder delivers non-silence and DSP preamp smoother has settled.
fn pump_until_tone_settles(
    player: &mut miniaudio_player::core::miniaudio_player::MiniaudioPlayer,
    frame_count: usize,
    settle_blocks: usize,
) {
    let mut rendered_nonzero = false;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < deadline {
        player.render_pcm(frame_count);
        let peak = player.scratch_music[..frame_count * 2]
            .iter()
            .fold(0.0f32, |m, &s| m.max(s.abs()));
        if peak > 1e-4 {
            rendered_nonzero = true;
            break;
        }
        std::thread::yield_now();
    }
    assert!(rendered_nonzero, "Timed out waiting for decoded audio samples");
    for _ in 0..settle_blocks {
        player.render_pcm(frame_count);
    }
}

#[test]
fn test_per_track_replay_gain_isolated_across_manual_and_auto_crossfade() {
    use miniaudio_player::core::dual_source::AudioSourceCore;
    use miniaudio_player::core::dual_source_control::TransitionCommitMode;
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;

    let sr = 48000u32;
    // 480 frames = 10ms = integer cycles for both 400 Hz (4 cycles) and 3200 Hz (32 cycles)
    let block_frames = 480usize;
    let wav_x = SignalGenerator::pcm16_wav_sine_bytes(sr as usize * 2, sr, 2, 400.0, 0.5);
    let wav_y = SignalGenerator::pcm16_wav_sine_bytes(sr as usize * 2, sr, 2, 3200.0, 0.5);

    let gain_x_db = -18.0f32;
    let expected_x_linear = 0.5 * 10.0f32.powf(gain_x_db / 20.0); // ~0.06295
    let expected_y_linear = 0.5 * 1.0f32; // 0 dB -> 0.500

    let make_track = |id: i64, bytes: Vec<u8>, rg_db: Option<f32>| AudioSourceCore {
        id,
        source: format!("mem://track_{}.wav", id),
        headers: None,
        data_bytes: Some(bytes),
        replay_gain_db: rg_db,
        replay_peak: Some(1.0),
        resolve_in_dart: false,
    };

    let wait_both_decks_pcm =
        |ply: &miniaudio_player::core::miniaudio_player::MiniaudioPlayer, min_samples: usize| {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            loop {
                let mm = &ply.music_manager.inner;
                let a_avail = mm
                    .active_deck_ref()
                    .renderer
                    .as_ref()
                    .map(|r| r.consumer.samples_available())
                    .unwrap_or(0);
                let s_avail = (if mm.active_deck.load(Ordering::Relaxed) == 0 {
                    &mm.deck_b
                } else {
                    &mm.deck_a
                })
                    .renderer
                    .as_ref()
                    .map(|r| r.consumer.samples_available())
                    .unwrap_or(0);
                if a_avail >= min_samples && s_avail >= min_samples {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "Timed out waiting for decoded PCM ring fill (active={}, standby={}, want={})",
                    a_avail,
                    s_avail,
                    min_samples
                );
                std::thread::yield_now();
            }
        };

    // Case 1: Manual Crossfade from Track X (-18 dB) -> Track Y (0 dB).
    {
        let mut player = MiniaudioPlayer::new(sr, 2, block_frames as u32, 4, None, None).unwrap();
        player.master_limiter.set_enabled(false);
        player.music_manager.set_crossfade(500, 500, 1); // 500ms linear crossfade
        let item_x = make_track(201, wav_x.clone(), Some(gain_x_db));
        let item_y = make_track(202, wav_y.clone(), Some(0.0));
        player
            .music_manager
            .inner
            .append_items(vec![item_x.clone(), item_y.clone()]);
        player.recalculate_and_apply_replay_gain();
        let mut deck_x =
            miniaudio_player::core::dual_source::StreamingDeck::new_deck(sr, 2, block_frames as u32)
                .unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut deck_x,
                &item_x,
                None,
                None,
            ),
            0
        );
        drop(player.music_manager.inner.commit_transition_internal(
            Some(deck_x),
            &item_x,
            None,
            TransitionCommitMode::Manual {
                manual_crossfade_ms: None,
                force_play: true,
            },
        ));
        player.recalculate_and_apply_replay_gain();

        pump_until_tone_settles(&mut player, block_frames, 5);
        let solo_x =
            measure_tone_amplitude_ch0(&player.scratch_music[..block_frames * 2], sr, 400.0);
        assert!(
            (solo_x - expected_x_linear).abs() < 0.008,
            "Solo Track X amplitude must match single -18dB ReplayGain ({}), got {} (double-gain would be ~0.0079)",
            expected_x_linear,
            solo_x
        );

        // Start manual crossfade to Track Y (0 dB).
        let mut deck_y =
            miniaudio_player::core::dual_source::StreamingDeck::new_deck(sr, 2, block_frames as u32)
                .unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut deck_y,
                &item_y,
                None,
                None,
            ),
            0
        );
        drop(player.music_manager.inner.commit_transition_internal(
            Some(deck_y),
            &item_y,
            None,
            TransitionCommitMode::Manual {
                manual_crossfade_ms: Some(500),
                force_play: true,
            },
        ));
        let active_rg = player.recalculate_and_apply_replay_gain();
        assert!((active_rg.0 - 0.0).abs() < 1e-4);
        assert_eq!(player.music_dsp.equalizer.replay_gain().enabled, 0);

        // Wait until BOTH outgoing Track X and incoming Track Y have decoded PCM queued in their
        // lock-free AudioRingBuffers before stepping crossfade frames.
        wait_both_decks_pcm(&player, block_frames * 2 * 25);

        // Ensure incoming Track Y decoder is delivering audio while crossfade is active (~20..40% progress).
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut checked_samples = 0;
        while std::time::Instant::now() < deadline && checked_samples < 8 {
            let cf_before = player
                .music_manager
                .inner
                .crossfade
                .current_frame
                .load(Ordering::Relaxed);
            let cf_total = player
                .music_manager
                .inner
                .crossfade
                .total_frames
                .load(Ordering::Relaxed);
            player.render_pcm(block_frames);
            let mid_progress = ((cf_before + (block_frames as u64) / 2) as f32
                / cf_total.max(1) as f32)
                .clamp(0.0, 1.0);
            let slice = &player.scratch_music[..block_frames * 2];
            let amp_x = measure_tone_amplitude_ch0(slice, sr, 400.0);
            let amp_y = measure_tone_amplitude_ch0(slice, sr, 3200.0);
            if amp_y > 0.01 && mid_progress > 0.08 && mid_progress < 0.85 {
                let exp_x = expected_x_linear * (1.0 - mid_progress);
                let exp_y = expected_y_linear * mid_progress;
                assert!(
                    (amp_x - exp_x).abs() < 0.015,
                    "Manual crossfade leaked Track Y ReplayGain into outgoing Track X at p={:.2}: expected X={}, got {} (Y leak would be ~{})",
                    mid_progress,
                    exp_x,
                    amp_x,
                    0.5 * (1.0 - mid_progress)
                );
                assert!(
                    (amp_y - exp_y).abs() < 0.025,
                    "Manual crossfade incoming Track Y amplitude mismatch at p={:.2}: expected {}, got {}",
                    mid_progress,
                    exp_y,
                    amp_y
                );
                checked_samples += 1;
            }
            if amp_y <= 0.01 {
                std::thread::yield_now();
            }
        }
        assert!(
            checked_samples >= 4,
            "Failed to observe overlapping manual crossfade audio blocks; checked={}",
            checked_samples
        );
    }

    // Case 2: Auto Crossfade from Track X (0 dB) -> Track Y (-18 dB).
    {
        let mut player = MiniaudioPlayer::new(sr, 2, block_frames as u32, 4, None, None).unwrap();
        player.master_limiter.set_enabled(false);
        player.music_manager.set_crossfade(500, 500, 1); // 500ms linear crossfade
        let item_x = make_track(301, wav_x, Some(0.0));
        let item_y = make_track(302, wav_y, Some(gain_x_db));
        player
            .music_manager
            .inner
            .append_items(vec![item_x.clone(), item_y.clone()]);
        player.recalculate_and_apply_replay_gain();
        let mut deck_x =
            miniaudio_player::core::dual_source::StreamingDeck::new_deck(sr, 2, block_frames as u32)
                .unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut deck_x,
                &item_x,
                None,
                None,
            ),
            0
        );
        drop(player.music_manager.inner.commit_transition_internal(
            Some(deck_x),
            &item_x,
            None,
            TransitionCommitMode::Manual {
                manual_crossfade_ms: None,
                force_play: true,
            },
        ));
        player.recalculate_and_apply_replay_gain();
        pump_until_tone_settles(&mut player, block_frames, 5);

        // Prewarm standby and trigger TransitionCommitMode::AutoCrossfade directly.
        let mut standby =
            miniaudio_player::core::dual_source::StreamingDeck::new_deck(sr, 2, block_frames as u32)
                .unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut standby,
                &item_y,
                None,
                None,
            ),
            0
        );
        if let Ok(displaced) = player
            .music_manager
            .inner
            .commit_prepared_standby(standby, &item_y)
        {
            drop(displaced);
        }
        assert!(player.music_manager.inner.standby_is_ready_for(&item_y));

        let _ = player.music_manager.inner.commit_transition_internal(
            None,
            &item_y,
            None,
            TransitionCommitMode::AutoCrossfade { eff_ms: 500 },
        );
        player.recalculate_and_apply_replay_gain();
        wait_both_decks_pcm(&player, block_frames * 2 * 25);

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut checked_samples = 0;
        while std::time::Instant::now() < deadline && checked_samples < 8 {
            let cf_before = player
                .music_manager
                .inner
                .crossfade
                .current_frame
                .load(Ordering::Relaxed);
            let cf_total = player
                .music_manager
                .inner
                .crossfade
                .total_frames
                .load(Ordering::Relaxed);
            player.render_pcm(block_frames);
            let mid_progress = ((cf_before + (block_frames as u64) / 2) as f32
                / cf_total.max(1) as f32)
                .clamp(0.0, 1.0);
            let slice = &player.scratch_music[..block_frames * 2];
            let amp_x = measure_tone_amplitude_ch0(slice, sr, 400.0);
            let amp_y = measure_tone_amplitude_ch0(slice, sr, 3200.0);
            if amp_y > 0.003 && mid_progress > 0.10 && mid_progress < 0.85 {
                let exp_x = expected_y_linear * (1.0 - mid_progress); // Track X has 0 dB
                let exp_y = expected_x_linear * mid_progress; // Track Y has -18 dB
                assert!(
                    (amp_x - exp_x).abs() < 0.025,
                    "Auto crossfade outgoing Track X (0 dB) mismatch at p={:.2}: expected {}, got {}",
                    mid_progress,
                    exp_x,
                    amp_x
                );
                assert!(
                    (amp_y - exp_y).abs() < 0.015,
                    "Auto crossfade leaked Track X gain into incoming Track Y (-18 dB) at p={:.2}: expected {}, got {} (X leak would be ~{})",
                    mid_progress,
                    exp_y,
                    amp_y,
                    0.5 * mid_progress
                );
                checked_samples += 1;
            }
            if amp_y <= 0.003 {
                std::thread::yield_now();
            }
        }
        assert!(
            checked_samples >= 4,
            "Failed to observe overlapping auto-crossfade audio blocks; checked={}",
            checked_samples
        );
    }
}

#[test]
fn test_replay_gain_modes_and_live_updates_preserve_per_deck_isolation_during_crossfade() {
    use miniaudio_player::api::player::RustMiniaudioPlayer;
    use miniaudio_player::api::types::{RustAudioSource, RustCrossfadeConfig, RustReplayGainConfig};
    use miniaudio_player::core::dual_source::AudioSourceCore;
    use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;

    let sr = 48000u32;
    let wav_a = SignalGenerator::pcm16_wav_sine_bytes(sr as usize * 2, sr, 2, 440.0, 0.5);
    let wav_b = SignalGenerator::pcm16_wav_sine_bytes(sr as usize * 2, sr, 2, 880.0, 0.5);

    // 1. Direct MiniaudioPlayer mode & queue removal mid-crossfade checks.
    {
        let mut player = MiniaudioPlayer::new(sr, 2, 480, 4, None, None).unwrap();
        player.music_manager.set_crossfade(500, 500, 0);
        let item_501 = AudioSourceCore {
            id: 501,
            source: "mem://501.wav".to_string(),
            headers: None,
            data_bytes: Some(wav_a.clone()),
            replay_gain_db: Some(-12.0),
            replay_peak: Some(0.9),
            resolve_in_dart: false,
        };
        let item_502 = AudioSourceCore {
            id: 502,
            source: "mem://502.wav".to_string(),
            headers: None,
            data_bytes: Some(wav_b.clone()),
            replay_gain_db: Some(-3.0),
            replay_peak: Some(0.8),
            resolve_in_dart: false,
        };
        player
            .music_manager
            .inner
            .append_items(vec![item_501.clone(), item_502.clone()]);
        let mut deck_501 =
            miniaudio_player::core::dual_source::StreamingDeck::new_deck(sr, 2, 480).unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut deck_501,
                &item_501,
                None,
                None,
            ),
            0
        );
        drop(player.music_manager.inner.commit_transition_internal(
            Some(deck_501),
            &item_501,
            None,
            miniaudio_player::core::dual_source_control::TransitionCommitMode::Manual {
                manual_crossfade_ms: None,
                force_play: true,
            },
        ));
        let mut deck_502 =
            miniaudio_player::core::dual_source::StreamingDeck::new_deck(sr, 2, 480).unwrap();
        assert_eq!(
            miniaudio_player::core::dual_source::DualSource::open_deck_source_with_cancel(
                &mut deck_502,
                &item_502,
                None,
                None,
            ),
            0
        );
        drop(player.music_manager.inner.commit_transition_internal(
            Some(deck_502),
            &item_502,
            None,
            miniaudio_player::core::dual_source_control::TransitionCommitMode::Manual {
                manual_crossfade_ms: Some(500),
                force_play: true,
            },
        ));
        let fg = player.recalculate_and_apply_replay_gain();
        assert!((fg.0 - (-3.0)).abs() < 1e-4);

        // Identify outgoing deck (holding 501) vs active incoming deck (holding 502).
        let (out_rg, in_rg) = {
            let act_idx = player.music_manager.inner.active_deck.load(Ordering::Relaxed);
            if act_idx == 1 {
                (player.music_manager.inner.deck_a.replay_gain, player.music_manager.inner.deck_b.replay_gain)
            } else {
                (player.music_manager.inner.deck_b.replay_gain, player.music_manager.inner.deck_a.replay_gain)
            }
        };
        assert_eq!(out_rg.enabled, 1);
        assert!((out_rg.gain_db - (-12.0)).abs() < 1e-4);
        assert_eq!(in_rg.enabled, 1);
        assert!((in_rg.gain_db - (-3.0)).abs() < 1e-4);
        assert_eq!(player.music_dsp.equalizer.replay_gain().enabled, 0);

        // Removing outgoing track from queue while it still fades out, then toggling Disabled -> Track,
        // must still restore -12 dB on outgoing deck and -3 dB on incoming deck.
        let _ = player.music_manager.inner.remove_item_at(0);
        let dis = player.set_replay_gain_mode(0);
        assert!((dis.0 - 0.0).abs() < 1e-4);
        assert_eq!(player.music_manager.inner.deck_a.replay_gain.enabled, 0);
        assert_eq!(player.music_manager.inner.deck_b.replay_gain.enabled, 0);

        let forced = player.set_default_replay_gain(-7.5, 0.95);
        assert!((forced.0 - 0.0).abs() < 1e-4); // Still in Disabled mode
        let mode2 = player.set_replay_gain_mode(2);
        assert!((mode2.0 - (-7.5)).abs() < 1e-4);
        assert!((player.music_manager.inner.deck_a.replay_gain.gain_db - (-7.5)).abs() < 1e-4);
        assert!((player.music_manager.inner.deck_b.replay_gain.gain_db - (-7.5)).abs() < 1e-4);

        let restored = player.set_replay_gain_mode(1);
        assert!((restored.0 - (-3.0)).abs() < 1e-4);
        let (out_after, in_after) = {
            let act_idx = player.music_manager.inner.active_deck.load(Ordering::Relaxed);
            if act_idx == 1 {
                (player.music_manager.inner.deck_a.replay_gain, player.music_manager.inner.deck_b.replay_gain)
            } else {
                (player.music_manager.inner.deck_b.replay_gain, player.music_manager.inner.deck_a.replay_gain)
            }
        };
        assert!((out_after.gain_db - (-12.0)).abs() < 1e-4);
        assert!((in_after.gain_db - (-3.0)).abs() < 1e-4);
    }

    // 2A. EngineActorHandle + ControlCoordinator + EngineUiSnapshots verification during crossfade.
    {
        use miniaudio_player::buffer::{CustomDartByteSource, CustomSourceRegistry};
        use miniaudio_player::core::control_coordinator::ControlCoordinator;
        use miniaudio_player::core::dual_source::CustomSourceFactory;
        use miniaudio_player::core::engine_actor::EngineActorHandle;
        use miniaudio_player::sync::write_unpoisoned;

        let (engine, _notify_rx, hint_rx) =
            EngineActorHandle::spawn(sr, 2, 512, 8, None, None, false, 0, Vec::new())
                .expect("Failed to spawn EngineActorHandle");
        let reg = CustomSourceRegistry::new();
        let coordinator = ControlCoordinator::spawn(
            engine.clone(),
            reg.clone(),
            hint_rx,
            Arc::new(|_snap| {}),
        );
        let custom_factory: CustomSourceFactory = Arc::new(move |stream_id, total_size| {
            CustomDartByteSource::with_registry(
                stream_id,
                total_size,
                true,
                Arc::new(|_| {}),
                Some(reg.clone()),
            )
        });

        engine
            .exec(|ply| {
                ply.music_manager.set_crossfade(500, 500, 1);
            })
            .unwrap();
        coordinator
            .set_queue(
                vec![
                    AudioSourceCore {
                        id: 801,
                        source: "mem://801.wav".to_string(),
                        headers: None,
                        data_bytes: Some(wav_a.clone()),
                        replay_gain_db: Some(-14.0),
                        replay_peak: Some(0.95),
                        resolve_in_dart: false,
                    },
                    AudioSourceCore {
                        id: 802,
                        source: "mem://802.wav".to_string(),
                        headers: None,
                        data_bytes: Some(wav_b.clone()),
                        replay_gain_db: Some(-2.5),
                        replay_peak: Some(0.85),
                        resolve_in_dart: false,
                    },
                ],
                custom_factory,
            )
            .unwrap();
        coordinator.play(Some(801), None, None, None, false).unwrap();
        assert!((engine.snapshots().unpack_rg().0 - (-14.0)).abs() < 1e-4);

        coordinator.next(Some(500), false).unwrap();
        assert!(engine.snapshots().is_xfading());
        assert!((engine.snapshots().unpack_rg().0 - (-2.5)).abs() < 1e-4);

        // Verify outgoing deck retains -14.0 dB while incoming foreground has -2.5 dB,
        // and updating outgoing track 801 in-place only alters the outgoing deck.
        let (out_gain, in_gain) = engine
            .exec(|ply| {
                {
                    let mut q = write_unpoisoned(&ply.music_manager.inner.queue);
                    q[0].replay_gain_db = Some(-9.0);
                }
                let _ = ply.recalculate_and_apply_replay_gain();
                let mm = &ply.music_manager.inner;
                if mm.active_deck.load(Ordering::Relaxed) == 1 {
                    (mm.deck_a.replay_gain.gain_db, mm.deck_b.replay_gain.gain_db)
                } else {
                    (mm.deck_b.replay_gain.gain_db, mm.deck_a.replay_gain.gain_db)
                }
            })
            .unwrap();
        assert!((out_gain - (-9.0)).abs() < 1e-4);
        assert!((in_gain - (-2.5)).abs() < 1e-4);
        assert!((engine.snapshots().unpack_rg().0 - (-2.5)).abs() < 1e-4);

        coordinator.shutdown();
        engine.shutdown();
    }

    // 2B. Public RustMiniaudioPlayer API + shuffle + set_replay_gain live update on outgoing track.
    {
        use miniaudio_player::api::types::RustPlayerConfig;

        let ply = RustMiniaudioPlayer::new(
            RustPlayerConfig::default(),
            sr,
            2,
            1024,
            Vec::new(),
        )
        .unwrap();
        ply.set_crossfade(RustCrossfadeConfig {
            auto_duration_ms: 400,
            manual_duration_ms: 400,
            curve: 0,
        });
        ply.set_queue(vec![
            RustAudioSource {
                id: 901,
                source: "mem://901.wav".to_string(),
                headers: None,
                data_bytes: Some(wav_a),
                replay_gain_db: Some(-14.0),
                replay_peak: Some(0.95),
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: 902,
                source: "mem://902.wav".to_string(),
                headers: None,
                data_bytes: Some(wav_b),
                replay_gain_db: Some(-2.5),
                replay_peak: Some(0.85),
                resolve_in_dart: false,
            },
        ])
        .unwrap();
        ply.set_shuffle(true);
        ply.play(Some(901), None, None, None).unwrap();
        ply.next(Some(400)).unwrap();

        // Updating outgoing track 901 by id under shuffle + crossfade must succeed cleanly.
        ply.set_replay_gain(
            Some(RustReplayGainConfig {
                gain_db: -9.0,
                peak: 0.9,
            }),
            Some(901),
            None,
        )
        .unwrap();
        ply.set_replay_gain_mode(2).unwrap();
        ply.set_default_replay_gain(-7.5, 0.95).unwrap();
        ply.dispose();
    }
}



