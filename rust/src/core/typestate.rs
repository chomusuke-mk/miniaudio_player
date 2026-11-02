//! Typestate Lifecycle Architecture for miniaudio_player.
//!
//! Replaces runtime state integer checks with compile-time state guarantees.
//! State transitions:
//! Uninitialized -> Open<S> -> Active<S> <-> Paused<S>
//!                         \-> Stopped<S> -> Uninitialized

use super::config::PlayerConfig;
use super::types::{PlayerError, Volume};
use crate::buffer::ByteSource;

/// Initial uninitialized state: no media source is loaded.
pub struct Uninitialized;

/// Open state: a valid byte source is attached and probed, but playback has not started.
pub struct Open<S: ByteSource> {
    pub source: S,
    pub total_bytes: Option<u64>,
    pub is_seekable: bool,
}

/// Active state: audio pipeline is actively decoding and rendering PCM frames.
pub struct Active<S: ByteSource> {
    pub source: S,
    pub current_position_ms: u64,
    pub volume: Volume,
}

/// Paused state: playback is temporarily paused; position is retained.
pub struct Paused<S: ByteSource> {
    pub source: S,
    pub paused_position_ms: u64,
    pub volume: Volume,
}

/// Stopped state: playback was stopped; playback head reset.
pub struct Stopped<S: ByteSource> {
    pub source: S,
    pub volume: Volume,
}

/// A type-safe audio player whose available methods are strictly governed by its compile-time `State`.
pub struct Player<State> {
    state: State,
    config: PlayerConfig,
}

impl Player<Uninitialized> {
    /// Creates a new uninitialized player instance with the given configuration.
    pub fn new(config: PlayerConfig) -> Self {
        Self {
            state: Uninitialized,
            config,
        }
    }

    /// Attaches and opens a byte source, transitioning the player to the `Open` state.
    pub fn open<S: ByteSource>(self, source: S) -> Result<Player<Open<S>>, PlayerError> {
        let is_seekable = source.is_seekable();
        let total_bytes = source.total_bytes();

        Ok(Player {
            state: Open {
                source,
                total_bytes,
                is_seekable,
            },
            config: self.config,
        })
    }

    pub fn config(&self) -> &PlayerConfig {
        &self.config
    }
}

impl<S: ByteSource> Player<Open<S>> {
    /// Begins playback, transitioning from `Open` to `Active`.
    pub fn play(self) -> Result<Player<Active<S>>, PlayerError> {
        Ok(Player {
            state: Active {
                source: self.state.source,
                current_position_ms: 0,
                volume: Volume::UNITY,
            },
            config: self.config,
        })
    }

    /// Closes the media source, returning the player to `Uninitialized`.
    pub fn close(self) -> Player<Uninitialized> {
        Player {
            state: Uninitialized,
            config: self.config,
        }
    }

    pub fn is_seekable(&self) -> bool {
        self.state.is_seekable
    }

    pub fn total_bytes(&self) -> Option<u64> {
        self.state.total_bytes
    }
}

impl<S: ByteSource> Player<Active<S>> {
    /// Pauses playback, transitioning from `Active` to `Paused`.
    pub fn pause(self) -> Player<Paused<S>> {
        Player {
            state: Paused {
                source: self.state.source,
                paused_position_ms: self.state.current_position_ms,
                volume: self.state.volume,
            },
            config: self.config,
        }
    }

    /// Stops playback, transitioning from `Active` to `Stopped`.
    pub fn stop(self) -> Player<Stopped<S>> {
        Player {
            state: Stopped {
                source: self.state.source,
                volume: self.state.volume,
            },
            config: self.config,
        }
    }

    pub fn set_volume(&mut self, vol: Volume) {
        self.state.volume = vol;
    }

    pub fn volume(&self) -> Volume {
        self.state.volume
    }

    pub fn position_ms(&self) -> u64 {
        self.state.current_position_ms
    }
}

impl<S: ByteSource> Player<Paused<S>> {
    /// Resumes playback from the paused position, transitioning to `Active`.
    pub fn resume(self) -> Player<Active<S>> {
        Player {
            state: Active {
                source: self.state.source,
                current_position_ms: self.state.paused_position_ms,
                volume: self.state.volume,
            },
            config: self.config,
        }
    }

    /// Stops playback, transitioning from `Paused` to `Stopped`.
    pub fn stop(self) -> Player<Stopped<S>> {
        Player {
            state: Stopped {
                source: self.state.source,
                volume: self.state.volume,
            },
            config: self.config,
        }
    }

    pub fn paused_position_ms(&self) -> u64 {
        self.state.paused_position_ms
    }
}

impl<S: ByteSource> Player<Stopped<S>> {
    /// Restarts playback from the beginning, transitioning from `Stopped` to `Active`.
    pub fn play(self) -> Result<Player<Active<S>>, PlayerError> {
        Ok(Player {
            state: Active {
                source: self.state.source,
                current_position_ms: 0,
                volume: self.state.volume,
            },
            config: self.config,
        })
    }

    /// Closes the media source, transitioning back to `Uninitialized`.
    pub fn close(self) -> Player<Uninitialized> {
        Player {
            state: Uninitialized,
            config: self.config,
        }
    }
}
