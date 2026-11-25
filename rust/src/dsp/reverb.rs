//! Studio-grade Algorithmic Stereo Reverberation (Freeverb Model) in pure Rust.

/// Number of parallel feedback comb filters per channel (8).
pub const NUM_COMBS: usize = 8;
/// Number of series all-pass diffusion filters per channel (4).
pub const NUM_ALLPASS: usize = 4;
/// Sample spread offset between left and right channels for stereo decorrelation.
pub const STEREO_SPREAD: usize = 23;

/// Default Freeverb comb delay lengths in samples at 44.1 kHz for the left channel.
const COMB_TUNINGS_L: [usize; NUM_COMBS] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
/// Default Freeverb allpass delay lengths in samples at 44.1 kHz for the left channel.
const ALLPASS_TUNINGS_L: [usize; NUM_ALLPASS] = [556, 441, 341, 225];

/// Scaling factor mapping normalized `room_size` to comb feedback gain.
const SCALE_ROOM: f32 = 0.28;
/// Base comb feedback offset added to scaled `room_size`.
const OFFSET_ROOM: f32 = 0.70;
/// Scaling factor mapping normalized `damping` to one-pole lowpass damping.
const SCALE_DAMP: f32 = 0.40;
/// Wet gain scaling factor compensating for Freeverb's fixed input attenuation.
const SCALE_WET: f32 = 2.50;
/// Input attenuation factor preventing comb filter bank saturation.
const SCALE_INPUT: f32 = 0.015;
/// Fixed feedback coefficient used by all Freeverb series all-pass diffusers.
const ALLPASS_FEEDBACK: f32 = 0.50;

/// Parameters configuring algorithmic studio reverberation.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReverbConfig {
    /// Non-zero if reverberation processing is enabled.
    pub enabled: i32,
    /// Normalized room decay size (0.0 to 1.0).
    pub room_size: f32,
    /// High-frequency absorption and damping factor (0.0 to 1.0).
    pub damping: f32,
    /// Stereo reflection width spread (0.0 to 1.0).
    pub width: f32,
    /// Wet reverberant signal mix gain (0.0 to 2.0).
    pub wet: f32,
    /// Dry direct signal mix gain (0.0 to 2.0).
    pub dry: f32,
}

impl Default for ReverbConfig {
    /// Returns a disabled [`ReverbConfig`] with balanced room size, damping, width, wet, and dry defaults.
    fn default() -> Self {
        Self {
            enabled: 0,
            room_size: 0.5,
            damping: 0.5,
            width: 1.0,
            wet: 0.33,
            dry: 1.0,
        }
    }
}

/// Lowpass-damped feedback comb filter used in Freeverb's parallel early/late decay bank.
#[derive(Clone)]
struct CombFilter {
    /// Circular delay line storage.
    buffer: Vec<f32>,
    /// Delay line length in samples.
    buf_size: usize,
    /// Current read/write cursor index inside `buffer`.
    buf_idx: usize,
    /// One-pole lowpass filter state register for high-frequency damping.
    filter_store: f32,
}

impl CombFilter {
    /// Creates a zero-initialized `CombFilter` with delay line length `size` samples.
    fn new(size: usize) -> Self {
        Self {
            buffer: vec![0.0; size],
            buf_size: size,
            buf_idx: 0,
            filter_store: 0.0,
        }
    }

    /// Resizes the comb delay line to `new_size` samples and clears internal state.
    fn resize(&mut self, new_size: usize) {
        self.buf_size = new_size.max(1);
        self.buffer.resize(self.buf_size, 0.0);
        self.clear();
    }

    /// Zeroes the delay buffer, cursor index, and lowpass damping state.
    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.buf_idx = 0;
        self.filter_store = 0.0;
    }

    /// Processes one `input` sample through the damped comb filter with `damp` and `feedback`.
    #[inline(always)]
    fn process(&mut self, input: f32, damp: f32, feedback: f32) -> f32 {
        let out = self.buffer[self.buf_idx];
        let mut store = out * (1.0 - damp) + self.filter_store * damp;
        if store.abs() < 1e-20 {
            store = 0.0;
        }
        self.filter_store = store;

        let mut in_val = input + store * feedback;
        if in_val.abs() < 1e-20 {
            in_val = 0.0;
        }
        self.buffer[self.buf_idx] = in_val;

        self.buf_idx += 1;
        if self.buf_idx >= self.buf_size {
            self.buf_idx = 0;
        }

        out
    }
}

/// Series all-pass diffuser filter used after Freeverb's parallel comb bank.
#[derive(Clone)]
struct AllpassFilter {
    /// Circular delay line storage.
    buffer: Vec<f32>,
    /// Delay line length in samples.
    buf_size: usize,
    /// Current read/write cursor index inside `buffer`.
    buf_idx: usize,
}

impl AllpassFilter {
    /// Creates a zero-initialized `AllpassFilter` with delay line length `size` samples.
    fn new(size: usize) -> Self {
        Self {
            buffer: vec![0.0; size],
            buf_size: size,
            buf_idx: 0,
        }
    }

    /// Resizes the all-pass delay line to `new_size` samples and clears internal state.
    fn resize(&mut self, new_size: usize) {
        self.buf_size = new_size.max(1);
        self.buffer.resize(self.buf_size, 0.0);
        self.clear();
    }

    /// Zeroes the delay buffer and resets the cursor index.
    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.buf_idx = 0;
    }

    /// Processes one `input` sample through the all-pass diffuser.
    #[inline(always)]
    fn process(&mut self, input: f32) -> f32 {
        let mut buf_out = self.buffer[self.buf_idx];
        if buf_out.abs() < 1e-20 {
            buf_out = 0.0;
        }

        let out = -input + buf_out;
        let mut in_val = input + buf_out * ALLPASS_FEEDBACK;
        if in_val.abs() < 1e-20 {
            in_val = 0.0;
        }
        self.buffer[self.buf_idx] = in_val;

        self.buf_idx += 1;
        if self.buf_idx >= self.buf_size {
            self.buf_idx = 0;
        }

        out
    }
}

/// Algorithmic studio reverberation unit based on the classic Freeverb physical model.
pub struct Freeverb {
    /// Active audio sample rate in Hz.
    sample_rate: u32,
    /// Current reverberation configuration parameters.
    config: ReverbConfig,

    /// Left-channel parallel comb filter bank.
    combs_l: Vec<CombFilter>,
    /// Right-channel parallel comb filter bank.
    combs_r: Vec<CombFilter>,
    /// Left-channel series all-pass diffuser bank.
    allpass_l: Vec<AllpassFilter>,
    /// Right-channel series all-pass diffuser bank.
    allpass_r: Vec<AllpassFilter>,

    /// Derived comb feedback gain from `room_size`.
    feedback: f32,
    /// Derived lowpass damping coefficient from `damping`.
    damp: f32,
    /// Target direct-channel wet mix gain.
    target_wet1: f32,
    /// Target cross-channel wet mix gain controlling stereo width.
    target_wet2: f32,
    /// Target dry direct signal gain.
    target_dry: f32,

    /// Current block-ramped dry signal gain.
    current_dry: f32,
    /// Current block-ramped direct wet gain.
    current_wet1: f32,
    /// Current block-ramped cross-channel wet gain.
    current_wet2: f32,

    /// Whether all delay lines are silent and processing can be bypassed.
    is_dormant: bool,
    /// Count of consecutive silent blocks used to transition into dormancy.
    silent_blocks: usize,
}

impl Freeverb {
    /// Constructs a new `Freeverb` instance calibrated for `sample_rate`.
    pub fn new(sample_rate: u32) -> Self {
        let sr = if sample_rate == 0 { 44100 } else { sample_rate };
        let rate_scale = sr as f64 / 44100.0;

        let mut combs_l = Vec::with_capacity(NUM_COMBS);
        let mut combs_r = Vec::with_capacity(NUM_COMBS);
        for &tuning in &COMB_TUNINGS_L {
            let len_l = ((tuning as f64 * rate_scale + 0.5) as usize).clamp(1, 8192);
            let len_r =
                (((tuning + STEREO_SPREAD) as f64 * rate_scale + 0.5) as usize).clamp(1, 8192);
            combs_l.push(CombFilter::new(len_l));
            combs_r.push(CombFilter::new(len_r));
        }

        let mut allpass_l = Vec::with_capacity(NUM_ALLPASS);
        let mut allpass_r = Vec::with_capacity(NUM_ALLPASS);
        for &tuning in &ALLPASS_TUNINGS_L {
            let len_l = ((tuning as f64 * rate_scale + 0.5) as usize).clamp(1, 4096);
            let len_r =
                (((tuning + STEREO_SPREAD) as f64 * rate_scale + 0.5) as usize).clamp(1, 4096);
            allpass_l.push(AllpassFilter::new(len_l));
            allpass_r.push(AllpassFilter::new(len_r));
        }

        let mut rev = Self {
            sample_rate: sr,
            config: ReverbConfig::default(),
            combs_l,
            combs_r,
            allpass_l,
            allpass_r,
            feedback: 0.5,
            damp: 0.5,
            target_wet1: 0.0,
            target_wet2: 0.0,
            target_dry: 1.0,
            current_dry: 1.0,
            current_wet1: 0.0,
            current_wet2: 0.0,
            is_dormant: true,
            silent_blocks: 0,
        };

        rev.update_params();
        rev
    }

    /// Re-scales comb and all-pass delay line lengths to match `sample_rate`.
    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        let sr = if sample_rate == 0 { 44100 } else { sample_rate };
        if self.sample_rate == sr {
            return;
        }
        self.sample_rate = sr;
        let rate_scale = sr as f64 / 44100.0;

        for (i, &tuning) in COMB_TUNINGS_L.iter().enumerate() {
            let len_l = ((tuning as f64 * rate_scale + 0.5) as usize).clamp(1, 8192);
            let len_r =
                (((tuning + STEREO_SPREAD) as f64 * rate_scale + 0.5) as usize).clamp(1, 8192);
            self.combs_l[i].resize(len_l);
            self.combs_r[i].resize(len_r);
        }

        for (i, &tuning) in ALLPASS_TUNINGS_L.iter().enumerate() {
            let len_l = ((tuning as f64 * rate_scale + 0.5) as usize).clamp(1, 4096);
            let len_r =
                (((tuning + STEREO_SPREAD) as f64 * rate_scale + 0.5) as usize).clamp(1, 4096);
            self.allpass_l[i].resize(len_l);
            self.allpass_r[i].resize(len_r);
        }
    }

    /// Updates reverb room size, damping, width, wet, and dry parameters from `config`.
    pub fn set_config(&mut self, config: ReverbConfig) {
        self.config = config;
        self.update_params();
    }

    /// Returns whether the reverberation network is dormant (all delay lines silent).
    #[inline]
    pub fn is_dormant(&self) -> bool {
        self.is_dormant
    }

    /// Clears all comb and all-pass delay line buffers to silence.
    pub fn clear(&mut self) {
        for c in &mut self.combs_l {
            c.clear();
        }
        for c in &mut self.combs_r {
            c.clear();
        }
        for a in &mut self.allpass_l {
            a.clear();
        }
        for a in &mut self.allpass_r {
            a.clear();
        }
        self.is_dormant = true;
        self.silent_blocks = 0;
    }

    /// Processes interleaved PCM `samples` across `channels` in-place through the reverberation network.
    pub fn process_frames(&mut self, samples: &mut [f32], channels: usize) {
        if samples.is_empty() || channels == 0 {
            return;
        }

        let is_active = self.config.enabled != 0;
        if !is_active
            && self.current_wet1 < 1e-5
            && self.current_wet2 < 1e-5
            && (self.current_dry - 1.0).abs() < 1e-5
        {
            self.is_dormant = true;
            return;
        }

        // Fast-path: Check if the incoming block has any audio signal
        let has_input = samples.iter().any(|&s| s.abs() > 1e-6);

        // If the reverb network is dormant (empty delay lines) and no audio is entering,
        // bypass processing completely with zero CPU cost.
        if self.is_dormant && !has_input {
            return;
        }

        if has_input {
            self.is_dormant = false;
            self.silent_blocks = 0;
        }

        let frame_count = samples.len() / channels;
        let tgt_dry = if is_active { self.target_dry } else { 1.0 };
        let tgt_wet1 = if is_active { self.target_wet1 } else { 0.0 };
        let tgt_wet2 = if is_active { self.target_wet2 } else { 0.0 };

        let dry_step = (tgt_dry - self.current_dry) / frame_count as f32;
        let wet1_step = (tgt_wet1 - self.current_wet1) / frame_count as f32;
        let wet2_step = (tgt_wet2 - self.current_wet2) / frame_count as f32;

        let damp = self.damp;
        let feedback = self.feedback;
        let mut max_tail_energy: f32 = 0.0;

        if channels >= 2 {
            for f in 0..frame_count {
                let idx = f * channels;
                let in_l = samples[idx];
                let in_r = samples[idx + 1];
                let input = (in_l + in_r) * SCALE_INPUT;

                let mut out_comb_l = 0.0;
                let mut out_comb_r = 0.0;

                for i in 0..NUM_COMBS {
                    out_comb_l += self.combs_l[i].process(input, damp, feedback);
                    out_comb_r += self.combs_r[i].process(input, damp, feedback);
                }

                for i in 0..NUM_ALLPASS {
                    out_comb_l = self.allpass_l[i].process(out_comb_l);
                    out_comb_r = self.allpass_r[i].process(out_comb_r);
                }

                let wet_out_l = out_comb_l * self.current_wet1 + out_comb_r * self.current_wet2;
                let wet_out_r = out_comb_r * self.current_wet1 + out_comb_l * self.current_wet2;

                max_tail_energy = max_tail_energy.max(wet_out_l.abs()).max(wet_out_r.abs());

                self.current_dry += dry_step;
                self.current_wet1 += wet1_step;
                self.current_wet2 += wet2_step;

                samples[idx] = in_l * self.current_dry + wet_out_l;
                samples[idx + 1] = in_r * self.current_dry + wet_out_r;
            }
        } else {
            // Mono
            for f in 0..frame_count {
                let in_val = samples[f];
                let input = in_val * SCALE_INPUT;

                let mut out_comb = 0.0;
                for i in 0..NUM_COMBS {
                    out_comb += self.combs_l[i].process(input, damp, feedback);
                }
                for i in 0..NUM_ALLPASS {
                    out_comb = self.allpass_l[i].process(out_comb);
                }

                let wet_out = out_comb * self.current_wet1;
                max_tail_energy = max_tail_energy.max(wet_out.abs());

                self.current_dry += dry_step;
                self.current_wet1 += wet1_step;

                samples[f] = in_val * self.current_dry + wet_out;
            }
        }

        // If no audio was input and the ringdown tail has dropped below the digital
        // silence floor (< 1e-5 / -100 dBFS) across 4 consecutive periods, transition
        // to dormant state and clear delay lines to prevent subnormal denormals.
        if !has_input && max_tail_energy < 1e-5 {
            self.silent_blocks += 1;
            if self.silent_blocks >= 4 {
                self.clear();
            }
        } else if has_input {
            self.silent_blocks = 0;
        }
    }

    /// Recomputes clamped Freeverb feedback, damping, and wet/dry mix targets from `config`.
    fn update_params(&mut self) {
        let room_size = self.config.room_size.clamp(0.0, 1.0);
        let damping = self.config.damping.clamp(0.0, 1.0);
        let width = self.config.width.clamp(0.0, 1.0);
        let wet = self.config.wet.clamp(0.0, 2.0);
        let dry = self.config.dry.clamp(0.0, 2.0);

        self.feedback = room_size * SCALE_ROOM + OFFSET_ROOM;
        self.damp = damping * SCALE_DAMP;
        self.target_wet1 = wet * (width * 0.5 + 0.5) * SCALE_WET;
        self.target_wet2 = wet * ((1.0 - width) * 0.5) * SCALE_WET;
        self.target_dry = dry;
    }
}
