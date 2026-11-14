//! Central thread-safe player coordinator integrating decoding, DSP, buffering, and device output.

#[cfg(not(target_arch = "wasm32"))]
use std::fs::File;
use std::io::{Cursor, ErrorKind, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use crate::sync::thread::{self, JoinHandle};
use std::time::Duration;

use crate::bridge::ffi::*;
use crate::buffer::{CustomByteSourceHandle, CustomDartByteSource, StreamBuffer, StreamSession};
use crate::core::renderer::{AudioRenderer, DspCommand};
use crate::decoder::{BoundaryInfo, BoundaryStatus, StreamClassifier, SymphoniaEngine};
use crate::dsp::channel_matrix::ChannelMatrix;
use crate::dsp::crossfeed::CrossfeedConfig;
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::resampler::RubatoResampler;
use crate::core::types::{PlaybackState, QueueTransition};
use crate::dsp::chain::DspChain;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::{SilenceConfig, SilenceDetector};
use crate::dsp::sonic::SonicStream;
use crate::dsp::visualizer::VisualizerData;
use crate::sync::ring_buffer::{AudioProducer, AudioRingBuffer};
use crate::sync::seqlock::CachePaddedSeqlock;
use crate::sync::telemetry::{
    EventType, MapEventData, MonotonicInstant, SpatializerData, TelemetryDispatcher,
};
use crate::sync::{
    lock_unpoisoned, read_unpoisoned, wait_timeout_unpoisoned, write_unpoisoned, CancelToken,
};

/// Returned by cancellable track opens when superseded or cancelled before completion.
pub const MAP_ERROR_ABORTED: i32 = -99;

/// Deck playback state: playback is stopped and position is reset.
pub const STATE_STOPPED: i32 = PlaybackState::Stopped.as_i32();
/// Deck playback state: audio is actively rendering.
pub const STATE_PLAYING: i32 = PlaybackState::Playing.as_i32();
/// Deck playback state: playback is paused.
pub const STATE_PAUSED: i32 = PlaybackState::Paused.as_i32();

/// Stream seek cache miss: required target range must be downloaded.
pub const MAP_STREAM_SEEK_CACHE_MISS: i32 = 0;
/// Stream seek cache hit: target range is immediately available in memory buffer.
pub const MAP_STREAM_SEEK_CACHE_HIT: i32 = 1;
/// Stream seek cache hit within prefetch window.
pub const MAP_STREAM_SEEK_CACHE_HIT_PREFETCH: i32 = 2;

/// Telemetry metrics snapshot for a tripartite streaming buffer.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct MiniaudioStreamStatus {
    /// Total buffer capacity in bytes.
    pub buffer_capacity: usize,
    /// Currently populated bytes in buffer.
    pub buffer_fill: usize,
    /// Buffer fill percentage (0.0 to 1.0).
    pub fill_percentage: f32,
    /// Non-zero if player is paused waiting for buffer refill.
    pub is_buffering: i32,
    /// Non-zero if end-of-file has been reached by the stream loader.
    pub is_eof: i32,
    /// Current consumer read cursor in stream bytes.
    pub read_cursor_byte: i64,
    /// Start byte offset of the currently available contiguous buffer window.
    pub range_start: i64,
    /// End byte offset of the currently available contiguous buffer window.
    pub range_end: i64,
}

/// Comprehensive synchronous telemetry status snapshot of a deck.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct MiniaudioPlayerStatus {
    /// Current elapsed playback position in milliseconds.
    pub position_ms: i64,
    /// Total track duration in milliseconds, or -1 if unknown.
    pub duration_ms: i64,
    /// Playback state integer code (`STATE_*`).
    pub state: i32,
    /// Non-zero if audio is actively playing.
    pub is_playing: i32,
    /// Non-zero if deck is stalled buffering.
    pub is_buffering: i32,
    /// Master volume level.
    pub volume: f32,
    /// Playback rate speed multiplier.
    pub rate: f32,
    /// Pitch shift multiplier.
    pub pitch: f32,
    /// Nominal bitrate in bps.
    pub bitrate: u32,
    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Audio channel count.
    pub channels: u32,
    /// Equalizer frequency band gains.
    pub equalizer: EqualizerParams,
    /// Active audio output device descriptor.
    pub device: MapDeviceInfo,
    /// Silence trimming configuration.
    pub silence: SilenceConfig,
    /// Cumulative silence skipped in milliseconds.
    pub silence_saved_ms: i64,
    /// Non-zero if FFT visualizer is enabled.
    pub visualizer_enabled: i32,
    /// Instantaneous FFT spectrum and amplitude metrics.
    pub visualizer: VisualizerData,
    /// Equalizer preamp gain in dB.
    pub preamp_db: f32,
    /// Active ReplayGain loudness normalization settings.
    pub replay_gain: ReplayGainConfig,
    /// Stereo balance pan (-1.0 to +1.0).
    pub balance: f32,
    /// Non-zero if stereo downmix to mono is active.
    pub mono_enabled: i32,
    /// Bauer binaural crossfeed settings.
    pub crossfeed: CrossfeedConfig,
    /// Non-zero if 3D stereo widening spatializer is enabled.
    pub spatializer_enabled: i32,
    /// 3D stereo widening factor.
    pub spatializer_width: f32,
    /// Algorithmic studio reverberation settings.
    pub reverb: ReverbConfig,
    /// Non-zero if output brickwall limiter is active.
    pub limiter_enabled: i32,
}


/// Strips `file://` or `file://localhost/` URI schemes from filesystem paths.
pub fn strip_file_prefix(source: &str) -> String {
    let s = source.trim();
    if let Some(stripped) = s.strip_prefix("file://localhost/") {
        format!("/{}", stripped.trim_start_matches('/'))
    } else if let Some(stripped) = s.strip_prefix("file:///") {
        let bytes = stripped.as_bytes();
        if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
            stripped.to_string()
        } else {
            format!("/{}", stripped.trim_start_matches('/'))
        }
    } else if let Some(stripped) = s.strip_prefix("file://") {
        if let Some(path) = stripped.strip_prefix('/') {
            format!("/{}", path)
        } else {
            format!("/{}", stripped)
        }
    } else {
        s.to_string()
    }
}

/// Normalizes local asset paths, stripping `asset://` prefixes and testing candidate locations.
pub fn resolve_local_source_path(trimmed: &str) -> String {
    let raw_path = if let Some(stripped) = trimmed.strip_prefix("asset://") {
        stripped.strip_prefix('/').unwrap_or(stripped).to_string()
    } else if let Some(stripped) = trimmed.strip_prefix("asset:") {
        stripped.strip_prefix('/').unwrap_or(stripped).to_string()
    } else {
        strip_file_prefix(trimmed)
    };

    if !std::path::Path::new(&raw_path).exists() {
        let candidate = format!("example/{}", raw_path);
        if std::path::Path::new(&candidate).exists() {
            return candidate;
        }
    }
    raw_path
}

fn encoding_format_to_extension(encoding_format: i32) -> Option<&'static str> {
    match encoding_format {
        1 => Some("wav"),
        2 => Some("flac"),
        3 => Some("mp3"),
        4 => Some("ogg"),
        5 => Some("aac"),
        6 => Some("mp4"),
        _ => None,
    }
}

fn infer_network_encoding_format(url: &str, content_type: Option<&str>) -> i32 {
    let lower_url = url.to_lowercase();
    let lower_ct = content_type.unwrap_or("").to_lowercase();

    if lower_url.ends_with(".wav")
        || lower_ct.contains("audio/wav")
        || lower_ct.contains("audio/x-wav")
    {
        1
    } else if lower_url.ends_with(".flac") || lower_ct.contains("audio/flac") {
        2
    } else if lower_url.ends_with(".mp3")
        || lower_ct.contains("audio/mpeg")
        || lower_ct.contains("audio/mp3")
    {
        3
    } else if lower_url.ends_with(".ogg")
        || lower_url.ends_with(".opus")
        || lower_ct.contains("audio/ogg")
        || lower_ct.contains("audio/opus")
    {
        4
    } else if lower_url.ends_with(".aac") || lower_ct.contains("audio/aac") {
        5
    } else if lower_url.ends_with(".m4a")
        || lower_url.ends_with(".mp4")
        || lower_ct.contains("audio/mp4")
    {
        6
    } else {
        0
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn build_network_agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .user_agent("miniaudio_player/3.1 (Flutter Audio Engine; +https://pub.dev)")
        .timeout_connect(Some(Duration::from_secs(5)))
        .timeout_recv_response(Some(Duration::from_secs(15)))
        .timeout_per_read(Some(Duration::from_secs(15)))
        .max_idle_connections(0)
        .build()
        .into()
}

/// Bounded HTTP probe agent used during cancellable initial stream open/header sniff.
#[cfg(not(target_arch = "wasm32"))]
fn build_network_probe_agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .user_agent("miniaudio_player/3.1 (Flutter Audio Engine; +https://pub.dev)")
        .timeout_connect(Some(Duration::from_secs(5)))
        .timeout_recv_response(Some(Duration::from_secs(8)))
        .timeout_per_read(Some(Duration::from_secs(8)))
        .max_idle_connections(0)
        .build()
        .into()
}

#[cfg(not(target_arch = "wasm32"))]
fn apply_http_headers(
    mut req: ureq::RequestBuilder<ureq::typestate::WithoutBody>,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
) -> ureq::RequestBuilder<ureq::typestate::WithoutBody> {
    if let Some(hdrs) = headers {
        for h in hdrs {
            req = req.header(&h.key, &h.value);
        }
    }
    req
}

#[cfg(not(target_arch = "wasm32"))]
fn response_header_str<'a>(
    res: &'a ureq::http::Response<ureq::Body>,
    name: &str,
) -> Option<&'a str> {
    res.headers().get(name).and_then(|v| v.to_str().ok())
}

#[cfg(not(target_arch = "wasm32"))]
fn synthesize_icy_id3_container(raw_icy: &[u8]) -> Option<Vec<u8>> {
    let text = String::from_utf8_lossy(raw_icy);
    let trimmed = text.trim_end_matches('\0').trim();
    if trimmed.is_empty() {
        return None;
    }

    let title = if let Some(idx) = trimmed.find("StreamTitle='") {
        let rest = &trimmed[idx + "StreamTitle='".len()..];
        let end = rest
            .find("';")
            .or_else(|| rest.find('\''))
            .unwrap_or(rest.len());
        rest[..end].trim()
    } else {
        trimmed
    };
    if title.is_empty() {
        return None;
    }

    let title_bytes = title.as_bytes();
    let frame_payload_len = 1 + title_bytes.len();
    let mut id3 = Vec::with_capacity(10 + 10 + frame_payload_len + 128);

    // ID3v2.3 header (10 bytes)
    let tag_size = (10 + frame_payload_len) as u32;
    let synchsafe = [
        ((tag_size >> 21) & 0x7F) as u8,
        ((tag_size >> 14) & 0x7F) as u8,
        ((tag_size >> 7) & 0x7F) as u8,
        (tag_size & 0x7F) as u8,
    ];
    id3.extend_from_slice(b"ID3\x03\x00\x00");
    id3.extend_from_slice(&synchsafe);

    // TIT2 frame (10-byte header + encoding byte + UTF-8/Latin1 text)
    id3.extend_from_slice(b"TIT2");
    id3.extend_from_slice(&(frame_payload_len as u32).to_be_bytes());
    id3.extend_from_slice(&[0x00, 0x00, 0x03]);
    id3.extend_from_slice(title_bytes);

    // 128-byte ID3v1 trailer starting with "TAG"
    let mut trailer = [0u8; 128];
    trailer[0..3].copy_from_slice(b"TAG");
    let copy_len = title_bytes.len().min(30);
    trailer[3..3 + copy_len].copy_from_slice(&title_bytes[..copy_len]);
    id3.extend_from_slice(&trailer);

    Some(id3)
}

#[cfg(not(target_arch = "wasm32"))]
struct IcyDemuxReader {
    inner: Box<dyn Read + Send>,
    metaint: usize,
    bytes_until_meta: usize,
    session_slot: Arc<Mutex<Option<StreamSession>>>,
    latest_icy: Arc<Mutex<Option<Vec<u8>>>>,
    icy_metadata: Arc<RwLock<Option<crate::api::types::RustIcyMetadata>>>,
}

#[cfg(not(target_arch = "wasm32"))]
impl IcyDemuxReader {
    fn new(
        inner: Box<dyn Read + Send>,
        metaint: usize,
        session_slot: Arc<Mutex<Option<StreamSession>>>,
        latest_icy: Arc<Mutex<Option<Vec<u8>>>>,
        icy_metadata: Arc<RwLock<Option<crate::api::types::RustIcyMetadata>>>,
    ) -> Self {
        Self {
            inner,
            metaint,
            bytes_until_meta: metaint,
            session_slot,
            latest_icy,
            icy_metadata,
        }
    }

    fn read_exact_bytes(&mut self, mut buf: &mut [u8]) -> std::io::Result<bool> {
        while !buf.is_empty() {
            match self.inner.read(buf) {
                Ok(0) => return Ok(false),
                Ok(n) => buf = &mut buf[n..],
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(true)
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl Read for IcyDemuxReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.metaint == 0 {
            return self.inner.read(out);
        }
        if self.bytes_until_meta == 0 {
            let mut len_byte = [0u8; 1];
            if !self.read_exact_bytes(&mut len_byte)? {
                return Ok(0);
            }
            let meta_len = (len_byte[0] as usize) * 16;
            if meta_len > 0 {
                let mut meta_buf = vec![0u8; meta_len];
                if !self.read_exact_bytes(&mut meta_buf)? {
                    return Ok(0);
                }
                let (stream_title, stream_url) =
                    crate::metadata::parse_icy_stream_block(&meta_buf);
                if stream_title.is_some() || stream_url.is_some() {
                    if let Ok(mut guard) = self.icy_metadata.write() {
                        let entry = guard.get_or_insert_with(Default::default);
                        if stream_title.is_some() {
                            entry.stream_title = stream_title;
                        }
                        if stream_url.is_some() {
                            entry.stream_url = stream_url;
                        }
                    }
                }
                if let Some(synthesized) = synthesize_icy_id3_container(&meta_buf) {
                    crate::map_log!(3, "ICY Metadata parsed (length={} bytes)", synthesized.len());
                    if let Ok(mut latest) = self.latest_icy.lock() {
                        *latest = Some(synthesized.clone());
                    }
                    if let Ok(guard) = self.session_slot.lock() {
                        if let Some(ref session) = *guard {
                            session.set_icy_meta(&synthesized);
                        }
                    }
                }
            }
            self.bytes_until_meta = self.metaint;
        }

        let max_audio = out.len().min(self.bytes_until_meta);
        let n = self.inner.read(&mut out[..max_audio])?;
        self.bytes_until_meta -= n;
        Ok(n)
    }
}

fn resolve_hls_uri(base_url: &str, seg_uri: &str) -> String {
    let trimmed = seg_uri.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return trimmed.to_string();
    }
    let base_no_query = base_url.split('?').next().unwrap_or(base_url);
    if trimmed.starts_with('/') {
        if let Some(scheme_idx) = base_no_query.find("://") {
            let after_scheme = &base_no_query[scheme_idx + 3..];
            if let Some(slash_idx) = after_scheme.find('/') {
                let origin = &base_no_query[..scheme_idx + 3 + slash_idx];
                return format!("{}{}", origin, trimmed);
            }
        }
        return trimmed.to_string();
    }
    if let Some(last_slash) = base_no_query.rfind('/') {
        format!("{}/{}", &base_no_query[..last_slash], trimmed)
    } else {
        trimmed.to_string()
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn fetch_hls_segment_audio(
    agent: &ureq::Agent,
    seg_url: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
) -> Option<(Vec<u8>, i32)> {
    let req = apply_http_headers(agent.get(seg_url), headers);
    let res = req.call().ok()?;
    let content_type = response_header_str(&res, "content-type").map(|s| s.to_string());
    let mut raw_bytes = Vec::new();
    res.into_body().into_reader().read_to_end(&mut raw_bytes).ok()?;
    if raw_bytes.is_empty() {
        return None;
    }
    if crate::hls::MpegTsDemuxer::is_mpeg_ts(&raw_bytes) {
        let demuxed = crate::hls::MpegTsDemuxer::demux_segment(&raw_bytes);
        let fmt = match demuxed.codec {
            crate::hls::TsAudioCodec::AacAdts => 5,
            crate::hls::TsAudioCodec::Mp3 => 3,
            _ => 0,
        };
        if !demuxed.audio_bytes.is_empty() {
            return Some((demuxed.audio_bytes, fmt));
        }
    }
    let fmt = infer_network_encoding_format(seg_url, content_type.as_deref());
    Some((raw_bytes, fmt))
}

#[cfg(not(target_arch = "wasm32"))]
fn fetch_range_bytes(
    agent: &ureq::Agent,
    url: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
    start: i64,
    end_inclusive: i64,
) -> Option<Vec<u8>> {
    if start < 0 || end_inclusive < start {
        return None;
    }
    let range_hdr = format!("bytes={}-{}", start, end_inclusive);
    let req = apply_http_headers(agent.get(url), headers).header("Range", &range_hdr);
    let res = req.call().ok()?;
    if res.status().as_u16() != 206 {
        return None;
    }
    let expected = (end_inclusive - start + 1) as usize;
    let mut buf = Vec::with_capacity(expected.min(4 * 1024 * 1024));
    res.into_body()
        .into_reader()
        .take(expected as u64)
        .read_to_end(&mut buf)
        .ok()?;
    if buf.len() == expected {
        Some(buf)
    } else {
        None
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn prefetch_initial_stream_bytes_cancellable(
    reader: &mut impl Read,
    content_length: i64,
    cancel: Option<&CancelToken>,
) -> (Vec<u8>, bool) {
    let mut initial_data = Vec::with_capacity(131072);
    let mut read_buf = [0u8; 32768];

    loop {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return (Vec::new(), true);
        }
        match reader.read(&mut read_buf) {
            Ok(0) => break,
            Ok(n) => {
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return (Vec::new(), true);
                }
                initial_data.extend_from_slice(&read_buf[..n]);
                if crate::hls::M3u8Parser::is_m3u8(&initial_data) {
                    break;
                }
                if initial_data.len() >= 65536 {
                    let (status, boundary) =
                        StreamClassifier::detect_head_boundary(&initial_data, content_length);
                    if status != crate::decoder::classifier::BoundaryStatus::NeedMore {
                        let min_required = (boundary.audio_start.max(0) as usize)
                            .saturating_add(32768)
                            .min(if content_length > 0 {
                                content_length as usize
                            } else {
                                usize::MAX
                            });
                        if initial_data.len() >= min_required {
                            break;
                        }
                    }
                    if initial_data.len() >= 16 * 1024 * 1024 {
                        break;
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }

    if !crate::hls::M3u8Parser::is_m3u8(&initial_data)
        && content_length > 0
        && initial_data.len() < (content_length as usize).min(65536)
    {
        return (Vec::new(), cancel.is_some_and(|c| c.is_cancelled()));
    }

    (initial_data, false)
}

#[cfg(not(target_arch = "wasm32"))]
fn spawn_network_streamer_thread(
    mut reader: Box<dyn Read + Send>,
    session: StreamSession,
    abort_stream: Arc<AtomicBool>,
    decoder_running: Arc<AtomicBool>,
    url: String,
    headers: Option<Vec<crate::api::types::RustHttpHeader>>,
    content_length: i64,
    is_live: bool,
) {
    crate::map_log!(3, "Network streamer thread started");
    let _ = std::thread::Builder::new()
        .name("miniaudio-net-streamer".to_string())
        .spawn(move || {
            session.body.set_push_streaming(true);
            let mut chunk = vec![0u8; 32768];
            let mut range_retries = 0u32;
            let mut stream_pos = session.range_end();

            while !abort_stream.load(Ordering::Relaxed) && decoder_running.load(Ordering::Relaxed) {
                if session.is_eof() {
                    session.body.set_push_streaming(false);
                    if is_live {
                        break;
                    }
                    if session.is_eof()
                        && !abort_stream.load(Ordering::Relaxed)
                        && decoder_running.load(Ordering::Relaxed)
                    {
                        session.wait_signal(Duration::from_millis(500));
                    }
                    continue;
                }

                // Query the 3-phase progressive block-coalescing scheduler (5s -> 5s -> 15s super-blocks)
                let Some(order) = session
                    .next_block_request()
                    .or_else(|| session.wait_for_next_block(Duration::from_millis(250)))
                else {
                    continue;
                };

                // If an out-of-cache seek re-anchored the circular window (`order.offset != stream_pos`),
                // reposition the stream via in-place skip (<= 64 KB forward) or HTTP Range request.
                if !is_live && order.offset != stream_pos {
                    let mut skipped_in_place = false;
                    if order.offset > stream_pos && (order.offset - stream_pos) <= 65536 {
                        let mut skip_rem = (order.offset - stream_pos) as usize;
                        skipped_in_place = true;
                        while skip_rem > 0 {
                            let n_skip = skip_rem.min(chunk.len());
                            match reader.read(&mut chunk[..n_skip]) {
                                Ok(0) => {
                                    skipped_in_place = false;
                                    break;
                                }
                                Ok(n) => {
                                    skip_rem -= n;
                                    stream_pos += n as u64;
                                }
                                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                                Err(_) => {
                                    skipped_in_place = false;
                                    break;
                                }
                            }
                        }
                    }

                    if !skipped_in_place {
                        let range_hdr = format!("bytes={}-", order.offset);
                        let agent = build_network_agent();
                        let req = apply_http_headers(agent.get(&url), headers.as_deref())
                            .header("Range", &range_hdr);
                        match req.call() {
                            Ok(res) if res.status().as_u16() == 206 => {
                                reader = Box::new(res.into_body().into_reader());
                                stream_pos = order.offset;
                            }
                            _ => {
                                std::thread::sleep(Duration::from_millis(50));
                                continue;
                            }
                        }
                    }
                }

                let mut remaining_in_block = order.length;
                while remaining_in_block > 0
                    && !abort_stream.load(Ordering::Relaxed)
                    && decoder_running.load(Ordering::Relaxed)
                {
                    if !is_live && session.range_end() != stream_pos {
                        break;
                    }

                    let to_read = remaining_in_block.min(chunk.len());
                    match reader.read(&mut chunk[..to_read]) {
                        Ok(0) => {
                            let current_end = session.range_end();
                            let target_end = session.audio_end_offset().unwrap_or(
                                if content_length > 0 {
                                    content_length as u64
                                } else {
                                    0
                                },
                            );
                            if !is_live
                                && target_end > 0
                                && current_end < target_end
                                && range_retries < 3
                            {
                                range_retries += 1;
                                let range_hdr = format!("bytes={}-", current_end);
                                let agent = build_network_agent();
                                let req =
                                    apply_http_headers(agent.get(&url), headers.as_deref())
                                        .header("Range", &range_hdr);
                                if let Ok(res) = req.call() {
                                    if res.status().as_u16() == 206 {
                                        reader = Box::new(res.into_body().into_reader());
                                        stream_pos = current_end;
                                        continue;
                                    }
                                }
                            }
                            crate::map_log!(3, "Network streamer reached EOF");
                            session.mark_eof();
                            session.body.set_push_streaming(false);
                            if is_live {
                                return;
                            }
                            stream_pos = u64::MAX;
                            break;
                        }
                        Ok(n) => {
                            range_retries = 0;
                            let mut offset = 0;
                            while offset < n
                                && !abort_stream.load(Ordering::Relaxed)
                                && decoder_running.load(Ordering::Relaxed)
                            {
                                if !is_live && session.range_end() != stream_pos + offset as u64 {
                                    break;
                                }
                                match session.feed_chunk(&chunk[offset..n]) {
                                    Ok(0) => {
                                        session.wait_for_free_space(
                                            n - offset,
                                            Duration::from_millis(250),
                                        );
                                    }
                                    Ok(written) => {
                                        offset += written;
                                    }
                                    Err(crate::buffer::BufferError::Busy) => {
                                        session.wait_for_free_space(
                                            n - offset,
                                            Duration::from_millis(250),
                                        );
                                    }
                                    Err(_) => {
                                        session.body.set_push_streaming(false);
                                        return;
                                    }
                                }
                            }
                            stream_pos += offset as u64;
                            remaining_in_block = remaining_in_block.saturating_sub(offset);
                            if session.is_eof() {
                                session.body.set_push_streaming(false);
                                if is_live {
                                    return;
                                }
                                break;
                            }
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(e) => {
                            let current_end = session.range_end();
                            let target_end = session.audio_end_offset().unwrap_or(
                                if content_length > 0 {
                                    content_length as u64
                                } else {
                                    0
                                },
                            );
                            if !is_live
                                && target_end > 0
                                && current_end < target_end
                                && range_retries < 3
                            {
                                range_retries += 1;
                                let range_hdr = format!("bytes={}-", current_end);
                                let agent = build_network_agent();
                                let req =
                                    apply_http_headers(agent.get(&url), headers.as_deref())
                                        .header("Range", &range_hdr);
                                if let Ok(res) = req.call() {
                                    if res.status().as_u16() == 206 {
                                        reader = Box::new(res.into_body().into_reader());
                                        stream_pos = current_end;
                                        continue;
                                    }
                                }
                            }
                            crate::map_log!(1, "Network streamer read error: {:?}", e);
                            session.body.set_push_streaming(false);
                            return;
                        }
                    }
                }

                if order.reaches_eof && session.range_end() >= order.offset + order.length as u64 {
                    crate::map_log!(3, "Network streamer completed audio payload up to audio_end");
                    session.mark_eof();
                    session.body.set_push_streaming(false);
                    if is_live {
                        break;
                    }
                    continue;
                }
            }
            session.body.set_push_streaming(false);
        });
}

/// Deterministic black-box PCM adaptation pipeline:
/// `SilenceDetector` -> `ChannelMatrix` -> `RubatoResampler` -> pending PCM staging buffer.
struct PcmAdaptationPipeline {
    silence_detector: SilenceDetector,
    channel_matrix: ChannelMatrix,
    resampler: RubatoResampler,
    active_buf: Vec<f32>,
    matrix_buf: Vec<f32>,
    resampler_out: Vec<f32>,
    pending_pcm: Vec<f32>,
    pending_offset: usize,
}

impl PcmAdaptationPipeline {
    fn new(track_sr: u32, track_ch: usize, dev_sr: u32, dev_ch: usize) -> Self {
        let sr = track_sr.max(8000);
        let ch = track_ch.clamp(1, 16);
        let d_sr = dev_sr.max(8000);
        let d_ch = dev_ch.clamp(1, 16);

        let resampler = RubatoResampler::new(sr, d_sr, d_ch, 1024)
            .unwrap_or_else(|_| RubatoResampler::passthrough(48000, d_ch, 1024));

        Self {
            silence_detector: SilenceDetector::new(ch, sr),
            channel_matrix: ChannelMatrix::new(ch, d_ch),
            resampler,
            active_buf: Vec::new(),
            matrix_buf: Vec::new(),
            resampler_out: Vec::new(),
            pending_pcm: Vec::new(),
            pending_offset: 0,
        }
    }

    fn sync_silence_format(&mut self, sr: u32, ch: usize) {
        if sr > 0
            && ch > 0
            && (sr != self.silence_detector.sample_rate() || ch != self.silence_detector.channels())
        {
            self.silence_detector.set_sample_rate(sr);
            self.silence_detector.set_channels(ch);
        }
    }

    fn reset(&mut self, reset_saved_ms: bool) {
        self.silence_detector.reset(reset_saved_ms);
        self.pending_pcm.clear();
        self.pending_offset = 0;
        self.resampler.reset();
    }

    fn clear_pending_and_resampler(&mut self) {
        self.pending_pcm.clear();
        self.pending_offset = 0;
        self.resampler.reset();
    }

    fn flush_resampler_into_pending(&mut self) {
        if self.pending_pcm.is_empty() {
            let _ = self.resampler.flush(&mut self.pending_pcm);
            self.pending_offset = 0;
        }
    }

    /// Drains any staged PCM samples into `producer_arc`.
    /// Returns `true` if all staged PCM samples have been completely written.
    fn drain_pending_to(&mut self, producer_arc: &Arc<Mutex<Option<AudioProducer>>>) -> bool {
        if self.pending_offset >= self.pending_pcm.len() {
            self.pending_pcm.clear();
            self.pending_offset = 0;
            return true;
        }

        let slice_to_write = &self.pending_pcm[self.pending_offset..];
        let written = producer_arc
            .lock()
            .ok()
            .and_then(|mut g| g.as_mut().map(|p| p.write_chunk(slice_to_write)))
            .unwrap_or(0);

        self.pending_offset += written;
        if self.pending_offset >= self.pending_pcm.len() {
            self.pending_pcm.clear();
            self.pending_offset = 0;
            true
        } else {
            false
        }
    }

    /// Processes a decoded interleaved frame buffer through silence trimming, channel matrixing,
    /// and high-precision resampling, staging the result in `pending_pcm`.
    /// Returns the total `saved_ms` accumulated by the silence detector.
    fn process_frame(
        &mut self,
        frame_buf: &[f32],
        track_sr: u32,
        track_ch: usize,
        dev_sr: u32,
        dev_ch: usize,
        silence_cfg: SilenceConfig,
    ) -> i64 {
        self.sync_silence_format(track_sr, track_ch);
        self.silence_detector.set_config(silence_cfg);

        if self.active_buf.len() < frame_buf.len() {
            self.active_buf.resize(frame_buf.len(), 0.0);
        }
        let (frames_out, _) = self
            .silence_detector
            .process_frames(frame_buf, &mut self.active_buf);
        let saved_ms = self.silence_detector.saved_ms() as i64;

        let samples_out = frames_out * track_ch;
        if samples_out == 0 {
            return saved_ms;
        }
        let active_slice = &self.active_buf[..samples_out];

        self.channel_matrix.set_channels(track_ch, dev_ch);
        self.channel_matrix
            .process_interleaved(active_slice, &mut self.matrix_buf);

        if self.resampler.sample_rate_in() != track_sr
            || self.resampler.sample_rate_out() != dev_sr
            || self.resampler.channels() != dev_ch
        {
            if let Ok(new_res) = RubatoResampler::new(track_sr, dev_sr, dev_ch, 1024) {
                self.resampler = new_res;
            }
        }

        self.resampler_out.clear();
        let _ = self
            .resampler
            .process_interleaved(&self.matrix_buf, &mut self.resampler_out);

        self.pending_pcm.extend_from_slice(&self.resampler_out);
        self.pending_offset = 0;
        saved_ms
    }
}

/// Background decoding worker orchestrating decoder lifecycle, stream re-init,
/// seek synchronization, PCM adaptation, and ring-buffer feeding.
struct DecoderWorker {
    running: Arc<AtomicBool>,
    wake: Arc<(Mutex<bool>, Condvar)>,
    state: Arc<AtomicI32>,
    engine_arc: Arc<Mutex<Option<SymphoniaEngine>>>,
    engine_loaded: Arc<AtomicBool>,
    producer_arc: Arc<Mutex<Option<AudioProducer>>>,
    seek_req: Arc<AtomicI64>,
    seek_packed: Arc<AtomicU64>,
    open_gen: Arc<AtomicU64>,
    pos_ms: Arc<AtomicI64>,
    pos_frames: Arc<AtomicI64>,
    dur_ms: Arc<AtomicI64>,
    sr_arc: Arc<AtomicU32>,
    ch_arc: Arc<AtomicU32>,
    dev_sr_arc: Arc<AtomicU32>,
    dev_ch_arc: Arc<AtomicU32>,
    silence_cfg_arc: Arc<CachePaddedSeqlock<SilenceConfig>>,
    silence_saved_arc: Arc<AtomicI64>,
    is_stream_arc: Arc<AtomicBool>,
    at_live_edge_arc: Arc<AtomicBool>,
    session_arc: Arc<RwLock<Option<StreamSession>>>,
    decoder_eof_arc: Arc<AtomicBool>,
    tele: Arc<TelemetryDispatcher>,
    track_exhausted: Arc<AtomicBool>,
    is_buffering: Arc<AtomicBool>,
    visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    visualizer_enabled: Arc<AtomicBool>,
    flush_generation: Arc<AtomicU64>,
    flush_acknowledged: Arc<AtomicU64>,
    stream_reinit_needed: Arc<AtomicBool>,

    pipeline: PcmAdaptationPipeline,
    frame_buf: Vec<f32>,
    last_tele_pos: i64,
    last_vis_instant: MonotonicInstant,
    last_vis: VisualizerData,
}

impl DecoderWorker {
    fn wait_for_wake(&self, timeout_ms: u64) {
        let (lock, cvar) = &*self.wake;
        let guard = lock_unpoisoned(lock);
        let _ = wait_timeout_unpoisoned(cvar, guard, Duration::from_millis(timeout_ms));
    }

    fn available_producer_slots(&self) -> usize {
        self.producer_arc
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|p| p.slots_available()))
            .unwrap_or(0)
    }

    fn is_producer_empty(&self) -> bool {
        self.producer_arc
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|p| p.slots_available() >= p.capacity()))
            .unwrap_or(true)
    }

    fn poll_renderer_flags(&mut self) {
        let cur_sr = self.sr_arc.load(Ordering::Relaxed);
        let cur_ch = self.ch_arc.load(Ordering::Relaxed) as usize;
        self.pipeline.sync_silence_format(cur_sr, cur_ch);

        if self.is_stream_arc.load(Ordering::Relaxed) {
            let live_edge = self
                .session_arc
                .read()
                .ok()
                .and_then(|g| g.as_ref().map(|s| s.is_at_live_edge()))
                .unwrap_or(false);
            self.at_live_edge_arc.store(live_edge, Ordering::Relaxed);
        } else {
            self.at_live_edge_arc.store(false, Ordering::Relaxed);
        }
    }

    /// Processes a pending seek request if one exists.
    /// Returns `true` if the main worker loop should `continue` immediately.
    fn handle_pending_seek(&mut self) -> bool {
        let packed = self.seek_packed.swap(0, Ordering::AcqRel);
        if packed == 0 {
            return false;
        }
        let gen = (packed >> 40) as i64;
        let target_seek = (packed & 0xFF_FFFF_FFFF) as i64;
        let start_open_gen = self.open_gen.load(Ordering::Acquire);
        let is_superseded = || {
            self.seek_packed.load(Ordering::Acquire) != 0
                || self.seek_req.load(Ordering::Acquire) != gen
                || self.open_gen.load(Ordering::Acquire) != start_open_gen
        };
        crate::map_log!(4, "DecoderWorker executing seek to {}ms (gen={})", target_seek, gen);

        let cur_dev_sr = self.dev_sr_arc.load(Ordering::Relaxed).max(8000) as i64;
        let dur = self.dur_ms.load(Ordering::Relaxed);
        if dur > 0 && target_seek >= dur {
            if !is_superseded() {
                self.decoder_eof_arc.store(true, Ordering::Relaxed);
                self.track_exhausted.store(true, Ordering::Release);
                self.pos_ms.store(dur, Ordering::Relaxed);
                let f = if cur_dev_sr > 0 {
                    (dur * cur_dev_sr * 1024) / 1000
                } else {
                    0
                };
                self.pos_frames.store(f, Ordering::Relaxed);
                self.tele
                    .post_event(EventType::Position, MapEventData { position_ms: dur });
                let _ = self.seek_req.compare_exchange(
                    gen,
                    -1,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
            }
            return true;
        }

        {
            let cur_flush = self.flush_generation.load(Ordering::Acquire);
            let start_wait = MonotonicInstant::now();
            while self.flush_acknowledged.load(Ordering::Acquire) < cur_flush
                && start_wait.elapsed() < Duration::from_millis(15)
            {
                if is_superseded() {
                    return true;
                }
                thread::sleep(Duration::from_millis(1));
            }
        }

        if is_superseded() {
            return true;
        }

        self.decoder_eof_arc.store(false, Ordering::Relaxed);
        if let Ok(mut eng_lock) = self.engine_arc.lock() {
            if is_superseded() {
                return true;
            }
            let mut reinit = false;
            if target_seek == 0 && self.is_stream_arc.load(Ordering::Relaxed) {
                if let Ok(guard) = self.session_arc.read() {
                    if let Some(ref session) = *guard {
                        let (hit, contig) = session.try_seek_cached(0);
                        if !hit || !contig {
                            session.flush(0);
                        }
                        session.set_decoding_audio(false);
                        let reader = session.create_reader();
                        if let Ok(new_eng) = SymphoniaEngine::new(reader, None) {
                            *eng_lock = Some(new_eng);
                            reinit = true;
                        }
                        session.set_decoding_audio(true);
                    }
                }
            }
            if !reinit {
                if let Some(ref mut eng) = *eng_lock {
                    match eng.seek_ms(target_seek as u64) {
                        Ok(()) => {
                            crate::map_log!(3, "DecoderWorker seek_ms({}) succeeded", target_seek);
                        }
                        Err(e) => {
                            crate::map_log!(1, "DecoderWorker seek_ms({}) failed: {:?}", target_seek, e);
                        }
                    }
                }
            }
        }

        // Discard stale seek commit completely if stop/begin_open or a newer seek arrived
        // while `eng.seek_ms` was running (otherwise slow linear seeks overwrite newer pos_ms).
        if is_superseded() {
            return true;
        }

        self.pipeline.reset(target_seek == 0);
        self.silence_saved_arc.store(0, Ordering::Relaxed);
        self.tele.post_event(
            EventType::SilenceSaved,
            MapEventData {
                silence_saved_ms: 0,
            },
        );

        if is_superseded() {
            return true;
        }

        self.pos_ms.store(target_seek, Ordering::Relaxed);
        let f = if cur_dev_sr > 0 {
            (target_seek * cur_dev_sr * 1024) / 1000
        } else {
            0
        };
        self.pos_frames.store(f, Ordering::Relaxed);
        self.tele.post_event(
            EventType::Position,
            MapEventData {
                position_ms: target_seek,
            },
        );
        self.seek_req
            .compare_exchange(gen, -1, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
    }

    /// Ensures a flushed live stream re-initializes its `SymphoniaEngine` once data arrives.
    /// Returns `true` if ready to proceed, `false` if waiting for stream bytes.
    fn ensure_stream_initialized(&mut self) -> bool {
        if !self.stream_reinit_needed.load(Ordering::Acquire) {
            return true;
        }

        let maybe_reader = self.session_arc.read().ok().and_then(|guard| {
            let session = guard.as_ref()?;
            let has_data = session.head_size() > 0
                || session.range_end() > session.range_start()
                || session.is_eof();
            if has_data {
                Some(session.create_reader())
            } else {
                None
            }
        });

        let Some(reader) = maybe_reader else {
            return false;
        };

        if let Ok(new_eng) = SymphoniaEngine::new(reader, None) {
            let new_sr = new_eng.sample_rate();
            let new_ch = new_eng.channels();
            if new_sr > 0 {
                self.sr_arc.store(new_sr, Ordering::Relaxed);
            }
            if new_ch > 0 {
                self.ch_arc.store(new_ch, Ordering::Relaxed);
            }
            if let Ok(mut eng_lock) = self.engine_arc.lock() {
                *eng_lock = Some(new_eng);
            }
            self.engine_loaded.store(true, Ordering::Release);
            self.stream_reinit_needed.store(false, Ordering::Release);
            self.decoder_eof_arc.store(false, Ordering::Relaxed);
            self.pipeline.clear_pending_and_resampler();
            true
        } else {
            false
        }
    }

    fn dispatch_periodic_telemetry(&mut self) {
        let cur_pos = self.pos_ms.load(Ordering::Relaxed);
        if cur_pos != self.last_tele_pos
            && (cur_pos / 33 != self.last_tele_pos / 33 || cur_pos == 0)
        {
            self.last_tele_pos = cur_pos;
            self.tele.post_event(
                EventType::Position,
                MapEventData {
                    position_ms: cur_pos,
                },
            );
        }

        if self.visualizer_enabled.load(Ordering::Relaxed)
            && self.last_vis_instant.elapsed() >= Duration::from_millis(33)
        {
            self.last_vis_instant = MonotonicInstant::now();
            let vis = self.visualizer_seqlock.read();
            if vis.is_different_from(&self.last_vis) {
                self.last_vis = vis;
                self.tele
                    .post_event(EventType::Visualizer, MapEventData { visualizer: vis });
            }
        }
    }

    fn check_buffering_recovery(&self) {
        if self.is_buffering.load(Ordering::Relaxed) && !self.is_producer_empty() {
            self.set_buffering(false);
        }
    }

    fn set_buffering(&self, buffering: bool) {
        let prev = self.is_buffering.swap(buffering, Ordering::AcqRel);
        if prev != buffering {
            crate::map_log!(4, "DecoderWorker is_buffering changed: {} -> {}", prev, buffering);
            self.tele
                .post_event(EventType::IsBuffering, MapEventData { is_buffering: buffering as i32 });
        }
    }

    fn handle_eof(&mut self) {
        if !self.decoder_eof_arc.swap(true, Ordering::SeqCst) {
            crate::map_log!(3, "DecoderWorker reached EOF");
        }
        if self.is_stream_arc.load(Ordering::Relaxed) {
            let is_buf_eof = self
                .session_arc
                .read()
                .ok()
                .and_then(|g| g.as_ref().map(|b| b.is_eof()))
                .unwrap_or(true);

            if !is_buf_eof {
                if PlaybackState::from_i32(self.state.load(Ordering::Relaxed)) == PlaybackState::Playing {
                    self.set_buffering(true);
                }
                thread::sleep(Duration::from_millis(15));
                return;
            }
        }

        self.pipeline.flush_resampler_into_pending();
        if !self.pipeline.drain_pending_to(&self.producer_arc) {
            self.wait_for_wake(4);
            return;
        }

        self.set_buffering(false);

        thread::sleep(Duration::from_millis(20));
    }

    fn decode_and_process_step(&mut self) {
        let mut decoded_ok = false;
        let mut eof_reached = false;
        let mut has_engine = false;

        if let Ok(mut eng_lock) = self.engine_arc.lock() {
            if let Some(ref mut eng) = *eng_lock {
                has_engine = true;
                match eng.decode_next_frame(&mut self.frame_buf) {
                    Ok(true) => {
                        decoded_ok = true;
                        let new_sr = eng.sample_rate();
                        let new_ch = eng.channels();
                        if new_sr > 0 && new_sr != self.sr_arc.load(Ordering::Relaxed) {
                            self.sr_arc.store(new_sr, Ordering::Relaxed);
                        }
                        if new_ch > 0 && new_ch != self.ch_arc.load(Ordering::Relaxed) {
                            self.ch_arc.store(new_ch, Ordering::Relaxed);
                        }
                    }
                    Ok(false) => {
                        eof_reached = true;
                    }
                    Err(err) => {
                        if self.is_stream_arc.load(Ordering::Relaxed) {
                            if self.is_producer_empty()
                                && PlaybackState::from_i32(self.state.load(Ordering::Relaxed)) == PlaybackState::Playing
                            {
                                self.set_buffering(true);
                            }
                            thread::sleep(Duration::from_millis(10));
                            return;
                        } else {
                            crate::map_log!(1, "DecoderWorker decode error: {}", err);
                            eof_reached = true;
                        }
                    }
                }
            }
        }

        if !has_engine {
            self.wait_for_wake(20);
            return;
        }

        if eof_reached {
            self.handle_eof();
            return;
        }

        if decoded_ok && !self.frame_buf.is_empty() {
            self.decoder_eof_arc.store(false, Ordering::Relaxed);
            self.set_buffering(false);

            let cur_track_sr = self.sr_arc.load(Ordering::Relaxed).max(8000);
            let cur_track_ch = (self.ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
            let cur_dev_sr = self.dev_sr_arc.load(Ordering::Relaxed).max(8000);
            let cur_dev_ch = (self.dev_ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
            let cur_silence_cfg = self.silence_cfg_arc.read();

            let _new_saved = self.pipeline.process_frame(
                &self.frame_buf,
                cur_track_sr,
                cur_track_ch,
                cur_dev_sr,
                cur_dev_ch,
                cur_silence_cfg,
            );

            let _drained = self.pipeline.drain_pending_to(&self.producer_arc);
        } else if !eof_reached {
            self.wait_for_wake(5);
        }
    }

    fn run(&mut self) {
        while self.running.load(Ordering::Relaxed) {
            self.poll_renderer_flags();

            if self.handle_pending_seek() {
                continue;
            }

            let cur_state = PlaybackState::from_i32(self.state.load(Ordering::Relaxed));
            if cur_state == PlaybackState::Stopped {
                self.wait_for_wake(30);
                continue;
            }
            if cur_state == PlaybackState::Paused && self.available_producer_slots() < 2048 {
                self.wait_for_wake(30);
                continue;
            }

            let cur_flush = self.flush_generation.load(Ordering::Acquire);
            if self.flush_acknowledged.load(Ordering::Acquire) < cur_flush {
                self.wait_for_wake(5);
                continue;
            }

            if self.decoder_eof_arc.load(Ordering::Relaxed) {
                self.wait_for_wake(50);
                continue;
            }

            if !self.ensure_stream_initialized() {
                self.wait_for_wake(10);
                continue;
            }

            self.dispatch_periodic_telemetry();
            self.check_buffering_recovery();

            if !self.pipeline.drain_pending_to(&self.producer_arc) {
                self.wait_for_wake(3);
                continue;
            }

            if self.available_producer_slots() < 2048 {
                self.wait_for_wake(3);
                continue;
            }

            self.decode_and_process_step();
        }
    }
}

/// Self-contained audio playback deck driving background decoding, buffering, DSP, and ring-buffer production.
pub struct StreamingDeck {
    /// Zero-based numerical deck identifier (0: Deck A, 1: Deck B).
    pub deck_id: usize,
    /// Owned real-time PCM renderer decoupled onto a dedicated slot.
    pub renderer: Option<Box<AudioRenderer>>,

    /// Atomic playback state code (`STATE_*`).
    pub state: Arc<AtomicI32>,
    /// Whether playback pauses automatically on audio device switch.
    pub pause_on_device_change: Arc<AtomicBool>,
    /// Current elapsed playback position in milliseconds.
    pub position_ms: Arc<AtomicI64>,
    /// Current elapsed playback position in rendered audio frames.
    pub position_frames: Arc<AtomicI64>,
    /// Total stream duration in milliseconds.
    pub duration_ms: Arc<AtomicI64>,
    /// Volume scale multiplier stored as atomic bits.
    pub volume: Arc<AtomicU32>,
    /// Playback rate speed multiplier stored as atomic bits.
    pub rate: Arc<AtomicU32>,
    /// Playback pitch shift multiplier stored as atomic bits.
    pub pitch: Arc<AtomicU32>,
    /// Stream nominal bitrate in bps.
    pub bitrate: Arc<AtomicU32>,
    /// Audio sample rate in Hz.
    pub sample_rate: Arc<AtomicU32>,
    /// Raw codec sample rate in Hz (0 if None).
    pub raw_sample_rate: Arc<AtomicU32>,
    /// Audio channel count.
    pub channels: Arc<AtomicU32>,
    /// Bit depth per sample (0 if None).
    pub bits_per_sample: Arc<AtomicU32>,
    /// Whether the codec is lossless.
    pub lossless: Arc<AtomicBool>,
    /// Bitrate encoding mode (`0 = Unknown`, `1 = CBR`, `2 = VBR`).
    pub bitrate_mode: Arc<AtomicI32>,
    /// Total file/stream byte size (0 if unknown/live).
    pub file_size: Arc<AtomicU64>,
    /// Canonical codec name (e.g. `"MP3"`, `"FLAC"`, `"AAC"`, `"Vorbis"`, `"Opus"`, `"PCM"`, `"DSD"`, `"APE"`, `"WavPack"`).
    pub codec: Arc<RwLock<String>>,
    /// Canonical container format name (e.g. `"MP3"`, `"FLAC"`, `"Ogg"`, `"MP4"`, `"WAV"`, `"RF64"`, `"RIFX"`, `"W64"`, `"AIFF"`, `"CAF"`, `"Matroska"`, `"WebM"`, `"ADTS"`, `"DSF"`, `"APE"`, `"WavPack"`).
    pub container_format: Arc<RwLock<String>>,
    /// Hardware device output sample rate.
    pub device_sample_rate: Arc<AtomicU32>,
    /// Hardware device output channel count.
    pub device_channels: Arc<AtomicU32>,
    /// Period size in audio frames per callback.
    pub period_size_in_frames: Arc<AtomicU32>,
    /// Cumulative silence skipped in milliseconds.
    pub silence_saved_ms: Arc<AtomicI64>,
    /// Whether FFT visualizer computation is active.
    pub visualizer_enabled: Arc<AtomicBool>,

    /// Whether this deck is streaming from a network stream session.
    pub is_stream: Arc<AtomicBool>,
    /// Whether this deck is at the live edge of an unbounded live broadcast.
    pub at_live_edge: Arc<AtomicBool>,
    /// Unified stream session (`head`, `body`, `metadata` `StreamBuffer`s).
    pub stream_session: Arc<RwLock<Option<StreamSession>>>,
    /// Audio boundary information discovered by stream classification.
    pub boundary_info: Arc<RwLock<Option<BoundaryInfo>>>,
    /// Container/codec format string (e.g. "mp3", "flac", "wav").
    pub format: Arc<RwLock<Option<String>>>,
    /// Metadata revisions, visuals, and chapters captured by Symphonia during probing.
    pub symphonia_meta: Arc<RwLock<crate::metadata::SymphoniaExtractedMeta>>,
    /// Live Shoutcast / Icecast ICY stream metadata and station headers.
    pub icy_metadata: Arc<RwLock<Option<crate::api::types::RustIcyMetadata>>>,
    /// Cached parsed `RustAudioMetadata` keyed by `(flush_generation, meta_version)`.
    pub cached_metadata: Arc<Mutex<Option<(u64, u32, crate::api::types::RustAudioMetadata)>>>,
    /// Optional handle for custom Dart byte stream data injection.
    pub custom_source_handle: Arc<RwLock<Option<CustomByteSourceHandle>>>,

    /// Telemetry event dispatcher delivering updates to Dart.
    pub telemetry: Arc<TelemetryDispatcher>,

    /// Dynamic silence detection and trimming configuration (wait-free seqlock).
    pub silence_config: Arc<CachePaddedSeqlock<SilenceConfig>>,

    /// Ring buffer producer feeding decoded PCM samples to the real-time audio thread.
    pub audio_producer: Arc<Mutex<Option<AudioProducer>>>,
    /// Lock-free command producer sending real-time DSP adjustments to the renderer.
    pub cmd_producer: Arc<Mutex<Option<rtrb::Producer<DspCommand>>>>,
    /// Lock-free Seqlock delivering visualizer metrics to telemetry readers.
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,

    /// Generation counter tracking requested seek flushes.
    pub flush_generation: Arc<AtomicU64>,
    /// Generation counter acknowledging completed seek flushes by the audio thread.
    pub flush_acknowledged: Arc<AtomicU64>,
    /// Whether playback reached the end of the current stream.
    pub track_exhausted: Arc<AtomicBool>,
    /// Whether the deck is waiting for buffer fill.
    pub is_buffering: Arc<AtomicBool>,

    // Cached DSP settings
    /// Graphic equalizer band parameters.
    pub eq_params: EqualizerParams,
    /// Preamp gain in dB stored as atomic float bits.
    pub preamp_db: Arc<AtomicU32>,
    /// ReplayGain loudness normalization settings.
    pub replay_gain: ReplayGainConfig,
    /// Queue item ID currently loaded on this deck (`None` when stopped/unloaded).
    pub queue_item_id: Option<i64>,
    /// Track-specific `(replay_gain_db, replay_peak)` associated with `queue_item_id`.
    pub track_replay_gain: (Option<f32>, Option<f32>),
    /// Stereo balance pan stored as atomic float bits.
    pub balance: Arc<AtomicU32>,
    /// Stereo downmix to mono flag.
    pub mono_enabled: Arc<AtomicBool>,
    /// 3D stereo widening spatializer flag.
    pub spatializer_enabled: Arc<AtomicBool>,
    pub spatializer_width: Arc<AtomicU32>,
    pub crossfeed_config: CrossfeedConfig,
    pub reverb_config: ReverbConfig,
    pub limiter_enabled: Arc<AtomicBool>,

    pub engine: Arc<Mutex<Option<SymphoniaEngine>>>,
    pub engine_loaded: Arc<AtomicBool>,
    pub seek_request_ms: Arc<AtomicI64>,
    pub seek_counter: Arc<AtomicU64>,
    pub seek_packed: Arc<AtomicU64>,
    pub decoder_eof: Arc<AtomicBool>,
    pub stream_reinit_needed: Arc<AtomicBool>,
    pub network_streamer_abort: Arc<AtomicBool>,

    pub decoder_running: Arc<AtomicBool>,
    pub decoder_wake: Arc<(Mutex<bool>, Condvar)>,
    pub decoder_thread: Option<JoinHandle<()>>,
    pub open_generation: Arc<AtomicU64>,
    pub is_analysis: bool,
}

// StreamingDeck is Send + Sync across threads
unsafe impl Send for StreamingDeck {}
unsafe impl Sync for StreamingDeck {}

impl StreamingDeck {
    pub fn new(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
    ) -> Result<Box<Self>, i32> {
        Self::new_internal(
            target_sample_rate,
            target_channels,
            period_size,
            true,
        )
    }

    pub fn new_deck(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
    ) -> Result<Box<Self>, i32> {
        Self::new(target_sample_rate, target_channels, period_size)
    }

    /// Creates a headless deck without hardware audio output and without the real-time decoder loop,
    /// ideal for unconstrained, maximum-speed offline CPU analysis.
    pub fn new_analysis_deck(
        target_sample_rate: u32,
        target_channels: u32,
    ) -> Result<Box<Self>, i32> {
        Self::new_internal(
            target_sample_rate,
            target_channels,
            1024,
            false,
        )
    }

    /// Pulls the next decoded PCM frame batch from `SymphoniaEngine` at unconstrained CPU speed.
    pub fn decode_next_analysis_frame(&mut self, out_buf: &mut Vec<f32>) -> Result<bool, String> {
        let mut eng_lock = lock_unpoisoned(&self.engine);
        if let Some(ref mut eng) = *eng_lock {
            eng.decode_next_frame(out_buf)
                .map_err(|e| format!("Decode error: {}", e))
        } else {
            Ok(false)
        }
    }

    fn new_internal(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
        run_decoder_loop: bool,
    ) -> Result<Box<Self>, i32> {
        let sr = if target_sample_rate > 0 {
            target_sample_rate
        } else {
            44100
        };
        let ch = if target_channels > 0 {
            target_channels
        } else {
            2
        };
        let period = if period_size > 0 { period_size } else { 1024 };

        let state = Arc::new(AtomicI32::new(STATE_STOPPED));
        let pause_on_device_change = Arc::new(AtomicBool::new(false));
        let position_ms = Arc::new(AtomicI64::new(0));
        let position_frames = Arc::new(AtomicI64::new(0));
        let duration_ms = Arc::new(AtomicI64::new(0));
        let volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let rate = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let pitch = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let bitrate = Arc::new(AtomicU32::new(0));
        let sample_rate = Arc::new(AtomicU32::new(sr));
        let raw_sample_rate = Arc::new(AtomicU32::new(0));
        let channels = Arc::new(AtomicU32::new(ch));
        let bits_per_sample = Arc::new(AtomicU32::new(0));
        let lossless = Arc::new(AtomicBool::new(false));
        let bitrate_mode = Arc::new(AtomicI32::new(0));
        let file_size = Arc::new(AtomicU64::new(0));
        let codec = Arc::new(RwLock::new(String::from("Unknown")));
        let container_format = Arc::new(RwLock::new(String::from("Unknown")));
        let device_sample_rate = Arc::new(AtomicU32::new(sr));
        let device_channels = Arc::new(AtomicU32::new(ch));
        let period_size_in_frames = Arc::new(AtomicU32::new(period));
        let silence_saved_ms = Arc::new(AtomicI64::new(0));
        let visualizer_enabled = Arc::new(AtomicBool::new(false));

        let is_stream = Arc::new(AtomicBool::new(false));
        let at_live_edge = Arc::new(AtomicBool::new(false));
        let stream_session = Arc::new(RwLock::new(None));
        let boundary_info = Arc::new(RwLock::new(None));
        let format = Arc::new(RwLock::new(None));
        let symphonia_meta = Arc::new(RwLock::new(crate::metadata::SymphoniaExtractedMeta::default()));
        let icy_metadata = Arc::new(RwLock::new(None));
        let cached_metadata = Arc::new(Mutex::new(None));
        let custom_source_handle = Arc::new(RwLock::new(None));

        let telemetry = Arc::new(TelemetryDispatcher::new());

        let silence_config = Arc::new(CachePaddedSeqlock::new(SilenceConfig::default()));

        static DECK_ID_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
        let deck_id = DECK_ID_COUNTER.fetch_add(1, Ordering::Relaxed);

        let ring_cap = (sr as usize * ch as usize * 3).max(262144);
        let (producer, consumer) = AudioRingBuffer::create(ring_cap);
        let audio_producer = Arc::new(Mutex::new(Some(producer)));

        let (cmd_prod, cmd_cons) = rtrb::RingBuffer::new(256);
        let cmd_producer = Arc::new(Mutex::new(Some(cmd_prod)));

        let visualizer_seqlock = Arc::new(CachePaddedSeqlock::new(VisualizerData::default()));
        let flush_generation = Arc::new(AtomicU64::new(0));
        let flush_acknowledged = Arc::new(AtomicU64::new(0));
        let track_exhausted = Arc::new(AtomicBool::new(false));
        let is_buffering = Arc::new(AtomicBool::new(false));

        let eq_params = EqualizerParams::default();
        let preamp_db = Arc::new(AtomicU32::new(0.0f32.to_bits()));
        let replay_gain = ReplayGainConfig::default();
        let queue_item_id = None;
        let track_replay_gain = (None, None);
        let balance = Arc::new(AtomicU32::new(0.0f32.to_bits()));
        let mono_enabled = Arc::new(AtomicBool::new(false));
        let spatializer_enabled = Arc::new(AtomicBool::new(false));
        let spatializer_width = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let crossfeed_config = CrossfeedConfig::default();
        let reverb_config = ReverbConfig::default();
        let limiter_enabled = Arc::new(AtomicBool::new(true));

        let engine = Arc::new(Mutex::new(None));
        let engine_loaded = Arc::new(AtomicBool::new(false));
        let seek_request_ms = Arc::new(AtomicI64::new(-1));
        let seek_counter = Arc::new(AtomicU64::new(1));
        let seek_packed = Arc::new(AtomicU64::new(0));
        let decoder_eof = Arc::new(AtomicBool::new(false));
        let stream_reinit_needed = Arc::new(AtomicBool::new(false));
        let network_streamer_abort = Arc::new(AtomicBool::new(false));

        let decoder_running = Arc::new(AtomicBool::new(true));
        let decoder_wake = Arc::new((Mutex::new(false), Condvar::new()));

        let pause_on_device = pause_on_device_change.clone();
        let state_for_notif = state.clone();
        let tele_for_notif = telemetry.clone();
        let notif_cb: Arc<dyn Fn(i32) + Send + Sync> = Arc::new(move |_notification_type: i32| {
            if pause_on_device.load(Ordering::Relaxed)
                && state_for_notif.load(Ordering::Relaxed) == STATE_PLAYING
            {
                state_for_notif.store(STATE_PAUSED, Ordering::Relaxed);
                tele_for_notif.post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
                tele_for_notif.post_event(
                    EventType::State,
                    MapEventData {
                        state: STATE_PAUSED,
                    },
                );
            }
        });

        let renderer = AudioRenderer {
            header: crate::core::renderer::PcmRendererHeader {
                render_fn: crate::core::renderer::audio_renderer_render_trampoline,
                notif_fn: crate::core::renderer::audio_renderer_notif_trampoline,
            },
            deck_id,
            consumer,
            cmd_consumer: cmd_cons,
            state: state.clone(),
            sample_rate: sample_rate.clone(),
            channels: channels.clone(),
            device_sample_rate: device_sample_rate.clone(),
            device_channels: device_channels.clone(),
            volume: volume.clone(),
            rate: rate.clone(),
            pitch: pitch.clone(),
            position_frames: position_frames.clone(),
            position_ms: position_ms.clone(),
            duration_ms: duration_ms.clone(),
            decoder_eof: decoder_eof.clone(),
            seek_request_ms: seek_request_ms.clone(),
            is_stream: is_stream.clone(),
            at_live_edge: at_live_edge.clone(),
            flush_generation: flush_generation.clone(),
            flush_acknowledged: flush_acknowledged.clone(),
            local_flush_gen: 0,
            track_exhausted: track_exhausted.clone(),
            is_buffering: is_buffering.clone(),
            dsp: DspChain::new(ch as usize, sr),
            sonic: SonicStream::new(sr, (ch as usize).clamp(1, 8)),
            sonic_in_buf: vec![0.0f32; 16384],
            visualizer_seqlock: visualizer_seqlock.clone(),
            visualizer_enabled: visualizer_enabled.clone(),
            spatial: crate::dsp::spatial::SpatialProcessor::default(),
            listener: crate::dsp::spatial::SpatialListener::default(),
            emitter: crate::dsp::spatial::SpatialEmitter::default(),
            notification_callback: Some(notif_cb),
        };
        let renderer = Some(Box::new(renderer));

        let mut coordinator = Box::new(Self {
            deck_id,
            renderer,
            state,
            pause_on_device_change,
            position_ms,
            position_frames,
            duration_ms,
            volume,
            rate,
            pitch,
            bitrate,
            sample_rate,
            raw_sample_rate,
            channels,
            bits_per_sample,
            lossless,
            bitrate_mode,
            file_size,
            codec,
            container_format,
            device_sample_rate,
            device_channels,
            period_size_in_frames,
            silence_saved_ms,
            visualizer_enabled,
            is_stream,
            at_live_edge,
            stream_session,
            boundary_info,
            format,
            symphonia_meta,
            icy_metadata,
            cached_metadata,
            custom_source_handle,
            telemetry,
            silence_config,
            audio_producer,
            cmd_producer,
            visualizer_seqlock,
            flush_generation,
            flush_acknowledged,
            track_exhausted,
            is_buffering,
            eq_params,
            preamp_db,
            replay_gain,
            queue_item_id,
            track_replay_gain,
            balance,
            mono_enabled,
            spatializer_enabled,
            spatializer_width,
            crossfeed_config,
            reverb_config,
            limiter_enabled,
            engine,
            engine_loaded,
            seek_request_ms,
            seek_counter,
            seek_packed,
            decoder_eof,
            stream_reinit_needed,
            network_streamer_abort,
            decoder_running,
            decoder_wake,
            decoder_thread: None,
            open_generation: Arc::new(AtomicU64::new(0)),
            is_analysis: !run_decoder_loop,
        });

        if run_decoder_loop {
            coordinator.start_decoder_loop();
        }
        Ok(coordinator)
    }

    /// Sends a real-time thread-safe control command to the audio renderer.
    pub fn send_dsp_command(&self, cmd: DspCommand) {
        if let Ok(mut guard) = self.cmd_producer.lock() {
            if let Some(ref mut prod) = *guard {
                let _ = prod.push(cmd);
            }
        }
    }

    /// Enables or disables 3D spatial audio processing on this deck.
    pub fn set_spatial_enabled(&mut self, enabled: bool) {
        self.send_dsp_command(DspCommand::SetSpatialEnabled(enabled));
    }

    /// Updates the 3D spatial listener position and orientation on this deck.
    pub fn set_spatial_listener(&mut self, listener: crate::dsp::spatial::SpatialListener) {
        self.send_dsp_command(DspCommand::SetSpatialListener(listener));
    }

    /// Updates the 3D spatial emitter parameters on this deck.
    pub fn set_spatial_emitter(&mut self, emitter: crate::dsp::spatial::SpatialEmitter) {
        self.send_dsp_command(DspCommand::SetSpatialEmitter(emitter));
    }

    /// Sets the Doppler effect intensity factor on this deck.
    pub fn set_spatial_doppler_factor(&mut self, factor: f32) {
        self.send_dsp_command(DspCommand::SetSpatialDopplerFactor(factor));
    }

    /// Sets the speed of sound medium velocity in meters per second.
    pub fn set_spatial_speed_of_sound(&mut self, speed: f32) {
        self.send_dsp_command(DspCommand::SetSpatialSpeedOfSound(speed));
    }

    fn start_decoder_loop(&mut self) {
        let cur_sr = self.sample_rate.load(Ordering::Relaxed).max(8000);
        let cur_ch = (self.channels.load(Ordering::Relaxed) as usize).clamp(1, 16);
        let cur_dev_sr = self.device_sample_rate.load(Ordering::Relaxed).max(8000);
        let cur_dev_ch = (self.device_channels.load(Ordering::Relaxed) as usize).clamp(1, 16);

        let mut worker = DecoderWorker {
            running: self.decoder_running.clone(),
            wake: self.decoder_wake.clone(),
            state: self.state.clone(),
            engine_arc: self.engine.clone(),
            engine_loaded: self.engine_loaded.clone(),
            producer_arc: self.audio_producer.clone(),
            seek_req: self.seek_request_ms.clone(),
            seek_packed: self.seek_packed.clone(),
            open_gen: self.open_generation.clone(),
            pos_ms: self.position_ms.clone(),
            pos_frames: self.position_frames.clone(),
            dur_ms: self.duration_ms.clone(),
            sr_arc: self.sample_rate.clone(),
            ch_arc: self.channels.clone(),
            dev_sr_arc: self.device_sample_rate.clone(),
            dev_ch_arc: self.device_channels.clone(),
            silence_cfg_arc: self.silence_config.clone(),
            silence_saved_arc: self.silence_saved_ms.clone(),
            is_stream_arc: self.is_stream.clone(),
            at_live_edge_arc: self.at_live_edge.clone(),
            session_arc: self.stream_session.clone(),
            decoder_eof_arc: self.decoder_eof.clone(),
            tele: self.telemetry.clone(),
            track_exhausted: self.track_exhausted.clone(),
            is_buffering: self.is_buffering.clone(),
            visualizer_seqlock: self.visualizer_seqlock.clone(),
            visualizer_enabled: self.visualizer_enabled.clone(),
            flush_generation: self.flush_generation.clone(),
            flush_acknowledged: self.flush_acknowledged.clone(),
            stream_reinit_needed: self.stream_reinit_needed.clone(),
            pipeline: PcmAdaptationPipeline::new(cur_sr, cur_ch, cur_dev_sr, cur_dev_ch),
            frame_buf: Vec::new(),
            last_tele_pos: -1,
            last_vis_instant: MonotonicInstant::now(),
            last_vis: VisualizerData {
                rms: -1.0,
                ..Default::default()
            },
        };

        self.decoder_thread = thread::Builder::new()
            .name("map-decoder".to_string())
            .spawn(move || worker.run())
            .ok();
    }



    fn mark_open_error(&self, err_code: i32) -> i32 {
        self.telemetry
            .post_event(EventType::Error, MapEventData { error_code: err_code });
        err_code
    }

    pub fn begin_open(&mut self) -> i32 {
        let _ = self.stop();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        self.clear_pending_seek();
        self.network_streamer_abort.store(true, Ordering::Release);
        self.is_stream.store(false, Ordering::Release);
        if let Ok(mut guard) = self.stream_session.write() {
            if let Some(ref session) = *guard {
                session.abort();
            }
            *guard = None;
        }
        if let Ok(mut guard) = self.boundary_info.write() {
            *guard = None;
        }
        if let Ok(mut guard) = self.symphonia_meta.write() {
            *guard = crate::metadata::SymphoniaExtractedMeta::default();
        }
        if let Ok(mut guard) = self.icy_metadata.write() {
            *guard = None;
        }
        if let Ok(mut guard) = self.cached_metadata.lock() {
            *guard = None;
        }
        self.stream_reinit_needed.store(false, Ordering::Release);
        if let Some(ref handle) = *read_unpoisoned(&self.custom_source_handle) {
            handle.abort();
        }
        *write_unpoisoned(&self.custom_source_handle) = None;
        self.engine_loaded.store(false, Ordering::Release);
        *lock_unpoisoned(&self.engine) = None;
        self.decoder_eof.store(false, Ordering::Relaxed);
        self.silence_saved_ms.store(0, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::SilenceSaved,
            MapEventData {
                silence_saved_ms: 0,
            },
        );
        self.position_ms.store(0, Ordering::Relaxed);
        self.position_frames.store(0, Ordering::Relaxed);
        self.duration_ms.store(0, Ordering::Relaxed);
        self.bitrate.store(0, Ordering::Relaxed);
        self.raw_sample_rate.store(0, Ordering::Relaxed);
        self.bits_per_sample.store(0, Ordering::Relaxed);
        self.lossless.store(false, Ordering::Relaxed);
        self.bitrate_mode.store(0, Ordering::Relaxed);
        self.file_size.store(0, Ordering::Relaxed);
        if let Ok(mut c) = self.codec.write() {
            *c = String::from("Unknown");
        }
        if let Ok(mut cf) = self.container_format.write() {
            *cf = String::from("Unknown");
        }
        MAP_SUCCESS
    }

    pub fn open_source(
        &mut self,
        source: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
    ) -> i32 {
        self.open_source_with_cancel(source, headers, None)
    }

    pub fn open_source_with_cancel(
        &mut self,
        source: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let trimmed = source.trim();
        crate::map_log!(3, "open_source: source={}", trimmed);
        if trimmed.starts_with("http://")
            || trimmed.starts_with("https://")
            || trimmed.starts_with("icy://")
            || trimmed.starts_with("blob:")
        {
            #[cfg(target_arch = "wasm32")]
            {
                return self.open_network_with_cancel(trimmed, headers, cancel);
            }
            #[cfg(not(target_arch = "wasm32"))]
            {
                let url = if let Some(stripped) = trimmed.strip_prefix("icy://") {
                    format!("http://{}", stripped)
                } else {
                    trimmed.to_string()
                };
                return self.open_network_with_cancel(&url, headers, cancel);
            }
        } else {
            let resolved = resolve_local_source_path(trimmed);
            let res = self.open_file(&resolved);
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            res
        }
    }

    fn open_hls_from_m3u8_bytes<F>(
        &mut self,
        base_url: &str,
        m3u8_bytes: &[u8],
        cancel: Option<&CancelToken>,
        mut fetch_bytes: F,
    ) -> i32
    where
        F: FnMut(&str) -> Result<Vec<u8>, i32>,
    {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let parsed = match crate::hls::M3u8Parser::parse(m3u8_bytes) {
            Ok(p) => p,
            Err(_) => return self.mark_open_error(MAP_ERROR_DECODE_FAILED),
        };

        let (base_media_url, media_playlist) = match parsed {
            crate::hls::ParsedHlsPlaylist::Master { variants } => {
                let Some(first_var) = variants.first() else {
                    return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                };
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                let media_url = resolve_hls_uri(base_url, &first_var.uri);
                let media_bytes = match fetch_bytes(&media_url) {
                    Ok(b) => b,
                    Err(code) => return self.mark_open_error(code),
                };
                match crate::hls::M3u8Parser::parse(&media_bytes) {
                    Ok(p) => (media_url, p),
                    Err(_) => return self.mark_open_error(MAP_ERROR_DECODE_FAILED),
                }
            }
            media => (base_url.to_string(), media),
        };

        let crate::hls::ParsedHlsPlaylist::Media {
            is_live,
            segments,
            total_duration_seconds,
            ..
        } = media_playlist
        else {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        };

        if segments.is_empty() {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        }

        let max_segs = if is_live { 8 } else { segments.len().min(512) };
        let mut combined_audio = Vec::new();
        let mut hint_ext: Option<&'static str> = None;

        for seg in segments.iter().take(max_segs) {
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            let seg_url = resolve_hls_uri(&base_media_url, &seg.uri);
            let Ok(raw_bytes) = fetch_bytes(&seg_url) else {
                if combined_audio.is_empty() {
                    return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
                }
                break;
            };
            if raw_bytes.is_empty() {
                continue;
            }
            if crate::hls::MpegTsDemuxer::is_mpeg_ts(&raw_bytes) {
                let demuxed = crate::hls::MpegTsDemuxer::demux_segment(&raw_bytes);
                if hint_ext.is_none() {
                    hint_ext = match demuxed.codec {
                        crate::hls::TsAudioCodec::AacAdts => Some("aac"),
                        crate::hls::TsAudioCodec::Mp3 => Some("mp3"),
                        _ => None,
                    };
                }
                if !demuxed.audio_bytes.is_empty() {
                    combined_audio.extend_from_slice(&demuxed.audio_bytes);
                }
            } else {
                if hint_ext.is_none() {
                    let fmt = infer_network_encoding_format(&seg_url, None);
                    hint_ext = encoding_format_to_extension(fmt);
                }
                combined_audio.extend_from_slice(&raw_bytes);
            }
        }

        if combined_audio.is_empty() {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        }

        if is_live {
            let fmt = match hint_ext {
                Some("aac") => 5,
                Some("mp3") => 3,
                _ => 0,
            };
            let res_code =
                self.open_stream_ex(&combined_audio, None, -1, true, 4 * 1024 * 1024, fmt);
            if res_code == MAP_SUCCESS {
                if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
                    session.mark_eof();
                }
            }
            return res_code;
        }

        let res_code = self.open_memory_with_hint(&combined_audio, hint_ext);
        if res_code == MAP_SUCCESS && total_duration_seconds > 0.0 {
            let dur_ms = (total_duration_seconds * 1000.0) as i64;
            self.duration_ms.store(dur_ms, Ordering::SeqCst);
            self.telemetry
                .post_event(EventType::Duration, MapEventData { duration_ms: dur_ms });
        }
        res_code
    }

    #[cfg(target_arch = "wasm32")]
    pub fn open_network(
        &mut self,
        url: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
    ) -> i32 {
        self.open_network_with_cancel(url, headers, None)
    }

    #[cfg(target_arch = "wasm32")]
    pub fn open_network_with_cancel(
        &mut self,
        url: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let _ = self.begin_open();
        self.open_generation.fetch_add(1, Ordering::AcqRel);

        let bytes = match crate::bridge::ffi::wasm_fetch_source_bytes(url, headers) {
            Ok(b) => b,
            Err(code) => return self.mark_open_error(code),
        };
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }

        if crate::hls::M3u8Parser::is_m3u8(&bytes) {
            return self.open_hls_from_m3u8_bytes(url, &bytes, cancel, |seg_url| {
                crate::bridge::ffi::wasm_fetch_source_bytes(seg_url, headers)
            });
        }

        if url.starts_with("icy://") {
            let fmt = infer_network_encoding_format(url, None);
            let res_code = self.open_stream_ex(&bytes, None, -1, true, 4 * 1024 * 1024, fmt);
            if res_code == MAP_SUCCESS {
                if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
                    session.mark_eof();
                }
            }
            return res_code;
        }

        let ext = StreamClassifier::extract_extension_hint(url);
        self.open_memory_with_hint(&bytes, ext)
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn open_hls_network_with_cancel(
        &mut self,
        agent: ureq::Agent,
        url: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
        mut m3u8_bytes: Vec<u8>,
        reader: &mut impl Read,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        crate::map_log!(3, "open_hls_network: url={}", url);
        let _ = reader.read_to_end(&mut m3u8_bytes);
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let parsed = match crate::hls::M3u8Parser::parse(&m3u8_bytes) {
            Ok(p) => p,
            Err(_) => {
                crate::map_log!(1, "open_hls_network failed: invalid m3u8 playlist");
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };

        let (base_media_url, media_playlist) = match parsed {
            crate::hls::ParsedHlsPlaylist::Master { variants } => {
                crate::map_log!(4, "open_hls_network: Master playlist with {} variants", variants.len());
                let Some(first_var) = variants.first() else {
                    crate::map_log!(1, "open_hls_network failed: no variants in master playlist");
                    return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                };
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                let media_url = resolve_hls_uri(url, &first_var.uri);
                let req = apply_http_headers(agent.get(&media_url), headers);
                let Ok(res) = req.call() else {
                    if cancel.is_some_and(|c| c.is_cancelled()) {
                        return self.mark_open_error(MAP_ERROR_ABORTED);
                    }
                    crate::map_log!(1, "open_hls_network failed to fetch media playlist from {}", media_url);
                    return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
                };
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                let mut media_bytes = Vec::new();
                if res.into_body().into_reader().read_to_end(&mut media_bytes).is_err() {
                    return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                }
                match crate::hls::M3u8Parser::parse(&media_bytes) {
                    Ok(p) => (media_url, p),
                    Err(_) => {
                        crate::map_log!(1, "open_hls_network failed: invalid variant media playlist");
                        return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                    }
                }
            }
            media => (url.to_string(), media),
        };

        let crate::hls::ParsedHlsPlaylist::Media {
            is_live,
            segments,
            total_duration_seconds,
            ..
        } = media_playlist
        else {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        };

        crate::map_log!(
            3,
            "open_hls_network: Media playlist parsed (segments={}, is_live={}, duration={:.2}s)",
            segments.len(),
            is_live,
            total_duration_seconds
        );

        if segments.is_empty() {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        }
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }

        let first_seg_url = resolve_hls_uri(&base_media_url, &segments[0].uri);
        let Some((first_audio, seg_fmt)) = fetch_hls_segment_audio(&agent, &first_seg_url, headers)
        else {
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        };
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }

        let res_code = self.open_stream_ex(&first_audio, None, -1, is_live, 4 * 1024 * 1024, seg_fmt);
        if res_code != MAP_SUCCESS {
            return res_code;
        }

        if !is_live && total_duration_seconds > 0.0 {
            let dur_ms = (total_duration_seconds * 1000.0) as i64;
            self.duration_ms.store(dur_ms, Ordering::SeqCst);
            self.telemetry.post_event(
                EventType::Duration,
                MapEventData {
                    duration_ms: dur_ms,
                },
            );
        }

        if is_live && self.is_analysis {
            crate::map_log!(
                3,
                "open_hls_network: livestream detected on analysis deck; skipping background HLS streamer thread for {}",
                url
            );
            return MAP_SUCCESS;
        }

        self.network_streamer_abort.store(true, Ordering::Release);
        let new_abort = Arc::new(AtomicBool::new(false));
        self.network_streamer_abort = new_abort.clone();

        if let Some(session) = read_unpoisoned(&self.stream_session).clone() {
            let remaining_urls: Vec<String> = segments
                .iter()
                .skip(1)
                .map(|s| resolve_hls_uri(&base_media_url, &s.uri))
                .collect();
            let owned_headers: Option<Vec<crate::api::types::RustHttpHeader>> =
                headers.map(|h| h.to_vec());
            let dec_running = self.decoder_running.clone();

            let _ = std::thread::Builder::new()
                .name("miniaudio-hls-streamer".to_string())
                .spawn(move || {
                    for seg_url in remaining_urls {
                        if new_abort.load(Ordering::Relaxed) || !dec_running.load(Ordering::Relaxed)
                        {
                            return;
                        }
                        if let Some((audio_bytes, _)) =
                            fetch_hls_segment_audio(&agent, &seg_url, owned_headers.as_deref())
                        {
                            let mut offset = 0;
                            while offset < audio_bytes.len()
                                && !new_abort.load(Ordering::Relaxed)
                                && dec_running.load(Ordering::Relaxed)
                            {
                                match session.feed_chunk(&audio_bytes[offset..]) {
                                    Ok(written) => offset += written,
                                    Err(crate::buffer::BufferError::Busy) => {
                                        session.wait_for_free_space(
                                            audio_bytes.len() - offset,
                                            Duration::from_millis(250),
                                        );
                                    }
                                    Err(_) => return,
                                }
                            }
                        }
                    }
                    session.mark_eof();
                });
        }

        MAP_SUCCESS
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn open_network(
        &mut self,
        url: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
    ) -> i32 {
        self.open_network_with_cancel(url, headers, None)
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn open_network_with_cancel(
        &mut self,
        url: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let _ = self.begin_open();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        crate::map_log!(3, "open_network: connecting to url={}", url);

        let agent = if cancel.is_some() {
            build_network_probe_agent()
        } else {
            build_network_agent()
        };
        let req = apply_http_headers(agent.get(url), headers).header("Icy-MetaData", "1");

        let res = match req.call() {
            Ok(r) => r,
            Err(ureq::Error::StatusCode(code)) => {
                crate::map_log!(1, "open_network failed: HTTP status {} for {}", code, url);
                let err = if code == 404 {
                    MAP_ERROR_FILE_NOT_FOUND
                } else if code == 401 || code == 403 {
                    MAP_ERROR_ACCESS_DENIED
                } else {
                    MAP_ERROR_DECODE_FAILED
                };
                return self.mark_open_error(err);
            }
            Err(err) => {
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                crate::map_log!(1, "open_network failed: connection error for {}: {}", url, err);
                return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
            }
        };
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }

        let content_length: i64 = response_header_str(&res, "content-length")
            .and_then(|s| s.parse().ok())
            .unwrap_or(-1);
        let content_type = response_header_str(&res, "content-type").map(|s| s.to_string());
        let icy_metaint: usize = response_header_str(&res, "icy-metaint")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let icy_name = response_header_str(&res, "icy-name")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let icy_genre = response_header_str(&res, "icy-genre")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let icy_url = response_header_str(&res, "icy-url")
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let icy_br: Option<u32> =
            response_header_str(&res, "icy-br").and_then(|s| s.trim().parse().ok());

        if icy_metaint > 0
            || icy_name.is_some()
            || icy_genre.is_some()
            || icy_url.is_some()
            || icy_br.is_some()
        {
            let mut guard = write_unpoisoned(&self.icy_metadata);
            *guard = Some(crate::api::types::RustIcyMetadata {
                stream_title: None,
                stream_url: None,
                station_name: icy_name,
                station_genre: icy_genre,
                station_url: icy_url,
                bitrate_kbps: icy_br,
            });
        }

        let encoding_format = infer_network_encoding_format(url, content_type.as_deref());
        crate::map_log!(
            4,
            "open_network response: content_length={}, content_type={:?}, icy_metaint={}",
            content_length,
            content_type,
            icy_metaint
        );

        let session_slot: Arc<Mutex<Option<StreamSession>>> = Arc::new(Mutex::new(None));
        let latest_icy: Arc<Mutex<Option<Vec<u8>>>> = Arc::new(Mutex::new(None));

        let mut reader: Box<dyn Read + Send> = if icy_metaint > 0 {
            Box::new(IcyDemuxReader::new(
                Box::new(res.into_body().into_reader()),
                icy_metaint,
                session_slot.clone(),
                latest_icy.clone(),
                self.icy_metadata.clone(),
            ))
        } else {
            Box::new(res.into_body().into_reader())
        };

        let (initial_data, was_aborted) =
            prefetch_initial_stream_bytes_cancellable(&mut reader, content_length, cancel);
        if was_aborted {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        if initial_data.is_empty() {
            crate::map_log!(1, "open_network failed: empty initial stream bytes from {}", url);
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        }

        if crate::hls::M3u8Parser::is_m3u8(&initial_data) {
            return self.open_hls_network_with_cancel(
                agent,
                url,
                headers,
                initial_data,
                &mut reader,
                cancel,
            );
        }

        let mut tail_data: Option<Vec<u8>> = None;
        let mut forced_audio_end: Option<u64> = None;

        if content_length > 0 && (initial_data.len() as i64) < content_length {
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            let (_status, boundary) =
                StreamClassifier::detect_head_boundary(&initial_data, content_length);
            if boundary.audio_end > 0
                && boundary.audio_end < content_length
                && (content_length - boundary.audio_end) <= 4 * 1024 * 1024
            {
                if let Some(tail) =
                    fetch_range_bytes(&agent, url, headers, boundary.audio_end, content_length - 1)
                {
                    tail_data = Some(tail);
                    forced_audio_end = Some(boundary.audio_end as u64);
                }
            } else if StreamClassifier::container_needs_tail_scan(boundary.container) {
                let floor = boundary.audio_start.max(0);
                let probe_len = 65536i64.min(content_length - floor);
                if probe_len > 0 {
                    let tail_offset = content_length - probe_len;
                    if let Some(probed) =
                        fetch_range_bytes(&agent, url, headers, tail_offset, content_length - 1)
                    {
                        let (_t_status, audio_end) = StreamClassifier::detect_tail_boundary(
                            boundary.container,
                            &probed,
                            tail_offset,
                            content_length,
                            boundary.audio_start,
                        );
                        if audio_end > 0 && audio_end <= content_length && audio_end >= tail_offset {
                            let rel_start = (audio_end - tail_offset) as usize;
                            if rel_start < probed.len() {
                                tail_data = Some(probed[rel_start..].to_vec());
                            } else {
                                tail_data = Some(probed.to_vec());
                            }
                            forced_audio_end = Some(audio_end as u64);
                        }
                    }
                }
            }
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
        }

        let preserved_icy = self.icy_metadata.read().ok().and_then(|g| g.clone());
        let is_live = content_length <= 0;
        let res_code = self.open_stream_ex(
            &initial_data,
            tail_data.as_deref(),
            content_length,
            is_live,
            4 * 1024 * 1024,
            encoding_format,
        );
        if let Ok(mut guard) = self.icy_metadata.write() {
            if guard.is_none() {
                *guard = preserved_icy;
            }
        }
        if res_code != MAP_SUCCESS {
            return res_code;
        }

        if let Some(session) = read_unpoisoned(&self.stream_session).clone() {
            if let Some(ae) = forced_audio_end {
                session.set_audio_end(ae);
                if let Some(ref td) = tail_data {
                    let td_off = if ae < content_length as u64 {
                        ae
                    } else {
                        (content_length - td.len() as i64).max(0) as u64
                    };
                    session.set_tail(td, Some(td_off));
                }
                if let Ok(mut b_guard) = self.boundary_info.write() {
                    if let Some(ref mut b) = *b_guard {
                        b.audio_end = ae as i64;
                    }
                }
            }
            if let Ok(guard) = latest_icy.lock() {
                if let Some(ref icy_bytes) = *guard {
                    session.set_icy_meta(icy_bytes);
                }
            }
            if let Ok(mut slot) = session_slot.lock() {
                *slot = Some(session.clone());
            }

            if is_live && self.is_analysis {
                crate::map_log!(
                    3,
                    "open_network: livestream detected on analysis deck; skipping background network streamer thread for {}",
                    url
                );
                return MAP_SUCCESS;
            }

            self.network_streamer_abort.store(true, Ordering::Release);
            let new_abort = Arc::new(AtomicBool::new(false));
            self.network_streamer_abort = new_abort.clone();

            spawn_network_streamer_thread(
                reader,
                session,
                new_abort,
                self.decoder_running.clone(),
                url.to_string(),
                headers.map(|h| h.to_vec()),
                content_length,
                is_live,
            );
        }

        crate::map_log!(
            3,
            "Network stream opened: {} (content_length={}, is_live={})",
            url,
            content_length,
            is_live
        );

        MAP_SUCCESS
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn extract_seekable_head_and_tail<R: Read + Seek>(
        reader: &mut R,
        total_size: i64,
    ) -> (Vec<u8>, Option<(Vec<u8>, Option<u64>)>, BoundaryInfo) {
        let init_cap = 65536usize.min(total_size.max(0) as usize).max(16);
        let mut initial_buf = vec![0u8; init_cap];
        let _ = reader.seek(SeekFrom::Start(0));
        let mut read_total = 0;
        while read_total < initial_buf.len() {
            match reader.read(&mut initial_buf[read_total..]) {
                Ok(0) => break,
                Ok(n) => read_total += n,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        initial_buf.truncate(read_total);
        if initial_buf.is_empty() {
            return (initial_buf, None, BoundaryInfo::new());
        }

        let (mut status, mut boundary) =
            StreamClassifier::detect_head_boundary(&initial_buf, total_size);
        while status == BoundaryStatus::NeedMore
            && boundary.needed_bytes > initial_buf.len() as i64
            && boundary.needed_bytes <= 16 * 1024 * 1024
        {
            let target_len =
                ((boundary.needed_bytes as usize) + 16384).min(total_size.max(0) as usize);
            if target_len <= initial_buf.len() {
                break;
            }
            let prev_len = initial_buf.len();
            initial_buf.resize(target_len, 0);
            let mut got = 0;
            while prev_len + got < target_len {
                match reader.read(&mut initial_buf[prev_len + got..]) {
                    Ok(0) => break,
                    Ok(n) => got += n,
                    Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            initial_buf.truncate(prev_len + got);
            if got == 0 {
                break;
            }
            let res = StreamClassifier::detect_head_boundary(&initial_buf, total_size);
            status = res.0;
            boundary = res.1;
        }

        let mut tail_out: Option<(Vec<u8>, Option<u64>)> = None;
        if total_size > 0 {
            if boundary.audio_end > 0
                && boundary.audio_end < total_size
                && (total_size - boundary.audio_end) <= 4 * 1024 * 1024
            {
                let tail_off = boundary.audio_end as u64;
                let tail_len = (total_size - boundary.audio_end) as usize;
                if reader.seek(SeekFrom::Start(tail_off)).is_ok() {
                    let mut tbuf = vec![0u8; tail_len];
                    let mut tgot = 0;
                    while tgot < tail_len {
                        match reader.read(&mut tbuf[tgot..]) {
                            Ok(0) => break,
                            Ok(n) => tgot += n,
                            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                            Err(_) => break,
                        }
                    }
                    tbuf.truncate(tgot);
                    if !tbuf.is_empty() {
                        tail_out = Some((tbuf, Some(tail_off)));
                    }
                }
            } else if StreamClassifier::container_needs_tail_scan(boundary.container) {
                let floor = boundary.audio_start.max(0);
                let probe_len = 65536i64.min(total_size - floor);
                if probe_len > 0 {
                    let tail_offset = total_size - probe_len;
                    if reader.seek(SeekFrom::Start(tail_offset as u64)).is_ok() {
                        let mut tbuf = vec![0u8; probe_len as usize];
                        let mut tgot = 0;
                        while tgot < tbuf.len() {
                            match reader.read(&mut tbuf[tgot..]) {
                                Ok(0) => break,
                                Ok(n) => tgot += n,
                                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                                Err(_) => break,
                            }
                        }
                        tbuf.truncate(tgot);
                        let (_ts, audio_end) = StreamClassifier::detect_tail_boundary(
                            boundary.container,
                            &tbuf,
                            tail_offset,
                            total_size,
                            boundary.audio_start,
                        );
                        if audio_end > 0 && audio_end <= total_size && audio_end >= tail_offset {
                            let rel = (audio_end - tail_offset) as usize;
                            if rel < tbuf.len() {
                                tail_out = Some((tbuf[rel..].to_vec(), Some(audio_end as u64)));
                            } else {
                                tail_out = Some((tbuf.clone(), Some(tail_offset as u64)));
                            }
                            boundary.audio_end = audio_end;
                        }
                    }
                }
            }
        }

        (initial_buf, tail_out, boundary)
    }

    pub fn open_file(&mut self, path: &str) -> i32 {
        let _ = self.begin_open();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        crate::map_log!(3, "open_file: path={}", path);

        #[cfg(target_arch = "wasm32")]
        {
            let bytes = match crate::bridge::ffi::wasm_fetch_source_bytes(path, None) {
                Ok(b) => b,
                Err(code) => {
                    crate::map_log!(1, "open_file (wasm) failed for {}: code {}", path, code);
                    return self.mark_open_error(code);
                }
            };
            if crate::hls::M3u8Parser::is_m3u8(&bytes) {
                return self.open_hls_from_m3u8_bytes(path, &bytes, None, |seg_path| {
                    let resolved = resolve_local_source_path(seg_path);
                    crate::bridge::ffi::wasm_fetch_source_bytes(&resolved, None)
                });
            }
            let ext = StreamClassifier::extract_extension_hint(path);
            return self.open_memory_with_hint(&bytes, ext);
        }

        #[cfg(not(target_arch = "wasm32"))]
        {
            if path.to_ascii_lowercase().ends_with(".m3u8") {
                if let Ok(m3u8_bytes) = std::fs::read(path) {
                    if crate::hls::M3u8Parser::is_m3u8(&m3u8_bytes) {
                        return self.open_hls_from_m3u8_bytes(path, &m3u8_bytes, None, |seg_path| {
                            let resolved = resolve_local_source_path(seg_path);
                            std::fs::read(&resolved).map_err(|_| MAP_ERROR_FILE_NOT_FOUND)
                        });
                    }
                }
            }

            let source = match crate::buffer::FileByteSource::open(std::path::Path::new(path)) {
                Ok(s) => s,
                Err(_) => {
                    crate::map_log!(1, "open_file failed: file not found: {}", path);
                    return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
                }
            };

            let file_size = source.size();
            let ext = std::path::Path::new(path)
                .extension()
                .and_then(|e| e.to_str());

            let (initial_buf, tail_data, boundary) = if let Ok(mut f) = File::open(path) {
                Self::extract_seekable_head_and_tail(&mut f, file_size as i64)
            } else {
                (Vec::new(), None, BoundaryInfo::new())
            };

            let effective_hint = boundary.container.hint_extension().or(ext);
            crate::map_log!(
                4,
                "open_file sniffed: container={:?}, effective_hint={:?}, size={}",
                boundary.container,
                effective_hint,
                file_size
            );

            let eng = match SymphoniaEngine::new(source, effective_hint) {
                Ok(e) => e,
                Err(e) => {
                    crate::map_log!(1, "open_file failed: decode error for {}: {:?}", path, e);
                    return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                }
            };

            let session = StreamSession::new(65536, Some(file_size), false);
            let classified_boundary = session.ingest_classified(
                &initial_buf,
                tail_data.as_ref().map(|(v, off)| (v.as_slice(), *off)),
            );
            session.mark_eof();
            *write_unpoisoned(&self.boundary_info) = Some(classified_boundary);
            *write_unpoisoned(&self.stream_session) = Some(session);

            self.init_engine(eng, false, file_size, &initial_buf);
            crate::map_log!(3, "open_file successfully opened: {}", path);
            MAP_SUCCESS
        }
    }

    pub fn open_memory(&mut self, data: &[u8], _take_ownership: bool) -> i32 {
        self.open_memory_with_hint(data, None)
    }

    pub fn open_memory_with_hint(&mut self, data: &[u8], hint_ext: Option<&str>) -> i32 {
        let _ = self.begin_open();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        crate::map_log!(3, "open_memory: size={}, hint={:?}", data.len(), hint_ext);

        let total_size = data.len() as i64;
        let (_status, boundary) = StreamClassifier::detect_head_boundary(data, total_size);
        let effective_hint = boundary.container.hint_extension().or(hint_ext);
        crate::map_log!(
            4,
            "open_memory sniffed: container={:?}, effective_hint={:?}",
            boundary.container,
            effective_hint
        );

        let mem_vec = data.to_vec();
        let cursor = Cursor::new(mem_vec);
        let eng = match SymphoniaEngine::new(cursor, effective_hint) {
            Ok(e) => e,
            Err(e) => {
                crate::map_log!(1, "open_memory failed: decode error: {:?}", e);
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };

        let head_keep = if boundary.audio_start > 0 {
            ((boundary.audio_start as usize) + 16384).min(data.len())
        } else {
            data.len().min(65536)
        };
        let mut tail_slice: Option<(&[u8], Option<u64>)> = None;
        if total_size > 0 {
            if boundary.audio_end > 0
                && boundary.audio_end < total_size
                && (total_size - boundary.audio_end) <= 4 * 1024 * 1024
            {
                let off = boundary.audio_end as usize;
                tail_slice = Some((&data[off..], Some(off as u64)));
            } else if StreamClassifier::container_needs_tail_scan(boundary.container) {
                let floor = boundary.audio_start.max(0);
                let probe_len = 65536i64.min(total_size - floor);
                if probe_len > 0 {
                    let tail_offset = total_size - probe_len;
                    let (_ts, audio_end) = StreamClassifier::detect_tail_boundary(
                        boundary.container,
                        &data[tail_offset as usize..],
                        tail_offset,
                        total_size,
                        boundary.audio_start,
                    );
                    if audio_end > 0 && audio_end <= total_size && audio_end >= tail_offset {
                        let rel = (audio_end - tail_offset) as usize;
                        if rel < data[tail_offset as usize..].len() {
                            tail_slice = Some((&data[audio_end as usize..], Some(audio_end as u64)));
                        } else {
                            tail_slice = Some((&data[tail_offset as usize..], Some(tail_offset as u64)));
                        }
                    }
                }
            }
        }

        let session = StreamSession::new(65536, Some(data.len() as u64), false);
        let classified_boundary = session.ingest_classified(&data[..head_keep], tail_slice);
        session.mark_eof();
        *write_unpoisoned(&self.boundary_info) = Some(classified_boundary);
        *write_unpoisoned(&self.stream_session) = Some(session);

        self.init_engine(eng, false, data.len() as u64, data);
        crate::map_log!(3, "open_memory successfully opened: size={}", data.len());
        MAP_SUCCESS
    }

    pub fn open_stream_ex(
        &mut self,
        initial_data: &[u8],
        tail_data: Option<&[u8]>,
        total_size: i64,
        is_live: bool,
        buffer_capacity_bytes: usize,
        encoding_format: i32,
    ) -> i32 {
        let _ = self.begin_open();

        let cap = if buffer_capacity_bytes > 0 {
            buffer_capacity_bytes
        } else {
            StreamSession::DEFAULT_RING_CAPACITY
        };
        crate::map_log!(
            3,
            "open_stream_ex: initial_bytes={}, total_size={}, is_live={}, ring_cap={}",
            initial_data.len(),
            total_size,
            is_live,
            cap
        );

        let tot = if total_size > 0 {
            Some(total_size as u64)
        } else {
            None
        };
        let session = StreamSession::new(cap, tot, is_live);

        let boundary = session.ingest_classified(initial_data, tail_data.map(|t| (t, None)));
        let container = boundary.container;
        if !initial_data.is_empty() {
            *write_unpoisoned(&self.boundary_info) = Some(boundary);
        }

        let hint = container
            .hint_extension()
            .or_else(|| encoding_format_to_extension(encoding_format));

        let reader = session.create_reader();
        let eng = match SymphoniaEngine::new(reader, hint) {
            Ok(e) => e,
            Err(e) => {
                crate::map_log!(1, "open_stream_ex failed: SymphoniaEngine::new failed for hint={:?}: {:?}", hint, e);
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };
        session.set_decoding_audio(true);

        let tot = session.total_size().unwrap_or(0);
        *write_unpoisoned(&self.stream_session) = Some(session);
        self.init_engine(eng, true, tot, initial_data);
        crate::map_log!(3, "open_stream_ex successfully opened (hint={:?})", hint);
        MAP_SUCCESS
    }

    pub fn open_custom_source(
        &mut self,
        source: CustomDartByteSource,
        handle: CustomByteSourceHandle,
        total_size: Option<u64>,
        is_seekable: bool,
    ) -> i32 {
        self.open_custom_source_with_cancel(source, handle, total_size, is_seekable, None)
    }

    pub fn open_custom_source_with_cancel(
        &mut self,
        source: CustomDartByteSource,
        handle: CustomByteSourceHandle,
        total_size: Option<u64>,
        is_seekable: bool,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            handle.abort();
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let _ = self.begin_open();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        crate::map_log!(
            3,
            "open_custom_source: total_size={:?}, is_seekable={}",
            total_size,
            is_seekable
        );

        let abort_handle = handle.clone();
        *write_unpoisoned(&self.custom_source_handle) = Some(handle);
        let _cancel_guard = cancel.map(|c| {
            let h = abort_handle.clone();
            c.on_cancel(move || h.abort())
        });

        let eng = match SymphoniaEngine::new(source, None) {
            Ok(e) => e,
            Err(e) => {
                drop(_cancel_guard);
                *write_unpoisoned(&self.custom_source_handle) = None;
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                crate::map_log!(1, "open_custom_source failed: SymphoniaEngine::new failed: {:?}", e);
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };
        drop(_cancel_guard);
        if cancel.is_some_and(|c| c.is_cancelled()) {
            abort_handle.abort();
            *write_unpoisoned(&self.custom_source_handle) = None;
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }

        self.init_engine(eng, !is_seekable, total_size.unwrap_or(0), &[]);
        crate::map_log!(3, "open_custom_source successfully opened");
        MAP_SUCCESS
    }

    pub fn supply_custom_bytes(
        &self,
        _stream_id: u32,
        request_id: u64,
        data: Vec<u8>,
        is_eof: bool,
    ) -> i32 {
        if let Some(ref handle) = *read_unpoisoned(&self.custom_source_handle) {
            handle.supply_bytes(request_id, data, is_eof);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn notify_custom_error(
        &self,
        _stream_id: u32,
        request_id: u64,
        error_message: String,
    ) -> i32 {
        if let Some(ref handle) = *read_unpoisoned(&self.custom_source_handle) {
            handle.notify_error(request_id, error_message);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    fn init_engine(
        &mut self,
        eng: SymphoniaEngine,
        is_stream: bool,
        total_bytes: u64,
        initial_data: &[u8],
    ) {
        let is_live = self.is_live_stream();
        let sr = eng.sample_rate();
        let raw_sr = eng.raw_sample_rate().unwrap_or(sr);
        let ch = eng.channels();
        let bps = eng.bits_per_sample().unwrap_or(0);
        let codec_str = eng.codec();
        let container_str = eng.container_format();
        let is_lossless = eng.lossless();
        let sym_meta = eng.symphonia_meta().clone();

        let mut dur = if is_live {
            0
        } else {
            eng.duration_ms().unwrap_or(0) as i64
        };

        if !is_live && dur <= 0 {
            if let Ok(guard) = self.stream_session.read() {
                if let Some(ref session) = *guard {
                    let tail = session.tail_data();
                    if !tail.is_empty() {
                        if let Ok(b_guard) = self.boundary_info.read() {
                            if let Some(boundary) = *b_guard {
                                if let Some(d) = StreamClassifier::extract_tail_duration_ms(
                                    boundary.container,
                                    sr,
                                    &tail,
                                ) {
                                    dur = d;
                                }
                            }
                        }
                    }
                }
            }
        }

        let mut sniffed_bitrate: Option<u32> = None;
        if !initial_data.is_empty() {
            if let Some((br, d)) =
                StreamClassifier::sniff_stream_info(initial_data, total_bytes as i64)
            {
                if br > 0 {
                    sniffed_bitrate = Some(br);
                }
                if !is_live && dur <= 0 && d > 0 {
                    dur = d;
                }
            }
        }

        let boundary = if !initial_data.is_empty() {
            StreamClassifier::detect_head_boundary(initial_data, total_bytes as i64).1
        } else {
            BoundaryInfo::new()
        };

        // Compute audio payload size (excluding huge ID3v2/FLAC cover art headers) for accurate bitrate
        let audio_payload_bytes = if total_bytes > 0 {
            let start = boundary.audio_start.max(0) as u64;
            let end = if boundary.audio_end > 0 && (boundary.audio_end as u64) <= total_bytes {
                boundary.audio_end as u64
            } else {
                total_bytes
            };
            if end > start {
                end - start
            } else {
                total_bytes
            }
        } else {
            0
        };

        let icy_br_bps = self
            .icy_metadata
            .read()
            .ok()
            .and_then(|g| g.as_ref().and_then(|m| m.bitrate_kbps.map(|kb| kb * 1000)));

        let bitrate = if codec_str == "PCM" && sr > 0 && ch > 0 && bps > 0 {
            sr * ch * bps
        } else if codec_str == "DSD" && raw_sr > 0 && ch > 0 {
            raw_sr * ch
        } else if dur > 0 && audio_payload_bytes > 0 {
            ((audio_payload_bytes * 8000) / dur as u64) as u32
        } else if let Some(br) = icy_br_bps.or(sniffed_bitrate) {
            br
        } else if sr > 0 && ch > 0 {
            sr * ch * bps.max(16)
        } else {
            0
        };

        let br_mode = StreamClassifier::detect_bitrate_mode(
            initial_data,
            boundary.container,
            codec_str,
            is_lossless,
        );
        let br_mode_code = match br_mode {
            crate::api::types::RustBitrateMode::Unknown => 0,
            crate::api::types::RustBitrateMode::Cbr => 1,
            crate::api::types::RustBitrateMode::Vbr => 2,
        };

        {
            if let Ok(mut fmt_guard) = self.format.write() {
                *fmt_guard = boundary
                    .container
                    .hint_extension()
                    .map(|s| s.to_string())
                    .or_else(|| {
                        if !container_str.is_empty() && container_str != "Unknown" {
                            Some(container_str.to_ascii_lowercase())
                        } else if !codec_str.is_empty() && codec_str != "Unknown" {
                            Some(codec_str.to_ascii_lowercase())
                        } else {
                            None
                        }
                    });
            }
            if let Ok(mut c_guard) = self.codec.write() {
                *c_guard = codec_str.to_string();
            }
            if let Ok(mut cf_guard) = self.container_format.write() {
                *cf_guard = container_str.to_string();
            }
            if let Ok(mut sm_guard) = self.symphonia_meta.write() {
                *sm_guard = sym_meta;
            }
            if let Ok(mut cm_guard) = self.cached_metadata.lock() {
                *cm_guard = None;
            }

            let mut eng_lock = lock_unpoisoned(&self.engine);
            *eng_lock = Some(eng);
            self.engine_loaded.store(true, Ordering::Release);
            self.sample_rate.store(sr, Ordering::SeqCst);
            self.raw_sample_rate.store(raw_sr, Ordering::SeqCst);
            self.channels.store(ch, Ordering::SeqCst);
            self.bits_per_sample.store(bps, Ordering::SeqCst);
            self.lossless.store(is_lossless, Ordering::SeqCst);
            self.bitrate_mode.store(br_mode_code, Ordering::SeqCst);
            self.file_size.store(total_bytes, Ordering::SeqCst);
            self.duration_ms.store(dur, Ordering::SeqCst);
            self.bitrate.store(bitrate, Ordering::SeqCst);
            self.is_stream.store(is_stream, Ordering::SeqCst);
            self.at_live_edge.store(is_live, Ordering::SeqCst);
            if let Ok(guard) = self.stream_session.read() {
                if let Some(ref session) = *guard {
                    let cur_rate = f32::from_bits(self.rate.load(Ordering::Relaxed));
                    session.configure_stream_timing(bitrate, dur, cur_rate);
                }
            }
            self.decoder_eof.store(false, Ordering::SeqCst);
            self.position_ms.store(0, Ordering::SeqCst);
            self.position_frames.store(0, Ordering::SeqCst);
            self.flush_generation.fetch_add(1, Ordering::SeqCst);
        }
        self.acknowledge_renderer_flush();

        self.send_dsp_command(DspCommand::SetSampleRate(
            self.device_sample_rate.load(Ordering::Relaxed),
        ));

        self.state.store(STATE_STOPPED, Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::Duration, MapEventData { duration_ms: dur });
        self.telemetry
            .post_event(EventType::Bitrate, MapEventData { bitrate });
        let mut br = MiniaudioBufferedRange::default();
        if self.get_buffered_range(&mut br) == MAP_SUCCESS {
            self.telemetry.post_event(
                EventType::BufferedRange,
                MapEventData {
                    buffered_range: crate::sync::telemetry::BufferedRange {
                        start_ms: br.start_ms,
                        end_ms: br.end_ms,
                        is_buffering: br.is_buffering,
                    },
                },
            );
        }
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_STOPPED,
            },
        );

        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();
    }

    #[inline]
    pub fn is_analysis(&self) -> bool {
        self.is_analysis
    }

    pub fn is_live_stream(&self) -> bool {
        if self
            .stream_session
            .read()
            .map(|g| g.as_ref().map(|s| s.is_live()).unwrap_or(false))
            .unwrap_or(false)
        {
            return true;
        }
        self.is_stream.load(Ordering::Acquire) && self.duration_ms.load(Ordering::Acquire) <= 0
    }

    pub fn stream_feed(&mut self, data: &[u8]) -> i32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            match session.feed_chunk(data) {
                Ok(_) => {
                    let (_, cvar) = &*self.decoder_wake;
                    cvar.notify_all();
                    MAP_SUCCESS
                }
                Err(crate::buffer::BufferError::Busy) => MAP_ERROR_BUSY,
                Err(_) => MAP_ERROR_GENERIC,
            }
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_flush(&mut self, new_stream_offset: i64) -> i32 {
        let session_opt = read_unpoisoned(&self.stream_session).clone();
        if let Some(session) = session_opt {
            session.flush(new_stream_offset as u64);
            self.decoder_eof.store(false, Ordering::Relaxed);
            self.flush_generation.fetch_add(1, Ordering::Release);
            self.acknowledge_renderer_flush();
            if session.is_live() {
                self.stream_reinit_needed.store(true, Ordering::Release);
            }
            let (_, cvar) = &*self.decoder_wake;
            cvar.notify_all();
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    #[inline]
    fn enqueue_seek(&self, position_ms: i64) {
        let clamped = (position_ms.max(0) as u64) & 0xFF_FFFF_FFFF;
        let mut gen = self.seek_counter.fetch_add(1, Ordering::AcqRel) & 0xFF_FFFF;
        if gen == 0 {
            gen = (self.seek_counter.fetch_add(1, Ordering::AcqRel) & 0xFF_FFFF).max(1);
        }
        self.seek_request_ms.store(gen as i64, Ordering::Release);
        let packed = (gen << 40) | clamped;
        self.seek_packed.store(packed, Ordering::Release);
    }

    #[inline]
    fn clear_pending_seek(&self) {
        self.seek_packed.store(0, Ordering::Release);
        self.seek_request_ms.store(-1, Ordering::Release);
    }

    fn complete_at_duration(&mut self, dur: i64) {
        self.decoder_eof.store(true, Ordering::Relaxed);
        self.track_exhausted.store(true, Ordering::Release);
        self.position_ms.store(dur, Ordering::Relaxed);
        let dev_sr = self.device_sample_rate.load(Ordering::Relaxed).max(8000) as i64;
        self.position_frames.store(
            if dev_sr > 0 {
                (dur * dev_sr * 1024) / 1000
            } else {
                0
            },
            Ordering::Relaxed,
        );
        self.clear_pending_seek();
        self.flush_generation.fetch_add(1, Ordering::Release);
        self.acknowledge_renderer_flush();

        self.telemetry
            .post_event(EventType::Position, MapEventData { position_ms: dur });
    }

    fn dispatch_seek_to_decoder(&mut self, position_ms: i64) {
        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur > 0 && position_ms >= dur {
            self.complete_at_duration(dur);
            return;
        }

        self.decoder_eof.store(false, Ordering::Relaxed);
        self.track_exhausted.store(false, Ordering::Release);
        self.flush_generation.fetch_add(1, Ordering::Release);
        self.acknowledge_renderer_flush();

        self.position_ms.store(position_ms, Ordering::Relaxed);
        let dev_sr = self.device_sample_rate.load(Ordering::Relaxed).max(8000) as i64;
        self.position_frames.store(
            if dev_sr > 0 {
                (position_ms * dev_sr * 1024) / 1000
            } else {
                0
            },
            Ordering::Relaxed,
        );
        self.telemetry
            .post_event(EventType::Position, MapEventData { position_ms });

        self.enqueue_seek(position_ms);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();
    }

    pub fn stream_seek(&mut self, position_ms: i64, new_stream_offset: i64) -> i32 {
        let (is_hit, is_contiguous) = {
            if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
                session.try_seek_cached(new_stream_offset as u64)
            } else {
                return MAP_ERROR_INVALID_STATE;
            }
        };

        let code = if is_hit {
            if is_contiguous {
                MAP_STREAM_SEEK_CACHE_HIT
            } else {
                MAP_STREAM_SEEK_CACHE_HIT_PREFETCH
            }
        } else {
            let _ = self.stream_flush(new_stream_offset);
            MAP_STREAM_SEEK_CACHE_MISS
        };

        self.dispatch_seek_to_decoder(position_ms);
        code
    }

    pub fn stream_end(&mut self) -> i32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.mark_eof();
            let (_, cvar) = &*self.decoder_wake;
            cvar.notify_all();
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_get_status(&self, out_status: &mut MiniaudioStreamStatus) -> i32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            let r = session.get_range();
            let cap = session.ring_capacity();
            out_status.buffer_capacity = cap;
            out_status.buffer_fill = (r.end_byte.saturating_sub(r.start_byte)).max(0) as usize;
            out_status.fill_percentage = r.fill_percentage * 100.0;
            out_status.is_buffering =
                self.is_buffering.load(Ordering::Relaxed) as i32;
            out_status.is_eof = r.is_eof;
            out_status.read_cursor_byte = r.read_cursor_byte;
            out_status.range_start = r.start_byte;
            out_status.range_end = r.end_byte;
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn get_buffered_range(&self, out_range: &mut MiniaudioBufferedRange) -> i32 {
        let duration = self.duration_ms.load(Ordering::Relaxed);
        if self.is_stream.load(Ordering::Relaxed) {
            if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
                let r = session.get_range();
                out_range.start_ms = 0;
                if r.total_bytes > 0 && duration > 0 {
                    out_range.end_ms =
                        ((r.end_byte as f64 / r.total_bytes as f64) * duration as f64) as i64;
                } else {
                    out_range.end_ms = 0;
                }
                out_range.is_buffering =
                    self.is_buffering.load(Ordering::Relaxed) as i32;
                return MAP_SUCCESS;
            }
        }
        out_range.start_ms = 0;
        out_range.end_ms = duration.max(0);
        out_range.is_buffering = 0;
        MAP_SUCCESS
    }

    pub fn stream_get_seek_byte(&self, position_ms: i64) -> i64 {
        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur <= 0 {
            return -1;
        }
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            if let Some(tot) = session.total_size() {
                let start = session.audio_start() as i64;
                let audio_len = (tot as i64) - start;
                let raw_byte = start + ((position_ms * audio_len) / dur);

                let headroom = 8192;
                let seek_byte = if position_ms > 0 {
                    (raw_byte - headroom).max(start)
                } else {
                    start
                };
                return (seek_byte / 4) * 4;
            }
        }
        -1
    }

    pub fn get_audio_data_offset(&self) -> i64 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.audio_start() as i64
        } else {
            0
        }
    }

    pub fn stream_get_pinned_head_size(&self) -> i64 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.head_size() as i64
        } else {
            0
        }
    }

    pub fn get_meta_bytes_version(&self) -> u32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.meta_version()
        } else {
            0
        }
    }

    pub fn get_meta_bytes_size(&self) -> usize {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.get_meta_bytes().len()
        } else {
            0
        }
    }

    pub fn get_meta_bytes(&self) -> Option<Vec<u8>> {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            let bytes = session.get_meta_bytes();
            if !bytes.is_empty() {
                return Some(bytes);
            }
        }
        None
    }

    /// Returns a zero-cost snapshot of the current track's [`RustAudioInfo`].
    pub fn get_audio_info(&self) -> crate::api::types::RustAudioInfo {
        let dur_ms = self.duration_ms.load(Ordering::Relaxed);
        let sr = self.sample_rate.load(Ordering::Relaxed);
        let raw_sr = self.raw_sample_rate.load(Ordering::Relaxed);
        let ch = self.channels.load(Ordering::Relaxed);
        let bps = self.bits_per_sample.load(Ordering::Relaxed);
        let br = self.bitrate.load(Ordering::Relaxed);
        let lossless = self.lossless.load(Ordering::Relaxed);
        let br_mode_code = self.bitrate_mode.load(Ordering::Relaxed);
        let fsize = self.file_size.load(Ordering::Relaxed);

        let bitrate_mode = match br_mode_code {
            1 => crate::api::types::RustBitrateMode::Cbr,
            2 => crate::api::types::RustBitrateMode::Vbr,
            _ => crate::api::types::RustBitrateMode::Unknown,
        };

        let format = self.format.read().ok().and_then(|g| g.clone());
        let codec = self
            .codec
            .read()
            .ok()
            .map(|g| g.clone())
            .unwrap_or_else(|| String::from("Unknown"));
        let container_format = self
            .container_format
            .read()
            .ok()
            .map(|g| g.clone())
            .unwrap_or_else(|| String::from("Unknown"));

        crate::api::types::RustAudioInfo {
            duration_ms: if dur_ms > 0 { Some(dur_ms) } else { None },
            sample_rate: sr,
            raw_sample_rate: if raw_sr > 0 { Some(raw_sr) } else { None },
            channels: ch,
            bits_per_sample: if bps > 0 { Some(bps) } else { None },
            bitrate: br,
            format,
            codec,
            container_format,
            lossless,
            bitrate_mode,
            file_size: if fsize > 0 { Some(fsize) } else { None },
        }
    }

    /// Parses and caches the full [`RustAudioMetadata`] for the currently opened source.
    ///
    /// Invoked only when `metadata` is explicitly requested (`analyzeAudio(metadata: true)` or
    /// `player.state.metadataEnabled == true`). Subsequent calls with the same `(flush_generation, meta_version)`
    /// return the cached clone in O(1).
    pub fn get_parsed_metadata(&self) -> Option<crate::api::types::RustAudioMetadata> {
        let cur_flush = self.flush_generation.load(Ordering::Acquire);
        let cur_meta_ver = self.get_meta_bytes_version();

        if let Ok(guard) = self.cached_metadata.lock() {
            if let Some((cached_flush, cached_ver, ref cached_meta)) = *guard {
                if cached_flush == cur_flush && cached_ver == cur_meta_ver {
                    return if cached_meta.bytes.is_empty() && !Self::has_any_parsed_fields(cached_meta) {
                        None
                    } else {
                        Some(cached_meta.clone())
                    };
                }
            }
        }

        let container_format = self
            .container_format
            .read()
            .ok()
            .map(|g| g.clone())
            .unwrap_or_default();
        let sym_meta = self.symphonia_meta.read().ok().map(|g| g.clone());
        let icy_meta = self.icy_metadata.read().ok().and_then(|g| g.clone());
        let meta_buf = self
            .stream_session
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|s| s.metadata.clone()))
            .unwrap_or_else(|| StreamBuffer::new_sparse(0, 4096, None));

        let parsed = crate::metadata::UniversalMetadataExtractor::extract(
            &meta_buf,
            &container_format,
            sym_meta.as_ref(),
            icy_meta,
        );

        let is_non_empty = !parsed.bytes.is_empty() || Self::has_any_parsed_fields(&parsed);
        if let Ok(mut guard) = self.cached_metadata.lock() {
            *guard = Some((cur_flush, cur_meta_ver, parsed.clone()));
        }

        if is_non_empty {
            Some(parsed)
        } else {
            None
        }
    }

    fn has_any_parsed_fields(m: &crate::api::types::RustAudioMetadata) -> bool {
        m.title.is_some()
            || m.track_artist.is_some()
            || m.album.is_some()
            || m.album_artist.is_some()
            || m.year.is_some()
            || m.genre.is_some()
            || m.track_number.is_some()
            || m.disc_number.is_some()
            || m.lyrics.is_some()
            || m.comment.is_some()
            || m.bpm.is_some()
            || m.replay_gain_track_gain.is_some()
            || m.replay_gain_album_gain.is_some()
            || !m.pictures.is_empty()
            || !m.chapters.is_empty()
            || !m.custom_tags.is_empty()
            || !m.tag_formats.is_empty()
            || m.icy.is_some()
    }

    pub fn copy_meta_bytes(&self, out: &mut [u8]) -> usize {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.copy_meta_bytes(out)
        } else {
            0
        }
    }

    pub fn set_icy_meta(&mut self, data: &[u8]) -> i32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.set_icy_meta(data);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn probe_tail(&mut self, tail_data: &[u8], tail_offset: i64) -> i32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.set_tail(tail_data, Some(tail_offset as u64));
            if self.duration_ms.load(Ordering::Relaxed) <= 0 {
                let sr = self.sample_rate.load(Ordering::Relaxed);
                if let Ok(b_guard) = self.boundary_info.read() {
                    if let Some(boundary) = *b_guard {
                        if let Some(dur) = StreamClassifier::extract_tail_duration_ms(
                            boundary.container,
                            sr,
                            tail_data,
                        ) {
                            self.duration_ms.store(dur, Ordering::Relaxed);
                            self.telemetry
                                .post_event(EventType::Duration, MapEventData { duration_ms: dur });
                        }
                    }
                }
            }
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }


    pub fn play(&mut self) -> i32 {
        let cur = self.state.load(Ordering::Relaxed);
        crate::map_log!(3, "play() called (current_state={})", cur);

        if let Ok(guard) = self.stream_session.read() {
            if let Some(ref session) = *guard {
                session.clear_abort();
            }
        }
        self.decoder_eof.store(false, Ordering::Relaxed);
        self.track_exhausted.store(false, Ordering::Release);

        self.state.store(STATE_PLAYING, Ordering::Release);
        self.telemetry
            .post_event(EventType::IsPlaying, MapEventData { is_playing: 1 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_PLAYING,
            },
        );

        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        MAP_SUCCESS
    }

    pub fn pause(&mut self) -> i32 {
        let cur = self.state.load(Ordering::Relaxed);
        crate::map_log!(3, "pause() called (current_state={})", cur);

        self.state.store(STATE_PAUSED, Ordering::Release);
        self.telemetry
            .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_PAUSED,
            },
        );

        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        MAP_SUCCESS
    }

    pub fn stop(&mut self) -> i32 {
        crate::map_log!(3, "stop() called");

        self.network_streamer_abort.store(true, Ordering::Release);
        self.decoder_eof.store(false, Ordering::Relaxed);
        self.is_buffering.store(false, Ordering::Release);
        self.track_exhausted.store(false, Ordering::Release);
        if let Ok(guard) = self.stream_session.read() {
            if let Some(ref session) = *guard {
                session.abort();
                if session.is_live() {
                    self.stream_reinit_needed.store(true, Ordering::Release);
                }
            }
        }
        if let Some(ref handle) = *read_unpoisoned(&self.custom_source_handle) {
            handle.abort();
        }
        self.flush_generation.fetch_add(1, Ordering::Release);
        self.acknowledge_renderer_flush();

        self.state.store(STATE_STOPPED, Ordering::Release);
        self.position_ms.store(0, Ordering::Relaxed);
        self.position_frames.store(0, Ordering::Relaxed);
        self.silence_saved_ms.store(0, Ordering::Relaxed);
        if !self.is_stream.load(Ordering::Relaxed) && self.engine_loaded.load(Ordering::Acquire) {
            self.enqueue_seek(0);
        } else {
            self.clear_pending_seek();
        }
        self.telemetry.post_event(
            EventType::SilenceSaved,
            MapEventData {
                silence_saved_ms: 0,
            },
        );
        self.telemetry
            .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
        self.telemetry
            .post_event(EventType::IsBuffering, MapEventData { is_buffering: 0 });
        self.telemetry
            .post_event(EventType::Position, MapEventData { position_ms: 0 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_STOPPED,
            },
        );

        MAP_SUCCESS
    }

    /// Case 2 termination: track reached end, stopping streamer/buffer while keeping seek position.
    pub fn finish_at_end(&mut self) {
        crate::map_log!(3, "finish_at_end() called");
        self.network_streamer_abort.store(true, Ordering::Release);
        if let Ok(guard) = self.stream_session.read() {
            if let Some(ref session) = *guard {
                session.abort();
            }
        }
        self.is_buffering.store(false, Ordering::Release);
        self.track_exhausted.store(true, Ordering::Release);
        self.state.store(STATE_STOPPED, Ordering::Release);

        self.telemetry
            .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
        self.telemetry
            .post_event(EventType::IsBuffering, MapEventData { is_buffering: 0 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_STOPPED,
            },
        );
    }

    pub fn seek(&mut self, position_ms: i64) -> i32 {
        crate::map_log!(4, "seek(position_ms={})", position_ms);
        if self.is_live_stream() {
            return MAP_SUCCESS;
        }

        self.dispatch_seek_to_decoder(position_ms);
        MAP_SUCCESS
    }

    pub fn set_volume(&mut self, volume: f32) -> i32 {
        let vol = volume.max(0.0);
        crate::map_log!(4, "set_volume(volume={})", vol);
        self.volume.store(vol.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetVolume(vol));
        self.telemetry
            .post_event(EventType::Volume, MapEventData { volume: vol });
        MAP_SUCCESS
    }

    pub fn set_rate(&mut self, rate: f32) -> i32 {
        if !rate.is_finite() || rate <= 0.0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        crate::map_log!(4, "set_rate(rate={})", rate);
        self.rate.store(rate.to_bits(), Ordering::Relaxed);
        if let Ok(guard) = self.stream_session.read() {
            if let Some(ref session) = *guard {
                session.set_playback_rate(rate);
            }
        }
        self.telemetry
            .post_event(EventType::Rate, MapEventData { rate });
        MAP_SUCCESS
    }

    pub fn set_pitch(&mut self, pitch: f32) -> i32 {
        if !pitch.is_finite() || pitch <= 0.0 {
            return MAP_ERROR_INVALID_ARGS;
        }
        crate::map_log!(4, "set_pitch(pitch={})", pitch);
        self.pitch.store(pitch.to_bits(), Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::Pitch, MapEventData { pitch });
        MAP_SUCCESS
    }

    pub fn set_buffer_size(&mut self, frames: u32) -> i32 {
        crate::map_log!(4, "set_buffer_size(frames={})", frames);
        self.period_size_in_frames.store(frames, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::BufferSize,
            MapEventData {
                buffer_size: frames,
            },
        );
        MAP_SUCCESS
    }

    pub fn get_buffer_size(&self) -> u32 {
        self.period_size_in_frames.load(Ordering::Relaxed)
    }


    pub fn set_pause_on_device_change(&mut self, enabled: i32) -> i32 {
        crate::map_log!(4, "set_pause_on_device_change(enabled={})", enabled != 0);
        self.pause_on_device_change
            .store(enabled != 0, Ordering::Relaxed);
        MAP_SUCCESS
    }

    pub fn get_pause_on_device_change(&self) -> i32 {
        self.pause_on_device_change.load(Ordering::Relaxed) as i32
    }

    pub fn set_equalizer(&mut self, params: &EqualizerParams) -> i32 {
        crate::map_log!(4, "set_equalizer updated");
        self.eq_params = *params;
        self.send_dsp_command(DspCommand::SetEqualizerParams(*params));
        self.telemetry
            .post_event(EventType::Equalizer, MapEventData { equalizer: *params });
        MAP_SUCCESS
    }

    pub fn set_equalizer_band(&mut self, band: u32, gain_db: f32) -> i32 {
        crate::map_log!(4, "set_equalizer_band(band={}, gain_db={})", band, gain_db);
        self.eq_params.set_band(band as usize, gain_db);
        self.send_dsp_command(DspCommand::SetEqualizerBand {
            band: band as usize,
            gain_db,
        });
        MAP_SUCCESS
    }

    pub fn get_equalizer(&self, out: &mut EqualizerParams) -> i32 {
        *out = self.eq_params;
        MAP_SUCCESS
    }

    pub fn set_replay_gain(&mut self, gain_db: f32, peak: f32, prevent_clipping: i32) -> i32 {
        crate::map_log!(
            4,
            "set_replay_gain(gain_db={}, peak={}, prevent_clipping={})",
            gain_db,
            peak,
            prevent_clipping != 0
        );
        let rg = ReplayGainConfig {
            gain_db,
            peak,
            prevent_clipping,
            enabled: 1,
        };
        self.replay_gain = rg;
        self.send_dsp_command(DspCommand::SetReplayGain(rg));
        self.telemetry
            .post_event(EventType::ReplayGain, MapEventData { replay_gain: rg });
        MAP_SUCCESS
    }

    pub fn clear_replay_gain(&mut self) -> i32 {
        crate::map_log!(4, "clear_replay_gain()");
        let rg = ReplayGainConfig::default();
        self.replay_gain = rg;
        self.send_dsp_command(DspCommand::SetReplayGain(rg));
        self.telemetry
            .post_event(EventType::ReplayGain, MapEventData { replay_gain: rg });
        MAP_SUCCESS
    }

    /// Updates this deck's cached ReplayGain config and pushes it to the RT renderer
    /// without mutating telemetry or neighboring decks.
    pub fn apply_replay_gain_config_silent(&mut self, rg: ReplayGainConfig) {
        if self.replay_gain != rg {
            self.replay_gain = rg;
            self.send_dsp_command(DspCommand::SetReplayGain(rg));
        }
    }

    /// Records the queue item identity and per-track ReplayGain metadata loaded on this deck.
    #[inline]
    pub fn set_queue_item_assignment(&mut self, item: &AudioSourceCore) {
        self.queue_item_id = Some(item.id);
        self.track_replay_gain = (item.replay_gain_db, item.replay_peak);
    }

    /// Clears the loaded queue item association and disables per-deck ReplayGain.
    #[inline]
    pub fn clear_queue_item_assignment(&mut self) {
        self.queue_item_id = None;
        self.track_replay_gain = (None, None);
        self.apply_replay_gain_config_silent(ReplayGainConfig::default());
    }

    pub fn set_preamp(&mut self, preamp_db: f32) -> i32 {
        crate::map_log!(4, "set_preamp(preamp_db={})", preamp_db);
        self.preamp_db.store(preamp_db.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetPreamp(preamp_db));
        self.telemetry
            .post_event(EventType::Preamp, MapEventData { preamp_db });
        MAP_SUCCESS
    }

    pub fn set_balance(&mut self, pan: f32) -> i32 {
        crate::map_log!(4, "set_balance(pan={})", pan);
        self.balance.store(pan.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetBalance(pan));
        self.telemetry
            .post_event(EventType::Balance, MapEventData { balance: pan });
        MAP_SUCCESS
    }

    pub fn set_mono(&mut self, enabled: i32) -> i32 {
        crate::map_log!(4, "set_mono(enabled={})", enabled != 0);
        let mono = enabled != 0;
        self.mono_enabled.store(mono, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetMono(mono));
        self.telemetry.post_event(
            EventType::Mono,
            MapEventData {
                mono_enabled: enabled,
            },
        );
        MAP_SUCCESS
    }

    pub fn set_crossfeed(&mut self, config: CrossfeedConfig) -> i32 {
        crate::map_log!(
            4,
            "set_crossfeed(enabled={}, cutoff={}, feed={})",
            config.enabled,
            config.cutoff_hz,
            config.feed_db
        );
        self.crossfeed_config = config;
        self.send_dsp_command(DspCommand::SetCrossfeed(config));
        self.telemetry.post_event(
            EventType::Crossfeed,
            MapEventData {
                crossfeed: config,
            },
        );
        MAP_SUCCESS
    }

    pub fn set_spatializer(&mut self, enabled: i32, width: f32) -> i32 {
        crate::map_log!(4, "set_spatializer(enabled={}, width={})", enabled != 0, width);
        let en = enabled != 0;
        self.spatializer_enabled.store(en, Ordering::Relaxed);
        self.spatializer_width
            .store(width.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetSpatializer { enabled: en, width });
        self.telemetry.post_event(
            EventType::Spatializer,
            MapEventData {
                spatializer: SpatializerData { enabled, width },
            },
        );
        MAP_SUCCESS
    }

    pub fn set_reverb(
        &mut self,
        enabled: i32,
        room_size: f32,
        damping: f32,
        width: f32,
        wet: f32,
        dry: f32,
    ) -> i32 {
        crate::map_log!(
            4,
            "set_reverb(enabled={}, room_size={}, damping={}, width={}, wet={}, dry={})",
            enabled != 0,
            room_size,
            damping,
            width,
            wet,
            dry
        );
        let rev = ReverbConfig {
            enabled,
            room_size,
            damping,
            width,
            wet,
            dry,
        };
        self.reverb_config = rev;
        self.send_dsp_command(DspCommand::SetReverb(rev));
        self.telemetry
            .post_event(EventType::Reverb, MapEventData { reverb: rev });
        MAP_SUCCESS
    }

    pub fn set_limiter(&mut self, enabled: i32) -> i32 {
        crate::map_log!(4, "set_limiter(enabled={})", enabled != 0);
        let en = enabled != 0;
        self.limiter_enabled.store(en, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetLimiter(en));
        self.telemetry.post_event(
            EventType::Limiter,
            MapEventData {
                limiter_enabled: enabled,
            },
        );
        MAP_SUCCESS
    }

    pub fn set_silence_config(&mut self, config: &SilenceConfig) -> i32 {
        crate::map_log!(
            4,
            "set_silence_config(mode={:?}, threshold_db={})",
            config.mode,
            config.threshold_db
        );
        self.silence_config.write(|s| *s = *config);
        self.telemetry.post_event(
            EventType::SilenceConfig,
            MapEventData {
                silence_config: *config,
            },
        );
        MAP_SUCCESS
    }

    pub fn get_silence_config(&self, out: &mut SilenceConfig) -> i32 {
        *out = self.silence_config.read();
        MAP_SUCCESS
    }

    pub fn get_silence_saved_ms(&self) -> i64 {
        self.silence_saved_ms.load(Ordering::Relaxed)
    }

    pub fn set_visualizer_enabled(&mut self, enabled: i32) -> i32 {
        let en = enabled != 0;
        crate::map_log!(4, "set_visualizer_enabled(enabled={})", en);
        self.visualizer_enabled.store(en, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetVisualizerEnabled(en));
        if !en {
            let zero_vis = VisualizerData::default();
            self.visualizer_seqlock.write(|v| *v = zero_vis);
            self.telemetry.post_event(
                EventType::Visualizer,
                MapEventData {
                    visualizer: zero_vis,
                },
            );
        }
        self.telemetry.post_event(
            EventType::VisualizerEnabled,
            MapEventData {
                visualizer_enabled: enabled,
            },
        );
        MAP_SUCCESS
    }

    pub fn is_visualizer_enabled(&self) -> i32 {
        self.visualizer_enabled.load(Ordering::Relaxed) as i32
    }

    pub fn get_visualizer_data(&self, out: &mut VisualizerData) -> i32 {
        *out = self.visualizer_seqlock.read();
        MAP_SUCCESS
    }

    #[inline]
    fn acknowledge_renderer_flush(&mut self) {
        if let Some(ref mut renderer) = self.renderer {
            renderer.acknowledge_flush_if_needed();
        }
    }

    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        if !output_frames.is_null() && frame_count > 0 {
            if let Some(ref mut renderer) = self.renderer {
                renderer.render_pcm(output_frames, frame_count);
            }
        }
    }

    pub fn get_status(&self, out: &mut MiniaudioPlayerStatus) -> i32 {
        out.position_ms = self.position_ms.load(Ordering::Relaxed);
        out.duration_ms = self.duration_ms.load(Ordering::Relaxed);
        let st = self.state.load(Ordering::Relaxed);
        out.state = st;
        out.is_playing = (st == STATE_PLAYING) as i32;
        out.is_buffering = self.is_buffering.load(Ordering::Relaxed) as i32;
        out.volume = f32::from_bits(self.volume.load(Ordering::Relaxed));
        out.rate = f32::from_bits(self.rate.load(Ordering::Relaxed));
        out.pitch = f32::from_bits(self.pitch.load(Ordering::Relaxed));
        out.bitrate = self.bitrate.load(Ordering::Relaxed);
        out.sample_rate = self.sample_rate.load(Ordering::Relaxed);
        out.channels = self.channels.load(Ordering::Relaxed);

        out.equalizer = self.eq_params;
        out.preamp_db = f32::from_bits(self.preamp_db.load(Ordering::Relaxed));
        out.replay_gain = self.replay_gain;
        out.balance = f32::from_bits(self.balance.load(Ordering::Relaxed));
        out.mono_enabled = self.mono_enabled.load(Ordering::Relaxed) as i32;
        out.crossfeed = self.crossfeed_config;
        out.spatializer_enabled = self.spatializer_enabled.load(Ordering::Relaxed) as i32;
        out.spatializer_width = f32::from_bits(self.spatializer_width.load(Ordering::Relaxed));
        out.reverb = self.reverb_config;
        out.limiter_enabled = self.limiter_enabled.load(Ordering::Relaxed) as i32;
        out.visualizer = self.visualizer_seqlock.read();

        out.visualizer_enabled = self.visualizer_enabled.load(Ordering::Relaxed) as i32;
        out.silence = self.silence_config.read();
        out.silence_saved_ms = self.silence_saved_ms.load(Ordering::Relaxed);

        out.device = MapDeviceInfo::default();

        MAP_SUCCESS
    }

    pub fn destroy(&mut self) {
        let _ = self.stop();
        self.network_streamer_abort.store(true, Ordering::Release);
        if let Ok(guard) = self.stream_session.read() {
            if let Some(ref session) = *guard {
                session.abort();
            }
        }
        self.telemetry.stop();
        self.decoder_running.store(false, Ordering::Relaxed);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        if let Some(handle) = self.decoder_thread.take() {
            let _ = handle.join();
        }

        self.renderer = None;
    }
}

impl Drop for StreamingDeck {
    fn drop(&mut self) {
        self.destroy();
    }
}

// =========================================================================
// Dual Source Pipeline (CurrentSlot / StandbySlot) and Queue Management
// =========================================================================

/// Core queued track item representation held in the dual-deck playlist.
#[derive(Debug, Clone, Default)]
pub struct AudioSourceCore {
    /// Unique track identifier.
    pub id: i64,
    /// URI or filesystem path string.
    pub source: String,
    /// Optional HTTP headers for network streaming.
    pub headers: Option<Vec<crate::api::types::RustHttpHeader>>,
    /// Optional in-memory raw audio bytes.
    pub data_bytes: Option<Vec<u8>>,
    /// Track-specific ReplayGain adjustment in dB.
    pub replay_gain_db: Option<f32>,
    /// Track-specific true peak amplitude.
    pub replay_peak: Option<f32>,
}

/// Resolves an effective [`ReplayGainConfig`] from global policy (`mode`, `default_gain`)
/// and optional per-track ReplayGain parts `(gain_db, peak)`.
pub fn resolve_replay_gain_parts(
    mode: u32,
    default_gain: (f32, f32),
    item_gain_db: Option<f32>,
    item_peak: Option<f32>,
) -> ReplayGainConfig {
    match mode {
        0 => ReplayGainConfig {
            gain_db: 0.0,
            peak: 1.0,
            prevent_clipping: 1,
            enabled: 0,
        },
        2 => ReplayGainConfig {
            gain_db: default_gain.0,
            peak: default_gain.1,
            prevent_clipping: 1,
            enabled: 1,
        },
        _ => {
            if let Some(gain_db) = item_gain_db {
                return ReplayGainConfig {
                    gain_db,
                    peak: item_peak.unwrap_or(1.0),
                    prevent_clipping: 1,
                    enabled: 1,
                };
            }
            ReplayGainConfig {
                gain_db: default_gain.0,
                peak: default_gain.1,
                prevent_clipping: 1,
                enabled: if default_gain.0 != 0.0 { 1 } else { 0 },
            }
        }
    }
}

/// Resolves an effective [`ReplayGainConfig`] for an optional queued item.
#[inline]
pub fn resolve_replay_gain(
    mode: u32,
    default_gain: (f32, f32),
    item: Option<&AudioSourceCore>,
) -> ReplayGainConfig {
    match item {
        Some(it) => {
            resolve_replay_gain_parts(mode, default_gain, it.replay_gain_db, it.replay_peak)
        }
        None => resolve_replay_gain_parts(mode, default_gain, None, None),
    }
}

/// Lock-free atomic tracker coordinating smooth crossfade transitions between Deck A and Deck B.
#[repr(C)]
pub struct CrossfadeAtomic {
    /// Internal queue transition state (Idle, AutoCrossfade, ManualCrossfade).
    pub transition: AtomicI32,
    /// Deck ID fading out (0: A, 1: B).
    pub from_deck: AtomicI32,
    /// Deck ID fading in (0: A, 1: B).
    pub to_deck: AtomicI32,
    /// Progress counter in audio frames rendered during this crossfade.
    pub current_frame: AtomicU64,
    /// Total duration of the crossfade in audio frames.
    pub total_frames: AtomicU64,
    /// Volume curve formula (0: EqualPower, 1: Linear).
    pub curve: AtomicI32,
}

impl Default for CrossfadeAtomic {
    fn default() -> Self {
        Self {
            transition: AtomicI32::new(QueueTransition::Idle.as_i32()),
            from_deck: AtomicI32::new(0),
            to_deck: AtomicI32::new(1),
            current_frame: AtomicU64::new(0),
            total_frames: AtomicU64::new(0),
            curve: AtomicI32::new(0),
        }
    }
}

impl CrossfadeAtomic {
    /// Commences an atomic crossfade transition from `from_deck` to `to_deck`.
    #[inline]
    pub fn begin(&self, from_deck: i32, to_deck: i32, total_frames: u64, curve: i32, transition: QueueTransition) {
        self.from_deck.store(from_deck, Ordering::Relaxed);
        self.to_deck.store(to_deck, Ordering::Relaxed);
        self.current_frame.store(0, Ordering::Relaxed);
        self.total_frames
            .store(total_frames.max(1), Ordering::Relaxed);
        self.curve.store(curve, Ordering::Relaxed);
        self.transition.store(transition.as_i32(), Ordering::Release);
    }

    /// Aborts any active crossfade transition immediately.
    #[inline]
    pub fn abort(&self) {
        self.transition.store(QueueTransition::Idle.as_i32(), Ordering::Release);
    }

    /// Returns whether a crossfade is currently active.
    #[inline]
    pub fn is_active(&self) -> bool {
        self.transition.load(Ordering::Acquire) != QueueTransition::Idle.as_i32()
    }

    /// Returns the current queue transition phase.
    #[inline]
    pub fn transition(&self) -> QueueTransition {
        QueueTransition::from_i32(self.transition.load(Ordering::Relaxed))
    }

    /// Computes instantaneous volume gains for (from_deck, to_deck) at a given normalized progress.
    #[inline]
    pub fn compute_gains(curve: i32, progress: f32) -> (f32, f32) {
        let p = progress.clamp(0.0, 1.0);
        if curve == 1 {
            (1.0 - p, p)
        } else {
            let angle = p * std::f32::consts::FRAC_PI_2;
            (angle.cos(), angle.sin())
        }
    }

    /// Advances the frame counter and computes the current volume gains for (Deck A, Deck B).
    #[inline]
    pub fn advance_and_get_gains(&self, frame_count: u64) -> (f32, f32) {
        let cur = self.current_frame.fetch_add(frame_count, Ordering::Relaxed);
        let tot = self.total_frames.load(Ordering::Relaxed).max(1);
        let curve = self.curve.load(Ordering::Relaxed);
        let progress = (cur as f32 / tot as f32).min(1.0);
        if cur + frame_count >= tot {
            self.transition.store(QueueTransition::Idle.as_i32(), Ordering::Release);
        }
        let (gain_from, gain_to) = Self::compute_gains(curve, progress);
        if self.from_deck.load(Ordering::Relaxed) == 0 {
            (gain_from, gain_to)
        } else {
            (gain_to, gain_from)
        }
    }
}

/// Factory function closure constructing a custom Dart byte source and response handle.
pub type CustomSourceFactory = Arc<
    dyn Fn(
            u32,
            Option<u64>,
        ) -> (
            crate::buffer::CustomDartByteSource,
            crate::buffer::CustomByteSourceHandle,
        ) + Send
        + Sync,
>;

/// Dual-deck crossfading coordinator orchestrating two independent streaming decks (Deck A and Deck B).
pub struct DualSource {
    /// Primary streaming deck A.
    pub deck_a: Box<StreamingDeck>,
    /// Secondary streaming deck B for gapless crossfades.
    pub deck_b: Box<StreamingDeck>,
    /// Active deck indicator (0: Deck A, 1: Deck B).
    pub active_deck: Arc<AtomicI32>,
    /// Lock-free atomic crossfade state coordinator.
    pub crossfade: Arc<CrossfadeAtomic>,
    /// Flag indicating that a crossfade completed.
    pub crossfade_completed_flag: Arc<AtomicBool>,
    /// Canonical transport playback state code (`PlaybackState`).
    pub playback_state: Arc<AtomicI32>,

    /// Active playlist queue (shuffled or un-shuffled).
    pub queue: Arc<RwLock<Vec<AudioSourceCore>>>,
    /// Canonical sequential order of the playlist queue.
    pub canonical_queue: Arc<RwLock<Vec<AudioSourceCore>>>,
    /// Original sequential indices mapping into the active queue.
    pub original_indices: Arc<RwLock<Vec<usize>>>,
    /// Current track index in the active queue.
    pub current_index: Arc<AtomicI64>,
    /// Active playlist loop mode policy.
    pub loop_mode: Arc<AtomicI32>,
    /// Whether playlist shuffle is active.
    pub shuffle_enabled: Arc<AtomicBool>,
    /// Whether continuous auto-refill infinite mix mode is enabled.
    pub infinite_mix_enabled: Arc<AtomicBool>,
    /// Threshold of remaining tracks ahead before requesting replenishment.
    pub infinite_mix_threshold: Arc<AtomicUsize>,
    /// Last track ID for which replenishment was requested (-1 if none/reset).
    pub last_notified_infinite_mix_id: Arc<AtomicI64>,

    /// Duration in milliseconds for automatic end-of-track crossfades.
    pub auto_crossfade_duration_ms: Arc<AtomicU64>,
    /// Duration in milliseconds for manual track skip crossfades.
    pub manual_crossfade_duration_ms: Arc<AtomicU64>,
    /// Gain curve formula for crossfades (0: EqualPower, 1: Linear).
    pub crossfade_curve: Arc<AtomicI32>,
    /// Monotonic track ID of the target track in an active crossfade (-1 when none).
    pub crossfade_target_id: Arc<AtomicI64>,

    pub sample_rate: u32,
    pub channels: u32,
    pub period_size: u32,
    pub custom_source_factory: Option<CustomSourceFactory>,
    /// Track ID currently decoded and paused in the standby deck (`-1` if none/invalidated).
    pub standby_ready_id: Arc<AtomicI64>,
    /// Normalized source URI matching `standby_ready_id` for source-reuse invalidation.
    pub standby_ready_source: Arc<RwLock<Option<String>>>,
    /// Logically committed queue cursor used for FIFO rapid-skip serialization.
    pub planned_index: Arc<AtomicI64>,
    /// Whether queue mutators synchronously call `preload_standby_deck` (false under Tri-Plane actor).
    pub auto_preload_standby: Arc<AtomicBool>,
    /// Default ReplayGain fallback/forced values `(gain_db, peak)`.
    pub default_replay_gain: (f32, f32),
    /// Global ReplayGain operating mode (`0 = Disabled`, `1 = Track`, `2 = Forced`).
    pub replay_gain_mode: u32,
}

unsafe impl Send for DualSource {}
unsafe impl Sync for DualSource {}

impl DualSource {
    pub fn new(sample_rate: u32, channels: u32, period_size: u32) -> Result<Self, i32> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels } else { 2 };
        let period = if period_size > 0 { period_size } else { 1024 };

        let deck_a = StreamingDeck::new_deck(sr, ch, period)?;
        let deck_b = StreamingDeck::new_deck(sr, ch, period)?;

        Ok(Self {
            deck_a,
            deck_b,
            active_deck: Arc::new(AtomicI32::new(0)),
            crossfade: Arc::new(CrossfadeAtomic::default()),
            crossfade_completed_flag: Arc::new(AtomicBool::new(false)),
            playback_state: Arc::new(AtomicI32::new(PlaybackState::Stopped.as_i32())),
            queue: Arc::new(RwLock::new(Vec::new())),
            canonical_queue: Arc::new(RwLock::new(Vec::new())),
            original_indices: Arc::new(RwLock::new(Vec::new())),
            current_index: Arc::new(AtomicI64::new(-1)),
            loop_mode: Arc::new(AtomicI32::new(0)),
            shuffle_enabled: Arc::new(AtomicBool::new(false)),
            infinite_mix_enabled: Arc::new(AtomicBool::new(false)),
            infinite_mix_threshold: Arc::new(AtomicUsize::new(2)),
            last_notified_infinite_mix_id: Arc::new(AtomicI64::new(-1)),
            auto_crossfade_duration_ms: Arc::new(AtomicU64::new(5000)),
            manual_crossfade_duration_ms: Arc::new(AtomicU64::new(500)),
            crossfade_curve: Arc::new(AtomicI32::new(0)),
            crossfade_target_id: Arc::new(AtomicI64::new(-1)),
            sample_rate: sr,
            channels: ch,
            period_size: period,
            custom_source_factory: None,
            standby_ready_id: Arc::new(AtomicI64::new(-1)),
            standby_ready_source: Arc::new(RwLock::new(None)),
            planned_index: Arc::new(AtomicI64::new(-1)),
            auto_preload_standby: Arc::new(AtomicBool::new(true)),
            default_replay_gain: (0.0, 1.0),
            replay_gain_mode: 1,
        })
    }

    /// Resolves effective ReplayGain configuration for `item` under the active global mode/default.
    #[inline]
    pub fn resolve_item_replay_gain(&self, item: Option<&AudioSourceCore>) -> ReplayGainConfig {
        resolve_replay_gain(self.replay_gain_mode, self.default_replay_gain, item)
    }

    /// Resolves effective ReplayGain telemetry for the current foreground track
    /// (or index 0 while stopped with a non-empty queue).
    pub fn resolve_foreground_replay_gain(&self) -> ReplayGainConfig {
        let q = read_unpoisoned(&self.queue);
        let cur = self.current_index.load(Ordering::Relaxed);
        let item = if cur >= 0 && (cur as usize) < q.len() {
            Some(&q[cur as usize])
        } else if !q.is_empty() {
            Some(&q[0])
        } else {
            None
        };
        resolve_replay_gain(self.replay_gain_mode, self.default_replay_gain, item)
    }

    /// Refreshes per-deck ReplayGain DSP settings on both Deck A and Deck B independently
    /// according to each deck's own loaded queue item and the global mode/default.
    pub fn refresh_deck_replay_gains(&mut self) {
        let mode = self.replay_gain_mode;
        let def_rg = self.default_replay_gain;
        let q = read_unpoisoned(&self.queue);
        for deck in [&mut self.deck_a, &mut self.deck_b] {
            if let Some(item_id) = deck.queue_item_id {
                if let Some(item) = q.iter().find(|it| it.id == item_id) {
                    deck.track_replay_gain = (item.replay_gain_db, item.replay_peak);
                }
                let rg = resolve_replay_gain_parts(
                    mode,
                    def_rg,
                    deck.track_replay_gain.0,
                    deck.track_replay_gain.1,
                );
                deck.apply_replay_gain_config_silent(rg);
            } else {
                deck.apply_replay_gain_config_silent(ReplayGainConfig::default());
            }
        }
    }

    /// Returns a mutable reference to the currently active foreground deck.
    #[inline]
    pub fn active_deck_mut(&mut self) -> &mut StreamingDeck {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &mut self.deck_a
        } else {
            &mut self.deck_b
        }
    }

    /// Returns a mutable reference to the standby / background deck.
    #[inline]
    pub fn standby_deck_mut(&mut self) -> &mut StreamingDeck {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &mut self.deck_b
        } else {
            &mut self.deck_a
        }
    }

    /// Returns an immutable reference to the active foreground deck.
    #[inline]
    pub fn active_deck_ref(&self) -> &StreamingDeck {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &self.deck_a
        } else {
            &self.deck_b
        }
    }

    /// Returns an immutable reference to the standby background deck.
    #[inline]
    pub fn standby_deck_ref(&self) -> &StreamingDeck {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &self.deck_b
        } else {
            &self.deck_a
        }
    }

    pub fn open_deck_source(
        deck: &mut StreamingDeck,
        item: &AudioSourceCore,
        custom_factory: Option<&CustomSourceFactory>,
    ) -> i32 {
        Self::open_deck_source_with_cancel(deck, item, custom_factory, None)
    }

    pub fn open_deck_source_with_cancel(
        deck: &mut StreamingDeck,
        item: &AudioSourceCore,
        custom_factory: Option<&CustomSourceFactory>,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            deck.clear_queue_item_assignment();
            return MAP_ERROR_ABORTED;
        }
        let res = if item.source.starts_with("custom:") || item.source.starts_with("custom://") {
            let id_str = item
                .source
                .trim_start_matches("custom://")
                .trim_start_matches("custom:");
            let (stream_id, total_size) = if let Some((id_part, query_part)) = id_str.split_once('?') {
                let parsed_id = id_part.parse::<u32>().unwrap_or(0);
                let s_id = if parsed_id > 0 { parsed_id } else { item.id as u32 };
                let mut size = None;
                for pair in query_part.split('&') {
                    if let Some((k, v)) = pair.split_once('=') {
                        if k == "size" {
                            size = v.parse::<u64>().ok();
                        }
                    }
                }
                (s_id, size)
            } else {
                let parsed_id = id_str.parse::<u32>().unwrap_or(0);
                let s_id = if parsed_id > 0 { parsed_id } else { item.id as u32 };
                (s_id, None)
            };
            if let Some(factory) = custom_factory {
                let (source, handle) = factory(stream_id, total_size);
                deck.open_custom_source_with_cancel(source, handle, total_size, true, cancel)
            } else {
                MAP_ERROR_UNSUPPORTED
            }
        } else if let Some(ref data) = item.data_bytes {
            let ext_hint = StreamClassifier::extract_extension_hint(&item.source);
            let open_res = deck.open_memory_with_hint(data, ext_hint);
            if cancel.is_some_and(|c| c.is_cancelled()) {
                deck.mark_open_error(MAP_ERROR_ABORTED)
            } else {
                open_res
            }
        } else {
            deck.open_source_with_cancel(&item.source, item.headers.as_deref(), cancel)
        };
        if res == MAP_SUCCESS {
            deck.set_queue_item_assignment(item);
        } else {
            deck.clear_queue_item_assignment();
        }
        res
    }

    /// Replaces the entire playback queue with `items` without starting playback.
    ///
    /// Resets `current_index` to `-1` (`null` in Dart), aborts any active crossfade,
    /// and stops both decks.
    pub fn set_queue(&mut self, items: Vec<AudioSourceCore>) {
        self.crossfade.abort();
        self.crossfade_target_id.store(-1, Ordering::Release);
        self.crossfade_completed_flag.store(false, Ordering::Release);
        self.standby_ready_id.store(-1, Ordering::Release);
        *write_unpoisoned(&self.standby_ready_source) = None;
        self.deck_a.stop();
        self.deck_a.clear_queue_item_assignment();
        self.deck_b.stop();
        self.deck_b.clear_queue_item_assignment();

        *write_unpoisoned(&self.canonical_queue) = items.clone();
        *write_unpoisoned(&self.original_indices) = (0..items.len()).collect();
        *write_unpoisoned(&self.queue) = items;

        self.current_index.store(-1, Ordering::Release);
        self.planned_index.store(-1, Ordering::Release);
        self.last_notified_infinite_mix_id.store(-1, Ordering::Release);
        self.playback_state.store(PlaybackState::Stopped.as_i32(), Ordering::Release);
    }

    /// Resolves the expected upcoming track ID based on the current active queue and loop mode.
    pub fn expected_next_track_id(&self) -> Option<i64> {
        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return None;
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        if cur < 0 {
            return None;
        }
        let next_idx = (cur as usize) + 1;
        let loop_mode = self.loop_mode.load(Ordering::Relaxed);
        if next_idx < q.len() {
            Some(q[next_idx].id)
        } else if loop_mode == 2 {
            Some(q[0].id)
        } else {
            None
        }
    }

    /// Verifies that any in-flight crossfade still targets the expected track ID.
    /// If a queue mutation invalidated the target track ID, aborts the crossfade immediately.
    pub fn verify_or_abort_crossfade(&mut self) {
        let trans = self.crossfade.transition();
        if trans == QueueTransition::Idle {
            return;
        }
        let target_id = self.crossfade_target_id.load(Ordering::Relaxed);
        if target_id < 0 {
            self.abort_active_crossfade();
            return;
        }
        if trans == QueueTransition::AutoCrossfade {
            if self.expected_next_track_id() != Some(target_id) {
                self.abort_active_crossfade();
            }
        } else if trans == QueueTransition::ManualCrossfade {
            let cur = self.current_index.load(Ordering::Relaxed);
            let cur_id = if cur >= 0 {
                read_unpoisoned(&self.queue).get(cur as usize).map(|it| it.id)
            } else {
                None
            };
            if cur_id != Some(target_id) {
                self.abort_active_crossfade();
            }
        }
    }

    pub fn preload_standby_deck(&mut self) {
        if !self.auto_preload_standby.load(Ordering::Relaxed) {
            return;
        }
        if self.crossfade.is_active() {
            return;
        }
        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return;
        }

        let cur = self.current_index.load(Ordering::Relaxed);
        if cur < 0 {
            return;
        }

        let cur_u = cur as usize;
        let next_idx = cur_u + 1;
        let loop_mode = self.loop_mode.load(Ordering::Relaxed);

        let target_item = if next_idx < q.len() {
            Some(q[next_idx].clone())
        } else if loop_mode == 2 && !q.is_empty() {
            // LoopMode.all wraps to index 0
            Some(q[0].clone())
        } else {
            None
        };
        drop(q);

        let active_deck = self.active_deck.load(Ordering::Relaxed);
        let custom_factory = self.custom_source_factory.clone();
        let standby_ready_id = self.standby_ready_id.clone();
        let standby_ready_source = self.standby_ready_source.clone();
        let rg_mode = self.replay_gain_mode;
        let def_rg = self.default_replay_gain;
        let standby_deck = if active_deck == 0 {
            &mut self.deck_b
        } else {
            &mut self.deck_a
        };

        if let Some(item) = target_item {
            let res = Self::open_deck_source(standby_deck, &item, custom_factory.as_ref());
            if res == 0 {
                let rg = resolve_replay_gain(rg_mode, def_rg, Some(&item));
                standby_deck.apply_replay_gain_config_silent(rg);
                standby_deck.pause();
                standby_ready_id.store(item.id, Ordering::Release);
                *write_unpoisoned(&standby_ready_source) = Some(item.source);
            } else {
                standby_ready_id.store(-1, Ordering::Release);
                *write_unpoisoned(&standby_ready_source) = None;
            }
        } else {
            standby_deck.stop();
            standby_deck.clear_queue_item_assignment();
            standby_ready_id.store(-1, Ordering::Release);
            *write_unpoisoned(&standby_ready_source) = None;
        }
    }

    pub fn append_items(&mut self, items: Vec<AudioSourceCore>) {
        let mut can = write_unpoisoned(&self.canonical_queue);
        let start = can.len();
        can.extend(items.clone());
        let mut orig_idx = write_unpoisoned(&self.original_indices);
        orig_idx.extend(start..can.len());
        let mut q = write_unpoisoned(&self.queue);
        q.extend(items);
        drop(q);
        drop(orig_idx);
        drop(can);
        self.verify_or_abort_crossfade();
        self.preload_standby_deck();
    }

    pub fn insert_next_item(&mut self, item: AudioSourceCore) {
        {
            let mut can = write_unpoisoned(&self.canonical_queue);
            can.push(item.clone());
            let n = can.len();
            *write_unpoisoned(&self.original_indices) = (0..n).collect();
        }
        let mut q = write_unpoisoned(&self.queue);
        let cur = self.current_index.load(Ordering::Relaxed);
        let insert_idx = ((cur + 1).max(0) as usize).min(q.len());
        q.insert(insert_idx, item);
        drop(q);
        self.verify_or_abort_crossfade();
        self.preload_standby_deck();
    }

    pub fn remove_item_at(&mut self, index: usize) -> Option<AudioSourceCore> {
        let mut q = write_unpoisoned(&self.queue);
        if index >= q.len() {
            return None;
        }
        let removed = q.remove(index);
        {
            let mut can = write_unpoisoned(&self.canonical_queue);
            can.retain(|it| it.id != removed.id);
            let n = can.len();
            *write_unpoisoned(&self.original_indices) = (0..n).collect();
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        if cur >= 0 {
            if (index as i64) < cur {
                self.current_index.store(cur - 1, Ordering::Release);
            } else if (index as i64) == cur {
                if q.is_empty() {
                    self.current_index.store(-1, Ordering::Release);
                    drop(q);
                    self.abort_active_crossfade();
                    self.deck_a.stop();
                    self.deck_a.clear_queue_item_assignment();
                    self.deck_b.stop();
                    self.deck_b.clear_queue_item_assignment();
                    self.playback_state.store(PlaybackState::Stopped.as_i32(), Ordering::Release);
                    return Some(removed);
                } else {
                    let new_idx = if cur >= q.len() as i64 {
                        (q.len() - 1) as i64
                    } else {
                        cur
                    };
                    self.current_index.store(new_idx, Ordering::Release);
                    self.planned_index.store(new_idx, Ordering::Release);
                    let next_item = q[new_idx as usize].clone();
                    drop(q);
                    self.abort_active_crossfade();
                    self.standby_ready_id.store(-1, Ordering::Release);
                    *write_unpoisoned(&self.standby_ready_source) = None;
                    if !self.auto_preload_standby.load(Ordering::Relaxed) {
                        self.deck_a.stop();
                        self.deck_a.clear_queue_item_assignment();
                        self.deck_b.stop();
                        self.deck_b.clear_queue_item_assignment();
                        return Some(removed);
                    }
                    let factory = self.custom_source_factory.clone();
                    let next_rg = self.resolve_item_replay_gain(Some(&next_item));
                    let active = self.active_deck_mut();
                    if Self::open_deck_source(active, &next_item, factory.as_ref()) == 0 {
                        active.apply_replay_gain_config_silent(next_rg);
                    }
                    active.play();
                    self.preload_standby_deck();
                    return Some(removed);
                }
            }
        }
        drop(q);
        self.verify_or_abort_crossfade();
        self.preload_standby_deck();
        Some(removed)
    }

    pub fn reorder_item(&mut self, from: usize, to: usize) -> bool {
        let mut q = write_unpoisoned(&self.queue);
        if from >= q.len() || to >= q.len() || from == to {
            return false;
        }
        let item = q.remove(from);
        q.insert(to, item);
        let cur = self.current_index.load(Ordering::Relaxed);
        if cur >= 0 {
            let cur_u = cur as usize;
            if cur_u == from {
                self.current_index.store(to as i64, Ordering::Release);
            } else if from < cur_u && to >= cur_u {
                self.current_index.store(cur - 1, Ordering::Release);
            } else if from > cur_u && to <= cur_u {
                self.current_index.store(cur + 1, Ordering::Release);
            }
        }
        drop(q);
        self.verify_or_abort_crossfade();
        self.preload_standby_deck();
        true
    }

    pub fn reorder_by_ids(&mut self, ids: &[i64]) -> bool {
        let mut q = write_unpoisoned(&self.queue);
        if q.is_empty() || ids.len() != q.len() {
            return false;
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        let current_id = if cur >= 0 && (cur as usize) < q.len() {
            Some(q[cur as usize].id)
        } else {
            None
        };

        let mut reordered = Vec::with_capacity(q.len());
        for &id in ids {
            if let Some(pos) = q.iter().position(|item| item.id == id) {
                reordered.push(q.remove(pos));
            } else {
                return false;
            }
        }
        *q = reordered;

        if let Some(cur_id) = current_id {
            if let Some(new_idx) = q.iter().position(|item| item.id == cur_id) {
                self.current_index.store(new_idx as i64, Ordering::Release);
            }
        }
        drop(q);
        self.verify_or_abort_crossfade();
        self.preload_standby_deck();
        true
    }

    pub fn clear_items(&mut self, keep_current: bool) {
        self.last_notified_infinite_mix_id.store(-1, Ordering::Release);
        write_unpoisoned(&self.canonical_queue).clear();
        write_unpoisoned(&self.original_indices).clear();
        let mut q = write_unpoisoned(&self.queue);
        let cur = self.current_index.load(Ordering::Relaxed);
        if keep_current && cur >= 0 && (cur as usize) < q.len() {
            let current_item = q[cur as usize].clone();
            q.clear();
            q.push(current_item.clone());
            write_unpoisoned(&self.canonical_queue).push(current_item);
            write_unpoisoned(&self.original_indices).push(0);
            self.current_index.store(0, Ordering::Release);
            drop(q);
            self.verify_or_abort_crossfade();
            self.preload_standby_deck();
        } else {
            q.clear();
            drop(q);
            self.current_index.store(-1, Ordering::Release);
            self.abort_active_crossfade();
            self.deck_a.stop();
            self.deck_b.stop();
            self.playback_state.store(PlaybackState::Stopped.as_i32(), Ordering::Release);
        }
    }

    pub fn next(&mut self, manual_crossfade_ms: Option<u64>) -> Result<(), String> {
        let trans = self.crossfade.transition();
        if trans == QueueTransition::AutoCrossfade {
            let target_id = self.crossfade_target_id.load(Ordering::Relaxed);
            if target_id >= 0 {
                if let Some(idx) = read_unpoisoned(&self.queue).iter().position(|it| it.id == target_id) {
                    self.current_index.store(idx as i64, Ordering::Release);
                }
            }
            let manual_ms = manual_crossfade_ms.unwrap_or_else(|| {
                self.manual_crossfade_duration_ms.load(Ordering::Relaxed)
            });
            let sr = self.sample_rate.max(1);
            let max_frames = (manual_ms * sr as u64) / 1000;
            let cur_frame = self.crossfade.current_frame.load(Ordering::Relaxed);
            let tot_frame = self.crossfade.total_frames.load(Ordering::Relaxed);
            if tot_frame > cur_frame + max_frames {
                self.crossfade.total_frames.store(cur_frame + max_frames, Ordering::Release);
            }
            self.crossfade.transition.store(QueueTransition::ManualCrossfade.as_i32(), Ordering::Release);
            return Ok(());
        }

        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return Ok(());
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        let next_idx = cur + 1;
        let loop_mode = self.loop_mode.load(Ordering::Relaxed);

        let target_idx = if next_idx < q.len() as i64 {
            next_idx
        } else if loop_mode == 2 {
            0
        } else {
            return Ok(());
        };
        drop(q);
        self.transition_to_index(target_idx as usize, manual_crossfade_ms, None, false)
    }

    pub fn previous(&mut self) -> Result<(), String> {
        let cur_deck = self.active_deck_ref();
        let pos_ms = cur_deck.position_ms.load(Ordering::Relaxed);
        let trans = self.crossfade.transition();
        let is_live = cur_deck.is_live_stream();

        if trans == QueueTransition::AutoCrossfade {
            self.abort_active_crossfade();
            if !is_live && pos_ms > 3000 {
                self.active_deck_mut().seek(0);
                return Ok(());
            }
        } else if !is_live && pos_ms > 3000 {
            self.abort_active_crossfade();
            self.active_deck_mut().seek(0);
            return Ok(());
        }

        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return Ok(());
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        let target_idx = if cur > 0 {
            cur - 1
        } else {
            0
        };
        drop(q);
        self.transition_to_index(target_idx as usize, None, None, false)
    }

    /// Internal deck transition helper used by `play`, `next`, and `previous`.
    pub fn transition_to_index(
        &mut self,
        index: usize,
        manual_crossfade_ms: Option<u64>,
        seek_ms: Option<i64>,
        force_play: bool,
    ) -> Result<(), String> {
        if self.crossfade.is_active() {
            self.abort_active_crossfade();
        }
        let q = read_unpoisoned(&self.queue);
        if index >= q.len() {
            return Err(format!("Index {} out of bounds (queue size {})", index, q.len()));
        }
        let item = q[index].clone();
        drop(q);

        self.crossfade_target_id.store(-1, Ordering::Release);
        self.crossfade_completed_flag.store(false, Ordering::Release);

        let active_deck = self.active_deck.load(Ordering::Relaxed);
        let cur_playback = PlaybackState::from_i32(self.playback_state.load(Ordering::Relaxed));
        let was_playing = cur_playback == PlaybackState::Playing;

        let to_deck = if active_deck == 0 { 1 } else { 0 };
        let to_rg = self.resolve_item_replay_gain(Some(&item));
        let custom_factory = self.custom_source_factory.clone();
        let to_slot = if to_deck == 0 {
            &mut self.deck_a
        } else {
            &mut self.deck_b
        };

        let res = Self::open_deck_source(to_slot, &item, custom_factory.as_ref());
        if res != 0 {
            return Err(format!("Failed to open track: error {}", res));
        }

        to_slot.apply_replay_gain_config_silent(to_rg);

        if let Some(ms) = seek_ms {
            if ms > 0 {
                to_slot.seek(ms);
            }
        }

        if !was_playing {
            let from_slot = if active_deck == 0 {
                &mut self.deck_a
            } else {
                &mut self.deck_b
            };
            from_slot.stop();
            self.active_deck.store(to_deck, Ordering::Release);
            self.current_index.store(index as i64, Ordering::Release);
            if force_play {
                let to_slot = if to_deck == 0 {
                    &mut self.deck_a
                } else {
                    &mut self.deck_b
                };
                to_slot.play();
                self.playback_state.store(PlaybackState::Playing.as_i32(), Ordering::Release);
            } else {
                self.playback_state.store(PlaybackState::Paused.as_i32(), Ordering::Release);
            }
            self.preload_standby_deck();
            return Ok(());
        }

        to_slot.play();

        let xfade_ms = manual_crossfade_ms.unwrap_or_else(|| {
            self.manual_crossfade_duration_ms.load(Ordering::Relaxed)
        });

        if xfade_ms > 0 {
            let sr = self.sample_rate;
            let total_frames = (xfade_ms as u64 * sr as u64) / 1000;
            let curve = self.crossfade_curve.load(Ordering::Relaxed);
            self.crossfade_target_id.store(item.id, Ordering::Release);
            self.crossfade.begin(active_deck, to_deck, total_frames, curve, QueueTransition::ManualCrossfade);
            self.active_deck.store(to_deck, Ordering::Release);
            self.current_index.store(index as i64, Ordering::Release);
            self.playback_state.store(PlaybackState::Playing.as_i32(), Ordering::Release);
        } else {
            self.active_deck.store(to_deck, Ordering::Release);
            let from_slot = if active_deck == 0 {
                &mut self.deck_a
            } else {
                &mut self.deck_b
            };
            from_slot.stop();
            self.current_index.store(index as i64, Ordering::Release);
            self.playback_state.store(PlaybackState::Playing.as_i32(), Ordering::Release);
        }

        self.preload_standby_deck();
        Ok(())
    }

    pub fn set_loop_mode(&mut self, mode: i32) {
        self.loop_mode.store(mode.clamp(0, 2), Ordering::Release);
        self.verify_or_abort_crossfade();
        self.preload_standby_deck();
    }

    pub fn set_shuffle(&mut self, enabled: bool) {
        let cur_enabled = self.shuffle_enabled.load(Ordering::Relaxed);
        if cur_enabled == enabled {
            return;
        }
        self.shuffle_enabled.store(enabled, Ordering::Release);

        let cur = self.current_index.load(Ordering::Relaxed);
        if cur >= 0 {
            if enabled {
                self.apply_shuffle(cur as usize);
            } else {
                self.restore_canonical_order(cur as usize);
            }
            self.verify_or_abort_crossfade();
            self.preload_standby_deck();
        }
    }

    fn apply_shuffle(&mut self, current_idx: usize) {
        let mut q = write_unpoisoned(&self.queue);
        if q.is_empty() {
            self.current_index.store(-1, Ordering::Release);
            return;
        }
        if current_idx < q.len() {
            q.swap(0, current_idx);
            self.current_index.store(0, Ordering::Release);
            if q.len() > 2 {
                use rand::seq::SliceRandom;
                let mut rng = rand::rng();
                q[1..].shuffle(&mut rng);
            }
        } else {
            use rand::seq::SliceRandom;
            let mut rng = rand::rng();
            q.shuffle(&mut rng);
            self.current_index.store(0, Ordering::Release);
        }
    }

    fn restore_canonical_order(&mut self, current_idx: usize) {
        let can = read_unpoisoned(&self.canonical_queue);
        let mut q = write_unpoisoned(&self.queue);
        if current_idx < q.len() {
            let cur_id = q[current_idx].id;
            *q = can.clone();
            if let Some(canonical_pos) = q.iter().position(|it| it.id == cur_id) {
                self.current_index.store(canonical_pos as i64, Ordering::Release);
            }
        } else {
            *q = can.clone();
        }
    }

    pub fn set_crossfade(&mut self, duration_ms: u64, manual_duration_ms: u64, curve: i32) {
        self.auto_crossfade_duration_ms.store(duration_ms, Ordering::Release);
        self.manual_crossfade_duration_ms.store(manual_duration_ms, Ordering::Release);
        self.crossfade_curve.store(curve.clamp(0, 1), Ordering::Release);
    }

    pub fn abort_active_crossfade(&mut self) {
        let trans = self.crossfade.transition();
        self.crossfade_target_id.store(-1, Ordering::Release);
        if trans == QueueTransition::AutoCrossfade {
            self.crossfade.abort();
            self.standby_deck_mut().stop();
            self.standby_deck_mut().clear_queue_item_assignment();
        } else if trans == QueueTransition::ManualCrossfade {
            self.crossfade.abort();
            let to_deck = self.crossfade.to_deck.load(Ordering::Relaxed);
            self.active_deck.store(to_deck, Ordering::Release);
            self.standby_deck_mut().stop();
            self.standby_deck_mut().clear_queue_item_assignment();
        } else {
            self.crossfade.abort();
        }
    }

    /// Universal playback command supporting initial start, resumption, track selection
    /// by ID or position, shuffle toggling, and immediate seeking.
    pub fn play(
        &mut self,
        id: Option<i64>,
        position: Option<usize>,
        shuffled: Option<bool>,
        seek_ms: Option<i64>,
    ) -> Result<(), String> {
        let cur = self.current_index.load(Ordering::Relaxed);

        // Case 1: First Playback Execution (current_index < 0)
        if cur < 0 {
            let can = read_unpoisoned(&self.canonical_queue).clone();
            if can.is_empty() {
                if id.is_some() || position.is_some() {
                    return Err("Cannot play specific track: queue is empty".to_string());
                }
                return Ok(());
            }

            let effective_shuffled = if let Some(shuf) = shuffled {
                self.shuffle_enabled.store(shuf, Ordering::Release);
                shuf
            } else {
                self.shuffle_enabled.load(Ordering::Relaxed)
            };

            let target_canon_idx: Option<usize> = if let Some(target_id) = id {
                let idx = can
                    .iter()
                    .position(|it| it.id == target_id)
                    .ok_or_else(|| format!("Track id {} not found in queue", target_id))?;
                Some(idx)
            } else if let Some(pos) = position {
                if pos >= can.len() {
                    return Err(format!(
                        "Position {} out of bounds (queue size {})",
                        pos,
                        can.len()
                    ));
                }
                Some(pos)
            } else {
                None
            };

            if effective_shuffled {
                let mut q = can;
                use rand::seq::SliceRandom;
                let mut rng = rand::rng();
                if let Some(canon_idx) = target_canon_idx {
                    q.swap(0, canon_idx);
                    if q.len() > 2 {
                        q[1..].shuffle(&mut rng);
                    }
                } else {
                    q.shuffle(&mut rng);
                }
                *write_unpoisoned(&self.queue) = q;
                self.current_index.store(0, Ordering::Release);
            } else {
                *write_unpoisoned(&self.queue) = can;
                let start_idx = target_canon_idx.unwrap_or(0);
                self.current_index.store(start_idx as i64, Ordering::Release);
            }

            let start_idx = self.current_index.load(Ordering::Relaxed) as usize;
            let start_item = read_unpoisoned(&self.queue)[start_idx].clone();

            self.crossfade.abort();
            self.crossfade_target_id.store(-1, Ordering::Release);
            self.crossfade_completed_flag.store(false, Ordering::Release);

            let active_deck = self.active_deck.load(Ordering::Relaxed);
            let start_rg = self.resolve_item_replay_gain(Some(&start_item));
            let custom_factory = self.custom_source_factory.clone();
            let active_slot = if active_deck == 0 {
                &mut self.deck_a
            } else {
                &mut self.deck_b
            };

            let res = Self::open_deck_source(
                active_slot,
                &start_item,
                custom_factory.as_ref(),
            );
            if res != 0 {
                return Err(format!("Failed to open track: error {}", res));
            }

            active_slot.apply_replay_gain_config_silent(start_rg);

            if let Some(ms) = seek_ms {
                if ms > 0 {
                    active_slot.seek(ms);
                }
            }

            let play_res = active_slot.play();
            if play_res != 0 {
                return Err(format!("Play failed: error {}", play_res));
            }
            self.playback_state.store(PlaybackState::Playing.as_i32(), Ordering::Release);
            self.preload_standby_deck();
            return Ok(());
        }

        // Case 2: Subsequent play() Calls (Queue Already Active, current_index >= 0)
        if id.is_none() && position.is_none() {
            if let Some(shuf) = shuffled {
                self.set_shuffle(shuf);
            }
            let cur_playback = PlaybackState::from_i32(self.playback_state.load(Ordering::Relaxed));
            if cur_playback == PlaybackState::Stopped {
                let cur_idx = self.current_index.load(Ordering::Relaxed);
                if cur_idx >= 0 {
                    let seek_target = seek_ms.unwrap_or(0);
                    return self.transition_to_index(cur_idx as usize, None, Some(seek_target), true);
                }
            }
            if let Some(ms) = seek_ms {
                self.seek(ms);
            }
            let res = self.active_deck_mut().play();
            if res == 0 {
                self.playback_state.store(PlaybackState::Playing.as_i32(), Ordering::Release);
                Ok(())
            } else {
                Err(format!("Play failed: code {}", res))
            }
        } else {
            // Target track specified by id (takes precedence) or position (in active queue)
            let target_track_id = if let Some(target_id) = id {
                let exists = read_unpoisoned(&self.queue)
                    .iter()
                    .any(|it| it.id == target_id);
                if !exists {
                    return Err(format!("Track id {} not found in queue", target_id));
                }
                target_id
            } else if let Some(pos) = position {
                let q = read_unpoisoned(&self.queue);
                if pos >= q.len() {
                    return Err(format!(
                        "Position {} out of bounds (queue size {})",
                        pos,
                        q.len()
                    ));
                }
                q[pos].id
            } else {
                unreachable!()
            };

            if let Some(shuf) = shuffled {
                self.shuffle_enabled.store(shuf, Ordering::Release);
                if shuf {
                    let mut q = write_unpoisoned(&self.queue);
                    if let Some(pos) = q.iter().position(|it| it.id == target_track_id) {
                        q.swap(0, pos);
                        if q.len() > 2 {
                            use rand::seq::SliceRandom;
                            let mut rng = rand::rng();
                            q[1..].shuffle(&mut rng);
                        }
                    }
                } else {
                    let can = read_unpoisoned(&self.canonical_queue).clone();
                    *write_unpoisoned(&self.queue) = can;
                }
            }

            let target_idx = read_unpoisoned(&self.queue)
                .iter()
                .position(|it| it.id == target_track_id)
                .ok_or_else(|| format!("Track id {} not found in queue", target_track_id))?;

            self.transition_to_index(target_idx, None, seek_ms, true)
        }
    }

    pub fn pause(&mut self) {
        self.active_deck_mut().pause();
        self.playback_state.store(PlaybackState::Paused.as_i32(), Ordering::Release);
    }

    pub fn stop(&mut self) {
        self.abort_active_crossfade();
        self.deck_a.stop();
        self.deck_a.clear_queue_item_assignment();
        self.deck_b.stop();
        self.deck_b.clear_queue_item_assignment();
        self.playback_state.store(PlaybackState::Stopped.as_i32(), Ordering::Release);
    }

    pub fn seek(&mut self, position_ms: i64) -> i32 {
        let trans = self.crossfade.transition();
        if trans == QueueTransition::ManualCrossfade {
            self.abort_active_crossfade();
            return self.active_deck_mut().seek(position_ms);
        } else if trans == QueueTransition::AutoCrossfade {
            let dur = self.active_deck_ref().duration_ms.load(Ordering::Relaxed);
            let auto_ms = self.auto_crossfade_duration_ms.load(Ordering::Relaxed);
            let in_xfade_zone = auto_ms > 0 && dur > auto_ms as i64 && position_ms >= (dur - auto_ms as i64);
            if in_xfade_zone {
                let sr = self.sample_rate.max(1);
                let eff_ms = if dur > position_ms {
                    ((dur - position_ms) as u64).clamp(50, auto_ms)
                } else {
                    auto_ms
                };
                let rem_frames = (eff_ms * sr as u64) / 1000;
                let cur_frame = self.crossfade.current_frame.load(Ordering::Relaxed);
                self.crossfade.total_frames.store(cur_frame + rem_frames, Ordering::Release);
                return self.active_deck_mut().seek(position_ms);
            } else {
                self.abort_active_crossfade();
                return self.active_deck_mut().seek(position_ms);
            }
        }
        self.active_deck_mut().seek(position_ms)
    }
}

