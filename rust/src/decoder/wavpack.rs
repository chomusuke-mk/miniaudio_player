//! WavPack (.wv) decoder wrapper using pure-Rust `wavicle`.

use std::io::{Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;
use wavicle::decode::decode_stream;

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
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<WavpackProbe, SymphoniaError> {
        if source.seek(SeekFrom::Start(0)).is_err() {
            return Ok(WavpackProbe::NotMatched(source));
        }

        let mut magic = [0u8; 4];
        if source.read_exact(&mut magic).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(WavpackProbe::NotMatched(source));
        }

        if &magic != b"wvpk" {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(WavpackProbe::NotMatched(source));
        }

        let _ = source.seek(SeekFrom::Start(0));

        let mut data = Vec::new();
        if source.read_to_end(&mut data).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Err(SymphoniaError::Unsupported("failed to read WavPack stream"));
        }

        // Calculate exact audio end by following block chains (ignoring trailing APEv2 / ID3 tags)
        let mut audio_end = 0;
        while audio_end + 8 <= data.len() && &data[audio_end..audio_end + 4] == b"wvpk" {
            let ck_size = u32::from_le_bytes(data[audio_end + 4..audio_end + 8].try_into().unwrap()) as usize;
            audio_end += 8 + ck_size;
        }

        let slice = if audio_end > 0 && audio_end <= data.len() {
            &data[..audio_end]
        } else {
            &data[..]
        };

        let decoded = match decode_stream(slice) {
            Ok(d) => d,
            Err(_) => {
                let _ = source.seek(SeekFrom::Start(0));
                return Err(SymphoniaError::Unsupported("malformed WavPack stream"));
            }
        };

        let sample_rate = decoded.sample_rate;
        let channels = decoded.channels;
        let bits = decoded.bits_per_sample;
        let is_float = decoded.is_float;

        if channels == 0 || sample_rate == 0 {
            return Err(SymphoniaError::Unsupported("invalid WavPack stream parameters"));
        }

        let total_samples = decoded.samples.len();
        let total_frames = total_samples / channels as usize;

        let mut samples_f32 = Vec::with_capacity(total_samples);

        if is_float {
            for &s in &decoded.samples {
                samples_f32.push(f32::from_bits(s as u32));
            }
        } else {
            let divisor = match bits {
                8 => 128.0,
                16 => 32768.0,
                24 => 8388608.0,
                32 => 2147483648.0,
                _ => 32768.0,
            };
            for &s in &decoded.samples {
                samples_f32.push(s as f32 / divisor);
            }
        }

        let duration_ms = if sample_rate > 0 {
            Some((total_frames as u64 * 1000) / sample_rate as u64)
        } else {
            None
        };

        Ok(WavpackProbe::Matched(WavpackReader {
            sample_rate,
            channels,
            samples_f32,
            current_frame: 0,
            total_frames,
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
        let target_frame = (sec * self.sample_rate as f64) as usize;

        self.current_frame = target_frame.min(self.total_frames);
        Ok(())
    }

    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();

        if self.current_frame >= self.total_frames {
            return Ok(false);
        }

        // Deliver up to 1024 frames per decode call
        let frames_to_deliver = 1024.min(self.total_frames - self.current_frame);
        let channels = self.channels as usize;
        let start_sample = self.current_frame * channels;
        let end_sample = start_sample + frames_to_deliver * channels;

        out_pcm.extend_from_slice(&self.samples_f32[start_sample..end_sample]);
        self.current_frame += frames_to_deliver;

        Ok(true)
    }
}
