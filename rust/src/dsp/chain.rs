//! Integrated DSP Processing Pipeline (`Preamp` -> `10-Band EQ` -> `Stereo Imaging` -> `BS2B` -> `Reverb` -> `Master Volume` -> `Limiter` -> `Visualizer`).

use super::crossfeed::{Bs2bCrossfeed, CrossfeedMode};
use super::equalizer::{compute_smoothing_factor, Equalizer, EqualizerParams, ReplayGainConfig};
use super::limiter::SoftLimiter;
use super::reverb::{Freeverb, ReverbConfig};
use super::visualizer::{Visualizer, VisualizerData};

/// Smoothed master output volume stage.
pub struct MasterVolumeStage {
    current_volume: f32,
    target_volume: f32,
    smooth_factor: f32,
}

impl MasterVolumeStage {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            current_volume: 1.0,
            target_volume: 1.0,
            smooth_factor: compute_smoothing_factor(sample_rate),
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        self.smooth_factor = compute_smoothing_factor(sample_rate);
    }

    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.target_volume = volume.max(0.0);
    }

    #[inline]
    pub fn volume(&self) -> f32 {
        self.target_volume
    }

    #[inline]
    pub fn process_frames(&mut self, frames: &mut [f32], channels: usize) {
        if frames.is_empty() || channels == 0 {
            return;
        }
        for frame in frames.chunks_exact_mut(channels) {
            self.current_volume += (self.target_volume - self.current_volume) * self.smooth_factor;
            for sample in frame.iter_mut() {
                *sample *= self.current_volume;
            }
        }
    }
}

pub struct DspChain {
    pub eq: Equalizer,
    pub crossfeed: Bs2bCrossfeed,
    pub reverb: Freeverb,
    pub volume_stage: MasterVolumeStage,
    pub limiter: SoftLimiter,
    pub visualizer: Visualizer,

    channels: usize,
    sample_rate: u32,
}

impl DspChain {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        let sr = sample_rate.max(8000);

        Self {
            eq: Equalizer::new(ch, sr),
            crossfeed: Bs2bCrossfeed::new(sr, CrossfeedMode::Off),
            reverb: Freeverb::new(sr),
            volume_stage: MasterVolumeStage::new(sr),
            limiter: SoftLimiter::new(true),
            visualizer: Visualizer::new(ch, sr),
            channels: ch,
            sample_rate: sr,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if sample_rate > 0 && self.sample_rate != sample_rate {
            self.sample_rate = sample_rate;
            self.eq.set_sample_rate(sample_rate);
            self.crossfeed.set_sample_rate(sample_rate);
            self.reverb.set_sample_rate(sample_rate);
            self.volume_stage.set_sample_rate(sample_rate);
            self.visualizer.set_sample_rate(sample_rate);
        }
    }

    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.volume_stage.set_volume(volume);
    }

    #[inline]
    pub fn volume(&self) -> f32 {
        self.volume_stage.volume()
    }

    #[inline]
    pub fn set_equalizer_params(&mut self, params: &EqualizerParams) {
        self.eq.set_all(params);
    }

    #[inline]
    pub fn set_equalizer_band(&mut self, band: usize, gain_db: f32) {
        self.eq.set_band(band, gain_db);
    }

    #[inline]
    pub fn set_preamp_db(&mut self, preamp_db: f32) {
        self.eq.set_preamp_db(preamp_db);
    }

    #[inline]
    pub fn set_replay_gain(&mut self, rg: ReplayGainConfig) {
        self.eq.set_replay_gain(rg);
    }

    #[inline]
    pub fn set_balance(&mut self, balance: f32) {
        self.eq.set_balance(balance);
    }

    #[inline]
    pub fn set_mono(&mut self, mono: bool) {
        self.eq.set_mono(mono);
    }

    #[inline]
    pub fn set_spatializer(&mut self, enabled: bool, width: f32) {
        self.eq.set_spatializer(enabled, width);
    }

    #[inline]
    pub fn set_crossfeed(&mut self, mode: CrossfeedMode) {
        self.crossfeed.set_mode(mode);
    }

    #[inline]
    pub fn set_reverb(&mut self, config: ReverbConfig) {
        self.reverb.set_config(config);
    }

    #[inline]
    pub fn set_limiter_enabled(&mut self, enabled: bool) {
        self.limiter.set_enabled(enabled);
    }

    #[inline]
    pub fn set_visualizer_enabled(&mut self, enabled: bool) {
        self.visualizer.set_enabled(enabled);
    }

    #[inline]
    pub fn visualizer_data(&self) -> VisualizerData {
        self.visualizer.get_data()
    }

    /// Processes interleaved PCM frames in-place through the declarative DSP stage pipeline.
    pub fn process_frames(&mut self, frames: &mut [f32]) {
        if frames.is_empty() || self.channels == 0 {
            return;
        }
        self.eq.process_interleaved(frames);
        self.crossfeed.process_frames(frames, self.channels);
        self.reverb.process_frames(frames, self.channels);
        self.volume_stage.process_frames(frames, self.channels);
        self.limiter.process_frames(frames);
        self.visualizer.process_frames(frames);
    }
}
