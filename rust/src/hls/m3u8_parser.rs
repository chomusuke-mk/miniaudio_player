//! Deterministic M3U8 Master & Media Playlist Parser.

use std::collections::VecDeque;
use std::time::Duration;

use m3u8_rs::{Key, KeyMethod, MasterPlaylist, MediaPlaylist, MediaSegment, Playlist};

/// Metadata for an alternative variant stream in an HLS master playlist.
#[derive(Debug, Clone, PartialEq)]
pub struct VariantStreamInfo {
    /// URI of the variant media playlist.
    pub uri: String,
    /// Peak bitrate requirement in bits per second.
    pub bandwidth: u64,
    /// Codec specification string (e.g. "mp4a.40.2").
    pub codecs: Option<String>,
    /// Video resolution width and height, if present.
    pub resolution: Option<(u64, u64)>,
    /// Associated audio group identifier.
    pub audio: Option<String>,
}

/// Encryption key metadata extracted from `#EXT-X-KEY`.
#[derive(Debug, Clone, PartialEq)]
pub struct EncryptionKeyInfo {
    /// Encryption method ("AES-128", "SAMPLE-AES", etc.).
    pub method: String,
    /// URI to fetch the 16-byte cryptographic key.
    pub uri: Option<String>,
    /// Explicit 128-bit Initialization Vector in hex string form, if present.
    pub iv: Option<String>,
    /// Key format identifier (e.g. "identity").
    pub keyformat: Option<String>,
}

impl EncryptionKeyInfo {
    fn from_m3u8_key(key: &Key) -> Option<Self> {
        let method = match key.method {
            KeyMethod::None => return None,
            KeyMethod::AES128 => "AES-128".to_string(),
            KeyMethod::SampleAES => "SAMPLE-AES".to_string(),
            KeyMethod::Other(ref s) => s.clone(),
        };
        Some(Self {
            method,
            uri: key.uri.clone(),
            iv: key.iv.clone(),
            keyformat: key.keyformat.clone(),
        })
    }
}

/// Metadata describing a single HLS media segment (`#EXTINF`).
#[derive(Debug, Clone, PartialEq)]
pub struct SegmentInfo {
    /// Segment URI (relative or absolute).
    pub uri: String,
    /// Duration of the segment in seconds.
    pub duration_seconds: f32,
    /// Optional human-readable segment title.
    pub title: Option<String>,
    /// Byte range `(length, offset)` if `#EXT-X-BYTERANGE` applies.
    pub byte_range: Option<(u64, u64)>,
    /// Calculated media sequence index of this segment.
    pub sequence_number: u64,
    /// Active encryption key parameters for this segment.
    pub key: Option<EncryptionKeyInfo>,
}

impl SegmentInfo {
    fn from_media_segment(
        seg: MediaSegment,
        sequence_number: u64,
        active_key: Option<EncryptionKeyInfo>,
        resolved_byte_range: Option<(u64, u64)>,
    ) -> Self {
        Self {
            uri: seg.uri,
            duration_seconds: seg.duration,
            title: seg.title,
            byte_range: resolved_byte_range,
            sequence_number,
            key: active_key,
        }
    }
}

/// Slices a byte sub-range `(length, offset)` safely when bounds allow.
pub fn slice_byte_range(bytes: &[u8], length: u64, offset: u64) -> Option<Vec<u8>> {
    if length == 0 {
        return None;
    }
    let start = usize::try_from(offset).ok()?;
    if start >= bytes.len() {
        return None;
    }
    let len = usize::try_from(length).unwrap_or(usize::MAX);
    let end = start.saturating_add(len).min(bytes.len());
    if end <= start {
        return None;
    }
    Some(bytes[start..end].to_vec())
}

/// Resolves an HLS playlist or segment URI against a base playlist URI or local path.
pub fn resolve_hls_uri(base_url: &str, seg_uri: &str) -> String {
    let trimmed = seg_uri.trim();
    if trimmed.starts_with("http://")
        || trimmed.starts_with("https://")
        || trimmed.starts_with("file://")
        || trimmed.starts_with("asset://")
        || trimmed.starts_with("data:")
        || trimmed.starts_with("blob:")
    {
        return trimmed.to_string();
    }
    let base_no_query = base_url.split(['?', '#']).next().unwrap_or(base_url);
    if trimmed.starts_with("//") {
        if let Some(scheme_idx) = base_no_query.find("://") {
            return format!("{}:{}", &base_no_query[..scheme_idx], trimmed);
        }
        return format!("https:{}", trimmed);
    }
    let root_rel = trimmed
        .strip_prefix("://")
        .filter(|s| s.starts_with('/'))
        .or_else(|| trimmed.starts_with('/').then_some(trimmed));
    if let Some(root_path) = root_rel {
        if let Some(scheme_idx) = base_no_query.find("://") {
            let after_scheme = &base_no_query[scheme_idx + 3..];
            if let Some(slash_idx) = after_scheme.find('/') {
                let origin = &base_no_query[..scheme_idx + 3 + slash_idx];
                return format!("{}{}", origin, root_path);
            }
            return format!("{}{}", base_no_query, root_path);
        }
        return root_path.to_string();
    }
    if let Some(last_slash) = base_no_query.rfind('/') {
        format!("{}/{}", &base_no_query[..last_slash], trimmed)
    } else {
        trimmed.to_string()
    }
}

/// Parsed representation of an HLS playlist (Master or Media).
#[derive(Debug, Clone, PartialEq)]
pub enum ParsedHlsPlaylist {
    /// Master playlist containing multiple quality variants.
    Master {
        /// List of available variant media stream definitions.
        variants: Vec<VariantStreamInfo>,
    },
    /// Media playlist containing a sequence of downloadable audio/video segments.
    Media {
        /// Whether the playlist represents a live stream without `#EXT-X-ENDLIST`.
        is_live: bool,
        /// Maximum duration for any segment in the playlist.
        target_duration: f32,
        /// Starting sequence number from `#EXT-X-MEDIA-SEQUENCE`.
        media_sequence: u64,
        /// List of media segments in order.
        segments: Vec<SegmentInfo>,
        /// Sum of durations across all parsed segments in seconds.
        total_duration_seconds: f64,
    },
}

const EXTINF_SENTINEL_PREFIX: &str = "__MINIAUDIO_EXTINF_";
const EXTINF_SENTINEL_SUFFIX: &str = "__";

fn split_extinf_comma_payload(line_no_eol: &str) -> Option<(&str, &str, &str)> {
    let ws_len = line_no_eol.len() - line_no_eol.trim_start().len();
    let (indent, trimmed) = line_no_eol.split_at(ws_len);
    let after_tag = trimmed.strip_prefix("#EXTINF:")?;
    let comma_idx = after_tag.find(',')?;
    let duration_part = &after_tag[..comma_idx];
    let payload = &after_tag[comma_idx + 1..];
    payload.contains(',').then_some((indent, duration_part, payload))
}

fn preprocess_m3u8_extinf_commas(content: &[u8]) -> Option<(Vec<u8>, Vec<String>)> {
    let text = std::str::from_utf8(content).ok()?;
    if !text.lines().any(|l| split_extinf_comma_payload(l).is_some()) {
        return None;
    }

    let mut out = String::with_capacity(text.len());
    let mut restored_titles = Vec::new();
    for line in text.split_inclusive('\n') {
        let (line_no_eol, eol) = if let Some(s) = line.strip_suffix("\r\n") {
            (s, "\r\n")
        } else if let Some(s) = line.strip_suffix('\n') {
            (s, "\n")
        } else {
            (line, "")
        };
        if let Some((indent, duration_part, payload)) = split_extinf_comma_payload(line_no_eol) {
            let idx = restored_titles.len();
            restored_titles.push(payload.to_string());
            out.push_str(indent);
            out.push_str("#EXTINF:");
            out.push_str(duration_part);
            out.push(',');
            out.push_str(EXTINF_SENTINEL_PREFIX);
            out.push_str(&idx.to_string());
            out.push_str(EXTINF_SENTINEL_SUFFIX);
            out.push_str(eol);
        } else {
            out.push_str(line);
        }
    }
    Some((out.into_bytes(), restored_titles))
}

fn restore_extinf_title(title: Option<String>, restored_titles: &[String]) -> Option<String> {
    let s = title?;
    if let Some(idx_str) = s
        .strip_prefix(EXTINF_SENTINEL_PREFIX)
        .and_then(|rest| rest.strip_suffix(EXTINF_SENTINEL_SUFFIX))
    {
        if let Ok(idx) = idx_str.parse::<usize>() {
            if let Some(orig) = restored_titles.get(idx) {
                return Some(orig.clone());
            }
        }
    }
    Some(s)
}

/// High-level parser for HLS M3U8 master and media manifests.
pub struct M3u8Parser;

impl M3u8Parser {
    /// Determines if raw content begins with an M3U8 playlist header.
    pub fn is_m3u8(data: &[u8]) -> bool {
        let trimmed = data.trim_ascii_start();
        trimmed.starts_with(b"#EXTM3U") || trimmed.starts_with(b"#EXT-X-")
    }

    /// Parses an M3U8 playlist from raw UTF-8 bytes into a `ParsedHlsPlaylist`.
    pub fn parse(content: &[u8]) -> Result<ParsedHlsPlaylist, String> {
        let preprocessed = preprocess_m3u8_extinf_commas(content);
        let (parse_bytes, restored_titles): (&[u8], &[String]) = match preprocessed {
            Some((ref buf, ref titles)) => (buf.as_slice(), titles.as_slice()),
            None => (content, &[]),
        };
        let playlist = m3u8_rs::parse_playlist_res(parse_bytes)
            .map_err(|e| format!("Failed to parse M3U8: {:?}", e))?;

        match playlist {
            Playlist::MasterPlaylist(master) => Ok(Self::process_master(master)),
            Playlist::MediaPlaylist(media) => Ok(Self::process_media(media, restored_titles)),
        }
    }

    fn process_master(master: MasterPlaylist) -> ParsedHlsPlaylist {
        let variants = master
            .variants
            .into_iter()
            .map(|v| VariantStreamInfo {
                uri: v.uri,
                bandwidth: v.bandwidth,
                codecs: v.codecs,
                resolution: v.resolution.map(|r| (r.width, r.height)),
                audio: v.audio,
            })
            .collect();

        ParsedHlsPlaylist::Master { variants }
    }

    fn process_media(media: MediaPlaylist, restored_titles: &[String]) -> ParsedHlsPlaylist {
        let is_live = !media.end_list;
        let target_duration = media.target_duration as f32;
        let base_seq = media.media_sequence;
        let mut total_duration_seconds = 0.0f64;
        let mut current_key: Option<EncryptionKeyInfo> = None;
        // RFC 8216 Section 4.3.2.2: omitted byte-range offset continues from previous sub-range end.
        let mut last_byte_range: Option<(String, u64)> = None;
        let mut segments = Vec::with_capacity(media.segments.len());

        for (idx, mut seg) in media.segments.into_iter().enumerate() {
            let seq = base_seq.saturating_add(idx as u64);
            seg.title = restore_extinf_title(seg.title, restored_titles);
            if let Some(ref key) = seg.key {
                current_key = EncryptionKeyInfo::from_m3u8_key(key);
            }
            let resolved_byte_range = if let Some(ref br) = seg.byte_range {
                let offset = match br.offset {
                    Some(o) => o,
                    None => match last_byte_range {
                        Some((ref prev_uri, prev_end)) if prev_uri == &seg.uri => prev_end,
                        _ => 0,
                    },
                };
                last_byte_range = Some((seg.uri.clone(), offset.saturating_add(br.length)));
                Some((br.length, offset))
            } else {
                last_byte_range = None;
                None
            };
            total_duration_seconds += seg.duration as f64;
            segments.push(SegmentInfo::from_media_segment(
                seg,
                seq,
                current_key.clone(),
                resolved_byte_range,
            ));
        }

        ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence: media.media_sequence,
            segments,
            total_duration_seconds,
        }
    }
}

/// Concrete segment fetch target extracted from a parsed HLS media playlist.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HlsSegmentTarget {
    /// Resolved segment URI or filesystem path.
    pub url: String,
    /// Optional `#EXT-X-BYTERANGE` `(length, offset)` slice.
    pub byte_range: Option<(u64, u64)>,
    /// Assigned HLS media sequence index.
    pub sequence_number: u64,
    /// Nominal `#EXTINF` segment duration in milliseconds.
    pub duration_ms: u64,
    /// Optional raw `#EXTINF` title/attribute string.
    pub title: Option<String>,
}

type SegmentKey = (String, Option<(u64, u64)>);

/// Incremental state machine tracking live HLS media playlist reloads without duplicates.
pub struct HlsPlaylistTracker {
    base_media_url: String,
    is_live: bool,
    target_duration_seconds: f32,
    last_media_sequence: u64,
    last_sequence_number: Option<u64>,
    last_first_key: Option<SegmentKey>,
    recent_keys: VecDeque<SegmentKey>,
}

impl HlsPlaylistTracker {
    const MAX_RECENT_KEYS: usize = 64;

    /// Initializes the tracker from an already-parsed media playlist snapshot.
    pub fn new(
        base_media_url: String,
        is_live: bool,
        target_duration_seconds: f32,
        media_sequence: u64,
        initial_segments: &[SegmentInfo],
    ) -> Self {
        let mut tracker = Self {
            base_media_url,
            is_live,
            target_duration_seconds,
            last_media_sequence: media_sequence,
            last_sequence_number: initial_segments.last().map(|s| s.sequence_number),
            last_first_key: None,
            recent_keys: VecDeque::with_capacity(Self::MAX_RECENT_KEYS),
        };
        if let Some(first) = initial_segments.first() {
            tracker.last_first_key = Some((
                resolve_hls_uri(&tracker.base_media_url, &first.uri),
                first.byte_range,
            ));
        }
        for seg in initial_segments {
            tracker.push_recent_key((
                resolve_hls_uri(&tracker.base_media_url, &seg.uri),
                seg.byte_range,
            ));
        }
        tracker
    }

    /// Returns the media playlist URL that subsequent live polls should fetch.
    #[inline]
    pub fn base_media_url(&self) -> &str {
        &self.base_media_url
    }

    /// Returns whether the stream still omits `#EXT-X-ENDLIST`.
    #[inline]
    pub fn is_live(&self) -> bool {
        self.is_live
    }

    /// Computes the interruptible poll delay before re-fetching a live media playlist.
    pub fn poll_interval(&self, had_new_segments: bool) -> Duration {
        let td = if self.target_duration_seconds > 0.0 {
            self.target_duration_seconds
        } else {
            2.0
        };
        let factor = if had_new_segments { 0.6 } else { 0.5 };
        let secs = (td * factor).clamp(0.25, 5.0);
        Duration::from_secs_f32(secs)
    }

    /// Builds `HlsSegmentTarget` items for a slice of segments using the playlist base URL.
    pub fn resolve_targets(&self, segments: &[SegmentInfo]) -> Vec<HlsSegmentTarget> {
        segments
            .iter()
            .map(|s| HlsSegmentTarget {
                url: resolve_hls_uri(&self.base_media_url, &s.uri),
                byte_range: s.byte_range,
                sequence_number: s.sequence_number,
                duration_ms: (s.duration_seconds.max(0.0) * 1000.0).round() as u64,
                title: s.title.clone(),
            })
            .collect()
    }

    /// Ingests a freshly fetched media playlist snapshot and returns only unseen segments in order.
    pub fn ingest_media_playlist(
        &mut self,
        media_sequence: u64,
        is_live: bool,
        target_duration: f32,
        segments: &[SegmentInfo],
    ) -> Vec<HlsSegmentTarget> {
        self.is_live = is_live;
        if target_duration > 0.0 {
            self.target_duration_seconds = target_duration;
        }
        if segments.is_empty() {
            return Vec::new();
        }

        let targets = self.resolve_targets(segments);
        let first_key = (targets[0].url.clone(), targets[0].byte_range);
        let last_seq_in_playlist = targets.last().map(|t| t.sequence_number);

        let unseen: Vec<HlsSegmentTarget> = match self.last_sequence_number {
            None => targets,
            Some(prev_seq) => {
                let seq_authoritative = media_sequence > self.last_media_sequence
                    || (media_sequence == self.last_media_sequence
                        && self.last_first_key.as_ref() == Some(&first_key));
                if seq_authoritative {
                    targets
                        .into_iter()
                        .filter(|t| t.sequence_number > prev_seq)
                        .collect()
                } else {
                    // Handles either a playlist discontinuity reset or servers that slide the window
                    // without incrementing `#EXT-X-MEDIA-SEQUENCE`.
                    let overlap_idx = targets
                        .iter()
                        .rposition(|t| {
                            self.recent_keys
                                .iter()
                                .any(|k| k.0 == t.url && k.1 == t.byte_range)
                        });
                    match overlap_idx {
                        Some(idx) => targets.into_iter().skip(idx + 1).collect(),
                        None => targets,
                    }
                }
            }
        };

        self.last_media_sequence = media_sequence;
        self.last_first_key = Some(first_key);
        if let Some(seq) = last_seq_in_playlist {
            self.last_sequence_number = Some(seq);
        }
        for target in &unseen {
            self.push_recent_key((target.url.clone(), target.byte_range));
        }

        unseen
    }

    fn push_recent_key(&mut self, key: SegmentKey) {
        if self.recent_keys.len() >= Self::MAX_RECENT_KEYS {
            self.recent_keys.pop_front();
        }
        self.recent_keys.push_back(key);
    }
}

/// Structured track metadata extracted from an HLS `#EXTINF` attribute payload or plain title.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HlsExtinfMetadata {
    /// Track or program title, if present and non-ad-marker.
    pub title: Option<String>,
    /// Track artist, if present and non-ad-marker.
    pub artist: Option<String>,
}

/// Returns `true` when `value` is empty or a transient live-stream ad-insertion marker token.
#[inline]
pub fn is_live_ad_marker(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.is_empty()
        || trimmed
            .get(..9)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("ADWSRTAG_"))
}

fn clean_live_meta_value(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if is_live_ad_marker(trimmed) {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn parse_extinf_kv_pairs(input: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let bytes = input.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b',' | b'\r' | b'\n') {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }

        let key_start = i;
        while i < bytes.len() && bytes[i] != b'=' && bytes[i] != b',' {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'=' {
            // Not a well-formed key=value attribute sequence; bail to plain-text fallback.
            return Vec::new();
        }
        let key = input[key_start..i].trim();
        if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Vec::new();
        }
        i += 1; // skip '='
        while i < bytes.len() && matches!(bytes[i], b' ' | b'\t') {
            i += 1;
        }
        if i >= bytes.len() {
            pairs.push((key.to_ascii_lowercase(), String::new()));
            break;
        }

        let val = if bytes[i] == b'"' || bytes[i] == b'\'' {
            let quote = bytes[i] as char;
            i += 1;
            let mut buf = String::new();
            let mut closed = false;
            let mut iter = input[i..].char_indices();
            while let Some((off, ch)) = iter.next() {
                if ch == '\\' {
                    if let Some((_, next_ch)) = iter.next() {
                        buf.push(next_ch);
                    }
                } else if ch == quote {
                    i += off + ch.len_utf8();
                    closed = true;
                    break;
                } else {
                    buf.push(ch);
                }
            }
            if !closed {
                return Vec::new();
            }
            buf
        } else {
            let val_start = i;
            while i < bytes.len() && bytes[i] != b',' {
                i += 1;
            }
            input[val_start..i].trim().to_string()
        };
        pairs.push((key.to_ascii_lowercase(), val));
    }

    pairs
}

/// Parses an HLS `#EXTINF` title string (attribute list or plain `"Artist - Title"`) into track metadata.
pub fn parse_hls_extinf_metadata(raw_title: &str) -> Option<HlsExtinfMetadata> {
    let trimmed = raw_title.trim();
    if trimmed.is_empty() {
        return None;
    }

    let kv = parse_extinf_kv_pairs(trimmed);
    let has_meta_key = kv.iter().any(|(k, _)| k == "title" || k == "artist");
    if has_meta_key {
        let mut title = None;
        let mut artist = None;
        for (k, v) in kv {
            if k == "title" && title.is_none() {
                title = clean_live_meta_value(&v);
            } else if k == "artist" && artist.is_none() {
                artist = clean_live_meta_value(&v);
            }
        }
        return (title.is_some() || artist.is_some()).then_some(HlsExtinfMetadata { title, artist });
    }

    if is_live_ad_marker(trimmed) {
        return None;
    }
    if let Some((artist_part, title_part)) = trimmed.split_once(" - ") {
        let a = artist_part.trim();
        let t = title_part.trim();
        if !a.is_empty() && !t.is_empty() {
            return Some(HlsExtinfMetadata {
                title: Some(t.to_string()),
                artist: Some(a.to_string()),
            });
        }
    }

    Some(HlsExtinfMetadata {
        title: Some(trimmed.to_string()),
        artist: None,
    })
}

fn parse_mdstrm_icecast_id(raw_url: &str) -> Option<(Option<&str>, &str)> {
    let clean = raw_url
        .split(['?', '#'])
        .next()
        .unwrap_or(raw_url)
        .trim()
        .trim_end_matches('/');
    let rest = clean
        .strip_prefix("https://")
        .or_else(|| clean.strip_prefix("http://"))
        .or_else(|| clean.strip_prefix("icy://"))?;
    let (host, path) = rest.split_once('/')?;
    if host.is_empty() {
        return None;
    }

    let host_no_port = host.split(':').next().unwrap_or(host);
    let is_valid_id = |id: &str| -> bool {
        !id.is_empty()
            && !id.contains('/')
            && !id.contains('.')
            && id.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    };

    if host_no_port.eq_ignore_ascii_case("cdn.mdstrm.com")
        || host_no_port
            .to_ascii_lowercase()
            .ends_with(".cdn.mdstrm.com")
    {
        if let Some(id) = path.strip_prefix("live-audio-aw/") {
            if is_valid_id(id) {
                return Some((Some(host), id));
            }
        }
    } else if host_no_port.eq_ignore_ascii_case("mdstrm.com")
        || host_no_port.eq_ignore_ascii_case("www.mdstrm.com")
    {
        if let Some(id) = path
            .strip_prefix("audio/")
            .and_then(|s| s.strip_suffix("/icecast.audio"))
        {
            if is_valid_id(id) {
                return Some((None, id));
            }
        }
    }

    None
}

/// Derives CORS-accessible companion HLS playlist URLs for direct Mediastream Icecast endpoints.
pub fn derive_companion_hls_metadata_urls(original_url: &str, final_url: Option<&str>) -> Vec<String> {
    let mut stream_id: Option<&str> = None;
    let mut edge_host: Option<&str> = None;

    for candidate in final_url.into_iter().chain(std::iter::once(original_url)) {
        if let Some((host, id)) = parse_mdstrm_icecast_id(candidate) {
            if stream_id.is_none() {
                stream_id = Some(id);
            }
            if edge_host.is_none() {
                edge_host = host;
            }
        }
    }

    let Some(id) = stream_id else {
        return Vec::new();
    };

    let mut urls = Vec::with_capacity(2);
    urls.push(format!("https://mdstrm.com/live-stream-playlist/{}.m3u8", id));
    if let Some(host) = edge_host {
        let candidate = format!("https://{}/live-audio-aw/{}/playlist.m3u8", host, id);
        if !urls.contains(&candidate) {
            urls.push(candidate);
        }
    }
    urls
}
