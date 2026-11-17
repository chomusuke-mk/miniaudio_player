//! Massive Multi-Plane Native Concurrency, Chaos, and Error-Injection Stress Suite.
//!
//! Validates thread safety, wait-free isolation, cancellation speed, LRU eviction,
//! snapshot coherence, and lifecycle churn across all native Tri-Plane layers with
//! zero blind sleeps (`thread::sleep`).

mod common;

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::api::player::{analyze_audio_source, EventReporter, RustMiniaudioPlayer};
use miniaudio_player::api::types::{
    RustAnalysisConfig, RustAudioEffect, RustAudioInput, RustAudioInputConfig, RustAudioOutput,
    RustAudioSource, RustCrossfadeConfig, RustCrossfeedConfig, RustDuckingConfig,
    RustEffectConfig, RustEqualizerParams, RustPlayerConfig, RustPlayerEvent, RustReverbParams,
    RustSilenceConfig, RustSpatialEmitter, RustSpatialListener, RustVector3, RustVisualizerData,
};
use miniaudio_player::buffer::{
    BufferError, CustomDartByteSource, CustomSourceRegistry, DartReadRequest, StreamSession,
};
use miniaudio_player::core::control_coordinator::ControlCoordinator;
use miniaudio_player::core::dual_source::AudioSourceCore;
use miniaudio_player::core::engine_actor::EngineActorHandle;
use miniaudio_player::core::hw_supervisor::HardwareDeviceSupervisor;
use miniaudio_player::core::recording::WavFormat;
use miniaudio_player::core::voice_pool::{SoundBuffer, MAX_VOICES};
use miniaudio_player::sync::{lock_unpoisoned, wait_timeout_unpoisoned};
use rand::rngs::StdRng;
use rand::{RngExt, SeedableRng};

fn spin_yield_until<F>(timeout: Duration, mut pred: F) -> bool
where
    F: FnMut() -> bool,
{
    let start = Instant::now();
    while start.elapsed() < timeout {
        if pred() {
            return true;
        }
        thread::yield_now();
    }
    false
}

/// Sleep-free adversarial HTTP test server serving valid WAV, HTTP 500, truncated payloads,
/// and releasing stalled tarpit sockets synchronously via a `Condvar` on drop.
struct ChaosHttpServer {
    port: u16,
    stop: Arc<(Mutex<bool>, Condvar)>,
    thread: Option<JoinHandle<()>>,
}

impl ChaosHttpServer {
    fn start(valid_wav: Vec<u8>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("Bind ephemeral chaos port");
        let port = listener.local_addr().expect("local_addr").port();
        let stop = Arc::new((Mutex::new(false), Condvar::new()));

        let stop_c = stop.clone();
        let wav_c = Arc::new(valid_wav);

        let thread = thread::Builder::new()
            .name("chaos-http-srv".to_string())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::new();
                while let Ok((stream, _)) = listener.accept() {
                    if *lock_unpoisoned(&stop_c.0) {
                        break;
                    }
                    let s_c = stop_c.clone();
                    let w_c = wav_c.clone();
                    workers.retain(|w| !w.is_finished());
                    workers.push(thread::spawn(move || {
                        Self::handle_client(stream, &w_c, &s_c);
                    }));
                }
                for w in workers {
                    let _ = w.join();
                }
            })
            .expect("Spawn chaos HTTP server");

        Self {
            port,
            stop,
            thread: Some(thread),
        }
    }

    fn handle_client(
        mut stream: TcpStream,
        valid_wav: &[u8],
        stop: &(Mutex<bool>, Condvar),
    ) {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
        let mut req_buf = [0u8; 2048];
        let n = match stream.read(&mut req_buf) {
            Ok(n) if n > 0 => n,
            _ => return,
        };
        let req_text = String::from_utf8_lossy(&req_buf[..n]);

        if req_text.contains("/valid.wav") {
            let hdr = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                valid_wav.len()
            );
            let _ = stream.write_all(hdr.as_bytes());
            let _ = stream.write_all(valid_wav);
        } else if req_text.contains("/http500") {
            let _ = stream.write_all(
                b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\nConnection: close\r\n\r\nERROR",
            );
        } else if req_text.contains("/truncated.wav") {
            let hdr = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: 524288\r\nConnection: close\r\n\r\n";
            let _ = stream.write_all(hdr.as_bytes());
            let partial = valid_wav.len().min(256);
            let _ = stream.write_all(&valid_wav[..partial]);
        } else {
            // Tarpit: park on Condvar without any sleep until server shuts down.
            let (lock, cvar) = stop;
            let mut stopped = lock_unpoisoned(lock);
            let deadline = Instant::now() + Duration::from_secs(10);
            while !*stopped && Instant::now() < deadline {
                let rem = deadline.saturating_duration_since(Instant::now());
                let (next, _) = wait_timeout_unpoisoned(cvar, stopped, rem);
                stopped = next;
            }
        }
    }
}

impl Drop for ChaosHttpServer {
    fn drop(&mut self) {
        {
            let (lock, cvar) = &*self.stop;
            *lock_unpoisoned(lock) = true;
            cvar.notify_all();
        }
        // Wake blocking listener.accept() immediately without socket polling sleeps.
        let _ = TcpStream::connect(("127.0.0.1", self.port));
        if let Some(jh) = self.thread.take() {
            let _ = jh.join();
        }
    }
}

fn find_wav_data_slice(wav_bytes: &[u8]) -> &[u8] {
    assert!(wav_bytes.len() >= 12);
    assert_eq!(&wav_bytes[0..4], b"RIFF");
    assert_eq!(&wav_bytes[8..12], b"WAVE");
    let mut off = 12usize;
    while off + 8 <= wav_bytes.len() {
        let id = &wav_bytes[off..off + 4];
        let chunk_len = u32::from_le_bytes(wav_bytes[off + 4..off + 8].try_into().unwrap()) as usize;
        off += 8;
        if id == b"data" {
            let end = (off + chunk_len).min(wav_bytes.len());
            return &wav_bytes[off..end];
        }
        off = off.saturating_add(chunk_len + (chunk_len % 2));
    }
    panic!("RIFF WAVE payload missing data chunk");
}

#[test]
fn scenario_1_16_thread_control_queue_navigation_chaos_matrix() {
    let valid_wav = SignalGenerator::pcm16_wav_bytes(96_000, 48_000, 2);
    let server = ChaosHttpServer::start(valid_wav.clone());
    let local_wav = FixtureResolver::resolve_str("salida.wav");

    let player = Arc::new(
        RustMiniaudioPlayer::new(RustPlayerConfig::default(), 48_000, 2, 1024, vec![])
            .expect("Failed to create RustMiniaudioPlayer"),
    );

    let sfx_wav = SignalGenerator::pcm16_wav_bytes(12_000, 48_000, 2);
    player
        .set_effects(vec![RustAudioEffect {
            id: "ping".to_string(),
            source: RustAudioSource {
                id: 9001,
                source: "memory://ping.wav".to_string(),
                headers: None,
                data_bytes: Some(sfx_wav),
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            max_polyphony: 16,
            pinned: true,
        }])
        .expect("set_effects failed");

    let next_id = Arc::new(AtomicU64::new(100));
    let make_mixed_queue = |base_id: u64| -> Vec<RustAudioSource> {
        vec![
            RustAudioSource {
                id: base_id as i64,
                source: format!("memory://mem_{}.wav", base_id),
                headers: None,
                data_bytes: Some(valid_wav.clone()),
                replay_gain_db: Some(-3.0),
                replay_peak: Some(0.9),
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: (base_id + 1) as i64,
                source: local_wav.clone(),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: (base_id + 2) as i64,
                source: format!("http://127.0.0.1:{}/valid.wav", server.port),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: (base_id + 3) as i64,
                source: format!("http://127.0.0.1:{}/http500", server.port),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: (base_id + 4) as i64,
                source: format!("http://127.0.0.1:{}/truncated.wav", server.port),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: (base_id + 5) as i64,
                source: "/nonexistent/missing_track_chaos.wav".to_string(),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: (base_id + 6) as i64,
                source: format!("http://127.0.0.1:{}/tarpit.wav", server.port),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
        ]
    };

    player
        .set_queue(make_mixed_queue(1))
        .expect("initial set_queue failed");

    let threads = 16usize;
    let barrier = Arc::new(Barrier::new(threads));
    let total_ops = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::with_capacity(threads);

    for tid in 0..threads {
        let p = player.clone();
        let b = barrier.clone();
        let ops = total_ops.clone();
        let nid = next_id.clone();
        let w = valid_wav.clone();
        let loc = local_wav.clone();
        let port = server.port;

        handles.push(thread::spawn(move || {
            let mut rng = StdRng::seed_from_u64(0x9E37_79B9_u64 + tid as u64);
            b.wait();

            for step in 0..40 {
                match tid % 3 {
                    0 => {
                        // Queue mutator lane
                        match rng.random_range(0..6) {
                            0 => {
                                let base = nid.fetch_add(10, Ordering::Relaxed);
                                let _ = p.set_queue(vec![
                                    RustAudioSource {
                                        id: base as i64,
                                        source: loc.clone(),
                                        headers: None,
                                        data_bytes: None,
                                        replay_gain_db: None,
                                        replay_peak: None,
                                        resolve_in_dart: false,
                                    },
                                    RustAudioSource {
                                        id: (base + 1) as i64,
                                        source: format!("http://127.0.0.1:{}/valid.wav", port),
                                        headers: None,
                                        data_bytes: None,
                                        replay_gain_db: None,
                                        replay_peak: None,
                                        resolve_in_dart: false,
                                    },
                                    RustAudioSource {
                                        id: (base + 2) as i64,
                                        source: if step % 2 == 0 {
                                            format!("http://127.0.0.1:{}/http500", port)
                                        } else {
                                            format!("http://127.0.0.1:{}/tarpit.wav", port)
                                        },
                                        headers: None,
                                        data_bytes: None,
                                        replay_gain_db: None,
                                        replay_peak: None,
                                        resolve_in_dart: false,
                                    },
                                ]);
                            }
                            1 => {
                                let id = nid.fetch_add(1, Ordering::Relaxed) as i64;
                                p.append(vec![RustAudioSource {
                                    id,
                                    source: format!("memory://app_{}.wav", id),
                                    headers: None,
                                    data_bytes: Some(w.clone()),
                                    replay_gain_db: None,
                                    replay_peak: None,
                                    resolve_in_dart: false,
                                }]);
                            }
                            2 => {
                                let id = nid.fetch_add(1, Ordering::Relaxed) as i64;
                                p.insert_next(RustAudioSource {
                                    id,
                                    source: loc.clone(),
                                    headers: None,
                                    data_bytes: None,
                                    replay_gain_db: None,
                                    replay_peak: None,
                                    resolve_in_dart: false,
                                });
                            }
                            3 => {
                                let _ = p.remove_at(rng.random_range(0..4));
                            }
                            4 => {
                                let _ = p.reorder(rng.random_range(0..3), rng.random_range(0..3));
                            }
                            _ => p.clear_queue(rng.random_bool(0.5)),
                        }
                    }
                    1 => {
                        // Transport & Navigation lane (tolerate expected errors on broken fixtures)
                        match rng.random_range(0..9) {
                            0 => {
                                let _ = p.play(
                                    None,
                                    Some(rng.random_range(0..5)),
                                    Some(rng.random_bool(0.3)),
                                    Some(rng.random_range(0..400)),
                                );
                            }
                            1 => {
                                let _ = p.next(Some(rng.random_range(0..100)));
                            }
                            2 => {
                                let _ = p.previous();
                            }
                            3 => {
                                let _ = p.seek(rng.random_range(0..800));
                            }
                            4 => p.pause(),
                            5 => p.stop(),
                            6 => p.set_loop_mode(rng.random_range(0..=2)),
                            7 => p.set_shuffle(rng.random_bool(0.5)),
                            _ => p.set_crossfade(RustCrossfadeConfig {
                                auto_duration_ms: rng.random_range(0..300),
                                manual_duration_ms: rng.random_range(0..150),
                                curve: rng.random_range(0..=1),
                            }),
                        }
                    }
                    _ => {
                        // High-frequency lock-free state & SFX reader/toggle lane
                        let _ = p.get_loaded_effect_ids();
                        let _ = p.get_allocated_ram_bytes();
                        assert!(p.get_active_voices_count() <= 64);
                        p.set_metadata_enabled(step % 2 == 0);
                        p.set_visualizer_enabled(step % 3 == 0);
                        let _ = p.play_effect(
                            "ping".to_string(),
                            RustEffectConfig {
                                volume: 0.4,
                                balance: 0.0,
                                pitch: 1.0,
                                rate: 1.0,
                                looping: false,
                                priority: 1,
                                ..Default::default()
                            },
                        );
                    }
                }
                ops.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }

    for h in handles {
        h.join().expect("Chaos worker thread panicked");
    }
    assert_eq!(total_ops.load(Ordering::Acquire), 16 * 40);

    // Deterministic clean recovery after chaos matrix.
    player.stop();
    player
        .set_queue(vec![RustAudioSource {
            id: 99_999,
            source: local_wav,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        }])
        .expect("Post-chaos set_queue failed");
    player
        .play(Some(99_999), None, None, Some(50))
        .expect("Post-chaos play recovery failed");
    player.stop();
    player.dispose();
}

#[test]
fn scenario_2_high_frequency_dsp_storm_during_decode_seek_crossfade() {
    let temp_dir = std::env::temp_dir().join(format!(
        "map_dsp_storm_{}_{:?}",
        std::process::id(),
        thread::current().id()
    ));
    std::fs::create_dir_all(&temp_dir).expect("Create temp dir");
    let rec_path = temp_dir.join("dsp_storm_f32.wav");

    let wav_a = SignalGenerator::pcm16_wav_bytes(144_000, 48_000, 2);
    let wav_b = SignalGenerator::pcm16_wav_bytes(144_000, 48_000, 2);
    let wav_c = FixtureResolver::resolve_str("salida.wav");

    let player = Arc::new(
        RustMiniaudioPlayer::new(RustPlayerConfig::default(), 48_000, 2, 512, vec![])
            .expect("Failed to create RustMiniaudioPlayer"),
    );

    player
        .set_effects(vec![RustAudioEffect {
            id: "loop_fx".to_string(),
            source: RustAudioSource {
                id: 500,
                source: "memory://loop_fx.wav".to_string(),
                headers: None,
                data_bytes: Some(SignalGenerator::pcm16_wav_bytes(24_000, 48_000, 2)),
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            max_polyphony: 8,
            pinned: true,
        }])
        .expect("set_effects failed");

    player.set_crossfade(RustCrossfadeConfig {
        auto_duration_ms: 400,
        manual_duration_ms: 150,
        curve: 0,
    });

    player
        .set_queue(vec![
            RustAudioSource {
                id: 1,
                source: "memory://a.wav".to_string(),
                headers: None,
                data_bytes: Some(wav_a),
                replay_gain_db: Some(-4.0),
                replay_peak: Some(0.95),
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: 2,
                source: "memory://b.wav".to_string(),
                headers: None,
                data_bytes: Some(wav_b),
                replay_gain_db: Some(-1.0),
                replay_peak: Some(0.85),
                resolve_in_dart: false,
            },
            RustAudioSource {
                id: 3,
                source: wav_c,
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
        ])
        .expect("set_queue failed");

    // Record Float32 WAV throughout the storm so we can verify every rendered sample is finite.
    player
        .start_recording(rec_path.to_string_lossy().to_string(), 1 /* Float32 */, 0 /* All */)
        .expect("start_recording failed");
    player
        .play(Some(1), None, None, Some(0))
        .expect("play failed");

    let voice_id = player
        .play_effect(
            "loop_fx".to_string(),
            RustEffectConfig {
                volume: 0.35,
                balance: 0.0,
                pitch: 1.0,
                rate: 1.0,
                looping: true,
                priority: 5,
                dsp_routing: 0,
                ..Default::default()
            },
        )
        .expect("play_effect failed");

    let threads = 8usize;
    let barrier = Arc::new(Barrier::new(threads));
    let dsp_updates = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::with_capacity(threads);

    for tid in 0..threads {
        let p = player.clone();
        let b = barrier.clone();
        let updates = dsp_updates.clone();

        handles.push(thread::spawn(move || {
            let mut rng = StdRng::seed_from_u64(0x517C_C1B7_u64 + tid as u64);
            b.wait();

            if tid < 4 {
                // 4 threads issuing 350 DSP mutations each = 1400 DSP updates (> 1000 target)
                for iter in 0..350 {
                    match iter % 12 {
                        0 => p.set_volume(rng.random_range(0.1..=1.2)),
                        1 => p.set_rate(rng.random_range(0.5..=2.0)),
                        2 => p.set_pitch(rng.random_range(0.6..=1.8)),
                        3 => p.set_balance(rng.random_range(-1.0..=1.0)),
                        4 => p.set_mono(rng.random_bool(0.5)),
                        5 => {
                            let gains: Vec<f32> = (0..10).map(|_| rng.random_range(-12.0..=12.0)).collect();
                            let _ = p.set_equalizer(RustEqualizerParams {
                                gains,
                                enabled: rng.random_bool(0.8),
                            });
                        }
                        6 => p.set_crossfeed(RustCrossfeedConfig {
                            enabled: rng.random_bool(0.7),
                            cutoff_hz: rng.random_range(400.0..=1600.0),
                            feed_db: rng.random_range(2.0..=10.0),
                        }),
                        7 => p.set_spatializer(rng.random_bool(0.7), rng.random_range(0.2..=1.8)),
                        8 => {
                            let _ = p.set_reverb(RustReverbParams {
                                room_size: rng.random_range(0.1..=0.95),
                                damping: rng.random_range(0.1..=0.9),
                                wet: rng.random_range(0.0..=0.8),
                                dry: rng.random_range(0.4..=1.0),
                                width: rng.random_range(0.0..=1.0),
                                mode: 0.0,
                                enabled: rng.random_bool(0.7),
                            });
                        }
                        9 => p.set_limiter(rng.random_bool(0.8)),
                        10 => {
                            let _ = p.set_replay_gain_mode(rng.random_range(0..=2));
                            let _ = p.set_default_replay_gain(rng.random_range(-6.0..=2.0), 0.95);
                        }
                        _ => {
                            let _ = p.set_silence_config(RustSilenceConfig {
                                mode: rng.random_range(0..=3),
                                threshold_db: -45.0,
                                min_silence_duration_ms: 150,
                                padding_ms: 20,
                                enabled: rng.random_bool(0.5),
                            });
                        }
                    }
                    updates.fetch_add(1, Ordering::Relaxed);
                }
            } else if tid < 6 {
                // 2 threads driving seeks, crossfades, and navigation simultaneously
                for _ in 0..35 {
                    let _ = p.seek(rng.random_range(0..1500));
                    let _ = p.next(Some(rng.random_range(20..180)));
                    let _ = p.seek(rng.random_range(0..1200));
                    let _ = p.previous();
                }
            } else {
                // 2 threads modulating 3D spatial listener, Doppler, and SFX voice parameters
                for iter in 0..160 {
                    p.set_doppler_parameters(1.0 + (iter % 3) as f32 * 0.25, 343.0);
                    p.set_listener(RustSpatialListener {
                        position: RustVector3 {
                            x: (iter % 10) as f32,
                            y: 0.0,
                            z: 1.0,
                        },
                        velocity: RustVector3::default(),
                        forward: RustVector3 {
                            x: 0.0,
                            y: 0.0,
                            z: -1.0,
                        },
                        up: RustVector3 {
                            x: 0.0,
                            y: 1.0,
                            z: 0.0,
                        },
                    });
                    p.set_effect_volume(voice_id, rng.random_range(0.1..=0.8));
                    p.set_effect_pitch(voice_id, rng.random_range(0.7..=1.5));
                    p.set_effect_balance(voice_id, rng.random_range(-1.0..=1.0));
                    p.set_effect_emitter(
                        voice_id,
                        Some(RustSpatialEmitter {
                            position: RustVector3 {
                                x: rng.random_range(-5.0..=5.0),
                                y: 0.0,
                                z: rng.random_range(1.0..=10.0),
                            },
                            ..Default::default()
                        }),
                    );
                }
            }
        }));
    }

    for h in handles {
        h.join().expect("DSP storm worker panicked");
    }
    assert_eq!(dsp_updates.load(Ordering::Acquire), 1400);

    player.stop_all_effects(0);
    let rec = player.stop_recording().expect("stop_recording failed");
    assert!(rec.bytes_written >= 44);
    if rec.sample_count > 0 {
        let wav_disk = std::fs::read(&rec_path).expect("Read Float32 recorded WAV");
        let payload = find_wav_data_slice(&wav_disk);
        assert!(payload.len() % 4 == 0);
        for chunk in payload.chunks_exact(4) {
            let sample = f32::from_le_bytes(chunk.try_into().unwrap());
            assert!(
                sample.is_finite(),
                "Non-finite PCM sample ({}) produced during DSP storm!",
                sample
            );
        }
    }

    player.stop();
    player.dispose();
    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn scenario_3_massive_sfx_polyphony_and_lru_eviction_storm() {
    let config = RustPlayerConfig {
        max_voices: MAX_VOICES as u32,
        max_ram_bytes: Some(256 * 1024),
        ..Default::default()
    };
    let player = Arc::new(
        RustMiniaudioPlayer::new(config, 48_000, 2, 512, vec![])
            .expect("Failed to create RustMiniaudioPlayer"),
    );

    let big_fx = SignalGenerator::pcm16_wav_bytes(16_000, 48_000, 2); // ~64 KB each
    let tiny_fx = SignalGenerator::pcm16_wav_bytes(1_000, 48_000, 2); // ~4 KB pinned
    let build_catalog = |prefix: &str, count: usize| -> Vec<RustAudioEffect> {
        let mut list: Vec<RustAudioEffect> = (0..count)
            .map(|i| RustAudioEffect {
                id: format!("{}_{}", prefix, i),
                source: RustAudioSource {
                    id: 20_000 + i as i64,
                    source: format!("memory://{}_{}.wav", prefix, i),
                    headers: None,
                    data_bytes: Some(if i < 2 { tiny_fx.clone() } else { big_fx.clone() }),
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
                max_polyphony: MAX_VOICES as u32,
                pinned: i < 2,
            })
            .collect();
        list.push(RustAudioEffect {
            id: "broken_missing".to_string(),
            source: RustAudioSource {
                id: 99_100,
                source: "/nonexistent/broken_sfx.wav".to_string(),
                ..Default::default()
            },
            max_polyphony: 4,
            pinned: false,
        });
        list
    };

    let cat_a = build_catalog("sfx_a", 20);
    let cat_b = build_catalog("sfx_b", 20);
    player.set_effects(cat_a.clone()).expect("Initial catalog failed");

    let threads = 8usize;
    let barrier = Arc::new(Barrier::new(threads));
    let mut handles = Vec::with_capacity(threads);

    for tid in 0..threads {
        let p = player.clone();
        let b = barrier.clone();
        let ca = cat_a.clone();
        let cb = cat_b.clone();

        handles.push(thread::spawn(move || {
            let mut rng = StdRng::seed_from_u64(0xCAFE_BABE_u64 + tid as u64);
            let mut my_voices = Vec::new();
            b.wait();

            for step in 0..80 {
                if tid == 0 && step % 15 == 0 {
                    let target = if (step / 15) % 2 == 0 {
                        cb.clone()
                    } else {
                        ca.clone()
                    };
                    let _ = p.set_effects(target);
                }

                let idx = rng.random_range(0..20);
                let id = if step % 9 == 0 {
                    "broken_missing".to_string()
                } else if rng.random_bool(0.5) {
                    format!("sfx_a_{}", idx)
                } else {
                    format!("sfx_b_{}", idx)
                };

                if let Ok(vid) = p.play_effect(
                    id,
                    RustEffectConfig {
                        volume: 0.2,
                        balance: rng.random_range(-1.0..=1.0),
                        pitch: rng.random_range(0.8..=1.4),
                        rate: 1.0,
                        looping: rng.random_bool(0.5),
                        priority: rng.random_range(0..=10),
                        ..Default::default()
                    },
                ) {
                    my_voices.push(vid);
                    p.set_effect_volume(vid, 0.3);
                }

                if my_voices.len() > 4 {
                    if let Some(old_v) = my_voices.pop() {
                        p.stop_effect(old_v, 0);
                    }
                }
                if step == 40 && tid == 1 {
                    p.stop_all_effects(0);
                }

                assert!(p.get_active_voices_count() <= MAX_VOICES as u32);
                let _ = p.get_loaded_effect_ids();
                let _ = p.get_allocated_ram_bytes();
            }
        }));
    }

    for h in handles {
        h.join().expect("SFX polyphony storm thread panicked");
    }

    // Verify looping SFX wraparound boundary never panics at cursor == total_frames.
    let tiny_buf = SoundBuffer::new(vec![0.1, -0.1, 0.2, -0.2, 0.3, -0.3], 48_000, 2);
    let total_frames = tiny_buf.frame_count();
    let mut c = total_frames as f64;
    let (f0, f1, frac) = SoundBuffer::resolve_lerp_indices(&mut c, total_frames, true)
        .expect("Looping cursor at end-of-buffer must wrap cleanly");
    assert_eq!((f0, f1), (0, 1));
    assert!(frac.abs() < 1e-6);
    let (sl, sr) = tiny_buf.sample_stereo_lerp(f0, f1, frac);
    assert!(sl.is_finite() && sr.is_finite());

    let mut c_oob = 2.0 * total_frames as f64 + 2.5;
    let (f0_last, f1_wrap, frac2) =
        SoundBuffer::resolve_lerp_indices(&mut c_oob, total_frames, true)
            .expect("Wrapped cursor at final frame must wrap f1 to 0");
    assert_eq!((f0_last, f1_wrap), (total_frames - 1, 0));
    let (wl, wr) = tiny_buf.sample_stereo_lerp(f0_last, f1_wrap, frac2);
    assert!(wl.is_finite() && wr.is_finite());

    let mut c_nonloop = total_frames as f64;
    assert!(SoundBuffer::resolve_lerp_indices(&mut c_nonloop, total_frames, false).is_none());

    player.stop_all_effects(0);
    player.set_effects(vec![]).expect("Clearing SFX catalog failed");
    assert_eq!(player.get_active_voices_count(), 0);
    assert!(player.get_loaded_effect_ids().is_empty());
    assert_eq!(player.get_allocated_ram_bytes(), 0);
    player.dispose();
}

#[test]
fn scenario_4_adversarial_custom_source_stream_session_and_offline_analysis() {
    // 1. Out-of-order StreamSession writes, overlapping seek offsets & concurrent reads
    let payload: Vec<u8> = (0..(48 * 1024usize)).map(|i| ((i * 31) & 0xFF) as u8).collect();
    let session = StreamSession::new(8192, Some(payload.len() as u64), false);
    session.set_audio_start(0);

    let s_w1 = session.clone();
    let p_w1 = payload.clone();
    let writer_even = thread::spawn(move || {
        for off in (0..p_w1.len()).step_by(512).rev() {
            let end = (off + 256).min(p_w1.len());
            let _ = s_w1.write_at(off as u64, &p_w1[off..end]);
        }
    });
    let s_w2 = session.clone();
    let p_w2 = payload.clone();
    let writer_odd = thread::spawn(move || {
        for off in (256..p_w2.len()).step_by(512) {
            let end = (off + 256).min(p_w2.len());
            let _ = s_w2.write_at(off as u64, &p_w2[off..end]);
        }
    });
    let s_r = session.clone();
    let reader_chk = thread::spawn(move || {
        let mut scratch = [0u8; 384];
        for iter in 0..120 {
            let off = ((iter * 384) % (40 * 1024)) as u64;
            match s_r.read_at(off, &mut scratch) {
                Ok(n) => {
                    for (i, &b) in scratch[..n].iter().enumerate() {
                        assert_eq!(b, (((off as usize + i) * 31) & 0xFF) as u8);
                    }
                }
                Err(BufferError::WouldBlock) => thread::yield_now(),
                Err(_) => break,
            }
        }
    });

    writer_even.join().unwrap();
    writer_odd.join().unwrap();
    session.mark_eof();
    reader_chk.join().unwrap();

    // 2. Adversarial CustomDartByteSource short reads, variable chunks & mid-read abort_all()
    let registry = CustomSourceRegistry::new();
    let wav_data = Arc::new(SignalGenerator::pcm16_wav_bytes(32_000, 48_000, 2));
    let reg_cb = registry.clone();
    let data_cb = wav_data.clone();
    let flaky_handler = Arc::new(move |req: DartReadRequest| {
        if req.stream_id == 77 {
            // Stream 77 simulates intentional silent stall waiting to be killed by abort_all()
            return;
        }
        let start = (req.offset as usize).min(data_cb.len());
        // Serve deliberately small chunks (short reads) to test multi-iteration assembly.
        let max_len = (req.length as usize).min(113);
        let end = start.saturating_add(max_len).min(data_cb.len());
        let eof = end >= data_cb.len();
        reg_cb.resolve_request(req.request_id, data_cb[start..end].to_vec(), eof);
    });

    let (mut active_src, _h1) = CustomDartByteSource::with_registry(
        76,
        Some(wav_data.len() as u64),
        true,
        flaky_handler.clone(),
        Some(registry.clone()),
    );

    let blocked_dispatched = Arc::new(AtomicBool::new(false));
    let bd_cb = blocked_dispatched.clone();
    let (mut stalled_src, _h2) = CustomDartByteSource::with_registry(
        77,
        Some(16384),
        true,
        Arc::new(move |_| {
            bd_cb.store(true, Ordering::Release);
        }),
        Some(registry.clone()),
    );

    let blocked_jh = thread::spawn(move || {
        let mut buf = [0u8; 64];
        let t0 = Instant::now();
        let r = stalled_src.read(&mut buf);
        (r.is_err() || matches!(r, Ok(0)), t0.elapsed())
    });

    let mut assembled = vec![0u8; wav_data.len()];
    let mut read_total = 0usize;
    while read_total < assembled.len() {
        let n = active_src.read(&mut assembled[read_total..]).expect("short-read source failed");
        if n == 0 {
            break;
        }
        read_total += n;
    }
    assert_eq!(&assembled[..read_total], wav_data.as_slice());

    assert!(spin_yield_until(Duration::from_secs(2), || {
        blocked_dispatched.load(Ordering::Acquire)
    }));
    registry.abort_all();
    let (aborted_ok, abort_time) = blocked_jh.join().unwrap();
    assert!(aborted_ok && abort_time < Duration::from_secs(1));

    // 3. Parallel analyze_audio_source across WAV/MP3/FLAC/Opus + corrupted payload rejection
    let fixtures = ["salida.wav", "salida.mp3", "salida.flac", "salida.opus"];
    let b_analyze = Arc::new(Barrier::new(6));
    let mut a_handles = Vec::with_capacity(6);

    for tid in 0..6 {
        let b = b_analyze.clone();
        let path = FixtureResolver::resolve_str(fixtures[tid % fixtures.len()]);
        let corrupt = vec![0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03];
        a_handles.push(thread::spawn(move || {
            b.wait();
            let valid_res = analyze_audio_source(
                RustAudioSource {
                    id: (tid + 1) as i64,
                    source: path,
                    ..Default::default()
                },
                None,
                RustAnalysisConfig {
                    replay_gain: true,
                    waveform: true,
                    metadata: true,
                    chromaprint: false,
                    waveform_points: 64,
                    target_lufs: -18.0,
                    max_duration_ms: Some(1500),
                },
            )
            .expect("Valid fixture analysis must succeed under concurrency");
            assert!(valid_res.has_replay_gain);
            assert!(valid_res.has_waveform && valid_res.waveform_peaks.len() == 64);

            let corrupt_res = analyze_audio_source(
                RustAudioSource {
                    id: (tid + 100) as i64,
                    source: "memory://corrupt.bin".to_string(),
                    data_bytes: Some(corrupt),
                    ..Default::default()
                },
                None,
                RustAnalysisConfig::default(),
            );
            assert!(corrupt_res.is_err(), "Corrupt bytes must fail cleanly with Err");
        }));
    }

    for h in a_handles {
        h.join().expect("Concurrent offline analysis panicked");
    }
}

#[test]
fn scenario_5_hardware_routing_capture_ducking_and_mid_crossfade_recording() {
    let temp_dir = std::env::temp_dir().join(format!(
        "map_hw_rec_matrix_{}_{:?}",
        std::process::id(),
        thread::current().id()
    ));
    std::fs::create_dir_all(&temp_dir).expect("Create temp dir");

    // Part A: Public RustMiniaudioPlayer concurrent hardware matrix + crossfade + recording
    let rec_pub_path = temp_dir.join("pub_matrix.wav");
    let player = Arc::new(
        RustMiniaudioPlayer::new(
            RustPlayerConfig::default(),
            48_000,
            2,
            1024,
            vec![RustAudioOutput {
                device_id: "AUTO".to_string(),
                source: 0,
            }],
        )
        .expect("Failed to create RustMiniaudioPlayer"),
    );

    let wav_a = SignalGenerator::pcm16_wav_bytes(96_000, 48_000, 2);
    let wav_b = SignalGenerator::pcm16_wav_bytes(96_000, 48_000, 2);
    player.set_crossfade(RustCrossfadeConfig {
        auto_duration_ms: 300,
        manual_duration_ms: 150,
        curve: 0,
    });
    player
        .set_queue(vec![
            RustAudioSource {
                id: 1,
                source: "memory://a.wav".to_string(),
                data_bytes: Some(wav_a.clone()),
                ..Default::default()
            },
            RustAudioSource {
                id: 2,
                source: "memory://b.wav".to_string(),
                data_bytes: Some(wav_b.clone()),
                ..Default::default()
            },
        ])
        .expect("set_queue failed");
    player.play(Some(1), None, None, Some(0)).expect("play failed");
    player
        .start_recording(rec_pub_path.to_string_lossy().to_string(), 0 /* Pcm16 */, 0)
        .expect("start_recording failed");

    let b = Arc::new(Barrier::new(6));
    let mut handles = Vec::with_capacity(6);
    for tid in 0..6 {
        let p = player.clone();
        let b_c = b.clone();
        handles.push(thread::spawn(move || {
            b_c.wait();
            for step in 0..10 {
                match tid % 3 {
                    0 => match step % 4 {
                        0 => {
                            let _ = p.set_outputs(vec![RustAudioOutput {
                                device_id: "AUTO".to_string(),
                                source: 0,
                            }]);
                        }
                        1 => {
                            let _ = p.add_output(RustAudioOutput {
                                device_id: "AUTO".to_string(),
                                source: 1,
                            });
                        }
                        2 => {
                            let _ = p.set_outputs(vec![]);
                        }
                        _ => {
                            let _ = p.remove_output(RustAudioOutput {
                                device_id: "AUTO".to_string(),
                                source: 1,
                            });
                        }
                    },
                    1 => {
                        let duck = Some(RustDuckingConfig {
                            enabled: true,
                            ducking_db: -16.0,
                            threshold_db: -32.0,
                            attack_ms: 20.0,
                            hold_ms: 150.0,
                            release_ms: 250.0,
                        });
                        match step % 3 {
                            0 => {
                                let _ = p.set_inputs(vec![RustAudioInput {
                                    device_id: "AUTO".to_string(),
                                    config: RustAudioInputConfig {
                                        volume: 0.85,
                                        ducking: duck,
                                        monitor_direct: false,
                                        monitor_volume: 1.0,
                                    },
                                }]);
                            }
                            1 => {
                                let _ = p.configure_input(
                                    "AUTO".to_string(),
                                    RustAudioInputConfig {
                                        volume: 0.65,
                                        ducking: duck,
                                        monitor_direct: false,
                                        monitor_volume: 0.5,
                                    },
                                );
                            }
                            _ => {
                                let _ = p.remove_input(RustAudioInput {
                                    device_id: "AUTO".to_string(),
                                    config: RustAudioInputConfig::default(),
                                });
                            }
                        }
                    }
                    _ => {
                        if step % 2 == 0 {
                            let _ = p.next(Some(80));
                        } else {
                            let _ = p.previous();
                        }
                        p.set_visualizer_source((step % 5) as i32);
                    }
                }
            }
        }));
    }
    for h in handles {
        h.join().expect("Hardware matrix thread panicked");
    }

    let pub_rec = player.stop_recording().expect("stop_recording failed");
    assert!(pub_rec.bytes_written >= 44);
    assert!(rec_pub_path.exists());
    player.stop();
    player.dispose();

    // Part B: Deterministic mid-crossfade EngineActorHandle + HardwareDeviceSupervisor recording flush
    let rec_det_path = temp_dir.join("det_crossfade_rec.wav");
    let trigger = Arc::new((Mutex::new(false), Condvar::new()));
    let custom_reg = CustomSourceRegistry::new();
    let (engine, _nrx, hrx) = EngineActorHandle::spawn(
        48_000,
        2,
        512,
        MAX_VOICES,
        None,
        Some(trigger.clone()),
        false,
        0,
        vec![],
    )
    .expect("spawn failed");
    let coord = ControlCoordinator::spawn(engine.clone(), custom_reg.clone(), hrx, Arc::new(|_| {}));
    let hw = HardwareDeviceSupervisor::new(engine.clone(), engine.reaper().clone(), trigger);

    let fac = Arc::new(|sid, sz| {
        CustomDartByteSource::with_registry(sid, sz, true, Arc::new(|_| {}), None)
    });
    coord
        .set_queue(
            vec![
                AudioSourceCore {
                    id: 1,
                    source: "memory://det1.wav".to_string(),
                    headers: None,
                    data_bytes: Some(wav_a),
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
                AudioSourceCore {
                    id: 2,
                    source: "memory://det2.wav".to_string(),
                    headers: None,
                    data_bytes: Some(wav_b),
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
            ],
            fac,
        )
        .expect("coord set_queue failed");
    engine
        .exec(|ply| ply.music_manager.set_crossfade(250, 150, 0))
        .expect("set_crossfade failed");
    coord.play(Some(1), None, None, Some(0), false).expect("play failed");
    hw.start_recording(
        rec_det_path.to_string_lossy().to_string(),
        WavFormat::Pcm16,
        miniaudio_player::api::types::AudioOutputSource::All,
    )
    .expect("hw start_recording failed");

    let _ = coord.next(Some(150), false);
    assert!(
        spin_yield_until(Duration::from_secs(3), || {
            engine.snapshots().recorded_duration_ms() >= 60
        }),
        "Mid-crossfade live recording did not accumulate >= 60ms deterministically"
    );

    let (_p, dur_ms, bytes_written, sample_count, _dropped_frames) =
        hw.stop_recording().expect("hw stop_recording failed");
    assert!(dur_ms >= 50);
    assert!(bytes_written > 44);
    assert!(sample_count > 0);
    let raw = std::fs::read(&rec_det_path).expect("Det WAV missing");
    assert_eq!(&raw[0..4], b"RIFF");
    assert_eq!(&raw[8..12], b"WAVE");

    coord.shutdown();
    engine.shutdown();
    let _ = std::fs::remove_dir_all(&temp_dir);
}

#[test]
fn scenario_6_event_reporter_and_ui_snapshots_ordering_coherence() {
    let custom_reg = CustomSourceRegistry::new();
    let (engine, _nrx, hrx) = EngineActorHandle::spawn(
        48_000,
        2,
        512,
        MAX_VOICES,
        None,
        None,
        false,
        0,
        vec![],
    )
    .expect("spawn failed");
    let coord = ControlCoordinator::spawn(engine.clone(), custom_reg, hrx, Arc::new(|_| {}));

    let wav_a = SignalGenerator::pcm16_wav_bytes(96_000, 48_000, 2);
    let wav_b = SignalGenerator::pcm16_wav_bytes(96_000, 48_000, 2);
    let fac = Arc::new(|sid, sz| {
        CustomDartByteSource::with_registry(sid, sz, true, Arc::new(|_| {}), None)
    });
    coord
        .set_queue(
            vec![
                AudioSourceCore {
                    id: 1,
                    source: "memory://snap1.wav".to_string(),
                    headers: None,
                    data_bytes: Some(wav_a),
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
                AudioSourceCore {
                    id: 2,
                    source: "memory://snap2.wav".to_string(),
                    headers: None,
                    data_bytes: Some(wav_b),
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
            ],
            fac,
        )
        .expect("set_queue failed");
    let _ = coord.play(Some(1), None, None, Some(0), false);

    let reporter = Arc::new(EventReporter::new());
    let threads = 12usize;
    let barrier = Arc::new(Barrier::new(threads));
    let mut handles = Vec::with_capacity(threads);

    for tid in 0..threads {
        let eng = engine.clone();
        let rep = reporter.clone();
        let b = barrier.clone();

        handles.push(thread::spawn(move || {
            b.wait();
            if tid < 6 {
                // Concurrent EventReporter multi-publisher load
                for step in 0..100 {
                    rep.emit(RustPlayerEvent::Position((tid * 1000 + step * 15) as i64));
                    rep.emit(RustPlayerEvent::CurrentIndex((step % 2) as i32));
                    rep.emit(RustPlayerEvent::IsCrossfading(step % 3 == 0));
                    rep.emit(RustPlayerEvent::RecordedDuration(step as u64 * 16));
                    rep.emit(RustPlayerEvent::Visualizer(RustVisualizerData {
                        bands: vec![0.1, 0.2, 0.3],
                        rms: 0.25,
                        peak: 0.5,
                        left: 0.25,
                        right: 0.25,
                    }));
                }
            } else if tid < 10 {
                // Tight wait-free snapshot reader coherence assertions
                for _ in 0..20_000 {
                    let s = eng.snapshots();
                    let _ = s.playback_state();
                    let _ = s.is_xfading();
                    let _ = s.is_recording();
                    let _ = s.recorded_duration_ms();
                    let _ = s.is_ducking();
                    assert!(s.position_ms() >= 0);
                    assert!(s.current_index() >= -1);
                    let _ = s.audio_info();
                    let _ = s.parsed_metadata();
                    let vis = s.read_visualizer();
                    assert!(vis.rms.is_finite() && vis.peak.is_finite());
                    let _ = s.outputs();
                    let _ = s.inputs();
                }
            } else {
                // Concurrent snapshot metadata/output/visualizer updaters
                for step in 0..100 {
                    eng.snapshots().set_outputs_snapshot(vec![RustAudioOutput {
                        device_id: format!("dev_{}", step % 3),
                        source: (step % 4) as i32,
                    }]);
                    let _ = eng.exec(move |ply| {
                        ply.output_manager.set_visualizer_enabled(step % 2 == 0);
                        ply.output_manager
                            .set_visualizer_source(miniaudio_player::api::types::AudioOutputSource::from((step % 5) as i32));
                    });
                }
            }
        }));
    }

    for h in handles {
        h.join().expect("Snapshot/reporter ordering thread panicked");
    }

    coord.shutdown();
    engine.shutdown();
}

#[test]
fn scenario_7_rapid_lifecycle_churn_25_cycles() {
    let wav = SignalGenerator::pcm16_wav_bytes(24_000, 48_000, 2);
    let local_wav = FixtureResolver::resolve_str("salida.wav");

    for cycle in 0..25usize {
        let player = Arc::new(
            RustMiniaudioPlayer::new(RustPlayerConfig::default(), 48_000, 2, 512, vec![])
                .expect("Lifecycle churn RustMiniaudioPlayer::new failed"),
        );

        let _ = player.set_effects(vec![RustAudioEffect {
            id: "churn_sfx".to_string(),
            source: RustAudioSource {
                id: 100 + cycle as i64,
                source: "memory://churn.wav".to_string(),
                data_bytes: Some(wav.clone()),
                ..Default::default()
            },
            max_polyphony: 8,
            pinned: false,
        }]);

        let _ = player.set_queue(vec![
            RustAudioSource {
                id: (cycle * 3 + 1) as i64,
                source: local_wav.clone(),
                ..Default::default()
            },
            RustAudioSource {
                id: (cycle * 3 + 2) as i64,
                source: "memory://mem_churn.wav".to_string(),
                data_bytes: Some(wav.clone()),
                ..Default::default()
            },
            RustAudioSource {
                id: (cycle * 3 + 3) as i64,
                source: "/nonexistent/churn_err.wav".to_string(),
                ..Default::default()
            },
        ]);

        let barrier = Arc::new(Barrier::new(6));
        let mut workers = Vec::with_capacity(6);
        for wid in 0..6 {
            let p = player.clone();
            let b = barrier.clone();
            workers.push(thread::spawn(move || {
                b.wait();
                match wid {
                    0 => {
                        let _ = p.play(None, Some(0), Some(cycle % 2 == 0), Some(0));
                        let _ = p.next(Some(50));
                    }
                    1 => {
                        let _ = p.seek(50);
                        p.pause();
                    }
                    2 => {
                        let _ = p.play_effect(
                            "churn_sfx".to_string(),
                            RustEffectConfig {
                                volume: 0.4,
                                looping: true,
                                ..Default::default()
                            },
                        );
                    }
                    3 => {
                        let _ = p.set_equalizer(RustEqualizerParams {
                            gains: vec![2.0; 10],
                            enabled: true,
                        });
                        p.set_limiter(true);
                    }
                    4 => {
                        p.set_visualizer_enabled(true);
                        let _ = p.set_reverb(RustReverbParams {
                            room_size: 0.4,
                            damping: 0.5,
                            wet: 0.3,
                            dry: 1.0,
                            width: 1.0,
                            mode: 0.0,
                            enabled: true,
                        });
                    }
                    _ => {
                        // Dispose races intentionally against active workers on every cycle
                        p.dispose();
                    }
                }
            }));
        }

        for w in workers {
            w.join().expect("Lifecycle churn worker panicked");
        }
        // Idempotent second dispose ensures complete thread cleanup before next cycle
        player.dispose();
    }
}
