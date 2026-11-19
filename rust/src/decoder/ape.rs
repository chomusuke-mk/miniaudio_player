//! Monkey's Audio (`.ape`) decoder wrapper using pure-Rust `ape-decoder` and `PcmSampleNormalizer`.

use ape_decoder::decoder::ApeDecoder;
use ape_decoder::error::ApeError;
use std::io::{Error as IoError, ErrorKind, Read, Result as IoResult, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;

use super::extended_pcm::PcmSampleNormalizer;

/// Ensures `Read::read` fills the full requested slice unless EOF (`Ok(0)`) is reached,
/// preventing `ape-decoder::read_frame_data` from failing with `"short read on frame data"`
/// across circular ring buffer wrap boundaries or incremental HTTP chunks.
struct FullReadSource(Box<dyn MediaSource>);

impl Read for FullReadSource {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        let mut total = 0usize;
        while total < buf.len() {
            match self.0.read(&mut buf[total..]) {
                Ok(0) => break,
                Ok(n) => total += n,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => {
                    if total > 0 {
                        return Ok(total);
                    }
                    return Err(e);
                }
            }
        }
        Ok(total)
    }
}

impl Seek for FullReadSource {
    fn seek(&mut self, pos: SeekFrom) -> IoResult<u64> {
        self.0.seek(pos)
    }
}

impl MediaSource for FullReadSource {
    #[inline]
    fn is_seekable(&self) -> bool {
        self.0.is_seekable()
    }

    #[inline]
    fn byte_len(&self) -> Option<u64> {
        self.0.byte_len()
    }
}

/// Result of probing a media source for Monkey's Audio (`.ape`) container format.
pub enum ApeProbe {
    /// Source matched Monkey's Audio format and initialized an `ApeReader`.
    Matched(ApeReader),
    /// Source did not match Monkey's Audio; stream was rewound and returned.
    NotMatched(Box<dyn MediaSource>),
}

/// Decoder reader parsing and decoding Monkey's Audio (`.ape`) frames into normalized float PCM.
pub struct ApeReader {
    decoder: ApeDecoder<FullReadSource>,
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u16,
    total_frames: u32,
    current_frame: u32,
    pending_skip_samples: usize,
    duration_ms: Option<u64>,
}

impl ApeReader {
    /// Attempts to probe magic bytes and initialize an `ApeReader` from a media source.
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
        let decoder = ApeDecoder::new(FullReadSource(source)).map_err(Self::map_ape_err)?;

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
            pending_skip_samples: 0,
            duration_ms,
        }))
    }

    fn map_ape_err(err: ApeError) -> SymphoniaError {
        match err {
            ApeError::Io(io_err) => SymphoniaError::IoError(io_err),
            ApeError::InvalidFormat(msg) | ApeError::DecodingError(msg) => {
                SymphoniaError::DecodeError(msg)
            }
            ApeError::InvalidChecksum => SymphoniaError::DecodeError("APE invalid frame checksum"),
            ApeError::UnsupportedVersion(_) => {
                SymphoniaError::Unsupported("unsupported APE version")
            }
            _ => SymphoniaError::DecodeError("APE decoder failure"),
        }
    }

    /// Returns the audio sample rate in Hz.
    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Returns the number of audio channels.
    #[inline]
    pub fn channels(&self) -> u32 {
        self.channels
    }

    /// Returns the bit depth per sample (e.g. 16, 24).
    #[inline]
    pub fn bits_per_sample(&self) -> u32 {
        self.bits_per_sample as u32
    }

    /// Returns the total duration in milliseconds if known.
    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    /// Seeks to the specified position in milliseconds.
    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let target_sample = ((position_ms as f64 / 1000.0) * self.sample_rate as f64) as u64;
        let seek_res = self.decoder.seek(target_sample).map_err(Self::map_ape_err)?;
        self.current_frame = seek_res.frame_index;
        self.pending_skip_samples = seek_res.skip_samples as usize;
        Ok(())
    }

    /// Exports exact `(frame_start_byte_offset, frame_start_ms)` anchors from the APE header
    /// seek table plus a terminal sentinel for accurate seek and buffered-range boundary snapping.
    pub fn frame_anchors(&self) -> Vec<(u64, i64)> {
        let fi = self.decoder.file_info();
        let total = self.total_frames;
        let sr = self.sample_rate.max(1) as u128;
        let mut out = Vec::with_capacity(total as usize + 1);
        for frame_idx in 0..total {
            let rem = self.decoder.seek_remainder(frame_idx) as u64;
            let byte_off = fi.seek_byte(frame_idx).saturating_sub(rem);
            let sample = frame_idx as u64 * fi.header.blocks_per_frame as u64;
            let ms = ((sample as u128 * 1000) / sr) as i64;
            out.push((byte_off, ms));
        }
        if total > 0 {
            let last = total - 1;
            let end_byte = fi
                .seek_byte(last)
                .saturating_add(fi.frame_byte_count(last));
            let dur_ms = self.duration_ms.map(|d| d as i64).unwrap_or_else(|| {
                let sample = fi.total_blocks.max(0) as u64;
                ((sample as u128 * 1000) / sr) as i64
            });
            out.push((end_byte, dur_ms));
        }
        out
    }

    /// Returns `(read_start_byte, read_end_byte)` required by `ApeDecoder::read_frame_data` for `current_frame`.
    pub fn current_frame_byte_range(&self) -> Option<(u64, u64)> {
        if self.current_frame >= self.total_frames {
            return None;
        }
        let fi = self.decoder.file_info();
        let rem = self.decoder.seek_remainder(self.current_frame) as u64;
        let start = fi.seek_byte(self.current_frame).saturating_sub(rem);
        let frame_bytes = fi.frame_byte_count(self.current_frame);
        let end = fi
            .seek_byte(self.current_frame)
            .saturating_add(frame_bytes)
            .saturating_add(4);
        Some((start, end))
    }

    /// Decodes the next audio frame into the output normalized float PCM buffer.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        loop {
            out_pcm.clear();
            if self.current_frame >= self.total_frames {
                return Ok(false);
            }

            let pcm_bytes = match self.decoder.decode_frame(self.current_frame) {
                Ok(bytes) => bytes,
                Err(ApeError::Io(io_err)) => {
                    return Err(SymphoniaError::IoError(IoError::new(
                        io_err.kind(),
                        io_err.to_string(),
                    )));
                }
                Err(other) => return Err(Self::map_ape_err(other)),
            };
            self.current_frame += 1;

            if pcm_bytes.is_empty() {
                continue;
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

            if self.pending_skip_samples > 0 {
                let skip_floats = self
                    .pending_skip_samples
                    .saturating_mul(self.channels.max(1) as usize);
                self.pending_skip_samples = 0;
                if skip_floats >= out_pcm.len() {
                    out_pcm.clear();
                    continue;
                }
                out_pcm.drain(..skip_floats);
            }
            return Ok(true);
        }
    }
}
