use miniaudio_player::buffer::MemoryByteSource;
use miniaudio_player::core::config::PlayerConfig;
use miniaudio_player::core::types::{Decibels, PlayerError, SampleRate, Volume};
use miniaudio_player::core::typestate::Player;

#[test]
fn test_sample_rate_domain_invariants() {
    assert!(SampleRate::new(44100).is_ok());
    assert!(SampleRate::new(48000).is_ok());
    assert!(SampleRate::new(192000).is_ok());

    // Below hardware floor
    assert_eq!(SampleRate::new(0), Err(PlayerError::InvalidArgs));
    assert_eq!(SampleRate::new(4000), Err(PlayerError::InvalidArgs));

    // Above hardware ceiling
    assert_eq!(SampleRate::new(500000), Err(PlayerError::InvalidArgs));

    let sr = SampleRate::new(44100).unwrap();
    assert_eq!(sr.get(), 44100);
}

#[test]
fn test_volume_domain_invariants() {
    assert!(Volume::new(1.0).is_ok());
    assert!(Volume::new(0.0).is_ok());
    assert!(Volume::new(2.0).is_ok());

    assert_eq!(Volume::new(-0.1), Err(PlayerError::InvalidArgs));
    assert_eq!(Volume::new(2.5), Err(PlayerError::InvalidArgs));
    assert_eq!(Volume::new(f32::NAN), Err(PlayerError::InvalidArgs));

    // Clamp behavior
    assert_eq!(Volume::clamp(-1.0).get(), 0.0);
    assert_eq!(Volume::clamp(3.5).get(), 2.0);
    assert_eq!(Volume::clamp(0.75).get(), 0.75);
}

#[test]
fn test_decibels_linear_conversions() {
    let unity = Volume::new(1.0).unwrap();
    let zero_db = Decibels::from_linear(unity);
    assert!((zero_db.get() - 0.0).abs() < 0.001);

    let half = Volume::new(0.5).unwrap();
    let minus_six_db = Decibels::from_linear(half);
    assert!((minus_six_db.get() - (-6.02)).abs() < 0.05);

    let reconstructed = zero_db.to_linear();
    assert!((reconstructed.get() - 1.0).abs() < 0.001);
}

#[test]
fn test_typestate_lifecycle_transitions() {
    let config = PlayerConfig {
        sample_rate: 44100,
        channels: 2,
        period_size: 1024,
    };

    // 1. Initial State: Uninitialized
    let player = Player::new(config);
    assert_eq!(player.config().sample_rate, 44100);

    // 2. Open State: MemoryByteSource loaded
    let source = MemoryByteSource::new(vec![0u8; 1024]);
    let open_player = player.open(source).expect("Failed to open source");
    assert!(open_player.is_seekable());
    assert_eq!(open_player.total_bytes(), Some(1024));

    // 3. Active State: Playback started
    let mut active_player = open_player.play().expect("Failed to start playback");
    assert_eq!(active_player.position_ms(), 0);
    active_player.set_volume(Volume::new(1.5).unwrap());
    assert_eq!(active_player.volume().get(), 1.5);

    // 4. Paused State: Pausing retains position & volume
    let paused_player = active_player.pause();
    assert_eq!(paused_player.paused_position_ms(), 0);

    // 5. Active State: Resuming playback
    let active_player2 = paused_player.resume();
    assert_eq!(active_player2.volume().get(), 1.5);

    // 6. Stopped State: Stopping resets head
    let stopped_player = active_player2.stop();

    // 7. Re-playing from stopped state
    let active_player3 = stopped_player.play().expect("Failed to restart");
    let stopped_player2 = active_player3.stop();

    // 8. Returning to Uninitialized state
    let closed_player = stopped_player2.close();
    assert_eq!(closed_player.config().channels, 2);
}
