//! Soft-knee True-Peak Limiter / DAC Protector preventing clipping and harsh digital distortion.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SoftLimiter {
    enabled: bool,
    threshold: f32,
    range: f32,
    inv_range: f32,
}

impl Default for SoftLimiter {
    fn default() -> Self {
        Self::new(true)
    }
}

impl SoftLimiter {
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

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    #[inline(always)]
    pub fn process_sample(&self, x: f32) -> f32 {
        if !self.enabled {
            return x;
        }

        let abs_x = x.abs();
        if abs_x > self.threshold {
            let excess = (abs_x - self.threshold) * self.inv_range;
            let sat = self.threshold + self.range * (excess / (1.0 + excess));
            if x >= 0.0 { sat } else { -sat }
        } else {
            x
        }
    }

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
