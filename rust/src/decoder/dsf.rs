//! DSD (Direct Stream Digital) `.dsf` format decoder and FIR decimation pipeline.
//!
//! Decimates 1-bit PDM streams (DSD64: 2.8224 MHz, DSD128: 5.6448 MHz) to PCM f32.

use std::f32::consts::PI;
use std::io::{Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;

struct DsfHeader {
    channels: u32,
    raw_sample_rate: u32,
    pcm_sample_rate: u32,
    decimation_factor: usize,
    block_size_per_channel: usize,
    data_start: u64,
    data_end: u64,
    total_pcm_samples_per_channel: u64,
    duration_ms: Option<u64>,
}

impl DsfHeader {
    fn parse(source: &mut dyn MediaSource) -> Option<Self> {
        source.seek(SeekFrom::Start(0)).ok()?;

        let mut dsd_chunk = [0u8; 28];
        source.read_exact(&mut dsd_chunk).ok()?;
        if &dsd_chunk[0..4] != b"DSD " {
            return None;
        }
        let chunk_size = u64::from_le_bytes(dsd_chunk[4..12].try_into().ok()?);
        if chunk_size != 28 {
            return None;
        }

        let mut fmt_chunk = [0u8; 52];
        source.read_exact(&mut fmt_chunk).ok()?;
        if &fmt_chunk[0..4] != b"fmt " {
            return None;
        }
        let fmt_chunk_size = u64::from_le_bytes(fmt_chunk[4..12].try_into().ok()?);
        if fmt_chunk_size < 52 {
            return None;
        }

        let channels = u32::from_le_bytes(fmt_chunk[24..28].try_into().ok()?);
        let raw_sample_rate = u32::from_le_bytes(fmt_chunk[28..32].try_into().ok()?);
        let bits_per_sample = u32::from_le_bytes(fmt_chunk[32..36].try_into().ok()?);
        let sample_count = u64::from_le_bytes(fmt_chunk[36..44].try_into().ok()?);
        let block_size_per_channel =
            u32::from_le_bytes(fmt_chunk[44..48].try_into().ok()?) as usize;

        if bits_per_sample != 1
            || channels == 0
            || channels > 8
            || block_size_per_channel == 0
            || raw_sample_rate == 0
        {
            return None;
        }

        if fmt_chunk_size > 52 {
            let extra = fmt_chunk_size - 52;
            source.seek(SeekFrom::Current(extra as i64)).ok()?;
        }

        let mut data_chunk_hdr = [0u8; 12];
        source.read_exact(&mut data_chunk_hdr).ok()?;
        if &data_chunk_hdr[0..4] != b"data" {
            return None;
        }
        let data_chunk_size = u64::from_le_bytes(data_chunk_hdr[4..12].try_into().ok()?);
        let data_start = 28 + fmt_chunk_size + 12;
        let data_end = data_start + data_chunk_size.saturating_sub(12);

        let pcm_sample_rate = if raw_sample_rate % 88200 == 0 {
            88200
        } else if raw_sample_rate % 44100 == 0 {
            44100
        } else {
            48000
        };

        let decimation_factor = (raw_sample_rate / pcm_sample_rate).max(1) as usize;
        let duration_ms = Some((sample_count * 1000) / raw_sample_rate as u64);
        let total_pcm_samples_per_channel = sample_count / decimation_factor as u64;

        Some(Self {
            channels,
            raw_sample_rate,
            pcm_sample_rate,
            decimation_factor,
            block_size_per_channel,
            data_start,
            data_end,
            total_pcm_samples_per_channel,
            duration_ms,
        })
    }
}

/// Deterministic Blackman-Harris low-pass FIR decimator for 1-bit PDM streams.
struct DsdFirDecimator {
    decimation_factor: usize,
    coeffs: Vec<f32>,
    history: Vec<Vec<f32>>,
}

impl DsdFirDecimator {
    fn new(decimation_factor: usize, channels: usize) -> Self {
        let coeffs = Self::design_filter(decimation_factor);
        let history = vec![vec![0.0f32; coeffs.len()]; channels];
        Self {
            decimation_factor,
            coeffs,
            history,
        }
    }

    fn design_filter(decimation_factor: usize) -> Vec<f32> {
        let num_taps = (decimation_factor * 2).clamp(32, 128);
        let mut taps = Vec::with_capacity(num_taps);
        let center = (num_taps - 1) as f32 / 2.0;
        let fc = 0.45 / decimation_factor as f32;

        let mut sum = 0.0f32;
        for i in 0..num_taps {
            let n = i as f32 - center;
            let sinc = if n.abs() < 1e-6 {
                2.0 * fc
            } else {
                (2.0 * PI * fc * n).sin() / (PI * n)
            };
            let phase = 2.0 * PI * i as f32 / (num_taps - 1) as f32;
            let window = 0.35875 - 0.48829 * phase.cos() + 0.14128 * (2.0 * phase).cos()
                - 0.01168 * (3.0 * phase).cos();

            let val = sinc * window;
            taps.push(val);
            sum += val;
        }

        if sum.abs() > 1e-6 {
            for tap in &mut taps {
                *tap /= sum;
            }
        }
        taps
    }

    fn reset(&mut self) {
        for ch_hist in &mut self.history {
            ch_hist.fill(0.0);
        }
    }

    fn process_block(
        &mut self,
        block_bytes: &[u8],
        channels: usize,
        bspc: usize,
        out_pcm: &mut Vec<f32>,
    ) -> usize {
        let raw_samples_per_block = bspc * 8;
        let m = self.decimation_factor;
        let pcm_samples_per_block = raw_samples_per_block / m;
        let fir_len = self.coeffs.len();

        out_pcm.reserve(pcm_samples_per_block * channels);

        let mut decimated_channels = vec![vec![0.0f32; pcm_samples_per_block]; channels];
        let mut raw_signal = vec![0.0f32; raw_samples_per_block];

        for ch in 0..channels {
            let ch_bytes = &block_bytes[ch * bspc..(ch + 1) * bspc];
            Self::unpack_pdm_bits(ch_bytes, &mut raw_signal);

            let hist = &mut self.history[ch];
            let dec_out = &mut decimated_channels[ch];

            for (i, dec_val) in dec_out.iter_mut().enumerate() {
                let sample_idx = i * m;
                let mut sum = 0.0f32;
                for k in 0..fir_len {
                    let sig_val = if sample_idx >= k {
                        raw_signal[sample_idx - k]
                    } else {
                        hist[fir_len - (k - sample_idx)]
                    };
                    sum += sig_val * self.coeffs[k];
                }
                *dec_val = sum;
            }

            if raw_samples_per_block >= fir_len {
                hist.copy_from_slice(&raw_signal[raw_samples_per_block - fir_len..]);
            }
        }

        for i in 0..pcm_samples_per_block {
            for ch_buf in &decimated_channels {
                out_pcm.push(ch_buf[i]);
            }
        }

        pcm_samples_per_block
    }

    #[inline]
    fn unpack_pdm_bits(ch_bytes: &[u8], out_signal: &mut [f32]) {
        for (byte_idx, &b) in ch_bytes.iter().enumerate() {
            let base = byte_idx * 8;
            for bit in 0..8 {
                out_signal[base + bit] = if (b & (1 << bit)) != 0 { 1.0 } else { -1.0 };
            }
        }
    }
}

pub enum DsfProbe {
    Matched(DsfReader),
    NotMatched(Box<dyn MediaSource>),
}

pub struct DsfReader {
    source: Box<dyn MediaSource>,
    sample_rate: u32,
    raw_sample_rate: u32,
    channels: u32,
    block_size_per_channel: usize,
    data_start: u64,
    data_end: u64,
    total_samples_per_channel: u64,
    current_sample_pos: u64,
    decimation_factor: usize,
    duration_ms: Option<u64>,
    block_buffer: Vec<u8>,
    decimator: DsdFirDecimator,
}

impl DsfReader {
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<DsfProbe, SymphoniaError> {
        let Some(hdr) = DsfHeader::parse(&mut *source) else {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        };

        let total_block_bytes = hdr.block_size_per_channel * hdr.channels as usize;
        let decimator = DsdFirDecimator::new(hdr.decimation_factor, hdr.channels as usize);

        Ok(DsfProbe::Matched(Self {
            source,
            sample_rate: hdr.pcm_sample_rate,
            raw_sample_rate: hdr.raw_sample_rate,
            channels: hdr.channels,
            block_size_per_channel: hdr.block_size_per_channel,
            data_start: hdr.data_start,
            data_end: hdr.data_end,
            total_samples_per_channel: hdr.total_pcm_samples_per_channel,
            current_sample_pos: 0,
            decimation_factor: hdr.decimation_factor,
            duration_ms: hdr.duration_ms,
            block_buffer: vec![0u8; total_block_bytes],
            decimator,
        }))
    }

    #[inline]
    pub fn raw_sample_rate(&self) -> u32 {
        self.raw_sample_rate
    }

    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[inline]
    pub fn channels(&self) -> u32 {
        self.channels
    }

    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let target_frame = ((position_ms as f64 / 1000.0) * self.sample_rate as f64) as u64;
        let clamped_frame = target_frame.min(self.total_samples_per_channel);
        let raw_dsd_byte_per_ch = (clamped_frame * self.decimation_factor as u64) / 8;

        let block_idx = raw_dsd_byte_per_ch / self.block_size_per_channel as u64;
        let block_stride = (self.block_size_per_channel * self.channels as usize) as u64;
        let target_pos = (self.data_start + block_idx * block_stride).min(self.data_end);

        self.source
            .seek(SeekFrom::Start(target_pos))
            .map_err(SymphoniaError::IoError)?;

        self.current_sample_pos =
            (block_idx * self.block_size_per_channel as u64 * 8) / self.decimation_factor as u64;
        self.decimator.reset();
        Ok(())
    }

    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();

        let cur_pos = self
            .source
            .seek(SeekFrom::Current(0))
            .map_err(SymphoniaError::IoError)?;
        if cur_pos >= self.data_end {
            return Ok(false);
        }

        match self.source.read_exact(&mut self.block_buffer) {
            Ok(_) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(false),
            Err(e) => return Err(SymphoniaError::IoError(e)),
        }

        let produced = self.decimator.process_block(
            &self.block_buffer,
            self.channels as usize,
            self.block_size_per_channel,
            out_pcm,
        );
        self.current_sample_pos += produced as u64;
        Ok(true)
    }
}
