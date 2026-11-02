//! Deterministic Direct Form II Transposed (DF2T) Biquad Filter & RBJ Audio EQ Cookbook Designer.

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
    const DENORMAL_THRESHOLD: f32 = 1e-20;

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
        Self::new(1.0, 0.0, 0.0, 0.0, 0.0)
    }

    #[inline]
    pub fn reset_state(&mut self) {
        self.s1 = 0.0;
        self.s2 = 0.0;
    }

    /// Updates filter coefficients while preserving internal state registers `s1` and `s2`.
    #[inline]
    pub fn update_coefficients_from(&mut self, prototype: &Self) {
        self.b0 = prototype.b0;
        self.b1 = prototype.b1;
        self.b2 = prototype.b2;
        self.a1 = prototype.a1;
        self.a2 = prototype.a2;
    }

    #[inline(always)]
    pub fn process(&mut self, x: f32) -> f32 {
        let mut y = self.b0 * x + self.s1;
        self.s1 = self.b1 * x - self.a1 * y + self.s2;
        self.s2 = self.b2 * x - self.a2 * y;

        if self.s1.abs() < Self::DENORMAL_THRESHOLD {
            self.s1 = 0.0;
        }
        if self.s2.abs() < Self::DENORMAL_THRESHOLD {
            self.s2 = 0.0;
        }
        if y.abs() < Self::DENORMAL_THRESHOLD {
            y = 0.0;
        }

        y
    }

    #[inline]
    fn from_normalized_f64(b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64) -> Self {
        if a0.abs() < 1e-15 {
            return Self::identity();
        }
        Self::new(
            (b0 / a0) as f32,
            (b1 / a0) as f32,
            (b2 / a0) as f32,
            (a1 / a0) as f32,
            (a2 / a0) as f32,
        )
    }

    #[inline]
    fn is_valid_frequency(f0: f64, fs: f64, param: f64) -> bool {
        fs > 0.0 && f0 > 0.0 && f0 < fs * 0.5 && param > 0.0
    }

    pub fn low_shelf(f0: f64, fs: f64, gain_db: f64, shelf_slope: f64) -> Self {
        if !Self::is_valid_frequency(f0, fs, shelf_slope) || gain_db.abs() < 1e-6 {
            return Self::identity();
        }

        let w = 2.0 * PI * f0 / fs;
        let s = w.sin();
        let c = w.cos();
        let a_val = 10.0f64.powf(gain_db / 40.0);
        let a = s / 2.0
            * ((a_val + 1.0 / a_val) * (1.0 / shelf_slope - 1.0) + 2.0)
                .max(0.0)
                .sqrt();
        let sqrt_a = 2.0 * a_val.sqrt() * a;

        let b0 = a_val * ((a_val + 1.0) - (a_val - 1.0) * c + sqrt_a);
        let b1 = 2.0 * a_val * ((a_val - 1.0) - (a_val + 1.0) * c);
        let b2 = a_val * ((a_val + 1.0) - (a_val - 1.0) * c - sqrt_a);
        let a0 = (a_val + 1.0) + (a_val - 1.0) * c + sqrt_a;
        let a1 = -2.0 * ((a_val - 1.0) + (a_val + 1.0) * c);
        let a2 = (a_val + 1.0) + (a_val - 1.0) * c - sqrt_a;

        Self::from_normalized_f64(b0, b1, b2, a0, a1, a2)
    }

    pub fn peaking(f0: f64, fs: f64, gain_db: f64, q: f64) -> Self {
        if !Self::is_valid_frequency(f0, fs, q) || gain_db.abs() < 1e-6 {
            return Self::identity();
        }

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

        Self::from_normalized_f64(b0, b1, b2, a0, a1, a2)
    }

    pub fn high_shelf(f0: f64, fs: f64, gain_db: f64, shelf_slope: f64) -> Self {
        if !Self::is_valid_frequency(f0, fs, shelf_slope) || gain_db.abs() < 1e-6 {
            return Self::identity();
        }

        let w = 2.0 * PI * f0 / fs;
        let s = w.sin();
        let c = w.cos();
        let a_val = 10.0f64.powf(gain_db / 40.0);
        let a = s / 2.0
            * ((a_val + 1.0 / a_val) * (1.0 / shelf_slope - 1.0) + 2.0)
                .max(0.0)
                .sqrt();
        let sqrt_a = 2.0 * a_val.sqrt() * a;

        let b0 = a_val * ((a_val + 1.0) + (a_val - 1.0) * c + sqrt_a);
        let b1 = -2.0 * a_val * ((a_val - 1.0) + (a_val + 1.0) * c);
        let b2 = a_val * ((a_val + 1.0) + (a_val - 1.0) * c - sqrt_a);
        let a0 = (a_val + 1.0) - (a_val - 1.0) * c + sqrt_a;
        let a1 = 2.0 * ((a_val - 1.0) - (a_val + 1.0) * c);
        let a2 = (a_val + 1.0) - (a_val - 1.0) * c - sqrt_a;

        Self::from_normalized_f64(b0, b1, b2, a0, a1, a2)
    }

    pub fn bandpass(f0: f64, fs: f64, q: f64) -> Self {
        if !Self::is_valid_frequency(f0, fs, q) {
            return Self::identity();
        }

        let w0 = 2.0 * PI * f0 / fs;
        let alpha = w0.sin() / (2.0 * q);
        let cos_w = w0.cos();

        let b0 = alpha;
        let b1 = 0.0;
        let b2 = -alpha;
        let a0 = 1.0 + alpha;
        let a1 = -2.0 * cos_w;
        let a2 = 1.0 - alpha;

        Self::from_normalized_f64(b0, b1, b2, a0, a1, a2)
    }
}
