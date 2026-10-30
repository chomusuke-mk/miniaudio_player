//! Silence Detection and Skipping FSM with 5ms smooth crossfade and saved time tracking.

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SilenceMode {
    Disabled = 0,
    TrimEdges = 1,
    Continuous = 2,
    All = 3,
}

impl Default for SilenceMode {
    fn default() -> Self {
        SilenceMode::Disabled
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SilenceConfig {
    pub mode: SilenceMode,
    pub threshold_db: f32,
    pub min_silence_duration_ms: u32,
    pub padding_ms: u32,
}

impl Default for SilenceConfig {
    fn default() -> Self {
        Self {
            mode: SilenceMode::Disabled,
            threshold_db: -45.0,
            min_silence_duration_ms: 300,
            padding_ms: 50,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SilenceState {
    Voice,
    Holding,
    Skipping,
}

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

    pub fn set_config(&mut self, config: SilenceConfig) {
        let prev_mode = self.config.mode;
        self.config = config;
        self.update_params();
        if prev_mode != config.mode && matches!(config.mode, SilenceMode::TrimEdges | SilenceMode::All) {
            if self.silence_saved_frames == 0 {
                self.lead_in_active = true;
            }
        }
    }

    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn set_channels(&mut self, channels: usize) {
        let ch = channels.max(1);
        if self.channels != ch {
            self.channels = ch;
            self.update_params();
            self.reset(true);
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        if self.sample_rate != sample_rate && sample_rate > 0 {
            self.sample_rate = sample_rate;
            self.update_params();
        }
    }

    pub fn reset(&mut self, is_start: bool) {
        self.state = SilenceState::Voice;
        self.hold_frames_count = 0;
        self.hold_frames_read_pos = 0;
        self.crossfade_remaining = 0;
        self.last_sample = [0.0; 8];

        if is_start {
            self.silence_saved_frames = 0;
            if matches!(self.config.mode, SilenceMode::TrimEdges | SilenceMode::All) {
                self.lead_in_active = true;
            } else {
                self.lead_in_active = false;
            }
        } else {
            self.lead_in_active = false;
        }
    }

    pub fn saved_ms(&self) -> u64 {
        if self.sample_rate == 0 {
            0
        } else {
            (self.silence_saved_frames * 1000) / self.sample_rate as u64
        }
    }

    pub fn saved_frames(&self) -> u64 {
        self.silence_saved_frames
    }

    pub fn state(&self) -> SilenceState {
        self.state
    }

    pub fn is_holding(&self) -> bool {
        self.state == SilenceState::Holding
    }

    pub fn is_skipping(&self) -> bool {
        self.state == SilenceState::Skipping
    }

    /// Process input PCM frames from `input` and writes non-silent audio frames to `output`.
    /// Returns `(frames_written_to_output, input_frames_consumed)`.
    pub fn process_frames(
        &mut self,
        input: &[f32],
        output: &mut [f32],
    ) -> (usize, usize) {
        if self.config.mode == SilenceMode::Disabled || input.is_empty() {
            let frames_in = input.len() / self.channels;
            let frames_out_cap = output.len() / self.channels;
            let to_copy = frames_in.min(frames_out_cap);
            let samples = to_copy * self.channels;
            output[..samples].copy_from_slice(&input[..samples]);
            return (to_copy, to_copy);
        }

        let input_frames = input.len() / self.channels;
        let output_frames_cap = output.len() / self.channels;

        let mut in_pos = 0;
        let mut out_pos = 0;

        while (in_pos < input_frames || self.hold_frames_read_pos < self.hold_frames_count)
            && out_pos < output_frames_cap
        {
            // 1. Drain held frames if not in HOLDING state
            if self.state != SilenceState::Holding && self.hold_frames_read_pos < self.hold_frames_count {
                let avail = self.hold_frames_count - self.hold_frames_read_pos;
                let to_copy = avail.min(output_frames_cap - out_pos);

                let src_start = self.hold_frames_read_pos * self.channels;
                let src_end = (self.hold_frames_read_pos + to_copy) * self.channels;
                let dst_start = out_pos * self.channels;
                let dst_end = (out_pos + to_copy) * self.channels;

                output[dst_start..dst_end].copy_from_slice(&self.hold_buffer[src_start..src_end]);

                if to_copy > 0 {
                    let last_idx = (self.hold_frames_read_pos + to_copy - 1) * self.channels;
                    for c in 0..self.channels.min(8) {
                        self.last_sample[c] = self.hold_buffer[last_idx + c];
                    }
                }

                self.hold_frames_read_pos += to_copy;
                out_pos += to_copy;

                if self.hold_frames_read_pos >= self.hold_frames_count {
                    self.hold_frames_read_pos = 0;
                    self.hold_frames_count = 0;
                }
                continue;
            }

            if in_pos >= input_frames {
                break;
            }

            let frame_start = in_pos * self.channels;
            let frame = &input[frame_start..frame_start + self.channels];
            in_pos += 1;

            let mut peak: f32 = 0.0;
            for &s in frame {
                let abs_s = s.abs();
                if abs_s > peak {
                    peak = abs_s;
                }
            }

            let is_silent_enter = peak <= self.threshold_amp_linear;
            let is_silent_exit = peak <= self.threshold_amp_exit;

            // Lead-in silence trim
            if self.lead_in_active {
                if is_silent_enter {
                    self.silence_saved_frames += 1;
                    continue;
                } else {
                    self.lead_in_active = false;
                    self.crossfade_remaining = self.crossfade_length;
                    self.last_sample = [0.0; 8];
                }
            }

            let body_skip_enabled = matches!(
                self.config.mode,
                SilenceMode::Continuous | SilenceMode::All
            );

            if !body_skip_enabled {
                let dst_start = out_pos * self.channels;
                for c in 0..self.channels {
                    output[dst_start + c] = frame[c];
                    if c < 8 {
                        self.last_sample[c] = frame[c];
                    }
                }
                out_pos += 1;
                continue;
            }

            match self.state {
                SilenceState::Voice => {
                    if !is_silent_enter {
                        let dst_start = out_pos * self.channels;
                        if self.crossfade_remaining > 0 && self.crossfade_length > 0 {
                            let alpha = 1.0
                                - (self.crossfade_remaining as f32 / self.crossfade_length as f32);
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
                        out_pos += 1;
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
                        // Voice resumed before min_silence_frames
                        self.state = SilenceState::Voice;
                        self.hold_frames_read_pos = 0;
                        // Rewind current frame so it gets processed after held frames drain
                        in_pos -= 1;
                    }
                }
                SilenceState::Skipping => {
                    if is_silent_exit {
                        self.silence_saved_frames += 1;
                    } else {
                        // Voice resumed
                        self.state = SilenceState::Voice;
                        self.crossfade_remaining = self.crossfade_length;

                        let dst_start = out_pos * self.channels;
                        if self.crossfade_remaining > 0 && self.crossfade_length > 0 {
                            let alpha = 1.0
                                - (self.crossfade_remaining as f32 / self.crossfade_length as f32);
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
                        out_pos += 1;
                    }
                }
            }
        }

        (out_pos, in_pos)
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
            self.min_silence_frames =
                ((self.config.min_silence_duration_ms as u64 * self.sample_rate as u64) / 1000)
                    as usize;
            self.padding_frames =
                ((self.config.padding_ms as u64 * self.sample_rate as u64) / 1000) as usize;
            let cf = ((5 * self.sample_rate as u64) / 1000) as usize;
            self.crossfade_length = cf.max(1);

            let required_frames = self.min_silence_frames + self.padding_frames + 2048;
            self.hold_buffer.resize(required_frames * self.channels, 0.0);
        }
    }
}
