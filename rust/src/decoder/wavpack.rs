//! WavPack (`.wv`) decoder wrapper using pure-Rust `wavicle`.

use std::io::{Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;
use wavicle::decode::decode_stream;

struct WavpackStreamParser;

impl WavpackStreamParser {
    /// Calculates the exact audio boundary by walking `"wvpk"` block headers,
    /// deterministically excluding trailing APEv2 or ID3v1 metadata tags.
    fn strip_trailing_tags(data: &[u8]) -> &[u8] {
        let mut audio_end = 0usize;
        while audio_end + 8 <= data.len() && &data[audio_end..audio_end + 4] == b"wvpk" {
            let ck_size =
                u32::from_le_bytes(data[audio_end + 4..audio_end + 8].try_into().unwrap()) as usize;
            let next = audio_end + 8 + ck_size;
            if next > data.len() {
                break;
            }
            audio_end = next;
        }
        if audio_end > 0 {
            &data[..audio_end]
        } else {
            data
        }
    }

    /// Deterministically normalizes decoded WavPack samples into `[-1.0, 1.0]` `f32` PCM.
    fn normalize_samples(
        samples: &[i32],
        bits_per_sample: u32,
        is_float: bool,
    ) -> Result<Vec<f32>, SymphoniaError> {
        let mut out = Vec::with_capacity(samples.len());
        if is_float {
            for &s in samples {
                out.push(f32::from_bits(s as u32));
            }
            return Ok(out);
        }

        let divisor = match bits_per_sample {
            8 => 128.0f32,
            16 => 32768.0f32,
            24 => 8388608.0f32,
            32 => 2147483648.0f32,
            _ => {
                return Err(SymphoniaError::Unsupported(
                    "unsupported WavPack bit depth",
                ))
            }
        };

        for &s in samples {
            out.push(s as f32 / divisor);
        }
        Ok(out)
    }
}

pub enum WavpackProbe {
    Matched(WavpackReader),
    NotMatched(Box<dyn MediaSource>),
}

pub struct WavpackReader {
    sample_rate: u32,
    channels: u32,
    samples_f32: Vec<f32>,
    current_frame: usize,
    total_frames: usize,
    duration_ms: Option<u64>,
}

impl WavpackReader {
    pub const FRAMES_PER_CHUNK: usize = 1024;

    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<WavpackProbe, SymphoniaError> {
        if source.seek(SeekFrom::Start(0)).is_err() {
            return Ok(WavpackProbe::NotMatched(source));
        }

        let mut magic = [0u8; 4];
        if source.read_exact(&mut magic).is_err() || &magic != b"wvpk" {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(WavpackProbe::NotMatched(source));
        }

        let _ = source.seek(SeekFrom::Start(0));
        let mut raw_bytes = Vec::new();
        source
            .read_to_end(&mut raw_bytes)
            .map_err(|_| SymphoniaError::Unsupported("failed to read WavPack stream"))?;

        let clean_slice = WavpackStreamParser::strip_trailing_tags(&raw_bytes);
        let decoded = decode_stream(clean_slice)
            .map_err(|_| SymphoniaError::Unsupported("malformed WavPack stream"))?;

        if decoded.channels == 0 || decoded.sample_rate == 0 {
            return Err(SymphoniaError::Unsupported(
                "invalid WavPack stream parameters",
            ));
        }

        let samples_f32 = WavpackStreamParser::normalize_samples(
            &decoded.samples,
            decoded.bits_per_sample,
            decoded.is_float,
        )?;
        let total_frames = samples_f32.len() / decoded.channels as usize;
        let duration_ms = Some((total_frames as u64 * 1000) / decoded.sample_rate as u64);

        Ok(WavpackProbe::Matched(Self {
            sample_rate: decoded.sample_rate,
            channels: decoded.channels,
            samples_f32,
            current_frame: 0,
            total_frames,
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
        let target_frame = ((position_ms as f64 / 1000.0) * self.sample_rate as f64) as usize;
        self.current_frame = target_frame.min(self.total_frames);
        Ok(())
    }

    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();
        if self.current_frame >= self.total_frames {
            return Ok(false);
        }

        let frames_to_deliver = Self::FRAMES_PER_CHUNK.min(self.total_frames - self.current_frame);
        let channels = self.channels as usize;
        let start_sample = self.current_frame * channels;
        let end_sample = start_sample + frames_to_deliver * channels;

        out_pcm.extend_from_slice(&self.samples_f32[start_sample..end_sample]);
        self.current_frame += frames_to_deliver;
        Ok(true)
    }
}
