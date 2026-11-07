//! Deterministic M3U8 Master & Media Playlist Parser.

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
    ) -> Self {
        let byte_range = seg
            .byte_range
            .map(|br| (br.length, br.offset.unwrap_or(0)));
        Self {
            uri: seg.uri,
            duration_seconds: seg.duration,
            title: seg.title,
            byte_range,
            sequence_number,
            key: active_key,
        }
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
        let mut seq = media.media_sequence;
        let mut total_duration_seconds = 0.0f64;
        let mut current_key: Option<EncryptionKeyInfo> = None;
        let mut segments = Vec::with_capacity(media.segments.len());

        for seg in media.segments {
            if let Some(ref key) = seg.key {
                current_key = EncryptionKeyInfo::from_m3u8_key(key);
            }
            total_duration_seconds += seg.duration as f64;
            segments.push(SegmentInfo::from_media_segment(
                seg,
                seq,
                current_key.clone(),
            ));
            seq += 1;
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
