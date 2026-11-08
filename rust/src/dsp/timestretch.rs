//! High-Fidelity Time-Stretching & Pitch-Shifting powered by timestretch (v0.16).
//!
//! Employs a hybrid Varispeed + Two-Band SOLA Keylock Stage to preserve transients,
//! low-frequency bass punch, and dynamic range > 140 dB.

use timestretch::{render, Backend, Parameters, PitchRatio, RatePolicy, SessionConfig, TempoRate};

/// High-fidelity time-stretching processor based on the `timestretch` crate.
pub struct TimeStretchProcessor {
    sample_rate: u32,
    channels: usize,
    speed: f32,
    pitch: f32,
}

impl TimeStretchProcessor {
    /// Creates a new time stretch processor.
    pub fn new(sample_rate: u32, channels: usize) -> Self {
        Self {
            sample_rate: sample_rate.max(1),
            channels: channels.clamp(1, 2),
            speed: 1.0,
            pitch: 1.0,
        }
    }

    /// Returns the configured sample rate in Hz.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Returns the configured channel count (1 or 2).
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Returns the current playback speed multiplier.
    pub fn speed(&self) -> f32 {
        self.speed
    }

    /// Returns the current pitch scaling multiplier.
    pub fn pitch(&self) -> f32 {
        self.pitch
    }

    /// Sets playback speed multiplier (> 0.0).
    pub fn set_speed(&mut self, speed: f32) {
        if speed > 0.0 && speed.is_finite() {
            self.speed = speed;
        }
    }

    /// Sets pitch multiplier (> 0.0).
    pub fn set_pitch(&mut self, pitch: f32) {
        if pitch > 0.0 && pitch.is_finite() {
            self.pitch = pitch;
        }
    }

    /// Process a slice of interleaved PCM audio frames with the current speed and pitch.
    pub fn process_slice(&self, input: &[f32]) -> Result<Vec<f32>, String> {
        if input.is_empty() {
            return Ok(Vec::new());
        }

        // Fast passthrough when pitch and speed are unity
        if (self.speed - 1.0).abs() < 0.001 && (self.pitch - 1.0).abs() < 0.001 {
            return Ok(input.to_vec());
        }

        timestretch_audio(
            input,
            self.sample_rate,
            self.channels,
            self.speed,
            self.pitch,
        )
    }
}

/// Convenience function to stretch or pitch-shift interleaved audio samples.
pub fn timestretch_audio(
    input: &[f32],
    sample_rate: u32,
    channels: usize,
    speed: f32,
    pitch: f32,
) -> Result<Vec<f32>, String> {
    if input.is_empty() {
        return Ok(Vec::new());
    }

    let ch = channels.clamp(1, 2);
    let sr = sample_rate.clamp(32000, 192000);
    let tempo = TempoRate::new(speed as f64)
        .map_err(|e| format!("Invalid tempo rate {}: {:?}", speed, e))?;
    let pitch_ratio = PitchRatio::new(pitch as f64)
        .map_err(|e| format!("Invalid pitch ratio {}: {:?}", pitch, e))?;

    let config = SessionConfig {
        source_sample_rate: sr,
        output_sample_rate: sr,
        channels: ch,
        backend: Backend::Auto,
        rate_policy: RatePolicy::AllowConversion,
        parameters: Parameters {
            tempo,
            pitch: pitch_ratio,
            constraint: Default::default(),
        },
        ..Default::default()
    };

    let rendered =
        render(input, config).map_err(|e| format!("timestretch render failed: {:?}", e))?;

    Ok(rendered.samples)
}
