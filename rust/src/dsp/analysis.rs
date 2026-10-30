//! High-performance offline and streaming audio analysis (ReplayGain, LUFS BS.1770, and Waveform).

use std::fs::File;
use std::io::Cursor;
use symphonia::core::io::MediaSource;

use crate::decoder::SymphoniaEngine;

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
#[derive(Debug, Clone, Copy, Default)]
pub struct ReplayGainData {
    pub gain_db: f32,
    pub peak: f32,
    pub lufs: f32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WaveformData {
    pub point_count: u32,
    pub points: *mut f32,
}

impl Default for WaveformData {
    fn default() -> Self {
        Self {
            point_count: 0,
            points: std::ptr::null_mut(),
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
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

use super::biquad::BiquadDf2t;

pub fn analyze_media_source<M: MediaSource + 'static>(
    source: M,
    hint_ext: Option<&str>,
    config: &AudioAnalysisConfig,
    byte_size: u64,
) -> Result<AudioAnalysisResult, i32> {
    let mut engine = match SymphoniaEngine::new(source, hint_ext) {
        Ok(e) => e,
        Err(_) => return Err(-6), // MAP_ERROR_DECODE_FAILED
    };

    let sample_rate = engine.sample_rate();
    let channels = engine.channels().max(1);
    let duration_ms = engine.duration_ms().unwrap_or(0) as i64;

    let mut peak = 0.0f32;
    let mut frame_buf = Vec::new();

    // Estructuras de acumulación
    let mut all_peaks = Vec::new();

    // ReplayGain ITU-R BS.1770 K-weighting filters
    let calc_rg = (config.flags & MAP_ANALYSIS_FLAG_REPLAY_GAIN) != 0;
    let (mut hs_l, mut hp_l, mut hs_r, mut hp_r) = if calc_rg && sample_rate > 0 {
        let f0_hs = 1681.974450955533f64;
        let g_hs = 3.999843853973347f64;
        let q_hs = 0.7071752369554196f64;
        let k_hs = (std::f64::consts::PI * f0_hs / (sample_rate as f64)).tan();
        let vh = 10.0f64.powf(g_hs / 20.0);
        let vb = vh.powf(0.4996667741545416);
        let a0_hs = 1.0 + k_hs / q_hs + k_hs * k_hs;

        let b0_hs = ((vh + vb * k_hs / q_hs + k_hs * k_hs) / a0_hs) as f32;
        let b1_hs = (2.0 * (k_hs * k_hs - vh) / a0_hs) as f32;
        let b2_hs = ((vh - vb * k_hs / q_hs + k_hs * k_hs) / a0_hs) as f32;
        let a1_hs = (2.0 * (k_hs * k_hs - 1.0) / a0_hs) as f32;
        let a2_hs = ((1.0 - k_hs / q_hs + k_hs * k_hs) / a0_hs) as f32;

        let hs1 = BiquadDf2t::new(b0_hs, b1_hs, b2_hs, a1_hs, a2_hs);
        let hs2 = BiquadDf2t::new(b0_hs, b1_hs, b2_hs, a1_hs, a2_hs);

        let f0_hp = 38.13547087602444f64;
        let q_hp = 0.5003270373238773f64;
        let k_hp = (std::f64::consts::PI * f0_hp / (sample_rate as f64)).tan();
        let ra0 = 1.0 + k_hp / q_hp + k_hp * k_hp;

        let a1_hp = (2.0 * (k_hp * k_hp - 1.0) / ra0) as f32;
        let a2_hp = ((1.0 - k_hp / q_hp + k_hp * k_hp) / ra0) as f32;

        let hp1 = BiquadDf2t::new(1.0, -2.0, 1.0, a1_hp, a2_hp);
        let hp2 = BiquadDf2t::new(1.0, -2.0, 1.0, a1_hp, a2_hp);

        (hs1, hp1, hs2, hp2)
    } else {
        (BiquadDf2t::default(), BiquadDf2t::default(), BiquadDf2t::default(), BiquadDf2t::default())
    };

    let samples_per_100ms = (0.1 * (sample_rate as f64) + 0.5).max(1.0) as usize;
    let mut current_interval_samples = 0usize;
    let mut current_interval_sq = [0.0f64; 2];
    let mut interval_energies: Vec<f32> = Vec::new();

    while let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
        if frame_buf.is_empty() {
            continue;
        }

        let num_frames = frame_buf.len() / (channels as usize);
        for f in 0..num_frames {
            let raw_l = frame_buf[f * (channels as usize) + 0];
            let raw_r = if channels > 1 {
                frame_buf[f * (channels as usize) + 1]
            } else {
                raw_l
            };

            let s_l = raw_l.clamp(-1.0, 1.0);
            let s_r = raw_r.clamp(-1.0, 1.0);

            let abs_l = s_l.abs();
            let abs_r = s_r.abs();
            let frame_max = abs_l.max(abs_r);
            if frame_max > peak {
                peak = frame_max;
            }

            if (config.flags & MAP_ANALYSIS_FLAG_WAVEFORM) != 0 {
                all_peaks.push(frame_max);
            }

            if calc_rg {
                let y1_l = hs_l.process(s_l);
                let y2_l = hp_l.process(y1_l);
                let y1_r = hs_r.process(s_r);
                let y2_r = hp_r.process(y1_r);

                current_interval_sq[0] += (y2_l as f64) * (y2_l as f64);
                current_interval_sq[1] += (y2_r as f64) * (y2_r as f64);
                current_interval_samples += 1;

                if current_interval_samples >= samples_per_100ms {
                    let interval_e = (current_interval_sq[0] + current_interval_sq[1]) / (samples_per_100ms as f64);
                    current_interval_sq = [0.0, 0.0];
                    current_interval_samples = 0;
                    interval_energies.push(interval_e as f32);
                }
            }
        }
    }

    let bitrate = if duration_ms > 0 && byte_size > 0 {
        ((byte_size * 8000) / (duration_ms as u64)) as u32
    } else {
        0
    };

    let mut result = AudioAnalysisResult {
        status: 0,
        duration_ms,
        sample_rate,
        channels,
        bitrate,
        peak,
        has_replay_gain: 0,
        replay_gain: ReplayGainData::default(),
        has_waveform: 0,
        waveform: WaveformData::default(),
    };

    // ReplayGain / Loudness estimation (ITU-R BS.1770-4 gated)
    if calc_rg {
        if current_interval_samples > 0 {
            let interval_e = (current_interval_sq[0] + current_interval_sq[1]) / (current_interval_samples as f64);
            interval_energies.push(interval_e as f32);
        }

        let mut lufs = -70.0f32;
        if interval_energies.len() >= 4 {
            let num_blocks = interval_energies.len() - 3;
            let mut block_energies = Vec::with_capacity(num_blocks);
            let mut block_loudness = Vec::with_capacity(num_blocks);

            let abs_thresh = -70.0f32;
            let mut z_unmasked = 0.0f64;
            let mut count_unmasked = 0usize;

            for k in 0..num_blocks {
                let e4 = ((interval_energies[k] + interval_energies[k + 1] + interval_energies[k + 2] + interval_energies[k + 3]) as f64) * 0.25;
                block_energies.push(e4 as f32);
                let loud = if e4 > 0.0 {
                    (-0.691 + 10.0 * e4.log10()) as f32
                } else {
                    -100.0f32
                };
                block_loudness.push(loud);

                if loud > abs_thresh {
                    z_unmasked += e4;
                    count_unmasked += 1;
                }
            }

            if count_unmasked > 0 {
                z_unmasked /= count_unmasked as f64;
                let rel_thresh = (-0.691 + 10.0 * z_unmasked.log10() - 10.0) as f32;

                let mut z_gated_sum = 0.0f64;
                let mut count_gated = 0usize;

                for k in 0..num_blocks {
                    if block_loudness[k] > abs_thresh && block_loudness[k] > rel_thresh {
                        z_gated_sum += block_energies[k] as f64;
                        count_gated += 1;
                    }
                }

                if count_gated > 0 {
                    let z_final = z_gated_sum / (count_gated as f64);
                    lufs = (-0.691 + 10.0 * z_final.log10()) as f32;
                } else {
                    lufs = (-0.691 + 10.0 * z_unmasked.log10()) as f32;
                }
            }
        } else if !interval_energies.is_empty() {
            let total_e: f64 = interval_energies.iter().map(|&e| e as f64).sum::<f64>() / (interval_energies.len() as f64);
            if total_e > 0.0 {
                lufs = (-0.691 + 10.0 * total_e.log10()) as f32;
            }
        }

        let target_lufs = if config.target_lufs == 0.0 { -18.0 } else { config.target_lufs };
        let gain_db = if lufs <= -70.0 {
            0.0
        } else {
            target_lufs - lufs
        };

        result.has_replay_gain = 1;
        result.replay_gain = ReplayGainData {
            gain_db,
            peak,
            lufs,
        };
    }

    // Waveform downsampling
    if (config.flags & MAP_ANALYSIS_FLAG_WAVEFORM) != 0 && !all_peaks.is_empty() {
        let target_points = config.waveform_points.max(1) as usize;
        let mut points = Vec::with_capacity(target_points);

        let chunk_size = (all_peaks.len() as f64) / (target_points as f64);
        for i in 0..target_points {
            let start = (i as f64 * chunk_size) as usize;
            let end = (((i + 1) as f64 * chunk_size) as usize).min(all_peaks.len());
            let mut chunk_peak = 0.0f32;
            for j in start..end {
                if all_peaks[j] > chunk_peak {
                    chunk_peak = all_peaks[j];
                }
            }
            points.push(chunk_peak.clamp(0.0, 1.0));
        }

        let mut boxed_slice = points.into_boxed_slice();
        result.waveform = WaveformData {
            point_count: target_points as u32,
            points: boxed_slice.as_mut_ptr(),
        };
        let _ = Box::into_raw(boxed_slice); // Retain memory for caller
        result.has_waveform = 1;
    }

    Ok(result)
}

pub fn analyze_file(path: &str, config: &AudioAnalysisConfig) -> Result<AudioAnalysisResult, i32> {
    let file = File::open(path).map_err(|_| -5)?; // MAP_ERROR_FILE_NOT_FOUND
    let byte_size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if byte_size == 0 {
        return Err(-6); // MAP_ERROR_DECODE_FAILED
    }
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str());
    analyze_media_source(file, ext, config, byte_size)
}

pub fn analyze_memory(data: &[u8], config: &AudioAnalysisConfig) -> Result<AudioAnalysisResult, i32> {
    let byte_size = data.len() as u64;
    let cursor = Cursor::new(data.to_vec());
    analyze_media_source(cursor, None, config, byte_size)
}

pub fn free_analysis_result(result: &mut AudioAnalysisResult) {
    if result.has_waveform != 0 && !result.waveform.points.is_null() && result.waveform.point_count > 0 {
        unsafe {
            let slice = std::slice::from_raw_parts_mut(
                result.waveform.points,
                result.waveform.point_count as usize,
            );
            drop(Box::from_raw(slice));
        }
        result.waveform.points = std::ptr::null_mut();
        result.waveform.point_count = 0;
        result.has_waveform = 0;
    }
}
