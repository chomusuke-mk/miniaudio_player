//! Configuration parameters for low-level audio device initialization.

/// Audio device initialization configuration.
#[derive(Debug, Clone)]
pub struct PlayerConfig {
    /// Audio sample rate in Hz (e.g. 44100 or 48000).
    pub sample_rate: u32,
    /// Channel count (e.g. 2 for stereo).
    pub channels: u32,
    /// Buffer period size in frames.
    pub period_size: u32,
}

impl Default for PlayerConfig {
    fn default() -> Self {
        Self {
            sample_rate: 44100,
            channels: 2,
            period_size: 1024,
        }
    }
}
