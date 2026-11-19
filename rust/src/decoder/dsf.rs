//! DSD (Direct Stream Digital) `.dsf` format decoder and FIR decimation pipeline.
//!
//! Decimates 1-bit PDM streams (DSD64: 2.8224 MHz, DSD128: 5.6448 MHz) to PCM f32.

use std::f64::consts::PI;
use std::io::{Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;

/// Sony DSF specification idle silence pattern (balanced 0-DC alternating bit pattern).
const DSF_SILENCE_BYTE: u8 = 0x69;

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

/// Zero-order modified Bessel function of the first kind `I_0(x)` for Kaiser window design.
#[inline]
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0f64;
    let mut term = 1.0f64;
    let half_x = 0.5 * x;
    let mut k = 1.0f64;
    while term > 1e-15 * sum {
        let ratio = half_x / k;
        term *= ratio * ratio;
        sum += term;
        k += 1.0;
    }
    sum
}

/// High-rejection Kaiser-windowed FIR decimator for 1-bit PDM (DSD64/128/256) streams.
///
/// Uses a precomputed 8-bit byte lookup table when the decimation factor is a multiple of 8
/// (covering DSD64=32, DSD128=64, DSD256=128) so 1024+ tap filtering runs via L2-resident
/// table adds without bit-by-bit unpacking.
struct DsdFirDecimator {
    decimation_factor: usize,
    coeffs: Vec<f32>,
    byte_lut: Vec<[f32; 256]>,
    hist_bytes: Vec<Vec<u8>>,
    hist_bits: Vec<Vec<f32>>,
}

impl DsdFirDecimator {
    fn new(decimation_factor: usize, channels: usize) -> Self {
        let coeffs = Self::design_filter(decimation_factor);
        let num_bytes = coeffs.len() / 8;
        let byte_lut = if decimation_factor.is_multiple_of(8) && coeffs.len().is_multiple_of(8) {
            Self::build_byte_lut(&coeffs)
        } else {
            Vec::new()
        };
        let hist_bytes = if byte_lut.is_empty() {
            Vec::new()
        } else {
            vec![vec![DSF_SILENCE_BYTE; num_bytes]; channels]
        };
        let hist_bits = if byte_lut.is_empty() {
            vec![vec![0.0f32; coeffs.len()]; channels]
        } else {
            Vec::new()
        };
        Self {
            decimation_factor,
            coeffs,
            byte_lut,
            hist_bytes,
            hist_bits,
        }
    }

    fn design_filter(decimation_factor: usize) -> Vec<f32> {
        // Scale tap count with decimation ratio (`1024` taps for DSD64 32x) so stopband reaches
        // <= -100 dB well before the decimated Nyquist frequency, preventing sigma-delta aliasing.
        let m = decimation_factor.max(1);
        let raw_taps = (m * 32).clamp(256, 4096);
        let num_taps = (raw_taps + 7) & !7;
        let mut taps = Vec::with_capacity(num_taps);
        let center = (num_taps - 1) as f64 / 2.0;
        let fc = 0.28 / m as f64;
        const KAISER_BETA: f64 = 10.0;
        let denom = bessel_i0(KAISER_BETA);

        let mut sum = 0.0f64;
        for i in 0..num_taps {
            let n = i as f64 - center;
            let sinc = if n.abs() < 1e-9 {
                2.0 * fc
            } else {
                (2.0 * PI * fc * n).sin() / (PI * n)
            };
            let r = (2.0 * i as f64) / (num_taps - 1) as f64 - 1.0;
            let arg = (1.0 - r * r).max(0.0).sqrt();
            let window = bessel_i0(KAISER_BETA * arg) / denom;
            let val = sinc * window;
            taps.push(val);
            sum += val;
        }

        let inv_sum = if sum.abs() > 1e-12 { 1.0 / sum } else { 1.0 };
        taps.into_iter().map(|t| (t * inv_sum) as f32).collect()
    }

    fn build_byte_lut(coeffs: &[f32]) -> Vec<[f32; 256]> {
        let num_bytes = coeffs.len() / 8;
        let mut lut = vec![[0.0f32; 256]; num_bytes];
        for (b, table) in lut.iter_mut().enumerate() {
            let tap_base = b * 8;
            for val in 0..256usize {
                let mut acc = 0.0f32;
                for r in 0..8usize {
                    let lsb_bit = 7 - r;
                    let sign = if ((val >> lsb_bit) & 1) != 0 {
                        1.0f32
                    } else {
                        -1.0f32
                    };
                    acc += sign * coeffs[tap_base + r];
                }
                table[val] = acc;
            }
        }
        lut
    }

    fn reset(&mut self) {
        for ch_bytes in &mut self.hist_bytes {
            ch_bytes.fill(DSF_SILENCE_BYTE);
        }
        for ch_hist in &mut self.hist_bits {
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
        if !self.byte_lut.is_empty() {
            return self.process_block_lut(block_bytes, channels, bspc, out_pcm);
        }
        self.process_block_bits(block_bytes, channels, bspc, out_pcm)
    }

    fn process_block_lut(
        &mut self,
        block_bytes: &[u8],
        channels: usize,
        bspc: usize,
        out_pcm: &mut Vec<f32>,
    ) -> usize {
        let bytes_per_step = self.decimation_factor / 8;
        let pcm_samples_per_block = bspc / bytes_per_step;
        let num_bytes = self.byte_lut.len();
        out_pcm.reserve(pcm_samples_per_block * channels);

        let mut decimated_channels = vec![vec![0.0f32; pcm_samples_per_block]; channels];
        for ch in 0..channels {
            let ch_bytes = &block_bytes[ch * bspc..(ch + 1) * bspc];
            let hist = &mut self.hist_bytes[ch];
            let dec_out = &mut decimated_channels[ch];

            for (i, dec_val) in dec_out.iter_mut().enumerate() {
                let base_byte = i * bytes_per_step;
                let split_b = base_byte.min(num_bytes);
                let mut sum = 0.0f32;
                for b in 0..split_b {
                    sum += self.byte_lut[b][ch_bytes[base_byte - 1 - b] as usize];
                }
                for b in split_b..num_bytes {
                    sum += self.byte_lut[b][hist[num_bytes - 1 - (b - base_byte)] as usize];
                }
                *dec_val = sum;
            }

            if bspc >= num_bytes {
                hist.copy_from_slice(&ch_bytes[bspc - num_bytes..]);
            } else if bspc > 0 {
                hist.copy_within(bspc..num_bytes, 0);
                hist[num_bytes - bspc..].copy_from_slice(ch_bytes);
            }
        }

        for i in 0..pcm_samples_per_block {
            for ch_buf in &decimated_channels {
                out_pcm.push(ch_buf[i]);
            }
        }
        pcm_samples_per_block
    }

    fn process_block_bits(
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

            let hist = &mut self.hist_bits[ch];
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
            } else if raw_samples_per_block > 0 {
                hist.copy_within(raw_samples_per_block..fir_len, 0);
                hist[fir_len - raw_samples_per_block..].copy_from_slice(&raw_signal);
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

/// Result of probing a media source for Direct Stream Digital (`.dsf`) audio container format.
pub enum DsfProbe {
    /// Source matched DSF format and initialized a `DsfReader`.
    Matched(DsfReader),
    /// Source did not match DSF format; stream was rewound and returned.
    NotMatched(Box<dyn MediaSource>),
}

/// Decoder reader parsing and decimating DSD (`.dsf`) 1-bit PDM streams into PCM float audio.
pub struct DsfReader {
    source: Box<dyn MediaSource>,
    sample_rate: u32,
    raw_sample_rate: u32,
    channels: u32,
    block_size_per_channel: usize,
    data_start: u64,
    data_end: u64,
    expected_byte_pos: u64,
    total_samples_per_channel: u64,
    current_sample_pos: u64,
    decimation_factor: usize,
    duration_ms: Option<u64>,
    block_buffer: Vec<u8>,
    decimator: DsdFirDecimator,
}

impl DsfReader {
    /// Attempts to parse the DSF chunk hierarchy and initialize a `DsfReader`.
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
            expected_byte_pos: hdr.data_start,
            total_samples_per_channel: hdr.total_pcm_samples_per_channel,
            current_sample_pos: 0,
            decimation_factor: hdr.decimation_factor,
            duration_ms: hdr.duration_ms,
            block_buffer: vec![0u8; total_block_bytes],
            decimator,
        }))
    }

    /// Returns the raw 1-bit DSD sampling rate (e.g., 2,822,400 Hz for DSD64).
    #[inline]
    pub fn raw_sample_rate(&self) -> u32 {
        self.raw_sample_rate
    }

    /// Returns the decimated output PCM sample rate in Hz.
    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Returns the number of audio channels.
    #[inline]
    pub fn channels(&self) -> u32 {
        self.channels
    }

    /// Returns the native DSD bit depth per sample (`1`).
    #[inline]
    pub fn bits_per_sample(&self) -> u32 {
        1
    }

    /// Returns total stream duration in milliseconds if known.
    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    /// Seeks to the specified position in milliseconds.
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

        self.expected_byte_pos = target_pos;
        self.current_sample_pos =
            (block_idx * self.block_size_per_channel as u64 * 8) / self.decimation_factor as u64;
        self.decimator.reset();
        Ok(())
    }

    /// Decodes and decimates the next block of DSD frames into normalized float PCM.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();

        if self.current_sample_pos >= self.total_samples_per_channel {
            return Ok(false);
        }

        let cur_pos = self
            .source
            .seek(SeekFrom::Start(self.expected_byte_pos))
            .map_err(SymphoniaError::IoError)?;
        if cur_pos >= self.data_end {
            return Ok(false);
        }

        let remaining_bytes = (self.data_end - cur_pos) as usize;
        let to_read = remaining_bytes.min(self.block_buffer.len());
        if to_read < self.block_buffer.len() {
            self.block_buffer.fill(DSF_SILENCE_BYTE);
        }
        match super::read_exact_resilient(&mut *self.source, &mut self.block_buffer[..to_read]) {
            Ok(()) => {
                self.expected_byte_pos = cur_pos + to_read as u64;
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(false),
            Err(e) => {
                let _ = self.source.seek(SeekFrom::Start(self.expected_byte_pos));
                return Err(SymphoniaError::IoError(e));
            }
        }

        let produced = self.decimator.process_block(
            &self.block_buffer,
            self.channels as usize,
            self.block_size_per_channel,
            out_pcm,
        );
        let remaining_frames = self
            .total_samples_per_channel
            .saturating_sub(self.current_sample_pos) as usize;
        let valid_frames = produced.min(remaining_frames);
        if valid_frames == 0 {
            out_pcm.clear();
            return Ok(false);
        }
        out_pcm.truncate(valid_frames * self.channels as usize);
        self.current_sample_pos += valid_frames as u64;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filter_mag_db(taps: &[f32], freq_hz: f64, fs_dsd: f64) -> f64 {
        let mut re = 0.0f64;
        let mut im = 0.0f64;
        for (k, &t) in taps.iter().enumerate() {
            let phase = 2.0 * PI * freq_hz * (k as f64) / fs_dsd;
            re += (t as f64) * phase.cos();
            im += (t as f64) * phase.sin();
        }
        20.0 * (re.hypot(im).max(1e-12)).log10()
    }

    #[test]
    fn test_dsd64_kaiser_decimator_frequency_response_and_lut_bit_parity() {
        let taps = DsdFirDecimator::design_filter(32);
        assert_eq!(taps.len(), 1024);

        let fs = 2_822_400.0;
        let pass_1k = filter_mag_db(&taps, 1_000.0, fs);
        let pass_18k = filter_mag_db(&taps, 18_000.0, fs);
        let pass_20k = filter_mag_db(&taps, 20_000.0, fs);
        let stop_34k = filter_mag_db(&taps, 34_000.0, fs);
        let stop_44k = filter_mag_db(&taps, 44_100.0, fs);
        let stop_88k = filter_mag_db(&taps, 88_200.0, fs);
        let stop_95k = filter_mag_db(&taps, 95_000.0, fs);

        assert!(pass_1k.abs() < 0.05, "1 kHz gain drift: {:.2} dB", pass_1k);
        assert!(pass_18k > -0.2, "18 kHz droop: {:.2} dB", pass_18k);
        assert!(pass_20k > -0.5, "20 kHz droop: {:.2} dB", pass_20k);
        assert!(stop_34k < -95.0, "34 kHz stopband insufficient: {:.2} dB", stop_34k);
        assert!(stop_44k < -100.0, "44.1 kHz stopband insufficient: {:.2} dB", stop_44k);
        assert!(stop_88k < -120.0, "88.2 kHz stopband insufficient: {:.2} dB", stop_88k);
        assert!(stop_95k < -120.0, "95 kHz stopband insufficient: {:.2} dB", stop_95k);

        // Verify byte LUT silence invariance on Sony DSF idle pattern (0x69)
        let mut dec = DsdFirDecimator::new(32, 2);
        let idle_block = vec![DSF_SILENCE_BYTE; 4096 * 2];
        let mut out = Vec::new();
        dec.process_block(&idle_block, 2, 4096, &mut out);
        let max_idle = out.iter().fold(0.0f32, |m, &x| m.max(x.abs()));
        assert!(max_idle < 1e-6, "Idle 0x69 leaked DC/noise: {}", max_idle);
    }
}
