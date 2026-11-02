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

/// Deterministic black-box PCM byte-to-f32 sample converter.
pub struct PcmSampleNormalizer;

impl PcmSampleNormalizer {
    pub fn decode_bytes(
        buf: &[u8],
        bits_per_sample: u16,
        is_float: bool,
        is_big_endian: bool,
        out_pcm: &mut Vec<f32>,
    ) -> Result<(), SymphoniaError> {
        match (bits_per_sample, is_float, is_big_endian) {
            (8, false, _) => {
                for &b in buf {
                    out_pcm.push((b as f32 - 128.0) / 128.0);
                }
            }
            (16, false, false) => {
                for chunk in buf.chunks_exact(2) {
                    let s = i16::from_le_bytes([chunk[0], chunk[1]]);
                    out_pcm.push(s as f32 / 32768.0);
                }
            }
            (16, false, true) => {
                for chunk in buf.chunks_exact(2) {
                    let s = i16::from_be_bytes([chunk[0], chunk[1]]);
                    out_pcm.push(s as f32 / 32768.0);
                }
            }
            (24, false, false) => {
                for chunk in buf.chunks_exact(3) {
                    let sign = if (chunk[2] & 0x80) != 0 { 0xFF } else { 0x00 };
                    let s = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], sign]);
                    out_pcm.push(s as f32 / 8388608.0);
                }
            }
            (24, false, true) => {
                for chunk in buf.chunks_exact(3) {
                    let s = i32::from_be_bytes([chunk[0], chunk[1], chunk[2], 0]) >> 8;
                    out_pcm.push(s as f32 / 8388608.0);
                }
            }
            (32, false, false) => {
                for chunk in buf.chunks_exact(4) {
                    let s = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s as f32 / 2147483648.0);
                }
            }
            (32, false, true) => {
                for chunk in buf.chunks_exact(4) {
                    let s = i32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s as f32 / 2147483648.0);
                }
            }
            (32, true, false) => {
                for chunk in buf.chunks_exact(4) {
                    out_pcm.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
                }
            }
            (32, true, true) => {
                for chunk in buf.chunks_exact(4) {
                    out_pcm.push(f32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
                }
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

pub enum ExtendedPcmProbe {
    Matched(ExtendedPcmReader),
    NotMatched(Box<dyn MediaSource>),
}

pub struct ExtendedPcmReader {
    source: Box<dyn MediaSource>,
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u16,
    block_align: u16,
    is_big_endian: bool,
    is_float: bool,
    data_start: u64,
    current_frame: u64,
    total_frames: u64,
    duration_ms: u64,
    read_buf: Vec<u8>,
}

impl ExtendedPcmReader {
    pub const FRAMES_PER_BLOCK: usize = 1024;

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
            Self::parse_riff_variant(source, true)
        } else if header.starts_with(b"RF64") && &header[8..12] == b"WAVE" {
            Self::parse_riff_variant(source, false)
        } else {
            let _ = source.seek(SeekFrom::Start(0));
            Ok(ExtendedPcmProbe::NotMatched(source))
        }
    }

    fn build_from_spec(
        mut source: Box<dyn MediaSource>,
        fmt: WaveFmtSpec,
        is_big_endian: bool,
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

        Self::build_from_spec(source, fmt, is_big_endian, data_start, data_size)
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

        Self::build_from_spec(source, fmt, false, data_start, data_size)
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
        Some(self.duration_ms)
    }

    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        if self.current_frame >= self.total_frames {
            return Ok(false);
        }

        let remaining_frames = self.total_frames - self.current_frame;
        let frames_to_read = remaining_frames.min(Self::FRAMES_PER_BLOCK as u64) as usize;
        let bytes_to_read = frames_to_read * self.block_align as usize;

        if self.read_buf.len() < bytes_to_read {
            self.read_buf.resize(bytes_to_read, 0);
        }

        let buf_slice = &mut self.read_buf[..bytes_to_read];
        match self.source.read_exact(buf_slice) {
            Ok(_) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(false),
            Err(e) => return Err(SymphoniaError::IoError(e)),
        }

        out_pcm.clear();
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
