//! Integrated DSP Processing Pipeline (EQ -> Preamp -> Balance -> BS2B -> Reverb -> Volume -> Limiter -> Visualizer).

use super::crossfeed::{Bs2bCrossfeed, CrossfeedMode};
use super::equalizer::{Equalizer, EqualizerParams, ReplayGainConfig};
use super::limiter::SoftLimiter;
use super::reverb::{Freeverb, ReverbConfig};
use super::visualizer::{Visualizer, VisualizerData};

pub struct DspChain {
    pub eq: Equalizer,
    pub crossfeed: Bs2bCrossfeed,
    pub reverb: Freeverb,
    pub limiter: SoftLimiter,
    pub visualizer: Visualizer,

    channels: usize,
    sample_rate: u32,

    current_volume: f32,
    target_volume: f32,
    smooth_factor: f32,
}

impl DspChain {
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        let sr = if sample_rate == 0 { 44100 } else { sample_rate };

        let factor = 1.0 - (-1.0 / (sr as f32 * 0.005)).exp();
        let smooth_factor = if factor <= 0.0 || factor > 0.05 { 0.005 } else { factor };

        Self {
            eq: Equalizer::new(ch, sr),
            crossfeed: Bs2bCrossfeed::new(sr, CrossfeedMode::Off),
            reverb: Freeverb::new(sr),
            limiter: SoftLimiter::new(true),
            visualizer: Visualizer::new(ch, sr),
            channels: ch,
            sample_rate: sr,
            current_volume: 1.0,
            target_volume: 1.0,
            smooth_factor,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if self.sample_rate != sample_rate && sample_rate > 0 {
            self.sample_rate = sample_rate;
            self.eq.set_sample_rate(sample_rate);
            self.crossfeed.set_sample_rate(sample_rate);
            self.reverb.set_sample_rate(sample_rate);
            self.visualizer.set_sample_rate(sample_rate);

            let factor = 1.0 - (-1.0 / (sample_rate as f32 * 0.005)).exp();
            self.smooth_factor = if factor <= 0.0 || factor > 0.05 { 0.005 } else { factor };
        }
    }

    pub fn set_volume(&mut self, volume: f32) {
        self.target_volume = volume.max(0.0);
    }

    pub fn volume(&self) -> f32 {
        self.target_volume
    }

    pub fn set_equalizer_params(&mut self, params: &EqualizerParams) {
        self.eq.set_all(params);
    }

    pub fn set_equalizer_band(&mut self, band: usize, gain_db: f32) {
        self.eq.set_band(band, gain_db);
    }

    pub fn set_preamp_db(&mut self, preamp_db: f32) {
        self.eq.set_preamp_db(preamp_db);
    }

    pub fn set_replay_gain(&mut self, rg: ReplayGainConfig) {
        self.eq.set_replay_gain(rg);
    }

    pub fn set_balance(&mut self, balance: f32) {
        self.eq.set_balance(balance);
    }

    pub fn set_mono(&mut self, mono: bool) {
        self.eq.set_mono(mono);
    }

    pub fn set_spatializer(&mut self, enabled: bool, width: f32) {
        self.eq.set_spatializer(enabled, width);
    }

    pub fn set_crossfeed(&mut self, mode: CrossfeedMode) {
        self.crossfeed.set_mode(mode);
    }

    pub fn set_reverb(&mut self, config: ReverbConfig) {
        self.reverb.set_config(config);
    }

    pub fn set_limiter_enabled(&mut self, enabled: bool) {
        self.limiter.set_enabled(enabled);
    }

    pub fn set_visualizer_enabled(&mut self, enabled: bool) {
        self.visualizer.set_enabled(enabled);
    }

    pub fn visualizer_data(&self) -> VisualizerData {
        self.visualizer.get_data()
    }

    /// Process interleaved PCM frames in-place through the complete DSP chain.
    pub fn process_frames(&mut self, frames: &mut [f32]) {
        if frames.is_empty() || self.channels == 0 {
            return;
        }

        // 1. Equalizer (Preamp, 10-band EQ, Balance, Mono, Spatializer)
        self.eq.process_interleaved(frames);

        // 2. Crossfeed (Bauer BS2B)
        self.crossfeed.process_frames(frames, self.channels);

        // 3. Reverb (Freeverb)
        self.reverb.process_frames(frames, self.channels);

        // 4. Volume smoothing
        let frame_count = frames.len() / self.channels;
        for f in 0..frame_count {
            self.current_volume += (self.target_volume - self.current_volume) * self.smooth_factor;
            let idx = f * self.channels;
            for c in 0..self.channels {
                frames[idx + c] *= self.current_volume;
            }
        }

        // 5. True-Peak Soft-Knee Limiter (DAC Protector)
        self.limiter.process_frames(frames);

        // 6. Visualizer analysis
        self.visualizer.process_frames(frames);
    }
}
