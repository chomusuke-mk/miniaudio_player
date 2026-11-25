//! 10-band Visualizer, RMS, and Peak energy tracking with adaptive perceptual weighting.

use super::biquad::BiquadDf2t;
use super::equalizer::{EQ_BAND_COUNT, EQ_FREQUENCIES};

/// Perceptual amplitude weighting factors for each of the 10 visualizer frequency bands.
pub const BAND_WEIGHTS: [f32; EQ_BAND_COUNT] = [1.4, 1.6, 1.8, 2.0, 2.2, 2.4, 2.8, 3.2, 3.6, 4.0];

/// Instantaneous visualizer measurements including 10-band spectrum, RMS, and channel peaks.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VisualizerData {
    /// Normalized amplitude `[0.0, 1.0]` across 10 EQ frequency bands.
    pub bands: [f32; 10],
    /// Overall Root-Mean-Square (RMS) power level `[0.0, 1.0]`.
    pub rms: f32,
    /// Maximum absolute peak level across channels `[0.0, 1.0]`.
    pub peak: f32,
    /// Left channel peak level `[0.0, 1.0]`.
    pub left: f32,
    /// Right channel peak level `[0.0, 1.0]`.
    pub right: f32,
}

impl Default for VisualizerData {
    /// Returns zeroed [`VisualizerData`] representing silence.
    fn default() -> Self {
        Self {
            bands: [0.0; 10],
            rms: 0.0,
            peak: 0.0,
            left: 0.0,
            right: 0.0,
        }
    }
}

impl VisualizerData {
    /// Checks whether any metric in this measurement differs from `other` beyond a threshold of `1e-4`.
    pub fn is_different_from(&self, other: &Self) -> bool {
        if (self.rms - other.rms).abs() > 1e-4 {
            return true;
        }
        if (self.peak - other.peak).abs() > 1e-4 {
            return true;
        }
        if (self.left - other.left).abs() > 1e-4 || (self.right - other.right).abs() > 1e-4 {
            return true;
        }
        for i in 0..10 {
            if (self.bands[i] - other.bands[i]).abs() > 1e-4 {
                return true;
            }
        }
        false
    }

    /// Returns whether the visualizer data is silent (all metrics at zero or below audible noise floor).
    #[inline]
    pub fn is_silent(&self) -> bool {
        self.rms <= 1e-4 && self.peak <= 1e-4 && self.bands.iter().all(|&b| b <= 1e-4)
    }
}

/// Real-time audio visualizer analyzing 10 frequency bands and signal levels.
pub struct Visualizer {
    /// Whether visualizer analysis is enabled.
    enabled: bool,
    /// Active audio sample rate in Hz.
    sample_rate: u32,
    /// Number of interleaved audio channels in incoming buffers.
    channels: usize,
    /// Bank of 10 constant-skirt-gain bandpass filters tuned to ISO 266 EQ frequencies.
    bpf_filters: [BiquadDf2t; EQ_BAND_COUNT],
    /// Most recently computed visualizer snapshot.
    current_data: VisualizerData,
}

impl Visualizer {
    /// Creates a new `Visualizer` instance for `channels` and `sample_rate`.
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let sr = if sample_rate == 0 { 44100 } else { sample_rate };
        let mut vis = Self {
            enabled: false,
            sample_rate: sr,
            channels: channels.max(1),
            bpf_filters: [BiquadDf2t::default(); EQ_BAND_COUNT],
            current_data: VisualizerData::default(),
        };
        vis.recalculate_filters();
        vis
    }

    /// Sets whether real-time visualizer processing is `enabled`, resetting state when disabled.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.reset();
        }
    }

    /// Resets all visualizer filter states and clears current measurements to default zeros.
    pub fn reset(&mut self) {
        self.current_data = VisualizerData::default();
        for f in &mut self.bpf_filters {
            f.reset_state();
        }
    }

    /// Updates `sample_rate` and recalculates bandpass filter coefficients when changed.
    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if self.sample_rate != sample_rate && sample_rate > 0 {
            self.sample_rate = sample_rate;
            self.recalculate_filters();
        }
    }

    /// Returns the latest calculated visualizer measurements.
    pub fn get_data(&self) -> VisualizerData {
        self.current_data
    }

    /// Processes a buffer of interleaved float `frames` and updates band energies and peak levels.
    pub fn process_frames(&mut self, frames: &[f32]) {
        if !self.enabled || frames.is_empty() || self.channels == 0 {
            return;
        }

        let total_frames = frames.len() / self.channels;
        let is_stereo = self.channels >= 2;

        let mut sum_sq_l: f32 = 0.0;
        let mut sum_sq_r: f32 = 0.0;
        let mut peak_l: f32 = 0.0;
        let mut peak_r: f32 = 0.0;
        let mut band_sq: [f32; EQ_BAND_COUNT] = [0.0; EQ_BAND_COUNT];

        for f in 0..total_frames {
            let idx = f * self.channels;
            let l = frames[idx];
            let r = if is_stereo { frames[idx + 1] } else { l };

            let abs_l = l.abs();
            let abs_r = r.abs();
            if abs_l > peak_l {
                peak_l = abs_l;
            }
            if abs_r > peak_r {
                peak_r = abs_r;
            }

            sum_sq_l += l * l;
            sum_sq_r += r * r;

            let mono = (l + r) * 0.5;
            for (b, band_acc) in band_sq.iter_mut().enumerate().take(EQ_BAND_COUNT) {
                let filtered = self.bpf_filters[b].process(mono);
                *band_acc += filtered * filtered;
            }
        }

        let inv_frames = 1.0 / total_frames as f32;
        let rms_l = (sum_sq_l * inv_frames).sqrt();
        let rms_r = (sum_sq_r * inv_frames).sqrt();
        let global_rms = (0.5 * (rms_l + rms_r)).min(1.0);
        let global_peak = (peak_l.max(peak_r)).min(1.0);

        // Adaptive decay envelope (100ms standard release)
        let dt = total_frames as f32 / self.sample_rate as f32;
        let decay = (-dt / 0.100).exp().clamp(0.1, 0.99);

        let mut new_bands = [0.0; EQ_BAND_COUNT];
        for b in 0..EQ_BAND_COUNT {
            let b_rms = (band_sq[b] * inv_frames).sqrt() * BAND_WEIGHTS[b];
            let b_clamped = b_rms.min(1.0);
            if b_clamped >= self.current_data.bands[b] {
                new_bands[b] = b_clamped;
            } else {
                let decayed = self.current_data.bands[b] * decay + b_clamped * (1.0 - decay);
                new_bands[b] = if decayed < 1e-4 { 0.0 } else { decayed };
            }
        }

        let eff_rms = if global_rms < 1e-4 { 0.0 } else { global_rms };
        let eff_peak = if global_peak < 1e-4 { 0.0 } else { global_peak };
        let eff_left = if peak_l < 1e-4 { 0.0 } else { peak_l.min(1.0) };
        let eff_right = if peak_r < 1e-4 { 0.0 } else { peak_r.min(1.0) };

        let candidate = VisualizerData {
            bands: new_bands,
            rms: eff_rms,
            peak: eff_peak,
            left: eff_left,
            right: eff_right,
        };

        if candidate.is_silent() {
            self.reset();
        } else {
            self.current_data = candidate;
        }
    }

    /// Recalculates the 10 bandpass filter coefficients from `sample_rate` while preserving filter states.
    fn recalculate_filters(&mut self) {
        let fs = self.sample_rate as f64;
        for (b, &freq) in EQ_FREQUENCIES.iter().enumerate().take(EQ_BAND_COUNT) {
            let s1 = self.bpf_filters[b].s1;
            let s2 = self.bpf_filters[b].s2;
            self.bpf_filters[b] = BiquadDf2t::bandpass(freq, fs, 1.2);
            self.bpf_filters[b].s1 = s1;
            self.bpf_filters[b].s2 = s2;
        }
    }
}
