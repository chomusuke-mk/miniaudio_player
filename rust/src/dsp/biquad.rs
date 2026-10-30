//! Direct Form II Transposed (DF2T) Biquad filter with anti-denormal protection and RBJ coefficient calculations.

use std::f64::consts::PI;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BiquadDf2t {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
    pub s1: f32,
    pub s2: f32,
}

impl Default for BiquadDf2t {
    fn default() -> Self {
        Self::identity()
    }
}

impl BiquadDf2t {
    pub const fn new(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Self {
        Self {
            b0,
            b1,
            b2,
            a1,
            a2,
            s1: 0.0,
            s2: 0.0,
        }
    }

    pub const fn identity() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            s1: 0.0,
            s2: 0.0,
        }
    }

    pub fn reset_state(&mut self) {
        self.s1 = 0.0;
        self.s2 = 0.0;
    }

    #[inline(always)]
    pub fn process(&mut self, x: f32) -> f32 {
        let mut y = self.b0 * x + self.s1;
        self.s1 = self.b1 * x - self.a1 * y + self.s2;
        self.s2 = self.b2 * x - self.a2 * y;

        // Anti-denormal flush
        if self.s1.abs() < 1e-20 {
            self.s1 = 0.0;
        }
        if self.s2.abs() < 1e-20 {
            self.s2 = 0.0;
        }
        if y.abs() < 1e-20 {
            y = 0.0;
        }

        y
    }

    pub fn low_shelf(f0: f64, fs: f64, gain_db: f64, shelf_slope: f64) -> Self {
        let fs = if fs <= 0.0 { 44100.0 } else { fs };
        let f0 = f0.clamp(10.0, fs * 0.49);
        let s_slope = if shelf_slope <= 0.0 { 0.7071067811865475 } else { shelf_slope };

        let w = 2.0 * PI * f0 / fs;
        let s = w.sin();
        let c = w.cos();
        let a_val = 10.0f64.powf(gain_db / 40.0);
        let a = s / 2.0 * ((a_val + 1.0 / a_val) * (1.0 / s_slope - 1.0) + 2.0).max(0.0).sqrt();
        let sqrt_a = 2.0 * a_val.sqrt() * a;

        let b0 = a_val * ((a_val + 1.0) - (a_val - 1.0) * c + sqrt_a);
        let b1 = 2.0 * a_val * ((a_val - 1.0) - (a_val + 1.0) * c);
        let b2 = a_val * ((a_val + 1.0) - (a_val - 1.0) * c - sqrt_a);
        let a0 = (a_val + 1.0) + (a_val - 1.0) * c + sqrt_a;
        let a1 = -2.0 * ((a_val - 1.0) + (a_val + 1.0) * c);
        let a2 = (a_val + 1.0) + (a_val - 1.0) * c - sqrt_a;

        Self::new(
            (b0 / a0) as f32,
            (b1 / a0) as f32,
            (b2 / a0) as f32,
            (a1 / a0) as f32,
            (a2 / a0) as f32,
        )
    }

    pub fn peaking(f0: f64, fs: f64, gain_db: f64, q: f64) -> Self {
        let fs = if fs <= 0.0 { 44100.0 } else { fs };
        let f0 = f0.clamp(10.0, fs * 0.49);
        let q = if q <= 0.0 { 1.15 } else { q };

        let w = 2.0 * PI * f0 / fs;
        let s = w.sin();
        let c = w.cos();
        let a = s / (2.0 * q);
        let a_val = 10.0f64.powf(gain_db / 40.0);

        let b0 = 1.0 + (a * a_val);
        let b1 = -2.0 * c;
        let b2 = 1.0 - (a * a_val);
        let a0 = 1.0 + (a / a_val);
        let a1 = -2.0 * c;
        let a2 = 1.0 - (a / a_val);

        Self::new(
            (b0 / a0) as f32,
            (b1 / a0) as f32,
            (b2 / a0) as f32,
            (a1 / a0) as f32,
            (a2 / a0) as f32,
        )
    }

    pub fn high_shelf(f0: f64, fs: f64, gain_db: f64, shelf_slope: f64) -> Self {
        let fs = if fs <= 0.0 { 44100.0 } else { fs };
        let f0 = f0.clamp(10.0, fs * 0.49);
        let s_slope = if shelf_slope <= 0.0 { 0.7071067811865475 } else { shelf_slope };

        let w = 2.0 * PI * f0 / fs;
        let s = w.sin();
        let c = w.cos();
        let a_val = 10.0f64.powf(gain_db / 40.0);
        let a = s / 2.0 * ((a_val + 1.0 / a_val) * (1.0 / s_slope - 1.0) + 2.0).max(0.0).sqrt();
        let sqrt_a = 2.0 * a_val.sqrt() * a;

        let b0 = a_val * ((a_val + 1.0) + (a_val - 1.0) * c + sqrt_a);
        let b1 = -2.0 * a_val * ((a_val - 1.0) + (a_val + 1.0) * c);
        let b2 = a_val * ((a_val + 1.0) + (a_val - 1.0) * c - sqrt_a);
        let a0 = (a_val + 1.0) - (a_val - 1.0) * c + sqrt_a;
        let a1 = 2.0 * ((a_val - 1.0) - (a_val + 1.0) * c);
        let a2 = (a_val + 1.0) - (a_val - 1.0) * c - sqrt_a;

        Self::new(
            (b0 / a0) as f32,
            (b1 / a0) as f32,
            (b2 / a0) as f32,
            (a1 / a0) as f32,
            (a2 / a0) as f32,
        )
    }

    pub fn bandpass(f0: f64, fs: f64, q: f64) -> Self {
        let fs = if fs <= 0.0 { 44100.0 } else { fs };
        let f0 = f0.clamp(10.0, fs * 0.49);
        let q = if q <= 0.0 { 1.2 } else { q };

        let w0 = 2.0 * PI * f0 / fs;
        let alpha = w0.sin() / (2.0 * q);
        let cos_w = w0.cos();

        let b0 = alpha;
        let b1 = 0.0;
        let b2 = -alpha;
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cos_w;
        let a2 = 1.0 - alpha;

        Self::new(
            (b0 / a0) as f32,
            (b1 / a0) as f32,
            (b2 / a0) as f32,
            (a1 / a0) as f32,
            (a2 / a0) as f32,
        )
    }
}
