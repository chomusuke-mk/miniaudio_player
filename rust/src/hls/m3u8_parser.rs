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
    let base_no_query = base_url.split('?').next().unwrap_or(base_url);
    if trimmed.starts_with("//") {
        if let Some(scheme_idx) = base_no_query.find("://") {
            return format!("{}:{}", &base_no_query[..scheme_idx], trimmed);
        }
        return format!("https:{}", trimmed);
    }
    if trimmed.starts_with('/') {
        if let Some(scheme_idx) = base_no_query.find("://") {
            let after_scheme = &base_no_query[scheme_idx + 3..];
            if let Some(slash_idx) = after_scheme.find('/') {
                let origin = &base_no_query[..scheme_idx + 3 + slash_idx];
                return format!("{}{}", origin, trimmed);
            }
            return format!("{}{}", base_no_query, trimmed);
        }
        return trimmed.to_string();
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
        let playlist = m3u8_rs::parse_playlist_res(content)
            .map_err(|e| format!("Failed to parse M3U8: {:?}", e))?;

        match playlist {
            Playlist::MasterPlaylist(master) => Ok(Self::process_master(master)),
            Playlist::MediaPlaylist(media) => Ok(Self::process_media(media)),
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

    fn process_media(media: MediaPlaylist) -> ParsedHlsPlaylist {
        let is_live = !media.end_list;
        let target_duration = media.target_duration as f32;
        let base_seq = media.media_sequence;
        let mut total_duration_seconds = 0.0f64;
        let mut current_key: Option<EncryptionKeyInfo> = None;
        // RFC 8216 Section 4.3.2.2: omitted byte-range offset continues from previous sub-range end.
        let mut last_byte_range: Option<(String, u64)> = None;
        let mut segments = Vec::with_capacity(media.segments.len());

        for (idx, seg) in media.segments.into_iter().enumerate() {
            let seq = base_seq.saturating_add(idx as u64);
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
