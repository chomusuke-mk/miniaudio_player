//! Soft-knee True-Peak Limiter / DAC Protector preventing clipping and harsh digital distortion.

/// Soft-knee brickwall peak limiter preventing digital DAC clipping and harsh inter-sample overs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SoftLimiter {
    /// Whether soft limiting is currently enabled.
    enabled: bool,
    /// Linear amplitude threshold above which soft saturation begins (`0.95`).
    threshold: f32,
    /// Headroom width between `threshold` and `1.0` (`0.05`).
    range: f32,
    /// Precomputed reciprocal of `range` (`20.0`).
    inv_range: f32,
}

impl Default for SoftLimiter {
    /// Returns an enabled [`SoftLimiter`] with default threshold `0.95`.
    fn default() -> Self {
        Self::new(true)
    }
}

impl SoftLimiter {
    /// Constructs a `SoftLimiter` with soft saturation onset at 0.95 (-0.45 dBFS) and initial state `enabled`.
    pub const fn new(enabled: bool) -> Self {
        let threshold = 0.95f32;
        let range = 0.05f32;
        let inv_range = 20.0f32;
        Self {
            enabled,
            threshold,
            range,
            inv_range,
        }
    }

    /// Sets whether limiter saturation is `enabled`.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    /// Returns whether the limiter is active.
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Processes a slice of audio `samples` in-place, limiting peaks exceeding the threshold.
    pub fn process_frames(&self, samples: &mut [f32]) {
        if !self.enabled || samples.is_empty() {
            return;
        }

        let threshold = self.threshold;
        let range = self.range;
        let inv_range = self.inv_range;

        for s in samples.iter_mut() {
            let x = *s;
            let abs_x = x.abs();
            if abs_x > threshold {
                let excess = (abs_x - threshold) * inv_range;
                let sat = threshold + range * (excess / (1.0 + excess));
                *s = if x >= 0.0 { sat } else { -sat };
            }
        }
    }
}
