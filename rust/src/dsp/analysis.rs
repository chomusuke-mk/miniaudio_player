//! Offline & Streaming Audio Analysis Pipeline (ITU-R BS.1770-4 LUFS, ReplayGain, and Waveform).
//!
//! Decomposes audio analysis into single-responsibility pipeline components:
//! - [`Bs1770LoudnessAnalyzer`]: K-weighting biquad cascade + 400 ms dual-gated LUFS integrator.
//! - [`WaveformAccumulator`]: Frame peak collector and deterministic downsampler.

use std::f64::consts::PI;
use std::fs::File;
use std::io::Cursor;
use symphonia::core::io::MediaSource;

use crate::decoder::sniffer::FormatSniffer;
use crate::decoder::SymphoniaEngine;

use super::biquad::BiquadDf2t;

pub const MAP_ANALYSIS_FLAG_REPLAY_GAIN: u32 = 1 << 0;
pub const MAP_ANALYSIS_FLAG_WAVEFORM: u32 = 1 << 1;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AudioAnalysisConfig {
    pub flags: u32,
    pub target_lufs: f32,
    pub waveform_points: u32,
}

impl Default for AudioAnalysisConfig {
    fn default() -> Self {
        Self {
            flags: MAP_ANALYSIS_FLAG_REPLAY_GAIN | MAP_ANALYSIS_FLAG_WAVEFORM,
            target_lufs: -18.0,
            waveform_points: 100,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ReplayGainData {
    pub gain_db: f32,
    pub peak: f32,
    pub lufs: f32,
}

#[repr(C)]
#[derive(Debug, Clone, PartialEq, Default)]
pub struct WaveformData {
    pub point_count: u32,
    pub points: Vec<f32>,
}

#[repr(C)]
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioAnalysisResult {
    pub status: i32,
    pub duration_ms: i64,
    pub sample_rate: u32,
    pub channels: u32,
    pub bitrate: u32,
    pub peak: f32,

    pub has_replay_gain: i32,
    pub replay_gain: ReplayGainData,

    pub has_waveform: i32,
    pub waveform: WaveformData,
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

/// Deterministic Waveform Peak Accumulator and Downsampler.
#[derive(Default)]
pub struct WaveformAccumulator {
    peaks: Vec<f32>,
}

impl WaveformAccumulator {
    #[inline]
    pub fn push_peak(&mut self, frame_peak: f32) {
        self.peaks.push(frame_peak);
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.peaks.is_empty()
    }

    pub fn finalize(self, target_points: u32) -> WaveformData {
        if self.peaks.is_empty() {
            return WaveformData::default();
        }
        let n_points = target_points.max(1) as usize;
        let mut points = Vec::with_capacity(n_points);
        let chunk_size = (self.peaks.len() as f64) / (n_points as f64);

        for i in 0..n_points {
            let start = (i as f64 * chunk_size) as usize;
            let end = (((i + 1) as f64 * chunk_size) as usize).min(self.peaks.len());
            let chunk_peak = self.peaks[start..end]
                .iter()
                .copied()
                .fold(0.0f32, f32::max)
                .clamp(0.0, 1.0);
            points.push(chunk_peak);
        }

        WaveformData {
            point_count: n_points as u32,
            points,
        }
    }
}

pub fn analyze_media_source<M: MediaSource + 'static>(
    source: M,
    hint_ext: Option<&str>,
    config: &AudioAnalysisConfig,
    byte_size: u64,
) -> Result<AudioAnalysisResult, i32> {
    let mut engine = SymphoniaEngine::new(source, hint_ext).map_err(|_| -6)?;

    let sample_rate = engine.sample_rate();
    let channels = engine.channels().max(1);
    let ch_usize = channels as usize;
    let duration_ms = engine.duration_ms().unwrap_or(0) as i64;

    let calc_rg = (config.flags & MAP_ANALYSIS_FLAG_REPLAY_GAIN) != 0;
    let calc_wf = (config.flags & MAP_ANALYSIS_FLAG_WAVEFORM) != 0;

    let mut rg_analyzer = calc_rg.then(|| Bs1770LoudnessAnalyzer::new(sample_rate));
    let mut wf_accumulator = WaveformAccumulator::default();
    let mut peak = 0.0f32;
    let mut frame_buf = Vec::new();

    while let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
        for frame in frame_buf.chunks_exact(ch_usize) {
            let s_l = frame[0].clamp(-1.0, 1.0);
            let s_r = if ch_usize > 1 {
                frame[1].clamp(-1.0, 1.0)
            } else {
                s_l
            };

            let frame_max = s_l.abs().max(s_r.abs());
            if frame_max > peak {
                peak = frame_max;
            }
            if calc_wf {
                wf_accumulator.push_peak(frame_max);
            }
            if let Some(ref mut rg) = rg_analyzer {
                rg.push_stereo_frame(s_l, s_r);
            }
        }
    }

    let bitrate = if duration_ms > 0 && byte_size > 0 {
        ((byte_size * 8000) / (duration_ms as u64)) as u32
    } else {
        0
    };

    let (has_replay_gain, replay_gain) = match rg_analyzer {
        Some(rg) => (1, rg.finalize(config.target_lufs, peak)),
        None => (0, ReplayGainData::default()),
    };

    let (has_waveform, waveform) = if calc_wf && !wf_accumulator.is_empty() {
        (1, wf_accumulator.finalize(config.waveform_points))
    } else {
        (0, WaveformData::default())
    };

    Ok(AudioAnalysisResult {
        status: 0,
        duration_ms,
        sample_rate,
        channels,
        bitrate,
        peak,
        has_replay_gain,
        replay_gain,
        has_waveform,
        waveform,
    })
}

pub fn analyze_file(path: &str, config: &AudioAnalysisConfig) -> Result<AudioAnalysisResult, i32> {
    let file = File::open(path).map_err(|_| -5)?;
    let byte_size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if byte_size == 0 {
        return Err(-6);
    }
    let ext = FormatSniffer::extract_extension_hint(path);
    analyze_media_source(file, ext, config, byte_size)
}

pub fn analyze_memory(
    data: &[u8],
    config: &AudioAnalysisConfig,
) -> Result<AudioAnalysisResult, i32> {
    let byte_size = data.len() as u64;
    let (_status, boundary) = FormatSniffer::detect_head_boundary(data, byte_size as i64);
    let sniffer_hint = boundary.container.hint_extension();
    let cursor = Cursor::new(data.to_vec());
    analyze_media_source(cursor, sniffer_hint, config, byte_size)
}

pub fn free_analysis_result(result: &mut AudioAnalysisResult) {
    result.waveform.points.clear();
    result.waveform.point_count = 0;
    result.has_waveform = 0;
}
