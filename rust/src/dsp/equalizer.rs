//! 10-band ISO 266 Equalizer, Preamp, ReplayGain, Balance, Mono and Spatializer DSP.

use super::biquad::BiquadDf2t;

pub const EQ_BAND_COUNT: usize = 10;
pub const EQ_FREQUENCIES: [f64; EQ_BAND_COUNT] = [
    31.0, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
];

pub const EQ_SHELF_SLOPE: f64 = 0.7071067811865475;
pub const EQ_Q: f64 = 1.15;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EqualizerParams {
    pub hz31: f32,
    pub hz63: f32,
    pub hz125: f32,
    pub hz250: f32,
    pub hz500: f32,
    pub hz1k: f32,
    pub hz2k: f32,
    pub hz4k: f32,
    pub hz8k: f32,
    pub hz16k: f32,
}

impl Default for EqualizerParams {
    fn default() -> Self {
        Self {
            hz31: 0.0,
            hz63: 0.0,
            hz125: 0.0,
            hz250: 0.0,
            hz500: 0.0,
            hz1k: 0.0,
            hz2k: 0.0,
            hz4k: 0.0,
            hz8k: 0.0,
            hz16k: 0.0,
        }
    }
}

impl EqualizerParams {
    pub fn as_array(&self) -> [f32; EQ_BAND_COUNT] {
        [
            self.hz31, self.hz63, self.hz125, self.hz250, self.hz500, self.hz1k, self.hz2k,
            self.hz4k, self.hz8k, self.hz16k,
        ]
    }

    pub fn from_array(arr: &[f32; EQ_BAND_COUNT]) -> Self {
        Self {
            hz31: arr[0],
            hz63: arr[1],
            hz125: arr[2],
            hz250: arr[3],
            hz500: arr[4],
            hz1k: arr[5],
            hz2k: arr[6],
            hz4k: arr[7],
            hz8k: arr[8],
            hz16k: arr[9],
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReplayGainConfig {
    pub gain_db: f32,
    pub peak: f32,
    pub prevent_clipping: i32,
    pub enabled: i32,
}

impl Default for ReplayGainConfig {
    fn default() -> Self {
        Self {
            gain_db: 0.0,
            peak: 0.0,
            prevent_clipping: 1,
            enabled: 0,
        }
    }
}

pub struct Equalizer {
    channels: usize,
    sample_rate: u32,
    band_gains: [f32; EQ_BAND_COUNT],
    // Filters per channel: filters[ch][band]
    filters: Vec<[BiquadDf2t; EQ_BAND_COUNT]>,

    preamp_db: f32,
    replay_gain: ReplayGainConfig,
    current_preamp_linear: f32,
    target_preamp_linear: f32,

    balance: f32,
    current_gl: f32,
    current_gr: f32,
    target_gl: f32,
    target_gr: f32,

    mono_enabled: bool,

    spatializer_enabled: bool,
    spatializer_width: f32,

    smooth_factor: f32,
}

impl Equalizer {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        let mut filters = Vec::with_capacity(ch);
        for _ in 0..ch {
            filters.push([BiquadDf2t::default(); EQ_BAND_COUNT]);
        }

        let mut eq = Self {
            channels: ch,
            sample_rate,
            band_gains: [0.0; EQ_BAND_COUNT],
            filters,
            preamp_db: 0.0,
            replay_gain: ReplayGainConfig::default(),
            current_preamp_linear: 1.0,
            target_preamp_linear: 1.0,
            balance: 0.0,
            current_gl: 1.0,
            current_gr: 1.0,
            target_gl: 1.0,
            target_gr: 1.0,
            mono_enabled: false,
            spatializer_enabled: false,
            spatializer_width: 1.0,
            smooth_factor: 0.005,
        };

        eq.recalculate_filters();
        eq.update_smooth_factor();
        eq
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if self.sample_rate != sample_rate && sample_rate > 0 {
            self.sample_rate = sample_rate;
            self.recalculate_filters();
            self.update_smooth_factor();
        }
    }

    pub fn set_band(&mut self, band_index: usize, gain_db: f32) {
        if band_index < EQ_BAND_COUNT {
            let clamped = gain_db.clamp(-24.0, 24.0);
            self.band_gains[band_index] = clamped;
            self.update_filter_band(band_index);
        }
    }

    pub fn set_all(&mut self, params: &EqualizerParams) {
        let arr = params.as_array();
        for i in 0..EQ_BAND_COUNT {
            self.band_gains[i] = arr[i].clamp(-24.0, 24.0);
        }
        self.recalculate_filters();
    }

    pub fn set_preamp_db(&mut self, preamp_db: f32) {
        self.preamp_db = preamp_db;
        self.recalculate_preamp();
    }

    pub fn set_replay_gain(&mut self, config: ReplayGainConfig) {
        self.replay_gain = config;
        self.recalculate_preamp();
    }

    pub fn set_balance(&mut self, balance: f32) {
        self.balance = balance.clamp(-1.0, 1.0);
        if self.balance < 0.0 {
            self.target_gl = 1.0;
            self.target_gr = 1.0 + self.balance;
        } else {
            self.target_gl = 1.0 - self.balance;
            self.target_gr = 1.0;
        }
    }

    pub fn set_mono(&mut self, enabled: bool) {
        self.mono_enabled = enabled;
    }

    pub fn set_spatializer(&mut self, enabled: bool, width: f32) {
        self.spatializer_enabled = enabled;
        self.spatializer_width = width.clamp(0.0, 2.0);
    }

    pub fn params(&self) -> EqualizerParams {
        EqualizerParams::from_array(&self.band_gains)
    }

    pub fn preamp_db(&self) -> f32 {
        self.preamp_db
    }

    pub fn replay_gain(&self) -> ReplayGainConfig {
        self.replay_gain
    }

    pub fn balance(&self) -> f32 {
        self.balance
    }

    pub fn mono(&self) -> bool {
        self.mono_enabled
    }

    pub fn spatializer_enabled(&self) -> bool {
        self.spatializer_enabled
    }

    pub fn spatializer_width(&self) -> f32 {
        self.spatializer_width
    }

    pub fn process_interleaved(&mut self, samples: &mut [f32]) {
        if samples.is_empty() || self.channels == 0 {
            return;
        }

        let frame_count = samples.len() / self.channels;
        let is_stereo = self.channels >= 2;

        for frame_idx in 0..frame_count {
            // 1. Smooth gain updates
            self.current_preamp_linear +=
                (self.target_preamp_linear - self.current_preamp_linear) * self.smooth_factor;
            self.current_gl += (self.target_gl - self.current_gl) * self.smooth_factor;
            self.current_gr += (self.target_gr - self.current_gr) * self.smooth_factor;

            let base = frame_idx * self.channels;

            // 2. Preamp application
            for ch in 0..self.channels {
                samples[base + ch] *= self.current_preamp_linear;
            }

            // 3. 10-band EQ filters
            for ch in 0..self.channels {
                let mut s = samples[base + ch];
                for b in 0..EQ_BAND_COUNT {
                    s = self.filters[ch][b].process(s);
                }
                samples[base + ch] = s;
            }

            // 4. Balance
            if is_stereo {
                samples[base] *= self.current_gl;
                samples[base + 1] *= self.current_gr;
            }

            // 5. Mono downmix
            if is_stereo && self.mono_enabled {
                let mono = (samples[base] + samples[base + 1]) * 0.5;
                samples[base] = mono;
                samples[base + 1] = mono;
            }

            // 6. Spatializer (Stereo Width)
            if is_stereo && self.spatializer_enabled && !self.mono_enabled {
                let l = samples[base];
                let r = samples[base + 1];
                let mid = (l + r) * 0.5;
                let side = (l - r) * 0.5 * self.spatializer_width;
                samples[base] = mid + side;
                samples[base + 1] = mid - side;
            }
        }
    }

    fn recalculate_preamp(&mut self) {
        let mut total_db = self.preamp_db;
        if self.replay_gain.enabled != 0 {
            total_db += self.replay_gain.gain_db;
        }

        let mut linear = 10.0f32.powf(total_db / 20.0);
        if self.replay_gain.enabled != 0
            && self.replay_gain.prevent_clipping != 0
            && self.replay_gain.peak > 0.0
        {
            let max_linear = 1.0 / self.replay_gain.peak;
            if linear > max_linear {
                linear = max_linear;
            }
        }

        self.target_preamp_linear = linear;
    }

    fn update_smooth_factor(&mut self) {
        let fs = self.sample_rate as f32;
        let factor = 1.0 - (-1.0 / (fs * 0.005)).exp();
        self.smooth_factor = if factor <= 0.0 || factor > 0.05 { 0.005 } else { factor };
    }

    fn update_filter_band(&mut self, b: usize) {
        let fs = self.sample_rate as f64;
        let f0 = EQ_FREQUENCIES[b];
        let gain = self.band_gains[b] as f64;

        let proto = if b == 0 {
            BiquadDf2t::low_shelf(f0, fs, gain, EQ_SHELF_SLOPE)
        } else if b == EQ_BAND_COUNT - 1 {
            BiquadDf2t::high_shelf(f0, fs, gain, EQ_SHELF_SLOPE)
        } else {
            BiquadDf2t::peaking(f0, fs, gain, EQ_Q)
        };

        for ch in 0..self.channels {
            // Preserve s1, s2 state registers across coefficient updates
            let s1 = self.filters[ch][b].s1;
            let s2 = self.filters[ch][b].s2;
            self.filters[ch][b] = proto;
            self.filters[ch][b].s1 = s1;
            self.filters[ch][b].s2 = s2;
        }
    }

    fn recalculate_filters(&mut self) {
        for b in 0..EQ_BAND_COUNT {
            self.update_filter_band(b);
        }
    }
}
