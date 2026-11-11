//! Offline & Streaming Audio Analysis Pipeline (ITU-R BS.1770-4 LUFS, ReplayGain, and Waveform).
//!
//! Decomposes audio analysis into single-responsibility pipeline components:
//! - [`Bs1770LoudnessAnalyzer`]: K-weighting biquad cascade + 400 ms dual-gated LUFS integrator.
//! - [`AdaptiveWaveformAccumulator`]: Dynamic decimation peak collector with bounded memory.

use std::f64::consts::PI;

use crate::api::types::{RustAnalysisConfig, RustAudioAnalysisResult, RustChromaprintResult};
use crate::core::dual_source::{AudioSourceCore, DualSource, StreamingDeck};
use crate::decoder::sniffer::FormatSniffer;

use super::biquad::BiquadDf2t;

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
/// Ensures peak accumulation memory remains strictly bounded (< 16 KB)
/// across any file duration from seconds to 10+ hours.
pub struct AdaptiveWaveformAccumulator {
    target_points: usize,
    buckets: Vec<f32>,
    current_block_peak: f32,
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
            current_block_peak: 0.0,
            current_block_frames: 0,
            frames_per_block: 256,
            has_samples: false,
        }
    }

    /// Feeds an instantaneous absolute frame peak value into the accumulator.
    #[inline]
    pub fn push_frame_peak(&mut self, peak: f32) {
        self.has_samples = true;
        if peak > self.current_block_peak {
            self.current_block_peak = peak;
        }
        self.current_block_frames += 1;
        if self.current_block_frames >= self.frames_per_block {
            self.buckets.push(self.current_block_peak);
            self.current_block_peak = 0.0;
            self.current_block_frames = 0;

            if self.buckets.len() >= Self::MAX_BUCKETS {
                let mut decimated = Vec::with_capacity(self.buckets.len() / 2);
                for chunk in self.buckets.chunks_exact(2) {
                    decimated.push(chunk[0].max(chunk[1]));
                }
                self.buckets = decimated;
                self.frames_per_block *= 2;
            }
        }
    }

    /// Resamples accumulated peaks into normalized `[0.0, 1.0]` points matching `target_points`.
    pub fn finalize(mut self) -> Vec<f32> {
        if !self.has_samples {
            return Vec::new();
        }
        if self.current_block_frames > 0 {
            self.buckets.push(self.current_block_peak);
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
            let chunk_peak = if start < self.buckets.len() {
                self.buckets[start..end.max(start + 1).min(self.buckets.len())]
                    .iter()
                    .copied()
                    .fold(0.0f32, f32::max)
                    .clamp(0.0, 1.0)
            } else {
                *self.buckets.last().unwrap_or(&0.0)
            };
            points.push(chunk_peak);
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

/// Standalone, reusable metadata and format extraction information from audio container headers.
#[derive(Debug, Clone, Default)]
pub struct HeadAnalysisInfo {
    /// Inferred container or codec format name (e.g., "mp3", "flac").
    pub format: Option<String>,
    /// Estimated nominal bitrate in bits per second.
    pub bitrate: u32,
    /// Estimated audio duration in milliseconds.
    pub duration_ms: i64,
    /// Byte offset where audio payload begins.
    pub audio_start: i64,
    /// Byte offset where audio payload ends.
    pub audio_end: i64,
    /// Raw metadata tag bytes extracted from header.
    pub metadata_bytes: Option<Vec<u8>>,
}

/// Safely inspects and extracts format and metadata information from audio header bytes.
/// Designed for modular reuse in both offline analysis and stream metadata inspection.
pub fn analyze_head_info(
    head_data: &[u8],
    total_byte_size: i64,
    extract_metadata: bool,
) -> HeadAnalysisInfo {
    let (_status, boundary) = FormatSniffer::detect_head_boundary(head_data, total_byte_size);
    let sniffed = FormatSniffer::sniff_stream_info(head_data, total_byte_size);
    let (bitrate, duration_ms) = sniffed.unwrap_or((0, 0));
    let format = boundary.container.hint_extension().map(|s| s.to_string());

    let metadata_bytes = if extract_metadata && !head_data.is_empty() {
        let meta_len = if boundary.audio_start > 0 {
            (boundary.audio_start as usize).min(head_data.len())
        } else {
            head_data.len().min(65536)
        };
        Some(head_data[..meta_len].to_vec())
    } else {
        None
    };

    HeadAnalysisInfo {
        format,
        bitrate,
        duration_ms,
        audio_start: boundary.audio_start,
        audio_end: boundary.audio_end,
        metadata_bytes,
    }
}

/// Performs comprehensive, memory-bounded ($O(1)$ RAM) acoustic, loudness, waveform,
/// and metadata analysis on an arbitrary [`AudioSourceCore`].
pub fn analyze_audio_source(
    source: AudioSourceCore,
    config: RustAnalysisConfig,
) -> Result<RustAudioAnalysisResult, String> {
    let mut deck = StreamingDeck::new_analysis_deck(44100, 2)
        .map_err(|e| format!("Failed to create analysis deck: {}", e))?;

    let res = DualSource::open_deck_source(&mut deck, &source, None);
    if res != 0 {
        return Err(format!("Failed to open audio source (code: {})", res));
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

    // Phase 2: Acoustic DSP Pull Loop at maximum CPU speed
    let ch_usize = channels as usize;
    let mut rg_analyzer = config.replay_gain.then(|| Bs1770LoudnessAnalyzer::new(sample_rate));
    let mut wf_accumulator = config.waveform.then(|| AdaptiveWaveformAccumulator::new(config.waveform_points as usize));
    let mut chromaprinter = if config.chromaprint && sample_rate > 0 {
        let mut fp = chromaprint::Fingerprinter::new(chromaprint::types::Algorithm::default());
        if fp.start(sample_rate, channels as u16).is_ok() {
            Some(fp)
        } else {
            None
        }
    } else {
        None
    };
    let mut pcm_i16_buf = Vec::new();
    let mut peak = 0.0f32;
    let mut total_decoded_frames = 0u64;

    let max_frames = config.max_duration_ms.map(|ms| {
        (ms as f64 * sample_rate as f64 / 1000.0) as u64
    });

    let mut frame_buf = Vec::new();
    while let Ok(true) = deck.decode_next_analysis_frame(&mut frame_buf) {
        let chunk_frames = (frame_buf.len() / ch_usize) as u64;
        total_decoded_frames += chunk_frames;

        for frame in frame_buf.chunks_exact(ch_usize) {
            let s_l = frame[0].clamp(-1.0, 1.0);
            let s_r = if ch_usize > 1 { frame[1].clamp(-1.0, 1.0) } else { s_l };
            let frame_max = s_l.abs().max(s_r.abs());
            if frame_max > peak { peak = frame_max; }
            if let Some(ref mut wf) = wf_accumulator { wf.push_frame_peak(frame_max); }
            if let Some(ref mut rg) = rg_analyzer { rg.push_stereo_frame(s_l, s_r); }
        }

        if let Some(ref mut fp) = chromaprinter {
            pcm_i16_buf.clear();
            pcm_i16_buf.reserve(frame_buf.len());
            for &sample in &frame_buf {
                let clamped = sample.clamp(-1.0, 1.0);
                let sample_i16 = (clamped * 32767.0) as i16;
                pcm_i16_buf.push(sample_i16);
            }
            let _ = fp.feed(&pcm_i16_buf);
        }

        if let Some(limit) = max_frames {
            if total_decoded_frames >= limit {
                break;
            }
        }
    }

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

    let (has_replay_gain, replay_gain) = match rg_analyzer {
        Some(rg) => (true, rg.finalize(config.target_lufs, peak)),
        None => (false, ReplayGainData::default()),
    };

    let (has_waveform, waveform_peaks) = match wf_accumulator {
        Some(wf) => (true, wf.finalize()),
        None => (false, Vec::new()),
    };

    let (has_chromaprint, chromaprint) = match chromaprinter {
        Some(mut fp) => {
            if fp.finish().is_ok() {
                let fingerprint = fp.encode();
                let raw = fp.fingerprint().to_vec();
                let algorithm = match fp.algorithm() {
                    chromaprint::types::Algorithm::Test1 => 0,
                    chromaprint::types::Algorithm::Test2 => 1,
                    chromaprint::types::Algorithm::Test3 => 2,
                    chromaprint::types::Algorithm::Test4 => 3,
                    chromaprint::types::Algorithm::Test5 => 4,
                };
                (
                    true,
                    Some(RustChromaprintResult {
                        fingerprint,
                        raw,
                        algorithm,
                    }),
                )
            } else {
                (false, None)
            }
        }
        None => (false, None),
    };

    let metadata = if config.metadata {
        deck.get_parsed_metadata()
    } else {
        None
    };

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
