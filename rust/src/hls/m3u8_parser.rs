use m3u8_rs::{KeyMethod, MasterPlaylist, MediaPlaylist, Playlist};

#[derive(Debug, Clone, PartialEq)]
pub struct VariantStreamInfo {
    pub uri: String,
    pub bandwidth: u64,
    pub codecs: Option<String>,
    pub resolution: Option<(u64, u64)>,
    pub audio: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EncryptionKeyInfo {
    pub method: String,
    pub uri: Option<String>,
    pub iv: Option<String>,
    pub keyformat: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SegmentInfo {
    pub uri: String,
    pub duration_seconds: f32,
    pub title: Option<String>,
    pub byte_range: Option<(u64, u64)>, // (length, offset)
    pub sequence_number: u64,
    pub key: Option<EncryptionKeyInfo>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ParsedHlsPlaylist {
    Master {
        variants: Vec<VariantStreamInfo>,
    },
    Media {
        is_live: bool,
        target_duration: f32,
        media_sequence: u64,
        segments: Vec<SegmentInfo>,
        total_duration_seconds: f64,
    },
}

pub struct M3u8Parser;

impl M3u8Parser {
    /// Determines if raw content is an M3U8 playlist.
    pub fn is_m3u8(data: &[u8]) -> bool {
        let trimmed = data.trim_ascii_start();
        trimmed.starts_with(b"#EXTM3U") || trimmed.starts_with(b"#EXT-X-")
    }

    /// Parses an M3U8 playlist from bytes.
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
            .map(|v| {
                let res = v.resolution.map(|r| (r.width, r.height));
                VariantStreamInfo {
                    uri: v.uri,
                    bandwidth: v.bandwidth,
                    codecs: v.codecs,
                    resolution: res,
                    audio: v.audio,
                }
            })
            .collect();

        ParsedHlsPlaylist::Master { variants }
    }

    fn process_media(media: MediaPlaylist) -> ParsedHlsPlaylist {
        let is_live = !media.end_list;
        let target_duration = media.target_duration as f32;
        let mut seq = media.media_sequence;
        let mut total_duration = 0.0f64;
        let mut current_key: Option<EncryptionKeyInfo> = None;

        let mut segments = Vec::with_capacity(media.segments.len());

        for seg in media.segments {
            if let Some(ref key) = seg.key {
                let method_str = match key.method {
                    KeyMethod::None => "NONE".to_string(),
                    KeyMethod::AES128 => "AES-128".to_string(),
                    KeyMethod::SampleAES => "SAMPLE-AES".to_string(),
                    KeyMethod::Other(ref s) => s.clone(),
                };

                if key.method == KeyMethod::None {
                    current_key = None;
                } else {
                    current_key = Some(EncryptionKeyInfo {
                        method: method_str,
                        uri: key.uri.clone(),
                        iv: key.iv.clone(),
                        keyformat: key.keyformat.clone(),
                    });
                }
            }

            let byte_range = seg.byte_range.map(|br| {
                let offset = br.offset.unwrap_or(0);
                (br.length, offset)
            });

            let dur = seg.duration as f32;
            total_duration += dur as f64;

            segments.push(SegmentInfo {
                uri: seg.uri,
                duration_seconds: dur,
                title: seg.title,
                byte_range,
                sequence_number: seq,
                key: current_key.clone(),
            });

            seq += 1;
        }

        ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence: media.media_sequence,
            segments,
            total_duration_seconds: total_duration,
        }
    }
}
