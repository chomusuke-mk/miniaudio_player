//! Deterministic Audio Stream Classification, Header Demuxing, and Boundary Calculation.

use std::io::{Read, Seek, SeekFrom};

/// Recognized container and codec encapsulation formats.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContainerFormat {
    /// Unidentified audio format.
    Unknown = 0,
    /// MPEG-1/2 Audio Layer III.
    Mp3 = 1,
    /// AAC in Audio Data Transport Stream (ADTS).
    Adts = 2,
    /// Free Lossless Audio Codec.
    Flac = 3,
    /// Ogg Vorbis stream.
    OggVorbis = 4,
    /// Ogg Opus stream.
    OggOpus = 5,
    /// RIFF / WAVE container.
    Wav = 6,
    /// ISO Base Media File Format (MP4 / M4A).
    Mp4 = 7,
    /// Matroska / WebM container.
    Matroska = 8,
    /// Direct Stream Digital (DSF / DSD).
    Dsf = 9,
    /// Monkey's Audio (APE).
    Ape = 10,
    /// WavPack hybrid lossless/lossy container.
    WavPack = 11,
    /// HTTP Live Streaming (HLS / M3U8).
    Hls = 12,
    /// AIFF / AIFF-C (`FORM`).
    Aiff = 13,
    /// Apple Core Audio Format (`caff`).
    Caf = 14,
}

impl ContainerFormat {
    /// Returns the canonical Symphonia hint extension for this container format.
    #[inline]
    pub const fn hint_extension(self) -> Option<&'static str> {
        match self {
            Self::Mp3 => Some("mp3"),
            Self::Adts => Some("aac"),
            Self::Flac => Some("flac"),
            Self::OggVorbis | Self::OggOpus => Some("ogg"),
            Self::Wav => Some("wav"),
            Self::Mp4 => Some("mp4"),
            Self::Matroska => Some("mkv"),
            Self::Dsf => Some("dsf"),
            Self::Ape => Some("ape"),
            Self::WavPack => Some("wv"),
            Self::Hls => Some("m3u8"),
            Self::Aiff => Some("aiff"),
            Self::Caf => Some("caf"),
            Self::Unknown => None,
        }
    }
}

/// Boundary detection status.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoundaryStatus {
    /// Container format not supported.
    Unsupported = -1,
    /// Additional bytes required to resolve boundary.
    NeedMore = 0,
    /// Header boundary located successfully.
    Found = 1,
}

/// Calculated audio payload offsets and metadata boundaries within a container.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundaryInfo {
    /// Identified container format.
    pub container: ContainerFormat,
    /// Byte offset where audio payload begins.
    pub audio_start: i64,
    /// Byte offset where audio payload ends (-1 if unbounded/live).
    pub audio_end: i64,
    /// Number of stream bytes needed to resolve the container boundary when status is `NeedMore`.
    pub needed_bytes: i64,
}

impl Default for BoundaryInfo {
    /// Returns a default uninitialized [`BoundaryInfo`] with unknown container and `-1` bounds.
    fn default() -> Self {
        Self::new()
    }
}

impl BoundaryInfo {
    /// Constructs a new [`BoundaryInfo`] initialized to [`ContainerFormat::Unknown`].
    pub const fn new() -> Self {
        Self {
            container: ContainerFormat::Unknown,
            audio_start: -1,
            audio_end: -1,
            needed_bytes: 0,
        }
    }

    /// Populates `self` for `container` whose audio payload spans `[start, total_size]`, setting
    /// `audio_start` to `start` and `audio_end` to `total_size`.
    #[inline]
    fn set_direct_container(&mut self, container: ContainerFormat, start: i64, total_size: i64) {
        self.container = container;
        self.audio_start = start;
        self.audio_end = total_size;
    }
}

/// Maximum number of leading stream bytes scanned when searching for container headers (`64 MiB`).
const MAX_HEAD_SCAN: i64 = 64 * 1024 * 1024;
/// Maximum byte distance scanned for MPEG/ADTS frame sync after any leading ID3v2 tags (`64 KiB`).
const SYNC_SCAN_LIMIT: i64 = 65536;

/// Sony Wave64 top-level RIFF chunk GUID.
const W64_RIFF_MAGIC: [u8; 16] = [
    0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00, 0x00,
];
/// Sony Wave64 WAVE form-type GUID.
const W64_WAVE_MAGIC: [u8; 16] = [
    0x77, 0x61, 0x76, 0x65, 0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0x00, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a,
];
/// Standard MPEG-4 ADTS sampling frequency lookup table indexed by the 4-bit header `sr_idx`.
const ADTS_SAMPLE_RATES: [u32; 13] = [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
];

/// Classified stream region emitted by [`StreamClassifier`] during byte ingestion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClassifiedSlice<'a> {
    /// Minimal container and codec header configuration (`Head`).
    DecoderHead(&'a [u8]),
    /// Framed audio payload (`Body`).
    AudioPayload(&'a [u8]),
    /// Metadata chunk (ID3, VorbisComment, RIFF INFO, MP4 moov, ICY) with its virtual stream offset (`Metadata`).
    MetadataChunk {
        /// Virtual stream byte offset where `data` originates.
        offset: u64,
        /// Raw metadata slice bytes.
        data: &'a [u8],
    },
}

/// Zero-copy stream classifier separating container headers, pure audio payloads, and sparse metadata.
pub struct StreamClassifier;

impl StreamClassifier {
    /// Classifies `initial_data` and optional trailing `(tail_bytes, tail_offset)` in `tail_data`
    /// for a stream of `total_size` bytes into `Head`, `Body`, and `Metadata` slices.
    pub fn classify_initial_stream<'a>(
        initial_data: &'a [u8],
        tail_data: Option<(&'a [u8], u64)>,
        total_size: i64,
    ) -> (BoundaryInfo, Vec<ClassifiedSlice<'a>>) {
        let mut slices = Vec::new();
        if initial_data.is_empty() {
            crate::map_log!(2, "[CLASSIFIER] Empty initial_data passed to classify_initial_stream");
            return (BoundaryInfo::new(), slices);
        }

        let (status, boundary) = Self::detect_head_boundary(initial_data, total_size);
        if boundary.audio_start > 0 {
            let head_len = (boundary.audio_start as usize).min(initial_data.len());
            let head_slice = &initial_data[..head_len];
            slices.push(ClassifiedSlice::DecoderHead(head_slice));
            slices.push(ClassifiedSlice::MetadataChunk {
                offset: 0,
                data: head_slice,
            });
            if initial_data.len() > head_len {
                slices.push(ClassifiedSlice::AudioPayload(&initial_data[head_len..]));
            }
        } else {
            slices.push(ClassifiedSlice::AudioPayload(initial_data));
            if boundary.container == ContainerFormat::Aiff && initial_data.len() >= 12 {
                // Expose the FORM metadata header + SSND header in the Metadata buffer so
                // `MetadataStreamReader` can seek across `SSND` straight into trailing `ID3 ` chunks.
                let mut p: usize = 12;
                let mut head_end: Option<usize> = None;
                while p + 8 <= initial_data.len() {
                    if &initial_data[p..p + 4] == b"SSND" {
                        head_end = Some((p + 8).min(initial_data.len()));
                        break;
                    }
                    let sz = be32(&initial_data[p + 4..p + 8]) as usize;
                    let Some(next_p) = 8usize
                        .checked_add(sz)
                        .and_then(|n| n.checked_add(sz & 1))
                        .and_then(|n| p.checked_add(n))
                    else {
                        break;
                    };
                    p = next_p;
                }
                let meta_len = head_end.unwrap_or_else(|| initial_data.len().min(65536));
                if meta_len > 0 {
                    slices.push(ClassifiedSlice::MetadataChunk {
                        offset: 0,
                        data: &initial_data[..meta_len],
                    });
                }
            }
        }

        if let Some((tail_bytes, tail_offset)) = tail_data {
            if !tail_bytes.is_empty() {
                slices.push(ClassifiedSlice::MetadataChunk {
                    offset: tail_offset,
                    data: tail_bytes,
                });
            }
        }

        crate::map_log!(
            4,
            "[CLASSIFIER] Classified initial stream ({}B, total_size={}): status={:?}, container={:?}, audio_start={}, audio_end={}, slices={}",
            initial_data.len(),
            total_size,
            status,
            boundary.container,
            boundary.audio_start,
            boundary.audio_end,
            slices.len()
        );

        (boundary, slices)
    }

    /// Extracts a normalized file extension hint from a path or URL `source` (ignoring query strings).
    pub fn extract_extension_hint(source: &str) -> Option<&'static str> {
        let clean = source.split('?').next().unwrap_or(source);
        let ext = clean.rsplit('.').next()?;
        match ext.to_ascii_lowercase().as_str() {
            "mp3" => Some("mp3"),
            "wav" | "bwf" => Some("wav"),
            "flac" => Some("flac"),
            "ogg" | "oga" | "opus" => Some("ogg"),
            "aac" | "adts" => Some("aac"),
            "m4a" | "mp4" | "m4b" => Some("mp4"),
            "aif" | "aiff" | "aifc" => Some("aiff"),
            "caf" => Some("caf"),
            "w64" => Some("w64"),
            "rf64" => Some("rf64"),
            "rifx" => Some("rifx"),
            "dsf" => Some("dsf"),
            "wv" => Some("wv"),
            "ape" => Some("ape"),
            "mkv" | "mka" => Some("mka"),
            "webm" => Some("webm"),
            "m3u8" | "m3u" => Some("m3u8"),
            _ => None,
        }
    }

    /// Whether `container` format can contain trailing metadata, tags, or seek cues.
    #[inline]
    pub fn container_needs_tail_scan(container: ContainerFormat) -> bool {
        matches!(
            container,
            ContainerFormat::Mp3
                | ContainerFormat::Adts
                | ContainerFormat::Flac
                | ContainerFormat::Ape
                | ContainerFormat::WavPack
                | ContainerFormat::OggVorbis
                | ContainerFormat::OggOpus
                | ContainerFormat::Matroska
        )
    }

    /// Parses the pinned head bytes `data` for a stream of `total_size` bytes to determine the
    /// container format, audio payload start, and metadata bounds.
    pub fn detect_head_boundary(data: &[u8], total_size: i64) -> (BoundaryStatus, BoundaryInfo) {
        let (status, info) = Self::detect_head_boundary_inner(data, total_size);
        match status {
            BoundaryStatus::Found => crate::map_log!(
                4,
                "[CLASSIFIER] Head boundary found: container={:?}, start={}, end={}",
                info.container,
                info.audio_start,
                info.audio_end
            ),
            BoundaryStatus::NeedMore => crate::map_log!(
                5,
                "[CLASSIFIER] Head boundary needs more bytes: avail={}, needed={}, total_size={}",
                data.len(),
                info.needed_bytes,
                total_size
            ),
            BoundaryStatus::Unsupported => crate::map_log!(
                4,
                "[CLASSIFIER] Head boundary unsupported/unrecognized (avail={}, total_size={})",
                data.len(),
                total_size
            ),
        }
        (status, info)
    }

    /// Internal implementation of [`StreamClassifier::detect_head_boundary`] inspecting `data`
    /// with total stream size `total_size`.
    fn detect_head_boundary_inner(data: &[u8], total_size: i64) -> (BoundaryStatus, BoundaryInfo) {
        let mut info = BoundaryInfo::new();
        let avail = data.len();

        if avail < 12 {
            let status = Self::need_more(&mut info, 12, total_size, avail);
            return (status, info);
        }

        if (data.starts_with(b"RIFF") || data.starts_with(b"RF64")) && &data[8..12] == b"WAVE" {
            return (Self::detect_wav(data, total_size, &mut info), info);
        }
        if data.starts_with(b"RIFX") && &data[8..12] == b"WAVE" {
            return (Self::detect_rifx(data, total_size, &mut info), info);
        }
        if data.starts_with(b"FORM") && (&data[8..12] == b"AIFF" || &data[8..12] == b"AIFC") {
            return (Self::detect_aiff(data, total_size, &mut info), info);
        }
        if data.starts_with(b"caff") {
            return (Self::detect_caf(data, total_size, &mut info), info);
        }
        if data.starts_with(&W64_RIFF_MAGIC) && avail >= 40 && data[24..40] == W64_WAVE_MAGIC {
            return (Self::detect_w64(data, total_size, &mut info), info);
        }
        if data.starts_with(b"fLaC") {
            return (Self::detect_flac(data, total_size, 0, &mut info), info);
        }
        if data.starts_with(b"OggS") {
            return (Self::detect_ogg(data, total_size, &mut info), info);
        }
        if &data[4..8] == b"ftyp" {
            return (Self::detect_mp4(data, total_size, &mut info), info);
        }
        if data.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
            return (Self::detect_mkv(data, total_size, &mut info), info);
        }
        if data.starts_with(b"#EXTM3U") || data.starts_with(b"#EXT-X-") {
            info.set_direct_container(ContainerFormat::Hls, 0, total_size);
            return (BoundaryStatus::Found, info);
        }
        if let Some(container) = Self::match_lossless_magic(data) {
            let mut audio_start = 0i64;
            let mut audio_end = total_size;
            if container == ContainerFormat::Dsf && avail >= 28 {
                let meta_off = le64(&data[20..28]) as i64;
                if meta_off > 0 && (total_size <= 0 || meta_off < total_size) {
                    audio_end = meta_off;
                }
                let fmt_size = if avail >= 40 && &data[28..32] == b"fmt " {
                    le64(&data[32..40]).clamp(52, 4096) as usize
                } else {
                    52
                };
                let dsf_data_start = 28 + fmt_size + 12;
                if avail >= dsf_data_start {
                    audio_start = dsf_data_start as i64;
                }
            }
            info.set_direct_container(container, audio_start, audio_end);
            return (BoundaryStatus::Found, info);
        }

        // Advance past any leading ID3v2 tags
        let p = match Self::skip_id3v2_chain(data, total_size, &mut info) {
            Ok(offset) => offset,
            Err(status) => return (status, info),
        };

        if p + 4 > avail {
            return (
                Self::need_more(&mut info, (p + 4) as i64, total_size, avail),
                info,
            );
        }

        if data[p..].starts_with(b"fLaC") {
            return (
                Self::detect_flac(data, total_size, p as i64, &mut info),
                info,
            );
        }
        if let Some(container) = Self::match_lossless_magic(&data[p..]) {
            let mut audio_start = p as i64;
            let mut audio_end = total_size;
            if container == ContainerFormat::Dsf && avail >= p + 28 {
                let meta_off = le64(&data[p + 20..p + 28]) as i64;
                if meta_off > 0 && (total_size <= 0 || meta_off < total_size) {
                    audio_end = meta_off;
                }
                let fmt_size = if avail >= p + 40 && &data[p + 28..p + 32] == b"fmt " {
                    le64(&data[p + 32..p + 40]).clamp(52, 4096) as usize
                } else {
                    52
                };
                let dsf_data_start = p + 28 + fmt_size + 12;
                if avail >= dsf_data_start {
                    audio_start = dsf_data_start as i64;
                }
            }
            info.set_direct_container(container, audio_start, audio_end);
            return (BoundaryStatus::Found, info);
        }

        (
            Self::detect_mpeg(data, total_size, p as i64, &mut info),
            info,
        )
    }

    /// Matches leading lossless container magic bytes (`DSD `, `MAC `, `wvpk`) at the start of `slice`.
    fn match_lossless_magic(slice: &[u8]) -> Option<ContainerFormat> {
        if slice.starts_with(b"DSD ") {
            Some(ContainerFormat::Dsf)
        } else if slice.starts_with(b"MAC ") {
            Some(ContainerFormat::Ape)
        } else if slice.starts_with(b"wvpk") {
            Some(ContainerFormat::WavPack)
        } else {
            None
        }
    }

    /// Advances past any chained leading ID3v2 tags in `data` (bounded by `total_size`), updating
    /// `info` (`info.needed_bytes`) if additional bytes are required.
    fn skip_id3v2_chain(
        data: &[u8],
        total_size: i64,
        info: &mut BoundaryInfo,
    ) -> Result<usize, BoundaryStatus> {
        let avail = data.len();
        let mut p = 0usize;
        loop {
            if p + 10 > avail {
                return Err(Self::need_more(info, (p + 10) as i64, total_size, avail));
            }
            let t = &data[p..];
            if &t[0..3] == b"ID3"
                && t[3] != 0xFF
                && t[4] != 0xFF
                && ((t[6] | t[7] | t[8] | t[9]) & 0x80) == 0
            {
                let tag_size = synchsafe32(&t[6..10]) as usize;
                let footer = if (t[5] & 0x10) != 0 { 10 } else { 0 };
                p += 10 + tag_size + footer;
                if p as i64 > MAX_HEAD_SCAN || (total_size > 0 && p as i64 > total_size) {
                    return Err(BoundaryStatus::Unsupported);
                }
                continue;
            }
            return Ok(p);
        }
    }

    /// Parses trailing `tail` bytes starting at `tail_offset` for `container` (with total stream
    /// size `total_size` and payload start `audio_start`) to strip ID3v1, APE, or Lyrics3 tags and
    /// compute the true audio payload end.
    pub fn detect_tail_boundary(
        container: ContainerFormat,
        tail: &[u8],
        tail_offset: i64,
        total_size: i64,
        audio_start: i64,
    ) -> (BoundaryStatus, i64) {
        if total_size <= 0 {
            return (BoundaryStatus::Unsupported, total_size);
        }
        if !Self::container_needs_tail_scan(container) {
            return (BoundaryStatus::Found, total_size);
        }
        if container == ContainerFormat::Matroska {
            return (BoundaryStatus::Found, total_size);
        }
        if tail.is_empty() || tail_offset + tail.len() as i64 != total_size {
            return (BoundaryStatus::Unsupported, total_size);
        }

        let floor = audio_start.max(0);
        let mut end = total_size;

        loop {
            if let Some(res) = Self::strip_id3v1_tail(tail, tail_offset, floor, end) {
                match res {
                    Ok(new_end) => {
                        end = new_end;
                        continue;
                    }
                    Err((status, req_off)) => return (status, req_off),
                }
            }
            if let Some(res) = Self::strip_ape_tail(tail, tail_offset, floor, end) {
                match res {
                    Ok(new_end) => {
                        end = new_end;
                        continue;
                    }
                    Err((status, req_off)) => return (status, req_off),
                }
            }
            if let Some(res) = Self::strip_lyrics3v2_tail(tail, tail_offset, floor, end) {
                match res {
                    Ok(new_end) => {
                        end = new_end;
                        continue;
                    }
                    Err((status, req_off)) => return (status, req_off),
                }
            }
            if let Some(res) = Self::strip_id3v2_footer_tail(tail, tail_offset, floor, end) {
                match res {
                    Ok(new_end) => {
                        end = new_end;
                        continue;
                    }
                    Err((status, req_off)) => return (status, req_off),
                }
            }
            break;
        }

        if end != total_size {
            crate::map_log!(
                4,
                "[CLASSIFIER] Stripped trailing tags for {:?}: total_size={} -> audio_end={}",
                container,
                total_size,
                end
            );
        }

        (BoundaryStatus::Found, end)
    }

    /// Strips a trailing ID3v1 (`TAG`) and optional ID3v1 Enhanced (`TAG+`) block ending at `end`
    /// within `tail` (anchored at `tail_offset` and bounded below by `floor`).
    fn strip_id3v1_tail(
        tail: &[u8],
        tail_offset: i64,
        floor: i64,
        end: i64,
    ) -> Option<Result<i64, (BoundaryStatus, i64)>> {
        if end - 128 < floor {
            return None;
        }
        if end - 128 < tail_offset {
            return Some(Err((BoundaryStatus::NeedMore, (end - 128).max(floor))));
        }
        let idx = (end - 128 - tail_offset) as usize;
        if !tail[idx..].starts_with(b"TAG") {
            return None;
        }
        let mut new_end = end - 128;
        if new_end - 227 >= floor && new_end - 227 >= tail_offset {
            let e_idx = (new_end - 227 - tail_offset) as usize;
            if tail[e_idx..].starts_with(b"TAG+") {
                new_end -= 227;
            }
        }
        Some(Ok(new_end))
    }

    /// Strips a trailing `APETAGEX` footer/tag ending at `end` within `tail` (anchored at
    /// `tail_offset` and bounded below by `floor`).
    fn strip_ape_tail(
        tail: &[u8],
        tail_offset: i64,
        floor: i64,
        end: i64,
    ) -> Option<Result<i64, (BoundaryStatus, i64)>> {
        if end - 32 < floor || end - 32 < tail_offset {
            return None;
        }
        let idx = (end - 32 - tail_offset) as usize;
        let f = &tail[idx..];
        if !f.starts_with(b"APETAGEX") {
            return None;
        }
        let ape_size = le32(&f[12..16]);
        let ape_flags = le32(&f[20..24]);
        let ape_total = ape_size as i64 + if (ape_flags & 0x80000000) != 0 { 32 } else { 0 };
        if ape_total < 32 || end - ape_total < floor {
            return None;
        }
        let new_end = end - ape_total;
        if new_end < tail_offset {
            Some(Err((BoundaryStatus::NeedMore, new_end)))
        } else {
            Some(Ok(new_end))
        }
    }

    /// Strips a trailing Lyrics3v2 (`LYRICS200`) block ending at `end` within `tail` (anchored at
    /// `tail_offset` and bounded below by `floor`).
    fn strip_lyrics3v2_tail(
        tail: &[u8],
        tail_offset: i64,
        floor: i64,
        end: i64,
    ) -> Option<Result<i64, (BoundaryStatus, i64)>> {
        if end - 15 < floor || end - 15 < tail_offset {
            return None;
        }
        let lyr_idx = (end - 9 - tail_offset) as usize;
        if !tail[lyr_idx..].starts_with(b"LYRICS200") {
            return None;
        }
        let s_idx = (end - 15 - tail_offset) as usize;
        let mut lyrics_size = 0i64;
        for &b in &tail[s_idx..s_idx + 6] {
            if !b.is_ascii_digit() {
                return None;
            }
            lyrics_size = lyrics_size * 10 + (b - b'0') as i64;
        }
        let lyr_total = lyrics_size + 15;
        if end - lyr_total < floor {
            return None;
        }
        let new_end = end - lyr_total;
        if new_end < tail_offset {
            Some(Err((BoundaryStatus::NeedMore, new_end)))
        } else {
            Some(Ok(new_end))
        }
    }

    /// Strips an appended ID3v2.4 footer (`3DI`) tag ending at `end` within `tail` (anchored at
    /// `tail_offset` and bounded below by `floor`).
    fn strip_id3v2_footer_tail(
        tail: &[u8],
        tail_offset: i64,
        floor: i64,
        end: i64,
    ) -> Option<Result<i64, (BoundaryStatus, i64)>> {
        if end - 10 < floor || end - 10 < tail_offset {
            return None;
        }
        let idx = (end - 10 - tail_offset) as usize;
        let f = &tail[idx..];
        if !f.starts_with(b"3DI") || ((f[6] | f[7] | f[8] | f[9]) & 0x80) != 0 {
            return None;
        }
        let id3_total = synchsafe32(&f[6..10]) as i64 + 20;
        if end - id3_total < floor {
            return None;
        }
        let new_end = end - id3_total;
        if new_end < tail_offset {
            Some(Err((BoundaryStatus::NeedMore, new_end)))
        } else {
            Some(Ok(new_end))
        }
    }

    /// Extracts stream duration in milliseconds from trailing Ogg Vorbis/Opus page granule
    /// positions in `tail` for `container` at `sample_rate` (forced to `48000` for Opus).
    pub fn extract_tail_duration_ms(
        container: ContainerFormat,
        sample_rate: u32,
        tail: &[u8],
    ) -> Option<i64> {
        if tail.len() < 27 {
            return None;
        }
        if !matches!(
            container,
            ContainerFormat::OggVorbis | ContainerFormat::OggOpus
        ) {
            return None;
        }
        let srate = if container == ContainerFormat::OggOpus {
            48000
        } else {
            sample_rate
        };
        if srate == 0 {
            return None;
        }

        let scan_start = tail.len() - 27;
        for j in (0..=scan_start).rev() {
            if tail[j..].starts_with(b"OggS") && tail[j + 4] == 0 {
                let granule_pos = le64(&tail[j + 6..j + 14]);
                if granule_pos > 0 && granule_pos != u64::MAX {
                    let dur_ms = (granule_pos.saturating_mul(1000) / srate as u64) as i64;
                    if dur_ms > 0 {
                        return Some(dur_ms);
                    }
                }
            }
        }
        None
    }

    /// Inspects MPEG audio frames and Xing/VBRI headers in `data` (with optional `total_size`) to
    /// compute `(bitrate_bps, estimated_duration_ms)`.
    pub fn sniff_mp3_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        let avail = data.len();
        if avail < 10 || Self::has_non_mpeg_magic(data) {
            return None;
        }

        let (start_offset, id3_total_size) = Self::initial_id3v2_skip(data);
        if start_offset + 4 > avail {
            return None;
        }

        let scan_limit = (start_offset + 32768).min(avail);
        for i in start_offset..scan_limit.saturating_sub(3) {
            let h = &data[i..];
            let mut hdr = MpegHeader::default();
            if !parse_mpeg_header(h, &mut hdr) {
                continue;
            }

            if i + hdr.frame_size as usize + 4 <= avail {
                let mut nh = MpegHeader::default();
                if !parse_mpeg_header(&data[i + hdr.frame_size as usize..], &mut nh) {
                    continue;
                }
            }

            if let Some(info) = Self::try_parse_xing_vbr(data, i, avail, total_size, &hdr) {
                return Some(info);
            }
            if let Some(info) = Self::try_parse_vbri(data, i, avail, &hdr) {
                return Some(info);
            }

            let bitrate = hdr.bitrate_kbps * 1000;
            let duration_ms = if total_size > 0 {
                let audio_bytes = if total_size > id3_total_size as i64 {
                    total_size - id3_total_size as i64
                } else {
                    total_size
                };
                ((audio_bytes as u64 * 8000) / bitrate as u64) as i64
            } else {
                0
            };
            return Some((bitrate, duration_ms));
        }

        None
    }

    /// Returns `true` if `data` starts with a known non-MPEG container magic signature.
    fn has_non_mpeg_magic(data: &[u8]) -> bool {
        if data.len() >= 4
            && (data.starts_with(b"RIFF")
                || data.starts_with(b"RF64")
                || data.starts_with(b"fLaC")
                || data.starts_with(b"FORM")
                || data.starts_with(b"OggS"))
        {
            return true;
        }
        data.len() >= 8 && &data[4..8] == b"ftyp"
    }

    /// Returns `(clamped_offset, total_id3v2_bytes)` for a single leading ID3v2 header in `data`.
    fn initial_id3v2_skip(data: &[u8]) -> (usize, u32) {
        if data.starts_with(b"ID3") && data.len() >= 10 {
            let mut id3_total = 10 + synchsafe32(&data[6..10]);
            if (data[5] & 0x10) != 0 {
                id3_total += 10;
            }
            ((id3_total as usize).min(data.len()), id3_total)
        } else {
            (0, 0)
        }
    }

    /// Attempts to parse a Xing or Info VBR/CBR header inside `data` at `frame_offset` (within
    /// `avail` bytes and optional stream `total_size`) using the parsed MPEG frame `hdr`.
    fn try_parse_xing_vbr(
        data: &[u8],
        frame_offset: usize,
        avail: usize,
        total_size: i64,
        hdr: &MpegHeader,
    ) -> Option<(u32, i64)> {
        let xing_offset = 4 + (if hdr.has_crc { 2 } else { 0 }) + hdr.side_info as usize;
        if hdr.layer != 1 || frame_offset + xing_offset + 12 > avail {
            return None;
        }
        let tag = &data[frame_offset + xing_offset..];
        if !tag.starts_with(b"Xing") && !tag.starts_with(b"Info") {
            return None;
        }
        let flags = be32(&tag[4..8]);
        if (flags & 0x01) == 0 {
            return None;
        }
        let total_mpeg_frames = be32(&tag[8..12]);
        let samples_per_frame = if hdr.ver == 3 { 1152 } else { 576 };
        let total_pcm = total_mpeg_frames as u64 * samples_per_frame as u64;
        let duration_ms = (total_pcm as f64 * 1000.0 / hdr.sample_rate as f64 + 0.5) as i64;
        let bitrate = if (flags & 0x02) != 0 && duration_ms > 0 && tag.len() >= 16 {
            let total_audio_bytes = be32(&tag[12..16]);
            ((total_audio_bytes as u64 * 8000) / duration_ms as u64) as u32
        } else if total_size > 0 && duration_ms > 0 {
            ((total_size as u64 * 8000) / duration_ms as u64) as u32
        } else {
            hdr.bitrate_kbps * 1000
        };
        Some((bitrate, duration_ms))
    }

    /// Attempts to parse a Fraunhofer VBRI header inside `data` at `frame_offset` (within `avail`
    /// bytes) using the parsed MPEG frame `hdr`.
    fn try_parse_vbri(
        data: &[u8],
        frame_offset: usize,
        avail: usize,
        hdr: &MpegHeader,
    ) -> Option<(u32, i64)> {
        let vbri_offset = 4 + (if hdr.has_crc { 2 } else { 0 }) + 32;
        if hdr.layer != 1 || frame_offset + vbri_offset + 18 > avail {
            return None;
        }
        let tag = &data[frame_offset + vbri_offset..];
        if !tag.starts_with(b"VBRI") {
            return None;
        }
        let total_mpeg_frames = be32(&tag[14..18]);
        let samples_per_frame = if hdr.ver == 3 { 1152 } else { 576 };
        let total_pcm = total_mpeg_frames as u64 * samples_per_frame as u64;
        let duration_ms = (total_pcm as f64 * 1000.0 / hdr.sample_rate as f64 + 0.5) as i64;
        let bitrate = if duration_ms > 0 {
            let total_audio_bytes = be32(&tag[10..14]);
            ((total_audio_bytes as u64 * 8000) / duration_ms as u64) as u32
        } else {
            hdr.bitrate_kbps * 1000
        };
        Some((bitrate, duration_ms))
    }

    /// Reads Vorbis identification headers from `data` (with optional `total_size`) to determine
    /// nominal `(bitrate_bps, duration_ms)`.
    pub fn sniff_ogg_vorbis_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        if data.len() < 40 || !data.starts_with(b"OggS") {
            return None;
        }

        let scan_limit = data.len().min(4096);
        for i in 0..scan_limit.saturating_sub(27) {
            if data[i..].starts_with(b"\x01vorbis") {
                let sample_rate = le32(&data[i + 12..i + 16]);
                let bitrate_nominal = le32(&data[i + 20..i + 24]) as i32;
                let bitrate_max = le32(&data[i + 16..i + 20]) as i32;

                if total_size > 0 && data.len() as i64 >= total_size && sample_rate > 0 {
                    if let Some(dur_ms) = Self::extract_tail_duration_ms(
                        ContainerFormat::OggVorbis,
                        sample_rate,
                        data,
                    ) {
                        let br = ((total_size as u64 * 8000) / dur_ms as u64) as u32;
                        return Some((br, dur_ms));
                    }
                }

                let br = if bitrate_nominal > 0 {
                    bitrate_nominal as u32
                } else if bitrate_max > 0 {
                    bitrate_max as u32
                } else {
                    0
                };

                if br > 0 {
                    let dur_ms = if total_size > 0 {
                        ((total_size as u64 * 8000) / br as u64) as i64
                    } else {
                        0
                    };
                    return Some((br, dur_ms));
                }
            }
        }
        None
    }

    /// Reads `OpusHead` identification headers from `data` (with optional `total_size`) to
    /// determine `(bitrate_bps, duration_ms)`.
    pub fn sniff_ogg_opus_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        if data.len() < 40 || !data.starts_with(b"OggS") {
            return None;
        }

        let scan_limit = data.len().min(4096);
        for i in 0..scan_limit.saturating_sub(18) {
            if data[i..].starts_with(b"OpusHead") {
                if total_size > 0 && data.len() as i64 >= total_size {
                    if let Some(dur_ms) =
                        Self::extract_tail_duration_ms(ContainerFormat::OggOpus, 48000, data)
                    {
                        let br = ((total_size as u64 * 8000) / dur_ms as u64) as u32;
                        return Some((br, dur_ms));
                    }
                }

                let channels = data[i + 9];
                let br = if channels >= 2 { 128000 } else { 64000 };
                let dur_ms = if total_size > 0 {
                    ((total_size as u64 * 8000) / br as u64) as i64
                } else {
                    0
                };
                return Some((br, dur_ms));
            }
        }
        None
    }

    /// Inspects ADTS AAC headers in `data` (with stream `total_size`) to calculate
    /// `(bitrate_bps, duration_ms)`.
    pub fn sniff_adts_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        if data.len() < 7 || total_size <= 0 {
            return None;
        }
        let mut dummy = BoundaryInfo::new();
        let start_search = Self::skip_id3v2_chain(data, total_size, &mut dummy).unwrap_or(0);
        let scan_limit = data.len().saturating_sub(6).min(start_search + 4096);
        for i in start_search..scan_limit {
            let h = &data[i..];
            if is_adts_sync(h) {
                let sr_idx = ((h[2] >> 2) & 0x0F) as usize;
                if let Some(&sr) = ADTS_SAMPLE_RATES.get(sr_idx) {
                    let mut pos = i;
                    let mut total_samples = 0u64;
                    let mut total_frame_bytes = 0u64;
                    let mut frame_count = 0u64;

                    while pos + 7 <= data.len() {
                        let fh = &data[pos..];
                        if !is_adts_sync(fh) {
                            break;
                        }
                        let flen = ((fh[3] as usize & 0x03) << 11)
                            | ((fh[4] as usize) << 3)
                            | ((fh[5] as usize) >> 5);
                        if flen < 7 || pos + flen > data.len() {
                            break;
                        }
                        let blocks = (fh[6] as u64 & 0x03) + 1;
                        total_samples += blocks * 1024;
                        total_frame_bytes += flen as u64;
                        frame_count += 1;
                        pos += flen;
                    }

                    if frame_count > 0 {
                        let audio_total = (total_size as u64).saturating_sub(i as u64);
                        let dur_ms = if data.len() as i64 >= total_size && total_samples > 0 {
                            (total_samples * 1000) / sr as u64
                        } else {
                            let avg_flen = total_frame_bytes as f64 / frame_count as f64;
                            let est_frames = audio_total as f64 / avg_flen;
                            (est_frames * 1024.0 * 1000.0 / sr as f64).round() as u64
                        } as i64;

                        let bitrate = if dur_ms > 0 {
                            ((audio_total * 8000) / dur_ms as u64) as u32
                        } else {
                            0
                        };
                        return Some((bitrate, dur_ms));
                    }
                }
            }
        }
        None
    }

    /// Samples ADTS frame lengths across multiple interior offsets (`5%..94%`) of a seekable
    /// `reader` with total length `total_bytes` to estimate `(sample_rate, channels, duration_ms)`
    /// for VBR ADTS streams without scanning every frame over the network.
    pub fn sample_adts_duration_ms<R: Read + Seek>(reader: &mut R, total_bytes: u64) -> Option<(u32, u32, u64)> {
        if total_bytes <= 512 * 1024 {
            return Self::scan_adts_stream(reader);
        }
        let orig_pos = reader.stream_position().ok()?;
        let _ = reader.seek(SeekFrom::Start(0));

        // Skip any chained ID3v2 headers to locate true first ADTS frame.
        let mut first_frame_pos = 0u64;
        loop {
            let mut hdr = [0u8; 10];
            if reader.seek(SeekFrom::Start(first_frame_pos)).is_err()
                || reader.read_exact(&mut hdr).is_err()
            {
                let _ = reader.seek(SeekFrom::Start(orig_pos));
                return None;
            }
            if &hdr[0..3] == b"ID3" {
                let tag_len = (((hdr[6] as u64 & 0x7F) << 21)
                    | ((hdr[7] as u64 & 0x7F) << 14)
                    | ((hdr[8] as u64 & 0x7F) << 7)
                    | (hdr[9] as u64 & 0x7F))
                    + 10
                    + if (hdr[5] & 0x10) != 0 { 10 } else { 0 };
                first_frame_pos = first_frame_pos.saturating_add(tag_len);
                if first_frame_pos >= total_bytes {
                    let _ = reader.seek(SeekFrom::Start(orig_pos));
                    return None;
                }
            } else {
                break;
            }
        }

        let mut head7 = [0u8; 7];
        if reader.seek(SeekFrom::Start(first_frame_pos)).is_err()
            || reader.read_exact(&mut head7).is_err()
            || !is_adts_sync(&head7)
        {
            let _ = reader.seek(SeekFrom::Start(orig_pos));
            return None;
        }
        let sr_idx = (head7[2] >> 2) & 0x0F;
        let ch_cfg = (((head7[2] & 0x01) << 2) | ((head7[3] >> 6) & 0x03)) as u32;
        let sample_rate = *ADTS_SAMPLE_RATES.get(sr_idx as usize)?;
        let channels = match ch_cfg {
            1..=6 => ch_cfg,
            7 => 8,
            _ => 2,
        };

        let audio_len = total_bytes.saturating_sub(first_frame_pos);
        if audio_len < 65_536 {
            let _ = reader.seek(SeekFrom::Start(orig_pos));
            return Self::scan_adts_stream(reader);
        }

        let mut sample_buf = vec![0u8; 32 * 1024];
        let mut total_frame_bytes = 0u64;
        let mut total_samples = 0u64;

        let quarter = audio_len / 4;
        let probe_offsets = [
            first_frame_pos + (audio_len * 10) / 100,
            first_frame_pos + quarter,
            first_frame_pos + quarter * 2,
            first_frame_pos + quarter * 3,
            first_frame_pos + (audio_len * 90) / 100,
        ];
        for probe_off in probe_offsets {
            if probe_off + 1024 >= total_bytes {
                continue;
            }
            if reader.seek(SeekFrom::Start(probe_off)).is_err() {
                continue;
            }
            let mut got = 0usize;
            while got < sample_buf.len() {
                match reader.read(&mut sample_buf[got..]) {
                    Ok(0) => break,
                    Ok(n) => got += n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            let buf = &sample_buf[..got];
            // Find 3 consecutive ADTS frames sharing identical sample_rate/channel config.
            let mut start_i = None;
            for i in 0..buf.len().saturating_sub(21) {
                let f0 = &buf[i..];
                if !is_adts_sync(f0)
                    || ((f0[2] >> 2) & 0x0F) != sr_idx
                    || (((f0[2] & 0x01) << 2) | ((f0[3] >> 6) & 0x03)) != ch_cfg as u8
                {
                    continue;
                }
                let l0 = ((f0[3] as usize & 0x03) << 11) | ((f0[4] as usize) << 3) | ((f0[5] as usize) >> 5);
                if l0 < 7 || i + l0 + 7 > buf.len() {
                    continue;
                }
                let f1 = &buf[i + l0..];
                if !is_adts_sync(f1) || ((f1[2] >> 2) & 0x0F) != sr_idx {
                    continue;
                }
                let l1 = ((f1[3] as usize & 0x03) << 11) | ((f1[4] as usize) << 3) | ((f1[5] as usize) >> 5);
                if l1 < 7 || i + l0 + l1 + 7 > buf.len() {
                    continue;
                }
                if is_adts_sync(&buf[i + l0 + l1..]) {
                    start_i = Some(i);
                    break;
                }
            }

            if let Some(mut pos) = start_i {
                while pos + 7 <= buf.len() {
                    let fh = &buf[pos..];
                    if !is_adts_sync(fh) || ((fh[2] >> 2) & 0x0F) != sr_idx {
                        break;
                    }
                    let flen = ((fh[3] as usize & 0x03) << 11)
                        | ((fh[4] as usize) << 3)
                        | ((fh[5] as usize) >> 5);
                    if flen < 7 || pos + flen > buf.len() {
                        break;
                    }
                    let blocks = (fh[6] as u64 & 0x03) + 1;
                    total_samples += blocks * 1024;
                    total_frame_bytes += flen as u64;
                    pos += flen;
                }
            }
        }

        let _ = reader.seek(SeekFrom::Start(orig_pos));
        if total_frame_bytes > 0 && total_samples > 0 {
            let est_samples = (audio_len as f64 / total_frame_bytes as f64) * total_samples as f64;
            let dur_ms = (est_samples * 1000.0 / sample_rate as f64).round() as u64;
            crate::map_log!(
                4,
                "[CLASSIFIER] Sampled ADTS duration: sr={}Hz, ch={}, dur_ms={}",
                sample_rate,
                channels,
                dur_ms
            );
            Some((sample_rate, channels, dur_ms))
        } else {
            None
        }
    }

    /// Fast, seek-based exact ADTS frame scanner over seekable `reader` (files, memory cursors).
    /// Scans frame headers by jumping payload lengths without decoding, returning
    /// `(sample_rate, channels, duration_ms)`.
    pub fn scan_adts_stream<R: Read + Seek>(reader: &mut R) -> Option<(u32, u32, u64)> {
        let start_pos = reader.stream_position().ok()?;

        let mut header = [0u8; 10];
        if reader.read_exact(&mut header).is_err() {
            let _ = reader.seek(SeekFrom::Start(start_pos));
            return None;
        }

        let mut first_frame_pos = start_pos;
        if &header[0..3] == b"ID3" {
            let tag_len = (((header[6] as u64 & 0x7F) << 21)
                | ((header[7] as u64 & 0x7F) << 14)
                | ((header[8] as u64 & 0x7F) << 7)
                | (header[9] as u64 & 0x7F))
                + 10;
            let footer_len = if (header[5] & 0x10) != 0 { 10 } else { 0 };
            first_frame_pos = start_pos + tag_len + footer_len;
            if reader.seek(SeekFrom::Start(first_frame_pos)).is_err() {
                let _ = reader.seek(SeekFrom::Start(start_pos));
                return None;
            }
            if reader.read_exact(&mut header[0..7]).is_err() {
                let _ = reader.seek(SeekFrom::Start(start_pos));
                return None;
            }
        }

        let h = &header[0..7];
        if !is_adts_sync(h) {
            let _ = reader.seek(SeekFrom::Start(start_pos));
            return None;
        }

        let sr_idx = ((h[2] >> 2) & 0x0F) as usize;
        let sample_rate = *ADTS_SAMPLE_RATES.get(sr_idx)?;
        let ch_cfg = (((h[2] & 0x01) << 2) | ((h[3] >> 6) & 0x03)) as u32;
        let channels = match ch_cfg {
            1..=6 => ch_cfg,
            7 => 8,
            _ => 2,
        };

        if reader.seek(SeekFrom::Start(first_frame_pos)).is_err() {
            let _ = reader.seek(SeekFrom::Start(start_pos));
            return None;
        }

        let mut total_samples = 0u64;
        let mut frame_buf = [0u8; 7];

        while reader.read_exact(&mut frame_buf).is_ok() {
            if !is_adts_sync(&frame_buf) {
                break;
            }
            let flen = ((frame_buf[3] as u64 & 0x03) << 11)
                | ((frame_buf[4] as u64) << 3)
                | ((frame_buf[5] as u64) >> 5);
            if flen < 7 {
                break;
            }
            let blocks = (frame_buf[6] & 0x03) as u64 + 1;
            total_samples += blocks * 1024;

            let payload = flen - 7;
            if reader.seek(SeekFrom::Current(payload as i64)).is_err() {
                break;
            }
        }

        let _ = reader.seek(SeekFrom::Start(start_pos));

        if sample_rate > 0 && total_samples > 0 {
            let duration_ms = (total_samples * 1000) / sample_rate as u64;
            crate::map_log!(
                4,
                "[CLASSIFIER] Scanned ADTS stream: sr={}Hz, ch={}, dur_ms={}",
                sample_rate,
                channels,
                duration_ms
            );
            Some((sample_rate, channels, duration_ms))
        } else {
            None
        }
    }

    /// High-level sniffer combining format probes over `data` and `total_size` to extract nominal
    /// `(bitrate_bps, duration_ms)`.
    pub fn sniff_stream_info(data: &[u8], total_size: i64) -> Option<(u32, i64)> {
        Self::sniff_mp3_stream_info(data, total_size)
            .or_else(|| Self::sniff_adts_stream_info(data, total_size))
            .or_else(|| Self::sniff_ogg_vorbis_stream_info(data, total_size))
            .or_else(|| Self::sniff_ogg_opus_stream_info(data, total_size))
    }

    /// Detects the bitrate encoding mode (`CBR`, `VBR`, or `Unknown`) from stream header `data`,
    /// `container`, `codec`, and `lossless` hint.
    pub fn detect_bitrate_mode(
        data: &[u8],
        container: ContainerFormat,
        codec: &str,
        lossless: bool,
    ) -> crate::api::types::RustBitrateMode {
        use crate::api::types::RustBitrateMode;

        match codec {
            "PCM" | "DSD" | "ALAW" | "ULAW" | "ADPCM" => return RustBitrateMode::Cbr,
            "FLAC" | "ALAC" | "APE" | "WavPack" | "Opus" => return RustBitrateMode::Vbr,
            _ => {}
        }
        if lossless {
            return RustBitrateMode::Vbr;
        }

        if container == ContainerFormat::Mp3 || matches!(codec, "MP3" | "MP2" | "MP1") {
            let (start_offset, _) = Self::initial_id3v2_skip(data);
            let avail = data.len();
            let scan_limit = (start_offset + 32768).min(avail);
            for i in start_offset..scan_limit.saturating_sub(3) {
                let mut hdr = MpegHeader::default();
                if !parse_mpeg_header(&data[i..], &mut hdr) {
                    continue;
                }
                if i + hdr.frame_size as usize + 4 <= avail {
                    let mut nh = MpegHeader::default();
                    if !parse_mpeg_header(&data[i + hdr.frame_size as usize..], &mut nh) {
                        continue;
                    }
                }
                let xing_off = 4 + (if hdr.has_crc { 2 } else { 0 }) + hdr.side_info as usize;
                if hdr.layer == 1 && i + xing_off + 4 <= avail {
                    let tag = &data[i + xing_off..];
                    if tag.starts_with(b"Xing") {
                        return RustBitrateMode::Vbr;
                    }
                    if tag.starts_with(b"Info") {
                        return RustBitrateMode::Cbr;
                    }
                }
                let vbri_off = 4 + (if hdr.has_crc { 2 } else { 0 }) + 32;
                if hdr.layer == 1 && i + vbri_off + 4 <= avail && data[i + vbri_off..].starts_with(b"VBRI") {
                    return RustBitrateMode::Vbr;
                }

                // Compare consecutive frame bitrates
                let mut pos = i + hdr.frame_size as usize;
                let mut checked = 0;
                while pos + 4 <= avail && checked < 8 {
                    let mut fh = MpegHeader::default();
                    if !parse_mpeg_header(&data[pos..], &mut fh) {
                        break;
                    }
                    if fh.bitrate_kbps != hdr.bitrate_kbps {
                        return RustBitrateMode::Vbr;
                    }
                    pos += fh.frame_size as usize;
                    checked += 1;
                }
                return RustBitrateMode::Cbr;
            }
            return RustBitrateMode::Cbr;
        }

        if container == ContainerFormat::OggVorbis || codec == "Vorbis" {
            let scan_limit = data.len().min(4096);
            for i in 0..scan_limit.saturating_sub(28) {
                if data[i..].starts_with(b"\x01vorbis") {
                    let br_max = le32(&data[i + 16..i + 20]) as i32;
                    let br_min = le32(&data[i + 24..i + 28]) as i32;
                    if br_min > 0 && br_max > 0 && br_min == br_max {
                        return RustBitrateMode::Cbr;
                    }
                    return RustBitrateMode::Vbr;
                }
            }
            return RustBitrateMode::Vbr;
        }

        if container == ContainerFormat::Adts {
            let scan_limit = data.len().saturating_sub(6).min(4096);
            for i in 0..scan_limit {
                if is_adts_sync(&data[i..]) {
                    let fh = &data[i..];
                    let fullness = (((fh[5] as u16) & 0x1F) << 6) | ((fh[6] as u16) >> 2);
                    if fullness == 0x7FF {
                        return RustBitrateMode::Vbr;
                    }
                    let first_len = ((fh[3] as usize & 0x03) << 11)
                        | ((fh[4] as usize) << 3)
                        | ((fh[5] as usize) >> 5);
                    let mut pos = i + first_len;
                    let mut checked = 0;
                    while pos + 7 <= data.len() && checked < 6 {
                        let nh = &data[pos..];
                        if !is_adts_sync(nh) {
                            break;
                        }
                        let nlen = ((nh[3] as usize & 0x03) << 11)
                            | ((nh[4] as usize) << 3)
                            | ((nh[5] as usize) >> 5);
                        if nlen.abs_diff(first_len) > 2 {
                            return RustBitrateMode::Vbr;
                        }
                        pos += nlen;
                        checked += 1;
                    }
                    return RustBitrateMode::Cbr;
                }
            }
        }

        if codec == "AAC" {
            return RustBitrateMode::Vbr;
        }

        RustBitrateMode::Unknown
    }

    /// Requests `needed` total bytes in `out` when `needed` exceeds `available` (bounded by
    /// `total_size` and `MAX_HEAD_SCAN`), returning [`BoundaryStatus::NeedMore`] or
    /// [`BoundaryStatus::Unsupported`].
    fn need_more(
        out: &mut BoundaryInfo,
        needed: i64,
        total_size: i64,
        available: usize,
    ) -> BoundaryStatus {
        let mut n = needed;
        if n > MAX_HEAD_SCAN {
            return BoundaryStatus::Unsupported;
        }
        if total_size > 0 && n > total_size {
            n = total_size;
        }
        if n <= available as i64 {
            return BoundaryStatus::Unsupported;
        }
        out.needed_bytes = n;
        BoundaryStatus::NeedMore
    }

    /// Walks RIFF / RF64 `WAVE` chunks in `d` (with stream size `total`) to populate `out` at the
    /// `data` chunk payload boundary.
    fn detect_wav(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let rf64 = d.starts_with(b"RF64");
        let mut ds64_data: u64 = 0;
        let mut p: usize = 12;

        loop {
            if p + 8 > d.len() {
                return Self::need_more(out, (p + 8) as i64, total, d.len());
            }

            let c = &d[p..];
            let size = le32(&c[4..8]);

            if rf64 && c.starts_with(b"ds64") {
                if p + 24 > d.len() {
                    return Self::need_more(out, (p + 24) as i64, total, d.len());
                }
                ds64_data = le64(&c[16..24]);
            }

            if c.starts_with(b"data") {
                let mut data_size = size as u64;
                if rf64 && size == 0xFFFFFFFF {
                    data_size = ds64_data;
                }

                out.container = ContainerFormat::Wav;
                out.audio_start = (p + 8) as i64;
                if data_size == 0 || data_size == 0xFFFFFFFF {
                    out.audio_end = if total > 0 { total } else { -1 };
                } else {
                    out.audio_end = out.audio_start + data_size as i64;
                    if total > 0 && out.audio_end > total {
                        out.audio_end = total;
                    }
                }
                return BoundaryStatus::Found;
            }

            p += 8 + size as usize + (size as usize & 1);
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    /// Walks big-endian `RIFX` `WAVE` chunks in `d` (with stream size `total`) to populate `out`.
    fn detect_rifx(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 12;

        loop {
            if p + 8 > d.len() {
                return Self::need_more(out, (p + 8) as i64, total, d.len());
            }

            let c = &d[p..];
            let size = be32(&c[4..8]);

            if c.starts_with(b"data") {
                out.container = ContainerFormat::Wav;
                out.audio_start = (p + 8) as i64;
                out.audio_end = out.audio_start + size as i64;
                if total > 0 && out.audio_end > total {
                    out.audio_end = total;
                }
                return BoundaryStatus::Found;
            }

            p += 8 + size as usize + (size as usize & 1);
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    /// Walks AIFF / AIFF-C (`FORM`) chunks in `d` (with stream size `total`) to find `SSND` and
    /// populate `out` with `audio_start = 0`.
    fn detect_aiff(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        /// Maximum AIFF header prefix scanned (`4 MiB`) before assuming offset `0..total`.
        const AIFF_MAX_HEADER_SCAN: usize = 4 * 1024 * 1024;
        // `AiffReader` requires reading from offset 0 (`FORM` -> `COMM` -> `SSND`).
        let found_at_start = |out: &mut BoundaryInfo| {
            out.set_direct_container(ContainerFormat::Aiff, 0, total);
            BoundaryStatus::Found
        };
        let mut p: usize = 12;

        loop {
            if p + 8 > d.len() {
                if p >= AIFF_MAX_HEADER_SCAN || (total > 0 && p as i64 >= total) {
                    return found_at_start(out);
                }
                return Self::need_more(out, (p + 16) as i64, total, d.len());
            }

            let c = &d[p..];
            let size = be32(&c[4..8]) as usize;

            if c.starts_with(b"SSND") {
                if p + 16 > d.len() && (total <= 0 || (p + 16) as i64 <= total) {
                    return Self::need_more(out, (p + 16) as i64, total, d.len());
                }
                let ssnd_end = 8usize
                    .checked_add(size)
                    .and_then(|n| n.checked_add(size & 1))
                    .and_then(|n| p.checked_add(n));
                let effective_end = match ssnd_end {
                    Some(end) if end > 0 && (total <= 0 || (end as i64) <= total) => end as i64,
                    _ => total,
                };
                out.set_direct_container(ContainerFormat::Aiff, 0, effective_end);
                return BoundaryStatus::Found;
            }

            let Some(next_p) = 8usize
                .checked_add(size)
                .and_then(|n| n.checked_add(size & 1))
                .and_then(|n| p.checked_add(n))
            else {
                return found_at_start(out);
            };
            p = next_p;
            if p >= AIFF_MAX_HEADER_SCAN || (total > 0 && p as i64 >= total) {
                return found_at_start(out);
            }
        }
    }

    /// Walks Apple Core Audio Format (`caff`) chunks in `d` (with stream size `total`) to locate
    /// the `data` chunk payload and populate `out`.
    fn detect_caf(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        /// Maximum CAF header prefix scanned (`4 MiB`) before falling back to offset `0..total`.
        const CAF_MAX_HEADER_SCAN: usize = 4 * 1024 * 1024;
        if d.len() < 8 || &d[0..4] != b"caff" || u16::from_be_bytes([d[4], d[5]]) != 1 {
            out.set_direct_container(ContainerFormat::Caf, 0, total);
            return BoundaryStatus::Found;
        }
        let mut p: usize = 8;

        loop {
            if p + 12 > d.len() {
                if p >= CAF_MAX_HEADER_SCAN || (total > 0 && p as i64 >= total) {
                    out.set_direct_container(ContainerFormat::Caf, 0, total);
                    return BoundaryStatus::Found;
                }
                return Self::need_more(out, (p + 32) as i64, total, d.len());
            }

            let chunk_id = &d[p..p + 4];
            let chunk_size = i64::from_be_bytes([
                d[p + 4],
                d[p + 5],
                d[p + 6],
                d[p + 7],
                d[p + 8],
                d[p + 9],
                d[p + 10],
                d[p + 11],
            ]);

            if chunk_id == b"data" {
                let data_hdr_end = p + 16;
                if data_hdr_end > d.len() && (total <= 0 || (data_hdr_end as i64) <= total) {
                    return Self::need_more(out, data_hdr_end as i64, total, d.len());
                }
                out.container = ContainerFormat::Caf;
                out.audio_start = data_hdr_end as i64;
                out.audio_end = if chunk_size >= 4 {
                    let end = out.audio_start.saturating_add(chunk_size - 4);
                    if total > 0 {
                        end.min(total)
                    } else {
                        end
                    }
                } else {
                    total
                };
                return BoundaryStatus::Found;
            }

            if chunk_size < 0 {
                out.set_direct_container(ContainerFormat::Caf, 0, total);
                return BoundaryStatus::Found;
            }

            let Some(next_p) = (p + 12).checked_add(chunk_size as usize) else {
                out.set_direct_container(ContainerFormat::Caf, 0, total);
                return BoundaryStatus::Found;
            };
            p = next_p;
            if p >= CAF_MAX_HEADER_SCAN || (total > 0 && p as i64 >= total) {
                out.set_direct_container(ContainerFormat::Caf, 0, total);
                return BoundaryStatus::Found;
            }
        }
    }

    /// Reads an EBML variable-length integer at `pos` inside `d`, stripping the VINT marker bit
    /// when `mask_leading` is `true`, and returns `(value, byte_width, is_all_ones_unknown)`.
    fn read_ebml_vint(d: &[u8], pos: usize, mask_leading: bool) -> Option<(u64, usize, bool)> {
        let &first = d.get(pos)?;
        if first == 0 {
            return None;
        }
        let width = (first.leading_zeros() as usize) + 1;
        if width > 8 || pos + width > d.len() {
            return None;
        }
        let marker = 0x80u8 >> (width - 1);
        let value_mask = marker - 1;
        let mut val = if mask_leading {
            (first & value_mask) as u64
        } else {
            first as u64
        };
        let mut all_ones = mask_leading && (first & value_mask) == value_mask;
        for &b in &d[pos + 1..pos + width] {
            val = (val << 8) | (b as u64);
            if b != 0xFF {
                all_ones = false;
            }
        }
        Some((val, width, all_ones))
    }

    /// Walks EBML/Matroska elements in `d` (with stream size `total`) to locate the first
    /// `Cluster` element and populate `out`.
    fn detect_mkv(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        /// Maximum Matroska header prefix scanned (`8 MiB`) while searching for `Cluster`.
        const MKV_MAX_HEADER_SCAN: usize = 8 * 1024 * 1024;
        /// EBML element ID for the top-level Matroska `Segment`.
        const MKV_SEGMENT_ID: u64 = 0x1853_8067;
        /// EBML element ID for the first audio/video `Cluster`.
        const MKV_CLUSTER_ID: u64 = 0x1F43_B675;
        let fallback = |out: &mut BoundaryInfo| {
            out.set_direct_container(ContainerFormat::Matroska, 0, total);
            BoundaryStatus::Found
        };

        let Some((_ebml_id, ebml_id_len, _)) = Self::read_ebml_vint(d, 0, false) else {
            return fallback(out);
        };
        let Some((ebml_sz, ebml_sz_len, ebml_unk)) = Self::read_ebml_vint(d, ebml_id_len, true)
        else {
            if ebml_id_len + 8 > d.len() {
                return Self::need_more(out, (ebml_id_len + 16) as i64, total, d.len());
            }
            return fallback(out);
        };
        if ebml_unk {
            return fallback(out);
        }
        let Some(seg_off) = usize::try_from(ebml_sz)
            .ok()
            .and_then(|s| s.checked_add(ebml_id_len + ebml_sz_len))
        else {
            return fallback(out);
        };
        if seg_off + 12 > d.len() {
            if seg_off >= MKV_MAX_HEADER_SCAN || (total > 0 && seg_off as i64 >= total) {
                return fallback(out);
            }
            return Self::need_more(out, (seg_off + 32) as i64, total, d.len());
        }

        let Some((seg_id, seg_id_len, _)) = Self::read_ebml_vint(d, seg_off, false) else {
            return fallback(out);
        };
        if seg_id != MKV_SEGMENT_ID {
            return fallback(out);
        }
        let Some((_seg_sz, seg_sz_len, _)) = Self::read_ebml_vint(d, seg_off + seg_id_len, true)
        else {
            return fallback(out);
        };

        let mut pos = seg_off + seg_id_len + seg_sz_len;
        for _ in 0..4096 {
            if pos + 12 > d.len() {
                if pos >= MKV_MAX_HEADER_SCAN || (total > 0 && pos as i64 >= total) {
                    return fallback(out);
                }
                return Self::need_more(out, (pos + 4096) as i64, total, d.len());
            }

            let Some((eid, eid_len, _)) = Self::read_ebml_vint(d, pos, false) else {
                return fallback(out);
            };
            if eid == MKV_CLUSTER_ID {
                out.set_direct_container(ContainerFormat::Matroska, pos as i64, total);
                return BoundaryStatus::Found;
            }

            let Some((esz, esz_len, is_unk)) = Self::read_ebml_vint(d, pos + eid_len, true) else {
                if pos + eid_len + 8 > d.len() {
                    return Self::need_more(out, (pos + eid_len + 32) as i64, total, d.len());
                }
                return fallback(out);
            };
            if is_unk {
                return fallback(out);
            }

            let hdr_end = pos + eid_len + esz_len;
            let Some(next_pos) = u64::try_from(hdr_end)
                .ok()
                .and_then(|n| n.checked_add(esz))
                .and_then(|n| usize::try_from(n).ok())
            else {
                return fallback(out);
            };

            if next_pos <= pos
                || next_pos >= MKV_MAX_HEADER_SCAN
                || (total > 0 && next_pos as i64 >= total)
            {
                return fallback(out);
            }
            if next_pos + 12 > d.len() {
                return Self::need_more(out, (next_pos + 4096) as i64, total, d.len());
            }
            pos = next_pos;
        }

        fallback(out)
    }

    /// Walks Sony Wave64 GUID chunks in `d` (with stream size `total`) to locate the `data` chunk
    /// and populate `out`.
    fn detect_w64(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 40;

        loop {
            if p + 24 > d.len() {
                return Self::need_more(out, (p + 24) as i64, total, d.len());
            }

            let c = &d[p..];
            let chunk_size = le64(&c[16..24]) as usize;
            if chunk_size < 24 {
                return BoundaryStatus::Unsupported;
            }

            if &c[0..4] == b"data" {
                out.container = ContainerFormat::Wav;
                out.audio_start = (p + 24) as i64;
                let data_size = chunk_size - 24;
                out.audio_end = out.audio_start + data_size as i64;
                if total > 0 && out.audio_end > total {
                    out.audio_end = total;
                }
                return BoundaryStatus::Found;
            }

            p += (chunk_size + 7) & !7;
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    /// Walks FLAC metadata blocks in `d` starting at `p` (with stream size `total`) until the
    /// `LAST_METADATA_BLOCK` flag, populating `out`.
    fn detect_flac(d: &[u8], total: i64, p: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut q = p + 4;
        let mut first = true;

        loop {
            if q + 4 > d.len() as i64 {
                return Self::need_more(out, q + 4, total, d.len());
            }

            let hb = d[q as usize];
            let is_last = (hb & 0x80) != 0;
            let block_type = hb & 0x7F;
            if block_type == 127 || (first && block_type != 0) {
                return BoundaryStatus::Unsupported;
            }

            let len = ((d[q as usize + 1] as u32) << 16)
                | ((d[q as usize + 2] as u32) << 8)
                | (d[q as usize + 3] as u32);
            q += 4 + len as i64;
            first = false;

            if q > MAX_HEAD_SCAN || (total > 0 && q > total) {
                return BoundaryStatus::Unsupported;
            }
            if is_last {
                out.container = ContainerFormat::Flac;
                out.audio_start = q;
                out.audio_end = -1;
                return BoundaryStatus::Found;
            }
        }
    }

    /// Walks Ogg pages in `d` (with stream size `total`) past the required Vorbis (3) or Opus (2)
    /// setup packets, populating `out`.
    fn detect_ogg(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 0;
        let mut serial: u32 = 0;
        let mut have_serial = false;
        let mut required: usize = 0;
        let mut packets: usize = 0;
        let mut container = ContainerFormat::Unknown;

        loop {
            if p + 27 > d.len() {
                return Self::need_more(out, (p + 27) as i64, total, d.len());
            }
            if !d[p..].starts_with(b"OggS") || d[p + 4] != 0 {
                return BoundaryStatus::Unsupported;
            }

            let nseg = d[p + 26] as usize;
            if p + 27 + nseg > d.len() {
                return Self::need_more(out, (p + 27 + nseg) as i64, total, d.len());
            }

            let body: usize = d[p + 27..p + 27 + nseg].iter().map(|&b| b as usize).sum();
            let body_start = p + 27 + nseg;
            let page_end = body_start + body;
            let ser = le32(&d[p + 14..p + 18]);

            if !have_serial {
                if (d[p + 5] & 0x02) == 0 {
                    return BoundaryStatus::Unsupported;
                }
                if body_start + 8 > d.len() {
                    return Self::need_more(out, (body_start + 8) as i64, total, d.len());
                }
                if d[body_start..].starts_with(b"\x01vorbis") {
                    required = 3;
                    container = ContainerFormat::OggVorbis;
                    out.container = ContainerFormat::OggVorbis;
                } else if d[body_start..].starts_with(b"OpusHead") {
                    required = 2;
                    container = ContainerFormat::OggOpus;
                    out.container = ContainerFormat::OggOpus;
                } else {
                    return BoundaryStatus::Unsupported;
                }
                serial = ser;
                have_serial = true;
            }

            if ser == serial {
                for &seg_len in &d[p + 27..p + 27 + nseg] {
                    if seg_len < 255 {
                        packets += 1;
                        if packets >= required {
                            out.container = container;
                            out.audio_start = page_end as i64;
                            out.audio_end = if total > 0 { total } else { -1 };
                            return BoundaryStatus::Found;
                        }
                    }
                }
            }

            p = page_end;
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    /// Walks ISO-BMFF/MP4 top-level atoms in `d` (with stream size `total`) to locate `mdat` or
    /// `moof` and populate `out`.
    fn detect_mp4(d: &[u8], total: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let mut p: usize = 0;
        loop {
            if p + 8 > d.len() {
                return Self::need_more(out, (p + 8) as i64, total, d.len());
            }

            let size32 = be32(&d[p..p + 4]);
            let atom_type = &d[p + 4..p + 8];
            let mut atom_size = size32 as u64;
            let mut hdr = 8;

            if size32 == 1 {
                if p + 16 > d.len() {
                    return Self::need_more(out, (p + 16) as i64, total, d.len());
                }
                atom_size = be64(&d[p + 8..p + 16]);
                hdr = 16;
            } else if size32 == 0 {
                atom_size = if total > 0 {
                    (total - p as i64) as u64
                } else {
                    0
                };
            }

            if atom_type == b"mdat" {
                out.container = ContainerFormat::Mp4;
                let mut audio_start = (p + hdr as usize) as i64;
                if let Some((_, anchors)) = crate::buffer::ByteTimeMap::extract_mp4_anchors(&d[..p])
                {
                    if let Some(&(first_soun_off, _)) = anchors.first() {
                        let off_i64 = first_soun_off as i64;
                        if off_i64 > audio_start && (off_i64 - audio_start) <= 65_536 {
                            if (d.len() as i64) < off_i64 {
                                return Self::need_more(out, off_i64, total, d.len());
                            }
                            audio_start = off_i64;
                        }
                    }
                }
                out.audio_start = audio_start;
                if size32 == 0 {
                    out.audio_end = if total > 0 { total } else { -1 };
                } else {
                    out.audio_end = p as i64 + atom_size as i64;
                    if total > 0 && out.audio_end > total {
                        out.audio_end = total;
                    }
                }
                if out.audio_end >= 0 && out.audio_end < out.audio_start {
                    out.audio_end = out.audio_start;
                }
                return BoundaryStatus::Found;
            }

            if atom_type == b"moof" {
                out.container = ContainerFormat::Mp4;
                out.audio_start = p as i64;
                out.audio_end = if total > 0 { total } else { -1 };
                return BoundaryStatus::Found;
            }

            if atom_size < hdr as u64 {
                return BoundaryStatus::Unsupported;
            }

            p += atom_size as usize;
            if p as i64 > MAX_HEAD_SCAN || (total > 0 && p as i64 >= total) {
                return BoundaryStatus::Unsupported;
            }
        }
    }

    /// Scans `d` starting at byte offset `p` (with stream size `total`) for consecutive ADTS or
    /// MPEG Layer I/II/III sync headers, populating `out` and skipping Xing/Info/VBRI frames.
    fn detect_mpeg(d: &[u8], total: i64, p: i64, out: &mut BoundaryInfo) -> BoundaryStatus {
        let limit = (p + SYNC_SCAN_LIMIT).min(d.len() as i64);

        for i in p..limit {
            if total > 0 && i + 4 > total {
                return BoundaryStatus::Unsupported;
            }
            if i + 7 > d.len() as i64 {
                return Self::need_more(out, i + 7, total, d.len());
            }

            let h = &d[i as usize..];
            if h[0] != 0xFF {
                continue;
            }

            if is_adts_sync(h) {
                let flen =
                    (((h[3] & 0x03) as u32) << 11) | ((h[4] as u32) << 3) | ((h[5] as u32) >> 5);
                if flen < 7 {
                    continue;
                }
                let next = i + flen as i64;
                if next + 2 <= d.len() as i64 {
                    let next_h = &d[next as usize..];
                    if !is_adts_sync(next_h) && !(next_h[0] == 0xFF && (next_h[1] & 0xF6) == 0xF0) {
                        continue;
                    }
                } else if total <= 0 || next + 2 <= total {
                    return Self::need_more(out, next + 7, total, d.len());
                }
                out.container = ContainerFormat::Adts;
                out.audio_start = i;
                out.audio_end = -1;
                return BoundaryStatus::Found;
            }

            let mut hdr = MpegHeader::default();
            if !parse_mpeg_header(h, &mut hdr) {
                continue;
            }

            let next = i + hdr.frame_size as i64;
            if next + 4 <= d.len() as i64 {
                let mut nh = MpegHeader::default();
                if !parse_mpeg_header(&d[next as usize..], &mut nh) {
                    continue;
                }
            } else if total <= 0 || next + 4 <= total {
                return Self::need_more(out, next + 4, total, d.len());
            }

            out.container = ContainerFormat::Mp3;
            out.audio_start = i;
            out.audio_end = -1;

            if hdr.layer == 1 && next <= d.len() as i64 {
                let xing = i + 4 + (if hdr.has_crc { 2 } else { 0 }) + hdr.side_info as i64;
                let vbri = i + 4 + 32;
                let is_vbr_frame = (xing + 4 <= next
                    && (d[xing as usize..].starts_with(b"Xing")
                        || d[xing as usize..].starts_with(b"Info")))
                    || (vbri + 4 <= next && d[vbri as usize..].starts_with(b"VBRI"));

                if is_vbr_frame {
                    out.audio_start = next;
                }
            }
            return BoundaryStatus::Found;
        }

        BoundaryStatus::Unsupported
    }
}

/// Parsed 4-byte MPEG audio frame header fields used for frame size calculation and VBR sniffing.
#[derive(Default)]
struct MpegHeader {
    /// Computed frame length in bytes.
    frame_size: u32,
    /// Side information byte offset before optional Xing/Info tag.
    side_info: u32,
    /// Encoded MPEG layer bits (`1` = Layer III, `2` = Layer II, `3` = Layer I).
    layer: u32,
    /// Encoded MPEG version bits (`3` = MPEG-1, `2` = MPEG-2, `0` = MPEG-2.5).
    ver: u32,
    /// Frame sampling rate in Hz.
    sample_rate: u32,
    /// Frame bitrate in kbps.
    bitrate_kbps: u32,
    /// `true` if the 16-bit CRC field immediately follows the 4-byte frame header.
    has_crc: bool,
}

/// Parses a 4-byte MPEG audio frame header from `h` into `out`, returning `true` if valid.
fn parse_mpeg_header(h: &[u8], out: &mut MpegHeader) -> bool {
    /// Bitrate table (kbps) for MPEG-1 Layer III.
    const MPEG1_L3: [u32; 16] = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ];
    /// Bitrate table (kbps) for MPEG-1 Layer II.
    const MPEG1_L2: [u32; 16] = [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0,
    ];
    /// Bitrate table (kbps) for MPEG-1 Layer I.
    const MPEG1_L1: [u32; 16] = [
        0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0,
    ];
    /// Bitrate table (kbps) for MPEG-2/2.5 Layer I.
    const MPEG2_L1: [u32; 16] = [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0,
    ];
    /// Bitrate table (kbps) for MPEG-2/2.5 Layer II and III.
    const MPEG2_L23: [u32; 16] = [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ];
    /// Sampling rate table (Hz) indexed by `[ver][sr_idx]`.
    const RATES: [[u32; 3]; 4] = [
        [11025, 12000, 8000],
        [0, 0, 0],
        [22050, 24000, 16000],
        [44100, 48000, 32000],
    ];

    if h.len() < 4 || h[0] != 0xFF || (h[1] & 0xE0) != 0xE0 {
        return false;
    }

    let ver = ((h[1] >> 3) & 0x03) as usize;
    let layer = ((h[1] >> 1) & 0x03) as u32;
    let br_idx = ((h[2] >> 4) & 0x0F) as usize;
    let sr_idx = ((h[2] >> 2) & 0x03) as usize;
    let padding = ((h[2] >> 1) & 0x01) as u32;
    let channel_mode = ((h[3] >> 6) & 0x03) as u32;

    if ver == 1 || layer == 0 || br_idx == 0 || br_idx == 15 || sr_idx == 3 || (h[3] & 0x03) == 2 {
        return false;
    }

    let kbps = if ver == 3 {
        if layer == 1 {
            MPEG1_L3[br_idx]
        } else if layer == 2 {
            MPEG1_L2[br_idx]
        } else {
            MPEG1_L1[br_idx]
        }
    } else if layer == 3 {
        MPEG2_L1[br_idx]
    } else {
        MPEG2_L23[br_idx]
    };

    let sr = RATES[ver][sr_idx];
    if kbps == 0 || sr == 0 {
        return false;
    }

    let fs = if layer == 3 {
        (12 * kbps * 1000 / sr + padding) * 4
    } else if layer == 2 || ver == 3 {
        144 * kbps * 1000 / sr + padding
    } else {
        72 * kbps * 1000 / sr + padding
    };
    if fs < 4 {
        return false;
    }

    out.frame_size = fs;
    out.layer = layer;
    out.ver = ver as u32;
    out.sample_rate = sr;
    out.bitrate_kbps = kbps;
    out.has_crc = (h[1] & 0x01) == 0;
    out.side_info = if layer == 1 {
        if ver == 3 {
            if channel_mode == 3 {
                17
            } else {
                32
            }
        } else if channel_mode == 3 {
            9
        } else {
            17
        }
    } else {
        0
    };

    true
}

/// Returns `true` if `h` begins with a valid 3-byte ADTS AAC frame sync prefix.
#[inline]
fn is_adts_sync(h: &[u8]) -> bool {
    h.len() >= 3
        && h[0] == 0xFF
        && (h[1] & 0xF6) == 0xF0
        && ((h[2] >> 6) & 0x03) != 3
        && ((h[2] >> 2) & 0x0F) <= 11
}

/// Decodes a 4-byte ID3v2 synchsafe big-endian integer from `b`.
#[inline]
fn synchsafe32(b: &[u8]) -> u32 {
    ((b[0] as u32 & 0x7F) << 21)
        | ((b[1] as u32 & 0x7F) << 14)
        | ((b[2] as u32 & 0x7F) << 7)
        | (b[3] as u32 & 0x7F)
}

/// Reads a little-endian `u32` from the first 4 bytes of `b`.
#[inline]
fn le32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

/// Reads a little-endian `u64` from the first 8 bytes of `b`.
#[inline]
fn le64(b: &[u8]) -> u64 {
    u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
}

/// Reads a big-endian `u32` from the first 4 bytes of `b`.
#[inline]
fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

/// Reads a big-endian `u64` from the first 8 bytes of `b`.
#[inline]
fn be64(b: &[u8]) -> u64 {
    u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
}
