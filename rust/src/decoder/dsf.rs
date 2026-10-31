//! DSD (Direct Stream Digital) .dsf format decoder and decimation filter.
//! Decimates 1-bit PDM streams (DSD64: 2.8224 MHz, DSD128: 5.6448 MHz) to high-fidelity 88.2 kHz PCM.

use std::io::{Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;

pub enum DsfProbe {
    Matched(DsfReader),
    NotMatched(Box<dyn MediaSource>),
}

pub struct DsfReader {
    source: Box<dyn MediaSource>,
    sample_rate: u32,       // Target PCM sample rate (typically 88200)
    raw_sample_rate: u32,   // Raw DSD sample rate (2822400 or 5644800)
    channels: u32,
    block_size_per_channel: usize,
    data_start: u64,
    data_end: u64,
    total_samples_per_channel: u64,
    current_sample_pos: u64, // in target PCM samples
    decimation_factor: usize, // raw_sample_rate / sample_rate (e.g. 32 or 64)
    duration_ms: Option<u64>,
    block_buffer: Vec<u8>,
    fir_coeffs: Vec<f32>,
    history: Vec<Vec<f32>>, // per-channel FIR history buffer
}

impl DsfReader {
    /// Attempts to probe and open a DSF stream.
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<DsfProbe, SymphoniaError> {
        if source.seek(SeekFrom::Start(0)).is_err() {
            return Ok(DsfProbe::NotMatched(source));
        }

        let mut header = [0u8; 28];
        if source.read_exact(&mut header).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        // Header chunk: "DSD " (4 bytes)
        if &header[0..4] != b"DSD " {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        let chunk_size = u64::from_le_bytes(header[4..12].try_into().unwrap());
        if chunk_size != 28 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        // Format chunk: "fmt "
        let mut fmt_chunk = [0u8; 52];
        if source.read_exact(&mut fmt_chunk).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        if &fmt_chunk[0..4] != b"fmt " {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        let fmt_chunk_size = u64::from_le_bytes(fmt_chunk[4..12].try_into().unwrap());
        if fmt_chunk_size < 52 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        let channel_num = u32::from_le_bytes(fmt_chunk[24..28].try_into().unwrap());
        let raw_sampling_freq = u32::from_le_bytes(fmt_chunk[28..32].try_into().unwrap());
        let bits_per_sample = u32::from_le_bytes(fmt_chunk[32..36].try_into().unwrap());
        let sample_count = u64::from_le_bytes(fmt_chunk[36..44].try_into().unwrap());
        let block_size_per_channel =
            u32::from_le_bytes(fmt_chunk[44..48].try_into().unwrap()) as usize;

        if bits_per_sample != 1 || channel_num == 0 || channel_num > 8 || block_size_per_channel == 0 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        // If fmt_chunk_size > 52, skip extra bytes in fmt chunk
        if fmt_chunk_size > 52 {
            let extra = fmt_chunk_size - 52;
            if source.seek(SeekFrom::Current(extra as i64)).is_err() {
                let _ = source.seek(SeekFrom::Start(0));
                return Ok(DsfProbe::NotMatched(source));
            }
        }

        // Data chunk: "data"
        let mut data_chunk_hdr = [0u8; 12];
        if source.read_exact(&mut data_chunk_hdr).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        if &data_chunk_hdr[0..4] != b"data" {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(DsfProbe::NotMatched(source));
        }

        let data_chunk_size = u64::from_le_bytes(data_chunk_hdr[4..12].try_into().unwrap());
        let data_start = 28 + fmt_chunk_size + 12;
        let data_end = data_start + data_chunk_size.saturating_sub(12);

        // Target PCM sample rate: 88.2 kHz for audiophile output without inaudible RF noise
        let pcm_sample_rate = if raw_sampling_freq % 88200 == 0 {
            88200
        } else if raw_sampling_freq % 44100 == 0 {
            44100
        } else {
            48000
        };

        let decimation_factor = (raw_sampling_freq / pcm_sample_rate).max(1) as usize;
        let duration_ms = if raw_sampling_freq > 0 {
            Some((sample_count * 1000) / raw_sampling_freq as u64)
        } else {
            None
        };

        let total_pcm_samples = sample_count / decimation_factor as u64;

        // Design a high-quality FIR anti-aliasing decimation filter
        let fir_coeffs = Self::design_decimation_filter(decimation_factor);
        let history = vec![vec![0.0f32; fir_coeffs.len()]; channel_num as usize];
        let total_block_bytes = block_size_per_channel * channel_num as usize;

        Ok(DsfProbe::Matched(DsfReader {
            source,
            sample_rate: pcm_sample_rate,
            raw_sample_rate: raw_sampling_freq,
            channels: channel_num,
            block_size_per_channel,
            data_start,
            data_end,
            total_samples_per_channel: total_pcm_samples,
            current_sample_pos: 0,
            decimation_factor,
            duration_ms,
            block_buffer: vec![0u8; total_block_bytes],
            fir_coeffs,
            history,
        }))
    }

    /// Designs a symmetric low-pass FIR filter with cut-off at ~0.45 of target Nyquist.
    fn design_decimation_filter(decimation_factor: usize) -> Vec<f32> {
        // Tap length proportional to decimation factor (e.g. 64 taps for 32x)
        let num_taps = (decimation_factor * 2).clamp(32, 128);
        let mut taps = Vec::with_capacity(num_taps);
        let center = (num_taps - 1) as f32 / 2.0;
        let fc = 0.45 / decimation_factor as f32; // Cutoff normalized to DSD rate

        let mut sum = 0.0f32;
        for i in 0..num_taps {
            let n = i as f32 - center;
            // Sinc function
            let sinc = if n.abs() < 1e-6 {
                2.0 * fc
            } else {
                (2.0 * std::f32::consts::PI * fc * n).sin() / (std::f32::consts::PI * n)
            };
            // Blackman-Harris window
            let a0 = 0.35875;
            let a1 = 0.48829;
            let a2 = 0.14128;
            let a3 = 0.01168;
            let w = a0
                - a1 * (2.0 * std::f32::consts::PI * i as f32 / (num_taps - 1) as f32).cos()
                + a2 * (4.0 * std::f32::consts::PI * i as f32 / (num_taps - 1) as f32).cos()
                - a3 * (6.0 * std::f32::consts::PI * i as f32 / (num_taps - 1) as f32).cos();

            let val = sinc * w;
            taps.push(val);
            sum += val;
        }

        // Normalize gain to unity (1.0)
        if sum.abs() > 1e-6 {
            for tap in &mut taps {
                *tap /= sum;
            }
        }
        taps
    }

    pub fn raw_sample_rate(&self) -> u32 {
        self.raw_sample_rate
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u32 {
        self.channels
    }

    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let sec = position_ms as f64 / 1000.0;
        let target_frame = (sec * self.sample_rate as f64) as u64;

        let clamped_frame = target_frame.min(self.total_samples_per_channel);
        let raw_dsd_sample = clamped_frame * self.decimation_factor as u64;
        let raw_dsd_byte_per_ch = raw_dsd_sample / 8;

        let block_idx = raw_dsd_byte_per_ch / self.block_size_per_channel as u64;
        let block_stride = (self.block_size_per_channel * self.channels as usize) as u64;
        let target_pos = self.data_start + block_idx * block_stride;

        self.source.seek(SeekFrom::Start(target_pos.min(self.data_end)))
            .map_err(|e| SymphoniaError::IoError(e))?;

        self.current_sample_pos = (block_idx * self.block_size_per_channel as u64 * 8)
            / self.decimation_factor as u64;

        // Reset FIR history on seek to prevent transient burst
        for h in &mut self.history {
            h.fill(0.0);
        }

        Ok(())
    }

    /// Decodes the next block of DSD frames, decimating 1-bit PDM to interleaved PCM f32.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();

        let cur_pos = self.source.seek(SeekFrom::Current(0))
            .map_err(|e| SymphoniaError::IoError(e))?;
        if cur_pos >= self.data_end {
            return Ok(false);
        }

        match self.source.read_exact(&mut self.block_buffer) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                return Ok(false);
            }
            Err(e) => return Err(SymphoniaError::IoError(e)),
        }

        let channels = self.channels as usize;
        let bspc = self.block_size_per_channel;
        let raw_samples_per_block = bspc * 8;
        let pcm_samples_per_block = raw_samples_per_block / self.decimation_factor;

        out_pcm.reserve(pcm_samples_per_block * channels);

        // Pre-unpack 1-bit PDM into float signals (+1.0 / -1.0)
        let mut unpacked_channels = vec![vec![0.0f32; raw_samples_per_block]; channels];

        for ch in 0..channels {
            let ch_data = &self.block_buffer[ch * bspc..(ch + 1) * bspc];
            let ch_out = &mut unpacked_channels[ch];

            for (byte_idx, &b) in ch_data.iter().enumerate() {
                let base = byte_idx * 8;
                // DSF stores LSB first (bit 0 is earliest)
                for bit in 0..8 {
                    ch_out[base + bit] = if (b & (1 << bit)) != 0 { 1.0 } else { -1.0 };
                }
            }
        }

        let fir_len = self.fir_coeffs.len();
        let m = self.decimation_factor;

        // Decimate each channel with FIR filter
        let mut decimated_channels = vec![vec![0.0f32; pcm_samples_per_block]; channels];

        for ch in 0..channels {
            let raw_signal = &unpacked_channels[ch];
            let hist = &mut self.history[ch];
            let dec_out = &mut decimated_channels[ch];

            for (i, dec_val) in dec_out.iter_mut().enumerate() {
                let sample_idx = i * m;
                let mut sum = 0.0f32;

                for k in 0..fir_len {
                    let sig_val = if sample_idx >= k {
                        raw_signal[sample_idx - k]
                    } else {
                        // Take from history buffer
                        hist[fir_len - (k - sample_idx)]
                    };
                    sum += sig_val * self.fir_coeffs[k];
                }
                *dec_val = sum;
            }

            // Update history with the end of this block
            if raw_samples_per_block >= fir_len {
                hist.copy_from_slice(&raw_signal[raw_samples_per_block - fir_len..]);
            }
        }

        // Interleave channels into out_pcm
        for i in 0..pcm_samples_per_block {
            for ch in 0..channels {
                out_pcm.push(decimated_channels[ch][i]);
            }
        }

        self.current_sample_pos += pcm_samples_per_block as u64;
        Ok(true)
    }
}
