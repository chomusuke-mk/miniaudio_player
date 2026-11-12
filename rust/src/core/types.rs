//! Strongly-typed Domain Newtypes and Error representations.
//!
//! Eliminates primitive obsession and guarantees invariant validation at compile-time and construction.

use std::num::NonZeroU32;

/// Real transport state of a player or deck.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PlaybackState {
    /// Playback has ended or been stopped; zero network or buffer requests.
    #[default]
    Stopped = 0,
    /// Authorized to render audio; active network and buffer requests.
    Playing = 1,
    /// Not authorized to render audio; network and buffer requests continue until full.
    Paused = 2,
}

impl PlaybackState {
    #[inline]
    pub const fn from_i32(v: i32) -> Self {
        match v {
            1 => Self::Playing,
            2 => Self::Paused,
            _ => Self::Stopped,
        }
    }

    #[inline]
    pub const fn as_i32(self) -> i32 {
        self as i32
    }
}

/// Internal track transition state managed exclusively by the Queue Coordinator (DualSource).
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum QueueTransition {
    /// No active track transition; rendering current deck normally.
    #[default]
    Idle = 0,
    /// Automatic overlap transition when approaching track end.
    AutoCrossfade = 1,
    /// User-initiated track transition (skip next / previous).
    ManualCrossfade = 2,
}

impl QueueTransition {
    #[inline]
    pub const fn from_i32(v: i32) -> Self {
        match v {
            1 => Self::AutoCrossfade,
            2 => Self::ManualCrossfade,
            _ => Self::Idle,
        }
    }

    #[inline]
    pub const fn as_i32(self) -> i32 {
        self as i32
    }

    #[inline]
    pub const fn is_crossfading(self) -> bool {
        matches!(self, Self::AutoCrossfade | Self::ManualCrossfade)
    }
}

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

    /// Returns the sample rate frequency in Hertz as a raw `u32`.
    pub fn get(self) -> u32 {
        self.0.get()
    }
}

impl Default for SampleRate {
    fn default() -> Self {
        Self(NonZeroU32::new(44100).unwrap())
    }
}

/// Validated audio volume multiplier constrained to `>= 0.0`.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Volume(f32);

impl Volume {
    /// Silence level (0.0 linear).
    pub const SILENCE: Self = Self(0.0);
    /// Unity gain level (1.0 linear).
    pub const UNITY: Self = Self(1.0);

    /// Creates a validated `Volume`, returning an error if negative or non-finite.
    pub fn new(vol: f32) -> Result<Self, PlayerError> {
        if !vol.is_finite() || vol < 0.0 {
            return Err(PlayerError::InvalidArgs);
        }
        Ok(Self(vol))
    }

    /// Clamps volume to `0.0` if non-finite or negative.
    pub fn clamp(vol: f32) -> Self {
        if !vol.is_finite() || vol < 0.0 {
            Self::SILENCE
        } else {
            Self(vol)
        }
    }

    /// Returns the raw linear volume scalar.
    pub fn get(self) -> f32 {
        self.0
    }

    /// Converts this linear volume multiplier into decibels (dB).
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
    /// Zero decibels reference point (unity gain).
    pub const ZERO_DB: Self = Self(0.0);

    /// Creates a validated `Decibels` instance, returning an error if non-finite.
    pub fn new(db: f32) -> Result<Self, PlayerError> {
        if !db.is_finite() {
            return Err(PlayerError::InvalidArgs);
        }
        Ok(Self(db))
    }

    /// Converts a linear `Volume` to decibels (clamped at -120 dB noise floor).
    pub fn from_linear(vol: Volume) -> Self {
        if vol.get() <= 0.000001 {
            Self(-120.0) // Audio floor
        } else {
            Self(20.0 * vol.get().log10())
        }
    }

    /// Converts this decibel level to a linear `Volume` multiplier.
    pub fn to_linear(self) -> Volume {
        let linear = 10.0f32.powf(self.0 / 20.0);
        Volume::clamp(linear)
    }

    /// Returns the raw decibel value as `f32`.
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
    /// General unspecified player failure.
    Failed,
    /// Invalid arguments supplied to the operation.
    InvalidArgs,
    /// Operation attempted in an invalid state.
    InvalidOperation,
    /// Memory allocation budget exceeded.
    OutOfMemory,
    /// Target file was not found.
    FileNotFound,
    /// Audio decoding or demuxing failed.
    DecodeFailed,
    /// Audio hardware device initialization failed.
    DeviceInitFailed,
    /// Audio hardware device could not be started.
    DeviceStartFailed,
    /// Asynchronous operation timed out.
    Timeout,
    /// Audio format or container not supported.
    FormatNotSupported,
    /// Streaming error with detailed message.
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
