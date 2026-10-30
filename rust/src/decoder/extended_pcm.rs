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
    _data_size: u64,
    current_frame: u64,
    total_frames: u64,
    duration_ms: u64,
    read_buf: Vec<u8>,
}

impl ExtendedPcmReader {
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        if let Err(_) = source.seek(SeekFrom::Start(0)) {
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let mut header = [0u8; 64];
        if source.read_exact(&mut header).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let is_rf64 = header.starts_with(b"RF64") && &header[8..12] == b"WAVE";
        let is_rifx = header.starts_with(b"RIFX") && &header[8..12] == b"WAVE";
        let is_w64 = header.starts_with(&W64_RIFF_GUID) && &header[24..40] == &W64_WAVE_GUID;

        if !is_rf64 && !is_rifx && !is_w64 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        if is_w64 {
            Self::parse_w64(source)
        } else if is_rifx {
            Self::parse_rifx(source)
        } else {
            Self::parse_rf64(source)
        }
    }

    fn parse_rf64(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        let mut p = 12u64;
        let mut ds64_data_size = 0u64;
        let mut fmt_parsed = false;
        let mut channels = 0u16;
        let mut sample_rate = 0u32;
        let mut block_align = 0u16;
        let mut bits_per_sample = 0u16;
        let mut is_float = false;
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
            let chunk_size = u32::from_le_bytes(chunk_hdr[4..8].try_into().unwrap()) as u64;

            if chunk_id == b"ds64" {
                let mut ds_buf = [0u8; 24];
                if source.read_exact(&mut ds_buf).is_ok() {
                    ds64_data_size = u64::from_le_bytes(ds_buf[8..16].try_into().unwrap());
                }
                p += 8 + chunk_size;
            } else if chunk_id == b"fmt " {
                let mut fmt_buf = [0u8; 16];
                if source.read_exact(&mut fmt_buf).is_ok() {
                    let audio_format = u16::from_le_bytes(fmt_buf[0..2].try_into().unwrap());
                    channels = u16::from_le_bytes(fmt_buf[2..4].try_into().unwrap());
                    sample_rate = u32::from_le_bytes(fmt_buf[4..8].try_into().unwrap());
                    block_align = u16::from_le_bytes(fmt_buf[12..14].try_into().unwrap());
                    bits_per_sample = u16::from_le_bytes(fmt_buf[14..16].try_into().unwrap());
                    is_float = audio_format == 3;
                    fmt_parsed = true;
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

        if !fmt_parsed || data_start == 0 || channels == 0 || sample_rate == 0 || block_align == 0 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let total_frames = data_size / block_align as u64;
        let duration_ms = (total_frames * 1000) / sample_rate as u64;

        if source.seek(SeekFrom::Start(data_start)).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        Ok(ExtendedPcmProbe::Matched(Self {
            source,
            sample_rate,
            channels: channels as u32,
            bits_per_sample,
            block_align,
            is_big_endian: false,
            is_float,
            data_start,
            _data_size: data_size,
            current_frame: 0,
            total_frames,
            duration_ms,
            read_buf: vec![0u8; 1024 * block_align as usize],
        }))
    }

    fn parse_rifx(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        let mut p = 12u64;
        let mut fmt_parsed = false;
        let mut channels = 0u16;
        let mut sample_rate = 0u32;
        let mut block_align = 0u16;
        let mut bits_per_sample = 0u16;
        let mut is_float = false;
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
            let chunk_size = u32::from_be_bytes(chunk_hdr[4..8].try_into().unwrap()) as u64;

            if chunk_id == b"fmt " {
                let mut fmt_buf = [0u8; 16];
                if source.read_exact(&mut fmt_buf).is_ok() {
                    let audio_format = u16::from_be_bytes(fmt_buf[0..2].try_into().unwrap());
                    channels = u16::from_be_bytes(fmt_buf[2..4].try_into().unwrap());
                    sample_rate = u32::from_be_bytes(fmt_buf[4..8].try_into().unwrap());
                    block_align = u16::from_be_bytes(fmt_buf[12..14].try_into().unwrap());
                    bits_per_sample = u16::from_be_bytes(fmt_buf[14..16].try_into().unwrap());
                    is_float = audio_format == 3;
                    fmt_parsed = true;
                }
                p += 8 + chunk_size;
            } else if chunk_id == b"data" {
                data_start = p + 8;
                data_size = chunk_size;
                break;
            } else {
                p += 8 + ((chunk_size + 1) & !1);
            }
        }

        if !fmt_parsed || data_start == 0 || channels == 0 || sample_rate == 0 || block_align == 0 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let total_frames = data_size / block_align as u64;
        let duration_ms = (total_frames * 1000) / sample_rate as u64;

        if source.seek(SeekFrom::Start(data_start)).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        Ok(ExtendedPcmProbe::Matched(Self {
            source,
            sample_rate,
            channels: channels as u32,
            bits_per_sample,
            block_align,
            is_big_endian: true,
            is_float,
            data_start,
            _data_size: data_size,
            current_frame: 0,
            total_frames,
            duration_ms,
            read_buf: vec![0u8; 1024 * block_align as usize],
        }))
    }

    fn parse_w64(mut source: Box<dyn MediaSource>) -> Result<ExtendedPcmProbe, SymphoniaError> {
        let mut p = 40u64;
        let mut fmt_parsed = false;
        let mut channels = 0u16;
        let mut sample_rate = 0u32;
        let mut block_align = 0u16;
        let mut bits_per_sample = 0u16;
        let mut is_float = false;
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

            if chunk_guid_prefix == &W64_FMT_PREFIX {
                let mut fmt_buf = [0u8; 16];
                if source.read_exact(&mut fmt_buf).is_ok() {
                    let audio_format = u16::from_le_bytes(fmt_buf[0..2].try_into().unwrap());
                    channels = u16::from_le_bytes(fmt_buf[2..4].try_into().unwrap());
                    sample_rate = u32::from_le_bytes(fmt_buf[4..8].try_into().unwrap());
                    block_align = u16::from_le_bytes(fmt_buf[12..14].try_into().unwrap());
                    bits_per_sample = u16::from_le_bytes(fmt_buf[14..16].try_into().unwrap());
                    is_float = audio_format == 3;
                    fmt_parsed = true;
                }
                p += (chunk_size + 7) & !7;
            } else if chunk_guid_prefix == &W64_DATA_PREFIX {
                data_start = p + 24;
                data_size = chunk_size - 24;
                break;
            } else {
                p += (chunk_size + 7) & !7;
            }
        }

        if !fmt_parsed || data_start == 0 || channels == 0 || sample_rate == 0 || block_align == 0 {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        let total_frames = data_size / block_align as u64;
        let duration_ms = (total_frames * 1000) / sample_rate as u64;

        if source.seek(SeekFrom::Start(data_start)).is_err() {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(ExtendedPcmProbe::NotMatched(source));
        }

        Ok(ExtendedPcmProbe::Matched(Self {
            source,
            sample_rate,
            channels: channels as u32,
            bits_per_sample,
            block_align,
            is_big_endian: false,
            is_float,
            data_start,
            _data_size: data_size,
            current_frame: 0,
            total_frames,
            duration_ms,
            read_buf: vec![0u8; 1024 * block_align as usize],
        }))
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u32 {
        self.channels
    }

    pub fn duration_ms(&self) -> Option<u64> {
        Some(self.duration_ms)
    }

    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        if self.current_frame >= self.total_frames {
            return Ok(false);
        }

        let remaining_frames = self.total_frames - self.current_frame;
        let frames_to_read = remaining_frames.min(1024) as usize;
        let bytes_to_read = frames_to_read * self.block_align as usize;

        if self.read_buf.len() < bytes_to_read {
            self.read_buf.resize(bytes_to_read, 0);
        }

        let buf_slice = &mut self.read_buf[..bytes_to_read];
        match self.source.read_exact(buf_slice) {
            Ok(_) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                return Ok(false);
            }
            Err(e) => return Err(SymphoniaError::IoError(e)),
        }

        out_pcm.clear();
        let total_samples = frames_to_read * self.channels as usize;
        out_pcm.reserve(total_samples);

        match (self.bits_per_sample, self.is_float, self.is_big_endian) {
            (16, false, false) => {
                for chunk in buf_slice.chunks_exact(2) {
                    let s = i16::from_le_bytes([chunk[0], chunk[1]]);
                    out_pcm.push(s as f32 / 32768.0);
                }
            }
            (16, false, true) => {
                for chunk in buf_slice.chunks_exact(2) {
                    let s = i16::from_be_bytes([chunk[0], chunk[1]]);
                    out_pcm.push(s as f32 / 32768.0);
                }
            }
            (24, false, false) => {
                for chunk in buf_slice.chunks_exact(3) {
                    let s = i32::from_le_bytes([0, chunk[0], chunk[1], chunk[2]]) >> 8;
                    out_pcm.push(s as f32 / 8388608.0);
                }
            }
            (24, false, true) => {
                for chunk in buf_slice.chunks_exact(3) {
                    let s = i32::from_be_bytes([chunk[0], chunk[1], chunk[2], 0]) >> 8;
                    out_pcm.push(s as f32 / 8388608.0);
                }
            }
            (32, false, false) => {
                for chunk in buf_slice.chunks_exact(4) {
                    let s = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s as f32 / 2147483648.0);
                }
            }
            (32, false, true) => {
                for chunk in buf_slice.chunks_exact(4) {
                    let s = i32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s as f32 / 2147483648.0);
                }
            }
            (32, true, false) => {
                for chunk in buf_slice.chunks_exact(4) {
                    let s = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s);
                }
            }
            (32, true, true) => {
                for chunk in buf_slice.chunks_exact(4) {
                    let s = f32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    out_pcm.push(s);
                }
            }
            _ => return Err(SymphoniaError::Unsupported("unsupported PCM bit depth")),
        }

        self.current_frame += frames_to_read as u64;
        Ok(true)
    }

    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let target_frame = ((position_ms as u128 * self.sample_rate as u128) / 1000) as u64;
        let target_frame = target_frame.min(self.total_frames);
        let target_byte = self.data_start + target_frame * self.block_align as u64;

        self.source
            .seek(SeekFrom::Start(target_byte))
            .map_err(SymphoniaError::IoError)?;

        self.current_frame = target_frame;
        Ok(())
    }
}
