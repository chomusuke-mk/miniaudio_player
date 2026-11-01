//! Monkey's Audio (`.ape`) decoder wrapper using pure-Rust `ape-decoder` and `PcmSampleNormalizer`.

use std::io::{Read, Seek, SeekFrom};
use ape_decoder::decoder::ApeDecoder;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;

use super::extended_pcm::PcmSampleNormalizer;

pub enum ApeProbe {
    Matched(ApeReader),
    NotMatched(Box<dyn MediaSource>),
}

pub struct ApeReader {
    decoder: ApeDecoder<Box<dyn MediaSource>>,
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u16,
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
        if source.read_exact(&mut magic).is_err() || &magic != b"MAC " {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ApeProbe::NotMatched(source));
        }

        let _ = source.seek(SeekFrom::Start(0));
        let decoder = ApeDecoder::new(source)
            .map_err(|_| SymphoniaError::Unsupported("malformed APE stream"))?;

        let info = decoder.info();
        let sample_rate = info.sample_rate;
        let channels = info.channels as u32;
        let bits_per_sample = info.bits_per_sample;
        let total_frames = decoder.total_frames();
        let duration_ms = if sample_rate > 0 {
            Some((info.total_samples as u64 * 1000) / sample_rate as u64)
        } else {
            None
        };

        Ok(ApeProbe::Matched(Self {
            decoder,
            sample_rate,
            channels,
            bits_per_sample,
            total_frames,
            current_frame: 0,
            duration_ms,
        }))
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
        let target_sample = ((position_ms as f64 / 1000.0) * self.sample_rate as f64) as u64;
        let seek_res = self
            .decoder
            .seek(target_sample)
            .map_err(|_| SymphoniaError::Unsupported("APE seek failed"))?;
        self.current_frame = seek_res.frame_index;
        Ok(())
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

        let bytes_per_sample = (self.bits_per_sample as usize / 8).max(1);
        out_pcm.reserve(pcm_bytes.len() / bytes_per_sample);
        PcmSampleNormalizer::decode_bytes(
            &pcm_bytes,
            self.bits_per_sample,
            false,
            false,
            out_pcm,
        )?;
        Ok(true)
    }
}
