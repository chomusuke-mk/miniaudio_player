//! Core transport and queue transition state enums.

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
    /// Converts a raw integer transport code `v` into a [`PlaybackState`], defaulting unknown values to [`PlaybackState::Stopped`].
    #[inline]
    pub const fn from_i32(v: i32) -> Self {
        match v {
            1 => Self::Playing,
            2 => Self::Paused,
            _ => Self::Stopped,
        }
    }

    /// Converts this [`PlaybackState`] into its raw `i32` ABI representation.
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
    /// Converts a raw integer transition code `v` into a [`QueueTransition`], defaulting unknown values to [`QueueTransition::Idle`].
    #[inline]
    pub const fn from_i32(v: i32) -> Self {
        match v {
            1 => Self::AutoCrossfade,
            2 => Self::ManualCrossfade,
            _ => Self::Idle,
        }
    }

    /// Converts this [`QueueTransition`] into its raw `i32` ABI representation.
    #[inline]
    pub const fn as_i32(self) -> i32 {
        self as i32
    }

    /// Returns `true` when this transition represents an active auto or manual crossfade.
    #[inline]
    pub const fn is_crossfading(self) -> bool {
        matches!(self, Self::AutoCrossfade | Self::ManualCrossfade)
    }
}
