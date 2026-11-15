//! HTTP Live Streaming (HLS) protocol support.
//!
//! Includes M3U8 manifest parsing (master playlists and media playlists)
//! and MPEG-TS container demuxing.

pub mod m3u8_parser;
pub mod mpegts;

pub use m3u8_parser::{
    resolve_hls_uri, slice_byte_range, EncryptionKeyInfo, HlsPlaylistTracker, HlsSegmentTarget,
    M3u8Parser, ParsedHlsPlaylist, SegmentInfo, VariantStreamInfo,
};
pub use mpegts::{MpegTsDemuxResult, MpegTsDemuxer, TsAudioCodec};


