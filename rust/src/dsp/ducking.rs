//! Real-time Auto-Ducking / Sidechain dynamics processor.
//!
//! Monitored voice / microphone audio dynamically attenuates background music and SFX buses.
//! Features:
//! - Sub-millisecond RMS level measurement.
//! - Configurable attack, hold, and release envelopes to prevent audio pumping.
//! - 100% Lock-Free and Zero-Allocation in the real-time audio thread.

#[derive(Debug, Clone)]
pub struct AutoDucker {
    pub enabled: bool,
    pub ducking_db: f32,
    pub threshold_db: f32,
    pub attack_time_ms: f32,
    pub hold_time_ms: f32,
    pub release_time_ms: f32,
    pub sample_rate: u32,

    current_gain: f32,
    target_gain: f32,
    hold_samples_remaining: usize,
    last_rms_db: f32,
}

impl Default for AutoDucker {
    fn default() -> Self {
        Self::new(44100)
    }
}

impl AutoDucker {
    pub fn new(sample_rate: u32) -> Self {
        let sr = sample_rate.max(8000);
        Self {
            enabled: false,
            ducking_db: -14.0,
            threshold_db: -30.0,
            attack_time_ms: 30.0,
            hold_time_ms: 250.0,
            release_time_ms: 400.0,
            sample_rate: sr,
            current_gain: 1.0,
            target_gain: 1.0,
            hold_samples_remaining: 0,
            last_rms_db: -100.0,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        self.sample_rate = sample_rate.max(8000);
    }

    pub fn set_params(
        &mut self,
        enabled: bool,
        ducking_db: f32,
        threshold_db: f32,
        attack_ms: f32,
        hold_ms: f32,
        release_ms: f32,
    ) {
        self.enabled = enabled;
        self.ducking_db = ducking_db.clamp(-60.0, 0.0);
        self.threshold_db = threshold_db.clamp(-80.0, 0.0);
        self.attack_time_ms = attack_ms.clamp(1.0, 1000.0);
        self.hold_time_ms = hold_ms.clamp(0.0, 5000.0);
        self.release_time_ms = release_ms.clamp(10.0, 5000.0);
        if !enabled {
            self.target_gain = 1.0;
        }
    }

    #[inline]
    pub fn is_ducking(&self) -> bool {
        self.enabled && self.current_gain < 0.99
    }

    #[inline]
    pub fn current_gain(&self) -> f32 {
        self.current_gain
    }

    #[inline]
    pub fn last_rms_db(&self) -> f32 {
        self.last_rms_db
    }

    /// Evaluates voice signal RMS and applies smooth sidechain attenuation onto the music buffer.
    pub fn process_sidechain(
        &mut self,
        voice_input: &[f32],
        music_output: &mut [f32],
        channels: usize,
    ) {
        if !self.enabled || music_output.is_empty() || channels == 0 {
            return;
        }

        let frame_count = music_output.len() / channels;

        // 1. Measure voice signal RMS (or assume quiet if voice_input is empty)
        let rms = if !voice_input.is_empty() {
            let sum_sq: f32 = voice_input.iter().map(|&s| s * s).sum();
            (sum_sq / voice_input.len() as f32).sqrt()
        } else {
            0.0
        };

        let rms_db = if rms > 1e-5 {
            20.0 * (rms.log10())
        } else {
            -100.0
        };
        self.last_rms_db = rms_db;

        let duck_gain = 10.0f32.powf(self.ducking_db / 20.0);

        // 2. Evaluate threshold and hold timer
        if rms_db >= self.threshold_db {
            self.target_gain = duck_gain;
            self.hold_samples_remaining =
                ((self.hold_time_ms * 0.001) * self.sample_rate as f32) as usize;
        } else if self.hold_samples_remaining > 0 {
            self.hold_samples_remaining = self.hold_samples_remaining.saturating_sub(frame_count);
            self.target_gain = duck_gain;
        } else {
            self.target_gain = 1.0;
        }

        // 3. Compute smoothing coefficients
        let sr = self.sample_rate as f32;
        let is_attacking = self.target_gain < self.current_gain;
        let time_ms = if is_attacking {
            self.attack_time_ms
        } else {
            self.release_time_ms
        };
        let tau_samples = (time_ms * 0.001 * sr).max(1.0);
        let alpha = 1.0 - (-1.0 / tau_samples).exp();

        // 4. Apply sample-by-sample smoothed gain to music output
        for k in 0..frame_count {
            self.current_gain += alpha * (self.target_gain - self.current_gain);
            let g = self.current_gain;
            for c in 0..channels {
                music_output[k * channels + c] *= g;
            }
        }
    }
}
