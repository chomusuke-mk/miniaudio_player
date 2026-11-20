//! Deterministic Extended PCM Container Reader (`RF64`, `RIFX`, `W64`) & Sample Normalizer.

use std::io::{Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;

const W64_RIFF_GUID: [u8; 16] = [
    0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00, 0x00,
];
const W64_WAVE_GUID: [u8; 16] = [
    0x77, 0x61, 0x76, 0x65, 0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0x00, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a,
];
const W64_FMT_PREFIX: [u8; 4] = [0x66, 0x6d, 0x74, 0x20];
const W64_DATA_PREFIX: [u8; 4] = [0x64, 0x61, 0x74, 0x61];

/// Deterministic black-box PCM byte-to-f32 sample converter supporting 8/16/24/32-bit int and float.
pub struct PcmSampleNormalizer;

impl PcmSampleNormalizer {
    /// Decodes raw PCM bytes of the specified bit depth and endianness into normalized `f32` samples (-1.0 to +1.0).
    pub fn decode_bytes(
        buf: &[u8],
        bits_per_sample: u16,
        is_float: bool,
        is_big_endian: bool,
        out_pcm: &mut Vec<f32>,
    ) -> Result<(), SymphoniaError> {
        match (bits_per_sample, is_float, is_big_endian) {
            (8, false, _) => {
                const INV_128: f32 = 1.0 / 128.0;
                out_pcm.reserve(buf.len());
                out_pcm.extend(buf.iter().map(|&b| (b as f32 - 128.0) * INV_128));
            }
            (16, false, false) => {
                const INV_32768: f32 = 1.0 / 32768.0;
                out_pcm.reserve(buf.len() / 2);
                out_pcm.extend(
                    buf.chunks_exact(2)
                        .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 * INV_32768),
                );
            }
            (16, false, true) => {
                const INV_32768: f32 = 1.0 / 32768.0;
                out_pcm.reserve(buf.len() / 2);
                out_pcm.extend(
                    buf.chunks_exact(2)
                        .map(|c| i16::from_be_bytes([c[0], c[1]]) as f32 * INV_32768),
                );
            }
            (24, false, false) => {
                const INV_8M: f32 = 1.0 / 8388608.0;
                out_pcm.reserve(buf.len() / 3);
                out_pcm.extend(buf.chunks_exact(3).map(|c| {
                    let sign = if (c[2] & 0x80) != 0 { 0xFF } else { 0x00 };
                    i32::from_le_bytes([c[0], c[1], c[2], sign]) as f32 * INV_8M
                }));
            }
            (24, false, true) => {
                const INV_8M: f32 = 1.0 / 8388608.0;
                out_pcm.reserve(buf.len() / 3);
                out_pcm.extend(buf.chunks_exact(3).map(|c| {
                    (i32::from_be_bytes([c[0], c[1], c[2], 0]) >> 8) as f32 * INV_8M
                }));
            }
            (32, false, false) => {
                const INV_2G: f32 = 1.0 / 2147483648.0;
                out_pcm.reserve(buf.len() / 4);
                out_pcm.extend(
                    buf.chunks_exact(4)
                        .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f32 * INV_2G),
                );
            }
            (32, false, true) => {
                const INV_2G: f32 = 1.0 / 2147483648.0;
                out_pcm.reserve(buf.len() / 4);
                out_pcm.extend(
                    buf.chunks_exact(4)
                        .map(|c| i32::from_be_bytes([c[0], c[1], c[2], c[3]]) as f32 * INV_2G),
                );
            }
            (32, true, false) => {
                out_pcm.reserve(buf.len() / 4);
                out_pcm.extend(
                    buf.chunks_exact(4)
                        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])),
                );
            }
            (32, true, true) => {
                out_pcm.reserve(buf.len() / 4);
                out_pcm.extend(
                    buf.chunks_exact(4)
                        .map(|c| f32::from_be_bytes([c[0], c[1], c[2], c[3]])),
                );
            }
            _ => return Err(SymphoniaError::Unsupported("unsupported PCM bit depth")),
        }
        Ok(())
    }
}

#[derive(Default)]
struct WaveFmtSpec {
    channels: u16,
    sample_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    is_float: bool,
    valid: bool,
}

impl WaveFmtSpec {
    fn parse(fmt_buf: &[u8; 16], is_big_endian: bool) -> Self {
        let u16_fn = if is_big_endian {
            u16::from_be_bytes
        } else {
            u16::from_le_bytes
        };
        let u32_fn = if is_big_endian {
            u32::from_be_bytes
        } else {
            u32::from_le_bytes
        };

        let audio_format = u16_fn([fmt_buf[0], fmt_buf[1]]);
        let channels = u16_fn([fmt_buf[2], fmt_buf[3]]);
        let sample_rate = u32_fn([fmt_buf[4], fmt_buf[5], fmt_buf[6], fmt_buf[7]]);
        let block_align = u16_fn([fmt_buf[12], fmt_buf[13]]);
        let bits_per_sample = u16_fn([fmt_buf[14], fmt_buf[15]]);

        Self {
            channels,
            sample_rate,
            block_align,
            bits_per_sample,
            is_float: audio_format == 3,
            valid: channels > 0 && sample_rate > 0 && block_align > 0 && bits_per_sample > 0,
        }
    }
}

/// Result of probing a media source for extended PCM formats (`RF64`, `RIFX`, `W64`).
pub enum ExtendedPcmProbe {
    /// Source matched an extended PCM format and initialized an `ExtendedPcmReader`.
    Matched(ExtendedPcmReader),
    /// Source did not match; stream was rewound and returned.
    NotMatched(Box<dyn MediaSource>),
}

/// Decoder reader parsing and decoding extended PCM containers (`RF64`, `RIFX`, `W64`).
pub struct ExtendedPcmReader {
    source: Box<dyn MediaSource>,
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u16,
    block_align: u16,
    is_big_endian: bool,
    is_float: bool,
    container_format: &'static str,
    data_start: u64,
    current_frame: u64,
    total_frames: u64,
    duration_ms: u64,
    read_buf: Vec<u8>,
}

impl ExtendedPcmReader {
    /// Number of audio frames read in each I/O batch.
    pub const FRAMES_PER_BLOCK: usize = 1024;

    /// Attempts to identify container signatures and initialize an `ExtendedPcmReader`.
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        if source.seek(SeekFrom::Start(0)).is_err() {
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let mut header = [0u8; 64];
        if source.read_exact(&mut header).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        if header.starts_with(&W64_RIFF_GUID) && header[24..40] == W64_WAVE_GUID {
            Self::parse_w64(source)
        } else if header.starts_with(b"RIFX") && &header[8..12] == b"WAVE" {
            Self::parse_riff_variant(source, true, "RIFX")
        } else if header.starts_with(b"RF64") && &header[8..12] == b"WAVE" {
            Self::parse_riff_variant(source, false, "RF64")
        } else if header.starts_with(b"caff") && u16::from_be_bytes([header[4], header[5]]) == 1 {
            Self::parse_caf(source)
        } else {
            let _ = source.seek(SeekFrom::Start(0));
            Ok(ExtendedPcmProbe::NotMatched(source))
        }
    }

    fn build_from_spec(
        mut source: Box<dyn MediaSource>,
        fmt: WaveFmtSpec,
        is_big_endian: bool,
        container_format: &'static str,
        data_start: u64,
        data_size: u64,
    ) -> Result<ExtendedPcmProbe, SymphoniaError> {
        if !fmt.valid || data_start == 0 || source.seek(SeekFrom::Start(data_start)).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let total_frames = data_size / fmt.block_align as u64;
        let duration_ms = (total_frames * 1000) / fmt.sample_rate as u64;

        Ok(ExtendedPcmProbe::Matched(Self {
            source,
            sample_rate: fmt.sample_rate,
            channels: fmt.channels as u32,
            bits_per_sample: fmt.bits_per_sample,
            block_align: fmt.block_align,
            is_big_endian,
            is_float: fmt.is_float,
            container_format,
            data_start,
            current_frame: 0,
            total_frames,
            duration_ms,
            read_buf: vec![0u8; Self::FRAMES_PER_BLOCK * fmt.block_align as usize],
        }))
    }

    fn parse_riff_variant(
        mut source: Box<dyn MediaSource>,
        is_big_endian: bool,
        container_format: &'static str,
    ) -> Result<ExtendedPcmProbe, SymphoniaError> {
        let mut p = 12u64;
        let mut ds64_data_size = 0u64;
        let mut fmt = WaveFmtSpec::default();
        let mut data_start = 0u64;
        let mut data_size = 0u64;

        loop {
            if source.seek(SeekFrom::Start(p)).is_err() {
                break;
            }
            let mut chunk_hdr = [0u8; 8];
            if source.read_exact(&mut chunk_hdr).is_err() {
                break;
            }
            let chunk_id = &chunk_hdr[0..4];
            let size_bytes = [chunk_hdr[4], chunk_hdr[5], chunk_hdr[6], chunk_hdr[7]];
            let chunk_size = if is_big_endian {
                u32::from_be_bytes(size_bytes) as u64
            } else {
                u32::from_le_bytes(size_bytes) as u64
            };

            if !is_big_endian && chunk_id == b"ds64" {
                let mut ds_buf = [0u8; 24];
                if source.read_exact(&mut ds_buf).is_ok() {
                    ds64_data_size = u64::from_le_bytes(ds_buf[8..16].try_into().unwrap());
                }
                p += 8 + chunk_size;
            } else if chunk_id == b"fmt " {
                let mut fmt_buf = [0u8; 16];
                if source.read_exact(&mut fmt_buf).is_ok() {
                    fmt = WaveFmtSpec::parse(&fmt_buf, is_big_endian);
                }
                p += 8 + chunk_size;
            } else if chunk_id == b"data" {
                data_start = p + 8;
                data_size = if ds64_data_size > 0 {
                    ds64_data_size
                } else {
                    chunk_size
                };
                break;
            } else {
                p += 8 + ((chunk_size + 1) & !1);
            }
        }

        Self::build_from_spec(
            source,
            fmt,
            is_big_endian,
            container_format,
            data_start,
            data_size,
        )
    }

    fn parse_w64(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        let mut p = 40u64;
        let mut fmt = WaveFmtSpec::default();
        let mut data_start = 0u64;
        let mut data_size = 0u64;

        loop {
            if source.seek(SeekFrom::Start(p)).is_err() {
                break;
            }
            let mut chunk_hdr = [0u8; 24];
            if source.read_exact(&mut chunk_hdr).is_err() {
                break;
            }
            let chunk_guid_prefix = &chunk_hdr[0..4];
            let chunk_size = u64::from_le_bytes(chunk_hdr[16..24].try_into().unwrap());
            if chunk_size < 24 {
                break;
            }

            if chunk_guid_prefix == W64_FMT_PREFIX {
                let mut fmt_buf = [0u8; 16];
                if source.read_exact(&mut fmt_buf).is_ok() {
                    fmt = WaveFmtSpec::parse(&fmt_buf, false);
                }
                p += (chunk_size + 7) & !7;
            } else if chunk_guid_prefix == W64_DATA_PREFIX {
                data_start = p + 24;
                data_size = chunk_size - 24;
                break;
            } else {
                p += (chunk_size + 7) & !7;
            }
        }

        Self::build_from_spec(source, fmt, false, "W64", data_start, data_size)
    }

    fn parse_caf(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        let mut p = 8u64;
        let mut fmt = WaveFmtSpec::default();
        let mut is_big_endian = true;
        let mut data_start = 0u64;
        let mut data_size = 0u64;

        loop {
            if source.seek(SeekFrom::Start(p)).is_err() {
                break;
            }
            let mut chunk_hdr = [0u8; 12];
            if source.read_exact(&mut chunk_hdr).is_err() {
                break;
            }
            let chunk_id = &chunk_hdr[0..4];
            let chunk_size = i64::from_be_bytes(chunk_hdr[4..12].try_into().unwrap());
            let body_pos = p + 12;

            if chunk_id == b"desc" && chunk_size >= 32 {
                let mut desc = [0u8; 32];
                if source.read_exact(&mut desc).is_err() {
                    break;
                }
                let sr_f64 = f64::from_be_bytes(desc[0..8].try_into().unwrap());
                let format_id = &desc[8..12];
                let format_flags = u32::from_be_bytes(desc[12..16].try_into().unwrap());
                let bytes_per_packet = u32::from_be_bytes(desc[16..20].try_into().unwrap());
                let frames_per_packet = u32::from_be_bytes(desc[20..24].try_into().unwrap());
                let channels_per_frame = u32::from_be_bytes(desc[24..28].try_into().unwrap());
                let bits_per_channel = u32::from_be_bytes(desc[28..32].try_into().unwrap());

                if format_id != b"lpcm" {
                    let _ = source.seek(SeekFrom::Start(0));
                    return Ok(ExtendedPcmProbe::NotMatched(source));
                }

                let is_float = (format_flags & 1) != 0;
                is_big_endian = (format_flags & 2) == 0;
                let sr = if sr_f64.is_finite() && sr_f64 > 0.0 && sr_f64 <= u32::MAX as f64 {
                    sr_f64.round() as u32
                } else {
                    0
                };
                let bits_supported = if is_float {
                    bits_per_channel == 32
                } else {
                    matches!(bits_per_channel, 16 | 24 | 32)
                };
                let block_align = if bytes_per_packet > 0 {
                    bytes_per_packet
                } else {
                    (bits_per_channel / 8).saturating_mul(channels_per_frame)
                };
                if sr == 0
                    || channels_per_frame == 0
                    || frames_per_packet != 1
                    || !bits_supported
                    || block_align == 0
                    || block_align > u16::MAX as u32
                    || channels_per_frame > u16::MAX as u32
                {
                    let _ = source.seek(SeekFrom::Start(0));
                    return Ok(ExtendedPcmProbe::NotMatched(source));
                }

                fmt = WaveFmtSpec {
                    channels: channels_per_frame as u16,
                    sample_rate: sr,
                    block_align: block_align as u16,
                    bits_per_sample: bits_per_channel as u16,
                    is_float,
                    valid: true,
                };
            } else if chunk_id == b"data" {
                // Skip 4-byte `mEditCount` and stop before payload without draining audio bytes.
                data_start = body_pos + 4;
                if chunk_size >= 4 {
                    let declared = (chunk_size - 4) as u64;
                    data_size = if let Some(total) = source.byte_len() {
                        declared.min(total.saturating_sub(data_start))
                    } else {
                        declared
                    };
                } else if chunk_size == -1 {
                    data_size = source
                        .byte_len()
                        .unwrap_or(0)
                        .saturating_sub(data_start);
                }
                break;
            }

            if chunk_size < 0 {
                break;
            }
            match body_pos.checked_add(chunk_size as u64) {
                Some(next) if next > p => p = next,
                _ => break,
            }
        }

        Self::build_from_spec(
            source,
            fmt,
            is_big_endian,
            "CAF",
            data_start,
            data_size,
        )
    }

    /// Returns the audio sample rate in Hz.
    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Returns the audio channel count.
    #[inline]
    pub fn channels(&self) -> u32 {
        self.channels
    }

    /// Returns the bit depth per sample (e.g. 8, 16, 24, 32).
    #[inline]
    pub fn bits_per_sample(&self) -> u32 {
        self.bits_per_sample as u32
    }

    /// Returns the canonical container format string (`"RF64"`, `"RIFX"`, or `"W64"`).
    #[inline]
    pub fn container_format(&self) -> &'static str {
        self.container_format
    }

    /// Returns total stream duration in milliseconds if known.
    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        Some(self.duration_ms)
    }

    /// Decodes the next block of PCM audio frames into the output buffer.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();
        self.decode_next_frame_append(out_pcm)
    }

    /// Decodes the next block of PCM audio frames, appending directly to `out_pcm`.
    pub fn decode_next_frame_append(
        &mut self,
        out_pcm: &mut Vec<f32>,
    ) -> Result<bool, SymphoniaError> {
        if self.current_frame >= self.total_frames {
            return Ok(false);
        }

        let remaining_frames = self.total_frames - self.current_frame;
        let frames_to_read = remaining_frames.min(Self::FRAMES_PER_BLOCK as u64) as usize;
        let bytes_to_read = frames_to_read * self.block_align as usize;

        if self.read_buf.len() < bytes_to_read {
            self.read_buf.resize(bytes_to_read, 0);
        }

        let expected_pos = self.data_start + self.current_frame * self.block_align as u64;
        self.source
            .seek(SeekFrom::Start(expected_pos))
            .map_err(SymphoniaError::IoError)?;

        let buf_slice = &mut self.read_buf[..bytes_to_read];
        match super::read_exact_resilient(&mut *self.source, buf_slice) {
            Ok(()) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(false),
            Err(e) => {
                let _ = self.source.seek(SeekFrom::Start(expected_pos));
                return Err(SymphoniaError::IoError(e));
            }
        }

        out_pcm.reserve(frames_to_read * self.channels as usize);
        PcmSampleNormalizer::decode_bytes(
            buf_slice,
            self.bits_per_sample,
            self.is_float,
            self.is_big_endian,
            out_pcm,
        )?;

        self.current_frame += frames_to_read as u64;
        Ok(true)
    }

    /// Seeks to the specified position in milliseconds within the audio data chunk.
    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let target_frame = ((position_ms as u128 * self.sample_rate as u128) / 1000) as u64;
        let clamped_frame = target_frame.min(self.total_frames);
        let target_byte = self.data_start + clamped_frame * self.block_align as u64;

        self.source
            .seek(SeekFrom::Start(target_byte))
            .map_err(SymphoniaError::IoError)?;

        self.current_frame = clamped_frame;
        Ok(())
    }
}
