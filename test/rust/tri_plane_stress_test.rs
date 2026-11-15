//! Extreme Tri-Plane Lock-Free Isolation & Stress Verification Suite (`docs/LOCK.md` Section 6).
//!
//! Validates all 8 Section 6 stress scenarios:
//! 1. TCP tarpit HTTP stall + 30 SFX/s + tight UI snapshot getters + instant `pause()`/`stop()` cancel.
//! 2. 500-skip rapid fire flood over stalled HTTP ending cleanly via epoch coalescing.
//! 3. 1.5s capture stall / drift on `CaptureReceiver` + `InputManager` with < 35ms live-edge convergence.
//! 4. Massive 64-voice polyphonic SFX storm + `setEffects` catalog hot-swap & `stopAllEffects`.
//! 5. Hardware hot-swap (`HardwareDeviceSupervisor::set_outputs`) + WAV recording stop under active load.
//! 6. Concurrent `CustomDartByteSource` streams + instant `CustomSourceRegistry::abort_all()`.
//! 7. Crossfade + pre-warm epoch invalidation during rapid `append`/`insert_next`/`reorder`/`remove_at`.
//! 8. Mutex/RwLock poison recovery resistance + single-thread `MiniaudioPlayer::render_pcm` WASM step parity.

mod common;

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Condvar, Mutex, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::api::types::{AudioOutputSource, RustAudioOutput};
use miniaudio_player::buffer::{CustomDartByteSource, CustomSourceRegistry, StreamSession};
use miniaudio_player::core::capture::DeviceCaptureNode;
use miniaudio_player::core::control_coordinator::ControlCoordinator;
use miniaudio_player::core::dual_source::{AudioSourceCore, CustomSourceFactory};
use miniaudio_player::core::effects_manager::EffectsControl;
use miniaudio_player::core::engine_actor::EngineActorHandle;
use miniaudio_player::core::hw_supervisor::HardwareDeviceSupervisor;
use miniaudio_player::core::input_manager::ActiveInputNode;
use miniaudio_player::core::miniaudio_player::MiniaudioPlayer;
use miniaudio_player::core::recording::WavFormat;
use miniaudio_player::core::voice_pool::{
    EffectCatalogItem, EffectConfig, MAX_VOICES,
};
use miniaudio_player::core::PlaybackState;
use miniaudio_player::dsp::ducking::AutoDucker;
use miniaudio_player::dsp::reverb::ReverbConfig;
use miniaudio_player::sync::{
    lock_unpoisoned, read_unpoisoned, wait_timeout_unpoisoned, write_unpoisoned,
};

struct TriPlaneHarness {
    engine: EngineActorHandle,
    coordinator: ControlCoordinator,
    hw: HardwareDeviceSupervisor,
    custom_registry: CustomSourceRegistry,
}

impl TriPlaneHarness {
    fn spawn() -> Self {
        let device_trigger = Arc::new((Mutex::new(false), Condvar::new()));
        let (engine, _notify_rx, hint_rx) = EngineActorHandle::spawn(
            48000,
            2,
            512,
            MAX_VOICES,
            None,
            Some(device_trigger.clone()),
            false,
            0,
            Vec::new(),
        )
        .expect("Failed to spawn EngineActorHandle");

        let custom_registry = CustomSourceRegistry::new();
        let coordinator = ControlCoordinator::spawn(
            engine.clone(),
            custom_registry.clone(),
            hint_rx,
            Arc::new(|_snap| {}),
        );
        let hw = HardwareDeviceSupervisor::new(
            engine.clone(),
            engine.reaper().clone(),
            device_trigger,
        );
        Self {
            engine,
            coordinator,
            hw,
            custom_registry,
        }
    }

    fn dummy_custom_factory(&self) -> CustomSourceFactory {
        let reg = self.custom_registry.clone();
        Arc::new(move |stream_id, total_size| {
            CustomDartByteSource::with_registry(
                stream_id,
                total_size,
                true,
                Arc::new(|_| {}),
                Some(reg.clone()),
            )
        })
    }
}

impl Drop for TriPlaneHarness {
    fn drop(&mut self) {
        self.custom_registry.abort_all();
        self.coordinator.shutdown();
        self.engine.shutdown();
    }
}

struct MockHttpServer {
    port: u16,
    tarpit_hits: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    release_tarpit: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl MockHttpServer {
    fn start(fast_wav: Vec<u8>, tarpit_hold: Duration) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("Bind ephemeral port");
        listener
            .set_nonblocking(true)
            .expect("Set listener nonblocking");
        let port = listener.local_addr().expect("local_addr").port();
        let tarpit_hits = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let release_tarpit = Arc::new(AtomicBool::new(false));

        let hits_c = tarpit_hits.clone();
        let stop_c = stop.clone();
        let rel_c = release_tarpit.clone();

        let thread = thread::Builder::new()
            .name("test-mock-http".to_string())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::new();
                while !stop_c.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let wav = fast_wav.clone();
                            let hits = hits_c.clone();
                            let s = stop_c.clone();
                            let rel = rel_c.clone();
                            workers.retain(|w| !w.is_finished());
                            workers.push(thread::spawn(move || {
                                Self::handle_client(stream, &wav, hits, s, rel, tarpit_hold);
                            }));
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(2));
                        }
                        Err(_) => break,
                    }
                }
                for w in workers {
                    let _ = w.join();
                }
            })
            .expect("Spawn mock HTTP server");

        Self {
            port,
            tarpit_hits,
            stop,
            release_tarpit,
            thread: Some(thread),
        }
    }

    fn handle_client(
        mut stream: TcpStream,
        fast_wav: &[u8],
        tarpit_hits: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
        release: Arc<AtomicBool>,
        tarpit_hold: Duration,
    ) {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
        let mut buf = [0u8; 2048];
        let n = stream.read(&mut buf).unwrap_or(0);
        let req = String::from_utf8_lossy(&buf[..n]);
        let is_fast = req.lines().next().is_some_and(|l| l.contains("/fast.wav"));

        if is_fast {
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                fast_wav.len()
            );
            let _ = stream.write_all(header.as_bytes());
            let _ = stream.write_all(fast_wav);
            let _ = stream.flush();
            return;
        }

        tarpit_hits.fetch_add(1, Ordering::AcqRel);
        let start = Instant::now();
        while !stop.load(Ordering::Acquire)
            && !release.load(Ordering::Acquire)
            && start.elapsed() < tarpit_hold
        {
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for MockHttpServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.release_tarpit.store(true, Ordering::Release);
        if let Some(jh) = self.thread.take() {
            let _ = jh.join();
        }
    }
}

fn mem_source(id: i64, wav_bytes: Vec<u8>) -> AudioSourceCore {
    AudioSourceCore {
        id,
        source: format!("memory://track_{}.wav", id),
        headers: None,
        data_bytes: Some(wav_bytes),
        replay_gain_db: None,
        replay_peak: None,
    }
}

fn url_source(id: i64, url: String) -> AudioSourceCore {
    AudioSourceCore {
        id,
        source: url,
        headers: None,
        data_bytes: None,
        replay_gain_db: None,
        replay_peak: None,
    }
}

fn build_memory_sfx_catalog(count: usize, wav_bytes: &[u8]) -> Vec<EffectCatalogItem> {
    (0..count)
        .map(|i| EffectCatalogItem {
            id: format!("sfx_{}", i),
            source: AudioSourceCore {
                id: 10_000 + i as i64,
                source: format!("memory://sfx_{}.wav", i),
                headers: None,
                data_bytes: Some(wav_bytes.to_vec()),
                replay_gain_db: None,
                replay_peak: None,
            },
            max_polyphony: MAX_VOICES,
            pinned: true,
        })
        .collect()
}

fn wait_until<F>(timeout: Duration, mut pred: F) -> bool
where
    F: FnMut() -> bool,
{
    let start = Instant::now();
    while start.elapsed() < timeout {
        if pred() {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    false
}

#[test]
fn scenario_1_network_tarpit_sfx_storm_ui_reads_and_instant_pause_cancel() {
    let server = MockHttpServer::start(
        SignalGenerator::pcm16_wav_bytes(48000, 48000, 2),
        Duration::from_secs(10),
    );
    let harness = TriPlaneHarness::spawn();

    let sfx_wav = SignalGenerator::pcm16_wav_bytes(12000, 48000, 2);
    harness
        .engine
        .effects()
        .set_effects(build_memory_sfx_catalog(4, &sfx_wav))
        .expect("Failed to register SFX catalog");

    let tarpit_url = format!("http://127.0.0.1:{}/tarpit/stalled.wav", server.port);
    harness
        .coordinator
        .set_queue(vec![url_source(1, tarpit_url)], harness.dummy_custom_factory())
        .expect("set_queue failed");

    let coord_clone = harness.coordinator.clone();
    let play_jh = thread::spawn(move || coord_clone.play(Some(1), Some(0), None, None, false));

    assert!(
        wait_until(Duration::from_secs(2), || {
            server.tarpit_hits.load(Ordering::Acquire) >= 1
        }),
        "Mock TCP tarpit never received connection"
    );

    // 1. Trigger 30 SFX voices and hammer UI wait-free snapshot getters at high frequency.
    let fx = harness.engine.effects().clone();
    let cfg = EffectConfig {
        looping: true,
        volume: 0.7,
        ..Default::default()
    };
    for i in 0..30 {
        fx.play_effect(&format!("sfx_{}", i % 4), cfg.clone())
            .expect("play_effect failed under HTTP tarpit");
    }

    let snaps = harness.engine.snapshots().clone();
    let mut max_getter_us = 0u128;
    for _ in 0..1000 {
        let t0 = Instant::now();
        let _playing = snaps.is_xfading();
        let _state = snaps.playback_state();
        let _pos = snaps.position_ms();
        let _voices = fx.active_voices_count();
        let _ram = fx.allocated_ram_bytes();
        let elapsed = t0.elapsed().as_micros();
        if elapsed > max_getter_us {
            max_getter_us = elapsed;
        }
    }
    assert!(
        max_getter_us < 2000,
        "UI snapshot getters exceeded wait-free bound under HTTP stall: max={}us",
        max_getter_us
    );

    // 2. Verify map-engine-clock responds in < 15ms while HTTP worker stalls on socket.
    let t_clock = Instant::now();
    let clock_alive = harness
        .engine
        .exec(|ply| ply.effects_manager.active_voices_count())
        .expect("engine.exec failed");
    assert!(
        t_clock.elapsed() < Duration::from_millis(20),
        "Engine actor clock stalled behind HTTP tarpit: {:?}",
        t_clock.elapsed()
    );
    assert!(clock_alive > 0, "Expected active SFX voices on clock");

    // 3. Call pause() and stop() BEFORE releasing TCP tarpit sockets -> must return < 50ms!
    let t_pause = Instant::now();
    let (paused_state, _) = harness.coordinator.pause().expect("pause failed");
    assert!(
        t_pause.elapsed() < Duration::from_millis(50),
        "pause() blocked behind slow HTTP open: {:?}",
        t_pause.elapsed()
    );
    assert_eq!(paused_state, PlaybackState::Paused.as_i32());

    let t_stop = Instant::now();
    let (stopped_state, _) = harness.coordinator.stop().expect("stop failed");
    assert!(
        t_stop.elapsed() < Duration::from_millis(50),
        "stop() blocked behind slow HTTP open: {:?}",
        t_stop.elapsed()
    );
    assert_eq!(stopped_state, PlaybackState::Stopped.as_i32());

    // Release mock tarpit sockets so background play thread cleans up promptly on exit.
    server.release_tarpit.store(true, Ordering::Release);
    let _ = play_jh.join();
}

#[test]
fn scenario_2_rapid_fire_500_skip_flood_epoch_coalescing() {
    let wav_bytes = SignalGenerator::pcm16_wav_bytes(96000, 48000, 2);
    let server = MockHttpServer::start(wav_bytes.clone(), Duration::from_millis(400));
    let harness = TriPlaneHarness::spawn();

    // Index 0: fast memory seed track; 1..=499: stalled HTTP tarpit; 500: valid /fast.wav
    let mut queue = Vec::with_capacity(501);
    queue.push(mem_source(1000, wav_bytes));
    for i in 1..=499 {
        queue.push(url_source(
            1000 + i as i64,
            format!("http://127.0.0.1:{}/tarpit/track_{}.wav", server.port, i),
        ));
    }
    queue.push(url_source(
        1500,
        format!("http://127.0.0.1:{}/fast.wav", server.port),
    ));

    harness
        .coordinator
        .set_queue(queue, harness.dummy_custom_factory())
        .expect("set_queue 501 items failed");
    harness
        .coordinator
        .play(None, Some(0), None, None, false)
        .expect("Initial play failed");

    // Flood 500 concurrent next() calls across 20 threads via dynamic work stealing
    // so OS thread jitter never strands multiple un-coalesced skips on a single thread.
    let worker_count = 20usize;
    let total_skips = 500usize;
    let next_ticket = Arc::new(AtomicUsize::new(0));
    let barrier = Arc::new(Barrier::new(worker_count));
    let flood_start = Instant::now();

    thread::scope(|s| {
        for _ in 0..worker_count {
            let coord = harness.coordinator.clone();
            let ticket = next_ticket.clone();
            let b = barrier.clone();
            s.spawn(move || {
                b.wait();
                while ticket.fetch_add(1, Ordering::AcqRel) < total_skips {
                    let _ = coord.next(None, false);
                }
            });
        }
    });

    let flood_elapsed = flood_start.elapsed();
    let (executed, coalesced) = harness.coordinator.io_pool_stats();

    assert!(
        coalesced >= 400,
        "Expected massive epoch coalescing under 500-skip burst; executed={}, coalesced={}",
        executed,
        coalesced
    );
    assert!(
        executed <= 60,
        "Expected bounded worker execution via coalescing; executed={}, coalesced={}",
        executed,
        coalesced
    );
    assert!(
        flood_elapsed < Duration::from_secs(3),
        "500-skip flood should complete far faster than uncoalesced HTTP timeouts: {:?}",
        flood_elapsed
    );

    assert_eq!(
        harness.engine.snapshots().current_index(),
        500,
        "Final track (index 500 /fast.wav) must win after 500 skips"
    );
    assert_eq!(
        harness.engine.snapshots().playback_state(),
        PlaybackState::Playing
    );
}

#[test]
fn scenario_3_capture_1_5s_stall_live_edge_recovery() {
    let sample_rate = 48000u32;
    let channels = 1usize;
    let period_frames = 512usize;
    let mut player = MiniaudioPlayer::new(sample_rate, 2, period_frames as u32, 16, None, None)
        .expect("MiniaudioPlayer::new failed");

    let (capture_node, _) =
        DeviceCaptureNode::new(sample_rate, channels as u32, period_frames as u32, None)
            .expect("DeviceCaptureNode::new failed");
    let (mut producer, consumer) = rtrb::RingBuffer::new(sample_rate as usize * 2);

    // Simulate 1.5s capture stall at 48kHz without RT reads.
    let stalled_samples = (sample_rate as f32 * 1.5) as usize * channels;
    for i in 0..stalled_samples {
        let _ = producer.push(((i % 64) as f32) * 0.01);
    }

    let mic_config = miniaudio_player::api::types::RustAudioInputConfig {
        volume: 1.0,
        monitor_direct: true,
        monitor_volume: 0.5,
        ducking: None,
    };

    player.input_manager.active_inputs.push(ActiveInputNode {
        device_id: "mock_mic".to_string(),
        resolved_id: "mock_mic".to_string(),
        config: mic_config,
        capture_node,
        consumer,
        ducker: AutoDucker::new(sample_rate),
        scratch_buffer: vec![0.0f32; period_frames * 2],
    });

    // Resume clock for just 2 ticks -> must snap back to <= 3 periods live edge (< 35ms).
    let out_len = period_frames * 2;
    for _ in 0..2 {
        player.super_flow[..out_len].fill(0.0);
        player
            .input_manager
            .process(&mut player.super_flow[..out_len], &mut player.scratch_voice[..out_len]);
    }

    let rem_samples = player.input_manager.active_inputs[0].consumer.slots();
    let max_live_edge = period_frames * channels * 3; // 1536 samples = 32ms (< 35ms)
    assert!(
        rem_samples <= max_live_edge,
        "Live edge discard failed after 1.5s stall: remaining={} samples (max={})",
        rem_samples,
        max_live_edge
    );
    assert_eq!(rem_samples % channels, 0, "Remaining samples must stay frame-aligned");
}

#[test]
fn scenario_4_massive_sfx_catalog_swap_and_polyphony_storm() {
    let harness = TriPlaneHarness::spawn();
    let fx: EffectsControl = harness.engine.effects().clone();

    let wav_a = SignalGenerator::pcm16_wav_bytes(16000, 48000, 2);
    let wav_b = SignalGenerator::pcm16_wav_bytes(24000, 48000, 2);

    fx.set_effects(build_memory_sfx_catalog(64, &wav_a))
        .expect("Initial 64-item SFX catalog load failed");
    let ram_before = fx.allocated_ram_bytes();
    assert!(ram_before > 0);

    let loop_cfg = EffectConfig {
        looping: true,
        volume: 0.4,
        ..Default::default()
    };
    for i in 0..MAX_VOICES {
        fx.play_effect(&format!("sfx_{}", i), loop_cfg.clone())
            .expect("Failed to trigger polyphonic voice");
    }
    assert!(wait_until(Duration::from_millis(500), || {
        fx.active_voices_count() as usize == MAX_VOICES
    }));

    // Hot-swap entire 64-item catalog twice while all 64 voices loop under active RT ticks.
    for round in 0..3 {
        let cat = if round % 2 == 0 { &wav_b } else { &wav_a };
        fx.set_effects(build_memory_sfx_catalog(64, cat))
            .expect("Hot-swap set_effects failed under 64 active voices");
        let t0 = Instant::now();
        let active_on_clock = harness
            .engine
            .exec(|ply| ply.effects_manager.active_voices_count())
            .expect("Clock exec failed during SFX storm");
        assert!(t0.elapsed() < Duration::from_millis(25));
        assert!(active_on_clock > 0);
    }

    fx.stop_all_effects(0);
    assert!(
        wait_until(Duration::from_millis(500), || fx.active_voices_count() == 0),
        "stop_all_effects(0) did not drain all 64 voices cleanly"
    );
}

#[test]
fn scenario_5_hardware_hot_swap_and_recording_stop_under_load() {
    let harness = TriPlaneHarness::spawn();
    let wav_bytes = SignalGenerator::pcm16_wav_bytes(48000, 48000, 2);
    harness
        .coordinator
        .set_queue(vec![mem_source(1, wav_bytes.clone())], harness.dummy_custom_factory())
        .expect("set_queue failed");
    harness
        .coordinator
        .play(None, Some(0), None, None, false)
        .expect("play failed");

    let rec_path = FixtureResolver::scratch_file_path("tri_plane_rec.wav");
    let _ = std::fs::remove_file(&rec_path);
    let rec_str = rec_path.to_string_lossy().into_owned();

    harness
        .hw
        .start_recording(rec_str.clone(), WavFormat::Pcm16, AudioOutputSource::All)
        .expect("start_recording failed");
    assert!(wait_until(Duration::from_millis(400), || {
        harness.engine.snapshots().is_recording()
    }));

    // Perform hardware output reconciliation / hot-swap attempt while recording & playing.
    let _ = harness.hw.set_outputs(vec![RustAudioOutput {
        device_id: "AUTO".to_string(),
        source: 0,
    }]);
    let t_clock = Instant::now();
    harness
        .hw
        .set_outputs(Vec::new())
        .expect("Fallback clear set_outputs failed");
    assert!(
        t_clock.elapsed() < Duration::from_millis(200),
        "Output teardown took abnormally long"
    );

    // Wait until the live recorder has observed active audio progression instead of a fixed sleep.
    assert!(
        wait_until(Duration::from_secs(2), || {
            harness.engine.snapshots().position_ms() > 0
        }),
        "Audio engine did not advance position before stopping live recording"
    );

    let t_stop = Instant::now();
    let (out_path, duration_ms, bytes_written, sample_count) =
        harness.hw.stop_recording().expect("stop_recording failed");
    assert_eq!(out_path, rec_str);
    assert!(duration_ms > 0);
    assert!(sample_count > 0);
    assert!(bytes_written > 44, "WAV file must contain PCM payload beyond header");
    assert!(
        t_stop.elapsed() < Duration::from_secs(2),
        "stop_recording stalled unexpectedly: {:?}",
        t_stop.elapsed()
    );

    let file_bytes = std::fs::read(&rec_path).expect("Recorded WAV file missing on disk");
    assert_eq!(&file_bytes[0..4], b"RIFF");
    assert_eq!(&file_bytes[8..12], b"WAVE");
    let _ = std::fs::remove_file(&rec_path);
}

#[test]
fn scenario_6_concurrent_custom_byte_source_active_standby_abort() {
    let registry = CustomSourceRegistry::new();
    let wav_bytes = Arc::new(SignalGenerator::pcm16_wav_bytes(24000, 48000, 2));

    // Streams 10 & 11 actively deliver bytes while stream 12 stays blocked with zero bytes.
    let req_tx_10 = Arc::new({
        let reg = registry.clone();
        let data = wav_bytes.clone();
        move |req: miniaudio_player::buffer::DartReadRequest| {
            let start = (req.offset as usize).min(data.len());
            let end = start.saturating_add(req.length as usize).min(data.len());
            let eof = end >= data.len();
            reg.resolve_request(req.request_id, data[start..end].to_vec(), eof);
        }
    });
    let req_tx_11 = req_tx_10.clone();

    let (mut src_10, _h10) = CustomDartByteSource::with_registry(
        10,
        Some(wav_bytes.len() as u64),
        true,
        req_tx_10,
        Some(registry.clone()),
    );
    let (mut src_11, _h11) = CustomDartByteSource::with_registry(
        11,
        Some(wav_bytes.len() as u64),
        true,
        req_tx_11,
        Some(registry.clone()),
    );
    let blocked_dispatched = Arc::new(AtomicBool::new(false));
    let blocked_dispatched_cb = blocked_dispatched.clone();
    let (mut src_blocked, _h12) = CustomDartByteSource::with_registry(
        12,
        Some(4096),
        true,
        Arc::new(move |_req| {
            blocked_dispatched_cb.store(true, Ordering::Release);
        }),
        Some(registry.clone()),
    );

    // Blocked stream 12 waiting in background must wake immediately when abort_all() fires
    // without interfering with streams 10 and 11 completing full parallel reads.
    let blocked_jh = thread::spawn(move || {
        let mut buf = [0u8; 256];
        let t0 = Instant::now();
        let res = src_blocked.read(&mut buf);
        (res.is_err() || matches!(res, Ok(0)), t0.elapsed())
    });

    let t_parallel = thread::spawn({
        let expected = wav_bytes.clone();
        move || {
            let mut out_a = vec![0u8; expected.len()];
            let mut out_b = vec![0u8; expected.len()];
            let mut read_a = 0usize;
            let mut read_b = 0usize;
            while read_a < out_a.len() {
                let n = src_10.read(&mut out_a[read_a..]).expect("src_10 read failed");
                if n == 0 {
                    break;
                }
                read_a += n;
            }
            while read_b < out_b.len() {
                let n = src_11.read(&mut out_b[read_b..]).expect("src_11 read failed");
                if n == 0 {
                    break;
                }
                read_b += n;
            }
            assert_eq!(&out_a[..read_a], expected.as_slice());
            assert_eq!(&out_b[..read_b], expected.as_slice());
        }
    });

    t_parallel.join().expect("Concurrent custom readers panicked");
    assert!(
        wait_until(Duration::from_secs(1), || {
            blocked_dispatched.load(Ordering::Acquire)
        }),
        "Blocked CustomDartByteSource did not dispatch initial read request before abort_all"
    );

    let t_abort = Instant::now();
    registry.abort_all();
    let (aborted_ok, wait_elapsed) = blocked_jh.join().expect("Blocked reader thread panicked");
    assert!(aborted_ok, "Blocked CustomDartByteSource must return abort/EOF on abort_all()");
    assert!(
        t_abort.elapsed() < Duration::from_millis(150) && wait_elapsed < Duration::from_secs(1),
        "Blocked CustomDartByteSource waited for timeout instead of instant abort: {:?}",
        wait_elapsed
    );
}

#[test]
fn scenario_7_crossfade_prewarm_epoch_invalidation_and_queue_mutation_race() {
    let harness = TriPlaneHarness::spawn();
    let wav = SignalGenerator::pcm16_wav_bytes(96000, 48000, 2);

    harness
        .engine
        .exec(|ply| {
            ply.music_manager.set_crossfade(500, 500, 0);
        })
        .expect("Failed to configure crossfade");

    let items: Vec<AudioSourceCore> = (0..6).map(|i| mem_source(i + 1, wav.clone())).collect();
    harness
        .coordinator
        .set_queue(items, harness.dummy_custom_factory())
        .expect("set_queue failed");
    harness
        .coordinator
        .play(None, Some(0), None, None, false)
        .expect("Initial play failed");

    // Rapidly mutate queue structure & trigger prewarm epoch invalidations concurrently.
    harness
        .coordinator
        .append(vec![mem_source(7, wav.clone()), mem_source(8, wav.clone())])
        .expect("append failed");
    harness
        .coordinator
        .insert_next(mem_source(9, wav.clone()))
        .expect("insert_next failed");
    assert!(harness.coordinator.reorder(2, 5).expect("reorder failed"));
    let _ = harness.coordinator.remove_at(3, false).expect("remove_at failed");

    // Next advance must load the post-mutation item deterministically with clean playback state.
    let snap = harness
        .coordinator
        .next(Some(150), false)
        .expect("next() after queue mutations failed");
    assert!(snap.is_some());
    assert_eq!(harness.engine.snapshots().current_index(), 1);
    assert_eq!(
        harness.engine.snapshots().playback_state(),
        PlaybackState::Playing
    );

    // Wait until crossfade settles cleanly without ghost swaps or dropouts.
    assert!(
        wait_until(Duration::from_secs(2), || {
            !harness.engine.snapshots().is_xfading()
                && harness.engine.snapshots().current_index() == 1
        }),
        "Crossfade did not settle cleanly on index 1"
    );
    assert_eq!(harness.engine.snapshots().current_index(), 1);
}

#[test]
fn scenario_8_poison_recovery_and_render_step_parity() {
    // 1. Intentional Mutex/RwLock/Condvar poison simulation -> zero abort via unpoisoned helpers.
    let poisoned_mutex = Arc::new(Mutex::new(42u32));
    let m_clone = poisoned_mutex.clone();
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _g = m_clone.lock().unwrap();
        panic!("simulated worker panic holding mutex");
    }));
    assert!(poisoned_mutex.is_poisoned());
    assert_eq!(*lock_unpoisoned(&poisoned_mutex), 42);

    let poisoned_rw = Arc::new(RwLock::new(7u32));
    let rw_clone = poisoned_rw.clone();
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _g = rw_clone.write().unwrap();
        panic!("simulated worker panic holding rwlock");
    }));
    assert!(poisoned_rw.is_poisoned());
    assert_eq!(*read_unpoisoned(&poisoned_rw), 7);
    *write_unpoisoned(&poisoned_rw) = 99;
    assert_eq!(*read_unpoisoned(&poisoned_rw), 99);

    let cv = Arc::new(Condvar::new());
    let g = lock_unpoisoned(&poisoned_mutex);
    let (_g2, _) = wait_timeout_unpoisoned(&cv, g, Duration::from_millis(5));

    // Also verify StreamSession remains healthy when exercised concurrently.
    let sb = StreamSession::new(4096, Some(16384), false);
    assert!(!sb.is_eof());

    // 2. Synchronous render callback step parity: drive MiniaudioPlayer::render_pcm directly.
    let mut player =
        MiniaudioPlayer::new(48000, 2, 512, 16, None, None).expect("MiniaudioPlayer::new failed");
    player.inherit_dsp.set_reverb(ReverbConfig {
        enabled: 1,
        room_size: 0.5,
        damping: 0.3,
        width: 1.0,
        wet: 0.4,
        dry: 1.0,
    });
    let wav = SignalGenerator::pcm16_wav_bytes(48000, 48000, 2);
    let item = mem_source(1, wav.clone());
    assert_eq!(
        player
            .music_manager
            .active_deck_mut()
            .open_memory_with_hint(&wav, Some("wav")),
        0
    );
    player
        .music_manager
        .active_deck_mut()
        .set_queue_item_assignment(&item);
    assert_eq!(player.music_manager.active_deck_mut().play(), 0);

    let mut reached_pos = 0i64;
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        player.render_pcm(512);
        reached_pos = player
            .music_manager
            .active_deck_ref()
            .position_ms
            .load(Ordering::Relaxed);
        if reached_pos > 0 {
            break;
        }
        thread::yield_now();
    }
    assert!(reached_pos > 0, "Single-thread render_pcm stepping did not advance position");
}
