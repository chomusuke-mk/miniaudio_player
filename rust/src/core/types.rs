//! Strongly-typed Domain Newtypes and Error representations.
//!
//! Eliminates primitive obsession and guarantees invariant validation at compile-time and construction.

use std::num::NonZeroU32;

/// Validated audio sample rate (e.g. 8000 Hz to 384000 Hz).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SampleRate(NonZeroU32);

impl SampleRate {
    /// Creates a new `SampleRate` validating that it falls within supported hardware limits (8000..=384000).
    pub fn new(rate: u32) -> Result<Self, PlayerError> {
        if !(8000..=384000).contains(&rate) {
            return Err(PlayerError::InvalidArgs);
        }
        NonZeroU32::new(rate)
            .map(Self)
            .ok_or(PlayerError::InvalidArgs)
    }

    /// Convenience unchecked constructor for valid static constants.
    pub const fn from_hz(rate: u32) -> Option<Self> {
        if rate >= 8000 && rate <= 384000 {
            if let Some(nz) = NonZeroU32::new(rate) {
                return Some(Self(nz));
            }
        }
        None
    }

    pub fn get(self) -> u32 {
        self.0.get()
    }
}

impl Default for SampleRate {
    fn default() -> Self {
        Self(NonZeroU32::new(44100).unwrap())
    }
}

/// Validated audio volume multiplier constrained to `[0.0, 2.0]`.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Volume(f32);

impl Volume {
    pub const SILENCE: Self = Self(0.0);
    pub const UNITY: Self = Self(1.0);
    pub const MAX: Self = Self(2.0);

    pub fn new(vol: f32) -> Result<Self, PlayerError> {
        if !vol.is_finite() || vol < 0.0 || vol > 2.0 {
            return Err(PlayerError::InvalidArgs);
        }
        Ok(Self(vol))
    }

    pub fn clamp(vol: f32) -> Self {
        if !vol.is_finite() || vol < 0.0 {
            Self::SILENCE
        } else if vol > 2.0 {
            Self::MAX
        } else {
            Self(vol)
        }
    }

    pub fn get(self) -> f32 {
        self.0
    }

    pub fn to_decibels(self) -> Decibels {
        Decibels::from_linear(self)
    }
}

impl Default for Volume {
    fn default() -> Self {
        Self::UNITY
    }
}

/// Audio level in decibels (dB).
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Decibels(f32);

impl Decibels {
    pub const ZERO_DB: Self = Self(0.0);

    pub fn new(db: f32) -> Result<Self, PlayerError> {
        if !db.is_finite() {
            return Err(PlayerError::InvalidArgs);
        }
        Ok(Self(db))
    }

    pub fn from_linear(vol: Volume) -> Self {
        if vol.get() <= 0.000001 {
            Self(-120.0) // Audio floor
        } else {
            Self(20.0 * vol.get().log10())
        }
    }

    pub fn to_linear(self) -> Volume {
        let linear = 10.0f32.powf(self.0 / 20.0);
        Volume::clamp(linear)
    }

    pub fn get(self) -> f32 {
        self.0
    }
}

impl Default for Decibels {
    fn default() -> Self {
        Self::ZERO_DB
    }
}

/// Strongly-typed player error conditions replacing integer codes `-1..-12`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlayerError {
    Failed,
    InvalidArgs,
    InvalidOperation,
    OutOfMemory,
    FileNotFound,
    DecodeFailed,
    DeviceInitFailed,
    DeviceStartFailed,
    Timeout,
    FormatNotSupported,
    StreamError(String),
}

impl std::fmt::Display for PlayerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlayerError::Failed => write!(f, "General player failure"),
            PlayerError::InvalidArgs => write!(f, "Invalid arguments"),
            PlayerError::InvalidOperation => write!(f, "Invalid operation in current state"),
            PlayerError::OutOfMemory => write!(f, "Out of memory"),
            PlayerError::FileNotFound => write!(f, "File not found"),
            PlayerError::DecodeFailed => write!(f, "Audio decoding failed"),
            PlayerError::DeviceInitFailed => write!(f, "Audio device initialization failed"),
            PlayerError::DeviceStartFailed => write!(f, "Audio device start failed"),
            PlayerError::Timeout => write!(f, "Operation timed out"),
            PlayerError::FormatNotSupported => write!(f, "Audio format not supported"),
            PlayerError::StreamError(msg) => write!(f, "Stream error: {}", msg),
        }
    }
}

impl std::error::Error for PlayerError {}
