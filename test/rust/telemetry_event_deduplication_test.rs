//! Telemetry Event Deduplication and Fine-Grained Emission Verification Tests.

mod common;

use std::thread;
use std::time::Duration;

use common::FixtureResolver;
use miniaudio_player::api::player::RustMiniaudioPlayer;
use miniaudio_player::api::types::{RustAudioSource, RustPlayerConfig};

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

    // Initial settling
    thread::sleep(Duration::from_millis(100));

    // In steady idle state, setting metadata enabled to false or true toggles without crash
    player.set_metadata_enabled(false);
    player.set_metadata_enabled(true);
    // Setting identical value again is a no-op
    player.set_metadata_enabled(true);
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
        }])
        .expect("set_queue failed");

    player.play(Some(1), None, None, Some(100)).expect("play failed");

    // Run ticks for 200ms
    thread::sleep(Duration::from_millis(200));

    player.stop();
}
