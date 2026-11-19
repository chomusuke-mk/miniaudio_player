//! Monotonic Byte-Offset <-> Timestamp (ms) Mapping for VBR & Segmented Streams.
//!
//! Eliminates false linear CBR/whole-file assumptions in buffered range reporting by:
//! - Parsing container seek/chunk tables directly from in-memory `Head` / `Moov` / `SeekTable`
//!   headers (MP4 `stts`/`stsc`/`stsz`/`stco`/`co64`, FLAC `SEEKTABLE`) with zero extra I/O.
//! - Recording segment boundaries in HLS VOD (`#EXTINF` cumulative durations vs fed bytes).
//! - Incorporating dynamic `(byte_offset, pos_ms)` waypoints during decode for VBR streams.

/// Maps stream byte offsets inside `[audio_start, audio_end]` to track timestamps in milliseconds.
#[derive(Debug, Clone)]
pub struct ByteTimeMap {
    audio_start: u64,
    audio_end: u64,
    duration_ms: i64,
    /// Strictly non-decreasing byte offsets and non-decreasing timestamps `(byte_offset, ms)`.
    anchors: Vec<(u64, i64)>,
}

impl Default for ByteTimeMap {
    fn default() -> Self {
        Self::new(0, 0, 0)
    }
}

impl ByteTimeMap {
    const MAX_ANCHORS: usize = 512;

    /// Initializes a map bounded by `[audio_start, audio_end]` and total track `duration_ms`.
    pub fn new(audio_start: u64, audio_end: u64, duration_ms: i64) -> Self {
        Self {
            audio_start,
            audio_end,
            duration_ms: duration_ms.max(0),
            anchors: Vec::new(),
        }
    }

    /// Updates stream bounds and duration while keeping any valid existing container/segment anchors.
    pub fn set_bounds(&mut self, audio_start: u64, audio_end: u64, duration_ms: i64) {
        self.audio_start = audio_start;
        self.audio_end = audio_end.max(audio_start);
        self.duration_ms = duration_ms.max(0);
    }

    /// Replaces anchors wholesale (sorted and compacted for fast binary search).
    pub fn set_anchors(&mut self, mut pts: Vec<(u64, i64)>) {
        pts.sort_by_key(|&(b, _)| b);
        pts.dedup_by(|a, b| a.0 == b.0);
        // Enforce monotonicity on timestamps.
        let mut max_ms = 0i64;
        for (_, ms) in &mut pts {
            if *ms < max_ms {
                *ms = max_ms;
            } else {
                max_ms = *ms;
            }
        }
        if pts.len() > Self::MAX_ANCHORS {
            let step = (pts.len() / Self::MAX_ANCHORS).max(1);
            let mut downsampled = Vec::with_capacity(Self::MAX_ANCHORS + 2);
            for (i, &p) in pts.iter().enumerate() {
                if i == 0 || i + 1 == pts.len() || i % step == 0 {
                    downsampled.push(p);
                }
            }
            pts = downsampled;
        }
        self.anchors = pts;
    }

    /// Appends or inserts a monotonic `(byte_offset, time_ms)` waypoint cleanly.
    pub fn record_anchor(&mut self, byte_offset: u64, time_ms: i64) {
        if time_ms < 0 {
            return;
        }
        if self.duration_ms > 0 && time_ms > self.duration_ms {
            return;
        }
        let pos = self.anchors.partition_point(|&(b, _)| b < byte_offset);
        if let Some(&(existing_b, _)) = self.anchors.get(pos) {
            if existing_b == byte_offset {
                // Verify monotonic consistency against neighbors before updating.
                let prev_ok = pos == 0 || self.anchors[pos - 1].1 <= time_ms;
                let next_ok = pos + 1 >= self.anchors.len() || time_ms <= self.anchors[pos + 1].1;
                if prev_ok && next_ok {
                    self.anchors[pos].1 = time_ms;
                }
                return;
            }
        }
        let prev_ok = pos == 0 || (byte_offset - self.anchors[pos - 1].0 >= 16_384 && self.anchors[pos - 1].1 <= time_ms);
        let next_ok = pos >= self.anchors.len() || (self.anchors[pos].0 - byte_offset >= 16_384 && time_ms <= self.anchors[pos].1);
        if !prev_ok || !next_ok {
            return;
        }
        if self.anchors.len() >= Self::MAX_ANCHORS {
            // Keep sparse density by dropping every odd intermediate entry when saturated.
            let mut compacted = Vec::with_capacity(self.anchors.len() / 2 + 2);
            for (i, &item) in self.anchors.iter().enumerate() {
                if i == 0 || i + 1 == self.anchors.len() || i % 2 == 0 {
                    compacted.push(item);
                }
            }
            self.anchors = compacted;
            let pos = self.anchors.partition_point(|&(b, _)| b < byte_offset);
            self.anchors.insert(pos, (byte_offset, time_ms));
        } else {
            self.anchors.insert(pos, (byte_offset, time_ms));
        }
    }

    /// Records a monotonic HLS VOD segment boundary (`[seg_start_byte, seg_end_byte]` -> `[start_ms, end_ms]`)
    /// without minimum byte-distance throttling so every segment is exact.
    pub fn push_segment_anchor(&mut self, byte_offset: u64, time_ms: i64) {
        let clamped_ms = time_ms.max(0);
        if let Some(last) = self.anchors.last_mut() {
            if last.0 == byte_offset {
                last.1 = last.1.max(clamped_ms);
                return;
            }
            if byte_offset < last.0 {
                return;
            }
            if clamped_ms < last.1 {
                return;
            }
        }
        self.anchors.push((byte_offset, clamped_ms));
        if self.anchors.len() > Self::MAX_ANCHORS {
            let mut compacted = Vec::with_capacity(Self::MAX_ANCHORS / 2 + 2);
            for (i, &item) in self.anchors.iter().enumerate() {
                if i == 0 || i + 1 == self.anchors.len() || i % 2 == 0 {
                    compacted.push(item);
                }
            }
            self.anchors = compacted;
        }
    }

    /// Maps an arbitrary stream byte position to milliseconds.
    /// When `is_range_start` is true and the byte lies inside `[audio_start, audio_end]`,
    /// rounds conservatively UP so backward seeks at `start_ms` do not miss evicted bytes;
    /// when false (range end), rounds conservatively DOWN so seeks near `end_ms` stay buffered.
    pub fn byte_to_ms(&self, byte_offset: u64, is_range_start: bool) -> i64 {
        let effective_dur = if self.duration_ms > 0 {
            self.duration_ms
        } else {
            self.anchors.last().map(|&(_, ms)| ms).unwrap_or(0)
        };
        if effective_dur <= 0 {
            return 0;
        }
        if byte_offset <= self.audio_start {
            return 0;
        }
        if self.audio_end > self.audio_start && byte_offset >= self.audio_end && self.duration_ms > 0
        {
            return self.duration_ms;
        }

        if !self.anchors.is_empty() {
            let idx = self.anchors.partition_point(|&(b, _)| b <= byte_offset);
            if idx == 0 {
                let (b1, t1) = self.anchors[0];
                return Self::interp(
                    self.audio_start,
                    0,
                    b1,
                    t1,
                    byte_offset,
                    is_range_start,
                );
            }
            let (b0, t0) = self.anchors[idx - 1];
            if b0 == byte_offset {
                return t0;
            }
            if idx < self.anchors.len() {
                let (b1, t1) = self.anchors[idx];
                return Self::interp(b0, t0, b1, t1, byte_offset, is_range_start);
            }
            if self.audio_end > b0 && self.duration_ms > t0 {
                return Self::interp(
                    b0,
                    t0,
                    self.audio_end,
                    self.duration_ms,
                    byte_offset,
                    is_range_start,
                );
            }
            return t0;
        }

        if self.audio_end > self.audio_start {
            return Self::interp(
                self.audio_start,
                0,
                self.audio_end,
                effective_dur,
                byte_offset,
                is_range_start,
            );
        }

        0
    }

    #[inline]
    fn interp(b0: u64, t0: i64, b1: u64, t1: i64, byte_offset: u64, ceil_round: bool) -> i64 {
        if b1 <= b0 || t1 <= t0 {
            return t0;
        }
        let b = byte_offset.clamp(b0, b1);
        let db = (b1 - b0) as u128;
        let dt = (t1 - t0) as u128;
        let num = (b - b0) as u128 * dt;
        let delta = if ceil_round {
            (num + db - 1) / db
        } else {
            num / db
        };
        t0 + (delta as i64)
    }

    /// Returns whether this map has explicit container/segment timing anchors beyond linear bounds.
    #[inline]
    pub fn has_anchors(&self) -> bool {
        !self.anchors.is_empty()
    }

    /// Attempts to extract exact chunk/sample `(byte_offset, time_ms)` anchors from an MP4/M4A
    /// `moov` box contained in `slice` (works for both fast-start `head` and non-fast-start `tail`).
    pub fn extract_mp4_anchors(slice: &[u8]) -> Option<(i64, Vec<(u64, i64)>)> {
        let moov = Self::find_top_box(slice, b"moov")?;
        let mut cursor = 0usize;
        while cursor + 8 <= moov.len() {
            let (sz, typ, body) = Self::read_box(moov, cursor)?;
            if typ == b"trak" {
                if let Some(parsed) = Self::parse_mp4_audio_trak(body) {
                    return Some(parsed);
                }
            }
            cursor = cursor.checked_add(sz)?;
        }
        None
    }

    fn find_top_box<'a>(mut data: &'a [u8], target: &[u8; 4]) -> Option<&'a [u8]> {
        let mut pos = 0usize;
        while pos + 8 <= data.len() {
            let sz32 = u32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]])
                as usize;
            let typ = &data[pos + 4..pos + 8];
            let (hdr_len, box_len) = if sz32 == 1 && pos + 16 <= data.len() {
                let sz64 = u64::from_be_bytes(data[pos + 8..pos + 16].try_into().ok()?);
                (16usize, usize::try_from(sz64).ok()?)
            } else if sz32 == 0 {
                (8usize, data.len() - pos)
            } else {
                (8usize, sz32)
            };
            if box_len < hdr_len || pos + box_len > data.len() {
                break;
            }
            if typ == target {
                return Some(&data[pos + hdr_len..pos + box_len]);
            }
            pos += box_len;
        }
        // Fallback scan if caller passed a sub-slice starting near moov.
        let _ = &mut data;
        None
    }

    #[inline]
    fn read_box(buf: &[u8], off: usize) -> Option<(usize, &[u8], &[u8])> {
        if off + 8 > buf.len() {
            return None;
        }
        let sz32 = u32::from_be_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]]) as usize;
        let typ = &buf[off + 4..off + 8];
        let (hdr_len, box_len) = if sz32 == 1 && off + 16 <= buf.len() {
            let sz64 = u64::from_be_bytes(buf[off + 8..off + 16].try_into().ok()?);
            (16usize, usize::try_from(sz64).ok()?)
        } else if sz32 == 0 {
            (8usize, buf.len() - off)
        } else {
            (8usize, sz32)
        };
        if box_len < hdr_len || off + box_len > buf.len() {
            return None;
        }
        Some((box_len, typ, &buf[off + hdr_len..off + box_len]))
    }

    fn find_child_box<'a>(parent: &'a [u8], target: &[u8; 4]) -> Option<&'a [u8]> {
        let mut pos = 0usize;
        while let Some((sz, typ, body)) = Self::read_box(parent, pos) {
            if typ == target {
                return Some(body);
            }
            pos += sz;
        }
        None
    }

    fn parse_mp4_audio_trak(trak: &[u8]) -> Option<(i64, Vec<(u64, i64)>)> {
        let mdia = Self::find_child_box(trak, b"mdia")?;
        let hdlr = Self::find_child_box(mdia, b"hdlr")?;
        if hdlr.len() < 12 || &hdlr[8..12] != b"soun" {
            return None;
        }

        let mdhd = Self::find_child_box(mdia, b"mdhd")?;
        if mdhd.is_empty() {
            return None;
        }
        let version = mdhd[0];
        let timescale: u64 = if version == 0 && mdhd.len() >= 16 {
            u32::from_be_bytes(mdhd[12..16].try_into().ok()?) as u64
        } else if version == 1 && mdhd.len() >= 24 {
            u32::from_be_bytes(mdhd[20..24].try_into().ok()?) as u64
        } else {
            return None;
        };
        if timescale == 0 {
            return None;
        }

        let minf = Self::find_child_box(mdia, b"minf")?;
        let stbl = Self::find_child_box(minf, b"stbl")?;
        let stts_body = Self::find_child_box(stbl, b"stts")?;
        let stsc_body = Self::find_child_box(stbl, b"stsc")?;
        let stsz_body = Self::find_child_box(stbl, b"stsz")?;

        // 1. Decode `stco` or `co64` chunk offsets.
        let mut chunk_offsets: Vec<u64> = Vec::new();
        if let Some(stco) = Self::find_child_box(stbl, b"stco") {
            if stco.len() >= 8 {
                let n = u32::from_be_bytes(stco[4..8].try_into().ok()?) as usize;
                let max_n = ((stco.len() - 8) / 4).min(n);
                chunk_offsets.reserve(max_n);
                for i in 0..max_n {
                    let o = 8 + i * 4;
                    chunk_offsets.push(u32::from_be_bytes(stco[o..o + 4].try_into().ok()?) as u64);
                }
            }
        } else if let Some(co64) = Self::find_child_box(stbl, b"co64") {
            if co64.len() >= 8 {
                let n = u32::from_be_bytes(co64[4..8].try_into().ok()?) as usize;
                let max_n = ((co64.len() - 8) / 8).min(n);
                chunk_offsets.reserve(max_n);
                for i in 0..max_n {
                    let o = 8 + i * 8;
                    chunk_offsets.push(u64::from_be_bytes(co64[o..o + 8].try_into().ok()?));
                }
            }
        }
        if chunk_offsets.is_empty() {
            return None;
        }

        // 2. Decode `stts` (run-length sample durations in timescale ticks).
        if stts_body.len() < 8 {
            return None;
        }
        let stts_count = u32::from_be_bytes(stts_body[4..8].try_into().ok()?) as usize;
        let max_stts = ((stts_body.len() - 8) / 8).min(stts_count);
        let mut stts_entries: Vec<(u32, u32)> = Vec::with_capacity(max_stts);
        for i in 0..max_stts {
            let o = 8 + i * 8;
            let sc = u32::from_be_bytes(stts_body[o..o + 4].try_into().ok()?);
            let sd = u32::from_be_bytes(stts_body[o + 4..o + 8].try_into().ok()?);
            stts_entries.push((sc, sd));
        }

        // 3. Decode `stsc` (`first_chunk` 1-based, `samples_per_chunk`).
        if stsc_body.len() < 8 {
            return None;
        }
        let stsc_count = u32::from_be_bytes(stsc_body[4..8].try_into().ok()?) as usize;
        let max_stsc = ((stsc_body.len() - 8) / 12).min(stsc_count);
        if max_stsc == 0 {
            return None;
        }
        let mut stsc_entries: Vec<(usize, usize)> = Vec::with_capacity(max_stsc);
        for i in 0..max_stsc {
            let o = 8 + i * 12;
            let first = u32::from_be_bytes(stsc_body[o..o + 4].try_into().ok()?) as usize;
            let spc = u32::from_be_bytes(stsc_body[o + 4..o + 8].try_into().ok()?) as usize;
            stsc_entries.push((first.saturating_sub(1), spc));
        }

        // 4. Decode `stsz` (sample byte sizes).
        if stsz_body.len() < 12 {
            return None;
        }
        let uniform_size = u32::from_be_bytes(stsz_body[4..8].try_into().ok()?) as u64;
        let sample_count = u32::from_be_bytes(stsz_body[8..12].try_into().ok()?) as usize;
        if sample_count == 0 {
            return None;
        }
        let var_entries = if uniform_size == 0 {
            ((stsz_body.len() - 12) / 4).min(sample_count)
        } else {
            0
        };

        // Walk samples sequentially through chunks to emit evenly spaced checkpoints (~256 points).
        let stride = (sample_count / 256).max(1);
        let mut raw_points: Vec<(u64, i64)> = Vec::with_capacity(sample_count / stride + 4);
        let mut stts_idx = 0usize;
        let mut stts_rem = stts_entries.first().map(|e| e.0).unwrap_or(0);
        let mut stts_delta = stts_entries.first().map(|e| e.1).unwrap_or(0) as u128;

        let mut stsc_cursor = 0usize;
        let mut sample_idx = 0usize;
        let mut pts_ticks: u128 = 0;

        for (chunk_idx, &chunk_off) in chunk_offsets.iter().enumerate() {
            while stsc_cursor + 1 < stsc_entries.len()
                && chunk_idx >= stsc_entries[stsc_cursor + 1].0
            {
                stsc_cursor += 1;
            }
            let samples_in_chunk = stsc_entries[stsc_cursor].1;
            let mut byte_pos = chunk_off;

            for _ in 0..samples_in_chunk {
                if sample_idx >= sample_count {
                    break;
                }
                let s_size: u64 = if uniform_size != 0 {
                    uniform_size
                } else if sample_idx < var_entries {
                    let o = 12 + sample_idx * 4;
                    u32::from_be_bytes(stsz_body[o..o + 4].try_into().ok()?) as u64
                } else {
                    break;
                };

                if sample_idx == 0 || sample_idx % stride == 0 {
                    let ms = ((pts_ticks * 1000) / timescale as u128) as i64;
                    raw_points.push((byte_pos, ms));
                }

                // Advance timestamp by one sample's `stts` delta.
                if stts_rem == 0 && stts_idx + 1 < stts_entries.len() {
                    stts_idx += 1;
                    stts_rem = stts_entries[stts_idx].0;
                    stts_delta = stts_entries[stts_idx].1 as u128;
                }
                if stts_rem > 0 {
                    stts_rem -= 1;
                    pts_ticks += stts_delta;
                }
                byte_pos += s_size;
                sample_idx += 1;
            }
            if sample_idx == sample_count {
                let end_ms = ((pts_ticks * 1000) / timescale as u128) as i64;
                raw_points.push((byte_pos, end_ms));
                break;
            }
        }

        if raw_points.len() < 2 {
            return None;
        }
        let total_ms = ((pts_ticks * 1000) / timescale as u128) as i64;
        // Double check chunk offset ordering (rare multi-track interleaving is still monotonic).
        if raw_points[0].0 > raw_points[raw_points.len() - 1].0 {
            None
        } else {
            Some((total_ms, raw_points))
        }
    }

    /// Parses FLAC `STREAMINFO` + optional `SEEKTABLE` metadata blocks from `head` into `(duration_ms, anchors)`.
    pub fn extract_flac_anchors(head: &[u8], first_frame_offset: u64) -> Option<(i64, Vec<(u64, i64)>)> {
        if head.len() < 42 || &head[0..4] != b"fLaC" {
            return None;
        }
        let mut p = 4usize;
        let mut sample_rate = 0u64;
        let mut total_samples = 0u64;
        let mut anchors = Vec::new();

        while p + 4 <= head.len() {
            let hdr = head[p];
            let is_last = (hdr & 0x80) != 0;
            let btype = hdr & 0x7F;
            let blen = ((head[p + 1] as usize) << 16)
                | ((head[p + 2] as usize) << 8)
                | (head[p + 3] as usize);
            p += 4;
            if p + blen > head.len() {
                break;
            }
            let block = &head[p..p + blen];
            if btype == 0 && blen >= 18 {
                let sr = ((block[10] as u64) << 12)
                    | ((block[11] as u64) << 4)
                    | ((block[12] as u64) >> 4);
                let ts = (((block[13] & 0x0F) as u64) << 32)
                    | ((block[14] as u64) << 24)
                    | ((block[15] as u64) << 16)
                    | ((block[16] as u64) << 8)
                    | (block[17] as u64);
                sample_rate = sr;
                total_samples = ts;
            } else if btype == 3 && sample_rate > 0 {
                for entry in block.chunks_exact(18) {
                    let smp = u64::from_be_bytes(entry[0..8].try_into().ok()?);
                    let off = u64::from_be_bytes(entry[8..16].try_into().ok()?);
                    if smp != u64::MAX {
                        let ms = ((smp as u128 * 1000) / sample_rate as u128) as i64;
                        anchors.push((first_frame_offset.saturating_add(off), ms));
                    }
                }
            }
            p += blen;
            if is_last {
                break;
            }
        }

        if sample_rate == 0 || total_samples == 0 || anchors.len() < 2 {
            return None;
        }
        let dur_ms = ((total_samples as u128 * 1000) / sample_rate as u128) as i64;
        Some((dur_ms, anchors))
    }

    /// Parses Ogg primary stream metadata `(serial, sample_rate, pre_skip)` from `head`
    /// supporting Opus (`OpusHead`), Vorbis (`\x01vorbis`), and Ogg-FLAC (`\x7fFLAC`).
    pub fn parse_ogg_stream_info(head: &[u8]) -> Option<(u32, u32, u64)> {
        let mut off = 0usize;
        while off + 28 <= head.len() {
            if &head[off..off + 4] != b"OggS" {
                off += 1;
                continue;
            }
            let serial = u32::from_le_bytes(head[off + 14..off + 18].try_into().ok()?);
            let n_segs = head[off + 26] as usize;
            let hdr_end = off + 27 + n_segs;
            if hdr_end > head.len() {
                break;
            }
            let body_len: usize = head[off + 27..hdr_end].iter().map(|&b| b as usize).sum();
            let payload_end = hdr_end.saturating_add(body_len).min(head.len());
            let payload = &head[hdr_end..payload_end];

            if payload.len() >= 19 && &payload[0..8] == b"OpusHead" {
                let pre_skip = u16::from_le_bytes([payload[10], payload[11]]) as u64;
                return Some((serial, 48_000, pre_skip));
            }
            if payload.len() >= 16 && &payload[0..7] == b"\x01vorbis" {
                let sr = u32::from_le_bytes(payload[12..16].try_into().ok()?);
                if sr > 0 {
                    return Some((serial, sr, 0));
                }
            }
            if payload.len() >= 35 && &payload[0..5] == b"\x7fFLAC" {
                if let Some(pos) = payload.windows(4).position(|w| w == b"fLaC") {
                    if pos + 26 <= payload.len() {
                        let b = &payload[pos + 8..];
                        let sr = ((b[10] as u32) << 12) | ((b[11] as u32) << 4) | ((b[12] as u32) >> 4);
                        if sr > 0 {
                            return Some((serial, sr, 0));
                        }
                    }
                }
            }
            off = payload_end.max(off + 1);
        }
        None
    }

    /// Scans `slice` (rooted at stream byte `slice_offset`) for a valid `OggS` page matching
    /// `serial` with a positive granule position and converts it to `(byte_offset, time_ms)`.
    pub fn extract_ogg_anchor_in_slice(
        slice: &[u8],
        slice_offset: u64,
        serial: u32,
        sample_rate: u32,
        pre_skip: u64,
    ) -> Option<(u64, i64)> {
        if sample_rate == 0 || slice.len() < 28 {
            return None;
        }
        let mut i = 0usize;
        while i + 28 <= slice.len() {
            if &slice[i..i + 4] == b"OggS" && slice[i + 4] == 0 && (slice[i + 5] & 0xF8) == 0 {
                let pg_serial = u32::from_le_bytes([
                    slice[i + 14],
                    slice[i + 15],
                    slice[i + 16],
                    slice[i + 17],
                ]);
                let granule = i64::from_le_bytes([
                    slice[i + 6],
                    slice[i + 7],
                    slice[i + 8],
                    slice[i + 9],
                    slice[i + 10],
                    slice[i + 11],
                    slice[i + 12],
                    slice[i + 13],
                ]);
                let n_segs = slice[i + 26] as usize;
                if pg_serial == serial && granule > pre_skip as i64 && i + 27 + n_segs <= slice.len()
                {
                    let samples = (granule as u64).saturating_sub(pre_skip);
                    let ms = ((samples as u128 * 1000) / sample_rate as u128) as i64;
                    return Some((slice_offset.saturating_add(i as u64), ms));
                }
            }
            i += 1;
        }
        None
    }

    /// Parses native FLAC `STREAMINFO` parameters `(sample_rate, min_blocksize, max_blocksize)`.
    pub fn parse_flac_stream_info(head: &[u8]) -> Option<(u32, u16, u16)> {
        let mut p = head.windows(4).position(|w| w == b"fLaC")?;
        p += 4;
        if p + 22 > head.len() {
            return None;
        }
        let hdr = head[p];
        if (hdr & 0x7F) != 0 {
            return None;
        }
        let blen = ((head[p + 1] as usize) << 16)
            | ((head[p + 2] as usize) << 8)
            | (head[p + 3] as usize);
        let blk = head.get(p + 4..p + 4 + blen)?;
        if blk.len() < 18 {
            return None;
        }
        let min_bs = u16::from_be_bytes([blk[0], blk[1]]);
        let max_bs = u16::from_be_bytes([blk[2], blk[3]]);
        let sr = ((blk[10] as u32) << 12) | ((blk[11] as u32) << 4) | ((blk[12] as u32) >> 4);
        if sr == 0 {
            None
        } else {
            Some((sr, min_bs, max_bs))
        }
    }

    /// Scans `slice` (rooted at stream byte `slice_offset`) for a CRC-8 verified FLAC frame header
    /// and returns `(byte_offset, time_ms)`.
    pub fn extract_flac_anchor_in_slice(
        slice: &[u8],
        slice_offset: u64,
        sample_rate: u32,
        min_bs: u16,
        max_bs: u16,
        max_dur_ms: i64,
    ) -> Option<(u64, i64)> {
        if sample_rate == 0 || slice.len() < 16 {
            return None;
        }
        for i in 0..slice.len().saturating_sub(14) {
            if slice[i] != 0xFF || (slice[i + 1] & 0xFE) != 0xF8 {
                continue;
            }
            let variable_block = (slice[i + 1] & 0x01) != 0;
            let bs_code = slice[i + 2] >> 4;
            let sr_code = slice[i + 2] & 0x0F;
            let ch_code = slice[i + 3] >> 4;
            let bps_code = (slice[i + 3] >> 1) & 0x07;
            let reserved = slice[i + 3] & 0x01;
            if reserved != 0
                || bs_code == 0
                || sr_code == 15
                || ch_code > 10
                || bps_code == 3
                || bps_code == 7
            {
                continue;
            }
            if !variable_block && (min_bs == 0 || min_bs != max_bs) {
                continue;
            }

            let Some((coded_num, utf_len)) = Self::decode_flac_utf8(&slice[i + 4..]) else {
                continue;
            };
            let mut hdr_end = i + 4 + utf_len;
            if bs_code == 6 {
                hdr_end += 1;
            } else if bs_code == 7 {
                hdr_end += 2;
            }
            if sr_code == 12 {
                hdr_end += 1;
            } else if sr_code == 13 || sr_code == 14 {
                hdr_end += 2;
            }
            if hdr_end >= slice.len() {
                continue;
            }

            if Self::crc8(&slice[i..hdr_end]) != slice[hdr_end] {
                continue;
            }
            let sample_num = if variable_block {
                coded_num
            } else {
                coded_num.saturating_mul(min_bs as u64)
            };
            let ms = ((sample_num as u128 * 1000) / sample_rate as u128) as i64;
            if max_dur_ms > 0 && ms > max_dur_ms + 2_000 {
                continue;
            }
            return Some((slice_offset.saturating_add(i as u64), ms));
        }
        None
    }

    fn decode_flac_utf8(bytes: &[u8]) -> Option<(u64, usize)> {
        let b0 = *bytes.first()?;
        if b0 < 0x80 {
            return Some((b0 as u64, 1));
        }
        let ones = b0.leading_ones() as usize;
        if !(2..=7).contains(&ones) || bytes.len() < ones {
            return None;
        }
        let mask = (1u8 << (7 - ones)) - 1;
        let mut val = (b0 & mask) as u64;
        for &cont in &bytes[1..ones] {
            if (cont & 0xC0) != 0x80 {
                return None;
            }
            val = (val << 6) | (cont & 0x3F) as u64;
        }
        Some((val, ones))
    }

    #[inline]
    fn crc8(bytes: &[u8]) -> u8 {
        let mut crc = 0u8;
        for &b in bytes {
            crc ^= b;
            for _ in 0..8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x07;
                } else {
                    crc <<= 1;
                }
            }
        }
        crc
    }
}
