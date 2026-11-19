//! Streaming WavPack (`.wv`) decoder wrapper using pure-Rust `wavicle`.

use std::io::{ErrorKind, Read, Seek, SeekFrom};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::io::MediaSource;
use wavicle::block::{BlockHeader, HEADER_LEN};
use wavicle::decode::decode_stream;

struct WavpackStreamParser;

impl WavpackStreamParser {
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
            _ => return Err(SymphoniaError::Unsupported("unsupported WavPack bit depth")),
        };

        for &s in samples {
            out.push(s as f32 / divisor);
        }
        Ok(out)
    }

    fn is_trailing_tag_magic(hdr: &[u8]) -> bool {
        hdr.starts_with(b"APETAGEX")
            || hdr.starts_with(b"TAG")
            || hdr.starts_with(b"ID3")
            || hdr.starts_with(b"LYRICS")
    }
}

/// Result of probing a media source for WavPack (`.wv`) audio format.
pub enum WavpackProbe {
    /// Source matched WavPack format and initialized a streaming `WavpackReader`.
    Matched(WavpackReader),
    /// Source did not match WavPack format; ownership of `source` is returned cleanly.
    NotMatched(Box<dyn MediaSource>),
}

/// Streaming block-by-block WavPack (`.wv`) decoder implementing incremental decode and seeking
/// without buffering the entire compressed file in memory.
pub struct WavpackReader {
    source: Box<dyn MediaSource>,
    audio_start: u64,
    audio_end: Option<u64>,
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u32,
    total_frames: Option<u64>,
    duration_ms: Option<u64>,
    current_frame: u64,
    current_block_range: (u64, u64),
    pending_pcm: Vec<f32>,
    pending_offset: usize,
    block_buf: Vec<u8>,
    checkpoints: Vec<(u64, u64)>,
}

impl WavpackReader {
    /// Default number of stereo/mono frames emitted per `decode_next_frame` call.
    pub const FRAMES_PER_CHUNK: usize = 1024;
    const MAX_SYNC_SCAN_BYTES: usize = 256 * 1024;
    const MAX_CHECKPOINTS: usize = 2048;

    /// Probes the source for a `"wvpk"` signature (skipping optional leading ID3v2) and decodes only
    /// the opening block so streams open immediately in O(1) memory.
    pub fn try_new(mut source: Box<dyn MediaSource>) -> Result<WavpackProbe, SymphoniaError> {
        if source.seek(SeekFrom::Start(0)).is_err() {
            return Ok(WavpackProbe::NotMatched(source));
        }

        // Skip optional chained leading ID3v2 tags before checking `"wvpk"`.
        let mut start_off = 0u64;
        for _ in 0..4 {
            let mut probe10 = [0u8; 10];
            if source.read_exact(&mut probe10).is_err() {
                let _ = source.seek(SeekFrom::Start(0));
                return Ok(WavpackProbe::NotMatched(source));
            }
            if &probe10[0..3] == b"ID3"
                && probe10[3] != 0xFF
                && probe10[4] != 0xFF
                && ((probe10[6] | probe10[7] | probe10[8] | probe10[9]) & 0x80) == 0
            {
                let tag_size = ((probe10[6] as u64 & 0x7F) << 21)
                    | ((probe10[7] as u64 & 0x7F) << 14)
                    | ((probe10[8] as u64 & 0x7F) << 7)
                    | (probe10[9] as u64 & 0x7F);
                let footer = if (probe10[5] & 0x10) != 0 { 10 } else { 0 };
                start_off += 10 + tag_size + footer;
                if source.seek(SeekFrom::Start(start_off)).is_err() {
                    let _ = source.seek(SeekFrom::Start(0));
                    return Ok(WavpackProbe::NotMatched(source));
                }
            } else {
                let _ = source.seek(SeekFrom::Start(start_off));
                break;
            }
        }

        let mut magic = [0u8; 4];
        if source.read_exact(&mut magic).is_err() || &magic != b"wvpk" {
            let _ = source.seek(SeekFrom::Start(0));
            return Ok(WavpackProbe::NotMatched(source));
        }

        let _ = source.seek(SeekFrom::Start(start_off));
        let audio_end = source.byte_len();
        let mut block_buf = vec![0u8; 64 * 1024];
        let mut cursor = start_off;

        loop {
            let mut hdr_bytes = [0u8; HEADER_LEN];
            match Self::read_block_header_raw(&mut *source, &mut hdr_bytes) {
                Ok(true) => {}
                Ok(false) => {
                    return Err(SymphoniaError::Unsupported("empty WavPack stream"));
                }
                Err(e) => {
                    if cursor == start_off {
                        if let SymphoniaError::IoError(ref ioe) = e {
                            if ioe.kind() == ErrorKind::WouldBlock {
                                return Err(e);
                            }
                        }
                        let _ = source.seek(SeekFrom::Start(0));
                        return Ok(WavpackProbe::NotMatched(source));
                    }
                    return Err(e);
                }
            }

            let hdr = BlockHeader::parse(&hdr_bytes)
                .map_err(|_| SymphoniaError::Unsupported("malformed WavPack block header"))?;
            let blen = hdr.block_len();
            if blen < HEADER_LEN {
                return Err(SymphoniaError::Unsupported("invalid WavPack block size"));
            }

            if hdr.block_samples == 0 {
                // Metadata-only block: advance to the first audio block.
                cursor += blen as u64;
                source
                    .seek(SeekFrom::Start(cursor))
                    .map_err(SymphoniaError::IoError)?;
                continue;
            }

            if block_buf.len() < blen {
                block_buf.resize(blen, 0);
            }
            block_buf[..HEADER_LEN].copy_from_slice(&hdr_bytes);
            super::read_exact_resilient(&mut *source, &mut block_buf[HEADER_LEN..blen])
                .map_err(SymphoniaError::IoError)?;

            let decoded = decode_stream(&block_buf[..blen])
                .map_err(|_| SymphoniaError::Unsupported("malformed WavPack stream"))?;
            if decoded.channels == 0 || decoded.sample_rate == 0 {
                return Err(SymphoniaError::Unsupported(
                    "invalid WavPack stream parameters",
                ));
            }

            let pending_pcm = WavpackStreamParser::normalize_samples(
                &decoded.samples,
                decoded.bits_per_sample,
                decoded.is_float,
            )?;

            let total_frames = hdr.total_samples;
            let duration_ms =
                total_frames.map(|frames| ((frames as u128 * 1000) / decoded.sample_rate as u128) as u64);
            let next_off = cursor + blen as u64;
            let mut checkpoints = Vec::with_capacity(64);
            checkpoints.push((hdr.block_index, cursor));
            checkpoints.push((hdr.block_index + hdr.block_samples as u64, next_off));

            return Ok(WavpackProbe::Matched(Self {
                source,
                audio_start: cursor,
                audio_end,
                sample_rate: decoded.sample_rate,
                channels: decoded.channels,
                bits_per_sample: decoded.bits_per_sample,
                total_frames,
                duration_ms,
                current_frame: hdr.block_index,
                current_block_range: (hdr.block_index, hdr.block_index + hdr.block_samples as u64),
                pending_pcm,
                pending_offset: 0,
                block_buf,
                checkpoints,
            }));
        }
    }

    /// Reads 32-byte block header, distinguishing clean stream boundary / trailing metadata EOF (`Ok(false)`)
    /// from genuine I/O or decode errors (`Err(...)`).
    fn read_block_header_raw(
        source: &mut dyn MediaSource,
        hdr_out: &mut [u8; HEADER_LEN],
    ) -> Result<bool, SymphoniaError> {
        let mut first = 0usize;
        while first == 0 {
            match source.read(&mut hdr_out[..1]) {
                Ok(0) => return Ok(false),
                Ok(1) => first = 1,
                Ok(_) => unreachable!(),
                Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(SymphoniaError::IoError(e)),
            }
        }

        // Read at least up to 8 bytes to detect short trailing tags (ID3v1 is 128B, APE is >=32B, custom >=4B).
        let mut filled = 1usize;
        while filled < HEADER_LEN {
            match source.read(&mut hdr_out[filled..]) {
                Ok(0) => {
                    if filled >= 3 && WavpackStreamParser::is_trailing_tag_magic(&hdr_out[..filled]) {
                        return Ok(false);
                    }
                    return Ok(false);
                }
                Ok(n) => filled += n,
                Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(SymphoniaError::IoError(e)),
            }
        }

        if &hdr_out[0..4] != b"wvpk" {
            if WavpackStreamParser::is_trailing_tag_magic(hdr_out) {
                return Ok(false);
            }
            return Err(SymphoniaError::DecodeError("invalid WavPack block sync"));
        }

        Ok(true)
    }

    fn record_checkpoint(&mut self, block_index: u64, offset: u64) {
        if self.checkpoints.len() >= Self::MAX_CHECKPOINTS {
            return;
        }
        match self.checkpoints.binary_search_by_key(&block_index, |&(f, _)| f) {
            Ok(_) => {}
            Err(pos) => self.checkpoints.insert(pos, (block_index, offset)),
        }
    }

    fn read_and_decode_next_block(&mut self) -> Result<bool, SymphoniaError> {
        loop {
            let block_offset = self
                .source
                .seek(SeekFrom::Current(0))
                .map_err(SymphoniaError::IoError)?;

            if let Some(end) = self.audio_end {
                if block_offset >= end {
                    return Ok(false);
                }
            }

            let mut hdr_bytes = [0u8; HEADER_LEN];
            match Self::read_block_header_raw(&mut *self.source, &mut hdr_bytes) {
                Ok(true) => {}
                Ok(false) => return Ok(false),
                Err(e) => {
                    let _ = self.source.seek(SeekFrom::Start(block_offset));
                    return Err(e);
                }
            }

            let hdr = BlockHeader::parse(&hdr_bytes)
                .map_err(|_| SymphoniaError::DecodeError("corrupt WavPack block header"))?;
            let blen = hdr.block_len();
            if blen < HEADER_LEN {
                return Err(SymphoniaError::DecodeError("invalid WavPack block length"));
            }

            if hdr.block_samples == 0 {
                let next_pos = block_offset + blen as u64;
                self.source
                    .seek(SeekFrom::Start(next_pos))
                    .map_err(SymphoniaError::IoError)?;
                continue;
            }

            if self.block_buf.len() < blen {
                self.block_buf.resize(blen, 0);
            }
            self.block_buf[..HEADER_LEN].copy_from_slice(&hdr_bytes);
            if let Err(e) = super::read_exact_resilient(
                &mut *self.source,
                &mut self.block_buf[HEADER_LEN..blen],
            ) {
                let _ = self.source.seek(SeekFrom::Start(block_offset));
                return Err(SymphoniaError::IoError(e));
            }

            let decoded = decode_stream(&self.block_buf[..blen])
                .map_err(|_| SymphoniaError::DecodeError("failed to decode WavPack block"))?;
            self.pending_pcm = WavpackStreamParser::normalize_samples(
                &decoded.samples,
                self.bits_per_sample,
                decoded.is_float,
            )?;
            self.pending_offset = 0;
            self.current_frame = hdr.block_index;
            self.current_block_range = (hdr.block_index, hdr.block_index + hdr.block_samples as u64);

            self.record_checkpoint(hdr.block_index, block_offset);
            let next_off = block_offset + blen as u64;
            if self
                .checkpoints
                .last()
                .is_none_or(|&(last_f, _)| last_f <= hdr.block_index)
            {
                self.record_checkpoint(hdr.block_index + hdr.block_samples as u64, next_off);
            }
            return Ok(true);
        }
    }

    fn verify_block_at(&mut self, offset: u64) -> Result<Option<(u64, BlockHeader)>, SymphoniaError> {
        self.source
            .seek(SeekFrom::Start(offset))
            .map_err(SymphoniaError::IoError)?;
        let mut hdr_bytes = [0u8; HEADER_LEN];
        match super::read_exact_resilient(&mut *self.source, &mut hdr_bytes) {
            Ok(()) => {}
            Err(ref e) if e.kind() == ErrorKind::UnexpectedEof => {
                return Ok(None);
            }
            Err(e) => return Err(SymphoniaError::IoError(e)),
        }
        let Ok(hdr) = BlockHeader::parse(&hdr_bytes) else {
            return Ok(None);
        };
        if hdr.block_samples == 0 || hdr.flags.output_channels() != self.channels {
            return Ok(None);
        }

        // Cross-check the next header boundary to eliminate false-positive sync inside payload bytes.
        let next_off = offset + hdr.block_len() as u64;
        if let Some(end) = self.audio_end {
            if next_off == end {
                return Ok(Some((offset, hdr)));
            }
            if next_off > end {
                return Ok(None);
            }
        }
        self.source
            .seek(SeekFrom::Start(next_off))
            .map_err(SymphoniaError::IoError)?;
        let mut peek = [0u8; HEADER_LEN];
        let mut n = 0usize;
        while n < HEADER_LEN {
            match self.source.read(&mut peek[n..]) {
                Ok(0) => break,
                Ok(read_n) => n += read_n,
                Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(SymphoniaError::IoError(e)),
            }
        }
        let valid_next = n == 0
            || (n >= 3 && WavpackStreamParser::is_trailing_tag_magic(&peek[..n]))
            || (n == HEADER_LEN && BlockHeader::parse(&peek).is_ok());
        if valid_next {
            Ok(Some((offset, hdr)))
        } else {
            Ok(None)
        }
    }

    fn find_verified_block_near(
        &mut self,
        start_off: u64,
        upper_bound_off: u64,
    ) -> Result<Option<(u64, BlockHeader)>, SymphoniaError> {
        let clamped_start = start_off.max(self.audio_start);
        if clamped_start >= upper_bound_off {
            return Ok(None);
        }
        self.source
            .seek(SeekFrom::Start(clamped_start))
            .map_err(SymphoniaError::IoError)?;

        let mut scan_end = clamped_start.saturating_add(Self::MAX_SYNC_SCAN_BYTES as u64);
        if let Some(end) = self.audio_end {
            scan_end = scan_end.min(end);
        }
        scan_end = scan_end.min(upper_bound_off);

        let mut win = vec![0u8; 65536];
        let mut cursor = clamped_start;
        let mut carry = 0usize;

        while cursor < scan_end {
            let to_read = ((scan_end - cursor) as usize).min(win.len() - carry);
            if to_read == 0 {
                break;
            }
            let n = loop {
                match self.source.read(&mut win[carry..carry + to_read]) {
                    Ok(n) => break n,
                    Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
                    Err(e) => return Err(SymphoniaError::IoError(e)),
                }
            };
            if n == 0 {
                break;
            }
            let valid_len = carry + n;
            let buf_base = cursor - carry as u64;
            let mut i = 0usize;
            let mut sought = false;
            while i + HEADER_LEN <= valid_len {
                if &win[i..i + 4] == b"wvpk" {
                    let cand_off = buf_base + i as u64;
                    sought = true;
                    if let Some(found) = self.verify_block_at(cand_off)? {
                        return Ok(Some(found));
                    }
                }
                i += 1;
            }
            if sought {
                self.source
                    .seek(SeekFrom::Start(cursor + n as u64))
                    .map_err(SymphoniaError::IoError)?;
            }
            let keep = valid_len.saturating_sub(i);
            win.copy_within(valid_len - keep..valid_len, 0);
            carry = keep;
            cursor += n as u64;
        }
        Ok(None)
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

    /// Returns the bit depth per sample (e.g. 16, 24, 32).
    #[inline]
    pub fn bits_per_sample(&self) -> u32 {
        self.bits_per_sample
    }

    /// Returns total stream duration in milliseconds if known.
    #[inline]
    pub fn duration_ms(&self) -> Option<u64> {
        self.duration_ms
    }

    /// Returns the start timestamp in milliseconds of the currently loaded `"wvpk"` block.
    #[inline]
    pub fn current_block_start_ms(&self) -> u64 {
        ((self.current_block_range.0 as u128 * 1000) / self.sample_rate.max(1) as u128) as u64
    }

    /// Seeks cleanly to `position_ms` using sparse checkpoints and verified `"wvpk"` block sync.
    pub fn seek_ms(&mut self, position_ms: u64) -> Result<(), SymphoniaError> {
        let target_frame =
            ((position_ms as u128 * self.sample_rate as u128) / 1000) as u64;
        if let Some(tot) = self.total_frames {
            if tot == 0 {
                self.current_frame = 0;
                self.pending_pcm.clear();
                self.pending_offset = 0;
                return Ok(());
            }
            if target_frame >= tot {
                self.current_frame = tot;
                self.pending_pcm.clear();
                self.pending_offset = 0;
                if let Some(end) = self.audio_end {
                    let _ = self.source.seek(SeekFrom::Start(end));
                }
                return Ok(());
            }
        }

        // Fast O(1) intra-block seek if already decoded.
        let (cur_start, cur_end) = self.current_block_range;
        if !self.pending_pcm.is_empty() && target_frame >= cur_start && target_frame < cur_end {
            self.pending_offset =
                ((target_frame - cur_start) as usize) * (self.channels as usize);
            self.current_frame = target_frame;
            return Ok(());
        }

        let ch = self.channels as usize;
        let cp_idx = self
            .checkpoints
            .partition_point(|&(f, _)| f <= target_frame)
            .saturating_sub(1);
        let (mut lo_frame, mut lo_off) = self.checkpoints[cp_idx];
        let (mut hi_frame, mut hi_off) = if cp_idx + 1 < self.checkpoints.len() {
            self.checkpoints[cp_idx + 1]
        } else {
            (
                self.total_frames.unwrap_or(u64::MAX),
                self.audio_end
                    .or_else(|| self.source.byte_len())
                    .unwrap_or(u64::MAX),
            )
        };

        let walk_threshold = (self.sample_rate as u64) * 6;
        if hi_off < u64::MAX && hi_frame < u64::MAX && target_frame.saturating_sub(lo_frame) > walk_threshold
        {
            for _ in 0..8 {
                if hi_off <= lo_off.saturating_add(HEADER_LEN as u64) {
                    break;
                }
                let frame_span = hi_frame.saturating_sub(lo_frame).max(1);
                let byte_span = hi_off.saturating_sub(lo_off);
                let rel = target_frame.saturating_sub(lo_frame).min(frame_span);
                let mut guess = lo_off + ((byte_span as u128 * rel as u128) / frame_span as u128) as u64;
                guess = guess.clamp(
                    lo_off + 1,
                    hi_off.saturating_sub(HEADER_LEN as u64).max(lo_off + 1),
                );

                match self.find_verified_block_near(guess, hi_off)? {
                    Some((found_off, hdr)) if found_off < hi_off => {
                        self.record_checkpoint(hdr.block_index, found_off);
                        let end_f = hdr.block_index + hdr.block_samples as u64;
                        self.record_checkpoint(end_f, found_off + hdr.block_len() as u64);

                        if target_frame >= hdr.block_index && target_frame < end_f {
                            lo_off = found_off;
                            break;
                        }
                        if end_f <= target_frame {
                            lo_frame = end_f;
                            lo_off = found_off + hdr.block_len() as u64;
                        } else {
                            hi_frame = hdr.block_index;
                            hi_off = found_off;
                        }
                        if target_frame.saturating_sub(lo_frame) <= walk_threshold {
                            break;
                        }
                    }
                    _ => {
                        // Narrow towards lower half if tail scan found no full block before hi_off.
                        hi_off = guess;
                    }
                }
            }
        }

        // Sequential header walk from nearest known block boundary <= target_frame.
        let mut cursor = lo_off;
        self.source
            .seek(SeekFrom::Start(cursor))
            .map_err(SymphoniaError::IoError)?;

        loop {
            let mut hdr_bytes = [0u8; HEADER_LEN];
            if !Self::read_block_header_raw(&mut *self.source, &mut hdr_bytes)? {
                self.pending_pcm.clear();
                self.pending_offset = 0;
                self.current_frame = self.total_frames.unwrap_or(self.current_frame);
                return Ok(());
            }
            let hdr = BlockHeader::parse(&hdr_bytes)
                .map_err(|_| SymphoniaError::DecodeError("corrupt WavPack block during seek"))?;
            let blen = hdr.block_len();
            if hdr.block_samples == 0 {
                cursor += blen as u64;
                self.source
                    .seek(SeekFrom::Start(cursor))
                    .map_err(SymphoniaError::IoError)?;
                continue;
            }

            let block_end_frame = hdr.block_index + hdr.block_samples as u64;
            if block_end_frame <= target_frame {
                self.record_checkpoint(hdr.block_index, cursor);
                cursor += blen as u64;
                self.source
                    .seek(SeekFrom::Start(cursor))
                    .map_err(SymphoniaError::IoError)?;
                continue;
            }

            if self.block_buf.len() < blen {
                self.block_buf.resize(blen, 0);
            }
            self.block_buf[..HEADER_LEN].copy_from_slice(&hdr_bytes);
            super::read_exact_resilient(&mut *self.source, &mut self.block_buf[HEADER_LEN..blen])
                .map_err(SymphoniaError::IoError)?;
            let decoded = decode_stream(&self.block_buf[..blen])
                .map_err(|_| SymphoniaError::DecodeError("failed to decode WavPack block"))?;
            self.pending_pcm = WavpackStreamParser::normalize_samples(
                &decoded.samples,
                self.bits_per_sample,
                decoded.is_float,
            )?;
            let skip_frames = target_frame.saturating_sub(hdr.block_index) as usize;
            self.pending_offset = (skip_frames * ch).min(self.pending_pcm.len());
            self.current_block_range = (hdr.block_index, block_end_frame);
            self.current_frame = hdr.block_index + skip_frames as u64;
            self.record_checkpoint(hdr.block_index, cursor);
            self.record_checkpoint(block_end_frame, cursor + blen as u64);
            return Ok(());
        }
    }

    /// Emits the next chunk of decoded PCM frames into the output buffer.
    pub fn decode_next_frame(&mut self, out_pcm: &mut Vec<f32>) -> Result<bool, SymphoniaError> {
        out_pcm.clear();
        let channels = self.channels as usize;

        if self.pending_offset >= self.pending_pcm.len() {
            if let Some(tot) = self.total_frames {
                if self.current_frame >= tot {
                    return Ok(false);
                }
            }
            if !self.read_and_decode_next_block()? {
                return Ok(false);
            }
        }

        let avail_samples = self.pending_pcm.len().saturating_sub(self.pending_offset);
        if avail_samples == 0 {
            return Ok(false);
        }
        let samples_to_deliver = (Self::FRAMES_PER_CHUNK * channels).min(avail_samples);
        let end = self.pending_offset + samples_to_deliver;
        out_pcm.extend_from_slice(&self.pending_pcm[self.pending_offset..end]);
        self.pending_offset = end;
        self.current_frame += (samples_to_deliver / channels.max(1)) as u64;
        Ok(true)
    }
}
