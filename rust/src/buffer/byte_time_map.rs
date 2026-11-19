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
    start_ms: i64,
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
            start_ms: 0,
            duration_ms: duration_ms.max(0),
            anchors: Vec::new(),
        }
    }

    /// Updates stream bounds and duration while keeping any valid existing container/segment anchors.
    pub fn set_bounds(&mut self, audio_start: u64, audio_end: u64, duration_ms: i64) {
        self.audio_start = self.audio_start.max(audio_start);
        self.audio_end = audio_end.max(self.audio_start);
        self.duration_ms = duration_ms.max(0);
    }

    /// Resets the map for a new contiguous HLS VOD segment window starting at `(audio_start, start_ms)`.
    pub fn reset_window(&mut self, audio_start: u64, start_ms: i64, duration_ms: i64) {
        self.audio_start = audio_start;
        self.audio_end = audio_start;
        self.start_ms = start_ms.max(0);
        self.duration_ms = duration_ms.max(0);
        self.anchors.clear();
        self.anchors.push((audio_start, self.start_ms));
    }

    /// Refines the logical start byte of `t = 0 ms` (e.g. first audio Ogg page or first MKV Cluster
    /// past embedded cover art) without altering demuxer container header boundaries.
    pub fn refine_audio_start(&mut self, first_audio_byte: u64) {
        if first_audio_byte > self.audio_start
            && (self.audio_end <= self.audio_start || first_audio_byte < self.audio_end)
        {
            self.audio_start = first_audio_byte;
            self.anchors.retain(|&(b, _)| b >= first_audio_byte);
        }
    }

    fn downsample_anchors(pts: &mut Vec<(u64, i64)>) {
        if pts.len() <= Self::MAX_ANCHORS {
            return;
        }
        let step = (pts.len() / Self::MAX_ANCHORS).max(1);
        let mut compacted = Vec::with_capacity(Self::MAX_ANCHORS + 2);
        for (i, &item) in pts.iter().enumerate() {
            if i == 0 || i + 1 == pts.len() || i % step == 0 {
                compacted.push(item);
            }
        }
        *pts = compacted;
    }

    /// Replaces anchors wholesale (sorted and compacted for fast binary search).
    pub fn set_anchors(&mut self, mut pts: Vec<(u64, i64)>) {
        pts.sort_by_key(|&(b, _)| b);
        pts.dedup_by(|a, b| a.0 == b.0);
        let mut max_ms = 0i64;
        for (_, ms) in &mut pts {
            if *ms < max_ms {
                *ms = max_ms;
            } else {
                max_ms = *ms;
            }
        }
        Self::downsample_anchors(&mut pts);
        self.anchors = pts;
    }

    /// Merges new container or probe anchors into existing anchors while preserving strict monotonicity.
    pub fn merge_anchors(&mut self, pts: Vec<(u64, i64)>) {
        if pts.is_empty() {
            return;
        }
        if self.anchors.is_empty() {
            self.set_anchors(pts);
            return;
        }
        let mut merged = self.anchors.clone();
        merged.extend(pts);
        self.set_anchors(merged);
    }

    /// Records a monotonic `(byte_offset, time_ms)` waypoint cleanly when far enough from neighbors.
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
                let prev_ok = pos == 0 || self.anchors[pos - 1].1 <= time_ms;
                let next_ok = pos + 1 >= self.anchors.len() || time_ms <= self.anchors[pos + 1].1;
                if prev_ok && next_ok {
                    self.anchors[pos].1 = time_ms;
                }
                return;
            }
        }
        let prev_ok = pos == 0
            || (byte_offset - self.anchors[pos - 1].0 >= 16_384
                && self.anchors[pos - 1].1 <= time_ms);
        let next_ok = pos >= self.anchors.len()
            || (self.anchors[pos].0 - byte_offset >= 16_384 && time_ms <= self.anchors[pos].1);
        if !prev_ok || !next_ok {
            return;
        }
        if self.anchors.len() >= Self::MAX_ANCHORS {
            Self::downsample_anchors(&mut self.anchors);
            let new_pos = self.anchors.partition_point(|&(b, _)| b < byte_offset);
            self.anchors.insert(new_pos, (byte_offset, time_ms));
        } else {
            self.anchors.insert(pos, (byte_offset, time_ms));
        }
    }

    /// Inserts an authoritative seek/frame observation `(byte_offset, time_ms)`, evicting any
    /// conflicting or stale nearby coarse anchors so seek boundaries never drift past actual targets.
    pub fn record_verified_anchor(&mut self, byte_offset: u64, time_ms: i64) {
        if time_ms < 0 {
            return;
        }
        let clamped_ms = if self.duration_ms > 0 {
            time_ms.min(self.duration_ms)
        } else {
            time_ms
        };
        if byte_offset <= self.audio_start {
            return;
        }
        self.anchors.retain(|&(b, t)| {
            if b.abs_diff(byte_offset) < 8_192 {
                return false;
            }
            if b < byte_offset && t > clamped_ms {
                return false;
            }
            if b > byte_offset && t < clamped_ms {
                return false;
            }
            true
        });
        let pos = self.anchors.partition_point(|&(b, _)| b < byte_offset);
        self.anchors.insert(pos, (byte_offset, clamped_ms));
        Self::downsample_anchors(&mut self.anchors);
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
            return self.start_ms;
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
                    self.start_ms,
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
                self.start_ms,
                self.audio_end,
                effective_dur,
                byte_offset,
                is_range_start,
            );
        }

        self.start_ms
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

    /// Returns a borrowed slice of sorted `(byte_offset, ms)` anchors.
    #[inline]
    pub fn anchors(&self) -> &[(u64, i64)] {
        &self.anchors
    }

    /// Returns the logical start byte offset where `t = 0 ms` begins.
    #[inline]
    pub fn audio_start(&self) -> u64 {
        self.audio_start
    }

    /// Estimates a byte offset corresponding to `time_ms` via inverse piecewise interpolation.
    pub fn estimate_byte_for_ms(&self, time_ms: i64) -> Option<u64> {
        if self.audio_end <= self.audio_start {
            return None;
        }
        let target = time_ms.max(0);
        if target == 0 {
            return Some(self.audio_start);
        }
        let eff_dur = if self.duration_ms > 0 {
            self.duration_ms
        } else {
            self.anchors.last().map(|&(_, ms)| ms).unwrap_or(0)
        };
        if eff_dur <= 0 {
            return None;
        }
        if target >= eff_dur {
            return Some(self.audio_end);
        }
        if !self.anchors.is_empty() {
            let idx = self.anchors.partition_point(|&(_, t)| t <= target);
            let (b0, t0) = if idx == 0 {
                (self.audio_start, 0i64)
            } else {
                self.anchors[idx - 1]
            };
            let (b1, t1) = if idx < self.anchors.len() {
                self.anchors[idx]
            } else {
                (self.audio_end, eff_dur)
            };
            if b1 <= b0 || t1 <= t0 {
                return Some(b0);
            }
            let frac = (target - t0).clamp(0, t1 - t0) as u128;
            let byte = b0 + ((frac * (b1 - b0) as u128) / (t1 - t0) as u128) as u64;
            return Some(byte.clamp(self.audio_start, self.audio_end));
        }
        let byte = self.audio_start
            + ((target as u128 * (self.audio_end - self.audio_start) as u128) / eff_dur as u128)
                as u64;
        Some(byte.clamp(self.audio_start, self.audio_end))
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

    fn parse_ogg_page_header(slice: &[u8], i: usize) -> Option<(u32, i64, usize)> {
        if i + 27 > slice.len() {
            return None;
        }
        if &slice[i..i + 4] != b"OggS" || slice[i + 4] != 0 || (slice[i + 5] & 0xF8) != 0 {
            return None;
        }
        let n_segs = slice[i + 26] as usize;
        let hdr_end = i + 27 + n_segs;
        if hdr_end > slice.len() {
            return None;
        }
        let pg_serial = u32::from_le_bytes(slice[i + 14..i + 18].try_into().ok()?);
        let granule = i64::from_le_bytes(slice[i + 6..i + 14].try_into().ok()?);
        let body_len: usize = slice[i + 27..hdr_end].iter().map(|&b| b as usize).sum();
        let page_len = 27 + n_segs + body_len;
        Some((pg_serial, granule, page_len))
    }

    /// Scans an initial Ogg byte slice starting at stream offset `slice_offset` for the byte
    /// offset of the first audio page belonging to `serial` whose granule exceeds `pre_skip`
    /// (skipping VorbisComment / OpusTags / FLAC `METADATA_BLOCK_PICTURE` cover-art pages).
    pub fn parse_ogg_first_audio_page(
        slice: &[u8],
        slice_offset: u64,
        serial: u32,
        pre_skip: u64,
    ) -> Option<u64> {
        let mut i = 0usize;
        while i + 28 <= slice.len() {
            let Some((pg_serial, granule, page_len)) = Self::parse_ogg_page_header(slice, i) else {
                i += 1;
                continue;
            };
            if pg_serial == serial && granule > pre_skip as i64 {
                return Some(slice_offset.saturating_add(i as u64));
            }
            if i + page_len <= slice.len() {
                i += page_len;
            } else {
                break;
            }
        }
        None
    }

    /// Extracts exact `OggS` page-boundary `(byte_offset, time_ms)` anchors within `slice`.
    ///
    /// Note that an Ogg page's `granule_position` records the PCM sample count at the **END** of
    /// that page (`page_start + page_len`), NOT its start byte. Pairing `page_end -> granule_ms`
    /// eliminates the +1..3s positive shift seen on VBR Opus/Vorbis/OggFLAC tracks with cover art.
    pub fn extract_ogg_anchors_in_slice(
        slice: &[u8],
        slice_offset: u64,
        serial: u32,
        sample_rate: u32,
        pre_skip: u64,
    ) -> Vec<(u64, i64)> {
        let mut out = Vec::new();
        if sample_rate == 0 || slice.len() < 28 {
            return out;
        }
        let mut i = 0usize;
        while i + 28 <= slice.len() {
            let Some((pg_serial, granule, page_len)) = Self::parse_ogg_page_header(slice, i) else {
                i += 1;
                continue;
            };
            let page_end = i + page_len;
            if page_end > slice.len() {
                // Verify no unaligned candidate later before ending if initial candidate wasn't verified.
                if out.is_empty() {
                    i += 1;
                    continue;
                }
                break;
            }
            // Confirm consecutive OggS sync when another header fits inside `slice` so random
            // audio payload bytes matching `OggS` are rejected deterministically.
            if page_end + 4 <= slice.len() && &slice[page_end..page_end + 4] != b"OggS" {
                i += 1;
                continue;
            }
            if pg_serial == serial && granule > pre_skip as i64 {
                let samples = (granule as u64).saturating_sub(pre_skip);
                let ms = ((samples as u128 * 1000) / sample_rate as u128) as i64;
                out.push((slice_offset.saturating_add(page_end as u64), ms));
            }
            i = page_end;
        }
        out
    }

    /// Scans `slice` (rooted at stream byte `slice_offset`) for a valid complete `OggS` page
    /// matching `serial` with a positive granule position and returns its exact `(page_end_byte, end_ms)`.
    pub fn extract_ogg_anchor_in_slice(
        slice: &[u8],
        slice_offset: u64,
        serial: u32,
        sample_rate: u32,
        pre_skip: u64,
    ) -> Option<(u64, i64)> {
        Self::extract_ogg_anchors_in_slice(slice, slice_offset, serial, sample_rate, pre_skip)
            .into_iter()
            .next()
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

    /// Walks native FLAC metadata blocks starting at `fLaC` and returns the byte offset where
    /// the first audio frame starts (immediately past the last metadata block header).
    pub fn parse_flac_first_frame_offset(head: &[u8]) -> Option<u64> {
        let mut p = head.windows(4).position(|w| w == b"fLaC")?;
        p += 4;
        while p + 4 <= head.len() {
            let hdr = head[p];
            let is_last = (hdr & 0x80) != 0;
            let blen = ((head[p + 1] as usize) << 16)
                | ((head[p + 2] as usize) << 8)
                | (head[p + 3] as usize);
            p += 4 + blen;
            if is_last {
                return Some(p as u64);
            }
        }
        None
    }

    #[inline]
    fn flac_header_sr_matches(sr_code: u8, expected_sr: u32) -> bool {
        let table_sr = match sr_code {
            1 => 88_200,
            2 => 176_400,
            3 => 192_000,
            4 => 8_000,
            5 => 16_000,
            6 => 22_050,
            7 => 24_000,
            8 => 32_000,
            9 => 44_100,
            10 => 48_000,
            11 => 96_000,
            _ => return true,
        };
        table_sr == expected_sr
    }

    /// Scans `slice` (rooted at `slice_offset`) and returns validated FLAC frame anchors as
    /// `(file_byte_offset, sample_number, time_ms)`.
    pub fn scan_flac_frames_in_slice(
        slice: &[u8],
        slice_offset: u64,
        sample_rate: u32,
        min_bs: u16,
        max_bs: u16,
        max_dur_ms: i64,
    ) -> Vec<(u64, u64, i64)> {
        let mut out = Vec::new();
        if sample_rate == 0 || slice.len() < 16 {
            return out;
        }
        let mut i = 0usize;
        while i + 14 < slice.len() {
            if slice[i] != 0xFF || (slice[i + 1] & 0xFE) != 0xF8 {
                i += 1;
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
                || !Self::flac_header_sr_matches(sr_code, sample_rate)
            {
                i += 1;
                continue;
            }
            if !variable_block && (min_bs == 0 || min_bs != max_bs) {
                i += 1;
                continue;
            }

            let Some((coded_num, utf_len)) = Self::decode_flac_utf8(&slice[i + 4..]) else {
                i += 1;
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
                i += 1;
                continue;
            }

            if Self::crc8(&slice[i..hdr_end]) != slice[hdr_end] {
                i += 1;
                continue;
            }
            let sample_num = if variable_block {
                coded_num
            } else {
                coded_num.saturating_mul(min_bs as u64)
            };
            let ms = ((sample_num as u128 * 1000) / sample_rate as u128) as i64;
            if max_dur_ms > 0 && ms > max_dur_ms + 2_000 {
                i += 1;
                continue;
            }
            if out.last().is_some_and(|&(_, prev_s, _)| sample_num <= prev_s) {
                i += 1;
                continue;
            }
            out.push((slice_offset.saturating_add(i as u64), sample_num, ms));
            i = hdr_end + 16;
        }
        out
    }

    /// Scans `slice` (rooted at stream byte `slice_offset`) for the first CRC-8 verified FLAC frame header
    /// and returns `(byte_offset, sample_number, time_ms)`.
    pub fn extract_flac_sample_anchor_in_slice(
        slice: &[u8],
        slice_offset: u64,
        sample_rate: u32,
        min_bs: u16,
        max_bs: u16,
        max_dur_ms: i64,
    ) -> Option<(u64, u64, i64)> {
        Self::scan_flac_frames_in_slice(
            slice,
            slice_offset,
            sample_rate,
            min_bs,
            max_bs,
            max_dur_ms,
        )
        .into_iter()
        .next()
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
        Self::extract_flac_sample_anchor_in_slice(
            slice,
            slice_offset,
            sample_rate,
            min_bs,
            max_bs,
            max_dur_ms,
        )
        .map(|(off, _smp, ms)| (off, ms))
    }

    /// Builds a virtual FLAC container header (`fLaC | STREAMINFO | SEEKTABLE | PADDING`)
    /// embedding `seek_points: &[(abs_byte_offset, sample_number)]` relative to `actual_first_frame`.
    ///
    /// Returns `(virtual_head_bytes, virtual_offset_delta)` where `virtual_offset_delta` is `0`
    /// whenever `actual_first_frame` has enough room for the synthetic `SEEKTABLE` + `PADDING`
    /// (so all frame offsets remain 1:1 with the real stream).
    pub fn build_synthetic_flac_head(
        orig_head: &[u8],
        actual_first_frame: u64,
        seek_points: &[(u64, u64)],
    ) -> Option<(Vec<u8>, u64)> {
        if seek_points.is_empty() {
            return None;
        }
        let flac_pos = orig_head.windows(4).position(|w| w == b"fLaC")?;
        let si_hdr = orig_head.get(flac_pos + 4..flac_pos + 8)?;
        if (si_hdr[0] & 0x7F) != 0 {
            return None;
        }
        let si_len = ((si_hdr[1] as usize) << 16) | ((si_hdr[2] as usize) << 8) | (si_hdr[3] as usize);
        if si_len != 34 {
            return None;
        }
        let stream_info = orig_head.get(flac_pos + 8..flac_pos + 8 + 34)?;
        let min_bs = u16::from_be_bytes([stream_info[0], stream_info[1]]).max(4096);

        let mut clean_pts: Vec<(u64, u64)> = seek_points
            .iter()
            .filter_map(|&(abs_off, smp)| {
                abs_off
                    .checked_sub(actual_first_frame)
                    .map(|rel| (smp, rel))
            })
            .collect();
        clean_pts.sort_by_key(|&(smp, rel)| (smp, rel));
        clean_pts.dedup_by(|a, b| a.0 == b.0 || a.1 == b.1);
        if clean_pts.is_empty() {
            return None;
        }
        let max_seek_entries = 128usize;
        if clean_pts.len() > max_seek_entries {
            let step = (clean_pts.len() / max_seek_entries).max(1);
            clean_pts = clean_pts
                .into_iter()
                .enumerate()
                .filter(|&(idx, _)| idx == 0 || idx % step == 0)
                .map(|(_, p)| p)
                .collect();
        }

        let seektable_len = clean_pts.len() * 18;
        if seektable_len > 0x00FF_FFFF {
            return None;
        }

        let prefix_len = 4 + 4 + 34 + 4 + seektable_len;
        let orig_len = actual_first_frame as usize;
        let need_padding = orig_len >= prefix_len + 4;
        let padding_payload = if need_padding { orig_len - prefix_len - 4 } else { 0 };
        let virtual_len = if need_padding { orig_len } else { prefix_len };
        let delta = virtual_len.saturating_sub(orig_len) as u64;

        let mut out = Vec::with_capacity(virtual_len);
        out.extend_from_slice(b"fLaC");
        out.extend_from_slice(&[0x00, 0x00, 0x00, 34]);
        out.extend_from_slice(stream_info);

        let st_last = if need_padding { 0x03 } else { 0x83 };
        out.push(st_last);
        out.push(((seektable_len >> 16) & 0xFF) as u8);
        out.push(((seektable_len >> 8) & 0xFF) as u8);
        out.push((seektable_len & 0xFF) as u8);
        for (smp, rel_off) in clean_pts {
            out.extend_from_slice(&smp.to_be_bytes());
            out.extend_from_slice(&rel_off.to_be_bytes());
            out.extend_from_slice(&min_bs.to_be_bytes());
        }

        if need_padding {
            out.push(0x81); // last block, PADDING type=1
            out.push(((padding_payload >> 16) & 0xFF) as u8);
            out.push(((padding_payload >> 8) & 0xFF) as u8);
            out.push((padding_payload & 0xFF) as u8);
            out.resize(virtual_len, 0);
        }

        Some((out, delta))
    }

    fn ebml_vint(data: &[u8], pos: usize, mask_leading: bool) -> Option<(u64, usize, bool)> {
        let first = *data.get(pos)?;
        if first == 0 {
            return None;
        }
        let width = first.leading_zeros() as usize + 1;
        if width > 8 || pos + width > data.len() {
            return None;
        }
        let mut all_ones = true;
        let mut val = if mask_leading {
            let mask = (1u8 << (8 - width)) - 1;
            if (first & mask) != mask {
                all_ones = false;
            }
            (first & mask) as u64
        } else {
            all_ones = false;
            first as u64
        };
        for &b in &data[pos + 1..pos + width] {
            if b != 0xFF {
                all_ones = false;
            }
            val = (val << 8) | b as u64;
        }
        Some((val, width, all_ones))
    }

    fn ebml_be_uint(bytes: &[u8]) -> Option<u64> {
        if bytes.is_empty() || bytes.len() > 8 {
            return None;
        }
        let mut v = 0u64;
        for &b in bytes {
            v = (v << 8) | b as u64;
        }
        Some(v)
    }

    /// Parses Matroska/WebM `(segment_data_start, timecode_scale_ns, first_cluster_offset)`.
    pub fn parse_mkv_stream_info(head: &[u8]) -> Option<(u64, u64, Option<u64>)> {
        let seg_pos = head.windows(4).position(|w| w == [0x18, 0x53, 0x80, 0x67])?;
        let (_, sz_len, _) = Self::ebml_vint(head, seg_pos + 4, true)?;
        let seg_data_start = seg_pos + 4 + sz_len;
        let mut scale_ns = 1_000_000u64;
        let mut first_cluster: Option<u64> = None;

        let mut pos = seg_data_start;
        while pos + 4 <= head.len() {
            let Some((eid, eid_len, _)) = Self::ebml_vint(head, pos, false) else {
                break;
            };
            if eid == 0x1F43_B675 {
                first_cluster = Some(pos as u64);
                break;
            }
            let Some((esz, esz_len, is_unk)) = Self::ebml_vint(head, pos + eid_len, true) else {
                break;
            };
            let payload_start = pos + eid_len + esz_len;
            if is_unk {
                break;
            }
            let payload_end = payload_start.saturating_add(esz as usize);
            if eid == 0x1549_A966 && payload_end <= head.len() {
                // Segment Info: look for TimestampScale (0x2AD7B1).
                let mut ipos = payload_start;
                while ipos + 3 <= payload_end {
                    let Some((cid, cid_len, _)) = Self::ebml_vint(head, ipos, false) else {
                        break;
                    };
                    let Some((csz, csz_len, cunk)) =
                        Self::ebml_vint(head, ipos + cid_len, true)
                    else {
                        break;
                    };
                    let c_start = ipos + cid_len + csz_len;
                    if cunk {
                        break;
                    }
                    let c_end = c_start.saturating_add(csz as usize);
                    if c_end > payload_end {
                        break;
                    }
                    if cid == 0x2AD7_B1 {
                        if let Some(s) = Self::ebml_be_uint(&head[c_start..c_end]) {
                            if s > 0 {
                                scale_ns = s;
                            }
                        }
                    }
                    ipos = c_end;
                }
            }
            if payload_end <= pos {
                break;
            }
            pos = payload_end;
        }
        Some((seg_data_start as u64, scale_ns, first_cluster))
    }

    fn parse_mkv_cues_slice(cues_body: &[u8], seg_data_start: u64, scale_ns: u64) -> Option<Vec<(u64, i64)>> {
        let mut anchors = Vec::new();
        let mut pos = 0usize;
        while pos < cues_body.len() {
            let (eid, eid_len, _) = Self::ebml_vint(cues_body, pos, false)?;
            let (esz, esz_len, is_unk) = Self::ebml_vint(cues_body, pos + eid_len, true)?;
            if is_unk {
                return None;
            }
            let c_start = pos + eid_len + esz_len;
            let c_end = c_start.checked_add(esz as usize)?;
            if c_end > cues_body.len() {
                return None;
            }
            if eid == 0xBB {
                let mut cue_time_ticks: Option<u64> = None;
                let mut cluster_rel: Option<u64> = None;
                let mut cp = c_start;
                while cp < c_end {
                    let (fid, fid_len, _) = Self::ebml_vint(cues_body, cp, false)?;
                    let (fsz, fsz_len, funk) = Self::ebml_vint(cues_body, cp + fid_len, true)?;
                    if funk {
                        return None;
                    }
                    let f_start = cp + fid_len + fsz_len;
                    let f_end = f_start.checked_add(fsz as usize)?;
                    if f_end > c_end {
                        return None;
                    }
                    if fid == 0xB3 {
                        cue_time_ticks = Self::ebml_be_uint(&cues_body[f_start..f_end]);
                    } else if fid == 0xB7 {
                        let mut tp = f_start;
                        while tp < f_end {
                            let (tid, tid_len, _) = Self::ebml_vint(cues_body, tp, false)?;
                            let (tsz, tsz_len, tunk) =
                                Self::ebml_vint(cues_body, tp + tid_len, true)?;
                            if tunk {
                                return None;
                            }
                            let t_start = tp + tid_len + tsz_len;
                            let t_end = t_start.checked_add(tsz as usize)?;
                            if t_end > f_end {
                                return None;
                            }
                            if tid == 0xF1 && cluster_rel.is_none() {
                                cluster_rel = Self::ebml_be_uint(&cues_body[t_start..t_end]);
                            }
                            tp = t_end;
                        }
                    }
                    cp = f_end;
                }
                if let (Some(ticks), Some(rel)) = (cue_time_ticks, cluster_rel) {
                    let ms = ((ticks as u128 * scale_ns as u128) / 1_000_000) as i64;
                    anchors.push((seg_data_start.saturating_add(rel), ms));
                }
            }
            pos = c_end;
        }
        if anchors.is_empty() {
            None
        } else {
            Some(anchors)
        }
    }

    /// Extracts `(cluster_byte_offset, time_ms)` anchors from Matroska/WebM `Cues` in `head` or `tail`.
    pub fn extract_mkv_anchors(head: &[u8], tail: &[u8]) -> Option<Vec<(u64, i64)>> {
        let (seg_data_start, scale_ns, _) = Self::parse_mkv_stream_info(head)?;
        for source in [head, tail] {
            if source.len() < 8 {
                continue;
            }
            for (idx, w) in source.windows(4).enumerate() {
                if w != [0x1C, 0x53, 0xBB, 0x6B] {
                    continue;
                }
                let Some((cues_sz, sz_len, is_unk)) = Self::ebml_vint(source, idx + 4, true)
                else {
                    continue;
                };
                if is_unk || cues_sz == 0 {
                    continue;
                }
                let body_start = idx + 4 + sz_len;
                let Some(body_end) = body_start.checked_add(cues_sz as usize) else {
                    continue;
                };
                if body_end > source.len() {
                    continue;
                }
                if let Some(pts) =
                    Self::parse_mkv_cues_slice(&source[body_start..body_end], seg_data_start, scale_ns)
                {
                    return Some(pts);
                }
            }
        }
        None
    }

    /// Scans a Matroska/WebM byte `slice` rooted at `slice_offset` for a validated `Cluster`
    /// element (`0x1F 0x43 0xB6 0x75`) + `Timestamp` (`0xE7`) and returns `(cluster_byte, time_ms)`.
    pub fn extract_mkv_cluster_anchor_in_slice(
        slice: &[u8],
        slice_offset: u64,
        timecode_scale_ns: u64,
        max_dur_ms: i64,
    ) -> Option<(u64, i64)> {
        if timecode_scale_ns == 0 || slice.len() < 16 {
            return None;
        }
        for i in 0..slice.len().saturating_sub(12) {
            if slice[i..i + 4] != [0x1F, 0x43, 0xB6, 0x75] {
                continue;
            }
            let Some((cl_sz, cl_sz_len, cl_unk)) = Self::ebml_vint(slice, i + 4, true) else {
                continue;
            };
            if !cl_unk && cl_sz > 64 * 1024 * 1024 {
                continue;
            }
            let mut inner = i + 4 + cl_sz_len;
            // Skip optional Cluster-leading elements such as CRC-32 (0xBF), Position (0xA7),
            // PrevSize (0xAB), or SilentTracks (0x5854) before Timestamp (0xE7).
            for _ in 0..4 {
                if inner + 3 >= slice.len() {
                    break;
                }
                if slice[inner] == 0xE7 {
                    break;
                }
                let Some((cid, cid_len, _)) = Self::ebml_vint(slice, inner, false) else {
                    break;
                };
                if !matches!(cid, 0xBF | 0xA7 | 0xAB | 0x5854) {
                    break;
                }
                let Some((csz, csz_len, cunk)) = Self::ebml_vint(slice, inner + cid_len, true)
                else {
                    break;
                };
                if cunk || csz > 4096 {
                    break;
                }
                let next_inner = inner + cid_len + csz_len + csz as usize;
                if next_inner >= slice.len() {
                    break;
                }
                inner = next_inner;
            }
            if inner + 3 >= slice.len() || slice[inner] != 0xE7 {
                continue;
            }
            let Some((ts_sz, ts_sz_len, ts_unk)) = Self::ebml_vint(slice, inner + 1, true) else {
                continue;
            };
            if ts_unk || !(1..=8).contains(&ts_sz) {
                continue;
            }
            let ts_start = inner + 1 + ts_sz_len;
            let ts_end = ts_start + ts_sz as usize;
            if ts_end >= slice.len() {
                continue;
            }
            let Some(ticks) = Self::ebml_be_uint(&slice[ts_start..ts_end]) else {
                continue;
            };
            // Verify the byte right after Timestamp begins a valid MKV Cluster child tag
            // (`SimpleBlock` 0xA3, `BlockGroup` 0xA0, `Position` 0xA7, `PrevSize` 0xAB, `SilentTracks` 0x58).
            if !matches!(slice[ts_end], 0xA3 | 0xA0 | 0xA7 | 0xAB | 0x58) {
                continue;
            }
            let ms = ((ticks as u128 * timecode_scale_ns as u128) / 1_000_000) as i64;
            if max_dur_ms > 0 && ms > max_dur_ms + 2_000 {
                continue;
            }
            return Some((slice_offset.saturating_add(i as u64), ms));
        }
        None
    }

    /// Scans a WavPack header slice for the byte offset of the first audio block (`block_samples > 0`).
    pub fn parse_wavpack_first_block_offset(head: &[u8]) -> Option<u64> {
        for (i, w) in head.windows(4).enumerate() {
            if w != b"wvpk" || i + wavicle::block::HEADER_LEN > head.len() {
                continue;
            }
            let hdr_arr: &[u8; wavicle::block::HEADER_LEN] =
                head[i..i + wavicle::block::HEADER_LEN].try_into().ok()?;
            if let Ok(hdr) = wavicle::block::BlockHeader::parse(hdr_arr) {
                let blen = hdr.block_len();
                if hdr.block_samples > 0 && blen >= wavicle::block::HEADER_LEN && blen <= 4 * 1024 * 1024 {
                    return Some(i as u64);
                }
            }
        }
        None
    }

    /// Scans a WavPack `slice` (rooted at `slice_offset`) for a validated `wvpk` block header
    /// and returns `(block_byte_offset, time_ms)`.
    pub fn extract_wavpack_anchor_in_slice(
        slice: &[u8],
        slice_offset: u64,
        sample_rate: u32,
        max_dur_ms: i64,
    ) -> Option<(u64, i64)> {
        if sample_rate == 0 || slice.len() < wavicle::block::HEADER_LEN {
            return None;
        }
        for i in 0..=slice.len() - wavicle::block::HEADER_LEN {
            if &slice[i..i + 4] != b"wvpk" {
                continue;
            }
            let hdr_arr: &[u8; wavicle::block::HEADER_LEN] =
                slice[i..i + wavicle::block::HEADER_LEN].try_into().ok()?;
            let Ok(hdr) = wavicle::block::BlockHeader::parse(hdr_arr) else {
                continue;
            };
            let blen = hdr.block_len();
            if blen < wavicle::block::HEADER_LEN
                || blen > 2 * 1024 * 1024
                || hdr.block_samples == 0
                || hdr.block_samples > sample_rate.saturating_mul(10)
            {
                continue;
            }
            if i + blen + 4 <= slice.len() && &slice[i + blen..i + blen + 4] != b"wvpk" {
                continue;
            }
            let ms = ((hdr.block_index as u128 * 1000) / sample_rate as u128) as i64;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_verified_anchor_overrides_stale_nearby_and_enforces_monotonicity() {
        let mut map = ByteTimeMap::new(100_000, 1_100_000, 100_000);
        map.set_anchors(vec![
            (300_000, 22_000),
            (600_000, 54_000), // intentionally stale +4s
            (900_000, 80_000),
        ]);
        map.record_verified_anchor(602_000, 50_000);
        assert_eq!(map.byte_to_ms(602_000, true), 50_000);
        assert_eq!(map.byte_to_ms(100_000, true), 0);
        // Contradictory 54s anchor at 600_000 must have been pruned.
        assert!(map.anchors().iter().all(|&(b, _)| b != 600_000));
    }

    #[test]
    fn parse_real_mkv_webm_cues_and_wavpack_headers_if_present() {
        let mka_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../example/assets/music/11_Mar_de_cristal.mka");
        if mka_path.exists() {
            let raw = std::fs::read(mka_path).unwrap();
            let head = &raw[..raw.len().min(200_000)];
            let tail = &raw[raw.len().saturating_sub(65_536)..];
            let (_, scale, first_cl) = ByteTimeMap::parse_mkv_stream_info(head).unwrap();
            assert_eq!(scale, 1_000_000);
            assert!(first_cl.unwrap() > 100_000);
            let cues = ByteTimeMap::extract_mkv_anchors(head, tail).unwrap();
            assert!(cues.len() >= 30, "expected >=30 MKA CuePoints, got {}", cues.len());
            assert_eq!(cues[0].1, 0);
        }

        let mkv_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../example/assets/music/14_Painting_the_Sky.mkv");
        if mkv_path.exists() {
            let raw = std::fs::read(mkv_path).unwrap();
            let head = &raw[..raw.len().min(200_000)];
            let (_, scale, first_cl) = ByteTimeMap::parse_mkv_stream_info(head).unwrap();
            assert!(first_cl.is_some());
            let mid = raw.len() / 2;
            let slice = &raw[mid..raw.len().min(mid + 128 * 1024)];
            let pt = ByteTimeMap::extract_mkv_cluster_anchor_in_slice(
                slice,
                mid as u64,
                scale,
                200_000,
            );
            assert!(pt.is_some(), "expected Cluster+Timestamp in MKV mid slice");
        }
    }

    #[test]
    fn ogg_anchors_map_page_end_not_page_start() {
        // Construct two consecutive OggS pages with known lengths and granules at 48kHz.
        let mut slice = Vec::new();
        for (idx, (g, body_len)) in [(48_000i64, 4usize), (96_000i64, 4usize)].iter().enumerate() {
            let _ = idx;
            let mut hdr = [0u8; 28];
            hdr[0..4].copy_from_slice(b"OggS");
            hdr[6..14].copy_from_slice(&g.to_le_bytes());
            hdr[14..18].copy_from_slice(&0x1234_5678u32.to_le_bytes());
            hdr[26] = 1;
            hdr[27] = *body_len as u8;
            slice.extend_from_slice(&hdr);
            slice.extend(std::iter::repeat_n(0xAAu8, *body_len));
        }
        let pts = ByteTimeMap::extract_ogg_anchors_in_slice(&slice, 1000, 0x1234_5678, 48_000, 0);
        assert_eq!(pts, vec![(1032, 1000), (1064, 2000)]);
    }
}
