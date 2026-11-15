//! HTTP Live Streaming (HLS) protocol support.
//!
//! Includes M3U8 manifest parsing (master playlists and media playlists)
//! and MPEG-TS container demuxing.

pub mod m3u8_parser;
pub mod mpegts;

pub use m3u8_parser::{
    EncryptionKeyInfo, M3u8Parser, ParsedHlsPlaylist, SegmentInfo, VariantStreamInfo,
};
pub use mpegts::{MpegTsDemuxResult, MpegTsDemuxer, TsAudioCodec};


