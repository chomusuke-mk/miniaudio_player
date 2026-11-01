//! Modular Gain, ISO 266 10-Band Equalizer, and Stereo Field Stages.
//!
//! Decomposes equalization and stereo field processing into single-responsibility DSP stages:
//! - [`PreampStage`]: Preamp gain + ReplayGain normalization with anti-clipping ceiling.
//! - [`Iso10BandStage`]: 10-band ISO 266 DF2T Biquad filter bank per channel.
//! - [`StereoImagingStage`]: Stereo balance, mono downmix, and Mid-Side width spatializer.
//! - [`Equalizer`]: Facade coordinating the three stages in a deterministic pipeline.

use super::biquad::BiquadDf2t;

pub const EQ_BAND_COUNT: usize = 10;
pub const EQ_FREQUENCIES: [f64; EQ_BAND_COUNT] = [
    31.0, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
];

pub const EQ_SHELF_SLOPE: f64 = 0.7071067811865475;
pub const EQ_Q: f64 = 1.15;

#[inline]
pub(crate) fn compute_smoothing_factor(sample_rate: u32) -> f32 {
    if sample_rate == 0 {
        return 0.005;
    }
    let factor = 1.0 - (-1.0 / (sample_rate as f32 * 0.005)).exp();
    if factor <= 0.0 || factor > 0.05 {
        0.005
    } else {
        factor
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
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

impl EqualizerParams {
    #[inline]
    pub const fn as_array(&self) -> [f32; EQ_BAND_COUNT] {
        [
            self.hz31, self.hz63, self.hz125, self.hz250, self.hz500, self.hz1k, self.hz2k,
            self.hz4k, self.hz8k, self.hz16k,
        ]
    }

    #[inline]
    pub const fn from_array(arr: &[f32; EQ_BAND_COUNT]) -> Self {
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

    pub fn set_band(&mut self, band_index: usize, gain_db: f32) {
        if band_index < EQ_BAND_COUNT {
            let mut arr = self.as_array();
            arr[band_index] = gain_db;
            *self = Self::from_array(&arr);
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

/// Stage 1: Smoothed Preamp & ReplayGain Processor.
pub struct PreampStage {
    preamp_db: f32,
    replay_gain: ReplayGainConfig,
    current_linear: f32,
    target_linear: f32,
    smooth_factor: f32,
}

impl PreampStage {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            preamp_db: 0.0,
            replay_gain: ReplayGainConfig::default(),
            current_linear: 1.0,
            target_linear: 1.0,
            smooth_factor: compute_smoothing_factor(sample_rate),
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        self.smooth_factor = compute_smoothing_factor(sample_rate);
    }

    pub fn set_preamp_db(&mut self, preamp_db: f32) {
        self.preamp_db = preamp_db;
        self.recalculate_target();
    }

    pub fn set_replay_gain(&mut self, config: ReplayGainConfig) {
        self.replay_gain = config;
        self.recalculate_target();
    }

    #[inline]
    pub fn preamp_db(&self) -> f32 {
        self.preamp_db
    }

    #[inline]
    pub fn replay_gain(&self) -> ReplayGainConfig {
        self.replay_gain
    }

    fn recalculate_target(&mut self) {
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
        self.target_linear = linear;
    }

    #[inline]
    pub fn process_interleaved(&mut self, samples: &mut [f32], channels: usize) {
        if samples.is_empty() || channels == 0 {
            return;
        }
        for frame in samples.chunks_exact_mut(channels) {
            self.current_linear += (self.target_linear - self.current_linear) * self.smooth_factor;
            for sample in frame.iter_mut() {
                *sample *= self.current_linear;
            }
        }
    }
}

/// Stage 2: 10-Band ISO 266 Biquad Filter Bank.
pub struct Iso10BandStage {
    sample_rate: u32,
    band_gains: [f32; EQ_BAND_COUNT],
    filters: Vec<[BiquadDf2t; EQ_BAND_COUNT]>,
}

impl Iso10BandStage {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        let mut stage = Self {
            sample_rate,
            band_gains: [0.0; EQ_BAND_COUNT],
            filters: vec![[BiquadDf2t::identity(); EQ_BAND_COUNT]; ch],
        };
        stage.recalculate_all_bands();
        stage
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if sample_rate > 0 && self.sample_rate != sample_rate {
            self.sample_rate = sample_rate;
            self.recalculate_all_bands();
        }
    }

    pub fn set_band(&mut self, band_index: usize, gain_db: f32) {
        if band_index < EQ_BAND_COUNT {
            self.band_gains[band_index] = gain_db.clamp(-24.0, 24.0);
            self.update_band(band_index);
        }
    }

    pub fn set_all(&mut self, params: &EqualizerParams) {
        let arr = params.as_array();
        for (i, &g) in arr.iter().enumerate() {
            self.band_gains[i] = g.clamp(-24.0, 24.0);
        }
        self.recalculate_all_bands();
    }

    #[inline]
    pub fn params(&self) -> EqualizerParams {
        EqualizerParams::from_array(&self.band_gains)
    }

    fn update_band(&mut self, band_idx: usize) {
        let fs = self.sample_rate as f64;
        let f0 = EQ_FREQUENCIES[band_idx];
        let gain = self.band_gains[band_idx] as f64;

        let proto = if band_idx == 0 {
            BiquadDf2t::low_shelf(f0, fs, gain, EQ_SHELF_SLOPE)
        } else if band_idx == EQ_BAND_COUNT - 1 {
            BiquadDf2t::high_shelf(f0, fs, gain, EQ_SHELF_SLOPE)
        } else {
            BiquadDf2t::peaking(f0, fs, gain, EQ_Q)
        };

        for ch_filters in &mut self.filters {
            ch_filters[band_idx].update_coefficients_from(&proto);
        }
    }

    fn recalculate_all_bands(&mut self) {
        for b in 0..EQ_BAND_COUNT {
            self.update_band(b);
        }
    }

    #[inline]
    pub fn process_interleaved(&mut self, samples: &mut [f32], channels: usize) {
        if samples.is_empty() || channels == 0 || channels > self.filters.len() {
            return;
        }
        for frame in samples.chunks_exact_mut(channels) {
            for (ch, sample) in frame.iter_mut().enumerate() {
                let mut s = *sample;
                for filter in &mut self.filters[ch] {
                    s = filter.process(s);
                }
                *sample = s;
            }
        }
    }
}

/// Stage 3: Stereo Balance, Mono Downmix, and Mid-Side Width Spatializer.
pub struct StereoImagingStage {
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

impl StereoImagingStage {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            balance: 0.0,
            current_gl: 1.0,
            current_gr: 1.0,
            target_gl: 1.0,
            target_gr: 1.0,
            mono_enabled: false,
            spatializer_enabled: false,
            spatializer_width: 1.0,
            smooth_factor: compute_smoothing_factor(sample_rate),
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        self.smooth_factor = compute_smoothing_factor(sample_rate);
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

    #[inline]
    pub fn balance(&self) -> f32 {
        self.balance
    }

    #[inline]
    pub fn mono(&self) -> bool {
        self.mono_enabled
    }

    #[inline]
    pub fn spatializer_enabled(&self) -> bool {
        self.spatializer_enabled
    }

    #[inline]
    pub fn spatializer_width(&self) -> f32 {
        self.spatializer_width
    }

    #[inline]
    pub fn process_interleaved(&mut self, samples: &mut [f32], channels: usize) {
        if samples.is_empty() || channels < 2 {
            return;
        }
        for frame in samples.chunks_exact_mut(channels) {
            self.current_gl += (self.target_gl - self.current_gl) * self.smooth_factor;
            self.current_gr += (self.target_gr - self.current_gr) * self.smooth_factor;

            frame[0] *= self.current_gl;
            frame[1] *= self.current_gr;

            if self.mono_enabled {
                let mono = (frame[0] + frame[1]) * 0.5;
                frame[0] = mono;
                frame[1] = mono;
            } else if self.spatializer_enabled {
                let l = frame[0];
                let r = frame[1];
                let mid = (l + r) * 0.5;
                let side = (l - r) * 0.5 * self.spatializer_width;
                frame[0] = mid + side;
                frame[1] = mid - side;
            }
        }
    }
}

/// Composite Equalizer Pipeline orchestrating [`PreampStage`], [`Iso10BandStage`], and [`StereoImagingStage`].
pub struct Equalizer {
    channels: usize,
    sample_rate: u32,
    pub preamp: PreampStage,
    pub bands: Iso10BandStage,
    pub stereo: StereoImagingStage,
}

impl Equalizer {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        Self {
            channels: ch,
            sample_rate,
            preamp: PreampStage::new(sample_rate),
            bands: Iso10BandStage::new(ch, sample_rate),
            stereo: StereoImagingStage::new(sample_rate),
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if sample_rate > 0 && self.sample_rate != sample_rate {
            self.sample_rate = sample_rate;
            self.preamp.set_sample_rate(sample_rate);
            self.bands.set_sample_rate(sample_rate);
            self.stereo.set_sample_rate(sample_rate);
        }
    }

    #[inline]
    pub fn set_band(&mut self, band_index: usize, gain_db: f32) {
        self.bands.set_band(band_index, gain_db);
    }

    #[inline]
    pub fn set_all(&mut self, params: &EqualizerParams) {
        self.bands.set_all(params);
    }

    #[inline]
    pub fn set_preamp_db(&mut self, preamp_db: f32) {
        self.preamp.set_preamp_db(preamp_db);
    }

    #[inline]
    pub fn set_replay_gain(&mut self, config: ReplayGainConfig) {
        self.preamp.set_replay_gain(config);
    }

    #[inline]
    pub fn set_balance(&mut self, balance: f32) {
        self.stereo.set_balance(balance);
    }

    #[inline]
    pub fn set_mono(&mut self, enabled: bool) {
        self.stereo.set_mono(enabled);
    }

    #[inline]
    pub fn set_spatializer(&mut self, enabled: bool, width: f32) {
        self.stereo.set_spatializer(enabled, width);
    }

    #[inline]
    pub fn params(&self) -> EqualizerParams {
        self.bands.params()
    }

    #[inline]
    pub fn preamp_db(&self) -> f32 {
        self.preamp.preamp_db()
    }

    #[inline]
    pub fn replay_gain(&self) -> ReplayGainConfig {
        self.preamp.replay_gain()
    }

    #[inline]
    pub fn balance(&self) -> f32 {
        self.stereo.balance()
    }

    #[inline]
    pub fn mono(&self) -> bool {
        self.stereo.mono()
    }

    #[inline]
    pub fn spatializer_enabled(&self) -> bool {
        self.stereo.spatializer_enabled()
    }

    #[inline]
    pub fn spatializer_width(&self) -> f32 {
        self.stereo.spatializer_width()
    }

    pub fn process_interleaved(&mut self, samples: &mut [f32]) {
        if samples.is_empty() || self.channels == 0 {
            return;
        }
        self.preamp.process_interleaved(samples, self.channels);
        self.bands.process_interleaved(samples, self.channels);
        self.stereo.process_interleaved(samples, self.channels);
    }
}
