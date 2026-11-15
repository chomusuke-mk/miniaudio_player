//! Integrated DSP Processing Pipeline (`Preamp` -> `10-Band EQ` -> `Stereo Imaging` -> `BS2B` -> `Reverb` -> `Master Volume` -> `Limiter` -> `Visualizer`).

use super::crossfeed::{Bs2bCrossfeed, CrossfeedConfig};
use super::equalizer::{compute_smoothing_factor, Equalizer, EqualizerParams, ReplayGainConfig};
use super::limiter::SoftLimiter;
use super::reverb::{Freeverb, ReverbConfig};
use super::visualizer::{Visualizer, VisualizerData};

/// Exponentially smoothed master volume gain stage preventing zipper noise.
pub struct MasterVolumeStage {
    current_volume: f32,
    target_volume: f32,
    smooth_factor: f32,
}

impl MasterVolumeStage {
    /// Creates a new `MasterVolumeStage` at unity gain (1.0).
    pub fn new(sample_rate: u32) -> Self {
        Self {
            current_volume: 1.0,
            target_volume: 1.0,
            smooth_factor: compute_smoothing_factor(sample_rate),
        }
    }

    /// Recalculates the volume smoothing coefficient upon sample rate change.
    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        self.smooth_factor = compute_smoothing_factor(sample_rate);
    }

    /// Sets the target volume level.
    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.target_volume = volume.max(0.0);
    }

    /// Applies smoothed volume scaling across interleaved audio frames.
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

/// Integrated DSP signal processing pipeline connecting EQ, crossfeed, reverb, volume, limiter, and visualizer.
pub struct DspChain {
    /// 10-band graphic equalizer and stereo imaging processor.
    pub eq: Equalizer,
    /// Bauer stereophonic-to-binaural (BS2B) crossfeed processor.
    pub crossfeed: Bs2bCrossfeed,
    /// Freeverb algorithmic reverberation unit.
    pub reverb: Freeverb,
    /// Smoothed master volume gain stage.
    pub volume_stage: MasterVolumeStage,
    /// Soft peak brickwall limiter.
    pub limiter: SoftLimiter,
    /// Real-time FFT spectrum and stereo visualizer analyzer.
    pub visualizer: Visualizer,

    channels: usize,
    sample_rate: u32,
}

impl DspChain {
    /// Constructs a new `DspChain` initialized with the given channel count and sample rate.
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        let sr = sample_rate.max(8000);

        Self {
            eq: Equalizer::new(ch, sr),
            crossfeed: Bs2bCrossfeed::new(sr, CrossfeedConfig::default()),
            reverb: Freeverb::new(sr),
            volume_stage: MasterVolumeStage::new(sr),
            limiter: SoftLimiter::new(true),
            visualizer: Visualizer::new(ch, sr),
            channels: ch,
            sample_rate: sr,
        }
    }

    /// Updates the sample rate across all internal DSP stages.
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

    /// Sets the master volume level.
    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.volume_stage.set_volume(volume);
    }

    /// Updates all 10 equalizer frequency band gains.
    #[inline]
    pub fn set_equalizer_params(&mut self, params: &EqualizerParams) {
        self.eq.set_all(params);
    }

    /// Sets the gain in dB for an individual equalizer band index (0 to 9).
    #[inline]
    pub fn set_equalizer_band(&mut self, band: usize, gain_db: f32) {
        self.eq.set_band(band, gain_db);
    }

    /// Sets the pre-amplification gain in dB applied before equalization.
    #[inline]
    pub fn set_preamp_db(&mut self, preamp_db: f32) {
        self.eq.set_preamp_db(preamp_db);
    }

    /// Configures active ReplayGain loudness normalization settings.
    #[inline]
    pub fn set_replay_gain(&mut self, rg: ReplayGainConfig) {
        self.eq.set_replay_gain(rg);
    }

    /// Sets stereo pan balance from -1.0 (hard left) to +1.0 (hard right).
    #[inline]
    pub fn set_balance(&mut self, balance: f32) {
        self.eq.set_balance(balance);
    }

    /// Enables or disables stereo downmixing to mono.
    #[inline]
    pub fn set_mono(&mut self, mono: bool) {
        self.eq.set_mono(mono);
    }

    /// Enables or disables 3D stereo widening spatializer with width factor.
    #[inline]
    pub fn set_spatializer(&mut self, enabled: bool, width: f32) {
        self.eq.set_spatializer(enabled, width);
    }

    /// Configures the Bauer binaural crossfeed filter.
    #[inline]
    pub fn set_crossfeed(&mut self, config: CrossfeedConfig) {
        self.crossfeed.set_config(config);
    }

    /// Updates Freeverb studio reverberation acoustic parameters.
    #[inline]
    pub fn set_reverb(&mut self, config: ReverbConfig) {
        self.reverb.set_config(config);
    }

    /// Enables or disables the output brickwall limiter.
    #[inline]
    pub fn set_limiter_enabled(&mut self, enabled: bool) {
        self.limiter.set_enabled(enabled);
    }

    /// Enables or disables real-time FFT spectrum analysis in the visualizer.
    #[inline]
    pub fn set_visualizer_enabled(&mut self, enabled: bool) {
        self.visualizer.set_enabled(enabled);
    }

    /// Retrieves an instantaneous snapshot of FFT spectrum and energy metrics.
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
