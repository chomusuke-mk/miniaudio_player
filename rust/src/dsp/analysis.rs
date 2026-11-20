//! Offline & Streaming Audio Analysis Pipeline (ITU-R BS.1770-4 LUFS, ReplayGain, and Waveform).
//!
//! Decomposes audio analysis into single-responsibility pipeline components:
//! - [`Bs1770LoudnessAnalyzer`]: K-weighting biquad cascade + 400 ms dual-gated LUFS integrator.
//! - [`AdaptiveWaveformAccumulator`]: Dynamic decimation peak collector with bounded memory.

use std::f64::consts::PI;

use crate::api::types::{RustAnalysisConfig, RustAudioAnalysisResult, RustChromaprintResult};
use crate::buffer::ResolvedCoreSource;
use crate::core::dual_source::{AudioSourceCore, DualSource, StreamingDeck};

use super::biquad::BiquadDf2t;
use super::chromaprint_fast::{CachedChromaprintSession, CHROMAPRINT_MAX_DURATION_SECS};

/// Computed ReplayGain loudness metrics.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ReplayGainData {
    /// Recommended gain adjustment in dB.
    pub gain_db: f32,
    /// Absolute true peak sample amplitude.
    pub peak: f32,
    /// Integrated loudness in LUFS according to ITU-R BS.1770-4.
    pub lufs: f32,
}

/// ITU-R BS.1770-4 K-Weighting Filter Pair and Dual-Gated Loudness Integrator.
pub struct Bs1770LoudnessAnalyzer {
    hs_l: BiquadDf2t,
    hp_l: BiquadDf2t,
    hs_r: BiquadDf2t,
    hp_r: BiquadDf2t,
    samples_per_100ms: usize,
    current_interval_samples: usize,
    current_interval_sq: [f64; 2],
    interval_energies: Vec<f32>,
}

impl Bs1770LoudnessAnalyzer {
    /// Constructs a new `Bs1770LoudnessAnalyzer` tuned for the specified sample rate.
    pub fn new(sample_rate: u32) -> Self {
        let (hs, hp) = Self::design_k_weighting_filters(sample_rate);
        let samples_per_100ms = (0.1 * (sample_rate as f64) + 0.5).max(1.0) as usize;
        Self {
            hs_l: hs,
            hp_l: hp,
            hs_r: hs,
            hp_r: hp,
            samples_per_100ms,
            current_interval_samples: 0,
            current_interval_sq: [0.0; 2],
            interval_energies: Vec::new(),
        }
    }

    fn design_k_weighting_filters(sample_rate: u32) -> (BiquadDf2t, BiquadDf2t) {
        if sample_rate == 0 {
            return (BiquadDf2t::identity(), BiquadDf2t::identity());
        }
        let fs = sample_rate as f64;

        // Stage 1: Acoustic head-model high-shelf pre-filter
        let f0_hs = 1681.974450955533f64;
        let g_hs = 3.999843853973347f64;
        let q_hs = 0.7071752369554196f64;
        let k_hs = (PI * f0_hs / fs).tan();
        let vh = 10.0f64.powf(g_hs / 20.0);
        let vb = vh.powf(0.4996667741545416);
        let a0_hs = 1.0 + k_hs / q_hs + k_hs * k_hs;

        let hs = BiquadDf2t::new(
            ((vh + vb * k_hs / q_hs + k_hs * k_hs) / a0_hs) as f32,
            (2.0 * (k_hs * k_hs - vh) / a0_hs) as f32,
            ((vh - vb * k_hs / q_hs + k_hs * k_hs) / a0_hs) as f32,
            (2.0 * (k_hs * k_hs - 1.0) / a0_hs) as f32,
            ((1.0 - k_hs / q_hs + k_hs * k_hs) / a0_hs) as f32,
        );

        // Stage 2: RLB high-pass weighting filter
        let f0_hp = 38.13547087602444f64;
        let q_hp = 0.5003270373238773f64;
        let k_hp = (PI * f0_hp / fs).tan();
        let ra0 = 1.0 + k_hp / q_hp + k_hp * k_hp;

        let hp = BiquadDf2t::new(
            1.0,
            -2.0,
            1.0,
            (2.0 * (k_hp * k_hp - 1.0) / ra0) as f32,
            ((1.0 - k_hp / q_hp + k_hp * k_hp) / ra0) as f32,
        );

        (hs, hp)
    }

    /// Feeds a stereo frame through K-weighting filters and accumulates 100 ms energy intervals.
    #[inline]
    pub fn push_stereo_frame(&mut self, s_l: f32, s_r: f32) {
        let y_l = self.hp_l.process(self.hs_l.process(s_l));
        let y_r = self.hp_r.process(self.hs_r.process(s_r));

        self.current_interval_sq[0] += (y_l as f64) * (y_l as f64);
        self.current_interval_sq[1] += (y_r as f64) * (y_r as f64);
        self.current_interval_samples += 1;

        if self.current_interval_samples >= self.samples_per_100ms {
            let energy = (self.current_interval_sq[0] + self.current_interval_sq[1])
                / (self.samples_per_100ms as f64);
            self.current_interval_sq = [0.0, 0.0];
            self.current_interval_samples = 0;
            self.interval_energies.push(energy as f32);
        }
    }

    #[inline]
    fn flush_denormals_100ms(&mut self) {
        const THRESHOLD: f32 = 1e-20;
        for f in [&mut self.hs_l, &mut self.hp_l, &mut self.hs_r, &mut self.hp_r] {
            if f.s1.abs() < THRESHOLD {
                f.s1 = 0.0;
            }
            if f.s2.abs() < THRESHOLD {
                f.s2 = 0.0;
            }
        }
    }

    #[inline]
    fn finish_interval(&mut self) {
        let energy = (self.current_interval_sq[0] + self.current_interval_sq[1])
            / (self.samples_per_100ms as f64);
        self.current_interval_sq = [0.0, 0.0];
        self.current_interval_samples = 0;
        self.interval_energies.push(energy as f32);
        self.flush_denormals_100ms();
    }

    /// Feeds a contiguous slice of interleaved PCM frames (`channels` per frame)
    /// into K-weighting filters and 100 ms energy accumulators.
    pub fn push_slice(&mut self, pcm: &[f32], channels: usize) {
        if channels == 0 || pcm.is_empty() {
            return;
        }
        let total_frames = pcm.len() / channels;
        if total_frames == 0 {
            return;
        }
        let expected_intervals = total_frames / self.samples_per_100ms.max(1);
        self.interval_energies.reserve(expected_intervals + 1);

        if channels == 1 {
            self.push_mono_slice(&pcm[..total_frames]);
        } else if channels == 2 {
            #[cfg(target_arch = "x86_64")]
            {
                // SAFETY: x86_64 always guarantees SSE2.
                unsafe {
                    self.push_stereo_slice_sse2(&pcm[..total_frames * 2]);
                }
            }
            #[cfg(not(target_arch = "x86_64"))]
            {
                self.push_stereo_slice_scalar(&pcm[..total_frames * 2]);
            }
        } else {
            self.push_multichannel_slice(pcm, channels);
        }
    }

    fn push_mono_slice(&mut self, mono: &[f32]) {
        let hs_b0 = self.hs_l.b0;
        let hs_b1 = self.hs_l.b1;
        let hs_b2 = self.hs_l.b2;
        let hs_a1 = self.hs_l.a1;
        let hs_a2 = self.hs_l.a2;
        let hp_b0 = self.hp_l.b0;
        let hp_b1 = self.hp_l.b1;
        let hp_b2 = self.hp_l.b2;
        let hp_a1 = self.hp_l.a1;
        let hp_a2 = self.hp_l.a2;

        let mut hs_s1 = self.hs_l.s1;
        let mut hs_s2 = self.hs_l.s2;
        let mut hp_s1 = self.hp_l.s1;
        let mut hp_s2 = self.hp_l.s2;

        let mut idx = 0;
        while idx < mono.len() {
            let rem = self.samples_per_100ms - self.current_interval_samples;
            let count = rem.min(mono.len() - idx);
            let mut sum_sq = 0.0f64;

            for &x in &mono[idx..idx + count] {
                let y_hs = hs_b0 * x + hs_s1;
                hs_s1 = hs_b1 * x - hs_a1 * y_hs + hs_s2;
                hs_s2 = hs_b2 * x - hs_a2 * y_hs;

                let y_hp = hp_b0 * y_hs + hp_s1;
                hp_s1 = hp_b1 * y_hs - hp_a1 * y_hp + hp_s2;
                hp_s2 = hp_b2 * y_hs - hp_a2 * y_hp;

                let yd = y_hp as f64;
                sum_sq += yd * yd;
            }

            self.current_interval_sq[0] += sum_sq;
            self.current_interval_sq[1] += sum_sq;
            self.current_interval_samples += count;
            idx += count;

            if self.current_interval_samples >= self.samples_per_100ms {
                self.hs_l.s1 = hs_s1;
                self.hs_l.s2 = hs_s2;
                self.hp_l.s1 = hp_s1;
                self.hp_l.s2 = hp_s2;
                self.hs_r.s1 = hs_s1;
                self.hs_r.s2 = hs_s2;
                self.hp_r.s1 = hp_s1;
                self.hp_r.s2 = hp_s2;
                self.finish_interval();
                hs_s1 = self.hs_l.s1;
                hs_s2 = self.hs_l.s2;
                hp_s1 = self.hp_l.s1;
                hp_s2 = self.hp_l.s2;
            }
        }

        self.hs_l.s1 = hs_s1;
        self.hs_l.s2 = hs_s2;
        self.hp_l.s1 = hp_s1;
        self.hp_l.s2 = hp_s2;
        self.hs_r.s1 = hs_s1;
        self.hs_r.s2 = hs_s2;
        self.hp_r.s1 = hp_s1;
        self.hp_r.s2 = hp_s2;
    }

    #[cfg(target_arch = "x86_64")]
    #[target_feature(enable = "sse2")]
    unsafe fn push_stereo_slice_sse2(&mut self, stereo: &[f32]) {
        use std::arch::x86_64::*;

        let hs_b0 = _mm_set1_ps(self.hs_l.b0);
        let hs_b1 = _mm_set1_ps(self.hs_l.b1);
        let hs_b2 = _mm_set1_ps(self.hs_l.b2);
        let hs_a1 = _mm_set1_ps(self.hs_l.a1);
        let hs_a2 = _mm_set1_ps(self.hs_l.a2);
        let hp_b0 = _mm_set1_ps(self.hp_l.b0);
        let hp_b1 = _mm_set1_ps(self.hp_l.b1);
        let hp_b2 = _mm_set1_ps(self.hp_l.b2);
        let hp_a1 = _mm_set1_ps(self.hp_l.a1);
        let hp_a2 = _mm_set1_ps(self.hp_l.a2);

        let mut hs_s1 = _mm_set_ps(0.0, 0.0, self.hs_r.s1, self.hs_l.s1);
        let mut hs_s2 = _mm_set_ps(0.0, 0.0, self.hs_r.s2, self.hs_l.s2);
        let mut hp_s1 = _mm_set_ps(0.0, 0.0, self.hp_r.s1, self.hp_l.s1);
        let mut hp_s2 = _mm_set_ps(0.0, 0.0, self.hp_r.s2, self.hp_l.s2);

        let total_frames = stereo.len() / 2;
        let mut frame_idx = 0;

        while frame_idx < total_frames {
            let rem = self.samples_per_100ms - self.current_interval_samples;
            let count = rem.min(total_frames - frame_idx);
            let mut sq_acc = _mm_setzero_pd();

            let chunk = &stereo[frame_idx * 2..(frame_idx + count) * 2];
            for frame in chunk.chunks_exact(2) {
                let x = _mm_set_ps(0.0, 0.0, frame[1], frame[0]);

                let y_hs = _mm_add_ps(_mm_mul_ps(hs_b0, x), hs_s1);
                hs_s1 = _mm_add_ps(_mm_sub_ps(_mm_mul_ps(hs_b1, x), _mm_mul_ps(hs_a1, y_hs)), hs_s2);
                hs_s2 = _mm_sub_ps(_mm_mul_ps(hs_b2, x), _mm_mul_ps(hs_a2, y_hs));

                let y_hp = _mm_add_ps(_mm_mul_ps(hp_b0, y_hs), hp_s1);
                hp_s1 = _mm_add_ps(_mm_sub_ps(_mm_mul_ps(hp_b1, y_hs), _mm_mul_ps(hp_a1, y_hp)), hp_s2);
                hp_s2 = _mm_sub_ps(_mm_mul_ps(hp_b2, y_hs), _mm_mul_ps(hp_a2, y_hp));

                let yd = _mm_cvtps_pd(y_hp);
                sq_acc = _mm_add_pd(sq_acc, _mm_mul_pd(yd, yd));
            }

            let mut lr = [0.0f64; 2];
            _mm_storeu_pd(lr.as_mut_ptr(), sq_acc);
            self.current_interval_sq[0] += lr[0];
            self.current_interval_sq[1] += lr[1];
            self.current_interval_samples += count;
            frame_idx += count;

            if self.current_interval_samples >= self.samples_per_100ms {
                let mut tmp = [0.0f32; 4];
                _mm_storeu_ps(tmp.as_mut_ptr(), hs_s1);
                self.hs_l.s1 = tmp[0];
                self.hs_r.s1 = tmp[1];
                _mm_storeu_ps(tmp.as_mut_ptr(), hs_s2);
                self.hs_l.s2 = tmp[0];
                self.hs_r.s2 = tmp[1];
                _mm_storeu_ps(tmp.as_mut_ptr(), hp_s1);
                self.hp_l.s1 = tmp[0];
                self.hp_r.s1 = tmp[1];
                _mm_storeu_ps(tmp.as_mut_ptr(), hp_s2);
                self.hp_l.s2 = tmp[0];
                self.hp_r.s2 = tmp[1];

                self.finish_interval();

                hs_s1 = _mm_set_ps(0.0, 0.0, self.hs_r.s1, self.hs_l.s1);
                hs_s2 = _mm_set_ps(0.0, 0.0, self.hs_r.s2, self.hs_l.s2);
                hp_s1 = _mm_set_ps(0.0, 0.0, self.hp_r.s1, self.hp_l.s1);
                hp_s2 = _mm_set_ps(0.0, 0.0, self.hp_r.s2, self.hp_l.s2);
            }
        }

        let mut tmp = [0.0f32; 4];
        _mm_storeu_ps(tmp.as_mut_ptr(), hs_s1);
        self.hs_l.s1 = tmp[0];
        self.hs_r.s1 = tmp[1];
        _mm_storeu_ps(tmp.as_mut_ptr(), hs_s2);
        self.hs_l.s2 = tmp[0];
        self.hs_r.s2 = tmp[1];
        _mm_storeu_ps(tmp.as_mut_ptr(), hp_s1);
        self.hp_l.s1 = tmp[0];
        self.hp_r.s1 = tmp[1];
        _mm_storeu_ps(tmp.as_mut_ptr(), hp_s2);
        self.hp_l.s2 = tmp[0];
        self.hp_r.s2 = tmp[1];
    }

    #[cfg(not(target_arch = "x86_64"))]
    fn push_stereo_slice_scalar(&mut self, stereo: &[f32]) {
        self.push_multichannel_slice(stereo, 2);
    }

    fn push_multichannel_slice(&mut self, pcm: &[f32], channels: usize) {
        let hs_b0 = self.hs_l.b0;
        let hs_b1 = self.hs_l.b1;
        let hs_b2 = self.hs_l.b2;
        let hs_a1 = self.hs_l.a1;
        let hs_a2 = self.hs_l.a2;
        let hp_b0 = self.hp_l.b0;
        let hp_b1 = self.hp_l.b1;
        let hp_b2 = self.hp_l.b2;
        let hp_a1 = self.hp_l.a1;
        let hp_a2 = self.hp_l.a2;

        let mut hs_s1_l = self.hs_l.s1;
        let mut hs_s2_l = self.hs_l.s2;
        let mut hp_s1_l = self.hp_l.s1;
        let mut hp_s2_l = self.hp_l.s2;
        let mut hs_s1_r = self.hs_r.s1;
        let mut hs_s2_r = self.hs_r.s2;
        let mut hp_s1_r = self.hp_r.s1;
        let mut hp_s2_r = self.hp_r.s2;

        let total_frames = pcm.len() / channels;
        let mut frame_idx = 0;

        while frame_idx < total_frames {
            let rem = self.samples_per_100ms - self.current_interval_samples;
            let count = rem.min(total_frames - frame_idx);
            let mut sum_sq_l = 0.0f64;
            let mut sum_sq_r = 0.0f64;

            let chunk = &pcm[frame_idx * channels..(frame_idx + count) * channels];
            for frame in chunk.chunks_exact(channels) {
                let x_l = frame[0];
                let x_r = frame[1];

                let y_hs_l = hs_b0 * x_l + hs_s1_l;
                hs_s1_l = hs_b1 * x_l - hs_a1 * y_hs_l + hs_s2_l;
                hs_s2_l = hs_b2 * x_l - hs_a2 * y_hs_l;
                let y_hp_l = hp_b0 * y_hs_l + hp_s1_l;
                hp_s1_l = hp_b1 * y_hs_l - hp_a1 * y_hp_l + hp_s2_l;
                hp_s2_l = hp_b2 * y_hs_l - hp_a2 * y_hp_l;

                let y_hs_r = hs_b0 * x_r + hs_s1_r;
                hs_s1_r = hs_b1 * x_r - hs_a1 * y_hs_r + hs_s2_r;
                hs_s2_r = hs_b2 * x_r - hs_a2 * y_hs_r;
                let y_hp_r = hp_b0 * y_hs_r + hp_s1_r;
                hp_s1_r = hp_b1 * y_hs_r - hp_a1 * y_hp_r + hp_s2_r;
                hp_s2_r = hp_b2 * y_hs_r - hp_a2 * y_hp_r;

                let yl = y_hp_l as f64;
                let yr = y_hp_r as f64;
                sum_sq_l += yl * yl;
                sum_sq_r += yr * yr;
            }

            self.current_interval_sq[0] += sum_sq_l;
            self.current_interval_sq[1] += sum_sq_r;
            self.current_interval_samples += count;
            frame_idx += count;

            if self.current_interval_samples >= self.samples_per_100ms {
                self.hs_l.s1 = hs_s1_l;
                self.hs_l.s2 = hs_s2_l;
                self.hp_l.s1 = hp_s1_l;
                self.hp_l.s2 = hp_s2_l;
                self.hs_r.s1 = hs_s1_r;
                self.hs_r.s2 = hs_s2_r;
                self.hp_r.s1 = hp_s1_r;
                self.hp_r.s2 = hp_s2_r;
                self.finish_interval();
                hs_s1_l = self.hs_l.s1;
                hs_s2_l = self.hs_l.s2;
                hp_s1_l = self.hp_l.s1;
                hp_s2_l = self.hp_l.s2;
                hs_s1_r = self.hs_r.s1;
                hs_s2_r = self.hs_r.s2;
                hp_s1_r = self.hp_r.s1;
                hp_s2_r = self.hp_r.s2;
            }
        }

        self.hs_l.s1 = hs_s1_l;
        self.hs_l.s2 = hs_s2_l;
        self.hp_l.s1 = hp_s1_l;
        self.hp_l.s2 = hp_s2_l;
        self.hs_r.s1 = hs_s1_r;
        self.hs_r.s2 = hs_s2_r;
        self.hp_r.s1 = hp_s1_r;
        self.hp_r.s2 = hp_s2_r;
    }

    /// Computes the gated integrated loudness (LUFS) and target gain difference in dB.
    pub fn finalize(mut self, target_lufs: f32, peak: f32) -> ReplayGainData {
        if self.current_interval_samples > 0 {
            let energy = (self.current_interval_sq[0] + self.current_interval_sq[1])
                / (self.current_interval_samples as f64);
            self.interval_energies.push(energy as f32);
        }

        let lufs = Self::compute_gated_lufs(&self.interval_energies);
        let eff_target = if target_lufs == 0.0 {
            -18.0
        } else {
            target_lufs
        };
        let gain_db = if lufs <= -70.0 {
            0.0
        } else {
            eff_target - lufs
        };

        ReplayGainData {
            gain_db,
            peak,
            lufs,
        }
    }

    fn compute_gated_lufs(interval_energies: &[f32]) -> f32 {
        const ABS_GATE_LUFS: f32 = -70.0;

        if interval_energies.len() < 4 {
            if interval_energies.is_empty() {
                return ABS_GATE_LUFS;
            }
            let mean_e: f64 = interval_energies.iter().map(|&e| e as f64).sum::<f64>()
                / (interval_energies.len() as f64);
            return if mean_e > 0.0 {
                (-0.691 + 10.0 * mean_e.log10()) as f32
            } else {
                ABS_GATE_LUFS
            };
        }

        let num_blocks = interval_energies.len() - 3;
        let mut block_energies = Vec::with_capacity(num_blocks);
        let mut block_loudness = Vec::with_capacity(num_blocks);
        let mut z_unmasked = 0.0f64;
        let mut count_unmasked = 0usize;

        for window in interval_energies.windows(4) {
            let e4 = ((window[0] + window[1] + window[2] + window[3]) as f64) * 0.25;
            block_energies.push(e4 as f32);
            let loud = if e4 > 0.0 {
                (-0.691 + 10.0 * e4.log10()) as f32
            } else {
                -100.0f32
            };
            block_loudness.push(loud);

            if loud > ABS_GATE_LUFS {
                z_unmasked += e4;
                count_unmasked += 1;
            }
        }

        if count_unmasked == 0 {
            return ABS_GATE_LUFS;
        }

        z_unmasked /= count_unmasked as f64;
        let rel_thresh = (-0.691 + 10.0 * z_unmasked.log10() - 10.0) as f32;

        let mut z_gated_sum = 0.0f64;
        let mut count_gated = 0usize;

        for (k, &loud) in block_loudness.iter().enumerate() {
            if loud > ABS_GATE_LUFS && loud > rel_thresh {
                z_gated_sum += block_energies[k] as f64;
                count_gated += 1;
            }
        }

        let final_energy = if count_gated > 0 {
            z_gated_sum / (count_gated as f64)
        } else {
            z_unmasked
        };
        (-0.691 + 10.0 * final_energy.log10()) as f32
    }
}

/// Adaptive Bounded Waveform Accumulator with 2:1 dynamic decimation.
/// Ensures energy/waveform accumulation memory remains strictly bounded (< 16 KB)
/// across any file duration from seconds to 10+ hours.
pub struct AdaptiveWaveformAccumulator {
    target_points: usize,
    buckets: Vec<f32>,
    current_block_sq: f64,
    current_block_frames: usize,
    frames_per_block: usize,
    has_samples: bool,
}

impl AdaptiveWaveformAccumulator {
    /// Maximum bucket threshold triggering dynamic 2:1 decimation.
    pub const MAX_BUCKETS: usize = 2048;

    /// Creates a new waveform accumulator targeting `target_points` output samples.
    pub fn new(target_points: usize) -> Self {
        Self {
            target_points: target_points.max(1),
            buckets: Vec::with_capacity(Self::MAX_BUCKETS),
            current_block_sq: 0.0,
            current_block_frames: 0,
            frames_per_block: 256,
            has_samples: false,
        }
    }

    /// Feeds an instantaneous stereo frame into the accumulator.
    #[inline]
    pub fn push_frame(&mut self, s_l: f32, s_r: f32) {
        self.has_samples = true;
        let power = (s_l as f64 * s_l as f64 + s_r as f64 * s_r as f64) * 0.5;
        self.current_block_sq += power;
        self.current_block_frames += 1;
        if self.current_block_frames >= self.frames_per_block {
            let rms = (self.current_block_sq / self.current_block_frames as f64).sqrt() as f32;
            self.buckets.push(rms);
            self.current_block_sq = 0.0;
            self.current_block_frames = 0;

            if self.buckets.len() >= Self::MAX_BUCKETS {
                self.decimate_buckets_in_place();
            }
        }
    }

    #[inline]
    fn decimate_buckets_in_place(&mut self) {
        let pairs = self.buckets.len() / 2;
        for i in 0..pairs {
            let a = self.buckets[i * 2];
            let b = self.buckets[i * 2 + 1];
            let avg_sq = (a * a + b * b) * 0.5;
            self.buckets[i] = avg_sq.sqrt();
        }
        self.buckets.truncate(pairs);
        self.frames_per_block *= 2;
    }

    /// Feeds an interleaved PCM chunk into the waveform accumulator in tight block loops
    /// with in-place 2:1 bucket decimation (zero heap allocations).
    pub fn push_slice(&mut self, pcm: &[f32], channels: usize) {
        if channels == 0 || pcm.is_empty() {
            return;
        }
        let total_frames = pcm.len() / channels;
        if total_frames == 0 {
            return;
        }
        self.has_samples = true;

        let mut frame_idx = 0;
        while frame_idx < total_frames {
            let rem = self.frames_per_block - self.current_block_frames;
            let count = rem.min(total_frames - frame_idx);

            let block_power_sum: f64 = if channels == 1 {
                let mut a0 = 0.0f64;
                let mut a1 = 0.0f64;
                let mut a2 = 0.0f64;
                let mut a3 = 0.0f64;
                let mut chunks = pcm[frame_idx..frame_idx + count].chunks_exact(4);
                for c in &mut chunks {
                    let s0 = c[0] as f64;
                    let s1 = c[1] as f64;
                    let s2 = c[2] as f64;
                    let s3 = c[3] as f64;
                    a0 += s0 * s0;
                    a1 += s1 * s1;
                    a2 += s2 * s2;
                    a3 += s3 * s3;
                }
                for &s in chunks.remainder() {
                    let sd = s as f64;
                    a0 += sd * sd;
                }
                (a0 + a1) + (a2 + a3)
            } else if channels == 2 {
                let mut a0 = 0.0f64;
                let mut a1 = 0.0f64;
                let mut a2 = 0.0f64;
                let mut a3 = 0.0f64;
                let mut chunks = pcm[frame_idx * 2..(frame_idx + count) * 2].chunks_exact(4);
                for c in &mut chunks {
                    let s0 = c[0] as f64;
                    let s1 = c[1] as f64;
                    let s2 = c[2] as f64;
                    let s3 = c[3] as f64;
                    a0 += s0 * s0;
                    a1 += s1 * s1;
                    a2 += s2 * s2;
                    a3 += s3 * s3;
                }
                for &s in chunks.remainder() {
                    let sd = s as f64;
                    a0 += sd * sd;
                }
                ((a0 + a1) + (a2 + a3)) * 0.5
            } else {
                let mut sum = 0.0f64;
                let sub = &pcm[frame_idx * channels..(frame_idx + count) * channels];
                for frame in sub.chunks_exact(channels) {
                    let l = frame[0] as f64;
                    let r = frame[1] as f64;
                    sum += (l * l + r * r) * 0.5;
                }
                sum
            };

            self.current_block_sq += block_power_sum;
            self.current_block_frames += count;
            frame_idx += count;

            if self.current_block_frames >= self.frames_per_block {
                let rms = (self.current_block_sq / self.current_block_frames as f64).sqrt() as f32;
                self.buckets.push(rms);
                self.current_block_sq = 0.0;
                self.current_block_frames = 0;

                if self.buckets.len() >= Self::MAX_BUCKETS {
                    self.decimate_buckets_in_place();
                }
            }
        }
    }

    /// Resamples accumulated energy into normalized `[0.0, 1.0]` points matching `target_points`.
    pub fn finalize(mut self) -> Vec<f32> {
        if !self.has_samples {
            return Vec::new();
        }
        if self.current_block_frames > 0 {
            let rms = (self.current_block_sq / self.current_block_frames as f64).sqrt() as f32;
            self.buckets.push(rms);
        }
        if self.buckets.is_empty() {
            return Vec::new();
        }

        let n = self.target_points;
        let mut points = Vec::with_capacity(n);
        let chunk_size = (self.buckets.len() as f64) / (n as f64);

        for i in 0..n {
            let start = (i as f64 * chunk_size) as usize;
            let end = (((i + 1) as f64 * chunk_size) as usize).min(self.buckets.len());
            let slice = &self.buckets[start..end.max(start + 1).min(self.buckets.len())];
            let mean_sq = slice.iter().map(|&x| (x * x) as f64).sum::<f64>() / (slice.len() as f64);
            points.push(mean_sq.sqrt() as f32);
        }

        let max_pt = points.iter().copied().fold(0.0f32, f32::max);
        if max_pt > 0.0 {
            for pt in &mut points {
                *pt = (*pt / max_pt).clamp(0.0, 1.0);
            }
        }

        points
    }
}

#[inline]
pub fn slice_peak(pcm: &[f32], channels: usize) -> f32 {
    if channels == 0 || pcm.is_empty() {
        return 0.0;
    }
    if channels <= 2 {
        let mut m0 = 0.0f32;
        let mut m1 = 0.0f32;
        let mut m2 = 0.0f32;
        let mut m3 = 0.0f32;
        let mut chunks = pcm.chunks_exact(4);
        for c in &mut chunks {
            m0 = m0.max(c[0].abs());
            m1 = m1.max(c[1].abs());
            m2 = m2.max(c[2].abs());
            m3 = m3.max(c[3].abs());
        }
        for &s in chunks.remainder() {
            m0 = m0.max(s.abs());
        }
        m0.max(m1).max(m2.max(m3))
    } else {
        let mut m = 0.0f32;
        for frame in pcm.chunks_exact(channels) {
            m = m.max(frame[0].abs()).max(frame[1].abs());
        }
        m
    }
}

#[cfg(not(target_arch = "wasm32"))]
mod worker_pool {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, OnceLock};
    use crossbeam_channel::{unbounded, Receiver, Sender};

    const TARGET_BATCH_FRAMES: usize = 16_384;
    const CHANNEL_BOUND: usize = 6;
    const RECYCLER_CAPACITY: usize = 12;

    type Job = Box<dyn FnOnce() + Send + 'static>;

    pub(super) const BATCH_FRAMES: usize = TARGET_BATCH_FRAMES;
    pub(super) const STAGE_QUEUE_BOUND: usize = CHANNEL_BOUND;
    pub(super) const RECYCLE_POOL_CAP: usize = RECYCLER_CAPACITY;

    pub(super) struct WorkerSlot {
        counter: Arc<AtomicUsize>,
        submitted: bool,
    }

    impl Drop for WorkerSlot {
        fn drop(&mut self) {
            if !self.submitted {
                self.counter.fetch_sub(1, Ordering::AcqRel);
            }
        }
    }

    struct ActiveGuard {
        counter: Arc<AtomicUsize>,
    }

    impl Drop for ActiveGuard {
        fn drop(&mut self) {
            self.counter.fetch_sub(1, Ordering::AcqRel);
        }
    }

    pub(super) struct AnalysisWorkerPool {
        job_tx: Sender<Job>,
        max_workers: usize,
        active_workers: Arc<AtomicUsize>,
    }

    impl AnalysisWorkerPool {
        pub(super) fn global() -> &'static Self {
            static INSTANCE: OnceLock<AnalysisWorkerPool> = OnceLock::new();
            INSTANCE.get_or_init(|| {
                let hw = std::thread::available_parallelism()
                    .map(|n| n.get())
                    .unwrap_or(4);
                let max_workers = hw.saturating_sub(1).clamp(2, 6);
                let (job_tx, job_rx) = unbounded::<Job>();
                let active_workers = Arc::new(AtomicUsize::new(0));

                for idx in 0..max_workers {
                    let rx: Receiver<Job> = job_rx.clone();
                    let _ = std::thread::Builder::new()
                        .name(format!("ma-analysis-w{}", idx))
                        .spawn(move || {
                            while let Ok(job) = rx.recv() {
                                job();
                            }
                        });
                }

                Self {
                    job_tx,
                    max_workers,
                    active_workers,
                }
            })
        }

        /// Non-blockingly reserves a worker slot; returns `None` when saturated so the
        /// caller falls back to inline execution without deadlocking under concurrent load.
        pub(super) fn try_reserve(&self) -> Option<WorkerSlot> {
            loop {
                let cur = self.active_workers.load(Ordering::Acquire);
                if cur >= self.max_workers {
                    return None;
                }
                if self
                    .active_workers
                    .compare_exchange_weak(cur, cur + 1, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
                {
                    return Some(WorkerSlot {
                        counter: Arc::clone(&self.active_workers),
                        submitted: false,
                    });
                }
            }
        }

        pub(super) fn submit<F>(&self, mut slot: WorkerSlot, f: F)
        where
            F: FnOnce() + Send + 'static,
        {
            slot.submitted = true;
            let counter = Arc::clone(&slot.counter);
            let job: Job = Box::new(move || {
                let _guard = ActiveGuard { counter };
                f();
            });
            if let Err(crossbeam_channel::SendError(rejected)) = self.job_tx.send(job) {
                drop(rejected);
            }
        }
    }

    pub(super) struct PooledChunk {
        pub(super) data: Vec<f32>,
        pub(super) len: usize,
        pub(super) recycler: Sender<Vec<f32>>,
    }

    impl PooledChunk {
        #[inline]
        pub(super) fn as_slice(&self) -> &[f32] {
            &self.data[..self.len]
        }
    }

    impl Drop for PooledChunk {
        fn drop(&mut self) {
            let mut buf = std::mem::take(&mut self.data);
            buf.clear();
            let _ = self.recycler.try_send(buf);
        }
    }
}

/// Performs comprehensive, memory-bounded ($O(1)$ RAM) acoustic, loudness, waveform,
/// and metadata analysis on an arbitrary [`AudioSourceCore`].
pub fn analyze_audio_source(
    source: AudioSourceCore,
    config: RustAnalysisConfig,
) -> Result<RustAudioAnalysisResult, String> {
    analyze_audio_source_with_resolved(source, None, config)
}

/// Performs comprehensive, memory-bounded ($O(1)$ RAM) acoustic, loudness, waveform,
/// and metadata analysis using an optional pre-resolved Dart source payload.
pub fn analyze_audio_source_with_resolved(
    source: AudioSourceCore,
    pre_resolved: Option<ResolvedCoreSource>,
    config: RustAnalysisConfig,
) -> Result<RustAudioAnalysisResult, String> {
    let mut deck = StreamingDeck::new_analysis_deck(44100, 2)
        .map_err(|e| format!("Failed to create analysis deck: {}", e))?;

    let res = DualSource::open_deck_with_pre_resolved(
        &mut deck,
        &source,
        pre_resolved,
        None,
        None,
        None,
    );
    if res != 0 {
        let detail = deck.take_last_open_error_message();
        return Err(detail.unwrap_or_else(|| format!("Failed to open audio source (code: {})", res)));
    }

    // Livestream fast-path: unbounded live broadcasts cannot and must not be analyzed for
    // whole-track acoustic metrics (ReplayGain, Waveform, Chromaprint).
    // Instead, only container format info and metadata (if requested) are extracted; duration is returned as null.
    if deck.is_live_stream() {
        let mut audio_info = deck.get_audio_info();
        audio_info.duration_ms = None;
        let metadata = if config.metadata {
            deck.get_parsed_metadata()
        } else {
            None
        };
        deck.stop();
        return Ok(RustAudioAnalysisResult {
            audio_info,
            has_replay_gain: false,
            integrated_lufs: 0.0,
            replay_gain_db: 0.0,
            replay_gain_peak: 0.0,
            has_waveform: false,
            spectral_centroid: 0.0,
            frequency_bands: Vec::new(),
            waveform_peaks: Vec::new(),
            has_metadata: metadata.is_some(),
            metadata,
            has_chromaprint: false,
            chromaprint: None,
        });
    }

    let mut audio_info = deck.get_audio_info();
    let sample_rate = audio_info.sample_rate;
    let channels = audio_info.channels.max(1);
    let mut duration_ms = audio_info.duration_ms.unwrap_or(0);

    // Fast path: if neither ReplayGain, Waveform, nor Chromaprint is requested, return early
    if !config.replay_gain && !config.waveform && !config.chromaprint {
        let metadata = if config.metadata {
            deck.get_parsed_metadata()
        } else {
            None
        };
        deck.stop();
        return Ok(RustAudioAnalysisResult {
            audio_info,
            has_replay_gain: false,
            integrated_lufs: 0.0,
            replay_gain_db: 0.0,
            replay_gain_peak: 0.0,
            has_waveform: false,
            spectral_centroid: 0.0,
            frequency_bands: Vec::new(),
            waveform_peaks: Vec::new(),
            has_metadata: metadata.is_some(),
            metadata,
            has_chromaprint: false,
            chromaprint: None,
        });
    }

    // Phase 2: Pipelined L3-Resident Acoustic DSP Pull Loop
    let ch_usize = channels as usize;
    let max_frames = config
        .max_duration_ms
        .map(|ms| (ms as f64 * sample_rate as f64 / 1000.0) as u64);

    #[cfg(not(target_arch = "wasm32"))]
    let (
        total_decoded_frames,
        has_replay_gain,
        replay_gain,
        has_waveform,
        waveform_peaks,
        has_chromaprint,
        chromaprint,
        metadata,
    ) = {
        use std::sync::Arc;
        use crossbeam_channel::{bounded, Receiver, Sender};
        use worker_pool::{
            AnalysisWorkerPool, PooledChunk, BATCH_FRAMES, RECYCLE_POOL_CAP, STAGE_QUEUE_BOUND,
        };

        let pool = AnalysisWorkerPool::global();

        // Dispatch metadata extraction onto a pool worker so header/tag/art parsing overlaps decode.
        let mut inline_meta_inputs = None;
        let meta_res_rx = if config.metadata {
            let inputs = deck.metadata_extract_inputs();
            if let Some(slot) = pool.try_reserve() {
                let (res_tx, res_rx) = bounded(1);
                pool.submit(slot, move || {
                    let parsed = crate::metadata::UniversalMetadataExtractor::extract(
                        &inputs.0,
                        &inputs.1,
                        inputs.2.as_ref(),
                        inputs.3,
                    );
                    let _ = res_tx.send(parsed);
                });
                Some(res_rx)
            } else {
                inline_meta_inputs = Some(inputs);
                None
            }
        } else {
            None
        };

        // Stage 1 Worker: ReplayGain 1.0 Scanner
        let mut inline_rgs: Option<crate::dsp::replaygain::ReplayGainScanner> = None;
        let (rg_tx, rg_res_rx): (
            Option<Sender<Arc<PooledChunk>>>,
            Option<Receiver<(f32, f32)>>,
        ) = if config.replay_gain {
            let scanner = crate::dsp::replaygain::ReplayGainScanner::new(sample_rate);
            if let Some(slot) = pool.try_reserve() {
                let (chunk_tx, chunk_rx) = bounded::<Arc<PooledChunk>>(STAGE_QUEUE_BOUND);
                let (res_tx, res_rx) = bounded(1);
                pool.submit(slot, move || {
                    let mut s = scanner;
                    while let Ok(chunk) = chunk_rx.recv() {
                        s.push_slice(chunk.as_slice(), ch_usize);
                    }
                    let _ = res_tx.send(s.finalize());
                });
                (Some(chunk_tx), Some(res_rx))
            } else {
                inline_rgs = Some(scanner);
                (None, None)
            }
        } else {
            (None, None)
        };

        // Stage 2 Worker: BS.1770 LUFS + Waveform + Peak
        let need_stage2 = config.replay_gain || config.waveform;
        let mut inline_bs: Option<Bs1770LoudnessAnalyzer> = None;
        let mut inline_wf: Option<AdaptiveWaveformAccumulator> = None;
        let mut inline_peak = 0.0f32;
        let target_lufs = config.target_lufs;
        let wf_points = config.waveform_points as usize;

        let (bs_tx, bs_res_rx): (
            Option<Sender<Arc<PooledChunk>>>,
            Option<Receiver<(Option<ReplayGainData>, Option<Vec<f32>>, f32)>>,
        ) = if need_stage2 {
            let bs = config.replay_gain.then(|| Bs1770LoudnessAnalyzer::new(sample_rate));
            let wf = config.waveform.then(|| AdaptiveWaveformAccumulator::new(wf_points));
            if let Some(slot) = pool.try_reserve() {
                let (chunk_tx, chunk_rx) = bounded::<Arc<PooledChunk>>(STAGE_QUEUE_BOUND);
                let (res_tx, res_rx) = bounded(1);
                pool.submit(slot, move || {
                    let mut bs = bs;
                    let mut wf = wf;
                    let mut local_peak = 0.0f32;
                    while let Ok(chunk) = chunk_rx.recv() {
                        let pcm = chunk.as_slice();
                        local_peak = local_peak.max(slice_peak(pcm, ch_usize));
                        if let Some(ref mut w) = wf {
                            w.push_slice(pcm, ch_usize);
                        }
                        if let Some(ref mut b) = bs {
                            b.push_slice(pcm, ch_usize);
                        }
                    }
                    let bs_out = bs.map(|b| b.finalize(target_lufs, local_peak));
                    let wf_out = wf.map(|w| w.finalize());
                    let _ = res_tx.send((bs_out, wf_out, local_peak));
                });
                (Some(chunk_tx), Some(res_rx))
            } else {
                inline_bs = bs;
                inline_wf = wf;
                (None, None)
            }
        } else {
            (None, None)
        };

        // Stage 3 Worker: Cached Chromaprint (120 s AcoustID standard cap)
        let chroma_max_frames = (sample_rate as u64).saturating_mul(CHROMAPRINT_MAX_DURATION_SECS);
        let mut inline_chroma: Option<CachedChromaprintSession> = None;
        let (mut chroma_tx, chroma_res_rx): (
            Option<Sender<Arc<PooledChunk>>>,
            Option<Receiver<Option<RustChromaprintResult>>>,
        ) = if config.chromaprint && sample_rate > 0 {
            if let Some(cp) = CachedChromaprintSession::new(sample_rate, ch_usize) {
                if let Some(slot) = pool.try_reserve() {
                    let (chunk_tx, chunk_rx) = bounded::<Arc<PooledChunk>>(STAGE_QUEUE_BOUND);
                    let (res_tx, res_rx) = bounded(1);
                    pool.submit(slot, move || {
                        let mut sess = cp;
                        while let Ok(chunk) = chunk_rx.recv() {
                            sess.push_slice(chunk.as_slice(), ch_usize);
                            if sess.is_capped() {
                                break;
                            }
                        }
                        drop(chunk_rx);
                        let _ = res_tx.send(sess.finish());
                    });
                    (Some(chunk_tx), Some(res_rx))
                } else {
                    inline_chroma = Some(cp);
                    (None, None)
                }
            } else {
                (None, None)
            }
        } else {
            (None, None)
        };

        // Bounded buffer recycler keeps batch buffers inside 9 MiB L3 cache across workers.
        let (recycle_tx, recycle_rx) = bounded::<Vec<f32>>(RECYCLE_POOL_CAP);
        for _ in 0..RECYCLE_POOL_CAP {
            let _ = recycle_tx.try_send(Vec::with_capacity(BATCH_FRAMES * ch_usize));
        }

        let mut engine = deck.take_analysis_engine();
        let mut total_decoded_frames = 0u64;
        let mut cur_buf = recycle_rx
            .try_recv()
            .unwrap_or_else(|_| Vec::with_capacity(BATCH_FRAMES * ch_usize));
        cur_buf.clear();

        let mut dispatch_batch = |buf: Vec<f32>, frames_before: u64| -> Vec<f32> {
            let len = buf.len();
            if len == 0 {
                return buf;
            }
            let chunk = Arc::new(PooledChunk {
                data: buf,
                len,
                recycler: recycle_tx.clone(),
            });

            if let Some(ref tx) = rg_tx {
                let _ = tx.send(Arc::clone(&chunk));
            } else if let Some(ref mut rgs) = inline_rgs {
                rgs.push_slice(chunk.as_slice(), ch_usize);
            }

            if let Some(ref tx) = bs_tx {
                let _ = tx.send(Arc::clone(&chunk));
            } else if need_stage2 {
                let pcm = chunk.as_slice();
                inline_peak = inline_peak.max(slice_peak(pcm, ch_usize));
                if let Some(ref mut w) = inline_wf {
                    w.push_slice(pcm, ch_usize);
                }
                if let Some(ref mut b) = inline_bs {
                    b.push_slice(pcm, ch_usize);
                }
            }

            if let Some(ref tx) = chroma_tx {
                if frames_before < chroma_max_frames {
                    let _ = tx.send(Arc::clone(&chunk));
                    let chunk_frames = (len / ch_usize) as u64;
                    if frames_before + chunk_frames >= chroma_max_frames {
                        chroma_tx = None;
                    }
                } else {
                    chroma_tx = None;
                }
            } else if let Some(ref mut cp) = inline_chroma {
                cp.push_slice(chunk.as_slice(), ch_usize);
            }

            drop(chunk);
            let mut next = recycle_rx
                .try_recv()
                .unwrap_or_else(|_| Vec::with_capacity(BATCH_FRAMES * ch_usize));
            next.clear();
            next
        };

        let mut batch_start_frames = 0u64;
        if let Some(ref mut eng) = engine {
            while let Ok(true) = eng.decode_next_frame_append(&mut cur_buf) {
                let cur_frames = (cur_buf.len() / ch_usize) as u64;
                total_decoded_frames = batch_start_frames + cur_frames;
                let hit_limit = max_frames.is_some_and(|limit| total_decoded_frames >= limit);
                if cur_frames as usize >= BATCH_FRAMES || hit_limit {
                    cur_buf = dispatch_batch(cur_buf, batch_start_frames);
                    batch_start_frames = total_decoded_frames;
                }
                if hit_limit {
                    break;
                }
            }
        } else {
            while let Ok(true) = deck.decode_next_analysis_frame(&mut cur_buf) {
                let pkt_frames = (cur_buf.len() / ch_usize) as u64;
                total_decoded_frames += pkt_frames;
                cur_buf = dispatch_batch(cur_buf, batch_start_frames);
                batch_start_frames = total_decoded_frames;
                if max_frames.is_some_and(|limit| total_decoded_frames >= limit) {
                    break;
                }
            }
        }
        if !cur_buf.is_empty() {
            let _ = dispatch_batch(cur_buf, batch_start_frames);
        }

        // Release decode engine & all chunk Senders before awaiting worker results (deadlock-free).
        drop(engine);
        drop(rg_tx);
        drop(bs_tx);
        drop(chroma_tx);

        let (bs_res, wf_out, stage2_peak) = match bs_res_rx {
            Some(rx) => rx.recv().unwrap_or((None, None, 0.0)),
            None => (
                inline_bs.map(|b| b.finalize(target_lufs, inline_peak)),
                inline_wf.map(|w| w.finalize()),
                inline_peak,
            ),
        };

        let rgs_out = match rg_res_rx {
            Some(rx) => rx.recv().ok(),
            None => inline_rgs.map(|s| s.finalize()),
        };

        let (has_replay_gain, replay_gain) = match bs_res {
            Some(bs_data) => {
                let (scanner_gain, scanner_peak) = rgs_out.unwrap_or((bs_data.gain_db, stage2_peak));
                (
                    true,
                    ReplayGainData {
                        gain_db: scanner_gain,
                        peak: scanner_peak.max(stage2_peak),
                        lufs: bs_data.lufs,
                    },
                )
            }
            None => (false, ReplayGainData::default()),
        };

        let (has_waveform, waveform_peaks) = match wf_out {
            Some(pts) => (true, pts),
            None => (false, Vec::new()),
        };

        let chroma_out = match chroma_res_rx {
            Some(rx) => rx.recv().ok().flatten(),
            None => inline_chroma.and_then(|cp| cp.finish()),
        };
        let has_chromaprint = chroma_out.is_some();

        let metadata = if let Some(rx) = meta_res_rx {
            rx.recv().ok()
        } else if let Some(inputs) = inline_meta_inputs {
            Some(crate::metadata::UniversalMetadataExtractor::extract(
                &inputs.0,
                &inputs.1,
                inputs.2.as_ref(),
                inputs.3,
            ))
        } else {
            None
        };

        (
            total_decoded_frames,
            has_replay_gain,
            replay_gain,
            has_waveform,
            waveform_peaks,
            has_chromaprint,
            chroma_out,
            metadata,
        )
    };

    #[cfg(target_arch = "wasm32")]
    let (
        total_decoded_frames,
        has_replay_gain,
        replay_gain,
        has_waveform,
        waveform_peaks,
        has_chromaprint,
        chromaprint,
        metadata,
    ) = {
        let mut rg_analyzer = config
            .replay_gain
            .then(|| Bs1770LoudnessAnalyzer::new(sample_rate));
        let mut rg_scanner = config
            .replay_gain
            .then(|| crate::dsp::replaygain::ReplayGainScanner::new(sample_rate));
        let mut wf_accumulator = config
            .waveform
            .then(|| AdaptiveWaveformAccumulator::new(config.waveform_points as usize));
        let mut chromaprinter = if config.chromaprint && sample_rate > 0 {
            CachedChromaprintSession::new(sample_rate, ch_usize)
        } else {
            None
        };
        let mut peak = 0.0f32;
        let mut total_decoded_frames = 0u64;
        let mut frame_buf = Vec::with_capacity(4096 * ch_usize);

        while let Ok(true) = deck.decode_next_analysis_frame(&mut frame_buf) {
            let chunk_frames = (frame_buf.len() / ch_usize) as u64;
            total_decoded_frames += chunk_frames;
            peak = peak.max(slice_peak(&frame_buf, ch_usize));
            if let Some(ref mut wf) = wf_accumulator {
                wf.push_slice(&frame_buf, ch_usize);
            }
            if let Some(ref mut rg) = rg_analyzer {
                rg.push_slice(&frame_buf, ch_usize);
            }
            if let Some(ref mut rgs) = rg_scanner {
                rgs.push_slice(&frame_buf, ch_usize);
            }
            if let Some(ref mut cp) = chromaprinter {
                cp.push_slice(&frame_buf, ch_usize);
            }
            if let Some(limit) = max_frames {
                if total_decoded_frames >= limit {
                    break;
                }
            }
        }

        let (has_replay_gain, replay_gain) = match rg_analyzer {
            Some(rg) => {
                let bs_data = rg.finalize(config.target_lufs, peak);
                let (scanner_gain, scanner_peak) = match rg_scanner {
                    Some(s) => s.finalize(),
                    None => (bs_data.gain_db, peak),
                };
                (
                    true,
                    ReplayGainData {
                        gain_db: scanner_gain,
                        peak: scanner_peak.max(peak),
                        lufs: bs_data.lufs,
                    },
                )
            }
            None => (false, ReplayGainData::default()),
        };

        let (has_waveform, waveform_peaks) = match wf_accumulator {
            Some(wf) => (true, wf.finalize()),
            None => (false, Vec::new()),
        };

        let chroma_out = chromaprinter.and_then(|cp| cp.finish());
        let has_chromaprint = chroma_out.is_some();
        let metadata = if config.metadata {
            deck.get_parsed_metadata()
        } else {
            None
        };

        (
            total_decoded_frames,
            has_replay_gain,
            replay_gain,
            has_waveform,
            waveform_peaks,
            has_chromaprint,
            chroma_out,
            metadata,
        )
    };

    if sample_rate > 0 && total_decoded_frames > 0 && config.max_duration_ms.is_none() {
        let decoded_dur = (total_decoded_frames as f64 * 1000.0 / sample_rate as f64).round() as i64;
        if duration_ms <= 0 || (decoded_dur - duration_ms).abs() > 100 {
            duration_ms = decoded_dur;
            audio_info.duration_ms = if duration_ms > 0 { Some(duration_ms) } else { None };
            if audio_info.bitrate == 0 && duration_ms > 0 {
                if let Some(fs) = audio_info.file_size {
                    if fs > 0 {
                        audio_info.bitrate = ((fs * 8000) / (duration_ms as u64)) as u32;
                    }
                }
            }
        }
    }

    deck.stop();

    Ok(RustAudioAnalysisResult {
        audio_info,
        has_replay_gain,
        integrated_lufs: if has_replay_gain { replay_gain.lufs } else { 0.0 },
        replay_gain_db: if has_replay_gain { replay_gain.gain_db } else { 0.0 },
        replay_gain_peak: if has_replay_gain { replay_gain.peak } else { 0.0 },
        has_waveform,
        spectral_centroid: 0.0,
        frequency_bands: Vec::new(),
        waveform_peaks,
        has_metadata: metadata.is_some(),
        metadata,
        has_chromaprint,
        chromaprint,
    })
}
