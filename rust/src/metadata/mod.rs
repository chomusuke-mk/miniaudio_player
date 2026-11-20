//! Comprehensive multi-codec audio metadata parser and normalizer.
//!
//! Combines `lofty` tag parsing (ID3v1, ID3v2, Vorbis Comments, MP4/iTunes `ilst`, APEv2,
//! RIFF INFO, AIFF Text), binary ID3v2 `CHAP` chapter extraction, DSF/RF64/RIFX/W64/BWF
//! chunk extractors, Symphonia `MetadataRevision`/`Visual`/`Cue` bridging (Matroska/WebM/MKA, CAF),
//! and live Shoutcast/Icecast ICY stream metadata into a unified [`RustAudioMetadata`] model.

use std::collections::{HashMap, HashSet};
use std::io::{Cursor, Read, Seek, SeekFrom};

use lofty::config::{ParseOptions, ParsingMode};
use lofty::file::{FileType, TaggedFileExt};
use lofty::picture::{MimeType as LoftyMimeType, PictureType as LoftyPictureType};
use lofty::probe::Probe;
use lofty::tag::{ItemKey,ItemValue, Tag, TagType};

use crate::api::types::{
    RustAudioChapter, RustAudioMetadata, RustAudioPicture, RustCustomTagField,
    RustExtendedMetadata, RustIcyMetadata, RustId3v2Version, RustMimeType, RustPictureType,
};

/// Lightweight snapshot of metadata, visuals, and chapter cues captured by Symphonia during probing.
#[derive(Debug, Clone, Default)]
pub struct SymphoniaExtractedMeta {
    /// Standard and raw tags captured from Symphonia `MetadataRevision`s.
    pub tags: Vec<symphonia::core::meta::Tag>,
    /// Visuals (embedded artwork) captured from Symphonia `MetadataRevision`s.
    pub visuals: Vec<RustAudioPicture>,
    /// Chapters captured from Symphonia `FormatReader::chapters()`.
    pub chapters: Vec<RustAudioChapter>,
}

impl SymphoniaExtractedMeta {
    /// Returns `true` if any tags, visuals, or chapters were captured.
    pub fn is_empty(&self) -> bool {
        self.tags.is_empty() && self.visuals.is_empty() && self.chapters.is_empty()
    }

    /// Captures all metadata revisions and chapters from a Symphonia `FormatReader`.
    pub fn from_format_reader(format: &mut dyn symphonia::core::formats::FormatReader) -> Self {
        let mut out = Self::default();

        {
            let mut fmt_meta = format.metadata();
            while let Some(rev) = fmt_meta.pop() {
                Self::ingest_revision(&mut out, &rev);
            }
            if let Some(rev) = fmt_meta.current() {
                Self::ingest_revision(&mut out, rev);
            }
        }

        if let Some(group) = format.chapters() {
            Self::ingest_chapter_group(&mut out.chapters, group);
            // Fix up end_ms for chapters that didn't specify end_time
            let len = out.chapters.len();
            for i in 0..len {
                if out.chapters[i].end_ms <= out.chapters[i].start_ms {
                    if let Some(next_start) = out.chapters.get(i + 1).map(|c| c.start_ms) {
                        out.chapters[i].end_ms = next_start;
                    }
                }
            }
        }

        // Ingest image file attachments (e.g. Matroska / WebM `Attachments` EBML element)
        for attachment in format.attachments() {
            if let symphonia::core::formats::Attachment::File(att) = attachment {
                if att.data.is_empty() {
                    continue;
                }
                let media_lower = att
                    .media_type
                    .as_deref()
                    .map(|s| s.trim().to_ascii_lowercase())
                    .unwrap_or_default();
                let mime_type = att
                    .media_type
                    .as_deref()
                    .and_then(parse_mime_str)
                    .or_else(|| sniff_image_mime(&att.data));
                if mime_type.is_none() && !media_lower.starts_with("image/") {
                    continue;
                }
                let label = format!(
                    "{} {}",
                    att.name,
                    att.description.as_deref().unwrap_or("")
                )
                .to_ascii_lowercase();
                let picture_type = if label.contains("back") {
                    RustPictureType::CoverBack
                } else if label.contains("icon") {
                    RustPictureType::Icon
                } else if label.contains("leaflet") {
                    RustPictureType::Leaflet
                } else if label.contains("artist") {
                    RustPictureType::Artist
                } else {
                    RustPictureType::CoverFront
                };
                let description = att
                    .description
                    .as_deref()
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string())
                    .or_else(|| {
                        let n = att.name.trim();
                        if n.is_empty() {
                            None
                        } else {
                            Some(n.to_string())
                        }
                    });
                let bytes = att.data.to_vec();
                let already_present = out.visuals.iter().any(|v| {
                    v.bytes.len() == bytes.len() && v.bytes.get(..16) == bytes.get(..16)
                });
                if !already_present {
                    out.visuals.push(RustAudioPicture {
                        picture_type,
                        mime_type,
                        description,
                        bytes,
                    });
                }
            }
        }

        out
    }

    fn ingest_chapter_group(
        chapters: &mut Vec<RustAudioChapter>,
        group: &symphonia::core::meta::ChapterGroup,
    ) {
        use symphonia::core::meta::{ChapterGroupItem, StandardTag};
        for item in &group.items {
            match item {
                ChapterGroupItem::Chapter(ch) => {
                    let start_ms = ch.start_time.as_millis().max(0) as u64;
                    let end_ms = ch
                        .end_time
                        .map(|t| t.as_millis().max(0) as u64)
                        .unwrap_or(start_ms);
                    let idx = chapters.len() + 1;
                    let title = ch
                        .tags
                        .iter()
                        .find_map(|t| match &t.std {
                            Some(StandardTag::TrackTitle(s)) | Some(StandardTag::ChapterTitle(s)) => {
                                Some(s.as_str().to_string())
                            }
                            _ if t.raw.key.eq_ignore_ascii_case("TITLE") => {
                                Some(t.raw.value.to_string())
                            }
                            _ => None,
                        })
                        .unwrap_or_else(|| format!("Chapter {idx}"));
                    chapters.push(RustAudioChapter {
                        title,
                        start_ms,
                        end_ms,
                    });
                }
                ChapterGroupItem::Group(sub) => {
                    Self::ingest_chapter_group(chapters, sub);
                }
            }
        }
    }

    fn ingest_revision(out: &mut Self, rev: &symphonia::core::meta::MetadataRevision) {
        Self::ingest_container(out, &rev.media);
        for pt in &rev.per_track {
            Self::ingest_container(out, &pt.metadata);
        }
    }

    fn ingest_container(out: &mut Self, container: &symphonia::core::meta::MetadataContainer) {
        use symphonia::core::meta::StandardTag;
        for tag in &container.tags {
            out.tags.push(tag.clone());
        }
        for vis in &container.visuals {
            if vis.data.is_empty() {
                continue;
            }
            let picture_type = map_symphonia_visual_key(vis.usage);
            let mime_type = vis
                .media_type
                .as_deref()
                .and_then(parse_mime_str)
                .or_else(|| sniff_image_mime(&vis.data));
            let description = vis
                .tags
                .iter()
                .find_map(|t| match &t.std {
                    Some(StandardTag::Description(s)) => Some(s.as_str().to_string()),
                    _ if t.raw.key.eq_ignore_ascii_case("DESCRIPTION") => {
                        Some(t.raw.value.to_string())
                    }
                    _ => None,
                })
                .filter(|s| !s.is_empty());
            out.visuals.push(RustAudioPicture {
                picture_type,
                mime_type,
                description,
                bytes: vis.data.to_vec(),
            });
        }
    }
}

/// Universal metadata extractor operating exclusively on a [`crate::buffer::StreamBuffer`]
/// (`Sparse` virtual address space) across local files, memory buffers, and network streams.
pub struct UniversalMetadataExtractor;

impl UniversalMetadataExtractor {
    /// Extracts complete [`RustAudioMetadata`] from `metadata_buffer` (`StreamBuffer` in `Sparse` mode),
    /// merging Symphonia container metadata and live ICY stream metadata when present.
    pub fn extract(
        metadata_buffer: &std::sync::Arc<crate::buffer::StreamBuffer>,
        container_format: &str,
        symphonia_meta: Option<&SymphoniaExtractedMeta>,
        icy_meta: Option<RustIcyMetadata>,
    ) -> RustAudioMetadata {
        let meta_bytes = metadata_buffer.synthesize_meta_bytes();
        let mut out = RustAudioMetadata {
            bytes: meta_bytes,
            icy: icy_meta.clone(),
            ..Default::default()
        };

        let mut consumed_custom_keys: HashSet<String> = HashSet::new();
        let mut parsed_any_lofty = false;

        // 1. Parse directly over the sparse virtual `MetadataStreamReader`
        let mut reader = crate::buffer::MetadataStreamReader::new(metadata_buffer.clone());
        if reader.seek(SeekFrom::Start(0)).is_ok() {
            parsed_any_lofty =
                try_parse_with_lofty(&mut reader, &mut out, &mut consumed_custom_keys);
        }
        if reader.seek(SeekFrom::Start(0)).is_ok() {
            try_parse_special_containers_seekable(
                &mut reader,
                &mut out,
                &mut consumed_custom_keys,
            );
        }
        if out.id3v2_version.is_none() || out.chapters.is_empty() {
            if reader.seek(SeekFrom::Start(0)).is_ok() {
                extract_id3v2_header_and_chapters_from_reader(&mut reader, &mut out);
            }
        }

        // 2. Fallback / supplement on synthesized compact container `out.bytes`
        if !out.bytes.is_empty() {
            let needs_id3_fallback = out.id3v2_version.is_none()
                && (!parsed_any_lofty
                    || out
                        .tag_formats
                        .iter()
                        .any(|f| matches!(f.as_str(), "RiffInfo" | "AiffText" | "ID3v1")));
            let bytes_snapshot = if !parsed_any_lofty
                || needs_id3_fallback
                || out.chapters.is_empty()
                || out.pictures.is_empty()
            {
                Some(out.bytes.clone())
            } else {
                None
            };

            if let Some(ref raw) = bytes_snapshot {
                if !parsed_any_lofty {
                    let mut cursor = Cursor::new(raw.as_slice());
                    parsed_any_lofty =
                        try_parse_with_lofty(&mut cursor, &mut out, &mut consumed_custom_keys);
                    if !parsed_any_lofty {
                        parse_raw_id3v2_slice(raw, &mut out, &mut consumed_custom_keys);
                    }
                }
                let mut cursor = Cursor::new(raw.as_slice());
                try_parse_special_containers_seekable(
                    &mut cursor,
                    &mut out,
                    &mut consumed_custom_keys,
                );
                extract_id3v2_header_and_chapters_from_slice(raw, &mut out);
            }
        }

        // 3. Bridge Symphonia metadata (authoritative for Matroska/WebM/MKA, CAF, Ogg, and fallback visuals)
        if let Some(sym) = symphonia_meta {
            if !sym.is_empty() {
                merge_symphonia_metadata(&mut out, sym, container_format, &consumed_custom_keys);
            }
        }

        // 4. Merge ICY Live Stream Metadata (Shoutcast / Icecast)
        if let Some(ref icy) = out.icy {
            if !out.tag_formats.iter().any(|f| f == "ICY") {
                out.tag_formats.push("ICY".to_string());
            }
            if let Some(ref st) = icy.stream_title {
                let trimmed = st.trim();
                if !crate::hls::is_live_ad_marker(trimmed) {
                    if let Some((artist_part, title_part)) = trimmed.split_once(" - ") {
                        let a = artist_part.trim();
                        let t = title_part.trim();
                        if !a.is_empty() {
                            out.track_artist = Some(a.to_string());
                        }
                        if !t.is_empty() {
                            out.title = Some(t.to_string());
                        }
                    } else {
                        out.title = Some(trimmed.to_string());
                    }
                }
            }
            if let Some(ref station) = icy.station_name {
                if out.album.is_none() && !station.trim().is_empty() {
                    out.album = Some(station.trim().to_string());
                }
            }
            if let Some(ref genre) = icy.station_genre {
                if out.genre.is_none() && !genre.trim().is_empty() {
                    out.genre = Some(genre.trim().to_string());
                }
            }
            if let Some(ref url) = icy.station_url {
                if out.extended.radio_station_url.is_none() && !url.trim().is_empty() {
                    out.extended.radio_station_url = Some(url.trim().to_string());
                }
            }
        }

        if out.chapters.len() > 1 {
            out.chapters.sort_by_key(|c| c.start_ms);
        }

        out
    }
}

fn try_parse_with_lofty<R: Read + Seek>(
    reader: &mut R,
    out: &mut RustAudioMetadata,
    consumed_custom_keys: &mut HashSet<String>,
) -> bool {
    let mut header = [0u8; 16];
    if reader.read_exact(&mut header).is_ok() {
        let _ = reader.seek(SeekFrom::Start(0));
        if (&header[0..4] == b"RF64" || &header[0..4] == b"RIFX") && &header[8..12] == b"WAVE" {
            return false;
        }
        const W64_RIFF_GUID: [u8; 16] = [
            0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00,
            0x00,
        ];
        if header == W64_RIFF_GUID {
            return false;
        }
    } else {
        let _ = reader.seek(SeekFrom::Start(0));
    }

    let options = ParseOptions::new()
        .read_properties(false)
        .parsing_mode(ParsingMode::Relaxed);

    let Ok(probe) = Probe::new(reader).options(options).guess_file_type() else {
        return false;
    };

    if probe.file_type().is_none() {
        return false;
    }

    let Ok(tagged_file) = probe.read() else {
        return false;
    };

    let tags = tagged_file.tags();
    if tags.is_empty() {
        return false;
    }

    for t in tags {
        let fmt_name = map_lofty_tag_type(t.tag_type());
        if !out.tag_formats.iter().any(|existing| existing == fmt_name) {
            out.tag_formats.push(fmt_name.to_string());
        }
    }

    // Populate from primary tag first, then fill missing fields from any other tags
    let primary_ptr = tagged_file.primary_tag().map(|p| p as *const Tag);
    if let Some(primary) = tagged_file.primary_tag() {
        ingest_lofty_tag(primary, out, consumed_custom_keys);
    }
    for tag in tags {
        if Some(tag as *const Tag) != primary_ptr {
            ingest_lofty_tag(tag, out, consumed_custom_keys);
        }
    }

    true
}

#[inline]
fn tag_str(tag: &Tag, key: ItemKey) -> Option<&str> {
    tag.get(key)
        .and_then(|item| item.value().text().or_else(|| item.value().locator()))
}

fn ingest_lofty_tag(
    tag: &Tag,
    out: &mut RustAudioMetadata,
    consumed_custom_keys: &mut HashSet<String>,
) {
    for known in [
        "REPLAYGAIN_TRACK_GAIN",
        "REPLAYGAIN_TRACK_PEAK",
        "REPLAYGAIN_ALBUM_GAIN",
        "REPLAYGAIN_ALBUM_PEAK",
        "BPM",
        "TRACKNUMBER",
        "TRACKTOTAL",
        "DISCNUMBER",
        "DISCTOTAL",
        "YEAR",
        "DATE",
        "IENG",
        "RTNG",
        "ENCODERSETTINGS",
    ] {
        consumed_custom_keys.insert(known.to_string());
    }

    if out.title.is_none() {
        out.title = tag_str(tag, ItemKey::TrackTitle).map(|s| s.to_string());
    }
    if out.track_artist.is_none() {
        out.track_artist = tag_str(tag, ItemKey::TrackArtist).map(|s| s.to_string());
    }
    if out.album.is_none() {
        out.album = tag_str(tag, ItemKey::AlbumTitle).map(|s| s.to_string());
    }
    if out.album_artist.is_none() {
        out.album_artist = tag_str(tag, ItemKey::AlbumArtist).map(|s| s.to_string());
    }
    if out.year.is_none() {
        out.year = tag_str(tag, ItemKey::Year)
            .and_then(|s| s.trim().parse::<u32>().ok())
            .or_else(|| {
                tag_str(tag, ItemKey::RecordingDate)
                    .and_then(|s| s.trim().get(0..4))
                    .and_then(|s| s.parse::<u32>().ok())
            });
    }
    if out.genre.is_none() {
        out.genre = tag_str(tag, ItemKey::Genre).map(|s| s.to_string());
    }
    if out.track_number.is_none() {
        out.track_number = tag_str(tag, ItemKey::TrackNumber)
            .and_then(parse_leading_u32)
            .or_else(|| {
                get_lofty_fallback(tag, &["TRACKNUMBER"], consumed_custom_keys)
                    .as_deref()
                    .and_then(parse_leading_u32)
            });
    }
    if out.track_total.is_none() {
        out.track_total = tag_str(tag, ItemKey::TrackTotal)
            .and_then(parse_leading_u32)
            .or_else(|| {
                tag_str(tag, ItemKey::TrackNumber).and_then(parse_slash_total_u32)
            })
            .or_else(|| {
                get_lofty_fallback(tag, &["TRACKTOTAL"], consumed_custom_keys)
                    .as_deref()
                    .and_then(parse_leading_u32)
            })
            .or_else(|| {
                get_lofty_fallback(tag, &["TRACKNUMBER"], consumed_custom_keys)
                    .as_deref()
                    .and_then(parse_slash_total_u32)
            });
    }
    if out.disc_number.is_none() {
        out.disc_number = tag_str(tag, ItemKey::DiscNumber)
            .and_then(parse_leading_u32)
            .or_else(|| {
                get_lofty_fallback(tag, &["DISCNUMBER"], consumed_custom_keys)
                    .as_deref()
                    .and_then(parse_leading_u32)
            });
    }
    if out.disc_total.is_none() {
        out.disc_total = tag_str(tag, ItemKey::DiscTotal)
            .and_then(parse_leading_u32)
            .or_else(|| {
                tag_str(tag, ItemKey::DiscNumber).and_then(parse_slash_total_u32)
            })
            .or_else(|| {
                get_lofty_fallback(tag, &["DISCTOTAL"], consumed_custom_keys)
                    .as_deref()
                    .and_then(parse_leading_u32)
            })
            .or_else(|| {
                get_lofty_fallback(tag, &["DISCNUMBER"], consumed_custom_keys)
                    .as_deref()
                    .and_then(parse_slash_total_u32)
            });
    }
    if out.lyrics.is_none() {
        out.lyrics = tag_str(tag, ItemKey::Lyrics)
            .or_else(|| tag_str(tag, ItemKey::UnsyncLyrics))
            .map(|s| s.to_string());
    }
    if out.comment.is_none() {
        out.comment = tag_str(tag, ItemKey::Comment).map(|s| s.to_string());
    }
    if out.bpm.is_none() {
        out.bpm = tag_str(tag, ItemKey::Bpm)
            .or_else(|| tag_str(tag, ItemKey::IntegerBpm))
            .and_then(|s| s.trim().parse::<f32>().ok())
            .or_else(|| {
                get_lofty_fallback(tag, &["BPM"], consumed_custom_keys)
                    .and_then(|s| s.trim().parse::<f32>().ok())
            });
    }
    if out.replay_gain_track_gain.is_none() {
        out.replay_gain_track_gain = tag_str(tag, ItemKey::ReplayGainTrackGain)
            .map(|s| s.to_string())
            .or_else(|| get_lofty_fallback(tag, &["REPLAYGAIN_TRACK_GAIN"], consumed_custom_keys));
    }
    if out.replay_gain_track_peak.is_none() {
        out.replay_gain_track_peak = tag_str(tag, ItemKey::ReplayGainTrackPeak)
            .map(|s| s.to_string())
            .or_else(|| get_lofty_fallback(tag, &["REPLAYGAIN_TRACK_PEAK"], consumed_custom_keys));
    }
    if out.replay_gain_album_gain.is_none() {
        out.replay_gain_album_gain = tag_str(tag, ItemKey::ReplayGainAlbumGain)
            .map(|s| s.to_string())
            .or_else(|| get_lofty_fallback(tag, &["REPLAYGAIN_ALBUM_GAIN"], consumed_custom_keys));
    }
    if out.replay_gain_album_peak.is_none() {
        out.replay_gain_album_peak = tag_str(tag, ItemKey::ReplayGainAlbumPeak)
            .map(|s| s.to_string())
            .or_else(|| get_lofty_fallback(tag, &["REPLAYGAIN_ALBUM_PEAK"], consumed_custom_keys));
    }

    // Pictures
    if out.pictures.is_empty() {
        for pic in tag.pictures() {
            let bytes = pic.data().to_vec();
            if bytes.is_empty() {
                continue;
            }
            let mime_type = pic
                .mime_type()
                .map(map_lofty_mime_type)
                .filter(|m| !matches!(m, RustMimeType::Unknown))
                .or_else(|| sniff_image_mime(&bytes));
            let picture_type = if tag.tag_type() == TagType::Mp4Ilst
                && pic.pic_type() == LoftyPictureType::Other
            {
                RustPictureType::CoverFront
            } else {
                map_lofty_picture_type(pic.pic_type())
            };
            out.pictures.push(RustAudioPicture {
                picture_type,
                mime_type,
                description: pic.description().map(|s| s.to_string()).filter(|s| !s.is_empty()),
                bytes,
            });
        }

        // APEv2 binary `Cover Art (*)` items are retained inside the companion `ApeTag` rather than `tag.pictures()`.
        if tag.tag_type() == TagType::Ape && tag.has_format_specific_items() {
            let ape = lofty::ape::ApeTag::from(tag.clone());
            for item in &ape {
                if let ItemValue::Binary(raw_bytes) = item.value() {
                    let key_lower = item.key().to_ascii_lowercase();
                    if key_lower.starts_with("cover art") {
                        if let Ok(pic) = lofty::picture::Picture::from_ape_bytes(item.key(), raw_bytes) {
                            let bytes = pic.data().to_vec();
                            if bytes.is_empty() {
                                continue;
                            }
                            let mapped_pt = map_lofty_picture_type(pic.pic_type());
                            let picture_type = if matches!(mapped_pt, RustPictureType::Other) {
                                if key_lower.contains("back") {
                                    RustPictureType::CoverBack
                                } else if key_lower.contains("icon") {
                                    RustPictureType::Icon
                                } else {
                                    RustPictureType::CoverFront
                                }
                            } else {
                                mapped_pt
                            };
                            let mime_type = pic
                                .mime_type()
                                .map(map_lofty_mime_type)
                                .filter(|m| !matches!(m, RustMimeType::Unknown))
                                .or_else(|| sniff_image_mime(&bytes));
                            let description = pic
                                .description()
                                .map(|s| s.trim().to_string())
                                .filter(|s| !s.is_empty());
                            if !out.pictures.iter().any(|p| {
                                p.bytes.len() == bytes.len() && p.bytes.get(..16) == bytes.get(..16)
                            }) {
                                out.pictures.push(RustAudioPicture {
                                    picture_type,
                                    mime_type,
                                    description,
                                    bytes,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    // Extended 63 fields (1:1 parity with haudiotagger::ExtendedTag)
    ingest_extended_from_lofty(tag, &mut out.extended, consumed_custom_keys);

    let unmapped_items = extract_raw_lofty_items(tag, out);

    // Vorbis chapters if present
    if out.chapters.is_empty() {
        let vorbis_chaps = extract_vorbis_chapters(&unmapped_items, consumed_custom_keys);
        if !vorbis_chaps.is_empty() {
            out.chapters = vorbis_chaps;
        }
    }

    // Remaining custom tags
    for (raw_key, val) in unmapped_items {
        let upper = raw_key.to_uppercase();
        if consumed_custom_keys.contains(&upper) {
            continue;
        }
        if upper.starts_with("CHAPTER") {
            continue;
        }
        if !out
            .custom_tags
            .iter()
            .any(|f| f.key.eq_ignore_ascii_case(&raw_key))
        {
            out.custom_tags.push(RustCustomTagField {
                key: raw_key,
                value: val,
            });
        }
    }
}

#[inline]
fn parse_leading_u32(s: &str) -> Option<u32> {
    let trimmed = s.trim();
    let num_part = trimmed.split('/').next().unwrap_or(trimmed).trim();
    num_part.parse::<u32>().ok()
}

#[inline]
fn parse_slash_total_u32(s: &str) -> Option<u32> {
    let (_, total_part) = s.trim().split_once('/')?;
    total_part.trim().parse::<u32>().ok()
}

fn get_lofty_field(
    tag: &Tag,
    key: ItemKey,
    fallbacks: &[&str],
    consumed: &mut HashSet<String>,
) -> Option<String> {
    for &fb in fallbacks {
        consumed.insert(fb.to_uppercase());
    }
    if let Some(val) = tag_str(tag, key) {
        if !val.is_empty() {
            return Some(val.to_string());
        }
    }
    get_lofty_fallback(tag, fallbacks, consumed)
}

fn get_lofty_fallback(
    tag: &Tag,
    fallbacks: &[&str],
    consumed: &mut HashSet<String>,
) -> Option<String> {
    for &fb in fallbacks {
        consumed.insert(fb.to_uppercase());
        if let Some(ik) = ItemKey::from_key(tag.tag_type(), fb)
            .or_else(|| ItemKey::from_key(tag.tag_type(), &fb.to_uppercase()))
        {
            if let Some(val) = tag_str(tag, ik) {
                if !val.is_empty() {
                    return Some(val.to_string());
                }
            }
        }
        if tag.has_format_specific_items() {
            if let Some(val) = lookup_unmapped_in_tag(tag, fb) {
                if !val.is_empty() {
                    return Some(val);
                }
            }
        }
    }
    None
}

fn lookup_unmapped_in_tag(tag: &Tag, key: &str) -> Option<String> {
    match tag.tag_type() {
        TagType::Id3v2 => {
            let id3v2 = lofty::id3::v2::Id3v2Tag::from(tag.clone());
            for frame in &id3v2 {
                match frame {
                    lofty::id3::v2::Frame::UserText(txxx) => {
                        if txxx.description.trim().eq_ignore_ascii_case(key)
                            && !txxx.content.trim().is_empty()
                        {
                            return Some(txxx.content.trim().to_string());
                        }
                    }
                    lofty::id3::v2::Frame::UserUrl(wxxx) => {
                        if wxxx.description.trim().eq_ignore_ascii_case(key)
                            && !wxxx.content.trim().is_empty()
                        {
                            return Some(wxxx.content.trim().to_string());
                        }
                    }
                    _ => {}
                }
            }
        }
        TagType::VorbisComments => {
            let vc = lofty::ogg::tag::VorbisComments::from(tag.clone());
            for (k, v) in vc.items() {
                if k.trim().eq_ignore_ascii_case(key) && !v.trim().is_empty() {
                    return Some(v.trim().to_string());
                }
            }
        }
        TagType::Ape => {
            let ape = lofty::ape::ApeTag::from(tag.clone());
            if let Some(item) = ape.get(key) {
                if let ItemValue::Text(v) | ItemValue::Locator(v) = item.value() {
                    if !v.trim().is_empty() {
                        return Some(v.trim().to_string());
                    }
                }
            }
        }
        TagType::Mp4Ilst => {
            let ilst = lofty::mp4::Ilst::from(tag.clone());
            for atom in &ilst {
                if let lofty::mp4::AtomIdent::Freeform { name, .. } = atom.ident() {
                    if name.trim().eq_ignore_ascii_case(key) {
                        for data in atom.data() {
                            if let lofty::mp4::AtomData::UTF8(s) | lofty::mp4::AtomData::UTF16(s) =
                                data
                            {
                                if !s.trim().is_empty() {
                                    return Some(s.trim().to_string());
                                }
                            }
                        }
                    }
                }
            }
        }
        TagType::RiffInfo => {
            let riff = lofty::iff::wav::RiffInfoList::from(tag.clone());
            for (k, v) in &riff {
                if k.trim().eq_ignore_ascii_case(key) && !v.trim().is_empty() {
                    return Some(v.trim().to_string());
                }
            }
        }
        _ => {}
    }
    None
}

fn extract_raw_lofty_items(tag: &Tag, out: &mut RustAudioMetadata) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    match tag.tag_type() {
        TagType::Id3v2 => {
            let id3v2 = lofty::id3::v2::Id3v2Tag::from(tag.clone());
            if out.id3v2_version.is_none() {
                out.id3v2_version = Some(match id3v2.original_version() {
                    lofty::id3::v2::Id3v2Version::V2 => RustId3v2Version::V2,
                    lofty::id3::v2::Id3v2Version::V3 => RustId3v2Version::V3,
                    lofty::id3::v2::Id3v2Version::V4 => RustId3v2Version::V4,
                });
            }
            for frame in &id3v2 {
                match frame {
                    lofty::id3::v2::Frame::UserText(txxx) => {
                        let desc = txxx.description.trim();
                        let val = txxx.content.trim();
                        if !desc.is_empty()
                            && !val.is_empty()
                            && ItemKey::from_key(TagType::Id3v2, desc).is_none()
                            && ItemKey::from_key(TagType::Id3v2, &desc.to_uppercase()).is_none()
                        {
                            pairs.push((desc.to_string(), val.to_string()));
                        }
                    }
                    lofty::id3::v2::Frame::UserUrl(wxxx) => {
                        let desc = wxxx.description.trim();
                        let val = wxxx.content.trim();
                        if !desc.is_empty()
                            && !val.is_empty()
                            && ItemKey::from_key(TagType::Id3v2, desc).is_none()
                            && ItemKey::from_key(TagType::Id3v2, &desc.to_uppercase()).is_none()
                        {
                            pairs.push((desc.to_string(), val.to_string()));
                        }
                    }
                    lofty::id3::v2::Frame::Chapter(chap) => {
                        let title = chap
                            .title()
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                            .unwrap_or_else(|| chap.id.to_string());
                        let start_ms = chap.times.start as u64;
                        let end_ms = chap.times.end as u64;
                        if !out
                            .chapters
                            .iter()
                            .any(|c| c.start_ms == start_ms && c.title == title)
                        {
                            out.chapters.push(RustAudioChapter {
                                title,
                                start_ms,
                                end_ms,
                            });
                        }
                    }
                    _ => {}
                }
            }
        }
        TagType::VorbisComments if tag.has_format_specific_items() => {
            let vc = lofty::ogg::tag::VorbisComments::from(tag.clone());
            for (k, v) in vc.items() {
                let kt = k.trim();
                let vt = v.trim();
                if !kt.is_empty()
                    && !vt.is_empty()
                    && ItemKey::from_key(TagType::VorbisComments, &kt.to_uppercase()).is_none()
                {
                    pairs.push((kt.to_string(), vt.to_string()));
                }
            }
        }
        TagType::Ape if tag.has_format_specific_items() => {
            let ape = lofty::ape::ApeTag::from(tag.clone());
            for item in &ape {
                let kt = item.key().trim();
                if let ItemValue::Text(v) | ItemValue::Locator(v) = item.value() {
                    let vt = v.trim();
                    if !kt.is_empty()
                        && !vt.is_empty()
                        && ItemKey::from_key(TagType::Ape, kt).is_none()
                        && ItemKey::from_key(TagType::Ape, &kt.to_uppercase()).is_none()
                    {
                        pairs.push((kt.to_string(), vt.to_string()));
                    }
                }
            }
        }
        TagType::Mp4Ilst if tag.has_format_specific_items() => {
            let ilst = lofty::mp4::Ilst::from(tag.clone());
            for atom in &ilst {
                if let lofty::mp4::AtomIdent::Freeform { mean, name } = atom.ident() {
                    let full_ident = format!("----:{}:{}", mean, name);
                    if ItemKey::from_key(TagType::Mp4Ilst, &full_ident).is_none() {
                        for data in atom.data() {
                            if let lofty::mp4::AtomData::UTF8(s) | lofty::mp4::AtomData::UTF16(s) =
                                data
                            {
                                let kt = name.trim();
                                let vt = s.trim();
                                if !kt.is_empty() && !vt.is_empty() {
                                    pairs.push((kt.to_string(), vt.to_string()));
                                }
                            }
                        }
                    }
                }
            }
        }
        TagType::RiffInfo if tag.has_format_specific_items() => {
            let riff = lofty::iff::wav::RiffInfoList::from(tag.clone());
            for (k, v) in &riff {
                let kt = k.trim();
                let vt = v.trim();
                if !kt.is_empty()
                    && !vt.is_empty()
                    && ItemKey::from_key(TagType::RiffInfo, &kt.to_uppercase()).is_none()
                {
                    pairs.push((kt.to_string(), vt.to_string()));
                }
            }
        }
        _ => {}
    }
    pairs
}

macro_rules! set_ext {
    ($target:expr, $tag:expr, $key:expr, $fallbacks:expr, $consumed:expr) => {
        if $target.is_none() {
            $target = get_lofty_field($tag, $key, $fallbacks, $consumed);
        } else {
            for &fb in $fallbacks {
                $consumed.insert(fb.to_uppercase());
            }
        }
    };
}

fn ingest_extended_from_lofty(
    tag: &Tag,
    ext: &mut RustExtendedMetadata,
    consumed: &mut HashSet<String>,
) {
    // MusicBrainz
    set_ext!(
        ext.music_brainz_recording_id,
        tag,
        ItemKey::MusicBrainzRecordingId,
        &["MUSICBRAINZ_TRACKID", "MusicBrainz Track Id"],
        consumed
    );
    set_ext!(
        ext.music_brainz_track_id,
        tag,
        ItemKey::MusicBrainzTrackId,
        &["MUSICBRAINZ_RELEASETRACKID", "MusicBrainz Release Track Id"],
        consumed
    );
    set_ext!(
        ext.music_brainz_release_id,
        tag,
        ItemKey::MusicBrainzReleaseId,
        &["MUSICBRAINZ_ALBUMID", "MusicBrainz Album Id"],
        consumed
    );
    set_ext!(
        ext.music_brainz_release_group_id,
        tag,
        ItemKey::MusicBrainzReleaseGroupId,
        &["MUSICBRAINZ_RELEASEGROUPID", "MusicBrainz Release Group Id"],
        consumed
    );
    set_ext!(
        ext.music_brainz_artist_id,
        tag,
        ItemKey::MusicBrainzArtistId,
        &["MUSICBRAINZ_ARTISTID", "MusicBrainz Artist Id"],
        consumed
    );
    set_ext!(
        ext.music_brainz_release_artist_id,
        tag,
        ItemKey::MusicBrainzReleaseArtistId,
        &["MUSICBRAINZ_ALBUMARTISTID", "MusicBrainz Album Artist Id"],
        consumed
    );
    set_ext!(
        ext.music_brainz_work_id,
        tag,
        ItemKey::MusicBrainzWorkId,
        &["MUSICBRAINZ_WORKID", "MusicBrainz Work Id"],
        consumed
    );
    if ext.music_brainz_release_type.is_none() {
        ext.music_brainz_release_type = get_lofty_fallback(
            tag,
            &[
                "RELEASETYPE",
                "MUSICBRAINZ_ALBUMTYPE",
                "MusicBrainz Album Type",
            ],
            consumed,
        );
    }

    // AcoustID
    set_ext!(
        ext.acoust_id,
        tag,
        ItemKey::AcoustId,
        &["ACOUSTID_ID", "Acoustid Id"],
        consumed
    );
    set_ext!(
        ext.acoust_id_fingerprint,
        tag,
        ItemKey::AcoustIdFingerprint,
        &["ACOUSTID_FINGERPRINT", "Acoustid Fingerprint"],
        consumed
    );

    // Identifiers
    set_ext!(ext.isrc, tag, ItemKey::Isrc, &["ISRC", "TSRC"], consumed);
    set_ext!(
        ext.barcode,
        tag,
        ItemKey::Barcode,
        &["BARCODE", "UPC"],
        consumed
    );
    set_ext!(
        ext.catalog_number,
        tag,
        ItemKey::CatalogNumber,
        &["CATALOGNUMBER", "CATALOG"],
        consumed
    );

    // Credits & People
    set_ext!(ext.arranger, tag, ItemKey::Arranger, &["ARRANGER"], consumed);
    set_ext!(
        ext.conductor,
        tag,
        ItemKey::Conductor,
        &["CONDUCTOR", "TPE3"],
        consumed
    );
    set_ext!(ext.director, tag, ItemKey::Director, &["DIRECTOR"], consumed);
    set_ext!(
        ext.engineer,
        tag,
        ItemKey::Engineer,
        &["ENGINEER", "IENG"],
        consumed
    );
    set_ext!(
        ext.lyricist,
        tag,
        ItemKey::Lyricist,
        &["LYRICIST", "TEXT"],
        consumed
    );
    set_ext!(ext.mix_dj, tag, ItemKey::MixDj, &["DJMIXER"], consumed);
    set_ext!(
        ext.mix_engineer,
        tag,
        ItemKey::MixEngineer,
        &["MIXER"],
        consumed
    );
    set_ext!(
        ext.performer,
        tag,
        ItemKey::Performer,
        &["PERFORMER"],
        consumed
    );
    set_ext!(ext.producer, tag, ItemKey::Producer, &["PRODUCER"], consumed);
    set_ext!(
        ext.publisher,
        tag,
        ItemKey::Publisher,
        &["PUBLISHER", "TPUB"],
        consumed
    );
    set_ext!(
        ext.label,
        tag,
        ItemKey::Label,
        &["LABEL", "ORGANIZATION"],
        consumed
    );
    set_ext!(
        ext.remixer,
        tag,
        ItemKey::Remixer,
        &["REMIXER", "TPE4", "MODIFIEDBY"],
        consumed
    );
    set_ext!(ext.writer, tag, ItemKey::Writer, &["WRITER"], consumed);
    set_ext!(
        ext.composer,
        tag,
        ItemKey::Composer,
        &["COMPOSER", "TCOM"],
        consumed
    );
    set_ext!(
        ext.original_lyricist,
        tag,
        ItemKey::OriginalLyricist,
        &["TOLY", "ORIGLYRICIST"],
        consumed
    );

    // Dates
    if ext.recording_date.is_none() && tag.tag_type() == TagType::Ape {
        if let Some(date_val) = lookup_unmapped_in_tag(tag, "DATE") {
            ext.recording_date = Some(date_val);
        }
    }
    set_ext!(
        ext.recording_date,
        tag,
        ItemKey::RecordingDate,
        &["DATE", "TDRC"],
        consumed
    );
    set_ext!(
        ext.release_date,
        tag,
        ItemKey::ReleaseDate,
        &["RELEASEDATE", "TDRL"],
        consumed
    );
    set_ext!(
        ext.original_release_date,
        tag,
        ItemKey::OriginalReleaseDate,
        &["ORIGINALDATE", "TDOR", "TORY"],
        consumed
    );

    // Style
    set_ext!(
        ext.initial_key,
        tag,
        ItemKey::InitialKey,
        &["INITIALKEY", "KEY", "TKEY"],
        consumed
    );
    set_ext!(ext.color, tag, ItemKey::Color, &["COLOR"], consumed);
    set_ext!(ext.mood, tag, ItemKey::Mood, &["MOOD", "TMOO"], consumed);

    // URLs
    set_ext!(
        ext.audio_file_url,
        tag,
        ItemKey::AudioFileUrl,
        &["WOAF"],
        consumed
    );
    set_ext!(
        ext.audio_source_url,
        tag,
        ItemKey::AudioSourceUrl,
        &["WOAS"],
        consumed
    );
    set_ext!(
        ext.commercial_information_url,
        tag,
        ItemKey::CommercialInformationUrl,
        &["WCOM"],
        consumed
    );
    set_ext!(
        ext.copyright_url,
        tag,
        ItemKey::CopyrightUrl,
        &["WCOP"],
        consumed
    );
    set_ext!(
        ext.track_artist_url,
        tag,
        ItemKey::TrackArtistUrl,
        &["WOAR"],
        consumed
    );
    set_ext!(
        ext.radio_station_url,
        tag,
        ItemKey::RadioStationUrl,
        &["WORS"],
        consumed
    );
    set_ext!(ext.payment_url, tag, ItemKey::PaymentUrl, &["WPAY"], consumed);
    set_ext!(
        ext.publisher_url,
        tag,
        ItemKey::PublisherUrl,
        &["WPUB"],
        consumed
    );

    // Legal
    set_ext!(
        ext.copyright_message,
        tag,
        ItemKey::CopyrightMessage,
        &["COPYRIGHT", "TCOP"],
        consumed
    );
    set_ext!(
        ext.license,
        tag,
        ItemKey::License,
        &["LICENSE"],
        consumed
    );

    // Podcast
    set_ext!(
        ext.podcast_description,
        tag,
        ItemKey::PodcastDescription,
        &["TDES"],
        consumed
    );
    if ext.podcast_description.is_none() && tag.tag_type() == TagType::Mp4Ilst {
        if let Some(desc) = tag_str(tag, ItemKey::Description) {
            let trimmed = desc.trim();
            if !trimmed.is_empty() {
                ext.podcast_description = Some(trimmed.to_string());
            }
        }
    }
    set_ext!(
        ext.podcast_series_category,
        tag,
        ItemKey::PodcastSeriesCategory,
        &["TCAT"],
        consumed
    );
    set_ext!(ext.podcast_url, tag, ItemKey::PodcastUrl, &["WFED"], consumed);
    set_ext!(
        ext.podcast_global_unique_id,
        tag,
        ItemKey::PodcastGlobalUniqueId,
        &["TGID"],
        consumed
    );
    set_ext!(
        ext.podcast_keywords,
        tag,
        ItemKey::PodcastKeywords,
        &["TKWD"],
        consumed
    );

    // Grouping, Sorting & Encoding
    set_ext!(
        ext.set_subtitle,
        tag,
        ItemKey::SetSubtitle,
        &["TSST", "DISCSUBTITLE"],
        consumed
    );
    set_ext!(
        ext.show_name,
        tag,
        ItemKey::ShowName,
        &["SHOW", "TVSHOW"],
        consumed
    );
    set_ext!(
        ext.content_group,
        tag,
        ItemKey::ContentGroup,
        &["GROUPING", "TIT1", "CONTENTGROUP"],
        consumed
    );
    set_ext!(
        ext.track_subtitle,
        tag,
        ItemKey::TrackSubtitle,
        &["SUBTITLE", "TIT3"],
        consumed
    );
    set_ext!(
        ext.language,
        tag,
        ItemKey::Language,
        &["LANGUAGE", "TLAN"],
        consumed
    );
    set_ext!(ext.script, tag, ItemKey::Script, &["SCRIPT"], consumed);
    set_ext!(
        ext.parental_advisory,
        tag,
        ItemKey::ParentalAdvisory,
        &["ITUNESADVISORY"],
        consumed
    );
    set_ext!(ext.file_owner, tag, ItemKey::FileOwner, &["TOWN"], consumed);
    set_ext!(
        ext.original_file_name,
        tag,
        ItemKey::OriginalFileName,
        &["TOFN"],
        consumed
    );
    set_ext!(
        ext.original_media_type,
        tag,
        ItemKey::OriginalMediaType,
        &["TMED", "MEDIA"],
        consumed
    );
    set_ext!(
        ext.encoded_by,
        tag,
        ItemKey::EncodedBy,
        &["ENCODEDBY", "TENC", "ENCODED-BY"],
        consumed
    );
    set_ext!(
        ext.encoder_software,
        tag,
        ItemKey::EncoderSoftware,
        &["ENCODER", "TSSE"],
        consumed
    );
    if ext.encoder_settings.is_none() && tag.tag_type() == TagType::Id3v2 {
        if let Some(settings) = lookup_unmapped_in_tag(tag, "ENCODERSETTINGS") {
            ext.encoder_settings = Some(settings);
        }
    }
    set_ext!(
        ext.encoder_settings,
        tag,
        ItemKey::EncoderSettings,
        &["ENCODERSETTINGS", "TSSE"],
        consumed
    );
}

// =========================================================================
// Special Container Extractors (DSF, RF64, RIFX, W64, BWF)
// =========================================================================

fn try_parse_special_containers_seekable<R: Read + Seek>(
    reader: &mut R,
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let mut header = [0u8; 64];
    let Ok(n) = reader.read(&mut header) else {
        return;
    };
    if n < 12 {
        return;
    }

    // 1. DSF container ("DSD ")
    if &header[0..4] == b"DSD " && n >= 28 {
        let meta_offset = u64::from_le_bytes(header[20..28].try_into().unwrap_or([0; 8]));
        if meta_offset > 0 && reader.seek(SeekFrom::Start(meta_offset)).is_ok() {
            let mut id3_buf = Vec::new();
            if reader.take(16 * 1024 * 1024).read_to_end(&mut id3_buf).is_ok()
                && id3_buf.starts_with(b"ID3")
            {
                parse_raw_id3v2_slice(&id3_buf, out, consumed);
            }
        }
        return;
    }

    // 2. RF64 or RIFX or BWF/WAV
    if (&header[0..4] == b"RF64" || &header[0..4] == b"RIFX" || &header[0..4] == b"RIFF")
        && &header[8..12] == b"WAVE"
    {
        let is_be = &header[0..4] == b"RIFX";
        parse_riff_family_chunks(reader, is_be, out, consumed);
        return;
    }

    // 3. Sony Wave64 (W64)
    const W64_RIFF_GUID: [u8; 16] = [
        0x72, 0x69, 0x66, 0x66, 0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00,
        0x00,
    ];
    if n >= 40 && header[0..16] == W64_RIFF_GUID {
        parse_w64_chunks(reader, out, consumed);
        return;
    }

    // 4. Apple Core Audio Format ("caff")
    if &header[0..4] == b"caff" {
        parse_caf_chunks(reader, out, consumed);
        return;
    }

    // 5. MP4 / M4A ("ftyp"): parse Nero `chpl` chapters when standard tags lack chapters
    if &header[4..8] == b"ftyp" && out.chapters.is_empty() {
        parse_mp4_chpl_chapters(reader, out);
        return;
    }

    // 6. AIFF / AIFC fallback if lofty could not open the stream directly
    if &header[0..4] == b"FORM"
        && (&header[8..12] == b"AIFF" || &header[8..12] == b"AIFC")
        && out.tag_formats.is_empty()
    {
        parse_aiff_chunks(reader, out, consumed);
    }
}

fn read_bmff_box_header<R: Read + Seek>(reader: &mut R, pos: u64) -> Option<(u64, u64, [u8; 4])> {
    if reader.seek(SeekFrom::Start(pos)).is_err() {
        return None;
    }
    let mut hdr = [0u8; 8];
    if reader.read_exact(&mut hdr).is_err() {
        return None;
    }
    let sz32 = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as u64;
    let fourcc = [hdr[4], hdr[5], hdr[6], hdr[7]];
    if sz32 == 1 {
        let mut ext = [0u8; 8];
        if reader.read_exact(&mut ext).is_err() {
            return None;
        }
        let sz64 = u64::from_be_bytes(ext);
        if sz64 < 16 {
            return None;
        }
        let next = pos.checked_add(sz64)?;
        Some((pos + 16, next, fourcc))
    } else if sz32 >= 8 {
        let next = pos.checked_add(sz32)?;
        Some((pos + 8, next, fourcc))
    } else {
        None
    }
}

fn find_bmff_child_box<R: Read + Seek>(
    reader: &mut R,
    start: u64,
    end: u64,
    target: [u8; 4],
) -> Option<(u64, u64)> {
    let mut pos = start;
    let mut count = 0u32;
    while count < 128 && (end == u64::MAX || pos + 8 <= end) {
        count += 1;
        let (payload_start, next_pos, fourcc) = read_bmff_box_header(reader, pos)?;
        if fourcc == target {
            return Some((payload_start, next_pos));
        }
        if next_pos <= pos {
            break;
        }
        pos = next_pos;
    }
    None
}

fn parse_mp4_chpl_chapters<R: Read + Seek>(reader: &mut R, out: &mut RustAudioMetadata) {
    let Some((moov_start, moov_end)) = find_bmff_child_box(reader, 0, u64::MAX, *b"moov") else {
        return;
    };
    let Some((udta_start, udta_end)) = find_bmff_child_box(reader, moov_start, moov_end, *b"udta") else {
        return;
    };
    let Some((chpl_start, chpl_end)) = find_bmff_child_box(reader, udta_start, udta_end, *b"chpl") else {
        return;
    };
    let payload_len = chpl_end.saturating_sub(chpl_start);
    if !(9..=1024 * 1024).contains(&payload_len) {
        return;
    }
    if reader.seek(SeekFrom::Start(chpl_start)).is_err() {
        return;
    }
    let mut payload = vec![0u8; payload_len as usize];
    if reader.read_exact(&mut payload).is_err() {
        return;
    }
    let version = payload[0];
    let (count, mut p) = if version == 1 {
        (payload[8] as usize, 9usize)
    } else if payload[4..7] == [0, 0, 0] && payload[7] > 0 {
        (payload[7] as usize, 8usize)
    } else {
        (payload[4] as usize, 5usize)
    };
    let mut parsed = Vec::with_capacity(count);
    for i in 0..count {
        if p + 9 > payload.len() {
            break;
        }
        let start_100ns = u64::from_be_bytes(payload[p..p + 8].try_into().unwrap_or([0; 8]));
        let start_ms = start_100ns / 10_000;
        let tlen = payload[p + 8] as usize;
        p += 9;
        if p + tlen > payload.len() {
            break;
        }
        let raw_title = String::from_utf8_lossy(&payload[p..p + tlen])
            .trim()
            .to_string();
        p += tlen;
        let title = if raw_title.is_empty() {
            format!("Chapter {}", i + 1)
        } else {
            raw_title
        };
        parsed.push(RustAudioChapter {
            title,
            start_ms,
            end_ms: start_ms,
        });
    }
    for i in 0..parsed.len().saturating_sub(1) {
        parsed[i].end_ms = parsed[i + 1].start_ms.max(parsed[i].start_ms);
    }
    if !parsed.is_empty() {
        out.chapters = parsed;
    }
}

fn parse_aiff_chunks<R: Read + Seek>(
    reader: &mut R,
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let mut pos = 12u64;
    let mut id3_chunks: Vec<Vec<u8>> = Vec::new();
    let mut name: Option<String> = None;
    let mut author: Option<String> = None;
    let mut copyright: Option<String> = None;
    let mut anno: Option<String> = None;

    for _ in 0..64 {
        if reader.seek(SeekFrom::Start(pos)).is_err() {
            break;
        }
        let mut hdr = [0u8; 8];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        let id = &hdr[0..4];
        let chunk_size = u32::from_be_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]) as u64;
        if id != b"SSND" && chunk_size > 0 && chunk_size <= 16 * 1024 * 1024 {
            let mut buf = vec![0u8; chunk_size as usize];
            if reader.read_exact(&mut buf).is_ok() {
                if (id == b"ID3 " || id == b"id3 ") && buf.starts_with(b"ID3") {
                    id3_chunks.push(buf);
                } else {
                    let s = String::from_utf8_lossy(&buf)
                        .trim_end_matches('\0')
                        .trim()
                        .to_string();
                    if !s.is_empty() {
                        match id {
                            b"NAME" if name.is_none() => name = Some(s),
                            b"AUTH" if author.is_none() => author = Some(s),
                            b"(c) " if copyright.is_none() => copyright = Some(s),
                            b"ANNO" if anno.is_none() => anno = Some(s),
                            _ => {}
                        }
                    }
                }
            }
        }
        let padded = (chunk_size + 1) & !1;
        match pos.checked_add(8 + padded) {
            Some(next) if next > pos => pos = next,
            _ => break,
        }
    }

    for id3_buf in id3_chunks {
        parse_raw_id3v2_slice(&id3_buf, out, consumed);
    }
    let has_text = name.is_some() || author.is_some() || copyright.is_some() || anno.is_some();
    if out.title.is_none() {
        out.title = name;
    }
    if out.track_artist.is_none() {
        out.track_artist = author;
    }
    if out.extended.copyright_message.is_none() {
        out.extended.copyright_message = copyright;
    }
    if out.comment.is_none() {
        out.comment = anno;
    }
    if has_text && !out.tag_formats.iter().any(|f| f == "AiffText") {
        out.tag_formats.push("AiffText".to_string());
    }
}

fn parse_caf_chunks<R: Read + Seek>(
    reader: &mut R,
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let mut pos = 8u64;
    let mut found_any = false;
    let mut chunks_seen = 0u32;

    while chunks_seen < 64 {
        chunks_seen += 1;
        if reader.seek(SeekFrom::Start(pos)).is_err() {
            break;
        }
        let mut hdr = [0u8; 12];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        let id = &hdr[0..4];
        let chunk_size = i64::from_be_bytes(hdr[4..12].try_into().unwrap_or([0; 8]));
        let body_pos = pos + 12;

        if id == b"info" && chunk_size > 4 && chunk_size <= 4 * 1024 * 1024 {
            let mut body = vec![0u8; chunk_size as usize];
            if reader.read_exact(&mut body).is_ok() && ingest_caf_info_chunk(&body, out, consumed) {
                found_any = true;
            }
        } else if id == b"data" {
            // Stop at audio payload so streaming metadata buffers never wait for multi-MB PCM payloads.
            break;
        }

        if chunk_size < 0 {
            break;
        }
        match body_pos.checked_add(chunk_size as u64) {
            Some(next) if next > pos => pos = next,
            _ => break,
        }
    }

    if found_any && !out.tag_formats.iter().any(|f| f == "CAF") {
        out.tag_formats.push("CAF".to_string());
    }
}

fn ingest_caf_info_chunk(
    body: &[u8],
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) -> bool {
    if body.len() < 4 {
        return false;
    }
    let entry_count = u32::from_be_bytes(body[0..4].try_into().unwrap_or([0; 4])) as usize;
    let mut p = 4usize;
    let mut any = false;

    for _ in 0..entry_count.min(1024) {
        if p >= body.len() {
            break;
        }
        let Some(k_rel) = body[p..].iter().position(|&b| b == 0) else {
            break;
        };
        let key = String::from_utf8_lossy(&body[p..p + k_rel]).trim().to_string();
        p += k_rel + 1;
        if p > body.len() {
            break;
        }
        let v_rel = body[p..].iter().position(|&b| b == 0).unwrap_or(body.len() - p);
        let val = String::from_utf8_lossy(&body[p..p + v_rel]).trim().to_string();
        p = (p + v_rel + 1).min(body.len());

        if key.is_empty() || val.is_empty() {
            continue;
        }
        any = true;
        let k_lower = key.to_ascii_lowercase();
        consumed.insert(k_lower.to_uppercase());
        match k_lower.as_str() {
            "title" => {
                if out.title.is_none() {
                    out.title = Some(val);
                }
            }
            "artist" => {
                if out.track_artist.is_none() {
                    out.track_artist = Some(val);
                }
            }
            "album" => {
                if out.album.is_none() {
                    out.album = Some(val);
                }
            }
            "album artist" | "albumartist" => {
                if out.album_artist.is_none() {
                    out.album_artist = Some(val);
                }
            }
            "genre" => {
                if out.genre.is_none() {
                    out.genre = Some(val);
                }
            }
            "year" | "recorded date" => {
                if out.year.is_none() {
                    out.year = val.get(0..4).and_then(|s| s.parse::<u32>().ok());
                }
                if out.extended.recording_date.is_none() {
                    out.extended.recording_date = Some(val);
                }
            }
            "track number" | "track" => {
                if out.track_number.is_none() {
                    out.track_number = parse_leading_u32(&val);
                }
                if out.track_total.is_none() {
                    out.track_total = parse_slash_total_u32(&val);
                }
            }
            "disc number" | "disc" => {
                if out.disc_number.is_none() {
                    out.disc_number = parse_leading_u32(&val);
                }
                if out.disc_total.is_none() {
                    out.disc_total = parse_slash_total_u32(&val);
                }
            }
            "composer" => {
                if out.extended.composer.is_none() {
                    out.extended.composer = Some(val);
                }
            }
            "comments" | "comment" => {
                if out.comment.is_none() {
                    out.comment = Some(val);
                }
            }
            "copyright" => {
                if out.extended.copyright_message.is_none() {
                    out.extended.copyright_message = Some(val);
                }
            }
            "encoded by" => {
                if out.extended.encoded_by.is_none() {
                    out.extended.encoded_by = Some(val);
                }
            }
            "encoder" => {
                if out.extended.encoder_software.is_none() {
                    out.extended.encoder_software = Some(val);
                }
            }
            "tempo" => {
                if out.bpm.is_none() {
                    out.bpm = val.parse::<f32>().ok();
                }
            }
            "key signature" => {
                if out.extended.initial_key.is_none() {
                    out.extended.initial_key = Some(val);
                }
            }
            "lyrics" => {
                if out.lyrics.is_none() {
                    out.lyrics = Some(val);
                }
            }
            _ => {
                if !out
                    .custom_tags
                    .iter()
                    .any(|f| f.key.eq_ignore_ascii_case(&key))
                {
                    out.custom_tags.push(RustCustomTagField { key, value: val });
                }
            }
        }
    }

    any
}

fn parse_raw_id3v2_slice(
    id3_slice: &[u8],
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let has_leading_id3v2 = id3_slice.starts_with(b"ID3") && id3_slice.len() >= 10;
    let has_trailing_tag = id3_slice.starts_with(b"APETAGEX")
        || (id3_slice.len() >= 128
            && &id3_slice[id3_slice.len() - 128..id3_slice.len() - 125] == b"TAG");
    if !has_leading_id3v2 && !has_trailing_tag {
        return;
    }

    if has_leading_id3v2 {
        extract_id3v2_header_and_chapters_from_slice(id3_slice, out);
    }

    let id3_end = if has_leading_id3v2 {
        let tag_size = decode_synchsafe(&id3_slice[6..10]) as usize;
        let footer = if (id3_slice[5] & 0x10) != 0 { 10 } else { 0 };
        (10 + tag_size + footer).min(id3_slice.len())
    } else {
        0
    };

    // Wrap the raw ID3v2 / trailing APEv2 / ID3v1 block with two minimal valid
    // MPEG1 Layer3 128kbps 44.1kHz frames so `lofty` can parse all tags through its MPEG reader.
    let mut synthetic_mp3 = Vec::with_capacity(id3_slice.len() + 836);
    if id3_end > 0 {
        synthetic_mp3.extend_from_slice(&id3_slice[..id3_end]);
    }
    let mut frame = [0u8; 418];
    frame[0] = 0xFF;
    frame[1] = 0xFB;
    frame[2] = 0x90;
    frame[3] = 0x64;
    synthetic_mp3.extend_from_slice(&frame);
    synthetic_mp3.extend_from_slice(&frame);
    if id3_slice.len() > id3_end {
        synthetic_mp3.extend_from_slice(&id3_slice[id3_end..]);
    }

    let mut cursor = Cursor::new(synthetic_mp3.as_slice());
    let options = ParseOptions::new()
        .read_properties(false)
        .parsing_mode(ParsingMode::Relaxed);
    if let Ok(tagged) = Probe::with_file_type(&mut cursor, FileType::Mpeg)
        .options(options)
        .read()
    {
        for t in tagged.tags() {
            let fmt_name = map_lofty_tag_type(t.tag_type());
            if !out.tag_formats.iter().any(|existing| existing == fmt_name) {
                out.tag_formats.push(fmt_name.to_string());
            }
            ingest_lofty_tag(t, out, consumed);
        }
    }
}

fn parse_riff_family_chunks<R: Read + Seek>(
    reader: &mut R,
    is_big_endian: bool,
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let mut pos = 12u64;
    let mut ds64_data_size = 0u64;
    let mut id3_chunks: Vec<Vec<u8>> = Vec::new();
    let mut info_chunks: Vec<Vec<u8>> = Vec::new();
    let mut bext_chunks: Vec<Vec<u8>> = Vec::new();

    loop {
        if reader.seek(SeekFrom::Start(pos)).is_err() {
            break;
        }
        let mut hdr = [0u8; 8];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        let id = &hdr[0..4];
        let sz_bytes = [hdr[4], hdr[5], hdr[6], hdr[7]];
        let mut chunk_size = if is_big_endian {
            u32::from_be_bytes(sz_bytes) as u64
        } else {
            u32::from_le_bytes(sz_bytes) as u64
        };

        if !is_big_endian && id == b"ds64" && chunk_size >= 24 {
            let mut ds_buf = [0u8; 24];
            if reader.read_exact(&mut ds_buf).is_ok() {
                ds64_data_size = u64::from_le_bytes(ds_buf[8..16].try_into().unwrap_or([0; 8]));
            }
        } else if id == b"data" && chunk_size == 0xFFFFFFFF && ds64_data_size > 0 {
            chunk_size = ds64_data_size;
        } else if (id == b"id3 " || id == b"ID3 ") && (11..=16 * 1024 * 1024).contains(&chunk_size) {
            let mut id3_buf = vec![0u8; chunk_size as usize];
            if reader.read_exact(&mut id3_buf).is_ok() {
                id3_chunks.push(id3_buf);
            }
        } else if id == b"LIST" && (4..=4 * 1024 * 1024).contains(&chunk_size) {
            let mut list_buf = vec![0u8; chunk_size as usize];
            if reader.read_exact(&mut list_buf).is_ok() && list_buf.starts_with(b"INFO") {
                info_chunks.push(list_buf[4..].to_vec());
            }
        } else if id == b"bext" && (348..=1024 * 1024).contains(&chunk_size) {
            let mut bext_buf = vec![0u8; chunk_size as usize];
            if reader.read_exact(&mut bext_buf).is_ok() {
                bext_chunks.push(bext_buf);
            }
        }

        let padded = (chunk_size + 1) & !1;
        match pos.checked_add(8 + padded) {
            Some(next) if next > pos => pos = next,
            _ => break,
        }
    }

    // Strict metadata priority: ID3v2 > LIST(INFO) > BWF bext
    for id3_buf in id3_chunks {
        parse_raw_id3v2_slice(&id3_buf, out, consumed);
    }
    for info_buf in info_chunks {
        parse_riff_info_subchunks(&info_buf, is_big_endian, out, consumed);
    }
    for bext_buf in bext_chunks {
        parse_bwf_bext_chunk(&bext_buf, out);
    }
}

fn parse_w64_chunks<R: Read + Seek>(
    reader: &mut R,
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let mut pos = 40u64;
    let mut id3_chunks: Vec<Vec<u8>> = Vec::new();
    let mut info_chunks: Vec<Vec<u8>> = Vec::new();

    loop {
        if reader.seek(SeekFrom::Start(pos)).is_err() {
            break;
        }
        let mut hdr = [0u8; 24];
        if reader.read_exact(&mut hdr).is_err() {
            break;
        }
        let prefix = &hdr[0..4];
        let chunk_size = u64::from_le_bytes(hdr[16..24].try_into().unwrap_or([0; 8]));
        if chunk_size < 24 {
            break;
        }
        let payload_size = chunk_size - 24;
        if (prefix == b"id3 " || prefix == b"ID3 ")
            && payload_size > 10
            && payload_size <= 16 * 1024 * 1024
        {
            let mut id3_buf = vec![0u8; payload_size as usize];
            if reader.read_exact(&mut id3_buf).is_ok() {
                id3_chunks.push(id3_buf);
            }
        } else if (prefix == b"list" || prefix == b"LIST")
            && (4..=4 * 1024 * 1024).contains(&payload_size)
        {
            let mut list_buf = vec![0u8; payload_size as usize];
            if reader.read_exact(&mut list_buf).is_ok() {
                let slice = if list_buf.len() >= 16 && &list_buf[0..4] == b"info" {
                    &list_buf[16..]
                } else if list_buf.starts_with(b"INFO") {
                    &list_buf[4..]
                } else {
                    &[]
                };
                if !slice.is_empty() {
                    info_chunks.push(slice.to_vec());
                }
            }
        }
        let aligned = (chunk_size + 7) & !7;
        match pos.checked_add(aligned) {
            Some(next) if next > pos => pos = next,
            _ => break,
        }
    }

    // Strict metadata priority: ID3v2 > list(INFO)
    for id3_buf in id3_chunks {
        parse_raw_id3v2_slice(&id3_buf, out, consumed);
    }
    for info_buf in info_chunks {
        parse_riff_info_subchunks(&info_buf, false, out, consumed);
    }
}

fn parse_riff_info_subchunks(
    data: &[u8],
    is_big_endian: bool,
    out: &mut RustAudioMetadata,
    consumed: &mut HashSet<String>,
) {
    let mut p = 0usize;
    let mut found_any = false;
    while p + 8 <= data.len() {
        let id = &data[p..p + 4];
        let sz_bytes = [data[p + 4], data[p + 5], data[p + 6], data[p + 7]];
        let sz = if is_big_endian {
            u32::from_be_bytes(sz_bytes) as usize
        } else {
            u32::from_le_bytes(sz_bytes) as usize
        };
        p += 8;
        if p + sz > data.len() {
            break;
        }
        let raw_val = &data[p..p + sz];
        let val = String::from_utf8_lossy(raw_val)
            .trim_end_matches('\0')
            .trim()
            .to_string();
        if !val.is_empty() {
            found_any = true;
            match id {
                b"INAM" if out.title.is_none() => out.title = Some(val),
                b"IART" if out.track_artist.is_none() => out.track_artist = Some(val),
                b"IPRD" if out.album.is_none() => out.album = Some(val),
                b"IGNR" if out.genre.is_none() => out.genre = Some(val),
                b"ICMT" if out.comment.is_none() => out.comment = Some(val),
                b"ICRD" => {
                    if out.year.is_none() {
                        out.year = val.get(0..4).and_then(|s| s.parse::<u32>().ok());
                    }
                    if out.extended.recording_date.is_none() {
                        out.extended.recording_date = Some(val);
                    }
                }
                b"ITRK" | b"IPRT" => {
                    if out.track_number.is_none() {
                        out.track_number = parse_leading_u32(&val);
                    }
                    if out.track_total.is_none() {
                        out.track_total = parse_slash_total_u32(&val);
                    }
                }
                b"ICOP" if out.extended.copyright_message.is_none() => {
                    out.extended.copyright_message = Some(val);
                }
                b"ISFT" if out.extended.encoder_software.is_none() => {
                    out.extended.encoder_software = Some(val);
                }
                b"IENG" => {
                    consumed.insert("IENG".to_string());
                    if out.extended.engineer.is_none() {
                        out.extended.engineer = Some(val);
                    }
                }
                b"ISRC" if out.extended.isrc.is_none() => out.extended.isrc = Some(val),
                _ => {}
            }
        }
        p += (sz + 1) & !1;
    }
    if found_any && !out.tag_formats.iter().any(|f| f == "RiffInfo") {
        out.tag_formats.push("RiffInfo".to_string());
    }
}

fn parse_bwf_bext_chunk(bext: &[u8], out: &mut RustAudioMetadata) {
    if bext.len() < 348 {
        return;
    }
    let desc = String::from_utf8_lossy(&bext[0..256])
        .trim_end_matches('\0')
        .trim()
        .to_string();
    let originator = String::from_utf8_lossy(&bext[256..288])
        .trim_end_matches('\0')
        .trim()
        .to_string();
    let orig_date = String::from_utf8_lossy(&bext[320..330])
        .trim_end_matches('\0')
        .trim()
        .to_string();

    let mut any = false;
    if !desc.is_empty() && out.comment.is_none() {
        out.comment = Some(desc);
        any = true;
    }
    if !originator.is_empty() && out.extended.encoded_by.is_none() {
        out.extended.encoded_by = Some(originator);
        any = true;
    }
    if !orig_date.is_empty() && out.extended.recording_date.is_none() {
        out.extended.recording_date = Some(orig_date);
        any = true;
    }
    if any && !out.tag_formats.iter().any(|f| f == "RiffInfo") {
        out.tag_formats.push("RiffInfo".to_string());
    }
}

// =========================================================================
// Binary ID3v2 Version & CHAP Chapter Extractor + Vorbis CHAPTERxxx
// =========================================================================

fn extract_id3v2_header_and_chapters_from_reader<R: Read + Seek>(
    reader: &mut R,
    out: &mut RustAudioMetadata,
) {
    let mut header = [0u8; 10];
    if reader.read_exact(&mut header).is_err() || &header[0..3] != b"ID3" {
        return;
    }
    let version = header[3];
    if out.id3v2_version.is_none() {
        out.id3v2_version = match version {
            2 => Some(RustId3v2Version::V2),
            3 => Some(RustId3v2Version::V3),
            4 => Some(RustId3v2Version::V4),
            _ => None,
        };
    }
    if !out.chapters.is_empty() || (version != 3 && version != 4) {
        return;
    }
    let tag_size = decode_synchsafe(&header[6..10]) as usize;
    if tag_size == 0 || tag_size > 32 * 1024 * 1024 {
        return;
    }
    let mut full_id3 = Vec::with_capacity(10 + tag_size);
    full_id3.extend_from_slice(&header);
    if reader
        .take(tag_size as u64)
        .read_to_end(&mut full_id3)
        .is_ok()
    {
        let chaps = parse_id3v2_chap_frames(&full_id3);
        if !chaps.is_empty() {
            out.chapters = chaps;
        }
    }
}

#[inline]
fn is_valid_id3v2_header(w: &[u8]) -> bool {
    w.len() >= 10
        && &w[0..3] == b"ID3"
        && matches!(w[3], 2..=4)
        && w[4] == 0
        && (w[6] & 0x80) == 0
        && (w[7] & 0x80) == 0
        && (w[8] & 0x80) == 0
        && (w[9] & 0x80) == 0
}

fn extract_id3v2_header_and_chapters_from_slice(data: &[u8], out: &mut RustAudioMetadata) {
    if data.len() < 10 {
        return;
    }
    let id3_pos = if is_valid_id3v2_header(data) {
        Some(0)
    } else {
        data.windows(10).position(is_valid_id3v2_header)
    };
    let Some(pos) = id3_pos else {
        return;
    };
    let slice = &data[pos..];
    if slice.len() < 10 {
        return;
    }
    let version = slice[3];
    if out.id3v2_version.is_none() {
        out.id3v2_version = match version {
            2 => Some(RustId3v2Version::V2),
            3 => Some(RustId3v2Version::V3),
            4 => Some(RustId3v2Version::V4),
            _ => None,
        };
    }
    if out.chapters.is_empty() && (version == 3 || version == 4) {
        let chaps = parse_id3v2_chap_frames(slice);
        if !chaps.is_empty() {
            out.chapters = chaps;
        }
    }
}

fn parse_id3v2_chap_frames(data: &[u8]) -> Vec<RustAudioChapter> {
    let mut chapters = Vec::new();
    if data.len() < 10 || &data[0..3] != b"ID3" {
        return chapters;
    }

    let version = data[3];
    let flags = data[5];
    let tag_size = decode_synchsafe(&data[6..10]) as usize;
    if version != 3 && version != 4 {
        return chapters;
    }

    let end = (10 + tag_size).min(data.len());
    let raw_tag = &data[10..end];

    let tag_cow: std::borrow::Cow<[u8]> = if (flags & 0x80) != 0 && version == 3 {
        let mut unsync = Vec::with_capacity(raw_tag.len());
        let mut i = 0;
        while i < raw_tag.len() {
            unsync.push(raw_tag[i]);
            if raw_tag[i] == 0xFF && i + 1 < raw_tag.len() && raw_tag[i + 1] == 0x00 {
                i += 2;
            } else {
                i += 1;
            }
        }
        std::borrow::Cow::Owned(unsync)
    } else {
        std::borrow::Cow::Borrowed(raw_tag)
    };

    let tag_bytes = tag_cow.as_ref();
    let mut offset = 0usize;

    if (flags & 0x40) != 0 && tag_bytes.len() >= 4 {
        let ext_size = if version == 4 {
            decode_synchsafe(&tag_bytes[0..4]) as usize
        } else {
            u32::from_be_bytes([tag_bytes[0], tag_bytes[1], tag_bytes[2], tag_bytes[3]]) as usize + 4
        };
        offset += ext_size;
    }

    while offset + 10 <= tag_bytes.len() {
        let frame_id = &tag_bytes[offset..offset + 4];
        if frame_id == [0, 0, 0, 0] || !frame_id.iter().all(|&b| b.is_ascii_alphanumeric()) {
            break;
        }
        let size_bytes = &tag_bytes[offset + 4..offset + 8];
        let mut frame_size = if version == 4 {
            decode_synchsafe(size_bytes) as usize
        } else {
            u32::from_be_bytes([size_bytes[0], size_bytes[1], size_bytes[2], size_bytes[3]])
                as usize
        };
        if version == 4 && frame_id == b"CHAP" && offset + 10 + frame_size > tag_bytes.len() {
            let alt =
                u32::from_be_bytes([size_bytes[0], size_bytes[1], size_bytes[2], size_bytes[3]])
                    as usize;
            if offset + 10 + alt <= tag_bytes.len() {
                frame_size = alt;
            }
        }

        let frame_flags = [tag_bytes[offset + 8], tag_bytes[offset + 9]];
        offset += 10;
        if frame_size == 0 || offset + frame_size > tag_bytes.len() {
            break;
        }

        if frame_id == b"CHAP" {
            let mut f_data = &tag_bytes[offset..offset + frame_size];
            let mut cow_f = std::borrow::Cow::Borrowed(f_data);
            if version == 4 && (frame_flags[1] & 0x02) != 0 {
                let mut unsync = Vec::with_capacity(f_data.len());
                let mut i = 0;
                while i < f_data.len() {
                    unsync.push(f_data[i]);
                    if f_data[i] == 0xFF && i + 1 < f_data.len() && f_data[i + 1] == 0x00 {
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
                cow_f = std::borrow::Cow::Owned(unsync);
            }
            if version == 4 && (frame_flags[1] & 0x01) != 0 && cow_f.len() >= 4 {
                cow_f = match cow_f {
                    std::borrow::Cow::Borrowed(b) => std::borrow::Cow::Borrowed(&b[4..]),
                    std::borrow::Cow::Owned(mut v) => {
                        v.drain(0..4);
                        std::borrow::Cow::Owned(v)
                    }
                };
            }
            f_data = cow_f.as_ref();
            if let Some(chap) = parse_single_chap_frame(f_data, version) {
                chapters.push(chap);
            }
        }

        offset += frame_size;
    }

    chapters
}

fn parse_single_chap_frame(data: &[u8], version: u8) -> Option<RustAudioChapter> {
    let null_pos = data.iter().position(|&b| b == 0)?;
    let time_offset = null_pos + 1;
    if time_offset + 16 > data.len() {
        return None;
    }
    let start_ms = u32::from_be_bytes([
        data[time_offset],
        data[time_offset + 1],
        data[time_offset + 2],
        data[time_offset + 3],
    ]) as u64;
    let end_ms = u32::from_be_bytes([
        data[time_offset + 4],
        data[time_offset + 5],
        data[time_offset + 6],
        data[time_offset + 7],
    ]) as u64;

    let mut sub_offset = time_offset + 16;
    let mut title = String::new();

    while sub_offset + 10 <= data.len() {
        let sub_id = &data[sub_offset..sub_offset + 4];
        if sub_id == [0, 0, 0, 0] {
            break;
        }
        let s_bytes = &data[sub_offset + 4..sub_offset + 8];
        let mut sub_size = if version == 4 {
            decode_synchsafe(s_bytes) as usize
        } else {
            u32::from_be_bytes([s_bytes[0], s_bytes[1], s_bytes[2], s_bytes[3]]) as usize
        };
        if version == 4 && sub_offset + 10 + sub_size > data.len() {
            let alt = u32::from_be_bytes([s_bytes[0], s_bytes[1], s_bytes[2], s_bytes[3]]) as usize;
            if sub_offset + 10 + alt <= data.len() {
                sub_size = alt;
            }
        }
        sub_offset += 10;
        if sub_size == 0 || sub_offset + sub_size > data.len() {
            break;
        }
        if sub_id == b"TIT2" {
            let sub_data = &data[sub_offset..sub_offset + sub_size];
            if !sub_data.is_empty() {
                title = decode_id3_text(sub_data[0], &sub_data[1..]);
            }
        }
        sub_offset += sub_size;
    }

    if title.is_empty() {
        title = String::from_utf8_lossy(&data[0..null_pos]).to_string();
    }

    Some(RustAudioChapter {
        title,
        start_ms,
        end_ms,
    })
}

fn decode_id3_text(encoding: u8, bytes: &[u8]) -> String {
    match encoding {
        0 => bytes
            .iter()
            .take_while(|&&b| b != 0)
            .map(|&b| b as char)
            .collect(),
        1 => {
            if bytes.len() < 2 {
                return String::new();
            }
            let (is_le, start) = if bytes.starts_with(&[0xFF, 0xFE]) {
                (true, 2)
            } else if bytes.starts_with(&[0xFE, 0xFF]) {
                (false, 2)
            } else {
                (true, 0)
            };
            let u16_iter = bytes[start..]
                .chunks_exact(2)
                .map(|c| {
                    if is_le {
                        u16::from_le_bytes([c[0], c[1]])
                    } else {
                        u16::from_be_bytes([c[0], c[1]])
                    }
                })
                .take_while(|&u| u != 0)
                .collect::<Vec<u16>>();
            String::from_utf16_lossy(&u16_iter)
        }
        2 => {
            let u16_iter = bytes
                .chunks_exact(2)
                .map(|c| u16::from_be_bytes([c[0], c[1]]))
                .take_while(|&u| u != 0)
                .collect::<Vec<u16>>();
            String::from_utf16_lossy(&u16_iter)
        }
        3 => {
            let slice = match bytes.iter().position(|&b| b == 0) {
                Some(pos) => &bytes[..pos],
                None => bytes,
            };
            String::from_utf8_lossy(slice).to_string()
        }
        _ => String::new(),
    }
}

#[inline]
fn decode_synchsafe(bytes: &[u8]) -> u32 {
    ((bytes[0] as u32 & 0x7F) << 21)
        | ((bytes[1] as u32 & 0x7F) << 14)
        | ((bytes[2] as u32 & 0x7F) << 7)
        | (bytes[3] as u32 & 0x7F)
}

fn extract_vorbis_chapters(
    unmapped_items: &[(String, String)],
    consumed: &mut HashSet<String>,
) -> Vec<RustAudioChapter> {
    let mut times: HashMap<u32, u64> = HashMap::new();
    let mut names: HashMap<u32, String> = HashMap::new();

    for (key, val) in unmapped_items {
        let upper = key.to_uppercase();
        if let Some(rest) = upper.strip_prefix("CHAPTER") {
            if rest.len() == 3 {
                if let Ok(idx) = rest.parse::<u32>() {
                    if let Some(ms) = parse_vorbis_timestamp(val) {
                        consumed.insert(upper);
                        times.insert(idx, ms);
                    }
                }
            } else if rest.len() == 7 && rest.ends_with("NAME") {
                if let Ok(idx) = rest[0..3].parse::<u32>() {
                    consumed.insert(upper);
                    names.insert(idx, val.clone());
                }
            }
        }
    }

    let mut indices: Vec<u32> = times.keys().copied().collect();
    indices.sort_unstable();

    let mut chapters = Vec::with_capacity(indices.len());
    for (i, &idx) in indices.iter().enumerate() {
        let start_ms = times[&idx];
        let end_ms = if i + 1 < indices.len() {
            times[&indices[i + 1]]
        } else {
            start_ms
        };
        let title = names
            .remove(&idx)
            .unwrap_or_else(|| format!("Chapter {}", idx));
        chapters.push(RustAudioChapter {
            title,
            start_ms,
            end_ms,
        });
    }
    chapters
}

fn parse_vorbis_timestamp(ts: &str) -> Option<u64> {
    let parts: Vec<&str> = ts.trim().split(':').collect();
    if parts.len() != 3 {
        return None;
    }
    let hours: u64 = parts[0].parse().ok()?;
    let mins: u64 = parts[1].parse().ok()?;
    let sec_parts: Vec<&str> = parts[2].split('.').collect();
    let secs: u64 = sec_parts[0].parse().ok()?;
    let millis: u64 = if sec_parts.len() > 1 {
        let mut ms_str = sec_parts[1].to_string();
        ms_str.truncate(3);
        while ms_str.len() < 3 {
            ms_str.push('0');
        }
        ms_str.parse().ok()?
    } else {
        0
    };
    Some((hours * 3600 + mins * 60 + secs) * 1000 + millis)
}

// =========================================================================
// Symphonia Metadata Bridge (Matroska / WebM / MKA / CAF / Fallback)
// =========================================================================

#[inline]
fn strip_symphonia_key(raw: &str) -> &str {
    let trimmed = raw.trim();
    let after_scope = if let Some(pos) = trimmed.rfind('@') {
        &trimmed[pos + 1..]
    } else {
        trimmed
    };
    let lower = after_scope.to_ascii_lowercase();
    if lower.starts_with("----:com.apple.itunes:") {
        &after_scope["----:com.apple.iTunes:".len()..]
    } else if lower.starts_with("com.apple.itunes:") {
        &after_scope["com.apple.iTunes:".len()..]
    } else {
        after_scope
    }
}

fn merge_symphonia_metadata(
    out: &mut RustAudioMetadata,
    sym: &SymphoniaExtractedMeta,
    container_format: &str,
    consumed_custom_keys: &HashSet<String>,
) {
    use symphonia::core::meta::StandardTag as ST;

    if out.tag_formats.is_empty() && (!sym.tags.is_empty() || !sym.visuals.is_empty()) {
        let fmt_label = match container_format {
            "Matroska" | "WebM" => "Matroska",
            "CAF" => "CAF",
            "WAV" | "RF64" | "W64" | "RIFX" => "RiffInfo",
            "AIFF" => "AiffText",
            "Ogg" | "FLAC" => "VorbisComments",
            "MP4" => "iTunes",
            _ => container_format,
        };
        if !fmt_label.is_empty() {
            out.tag_formats.push(fmt_label.to_string());
        }
    }

    if out.pictures.is_empty() && !sym.visuals.is_empty() {
        out.pictures = sym.visuals.clone();
    }

    if out.chapters.is_empty() && !sym.chapters.is_empty() {
        out.chapters = sym.chapters.clone();
    }

    for tag in &sym.tags {
        let raw_val_str = tag.raw.value.to_string();
        let val = raw_val_str.trim();
        if val.is_empty() && tag.std.is_none() {
            continue;
        }
        match &tag.std {
            Some(ST::TrackTitle(s)) => {
                if out.title.is_none() && !s.trim().is_empty() {
                    out.title = Some(s.trim().to_string());
                }
            }
            Some(ST::ChapterTitle(s)) => {
                if matches!(container_format, "Matroska" | "WebM")
                    && out.title.is_none()
                    && !s.trim().is_empty()
                {
                    out.title = Some(s.trim().to_string());
                }
            }
            Some(ST::Artist(s)) => {
                if out.track_artist.is_none() && !s.trim().is_empty() {
                    out.track_artist = Some(s.trim().to_string());
                }
            }
            Some(ST::Album(s)) => {
                if out.album.is_none() && !s.trim().is_empty() {
                    out.album = Some(s.trim().to_string());
                }
            }
            Some(ST::AlbumArtist(s)) => {
                if out.album_artist.is_none() && !s.trim().is_empty() {
                    out.album_artist = Some(s.trim().to_string());
                }
            }
            Some(ST::RecordingDate(s)) => {
                let st = s.trim();
                if !st.is_empty() {
                    if out.year.is_none() {
                        out.year = st.get(0..4).and_then(|y| y.parse::<u32>().ok());
                    }
                    if out.extended.recording_date.is_none() {
                        out.extended.recording_date = Some(st.to_string());
                    }
                }
            }
            Some(ST::RecordingYear(y)) => {
                if out.year.is_none() {
                    out.year = Some(*y as u32);
                }
                if out.extended.recording_date.is_none() {
                    out.extended.recording_date = Some(y.to_string());
                }
            }
            Some(ST::ReleaseDate(s)) => {
                let st = s.trim();
                if !st.is_empty() {
                    if out.year.is_none() {
                        out.year = st.get(0..4).and_then(|y| y.parse::<u32>().ok());
                    }
                    // MP4 `©day` represents recording date in iTunes tags (already stored by `lofty`);
                    // avoid duplicating `©day` into `release_date` when `recording_date` is set.
                    let is_itunes_day = tag.raw.key.trim() == "\u{a9}day";
                    if out.extended.release_date.is_none()
                        && !(is_itunes_day && out.extended.recording_date.is_some())
                    {
                        out.extended.release_date = Some(st.to_string());
                    }
                }
            }
            Some(ST::ReleaseYear(y)) => {
                if out.year.is_none() {
                    out.year = Some(*y as u32);
                }
                if out.extended.release_date.is_none() {
                    out.extended.release_date = Some(y.to_string());
                }
            }
            Some(ST::OriginalReleaseDate(s)) => {
                let st = s.trim();
                if !st.is_empty() && out.extended.original_release_date.is_none() {
                    out.extended.original_release_date = Some(st.to_string());
                }
            }
            Some(ST::OriginalReleaseYear(y)) => {
                if out.extended.original_release_date.is_none() {
                    out.extended.original_release_date = Some(y.to_string());
                }
            }
            Some(ST::Genre(s)) => {
                if out.genre.is_none() && !s.trim().is_empty() {
                    out.genre = Some(s.trim().to_string());
                }
            }
            Some(ST::TrackNumber(n)) => {
                if out.track_number.is_none() {
                    out.track_number = Some(*n as u32);
                }
            }
            Some(ST::TrackTotal(n)) => {
                if out.track_total.is_none() {
                    out.track_total = Some(*n as u32);
                }
            }
            Some(ST::DiscNumber(n)) => {
                if out.disc_number.is_none() {
                    out.disc_number = Some(*n as u32);
                }
            }
            Some(ST::DiscTotal(n)) => {
                if out.disc_total.is_none() {
                    out.disc_total = Some(*n as u32);
                }
            }
            Some(ST::Lyrics(s)) => {
                if out.lyrics.is_none() && !s.trim().is_empty() {
                    out.lyrics = Some(s.trim().to_string());
                }
            }
            Some(ST::Comment(s)) | Some(ST::Description(s)) => {
                if out.comment.is_none() && !s.trim().is_empty() {
                    out.comment = Some(s.trim().to_string());
                }
            }
            Some(ST::Bpm(n)) => {
                if out.bpm.is_none() {
                    out.bpm = Some(*n as f32);
                }
            }
            Some(ST::ReplayGainTrackGain(s)) => {
                if out.replay_gain_track_gain.is_none() && !s.trim().is_empty() {
                    out.replay_gain_track_gain = Some(s.trim().to_string());
                }
            }
            Some(ST::ReplayGainTrackPeak(s)) => {
                if out.replay_gain_track_peak.is_none() && !s.trim().is_empty() {
                    out.replay_gain_track_peak = Some(s.trim().to_string());
                }
            }
            Some(ST::ReplayGainAlbumGain(s)) => {
                if out.replay_gain_album_gain.is_none() && !s.trim().is_empty() {
                    out.replay_gain_album_gain = Some(s.trim().to_string());
                }
            }
            Some(ST::ReplayGainAlbumPeak(s)) => {
                if out.replay_gain_album_peak.is_none() && !s.trim().is_empty() {
                    out.replay_gain_album_peak = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzRecordingId(s)) => {
                if out.extended.music_brainz_recording_id.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_recording_id = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzTrackId(s)) => {
                let st = s.trim();
                if !st.is_empty() {
                    let base = strip_symphonia_key(&tag.raw.key).trim();
                    if base.eq_ignore_ascii_case("MusicBrainz Track Id")
                        || base.eq_ignore_ascii_case("MUSICBRAINZ_TRACKID")
                    {
                        if out.extended.music_brainz_recording_id.is_none() {
                            out.extended.music_brainz_recording_id = Some(st.to_string());
                        }
                    } else if out.extended.music_brainz_track_id.is_none() {
                        out.extended.music_brainz_track_id = Some(st.to_string());
                    }
                }
            }
            Some(ST::MusicBrainzAlbumId(s)) => {
                if out.extended.music_brainz_release_id.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_release_id = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzReleaseGroupId(s)) => {
                if out.extended.music_brainz_release_group_id.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_release_group_id = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzArtistId(s)) => {
                if out.extended.music_brainz_artist_id.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_artist_id = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzAlbumArtistId(s)) => {
                if out.extended.music_brainz_release_artist_id.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_release_artist_id = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzWorkId(s)) => {
                if out.extended.music_brainz_work_id.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_work_id = Some(s.trim().to_string());
                }
            }
            Some(ST::MusicBrainzReleaseType(s)) => {
                if out.extended.music_brainz_release_type.is_none() && !s.trim().is_empty() {
                    out.extended.music_brainz_release_type = Some(s.trim().to_string());
                }
            }
            Some(ST::AcoustIdId(s)) => {
                if out.extended.acoust_id.is_none() && !s.trim().is_empty() {
                    out.extended.acoust_id = Some(s.trim().to_string());
                }
            }
            Some(ST::AcoustIdFingerprint(s)) => {
                if out.extended.acoust_id_fingerprint.is_none() && !s.trim().is_empty() {
                    out.extended.acoust_id_fingerprint = Some(s.trim().to_string());
                }
            }
            Some(ST::IdentIsrc(s)) => {
                if out.extended.isrc.is_none() && !s.trim().is_empty() {
                    out.extended.isrc = Some(s.trim().to_string());
                }
            }
            Some(ST::IdentBarcode(s)) | Some(ST::IdentUpc(s)) => {
                if out.extended.barcode.is_none() && !s.trim().is_empty() {
                    out.extended.barcode = Some(s.trim().to_string());
                }
            }
            Some(ST::IdentCatalogNumber(s)) => {
                if out.extended.catalog_number.is_none() && !s.trim().is_empty() {
                    out.extended.catalog_number = Some(s.trim().to_string());
                }
            }
            Some(ST::Arranger(s)) => {
                if out.extended.arranger.is_none() && !s.trim().is_empty() {
                    out.extended.arranger = Some(s.trim().to_string());
                }
            }
            Some(ST::Conductor(s)) => {
                if out.extended.conductor.is_none() && !s.trim().is_empty() {
                    out.extended.conductor = Some(s.trim().to_string());
                }
            }
            Some(ST::Director(s)) => {
                if out.extended.director.is_none() && !s.trim().is_empty() {
                    out.extended.director = Some(s.trim().to_string());
                }
            }
            Some(ST::Engineer(s)) => {
                if out.extended.engineer.is_none() && !s.trim().is_empty() {
                    out.extended.engineer = Some(s.trim().to_string());
                }
            }
            Some(ST::Lyricist(s)) => {
                if out.extended.lyricist.is_none() && !s.trim().is_empty() {
                    out.extended.lyricist = Some(s.trim().to_string());
                }
            }
            Some(ST::MixDj(s)) => {
                if out.extended.mix_dj.is_none() && !s.trim().is_empty() {
                    out.extended.mix_dj = Some(s.trim().to_string());
                }
            }
            Some(ST::MixEngineer(s)) => {
                if out.extended.mix_engineer.is_none() && !s.trim().is_empty() {
                    out.extended.mix_engineer = Some(s.trim().to_string());
                }
            }
            Some(ST::Performer(s)) => {
                if out.extended.performer.is_none() && !s.trim().is_empty() {
                    out.extended.performer = Some(s.trim().to_string());
                }
            }
            Some(ST::Producer(s)) => {
                if out.extended.producer.is_none() && !s.trim().is_empty() {
                    out.extended.producer = Some(s.trim().to_string());
                }
            }
            Some(ST::Label(s)) => {
                let st = s.trim();
                if !st.is_empty() {
                    let base = strip_symphonia_key(&tag.raw.key).trim();
                    if base.eq_ignore_ascii_case("PUBLISHER") {
                        if out.extended.publisher.is_none() {
                            out.extended.publisher = Some(st.to_string());
                        }
                    } else if out.extended.label.is_none() {
                        out.extended.label = Some(st.to_string());
                    }
                }
            }
            Some(ST::Remixer(s)) => {
                if out.extended.remixer.is_none() && !s.trim().is_empty() {
                    out.extended.remixer = Some(s.trim().to_string());
                }
            }
            Some(ST::Writer(s)) => {
                let st = s.trim();
                if !st.is_empty() {
                    // MP4 `©wrt` is Composer in iTunes/Mutagen tags (already stored by `lofty`);
                    // avoid duplicating `©wrt` into `writer` when `composer` is set.
                    let is_itunes_wrt = tag.raw.key.trim() == "\u{a9}wrt";
                    if out.extended.writer.is_none()
                        && !(is_itunes_wrt && out.extended.composer.is_some())
                    {
                        out.extended.writer = Some(st.to_string());
                    }
                }
            }
            Some(ST::Composer(s)) => {
                if out.extended.composer.is_none() && !s.trim().is_empty() {
                    out.extended.composer = Some(s.trim().to_string());
                }
            }
            Some(ST::OriginalLyricist(s)) => {
                if out.extended.original_lyricist.is_none() && !s.trim().is_empty() {
                    out.extended.original_lyricist = Some(s.trim().to_string());
                }
            }
            Some(ST::InitialKey(s)) => {
                if out.extended.initial_key.is_none() && !s.trim().is_empty() {
                    out.extended.initial_key = Some(s.trim().to_string());
                }
            }
            Some(ST::Mood(s)) => {
                if out.extended.mood.is_none() && !s.trim().is_empty() {
                    out.extended.mood = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlOfficial(s)) | Some(ST::UrlArtist(s)) => {
                if out.extended.track_artist_url.is_none() && !s.trim().is_empty() {
                    out.extended.track_artist_url = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlCopyright(s)) => {
                if out.extended.copyright_url.is_none() && !s.trim().is_empty() {
                    out.extended.copyright_url = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlInternetRadio(s)) => {
                if out.extended.radio_station_url.is_none() && !s.trim().is_empty() {
                    out.extended.radio_station_url = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlPayment(s)) => {
                if out.extended.payment_url.is_none() && !s.trim().is_empty() {
                    out.extended.payment_url = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlPodcast(s)) => {
                if out.extended.podcast_url.is_none() && !s.trim().is_empty() {
                    out.extended.podcast_url = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlPurchase(s)) => {
                if out.extended.commercial_information_url.is_none() && !s.trim().is_empty() {
                    out.extended.commercial_information_url = Some(s.trim().to_string());
                }
            }
            Some(ST::UrlSource(s)) => {
                if out.extended.audio_source_url.is_none() && !s.trim().is_empty() {
                    out.extended.audio_source_url = Some(s.trim().to_string());
                }
            }
            Some(ST::Copyright(s)) => {
                if out.extended.copyright_message.is_none() && !s.trim().is_empty() {
                    out.extended.copyright_message = Some(s.trim().to_string());
                }
            }
            Some(ST::License(s)) => {
                if out.extended.license.is_none() && !s.trim().is_empty() {
                    out.extended.license = Some(s.trim().to_string());
                }
            }
            Some(ST::PodcastDescription(s)) => {
                if out.extended.podcast_description.is_none() && !s.trim().is_empty() {
                    out.extended.podcast_description = Some(s.trim().to_string());
                }
            }
            Some(ST::PodcastCategory(s)) => {
                if out.extended.podcast_series_category.is_none() && !s.trim().is_empty() {
                    out.extended.podcast_series_category = Some(s.trim().to_string());
                }
            }
            Some(ST::IdentPodcast(s)) => {
                if out.extended.podcast_global_unique_id.is_none() && !s.trim().is_empty() {
                    out.extended.podcast_global_unique_id = Some(s.trim().to_string());
                }
            }
            Some(ST::PodcastKeywords(s)) => {
                if out.extended.podcast_keywords.is_none() && !s.trim().is_empty() {
                    out.extended.podcast_keywords = Some(s.trim().to_string());
                }
            }
            Some(ST::DiscSubtitle(s)) => {
                if out.extended.set_subtitle.is_none() && !s.trim().is_empty() {
                    out.extended.set_subtitle = Some(s.trim().to_string());
                }
            }
            Some(ST::TvSeriesTitle(s)) => {
                if out.extended.show_name.is_none() && !s.trim().is_empty() {
                    out.extended.show_name = Some(s.trim().to_string());
                }
            }
            Some(ST::Grouping(s)) => {
                if out.extended.content_group.is_none() && !s.trim().is_empty() {
                    out.extended.content_group = Some(s.trim().to_string());
                }
            }
            Some(ST::TrackSubtitle(s)) => {
                if out.extended.track_subtitle.is_none() && !s.trim().is_empty() {
                    out.extended.track_subtitle = Some(s.trim().to_string());
                }
            }
            Some(ST::Language(s)) => {
                if out.extended.language.is_none() && !s.trim().is_empty() {
                    out.extended.language = Some(s.trim().to_string());
                }
            }
            Some(ST::Script(s)) => {
                if out.extended.script.is_none() && !s.trim().is_empty() {
                    out.extended.script = Some(s.trim().to_string());
                }
            }
            Some(ST::Owner(s)) => {
                if out.extended.file_owner.is_none() && !s.trim().is_empty() {
                    out.extended.file_owner = Some(s.trim().to_string());
                }
            }
            Some(ST::OriginalFile(s)) => {
                if out.extended.original_file_name.is_none() && !s.trim().is_empty() {
                    out.extended.original_file_name = Some(s.trim().to_string());
                }
            }
            Some(ST::MediaFormat(s)) => {
                if out.extended.original_media_type.is_none() && !s.trim().is_empty() {
                    out.extended.original_media_type = Some(s.trim().to_string());
                }
            }
            Some(ST::EncodedBy(s)) => {
                if out.extended.encoded_by.is_none() && !s.trim().is_empty() {
                    out.extended.encoded_by = Some(s.trim().to_string());
                }
            }
            Some(ST::Encoder(s)) => {
                if out.extended.encoder_software.is_none() && !s.trim().is_empty() {
                    out.extended.encoder_software = Some(s.trim().to_string());
                }
            }
            Some(ST::EncoderSettings(s)) => {
                if out.extended.encoder_settings.is_none() && !s.trim().is_empty() {
                    out.extended.encoder_settings = Some(s.trim().to_string());
                }
            }
            _ => {
                let raw_k = tag.raw.key.trim();
                let base_k = strip_symphonia_key(raw_k).trim();
                if base_k.is_empty() || val.is_empty() {
                    continue;
                }
                let base_upper = base_k.to_ascii_uppercase();
                // Ignore container muxer / bookkeeping / stream-statistics keys
                if matches!(
                    base_upper.as_str(),
                    "DURATION"
                        | "HANDLER_NAME"
                        | "VENDOR_ID"
                        | "TXXX"
                        | "BPS"
                        | "NUMBER_OF_FRAMES"
                        | "NUMBER_OF_BYTES"
                        | "SOURCE_ID"
                        | "MAJOR_BRAND"
                        | "MINOR_VERSION"
                        | "COMPATIBLE_BRANDS"
                        | "CREATION_TIME"
                ) || base_upper.starts_with("_STATISTICS_")
                    || base_upper.starts_with("BPS-")
                    || base_upper.starts_with("DURATION-")
                    || base_upper.starts_with("NUMBER_OF_")
                {
                    continue;
                }

                match base_upper.as_str() {
                    "TITLE" => {
                        if out.title.is_none() {
                            out.title = Some(val.to_string());
                        }
                    }
                    "ALBUM" => {
                        if out.album.is_none() {
                            out.album = Some(val.to_string());
                        }
                    }
                    "ARTIST" => {
                        if out.track_artist.is_none() {
                            out.track_artist = Some(val.to_string());
                        }
                    }
                    "ALBUM_ARTIST" | "ALBUMARTIST" => {
                        if out.album_artist.is_none() {
                            out.album_artist = Some(val.to_string());
                        }
                    }
                    "PART_NUMBER" | "TRACK" | "TRACKNUMBER" => {
                        if out.track_number.is_none() {
                            out.track_number = parse_leading_u32(val);
                        }
                        if out.track_total.is_none() {
                            out.track_total = parse_slash_total_u32(val);
                        }
                    }
                    "TOTAL_PARTS" | "TRACKTOTAL" => {
                        if out.track_total.is_none() {
                            out.track_total = parse_leading_u32(val);
                        }
                    }
                    "DISC" | "DISCNUMBER" => {
                        if out.disc_number.is_none() {
                            out.disc_number = parse_leading_u32(val);
                        }
                        if out.disc_total.is_none() {
                            out.disc_total = parse_slash_total_u32(val);
                        }
                    }
                    "DISCTOTAL" => {
                        if out.disc_total.is_none() {
                            out.disc_total = parse_leading_u32(val);
                        }
                    }
                    "GENRE" => {
                        if out.genre.is_none() {
                            out.genre = Some(val.to_string());
                        }
                    }
                    "COMPOSER" => {
                        if out.extended.composer.is_none() {
                            out.extended.composer = Some(val.to_string());
                        }
                    }
                    "COPYRIGHT" => {
                        if out.extended.copyright_message.is_none() {
                            out.extended.copyright_message = Some(val.to_string());
                        }
                    }
                    "ISRC" => {
                        if out.extended.isrc.is_none() {
                            out.extended.isrc = Some(val.to_string());
                        }
                    }
                    "MOOD" => {
                        if out.extended.mood.is_none() {
                            out.extended.mood = Some(val.to_string());
                        }
                    }
                    "REPLAYGAIN_TRACK_GAIN" => {
                        if out.replay_gain_track_gain.is_none() {
                            out.replay_gain_track_gain = Some(val.to_string());
                        }
                    }
                    "REPLAYGAIN_TRACK_PEAK" => {
                        if out.replay_gain_track_peak.is_none() {
                            out.replay_gain_track_peak = Some(val.to_string());
                        }
                    }
                    "REPLAYGAIN_ALBUM_GAIN" => {
                        if out.replay_gain_album_gain.is_none() {
                            out.replay_gain_album_gain = Some(val.to_string());
                        }
                    }
                    "REPLAYGAIN_ALBUM_PEAK" => {
                        if out.replay_gain_album_peak.is_none() {
                            out.replay_gain_album_peak = Some(val.to_string());
                        }
                    }
                    "MUSICBRAINZ_TRACKID" => {
                        if out.extended.music_brainz_recording_id.is_none() {
                            out.extended.music_brainz_recording_id = Some(val.to_string());
                        }
                    }
                    "PUBLISHER" => {
                        if out.extended.publisher.is_none() {
                            out.extended.publisher = Some(val.to_string());
                        }
                    }
                    "LABEL" => {
                        if out.extended.label.is_none() {
                            out.extended.label = Some(val.to_string());
                        }
                    }
                    "BPM" => {
                        if out.bpm.is_none() {
                            out.bpm = val.parse::<f32>().ok();
                        }
                    }
                    "DATE_RECORDED" | "DATE" => {
                        if out.year.is_none() {
                            out.year = val.get(0..4).and_then(|y| y.parse::<u32>().ok());
                        }
                        if out.extended.recording_date.is_none() {
                            out.extended.recording_date = Some(val.to_string());
                        }
                    }
                    "INITIAL_KEY" | "INITIALKEY" => {
                        if out.extended.initial_key.is_none() {
                            out.extended.initial_key = Some(val.to_string());
                        }
                    }
                    "RTNG" => {
                        if out.extended.parental_advisory.is_none() {
                            out.extended.parental_advisory = Some(val.to_string());
                        }
                    }
                    "IENG" => {
                        if out.extended.engineer.is_none() {
                            out.extended.engineer = Some(val.to_string());
                        }
                    }
                    "TDRL" => {
                        if out.extended.release_date.is_none() {
                            out.extended.release_date = Some(val.to_string());
                        }
                    }
                    "WPUB" => {
                        if out.extended.publisher_url.is_none() {
                            out.extended.publisher_url = Some(val.to_string());
                        }
                    }
                    "ENCODER" => {
                        if out.extended.encoder_software.is_none() {
                            out.extended.encoder_software = Some(val.to_string());
                        }
                    }
                    "COMMENT" | "DESCRIPTION" => {
                        if out.comment.is_none() {
                            out.comment = Some(val.to_string());
                        }
                    }
                    "LYRICS" => {
                        if out.lyrics.is_none() {
                            out.lyrics = Some(val.to_string());
                        }
                    }
                    _ => {
                        if !consumed_custom_keys.contains(&base_upper)
                            && !consumed_custom_keys.contains(&raw_k.to_ascii_uppercase())
                            && !out
                                .custom_tags
                                .iter()
                                .any(|f| f.key.eq_ignore_ascii_case(base_k))
                        {
                            out.custom_tags.push(RustCustomTagField {
                                key: base_k.to_string(),
                                value: val.to_string(),
                            });
                        }
                    }
                }
            }
        }
    }
}

// =========================================================================
// Enum & Type Mappers
// =========================================================================

fn map_lofty_tag_type(t: TagType) -> &'static str {
    match t {
        TagType::Id3v1 => "ID3v1",
        TagType::Id3v2 => "ID3v2",
        TagType::Ape => "APE",
        TagType::Mp4Ilst => "iTunes",
        TagType::VorbisComments => "VorbisComments",
        TagType::RiffInfo => "RiffInfo",
        TagType::AiffText => "AiffText",
        _ => "Unknown",
    }
}

fn map_lofty_picture_type(pt: LoftyPictureType) -> RustPictureType {
    match pt {
        LoftyPictureType::Other => RustPictureType::Other,
        LoftyPictureType::Icon => RustPictureType::Icon,
        LoftyPictureType::OtherIcon => RustPictureType::OtherIcon,
        LoftyPictureType::CoverFront => RustPictureType::CoverFront,
        LoftyPictureType::CoverBack => RustPictureType::CoverBack,
        LoftyPictureType::Leaflet => RustPictureType::Leaflet,
        LoftyPictureType::Media => RustPictureType::Media,
        LoftyPictureType::LeadArtist => RustPictureType::LeadArtist,
        LoftyPictureType::Artist => RustPictureType::Artist,
        LoftyPictureType::Conductor => RustPictureType::Conductor,
        LoftyPictureType::Band => RustPictureType::Band,
        LoftyPictureType::Composer => RustPictureType::Composer,
        LoftyPictureType::Lyricist => RustPictureType::Lyricist,
        LoftyPictureType::RecordingLocation => RustPictureType::RecordingLocation,
        LoftyPictureType::DuringRecording => RustPictureType::DuringRecording,
        LoftyPictureType::DuringPerformance => RustPictureType::DuringPerformance,
        LoftyPictureType::ScreenCapture => RustPictureType::ScreenCapture,
        LoftyPictureType::BrightFish => RustPictureType::BrightFish,
        LoftyPictureType::Illustration => RustPictureType::Illustration,
        LoftyPictureType::BandLogo => RustPictureType::BandLogo,
        LoftyPictureType::PublisherLogo => RustPictureType::PublisherLogo,
        _ => RustPictureType::Other,
    }
}

fn map_symphonia_visual_key(
    vk: Option<symphonia::core::meta::StandardVisualKey>,
) -> RustPictureType {
    use symphonia::core::meta::StandardVisualKey as SVK;
    match vk {
        Some(SVK::FileIcon) => RustPictureType::Icon,
        Some(SVK::OtherIcon) => RustPictureType::OtherIcon,
        Some(SVK::FrontCover) => RustPictureType::CoverFront,
        Some(SVK::BackCover) => RustPictureType::CoverBack,
        Some(SVK::Leaflet) => RustPictureType::Leaflet,
        Some(SVK::Media) => RustPictureType::Media,
        Some(SVK::LeadArtistPerformerSoloist) => RustPictureType::LeadArtist,
        Some(SVK::ArtistPerformer) => RustPictureType::Artist,
        Some(SVK::Conductor) => RustPictureType::Conductor,
        Some(SVK::BandOrchestra) => RustPictureType::Band,
        Some(SVK::Composer) => RustPictureType::Composer,
        Some(SVK::Lyricist) => RustPictureType::Lyricist,
        Some(SVK::RecordingLocation) => RustPictureType::RecordingLocation,
        Some(SVK::RecordingSession) => RustPictureType::DuringRecording,
        Some(SVK::Performance) => RustPictureType::DuringPerformance,
        Some(SVK::ScreenCapture) => RustPictureType::ScreenCapture,
        Some(SVK::Illustration) => RustPictureType::Illustration,
        Some(SVK::BandArtistLogo) => RustPictureType::BandLogo,
        Some(SVK::PublisherStudioLogo) => RustPictureType::PublisherLogo,
        Some(_) => RustPictureType::Other,
        None => RustPictureType::CoverFront,
    }
}

fn map_lofty_mime_type(m: &LoftyMimeType) -> RustMimeType {
    match m {
        LoftyMimeType::Png => RustMimeType::Png,
        LoftyMimeType::Jpeg => RustMimeType::Jpeg,
        LoftyMimeType::Tiff => RustMimeType::Tiff,
        LoftyMimeType::Bmp => RustMimeType::Bmp,
        LoftyMimeType::Gif => RustMimeType::Gif,
        LoftyMimeType::Unknown(s) => parse_mime_str(s).unwrap_or(RustMimeType::Unknown),
        _ => RustMimeType::Unknown,
    }
}

fn parse_mime_str(s: &str) -> Option<RustMimeType> {
    let lower = s.trim().to_ascii_lowercase();
    if lower.contains("png") {
        Some(RustMimeType::Png)
    } else if lower.contains("jpeg") || lower.contains("jpg") {
        Some(RustMimeType::Jpeg)
    } else if lower.contains("webp") {
        Some(RustMimeType::Webp)
    } else if lower.contains("gif") {
        Some(RustMimeType::Gif)
    } else if lower.contains("bmp") {
        Some(RustMimeType::Bmp)
    } else if lower.contains("tiff") || lower.contains("tif") {
        Some(RustMimeType::Tiff)
    } else {
        None
    }
}

/// Infers image MIME type from magic header bytes when the container omits or mislabels it.
pub fn sniff_image_mime(bytes: &[u8]) -> Option<RustMimeType> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some(RustMimeType::Png)
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(RustMimeType::Jpeg)
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(RustMimeType::Webp)
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(RustMimeType::Gif)
    } else if bytes.starts_with(b"BM") {
        Some(RustMimeType::Bmp)
    } else if bytes.starts_with(&[0x49, 0x49, 0x2A, 0x00])
        || bytes.starts_with(&[0x4D, 0x4D, 0x00, 0x2A])
    {
        Some(RustMimeType::Tiff)
    } else {
        None
    }
}

/// Parses raw ICY metadata block (`StreamTitle='...';StreamUrl='...';`) into `(title, url)`.
pub fn parse_icy_stream_block(raw_icy: &[u8]) -> (Option<String>, Option<String>) {
    let text = String::from_utf8_lossy(raw_icy);
    let trimmed = text.trim_end_matches('\0').trim();
    if trimmed.is_empty() {
        return (None, None);
    }

    let extract_kv = |key: &str| -> Option<String> {
        let idx = trimmed.find(key)?;
        let rest = &trimmed[idx + key.len()..];
        let end = rest
            .find("';")
            .or_else(|| rest.find('\''))
            .unwrap_or(rest.len());
        let v = rest[..end].trim();
        if v.is_empty() {
            None
        } else {
            Some(v.to_string())
        }
    };

    let title = extract_kv("StreamTitle='")
        .or_else(|| {
            if !trimmed.contains('=') {
                Some(trimmed.to_string())
            } else {
                None
            }
        })
        .filter(|t| !crate::hls::is_live_ad_marker(t));
    let url = extract_kv("StreamUrl='");
    (title, url)
}

/// Extracts `(title, track_artist, album)` from an embedded ID3v2 byte container (filtering ad markers).
pub fn extract_basic_id3v2_tags(raw_id3: &[u8]) -> (Option<String>, Option<String>, Option<String>) {
    if raw_id3.len() < 10 || !raw_id3.starts_with(b"ID3") {
        return (None, None, None);
    }
    let mut meta = RustAudioMetadata::default();
    let mut consumed = HashSet::new();
    parse_raw_id3v2_slice(raw_id3, &mut meta, &mut consumed);

    let clean = |opt: Option<String>| -> Option<String> {
        opt.and_then(|s| {
            let t = s.trim_matches('\0').trim();
            if crate::hls::is_live_ad_marker(t) {
                None
            } else {
                Some(t.to_string())
            }
        })
    };

    (clean(meta.title), clean(meta.track_artist), clean(meta.album))
}
