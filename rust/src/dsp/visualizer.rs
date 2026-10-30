//! 10-band Visualizer, RMS, and Peak energy tracking with adaptive perceptual weighting.

use super::biquad::BiquadDf2t;
use super::equalizer::{EQ_BAND_COUNT, EQ_FREQUENCIES};

pub const BAND_WEIGHTS: [f32; EQ_BAND_COUNT] = [
    1.4, 1.6, 1.8, 2.0, 2.2, 2.4, 2.8, 3.2, 3.6, 4.0,
];

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VisualizerData {
    pub bands: [f32; 10],
    pub rms: f32,
    pub peak: f32,
    pub left: f32,
    pub right: f32,
}

impl Default for VisualizerData {
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

pub struct Visualizer {
    enabled: bool,
    sample_rate: u32,
    channels: usize,
    bpf_filters: [BiquadDf2t; EQ_BAND_COUNT],
    current_data: VisualizerData,
}

impl Visualizer {
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

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.current_data = VisualizerData::default();
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if self.sample_rate != sample_rate && sample_rate > 0 {
            self.sample_rate = sample_rate;
            self.recalculate_filters();
        }
    }

    pub fn get_data(&self) -> VisualizerData {
        self.current_data
    }

    pub fn data(&self) -> VisualizerData {
        self.current_data
    }

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
            if abs_l > peak_l { peak_l = abs_l; }
            if abs_r > peak_r { peak_r = abs_r; }

            sum_sq_l += l * l;
            sum_sq_r += r * r;

            let mono = (l + r) * 0.5;
            for b in 0..EQ_BAND_COUNT {
                let filtered = self.bpf_filters[b].process(mono);
                band_sq[b] += filtered * filtered;
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
                new_bands[b] = self.current_data.bands[b] * decay + b_clamped * (1.0 - decay);
            }
        }

        self.current_data = VisualizerData {
            bands: new_bands,
            rms: global_rms,
            peak: global_peak,
            left: peak_l.min(1.0),
            right: peak_r.min(1.0),
        };
    }

    fn recalculate_filters(&mut self) {
        let fs = self.sample_rate as f64;
        for b in 0..EQ_BAND_COUNT {
            let s1 = self.bpf_filters[b].s1;
            let s2 = self.bpf_filters[b].s2;
            self.bpf_filters[b] = BiquadDf2t::bandpass(EQ_FREQUENCIES[b], fs, 1.2);
            self.bpf_filters[b].s1 = s1;
            self.bpf_filters[b].s2 = s2;
        }
    }
}
