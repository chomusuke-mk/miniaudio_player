//! Bauer Stereophonic-to-Binaural (BS2B) Crossfeed Filter for headphone listening.

use std::f64::consts::PI;

pub const BS2B_DEFAULT_CLEVEL: u32 = 700 | (45 << 16); // Moffat-Bauer: 700 Hz, 4.5 dB
pub const BS2B_CMOY_CLEVEL: u32 = 700 | (60 << 16);    // Chu Moy: 700 Hz, 6.0 dB

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrossfeedMode {
    Off = 0,
    MoffatBauer = 1,
    ChuMoy = 2,
}

impl Default for CrossfeedMode {
    fn default() -> Self {
        CrossfeedMode::Off
    }
}

#[derive(Debug, Clone)]
pub struct Bs2bCrossfeed {
    mode: CrossfeedMode,
    sample_rate: u32,
    a0_lo: f32,
    b1_lo: f32,
    a0_hi: f32,
    a1_hi: f32,
    b1_hi: f32,
    gain: f32,

    // Filter states for L and R: [0] = left, [1] = right
    asis: [f32; 2],
    lo: [f32; 2],
    hi: [f32; 2],
}

impl Bs2bCrossfeed {
    pub fn new(sample_rate: u32, mode: CrossfeedMode) -> Self {
        let mut cf = Self {
            mode,
            sample_rate: sample_rate.clamp(2000, 384000),
            a0_lo: 0.0,
            b1_lo: 0.0,
            a0_hi: 0.0,
            a1_hi: 0.0,
            b1_hi: 0.0,
            gain: 1.0,
            asis: [0.0; 2],
            lo: [0.0; 2],
            hi: [0.0; 2],
        };
        cf.recalculate();
        cf
    }

    pub fn set_mode(&mut self, mode: CrossfeedMode) {
        if self.mode != mode {
            self.mode = mode;
            self.recalculate();
        }
    }

    pub fn mode(&self) -> CrossfeedMode {
        self.mode
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        let sr = sample_rate.clamp(2000, 384000);
        if self.sample_rate != sr {
            self.sample_rate = sr;
            self.recalculate();
        }
    }

    pub fn reset_state(&mut self) {
        self.asis = [0.0; 2];
        self.lo = [0.0; 2];
        self.hi = [0.0; 2];
    }

    pub fn process_frames(&mut self, samples: &mut [f32], channels: usize) {
        if self.mode == CrossfeedMode::Off || channels < 2 || samples.is_empty() {
            return;
        }

        let frame_count = samples.len() / channels;

        let a0_lo = self.a0_lo;
        let b1_lo = self.b1_lo;
        let a0_hi = self.a0_hi;
        let a1_hi = self.a1_hi;
        let b1_hi = self.b1_hi;
        let gain = self.gain;

        let mut lo0 = self.lo[0];
        let mut lo1 = self.lo[1];
        let mut hi0 = self.hi[0];
        let mut hi1 = self.hi[1];
        let mut asis0 = self.asis[0];
        let mut asis1 = self.asis[1];

        for f in 0..frame_count {
            let idx = f * channels;
            let in_l = samples[idx];
            let in_r = samples[idx + 1];

            // Lowpass filter
            lo0 = a0_lo * in_l + b1_lo * lo0;
            lo1 = a0_lo * in_r + b1_lo * lo1;

            // Highboost filter
            hi0 = a0_hi * in_l + a1_hi * asis0 + b1_hi * hi0;
            hi1 = a0_hi * in_r + a1_hi * asis1 + b1_hi * hi1;
            asis0 = in_l;
            asis1 = in_r;

            // Crossfeed sum
            let out_l = (hi0 + lo1) * gain;
            let out_r = (hi1 + lo0) * gain;

            // Anti-denormal flush
            if lo0.abs() < 1e-20 { lo0 = 0.0; }
            if lo1.abs() < 1e-20 { lo1 = 0.0; }
            if hi0.abs() < 1e-20 { hi0 = 0.0; }
            if hi1.abs() < 1e-20 { hi1 = 0.0; }

            samples[idx] = out_l;
            samples[idx + 1] = out_r;
        }

        self.lo[0] = lo0;
        self.lo[1] = lo1;
        self.hi[0] = hi0;
        self.hi[1] = hi1;
        self.asis[0] = asis0;
        self.asis[1] = asis1;
    }

    fn recalculate(&mut self) {
        if self.mode == CrossfeedMode::Off {
            return;
        }

        let level = match self.mode {
            CrossfeedMode::MoffatBauer => BS2B_DEFAULT_CLEVEL,
            CrossfeedMode::ChuMoy => BS2B_CMOY_CLEVEL,
            CrossfeedMode::Off => return,
        };

        let mut fc_lo = (level & 0xffff) as f64;
        let mut lev_db = ((level & 0xffff0000) >> 16) as f64;

        if !(300.0..=2000.0).contains(&fc_lo) || !(10.0..=150.0).contains(&lev_db) {
            fc_lo = 700.0;
            lev_db = 45.0;
        }

        lev_db /= 10.0; // dB

        let gb_lo = lev_db * (-5.0 / 6.0) - 3.0;
        let gb_hi = lev_db / 6.0 - 3.0;

        let g_lo = 10.0f64.powf(gb_lo / 20.0);
        let g_hi = 1.0 - 10.0f64.powf(gb_hi / 20.0);
        let fc_hi = fc_lo * 2.0f64.powf((gb_lo - 20.0 * g_hi.log10()) / 12.0);

        let srate = self.sample_rate as f64;
        let x_lo = (-2.0 * PI * fc_lo / srate).exp();
        self.b1_lo = x_lo as f32;
        self.a0_lo = (g_lo * (1.0 - x_lo)) as f32;

        let x_hi = (-2.0 * PI * fc_hi / srate).exp();
        self.b1_hi = x_hi as f32;
        self.a0_hi = (1.0 - g_hi * (1.0 - x_hi)) as f32;
        self.a1_hi = (-x_hi) as f32;

        self.gain = (1.0 / (1.0 - g_hi + g_lo)) as f32;
    }
}
