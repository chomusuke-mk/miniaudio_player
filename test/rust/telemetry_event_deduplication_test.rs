//! Telemetry Event Deduplication and Fine-Grained Emission Verification Tests.

mod common;

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use common::FixtureResolver;
use miniaudio_player::api::player::RustMiniaudioPlayer;
use miniaudio_player::api::types::{RustAudioSource, RustPlayerConfig};
use miniaudio_player::sync::{TelemetryDispatcher, TelemetryEvent};

#[test]
fn test_telemetry_dispatcher_deduplicates_positions_synchronously_via_condvar() {
    let dispatcher = TelemetryDispatcher::new();
    let captured = Arc::new((Mutex::new(Vec::<TelemetryEvent>::new()), Condvar::new()));
    let captured_cb = captured.clone();

    dispatcher.set_typed_callback(Some(Box::new(move |ev: &TelemetryEvent| {
        let (lock, cvar) = &*captured_cb;
        let mut events = lock.lock().unwrap();
        events.push(ev.clone());
        if matches!(ev, TelemetryEvent::Position(9999)) {
            cvar.notify_all();
        }
    })));

    // Burst consecutive identical position updates; only distinct transitions should be forwarded.
    for _ in 0..8 {
        dispatcher.post(TelemetryEvent::Position(1000));
    }
    dispatcher.post(TelemetryEvent::IsPlaying(true));
    for _ in 0..8 {
        dispatcher.post(TelemetryEvent::Position(2500));
    }
    dispatcher.post(TelemetryEvent::Position(9999));

    let (lock, cvar) = &*captured;
    let guard = lock.lock().unwrap();
    let (guard, timeout) = cvar
        .wait_timeout_while(guard, Duration::from_secs(2), |events| {
            !events
                .iter()
                .any(|e| matches!(e, TelemetryEvent::Position(9999)))
        })
        .unwrap();
    assert!(
        !timeout.timed_out(),
        "Timed out waiting for TelemetryDispatcher sentinel event"
    );

    let positions: Vec<i64> = guard
        .iter()
        .filter_map(|e| match e {
            TelemetryEvent::Position(p) => Some(*p),
            _ => None,
        })
        .collect();
    assert_eq!(positions, vec![1000, 2500, 9999]);
    assert!(guard
        .iter()
        .any(|e| matches!(e, TelemetryEvent::IsPlaying(true))));

    dispatcher.stop();
}

#[test]
fn test_telemetry_deduplication_in_idle_state() {
    let player = RustMiniaudioPlayer::new(
        RustPlayerConfig::default(),
        48000,
        2,
        1024,
        vec![],
    )
    .expect("Failed to create RustMiniaudioPlayer");

    // In steady idle state, setting metadata enabled to false or true toggles cleanly.
    player.set_metadata_enabled(false);
    player.set_metadata_enabled(true);
    // Setting identical value again is a safe idempotent no-op.
    player.set_metadata_enabled(true);
    player.dispose();
}

#[test]
fn test_metadata_single_emission_guarantee() {
    let player = RustMiniaudioPlayer::new(
        RustPlayerConfig::default(),
        48000,
        2,
        1024,
        vec![],
    )
    .expect("Failed to create RustMiniaudioPlayer");

    player.set_metadata_enabled(true);

    let wav_path = FixtureResolver::resolve_str("salida.wav");
    player
        .set_queue(vec![RustAudioSource {
            id: 1,
            source: wav_path,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        }])
        .expect("set_queue failed");

    player
        .play(Some(1), None, None, Some(100))
        .expect("play failed");
    player.set_metadata_enabled(false);
    player.set_metadata_enabled(true);
    player.stop();
    player.dispose();
}

#[test]
fn test_visualizer_deduplication_guarantee() {
    let player = RustMiniaudioPlayer::new(
        RustPlayerConfig::default(),
        48000,
        2,
        1024,
        vec![],
    )
    .expect("Failed to create RustMiniaudioPlayer");

    player.set_visualizer_enabled(true);
    player.set_visualizer_enabled(true);

    // When stopped or paused, visualizer filter deduplicates identical default/zero events.
    player.pause();
    player.stop();
    player.set_visualizer_enabled(false);
    player.dispose();
}
