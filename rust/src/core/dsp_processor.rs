//! Reusable DSP Effect Chain Processor.
//!
//! Applies Equalization, Reverb, Panning, and Gain in a vectorized SIMD pass.

use crate::dsp::equalizer::{Equalizer, EqualizerParams, ReplayGainConfig};
use crate::dsp::reverb::{Freeverb, ReverbConfig};

/// Reusable vectorized DSP effect chain applying Equalizer, Reverb, Panning, and Volume.
pub struct DspProcessor {
    /// 10-band ISO peaking equalizer and preamp processor.
    pub equalizer: Equalizer,
    /// Freeverb algorithmic stereo reverberation network.
    pub reverb: Freeverb,
    /// Local volume factor.
    pub volume: f32,
    /// Stereo panning balance (-1.0 to 1.0).
    pub balance: f32,
    /// Whether monophonic downmixing is enabled.
    pub mono: bool,
    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: usize,
}

impl DspProcessor {
    /// Creates a new `DspProcessor` initialized with the given `sample_rate` and `channels` count.
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        let ch = channels.max(1);
        crate::map_log!(4, "[DSP] Initialized DspProcessor (sr={}, ch={})", sample_rate, ch);
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

    /// Updates `sample_rate` across equalizer and reverb stages when positive and changed.
    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if sample_rate > 0 && self.sample_rate != sample_rate {
            crate::map_log!(
                3,
                "[DSP] Updating DspProcessor sample rate: {} -> {} Hz",
                self.sample_rate,
                sample_rate
            );
            self.sample_rate = sample_rate;
            self.equalizer.set_sample_rate(sample_rate);
            self.reverb.set_sample_rate(sample_rate);
        }
    }

    /// Updates 10-band equalizer band gains from `params`.
    #[inline]
    pub fn set_equalizer(&mut self, params: &EqualizerParams) {
        crate::map_log!(5, "[DSP] Updating equalizer params (enabled={})", params.enabled);
        self.equalizer.set_all(params);
    }

    /// Configures algorithmic reverb parameters from `config`.
    #[inline]
    pub fn set_reverb(&mut self, config: ReverbConfig) {
        crate::map_log!(5, "[DSP] Updating reverb config (enabled={})", config.enabled);
        self.reverb.set_config(config);
    }

    /// Sets preamp gain in decibels via `preamp_db`.
    #[inline]
    pub fn set_preamp(&mut self, preamp_db: f32) {
        crate::map_log!(5, "[DSP] Setting preamp={} dB", preamp_db);
        self.equalizer.set_preamp_db(preamp_db);
    }

    /// Configures ReplayGain loudness normalization using `config`.
    #[inline]
    pub fn set_replay_gain(&mut self, config: ReplayGainConfig) {
        crate::map_log!(
            5,
            "[DSP] Setting ReplayGain (gain_db={}, peak={})",
            config.gain_db,
            config.peak
        );
        self.equalizer.set_replay_gain(config);
    }

    /// Sets stereo pan `balance` clamped to `-1.0` (left) through `1.0` (right).
    #[inline]
    pub fn set_balance(&mut self, balance: f32) {
        self.balance = balance.clamp(-1.0, 1.0);
        crate::map_log!(5, "[DSP] Setting balance={}", self.balance);
        self.equalizer.set_balance(self.balance);
    }

    /// Enables or disables monophonic downmixing according to `mono`.
    #[inline]
    pub fn set_mono(&mut self, mono: bool) {
        self.mono = mono;
        crate::map_log!(5, "[DSP] Setting mono={}", mono);
        self.equalizer.set_mono(mono);
    }

    /// Sets local stage `volume` multiplier (clamped to non-negative values).
    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.volume = volume.max(0.0);
        crate::map_log!(5, "[DSP] Setting volume={}", self.volume);
    }

    /// Processes interleaved audio `samples` in-place through the DSP chain.
    #[inline]
    pub fn process(&mut self, samples: &mut [f32]) {
        if samples.is_empty() {
            return;
        }

        let is_dormant = self.reverb.is_dormant();
        let has_input = samples.iter().any(|&s| s.abs() > 1e-6);

        // If dormant (reverb delay buffers empty) and no incoming signal,
        // the entire DSP chain is a no-op: early return with zero CPU cost.
        if is_dormant && !has_input {
            return;
        }

        // 1. Equalizer (Preamp, ReplayGain, 10-band ISO biquad, Stereo Balance/Mono)
        if has_input {
            self.equalizer.process_interleaved(samples);
        }

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
