//! Silence Detection and Skipping FSM with 5ms smooth crossfade and saved time tracking.

/// Dynamic silence skipping and trimming operational modes.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SilenceMode {
    /// Silence skipping disabled.
    Disabled = 0,
    /// Trim silence from lead-in and lead-out only.
    TrimEdges = 1,
    /// Continuously skip silence gaps throughout the stream.
    Continuous = 2,
    /// Trim edges and skip continuous internal silence.
    All = 3,
}

impl Default for SilenceMode {
    fn default() -> Self {
        SilenceMode::Disabled
    }
}

/// Configuration settings for dynamic silence detection and skipping.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SilenceConfig {
    /// Whether dynamic silence skipping is enabled.
    pub enabled: bool,
    /// Operational mode policy (`SilenceMode`).
    pub mode: SilenceMode,
    /// Silence detection threshold in decibels full scale (e.g. -45.0 dBFS).
    pub threshold_db: f32,
    /// Minimum continuous duration in milliseconds before silence skipping triggers.
    pub min_silence_duration_ms: u32,
    /// Margin padding in milliseconds preserved before and after non-silent audio.
    pub padding_ms: u32,
}

impl Default for SilenceConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: SilenceMode::Disabled,
            threshold_db: -45.0,
            min_silence_duration_ms: 300,
            padding_ms: 50,
        }
    }
}

/// Operational state of the silence detection finite-state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SilenceState {
    /// Audible audio is playing normally.
    Voice,
    /// Trailing potential silence is being buffered in holding queue.
    Holding,
    /// Silence confirmed; audio frames are skipped and discarded.
    Skipping,
}

/// Dynamic silence detector and skipper with 5ms smooth crossfade and cumulative saved time tracking.
pub struct SilenceDetector {
    channels: usize,
    sample_rate: u32,
    config: SilenceConfig,
    state: SilenceState,

    threshold_amp_linear: f32,
    threshold_amp_exit: f32,

    min_silence_frames: usize,
    padding_frames: usize,

    lead_in_active: bool,
    silence_saved_frames: u64,

    hold_buffer: Vec<f32>,
    hold_frames_count: usize,
    hold_frames_read_pos: usize,

    last_sample: [f32; 8],
    crossfade_length: usize,
    crossfade_remaining: usize,
}

impl SilenceDetector {
    /// Constructs a `SilenceDetector` calibrated for the specified channel count and sample rate.
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let ch = channels.max(1);
        let mut det = Self {
            channels: ch,
            sample_rate,
            config: SilenceConfig::default(),
            state: SilenceState::Voice,
            threshold_amp_linear: 0.0,
            threshold_amp_exit: 0.0,
            min_silence_frames: 0,
            padding_frames: 0,
            lead_in_active: false,
            silence_saved_frames: 0,
            hold_buffer: Vec::new(),
            hold_frames_count: 0,
            hold_frames_read_pos: 0,
            last_sample: [0.0; 8],
            crossfade_length: 0,
            crossfade_remaining: 0,
        };
        det.update_params();
        det.reset(true);
        det
    }

    /// Reconfigures silence detection thresholds, mode, and padding durations.
    pub fn set_config(&mut self, config: SilenceConfig) {
        let prev_mode = self.config.mode;
        let prev_enabled = self.config.enabled;
        self.config = config;
        self.update_params();
        if !config.enabled {
            self.reset(true);
        } else if (!prev_enabled || prev_mode != config.mode)
            && matches!(config.mode, SilenceMode::TrimEdges | SilenceMode::All)
            && self.silence_saved_frames == 0
        {
            self.lead_in_active = true;
        }
    }

    /// Returns the number of channels processed.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Returns the active audio sample rate in Hz.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Updates the channel count and resets internal buffers.
    pub fn set_channels(&mut self, channels: usize) {
        let ch = channels.max(1);
        if self.channels != ch {
            self.channels = ch;
            self.update_params();
            self.reset(true);
        }
    }

    /// Updates the sample rate and recalculates time-based frame thresholds.
    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if self.sample_rate != sample_rate && sample_rate > 0 {
            self.sample_rate = sample_rate;
            self.update_params();
        }
    }

    /// Resets state machine registers, optionally resetting cumulative saved counters if `is_start` is true.
    pub fn reset(&mut self, is_start: bool) {
        self.state = SilenceState::Voice;
        self.hold_frames_count = 0;
        self.hold_frames_read_pos = 0;
        self.crossfade_remaining = 0;
        self.last_sample = [0.0; 8];

        if is_start {
            self.silence_saved_frames = 0;
            self.lead_in_active =
                matches!(self.config.mode, SilenceMode::TrimEdges | SilenceMode::All);
        } else {
            self.lead_in_active = false;
        }
    }

    /// Returns cumulative silence skipped in milliseconds.
    pub fn saved_ms(&self) -> u64 {
        if self.sample_rate == 0 {
            0
        } else {
            (self.silence_saved_frames * 1000) / self.sample_rate as u64
        }
    }

    /// Returns cumulative silence skipped in audio frames.
    pub fn saved_frames(&self) -> u64 {
        self.silence_saved_frames
    }

    /// Returns the current state of the silence detector FSM.
    pub fn state(&self) -> SilenceState {
        self.state
    }

    /// Returns whether the detector is currently buffering potential silence in its hold queue.
    pub fn is_holding(&self) -> bool {
        self.state == SilenceState::Holding
    }

    /// Returns whether the detector is actively skipping audio frames.
    pub fn is_skipping(&self) -> bool {
        self.state == SilenceState::Skipping
    }

    /// Process input PCM frames from `input` and writes non-silent audio frames to `output`.
    /// Returns `(frames_written_to_output, input_frames_consumed)`.
    pub fn process_frames(&mut self, input: &[f32], output: &mut [f32]) -> (usize, usize) {
        let input_frames = input.len() / self.channels;
        let output_frames_cap = output.len() / self.channels;

        if !self.config.enabled || self.config.mode == SilenceMode::Disabled || input.is_empty() {
            let to_copy = input_frames.min(output_frames_cap);
            let samples = to_copy * self.channels;
            output[..samples].copy_from_slice(&input[..samples]);
            return (to_copy, to_copy);
        }

        let mut in_pos = 0;
        let mut out_pos = 0;
        let body_skip_enabled =
            matches!(self.config.mode, SilenceMode::Continuous | SilenceMode::All);

        while (in_pos < input_frames || self.hold_frames_read_pos < self.hold_frames_count)
            && out_pos < output_frames_cap
        {
            if self.drain_held_frames(output, &mut out_pos, output_frames_cap) {
                continue;
            }
            if in_pos >= input_frames {
                break;
            }

            let frame_start = in_pos * self.channels;
            let frame = &input[frame_start..frame_start + self.channels];
            in_pos += 1;

            let peak = Self::frame_peak(frame);
            let is_silent_enter = peak <= self.threshold_amp_linear;
            let is_silent_exit = peak <= self.threshold_amp_exit;

            if self.lead_in_active {
                if is_silent_enter {
                    self.silence_saved_frames += 1;
                    continue;
                }
                self.lead_in_active = false;
                self.crossfade_remaining = self.crossfade_length;
                self.last_sample = [0.0; 8];
            }

            if !body_skip_enabled {
                self.crossfade_remaining = 0;
                self.emit_voice_frame(frame, output, &mut out_pos);
                continue;
            }

            match self.state {
                SilenceState::Voice => {
                    if !is_silent_enter {
                        self.emit_voice_frame(frame, output, &mut out_pos);
                    } else {
                        self.state = SilenceState::Holding;
                        self.hold_frames_count = 0;
                        self.hold_frames_read_pos = 0;
                        self.append_hold_frame(frame);
                    }
                }
                SilenceState::Holding => {
                    if is_silent_enter {
                        self.append_hold_frame(frame);
                        if self.hold_frames_count >= self.min_silence_frames {
                            let keep = self.padding_frames.min(self.hold_frames_count);
                            self.silence_saved_frames += (self.hold_frames_count - keep) as u64;
                            self.hold_frames_count = keep;
                            self.hold_frames_read_pos = 0;
                            self.state = SilenceState::Skipping;
                        }
                    } else {
                        self.state = SilenceState::Voice;
                        self.hold_frames_read_pos = 0;
                        in_pos -= 1;
                    }
                }
                SilenceState::Skipping => {
                    if is_silent_exit {
                        self.silence_saved_frames += 1;
                    } else {
                        self.state = SilenceState::Voice;
                        self.crossfade_remaining = self.crossfade_length;
                        self.emit_voice_frame(frame, output, &mut out_pos);
                    }
                }
            }
        }

        (out_pos, in_pos)
    }

    #[inline]
    fn frame_peak(frame: &[f32]) -> f32 {
        let mut peak: f32 = 0.0;
        for &s in frame {
            let abs_s = s.abs();
            if abs_s > peak {
                peak = abs_s;
            }
        }
        peak
    }

    fn drain_held_frames(
        &mut self,
        output: &mut [f32],
        out_pos: &mut usize,
        output_frames_cap: usize,
    ) -> bool {
        if self.state == SilenceState::Holding
            || self.hold_frames_read_pos >= self.hold_frames_count
        {
            return false;
        }

        let avail = self.hold_frames_count - self.hold_frames_read_pos;
        let to_copy = avail.min(output_frames_cap - *out_pos);

        let src_start = self.hold_frames_read_pos * self.channels;
        let src_end = (self.hold_frames_read_pos + to_copy) * self.channels;
        let dst_start = *out_pos * self.channels;
        let dst_end = (*out_pos + to_copy) * self.channels;

        output[dst_start..dst_end].copy_from_slice(&self.hold_buffer[src_start..src_end]);

        if to_copy > 0 {
            let last_idx = (self.hold_frames_read_pos + to_copy - 1) * self.channels;
            for c in 0..self.channels.min(8) {
                self.last_sample[c] = self.hold_buffer[last_idx + c];
            }
        }

        self.hold_frames_read_pos += to_copy;
        *out_pos += to_copy;

        if self.hold_frames_read_pos >= self.hold_frames_count {
            self.hold_frames_read_pos = 0;
            self.hold_frames_count = 0;
        }
        true
    }

    #[inline]
    fn emit_voice_frame(&mut self, frame: &[f32], output: &mut [f32], out_pos: &mut usize) {
        let dst_start = *out_pos * self.channels;
        if self.crossfade_remaining > 0 && self.crossfade_length > 0 {
            let alpha = 1.0 - (self.crossfade_remaining as f32 / self.crossfade_length as f32);
            for c in 0..self.channels {
                let last = if c < 8 { self.last_sample[c] } else { 0.0 };
                output[dst_start + c] = (1.0 - alpha) * last + alpha * frame[c];
            }
            self.crossfade_remaining -= 1;
        } else {
            output[dst_start..dst_start + self.channels].copy_from_slice(frame);
        }
        for c in 0..self.channels.min(8) {
            self.last_sample[c] = frame[c];
        }
        *out_pos += 1;
    }

    fn append_hold_frame(&mut self, frame: &[f32]) {
        let capacity_frames = self.hold_buffer.len() / self.channels;
        if self.hold_frames_count < capacity_frames {
            let start = self.hold_frames_count * self.channels;
            self.hold_buffer[start..start + self.channels].copy_from_slice(frame);
            self.hold_frames_count += 1;
        }
    }

    fn update_params(&mut self) {
        self.threshold_amp_linear = 10.0f32.powf(self.config.threshold_db / 20.0);
        self.threshold_amp_exit = 10.0f32.powf((self.config.threshold_db + 2.0) / 20.0);

        if self.sample_rate > 0 {
            self.min_silence_frames = ((self.config.min_silence_duration_ms as u64
                * self.sample_rate as u64)
                / 1000) as usize;
            self.padding_frames =
                ((self.config.padding_ms as u64 * self.sample_rate as u64) / 1000) as usize;
            let cf = ((5 * self.sample_rate as u64) / 1000) as usize;
            self.crossfade_length = cf.max(1);

            let required_frames = self.min_silence_frames + self.padding_frames + 2048;
            self.hold_buffer
                .resize(required_frames * self.channels, 0.0);
        }
    }
}
