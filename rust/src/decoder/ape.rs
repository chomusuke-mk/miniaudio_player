//! Monkey's Audio (.ape) decoder wrapper using pure-Rust `ape-decoder`.

use std::io::{Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;
use ape_decoder::decoder::ApeDecoder;

pub enum ApeProbe {
    Matched(ApeReader),
    NotMatched(Box<dyn MediaSource>),
}

pub struct ApeReader {
    decoder: ApeDecoder<Box<dyn MediaSource>>,
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u32,
    total_frames: u32,
    current_frame: u32,
    duration_ms: Option<u64>,
}

impl ApeReader {
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<ApeProbe, SymphoniaError> {
        if source.seek(SeekFrom::Start(0)).is_err() {
            return Ok(ApeProbe::NotMatched(source));
        }

        let mut magic = [0u8; 4];
        if source.read_exact(&mut magic).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ApeProbe::NotMatched(source));
        }

        if &magic != b"MAC " {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ApeProbe::NotMatched(source));
        }

        let _ = source.seek(SeekFrom::Start(0));
        let decoder = match ApeDecoder::new(source) {
            Ok(d) => d,
            Err(_) => return Err(SymphoniaError::Unsupported("malformed APE stream")),
        };

        let info = decoder.info();
        let sample_rate = info.sample_rate;
        let channels = info.channels as u32;
        let bits_per_sample = info.bits_per_sample as u32;
        let total_frames = decoder.total_frames();

        let total_samples = info.total_samples;
        let duration_ms = if sample_rate > 0 {
            Some((total_samples as u64 * 1000) / sample_rate as u64)
        } else {
            None
        };

        Ok(ApeProbe::Matched(ApeReader {
            decoder,
            sample_rate,
            channels,
            bits_per_sample,
            total_frames,
            current_frame: 0,
            duration_ms,
        }))
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
        let target_sample = (sec * self.sample_rate as f64) as u64;

        match self.decoder.seek(target_sample) {
            Ok(seek_res) => {
                self.current_frame = seek_res.frame_index;
                Ok(())
            }
            Err(_) => Err(SymphoniaError::Unsupported("APE seek failed")),
        }
    }

    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();

        if self.current_frame >= self.total_frames {
            return Ok(false);
        }

        let pcm_bytes = match self.decoder.decode_frame(self.current_frame) {
            Ok(bytes) => bytes,
            Err(_) => return Ok(false),
        };

        self.current_frame += 1;

        if pcm_bytes.is_empty() {
            return Ok(true);
        }

        match self.bits_per_sample {
            16 => {
                let num_samples = pcm_bytes.len() / 2;
                out_pcm.reserve(num_samples);
                for chunk in pcm_bytes.chunks_exact(2) {
                    let s = i16::from_le_bytes([chunk[0], chunk[1]]);
                    out_pcm.push(s as f32 / 32768.0);
                }
            }
            24 => {
                let num_samples = pcm_bytes.len() / 3;
                out_pcm.reserve(num_samples);
                for chunk in pcm_bytes.chunks_exact(3) {
                    // Sign extend 24-bit little endian
                    let s = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], if (chunk[2] & 0x80) != 0 { 0xFF } else { 0x00 }]);
                    out_pcm.push(s as f32 / 8388608.0);
                }
            }
            32 => {
                let num_samples = pcm_bytes.len() / 4;
                out_pcm.reserve(num_samples);
                for chunk in pcm_bytes.chunks_exact(4) {
                    let s = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s as f32 / 2147483648.0);
                }
            }
            8 => {
                out_pcm.reserve(pcm_bytes.len());
                for &b in &pcm_bytes {
                    let s = (b as f32 - 128.0) / 128.0;
                    out_pcm.push(s);
                }
            }
            _ => return Err(SymphoniaError::Unsupported("unsupported APE bit depth")),
        }

        Ok(true)
    }
}
