//! Reusable DSP Effect Chain Processor.
//!
//! Applies Equalization, Reverb, Panning, and Gain in a vectorized SIMD pass.

use crate::dsp::equalizer::{Equalizer, EqualizerParams, ReplayGainConfig};
use crate::dsp::reverb::{Freeverb, ReverbConfig};

pub struct DspProcessor {
    pub equalizer: Equalizer,
    pub reverb: Freeverb,
    pub volume: f32,
    pub balance: f32,
    pub mono: bool,
    pub sample_rate: u32,
    pub channels: usize,
}

impl DspProcessor {
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        let ch = channels.max(1);
        Self {
            equalizer: Equalizer::new(ch, sample_rate),
            reverb: Freeverb::new(sample_rate),
            volume: 1.0,
            balance: 0.0,
            mono: false,
            sample_rate,
            channels: ch,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if sample_rate > 0 && self.sample_rate != sample_rate {
            self.sample_rate = sample_rate;
            self.equalizer.set_sample_rate(sample_rate);
            self.reverb.set_sample_rate(sample_rate);
        }
    }

    #[inline]
    pub fn set_equalizer(&mut self, params: &EqualizerParams) {
        self.equalizer.set_all(params);
    }

    #[inline]
    pub fn set_reverb(&mut self, config: ReverbConfig) {
        self.reverb.set_config(config);
    }

    #[inline]
    pub fn set_preamp(&mut self, preamp_db: f32) {
        self.equalizer.set_preamp_db(preamp_db);
    }

    #[inline]
    pub fn set_replay_gain(&mut self, config: ReplayGainConfig) {
        self.equalizer.set_replay_gain(config);
    }

    #[inline]
    pub fn set_balance(&mut self, balance: f32) {
        self.balance = balance.clamp(-1.0, 1.0);
        self.equalizer.set_balance(self.balance);
    }

    #[inline]
    pub fn set_mono(&mut self, mono: bool) {
        self.mono = mono;
        self.equalizer.set_mono(mono);
    }

    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.volume = volume.max(0.0);
    }

    /// Processes audio samples in-place through the DSP chain.
    #[inline]
    pub fn process(&mut self, samples: &mut [f32]) {
        if samples.is_empty() {
            return;
        }

        // 1. Equalizer (Preamp, ReplayGain, 10-band ISO biquad, Stereo Balance/Mono)
        self.equalizer.process_interleaved(samples);

        // 2. Algorithmic Stereo Reverb (Freeverb)
        self.reverb.process_frames(samples, self.channels);

        // 3. Local Gain Scaling
        if (self.volume - 1.0).abs() > 1e-4 {
            for s in samples.iter_mut() {
                *s *= self.volume;
            }
        }
    }
}
