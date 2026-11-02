//! Central thread-safe player coordinator integrating decoding, DSP, buffering, and device output.

use std::ffi::{c_char, c_void};
use std::fs::File;
use std::io::{Cursor, Read};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
#[cfg(not(target_arch = "wasm32"))]
use std::thread;
use std::thread::JoinHandle;
use std::time::Duration;

use crate::bridge::ffi::*;
use crate::buffer::{CustomByteSourceHandle, CustomDartByteSource, TripartiteBuffer};
use crate::core::renderer::{AudioRenderer, DspCommand};
use crate::decoder::{BoundaryInfo, ContainerFormat, FormatSniffer, SymphoniaEngine};
use crate::dsp::channel_matrix::ChannelMatrix;
use crate::dsp::crossfeed::CrossfeedMode;
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::resampler::RubatoResampler;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::{SilenceConfig, SilenceDetector};
use crate::dsp::sonic::SonicStream;
use crate::dsp::visualizer::VisualizerData;
use crate::dsp::DspChain;
use crate::sync::ring_buffer::{AudioProducer, AudioRingBuffer};
use crate::sync::seqlock::CachePaddedSeqlock;
use crate::sync::telemetry::{
    DeviceInfo as TelemetryDeviceInfo, EventCallback, EventType, MapEventData, MonotonicInstant,
    SpatializerData, TelemetryDispatcher,
};

pub const STATE_STOPPED: i32 = 0;
pub const STATE_PLAYING: i32 = 1;
pub const STATE_PAUSED: i32 = 2;
pub const STATE_COMPLETED: i32 = 3;
pub const STATE_BUFFERING: i32 = 4;
pub const STATE_ERROR: i32 = 5;
pub const STATE_OPENING: i32 = 6;

pub const MAP_STREAM_SEEK_CACHE_MISS: i32 = 0;
pub const MAP_STREAM_SEEK_CACHE_HIT: i32 = 1;
pub const MAP_STREAM_SEEK_CACHE_HIT_PREFETCH: i32 = 2;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct MiniaudioStreamStatus {
    pub buffer_capacity: usize,
    pub buffer_fill: usize,
    pub fill_percentage: f32,
    pub is_buffering: i32,
    pub is_eof: i32,
    pub read_cursor_byte: i64,
    pub range_start: i64,
    pub range_end: i64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MiniaudioPlayerStatus {
    pub position_ms: i64,
    pub duration_ms: i64,
    pub state: i32,
    pub is_playing: i32,
    pub is_buffering: i32,
    pub is_completed: i32,
    pub volume: f32,
    pub rate: f32,
    pub pitch: f32,
    pub bitrate: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub equalizer: EqualizerParams,
    pub device: MapDeviceInfo,
    pub silence: SilenceConfig,
    pub silence_saved_ms: i64,
    pub visualizer_enabled: i32,
    pub visualizer: VisualizerData,
    pub preamp_db: f32,
    pub replay_gain: ReplayGainConfig,
    pub balance: f32,
    pub mono_enabled: i32,
    pub crossfeed_mode: i32,
    pub spatializer_enabled: i32,
    pub spatializer_width: f32,
    pub reverb: ReverbConfig,
    pub limiter_enabled: i32,
}

pub type CompletionCallback = unsafe extern "C" fn(user_data: *mut c_void);

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

fn resolve_local_source_path(trimmed: &str) -> String {
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

#[cfg(not(target_arch = "wasm32"))]
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
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(3))
        .timeout_read(Duration::from_secs(5))
        .build()
}

#[cfg(not(target_arch = "wasm32"))]
fn apply_http_headers(
    mut req: ureq::Request,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
) -> ureq::Request {
    if let Some(hdrs) = headers {
        for h in hdrs {
            req = req.set(&h.key, &h.value);
        }
    }
    req
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
    trip_slot: Arc<Mutex<Option<TripartiteBuffer>>>,
    latest_icy: Arc<Mutex<Option<Vec<u8>>>>,
}

#[cfg(not(target_arch = "wasm32"))]
impl IcyDemuxReader {
    fn new(
        inner: Box<dyn Read + Send>,
        metaint: usize,
        trip_slot: Arc<Mutex<Option<TripartiteBuffer>>>,
        latest_icy: Arc<Mutex<Option<Vec<u8>>>>,
    ) -> Self {
        Self {
            inner,
            metaint,
            bytes_until_meta: metaint,
            trip_slot,
            latest_icy,
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
                if let Some(synthesized) = synthesize_icy_id3_container(&meta_buf) {
                    crate::map_log!(3, "ICY Metadata parsed (length={} bytes)", synthesized.len());
                    if let Ok(mut latest) = self.latest_icy.lock() {
                        *latest = Some(synthesized.clone());
                    }
                    if let Ok(guard) = self.trip_slot.lock() {
                        if let Some(ref trip) = *guard {
                            trip.set_icy_meta(&synthesized);
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

#[cfg(not(target_arch = "wasm32"))]
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
    let content_type = res.header("content-type").map(|s| s.to_string());
    let mut raw_bytes = Vec::new();
    res.into_reader().read_to_end(&mut raw_bytes).ok()?;
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
    let req = apply_http_headers(agent.get(url), headers).set("Range", &range_hdr);
    let res = req.call().ok()?;
    if res.status() != 206 {
        return None;
    }
    let expected = (end_inclusive - start + 1) as usize;
    let mut buf = Vec::with_capacity(expected.min(4 * 1024 * 1024));
    res.into_reader()
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
fn prefetch_initial_stream_bytes(reader: &mut impl Read, content_length: i64) -> Vec<u8> {
    let mut initial_data = Vec::with_capacity(131072);
    let mut read_buf = [0u8; 32768];

    loop {
        match reader.read(&mut read_buf) {
            Ok(0) => break,
            Ok(n) => {
                initial_data.extend_from_slice(&read_buf[..n]);
                if crate::hls::M3u8Parser::is_m3u8(&initial_data) {
                    break;
                }
                if initial_data.len() >= 65536 {
                    let (status, boundary) =
                        FormatSniffer::detect_head_boundary(&initial_data, content_length);
                    if status != crate::decoder::sniffer::BoundaryStatus::NeedMore {
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
        return Vec::new();
    }

    initial_data
}

#[cfg(not(target_arch = "wasm32"))]
fn spawn_network_streamer_thread(
    mut reader: Box<dyn Read + Send>,
    trip: TripartiteBuffer,
    abort_stream: Arc<AtomicBool>,
    decoder_running: Arc<AtomicBool>,
) {
    crate::map_log!(3, "Network streamer thread started");
    let _ = std::thread::Builder::new()
        .name("miniaudio-net-streamer".to_string())
        .spawn(move || {
            let mut chunk = vec![0u8; 32768];
            while !abort_stream.load(Ordering::Relaxed) && decoder_running.load(Ordering::Relaxed) {
                match reader.read(&mut chunk) {
                    Ok(0) => {
                        crate::map_log!(3, "Network streamer reached EOF");
                        trip.mark_eof();
                        break;
                    }
                    Ok(n) => {
                        crate::map_log!(5, "Network streamer read {} bytes", n);
                        let mut offset = 0;
                        while offset < n
                            && !abort_stream.load(Ordering::Relaxed)
                            && decoder_running.load(Ordering::Relaxed)
                        {
                            match trip.feed_chunk(&chunk[offset..n]) {
                                Ok(written) => offset += written,
                                Err(crate::buffer::BufferError::Busy) => {
                                    crate::map_log!(2, "Network streamer buffer busy, throttling 20ms");
                                    std::thread::sleep(Duration::from_millis(20));
                                }
                                Err(_) => return,
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => {
                        crate::map_log!(1, "Network streamer read error: {:?}", e);
                        break;
                    }
                }
            }
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
            .unwrap_or_else(|_| RubatoResampler::new(48000, 48000, d_ch, 1024).unwrap());

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
    #[allow(dead_code)]
    wake: Arc<(Mutex<bool>, Condvar)>,
    state: Arc<AtomicI32>,
    engine_arc: Arc<Mutex<Option<SymphoniaEngine>>>,
    producer_arc: Arc<Mutex<Option<AudioProducer>>>,
    seek_req: Arc<AtomicI64>,
    pos_ms: Arc<AtomicI64>,
    pos_frames: Arc<AtomicI64>,
    dur_ms: Arc<AtomicI64>,
    sr_arc: Arc<AtomicU32>,
    ch_arc: Arc<AtomicU32>,
    dev_sr_arc: Arc<AtomicU32>,
    dev_ch_arc: Arc<AtomicU32>,
    silence_cfg_arc: Arc<RwLock<SilenceConfig>>,
    silence_saved_arc: Arc<AtomicI64>,
    is_stream_arc: Arc<AtomicBool>,
    trip_buf_arc: Arc<RwLock<Option<TripartiteBuffer>>>,
    decoder_eof_arc: Arc<AtomicBool>,
    tele: Arc<TelemetryDispatcher>,
    completed_flag: Arc<AtomicBool>,
    buffering_flag: Arc<AtomicBool>,
    buffering_resumed_flag: Arc<AtomicBool>,
    visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    visualizer_enabled: Arc<AtomicBool>,
    completion_cb: Arc<RwLock<Option<(CompletionCallback, usize)>>>,
    #[allow(dead_code)]
    flush_generation: Arc<AtomicU64>,
    #[allow(dead_code)]
    flush_acknowledged: Arc<AtomicU64>,
    stream_reinit_needed: Arc<AtomicBool>,

    pipeline: PcmAdaptationPipeline,
    frame_buf: Vec<f32>,
    last_tele_pos: i64,
    last_vis_instant: MonotonicInstant,
    last_vis: VisualizerData,
}

impl DecoderWorker {
    #[cfg(not(target_arch = "wasm32"))]
    fn wait_for_wake(&self, timeout_ms: u64) {
        let (lock, cvar) = &*self.wake;
        let guard = lock.lock().unwrap();
        let _ = cvar.wait_timeout(guard, Duration::from_millis(timeout_ms));
    }

    #[cfg(target_arch = "wasm32")]
    fn wait_for_wake(&self, _timeout_ms: u64) {}

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
        if self.completed_flag.swap(false, Ordering::AcqRel) {
            let dur = self.dur_ms.load(Ordering::Relaxed);
            self.tele
                .post_event(EventType::Position, MapEventData { position_ms: dur });
            self.tele
                .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
            self.tele
                .post_event(EventType::IsCompleted, MapEventData { is_completed: 1 });
            self.tele.post_event(
                EventType::State,
                MapEventData {
                    state: STATE_COMPLETED,
                },
            );
            if let Ok(guard) = self.completion_cb.read() {
                if let Some((cb, udata)) = *guard {
                    unsafe {
                        cb(udata as *mut c_void);
                    }
                }
            }
        }

        if self.buffering_flag.swap(false, Ordering::AcqRel) {
            self.tele
                .post_event(EventType::IsBuffering, MapEventData { is_buffering: 1 });
            self.tele.post_event(
                EventType::State,
                MapEventData {
                    state: STATE_BUFFERING,
                },
            );
        }
        if self.buffering_resumed_flag.swap(false, Ordering::AcqRel) {
            self.tele
                .post_event(EventType::IsBuffering, MapEventData { is_buffering: 0 });
            self.tele.post_event(
                EventType::State,
                MapEventData {
                    state: STATE_PLAYING,
                },
            );
        }

        let cur_sr = self.sr_arc.load(Ordering::Relaxed);
        let cur_ch = self.ch_arc.load(Ordering::Relaxed) as usize;
        self.pipeline.sync_silence_format(cur_sr, cur_ch);
    }

    /// Processes a pending seek request if one exists.
    /// Returns `true` if the main worker loop should `continue` immediately.
    fn handle_pending_seek(&mut self) -> bool {
        let target_seek = self.seek_req.swap(-1, Ordering::SeqCst);
        if target_seek < 0 {
            return false;
        }
        crate::map_log!(4, "DecoderWorker executing seek to {}ms", target_seek);

        let cur_dev_sr = self.dev_sr_arc.load(Ordering::Relaxed).max(8000) as i64;
        let dur = self.dur_ms.load(Ordering::Relaxed);
        if dur > 0 && target_seek >= dur {
            self.decoder_eof_arc.store(true, Ordering::Relaxed);
            self.state.store(STATE_COMPLETED, Ordering::Relaxed);
            self.pos_ms.store(dur, Ordering::Relaxed);
            let f = if cur_dev_sr > 0 {
                (dur * cur_dev_sr * 1024) / 1000
            } else {
                0
            };
            self.pos_frames.store(f, Ordering::Relaxed);
            self.tele
                .post_event(EventType::Position, MapEventData { position_ms: dur });
            self.tele
                .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
            self.tele
                .post_event(EventType::IsCompleted, MapEventData { is_completed: 1 });
            self.tele.post_event(
                EventType::State,
                MapEventData {
                    state: STATE_COMPLETED,
                },
            );
            return true;
        }

        #[cfg(not(target_arch = "wasm32"))]
        if self.state.load(Ordering::Relaxed) == STATE_PLAYING {
            let cur_flush = self.flush_generation.load(Ordering::Acquire);
            let start_wait = MonotonicInstant::now();
            while self.flush_acknowledged.load(Ordering::Acquire) < cur_flush
                && start_wait.elapsed() < Duration::from_millis(15)
            {
                std::thread::yield_now();
            }
        }

        self.decoder_eof_arc.store(false, Ordering::Relaxed);
        if let Ok(mut eng_lock) = self.engine_arc.lock() {
            let mut reinit = false;
            if target_seek == 0 && self.is_stream_arc.load(Ordering::Relaxed) {
                if let Ok(guard) = self.trip_buf_arc.read() {
                    if let Some(ref trip) = *guard {
                        let (hit, contig) = trip.try_seek_cached(0);
                        if !hit || !contig {
                            trip.flush(0);
                        }
                        trip.set_decoding_audio(false);
                        let reader = trip.create_reader();
                        if let Ok(new_eng) = SymphoniaEngine::new(reader, None) {
                            *eng_lock = Some(new_eng);
                            reinit = true;
                        }
                        trip.set_decoding_audio(true);
                    }
                }
            }
            if !reinit {
                if let Some(ref mut eng) = *eng_lock {
                    let _ = eng.seek_ms(target_seek as u64);
                }
            }
        }

        self.pipeline.reset(target_seek == 0);
        self.silence_saved_arc.store(0, Ordering::Relaxed);
        self.tele.post_event(
            EventType::SilenceSaved,
            MapEventData {
                silence_saved_ms: 0,
            },
        );
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
        false
    }

    /// Ensures a flushed live stream re-initializes its `SymphoniaEngine` once data arrives.
    /// Returns `true` if ready to proceed, `false` if waiting for stream bytes.
    fn ensure_stream_initialized(&mut self) -> bool {
        if !self.stream_reinit_needed.load(Ordering::Acquire) {
            return true;
        }

        let maybe_reader = self.trip_buf_arc.read().ok().and_then(|guard| {
            let trip = guard.as_ref()?;
            let has_data =
                trip.head_size() > 0 || trip.range_end() > trip.range_start() || trip.is_eof();
            if has_data {
                Some(trip.create_reader())
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
            self.stream_reinit_needed.store(false, Ordering::Release);
            self.decoder_eof_arc.store(false, Ordering::Relaxed);
            self.pipeline.clear_pending_and_resampler();
        }
        true
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
        if self.state.load(Ordering::Relaxed) == STATE_BUFFERING && !self.is_producer_empty() {
            self.transition_to_playing_from_buffering();
        }
    }

    fn transition_to_playing_from_buffering(&self) {
        crate::map_log!(4, "DecoderWorker recovered from buffering -> PLAYING");
        self.state.store(STATE_PLAYING, Ordering::Relaxed);
        self.tele
            .post_event(EventType::IsBuffering, MapEventData { is_buffering: 0 });
        self.tele.post_event(
            EventType::State,
            MapEventData {
                state: STATE_PLAYING,
            },
        );
    }

    fn transition_to_buffering(&self) {
        crate::map_log!(4, "DecoderWorker transitioned to BUFFERING");
        self.state.store(STATE_BUFFERING, Ordering::Relaxed);
        self.tele
            .post_event(EventType::IsBuffering, MapEventData { is_buffering: 1 });
        self.tele.post_event(
            EventType::State,
            MapEventData {
                state: STATE_BUFFERING,
            },
        );
    }

    fn handle_eof(&mut self) {
        if !self.decoder_eof_arc.swap(true, Ordering::SeqCst) {
            crate::map_log!(3, "DecoderWorker reached EOF");
        }
        if self.is_stream_arc.load(Ordering::Relaxed) {
            let is_buf_eof = self
                .trip_buf_arc
                .read()
                .ok()
                .and_then(|g| g.as_ref().map(|b| b.is_eof()))
                .unwrap_or(true);

            if !is_buf_eof {
                self.transition_to_buffering();
                #[cfg(not(target_arch = "wasm32"))]
                thread::sleep(Duration::from_millis(15));
                return;
            }
        }

        self.pipeline.flush_resampler_into_pending();
        if !self.pipeline.drain_pending_to(&self.producer_arc) {
            self.wait_for_wake(4);
            return;
        }

        if self.state.load(Ordering::Relaxed) == STATE_BUFFERING {
            self.transition_to_playing_from_buffering();
        }

        #[cfg(not(target_arch = "wasm32"))]
        thread::sleep(Duration::from_millis(20));
    }

    fn decode_and_process_step(&mut self) {
        let mut decoded_ok = false;
        let mut eof_reached = false;

        if let Ok(mut eng_lock) = self.engine_arc.lock() {
            if let Some(ref mut eng) = *eng_lock {
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
                                && self.state.load(Ordering::Relaxed) != STATE_BUFFERING
                            {
                                self.transition_to_buffering();
                            }
                            #[cfg(not(target_arch = "wasm32"))]
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

        if eof_reached {
            self.handle_eof();
            return;
        }

        if decoded_ok && !self.frame_buf.is_empty() {
            self.decoder_eof_arc.store(false, Ordering::Relaxed);
            if self.state.load(Ordering::Relaxed) == STATE_BUFFERING {
                self.transition_to_playing_from_buffering();
            }

            let cur_track_sr = self.sr_arc.load(Ordering::Relaxed).max(8000);
            let cur_track_ch = (self.ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
            let cur_dev_sr = self.dev_sr_arc.load(Ordering::Relaxed).max(8000);
            let cur_dev_ch = (self.dev_ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
            let cur_silence_cfg = *self.silence_cfg_arc.read().unwrap();

            let new_saved = self.pipeline.process_frame(
                &self.frame_buf,
                cur_track_sr,
                cur_track_ch,
                cur_dev_sr,
                cur_dev_ch,
                cur_silence_cfg,
            );

            let old_saved = self.silence_saved_arc.swap(new_saved, Ordering::Relaxed);
            if new_saved != old_saved {
                self.tele.post_event(
                    EventType::SilenceSaved,
                    MapEventData {
                        silence_saved_ms: new_saved,
                    },
                );
            }

            let _ = self.pipeline.drain_pending_to(&self.producer_arc);
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn run(&mut self) {
        while self.running.load(Ordering::Relaxed) {
            self.poll_renderer_flags();

            if self.handle_pending_seek() {
                continue;
            }

            let cur_state = self.state.load(Ordering::Relaxed);
            if cur_state != STATE_PLAYING && cur_state != STATE_BUFFERING {
                self.wait_for_wake(30);
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

    #[cfg(target_arch = "wasm32")]
    fn step_quantum(&mut self) -> bool {
        if !self.running.load(Ordering::Relaxed) {
            return false;
        }

        self.poll_renderer_flags();

        if self.handle_pending_seek() {
            return true;
        }

        let cur_state = self.state.load(Ordering::Relaxed);
        if cur_state != STATE_PLAYING && cur_state != STATE_BUFFERING {
            return true;
        }

        if !self.ensure_stream_initialized() {
            return true;
        }

        self.dispatch_periodic_telemetry();
        self.check_buffering_recovery();

        for _ in 0..8 {
            if !self.pipeline.drain_pending_to(&self.producer_arc) {
                break;
            }
            if self.available_producer_slots() < 2048 {
                break;
            }
            if self.decoder_eof_arc.load(Ordering::Relaxed) {
                break;
            }
            self.decode_and_process_step();
        }

        true
    }
}

pub struct PlayerCoordinator {
    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut AudioRenderer,

    pub state: Arc<AtomicI32>,
    pub pause_on_device_change: Arc<AtomicBool>,
    pub position_ms: Arc<AtomicI64>,
    pub position_frames: Arc<AtomicI64>,
    pub duration_ms: Arc<AtomicI64>,
    pub volume: Arc<AtomicU32>,
    pub rate: Arc<AtomicU32>,
    pub pitch: Arc<AtomicU32>,
    pub bitrate: Arc<AtomicU32>,
    pub sample_rate: Arc<AtomicU32>,
    pub channels: Arc<AtomicU32>,
    pub device_sample_rate: Arc<AtomicU32>,
    pub device_channels: Arc<AtomicU32>,
    pub period_size_in_frames: Arc<AtomicU32>,
    pub silence_saved_ms: Arc<AtomicI64>,
    pub visualizer_enabled: Arc<AtomicBool>,

    pub is_stream: Arc<AtomicBool>,
    pub trip_buffer: Arc<RwLock<Option<TripartiteBuffer>>>,
    pub boundary_info: Arc<RwLock<Option<BoundaryInfo>>>,
    pub custom_source_handle: Arc<RwLock<Option<CustomByteSourceHandle>>>,

    pub telemetry: Arc<TelemetryDispatcher>,
    pub completion_cb: Arc<RwLock<Option<(CompletionCallback, usize)>>>,

    pub silence_config: Arc<RwLock<SilenceConfig>>,

    pub audio_producer: Arc<Mutex<Option<AudioProducer>>>,
    pub cmd_producer: Arc<Mutex<Option<rtrb::Producer<DspCommand>>>>,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,

    pub flush_generation: Arc<AtomicU64>,
    pub flush_acknowledged: Arc<AtomicU64>,
    pub completed_flag: Arc<AtomicBool>,
    pub buffering_flag: Arc<AtomicBool>,
    pub buffering_resumed_flag: Arc<AtomicBool>,

    // Cached DSP settings
    pub eq_params: Arc<RwLock<EqualizerParams>>,
    pub preamp_db: Arc<AtomicU32>,
    pub replay_gain: Arc<RwLock<ReplayGainConfig>>,
    pub balance: Arc<AtomicU32>,
    pub mono_enabled: Arc<AtomicBool>,
    pub spatializer_enabled: Arc<AtomicBool>,
    pub spatializer_width: Arc<AtomicU32>,
    pub crossfeed_mode: Arc<AtomicI32>,
    pub reverb_config: Arc<RwLock<ReverbConfig>>,
    pub limiter_enabled: Arc<AtomicBool>,

    pub engine: Arc<Mutex<Option<SymphoniaEngine>>>,
    pub seek_request_ms: Arc<AtomicI64>,
    pub decoder_eof: Arc<AtomicBool>,
    pub stream_reinit_needed: Arc<AtomicBool>,
    pub network_streamer_abort: Arc<AtomicBool>,

    pub decoder_running: Arc<AtomicBool>,
    pub decoder_wake: Arc<(Mutex<bool>, Condvar)>,
    pub decoder_thread: Option<JoinHandle<()>>,
}

// PlayerCoordinator is Send + Sync across threads
unsafe impl Send for PlayerCoordinator {}
unsafe impl Sync for PlayerCoordinator {}

impl PlayerCoordinator {
    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn new(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
        playback_device_id: *const c_char,
        on_completed: Option<CompletionCallback>,
        user_data: *mut c_void,
    ) -> Result<Box<Self>, i32> {
        Self::new_internal(
            target_sample_rate,
            target_channels,
            period_size,
            playback_device_id,
            on_completed,
            user_data,
            true,
        )
    }

    pub fn new_deck(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
    ) -> Result<Box<Self>, i32> {
        Self::new_internal(
            target_sample_rate,
            target_channels,
            period_size,
            std::ptr::null(),
            None,
            std::ptr::null_mut(),
            false,
        )
    }

    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    fn new_internal(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
        playback_device_id: *const c_char,
        on_completed: Option<CompletionCallback>,
        user_data: *mut c_void,
        with_device: bool,
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
        let channels = Arc::new(AtomicU32::new(ch));
        let device_sample_rate = Arc::new(AtomicU32::new(sr));
        let device_channels = Arc::new(AtomicU32::new(ch));
        let period_size_in_frames = Arc::new(AtomicU32::new(period));
        let silence_saved_ms = Arc::new(AtomicI64::new(0));
        let visualizer_enabled = Arc::new(AtomicBool::new(false));

        let is_stream = Arc::new(AtomicBool::new(false));
        let trip_buffer = Arc::new(RwLock::new(None));
        let boundary_info = Arc::new(RwLock::new(None));
        let custom_source_handle = Arc::new(RwLock::new(None));

        let telemetry = Arc::new(TelemetryDispatcher::new(None, std::ptr::null_mut()));
        let completion_cb = Arc::new(RwLock::new(on_completed.map(|cb| (cb, user_data as usize))));

        let silence_config = Arc::new(RwLock::new(SilenceConfig::default()));

        let ring_cap = (sr as usize * ch as usize * 3).max(262144);
        let (producer, consumer) = AudioRingBuffer::create(ring_cap);
        let audio_producer = Arc::new(Mutex::new(Some(producer)));

        let (cmd_prod, cmd_cons) = rtrb::RingBuffer::new(256);
        let cmd_producer = Arc::new(Mutex::new(Some(cmd_prod)));

        let visualizer_seqlock = Arc::new(CachePaddedSeqlock::new(VisualizerData::default()));
        let flush_generation = Arc::new(AtomicU64::new(0));
        let flush_acknowledged = Arc::new(AtomicU64::new(0));
        let completed_flag = Arc::new(AtomicBool::new(false));
        let buffering_flag = Arc::new(AtomicBool::new(false));
        let buffering_resumed_flag = Arc::new(AtomicBool::new(false));

        let eq_params = Arc::new(RwLock::new(EqualizerParams::default()));
        let preamp_db = Arc::new(AtomicU32::new(0.0f32.to_bits()));
        let replay_gain = Arc::new(RwLock::new(ReplayGainConfig::default()));
        let balance = Arc::new(AtomicU32::new(0.0f32.to_bits()));
        let mono_enabled = Arc::new(AtomicBool::new(false));
        let spatializer_enabled = Arc::new(AtomicBool::new(false));
        let spatializer_width = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let crossfeed_mode = Arc::new(AtomicI32::new(0));
        let reverb_config = Arc::new(RwLock::new(ReverbConfig::default()));
        let limiter_enabled = Arc::new(AtomicBool::new(true));

        let engine = Arc::new(Mutex::new(None));
        let seek_request_ms = Arc::new(AtomicI64::new(-1));
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
            flush_generation: flush_generation.clone(),
            flush_acknowledged: flush_acknowledged.clone(),
            local_flush_gen: 0,
            completed_flag: completed_flag.clone(),
            buffering_flag: buffering_flag.clone(),
            buffering_resumed_flag: buffering_resumed_flag.clone(),
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
        let renderer_ptr = Box::into_raw(Box::new(renderer));

        let mut device_ctx = std::ptr::null_mut();
        if with_device {
            let mut dev_res = 0;
            device_ctx = unsafe {
                map_device_create(
                    sr,
                    ch,
                    period,
                    playback_device_id,
                    renderer_ptr as *mut c_void,
                    &mut dev_res,
                )
            };

            if device_ctx.is_null() || dev_res != 0 {
                unsafe {
                    drop(Box::from_raw(renderer_ptr));
                }
                return Err(dev_res);
            }

            let actual_sr = unsafe { map_device_get_sample_rate(device_ctx) };
            let actual_ch = unsafe { map_device_get_channels(device_ctx) };
            if actual_sr > 0 {
                device_sample_rate.store(actual_sr, Ordering::SeqCst);
            }
            if actual_ch > 0 {
                device_channels.store(actual_ch, Ordering::SeqCst);
            }
        }

        let mut coordinator = Box::new(Self {
            device_ctx,
            renderer_ptr,
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
            channels,
            device_sample_rate,
            device_channels,
            period_size_in_frames,
            silence_saved_ms,
            visualizer_enabled,
            is_stream,
            trip_buffer,
            boundary_info,
            custom_source_handle,
            telemetry,
            completion_cb,
            silence_config,
            audio_producer,
            cmd_producer,
            visualizer_seqlock,
            flush_generation,
            flush_acknowledged,
            completed_flag,
            buffering_flag,
            buffering_resumed_flag,
            eq_params,
            preamp_db,
            replay_gain,
            balance,
            mono_enabled,
            spatializer_enabled,
            spatializer_width,
            crossfeed_mode,
            reverb_config,
            limiter_enabled,
            engine,
            seek_request_ms,
            decoder_eof,
            stream_reinit_needed,
            network_streamer_abort,
            decoder_running,
            decoder_wake,
            decoder_thread: None,
        });

        coordinator.start_decoder_loop();
        Ok(coordinator)
    }

    pub fn send_dsp_command(&self, cmd: DspCommand) {
        if let Ok(mut guard) = self.cmd_producer.lock() {
            if let Some(ref mut prod) = *guard {
                let _ = prod.push(cmd);
            }
        }
    }

    pub fn set_spatial_enabled(&mut self, enabled: bool) {
        self.send_dsp_command(DspCommand::SetSpatialEnabled(enabled));
    }

    pub fn set_spatial_listener(&mut self, listener: crate::dsp::spatial::SpatialListener) {
        self.send_dsp_command(DspCommand::SetSpatialListener(listener));
    }

    pub fn set_spatial_emitter(&mut self, emitter: crate::dsp::spatial::SpatialEmitter) {
        self.send_dsp_command(DspCommand::SetSpatialEmitter(emitter));
    }

    pub fn set_spatial_doppler_factor(&mut self, factor: f32) {
        self.send_dsp_command(DspCommand::SetSpatialDopplerFactor(factor));
    }

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
            producer_arc: self.audio_producer.clone(),
            seek_req: self.seek_request_ms.clone(),
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
            trip_buf_arc: self.trip_buffer.clone(),
            decoder_eof_arc: self.decoder_eof.clone(),
            tele: self.telemetry.clone(),
            completed_flag: self.completed_flag.clone(),
            buffering_flag: self.buffering_flag.clone(),
            buffering_resumed_flag: self.buffering_resumed_flag.clone(),
            visualizer_seqlock: self.visualizer_seqlock.clone(),
            visualizer_enabled: self.visualizer_enabled.clone(),
            completion_cb: self.completion_cb.clone(),
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

        #[cfg(not(target_arch = "wasm32"))]
        {
            self.decoder_thread = thread::Builder::new()
                .name("map-decoder".to_string())
                .spawn(move || worker.run())
                .ok();
        }

        #[cfg(target_arch = "wasm32")]
        {
            crate::bridge::ffi::wasm_register_decoder_task(Box::new(move || worker.step_quantum()));
        }
    }

    fn post_current_device_telemetry(&self) {
        let mut dev_info = MapDeviceInfo::default();
        let _ = self.get_current_device(&mut dev_info);
        let tele_dev = TelemetryDeviceInfo {
            id: dev_info.id,
            effective_id: dev_info.effective_id,
            name: dev_info.name,
            is_default: dev_info.is_default,
            is_auto: dev_info.is_auto,
        };
        self.telemetry
            .post_event(EventType::Device, MapEventData { device: tele_dev });
    }

    pub fn on_device_notification(&mut self, _notification_type: i32) {
        if self.pause_on_device_change.load(Ordering::Relaxed)
            && self.state.load(Ordering::Relaxed) == STATE_PLAYING
        {
            let _ = self.pause();
        }
        self.post_current_device_telemetry();
    }

    pub fn set_event_callback(
        &self,
        callback: Option<EventCallback>,
        user_data: *mut c_void,
    ) -> i32 {
        self.telemetry.set_callback(callback, user_data);
        MAP_SUCCESS
    }

    fn mark_open_error(&self, err_code: i32) -> i32 {
        self.state.store(STATE_ERROR, Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::State, MapEventData { state: STATE_ERROR });
        err_code
    }

    pub fn begin_open(&mut self) -> i32 {
        let _ = self.stop();
        self.network_streamer_abort.store(true, Ordering::Release);
        self.is_stream.store(false, Ordering::Release);
        if let Ok(mut guard) = self.trip_buffer.write() {
            if let Some(ref trip) = *guard {
                trip.abort();
            }
            *guard = None;
        }
        if let Ok(mut guard) = self.boundary_info.write() {
            *guard = None;
        }
        self.stream_reinit_needed.store(false, Ordering::Release);
        *self.custom_source_handle.write().unwrap() = None;
        *self.engine.lock().unwrap() = None;
        self.decoder_eof.store(false, Ordering::Relaxed);
        self.silence_saved_ms.store(0, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::SilenceSaved,
            MapEventData {
                silence_saved_ms: 0,
            },
        );
        self.state.store(STATE_OPENING, Ordering::Relaxed);
        self.position_ms.store(0, Ordering::Relaxed);
        self.position_frames.store(0, Ordering::Relaxed);
        self.duration_ms.store(0, Ordering::Relaxed);
        self.bitrate.store(0, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_OPENING,
            },
        );
        MAP_SUCCESS
    }

    pub fn open_source(
        &mut self,
        source: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
    ) -> i32 {
        let trimmed = source.trim();
        crate::map_log!(3, "open_source: source={}", trimmed);
        if trimmed.starts_with("http://")
            || trimmed.starts_with("https://")
            || trimmed.starts_with("icy://")
        {
            let url = if let Some(stripped) = trimmed.strip_prefix("icy://") {
                format!("http://{}", stripped)
            } else {
                trimmed.to_string()
            };
            self.open_network(&url, headers)
        } else {
            let resolved = resolve_local_source_path(trimmed);
            self.open_file(&resolved)
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub fn open_network(
        &mut self,
        _url: &str,
        _headers: Option<&[crate::api::types::RustHttpHeader]>,
    ) -> i32 {
        self.mark_open_error(MAP_ERROR_UNSUPPORTED)
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn open_hls_network(
        &mut self,
        agent: ureq::Agent,
        url: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
        mut m3u8_bytes: Vec<u8>,
        reader: &mut impl Read,
    ) -> i32 {
        crate::map_log!(3, "open_hls_network: url={}", url);
        let _ = reader.read_to_end(&mut m3u8_bytes);
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
                let media_url = resolve_hls_uri(url, &first_var.uri);
                let req = apply_http_headers(agent.get(&media_url), headers);
                let Ok(res) = req.call() else {
                    crate::map_log!(1, "open_hls_network failed to fetch media playlist from {}", media_url);
                    return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
                };
                let mut media_bytes = Vec::new();
                if res.into_reader().read_to_end(&mut media_bytes).is_err() {
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

        let first_seg_url = resolve_hls_uri(&base_media_url, &segments[0].uri);
        let Some((first_audio, seg_fmt)) = fetch_hls_segment_audio(&agent, &first_seg_url, headers)
        else {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        };

        let res_code = self.open_stream_ex(&first_audio, None, -1, true, 4 * 1024 * 1024, seg_fmt);
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

        self.network_streamer_abort.store(true, Ordering::Release);
        let new_abort = Arc::new(AtomicBool::new(false));
        self.network_streamer_abort = new_abort.clone();

        if let Some(trip) = self.trip_buffer.read().unwrap().clone() {
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
                                match trip.feed_chunk(&audio_bytes[offset..]) {
                                    Ok(written) => offset += written,
                                    Err(crate::buffer::BufferError::Busy) => {
                                        std::thread::sleep(Duration::from_millis(20));
                                    }
                                    Err(_) => return,
                                }
                            }
                        }
                    }
                    trip.mark_eof();
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
        let _ = self.begin_open();
        crate::map_log!(3, "open_network: connecting to url={}", url);

        let agent = build_network_agent();
        let req = apply_http_headers(agent.get(url), headers).set("Icy-MetaData", "1");

        let res = match req.call() {
            Ok(r) => r,
            Err(ureq::Error::Status(code, _)) => {
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
                crate::map_log!(1, "open_network failed: connection error for {}: {}", url, err);
                return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
            }
        };

        let content_length: i64 = res
            .header("content-length")
            .and_then(|s| s.parse().ok())
            .unwrap_or(-1);
        let content_type = res.header("content-type").map(|s| s.to_string());
        let icy_metaint: usize = res
            .header("icy-metaint")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let encoding_format = infer_network_encoding_format(url, content_type.as_deref());
        crate::map_log!(
            4,
            "open_network response: content_length={}, content_type={:?}, icy_metaint={}",
            content_length,
            content_type,
            icy_metaint
        );

        let trip_slot: Arc<Mutex<Option<TripartiteBuffer>>> = Arc::new(Mutex::new(None));
        let latest_icy: Arc<Mutex<Option<Vec<u8>>>> = Arc::new(Mutex::new(None));

        let mut reader: Box<dyn Read + Send> = if icy_metaint > 0 {
            Box::new(IcyDemuxReader::new(
                Box::new(res.into_reader()),
                icy_metaint,
                trip_slot.clone(),
                latest_icy.clone(),
            ))
        } else {
            Box::new(res.into_reader())
        };

        let initial_data = prefetch_initial_stream_bytes(&mut reader, content_length);
        if initial_data.is_empty() {
            crate::map_log!(1, "open_network failed: empty initial stream bytes from {}", url);
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        }

        if crate::hls::M3u8Parser::is_m3u8(&initial_data) {
            return self.open_hls_network(agent, url, headers, initial_data, &mut reader);
        }

        let mut tail_data: Option<Vec<u8>> = None;
        let mut forced_audio_end: Option<u64> = None;

        if content_length > 0 && (initial_data.len() as i64) < content_length {
            let (_status, boundary) =
                FormatSniffer::detect_head_boundary(&initial_data, content_length);
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
            } else if FormatSniffer::container_needs_tail_scan(boundary.container) {
                let floor = boundary.audio_start.max(0);
                let probe_len = 65536i64.min(content_length - floor);
                if probe_len > 0 {
                    let tail_offset = content_length - probe_len;
                    if let Some(probed) =
                        fetch_range_bytes(&agent, url, headers, tail_offset, content_length - 1)
                    {
                        let (_t_status, audio_end) = FormatSniffer::detect_tail_boundary(
                            boundary.container,
                            &probed,
                            tail_offset,
                            content_length,
                            boundary.audio_start,
                        );
                        if audio_end > 0 && audio_end < content_length && audio_end >= tail_offset {
                            let rel_start = (audio_end - tail_offset) as usize;
                            tail_data = Some(probed[rel_start..].to_vec());
                            forced_audio_end = Some(audio_end as u64);
                        }
                    }
                }
            }
        }

        let is_live = content_length <= 0;
        let res_code = self.open_stream_ex(
            &initial_data,
            tail_data.as_deref(),
            content_length,
            is_live,
            4 * 1024 * 1024,
            encoding_format,
        );
        if res_code != MAP_SUCCESS {
            return res_code;
        }

        if let Some(trip) = self.trip_buffer.read().unwrap().clone() {
            if let Some(ae) = forced_audio_end {
                trip.set_audio_end(ae);
                if let Some(ref td) = tail_data {
                    trip.set_tail(td, Some(ae));
                }
                if let Ok(mut b_guard) = self.boundary_info.write() {
                    if let Some(ref mut b) = *b_guard {
                        b.audio_end = ae as i64;
                    }
                }
            }
            if let Ok(guard) = latest_icy.lock() {
                if let Some(ref icy_bytes) = *guard {
                    trip.set_icy_meta(icy_bytes);
                }
            }
            if let Ok(mut slot) = trip_slot.lock() {
                *slot = Some(trip.clone());
            }

            self.network_streamer_abort.store(true, Ordering::Release);
            let new_abort = Arc::new(AtomicBool::new(false));
            self.network_streamer_abort = new_abort.clone();

            spawn_network_streamer_thread(reader, trip, new_abort, self.decoder_running.clone());
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

    pub fn open_file(&mut self, path: &str) -> i32 {
        let _ = self.begin_open();
        crate::map_log!(3, "open_file: path={}", path);

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

        let mut header = [0u8; 8192];
        let mut header_len = 0;
        if let Ok(mut f) = File::open(path) {
            if let Ok(n) = f.read(&mut header) {
                header_len = n;
            }
        }

        let (_status, boundary) =
            FormatSniffer::detect_head_boundary(&header[..header_len], file_size as i64);
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

        self.init_engine(eng, false, file_size, &header[..header_len]);
        crate::map_log!(3, "open_file successfully opened: {}", path);
        MAP_SUCCESS
    }

    pub fn open_memory(&mut self, data: &[u8], _take_ownership: bool) -> i32 {
        self.open_memory_with_hint(data, None)
    }

    pub fn open_memory_with_hint(&mut self, data: &[u8], hint_ext: Option<&str>) -> i32 {
        let _ = self.begin_open();
        crate::map_log!(3, "open_memory: size={}, hint={:?}", data.len(), hint_ext);

        let (_status, boundary) = FormatSniffer::detect_head_boundary(data, data.len() as i64);
        let effective_hint = boundary.container.hint_extension().or(hint_ext);
        crate::map_log!(
            4,
            "open_memory sniffed: container={:?}, effective_hint={:?}",
            boundary.container,
            effective_hint
        );

        let cursor = Cursor::new(data.to_vec());
        let eng = match SymphoniaEngine::new(cursor, effective_hint) {
            Ok(e) => e,
            Err(e) => {
                crate::map_log!(1, "open_memory failed: decode error: {:?}", e);
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };

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
            TripartiteBuffer::DEFAULT_RING_CAPACITY
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
        let trip = TripartiteBuffer::new(cap, tot, is_live);

        let mut container = ContainerFormat::Unknown;
        if !initial_data.is_empty() {
            let (_status, boundary) = FormatSniffer::detect_head_boundary(initial_data, total_size);
            container = boundary.container;
            if boundary.audio_start > 0 {
                let head_len = (boundary.audio_start as usize).min(initial_data.len());
                trip.set_head(&initial_data[..head_len]);
                trip.set_audio_start(boundary.audio_start as u64);
                if initial_data.len() > head_len {
                    let _ = trip.feed_chunk(&initial_data[head_len..]);
                }
            } else if boundary.audio_start == 0 {
                trip.set_audio_start(0);
                let _ = trip.feed_chunk(initial_data);
            } else {
                let _ = trip.feed_chunk(initial_data);
            }
            if boundary.audio_end > 0 {
                trip.set_audio_end(boundary.audio_end as u64);
            }
            *self.boundary_info.write().unwrap() = Some(boundary);
        }

        if let Some(tail) = tail_data {
            if !tail.is_empty() {
                trip.set_tail(tail, None);
            }
        }

        let hint = container
            .hint_extension()
            .or_else(|| encoding_format_to_extension(encoding_format));

        let reader = trip.create_reader();
        let eng = match SymphoniaEngine::new(reader, hint) {
            Ok(e) => e,
            Err(e) => {
                crate::map_log!(1, "open_stream_ex failed: SymphoniaEngine::new failed for hint={:?}: {:?}", hint, e);
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };
        trip.set_decoding_audio(true);

        let tot = trip.total_size().unwrap_or(0);
        *self.trip_buffer.write().unwrap() = Some(trip);
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
        initial_bytes: &[u8],
    ) -> i32 {
        let _ = self.begin_open();
        crate::map_log!(
            3,
            "open_custom_source: total_size={:?}, is_seekable={}, initial_bytes={}",
            total_size,
            is_seekable,
            initial_bytes.len()
        );

        let hint = if !initial_bytes.is_empty() {
            let (_status, boundary) = FormatSniffer::detect_head_boundary(
                initial_bytes,
                total_size.map(|s| s as i64).unwrap_or(-1),
            );
            boundary.container.hint_extension()
        } else {
            None
        };

        *self.custom_source_handle.write().unwrap() = Some(handle);

        let eng = match SymphoniaEngine::new(source, hint) {
            Ok(e) => e,
            Err(e) => {
                crate::map_log!(1, "open_custom_source failed: SymphoniaEngine::new failed: {:?}", e);
                *self.custom_source_handle.write().unwrap() = None;
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };

        self.init_engine(eng, !is_seekable, total_size.unwrap_or(0), initial_bytes);
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
        if let Some(ref handle) = *self.custom_source_handle.read().unwrap() {
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
        if let Some(ref handle) = *self.custom_source_handle.read().unwrap() {
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
        let ch = eng.channels();
        let mut dur = if is_live {
            0
        } else {
            eng.duration_ms().unwrap_or(0) as i64
        };

        if !is_live && dur <= 0 {
            if let Ok(guard) = self.trip_buffer.read() {
                if let Some(ref trip) = *guard {
                    let tail = trip.tail_data();
                    if !tail.is_empty() {
                        if let Ok(b_guard) = self.boundary_info.read() {
                            if let Some(boundary) = *b_guard {
                                if let Some(d) = FormatSniffer::extract_tail_duration_ms(
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

        if !is_live && dur <= 0 && total_bytes > 0 && !initial_data.is_empty() {
            if let Some((_br, d)) =
                FormatSniffer::sniff_stream_info(initial_data, total_bytes as i64)
            {
                if d > 0 {
                    dur = d;
                }
            }
        }

        let bitrate = if dur > 0 && total_bytes > 0 {
            ((total_bytes * 8000) / dur as u64) as u32
        } else if sr > 0 && ch > 0 {
            sr * ch * 16
        } else {
            0
        };

        {
            let mut eng_lock = self.engine.lock().unwrap();
            *eng_lock = Some(eng);
            self.sample_rate.store(sr, Ordering::SeqCst);
            self.channels.store(ch, Ordering::SeqCst);
            self.duration_ms.store(dur, Ordering::SeqCst);
            self.bitrate.store(bitrate, Ordering::SeqCst);
            self.is_stream.store(is_stream, Ordering::SeqCst);
            self.decoder_eof.store(false, Ordering::SeqCst);
            self.position_ms.store(0, Ordering::SeqCst);
            self.position_frames.store(0, Ordering::SeqCst);
            self.flush_generation.fetch_add(1, Ordering::SeqCst);
            #[cfg(target_arch = "wasm32")]
            if !self.renderer_ptr.is_null() {
                unsafe {
                    (*self.renderer_ptr).acknowledge_flush_if_needed();
                }
            }
        }

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
                        duration_ms: br.duration_ms,
                        fill_percentage: br.fill_percentage,
                        stream_percentage: br.stream_percentage,
                        is_buffering: br.is_buffering,
                        is_eof: br.is_eof,
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

    pub fn is_live_stream(&self) -> bool {
        self.trip_buffer
            .read()
            .map(|g| g.as_ref().map(|t| t.is_live()).unwrap_or(false))
            .unwrap_or(false)
    }

    pub fn stream_feed(&mut self, data: &[u8]) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            match trip.feed_chunk(data) {
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
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.flush(new_stream_offset as u64);
            self.decoder_eof.store(false, Ordering::Relaxed);
            self.flush_generation.fetch_add(1, Ordering::Release);
            #[cfg(target_arch = "wasm32")]
            if !self.renderer_ptr.is_null() {
                unsafe {
                    (*self.renderer_ptr).acknowledge_flush_if_needed();
                }
            }
            if trip.is_live() {
                self.stream_reinit_needed.store(true, Ordering::Release);
            }
            let (_, cvar) = &*self.decoder_wake;
            cvar.notify_all();
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    fn complete_at_duration(&self, dur: i64) {
        self.decoder_eof.store(true, Ordering::Relaxed);
        self.state.store(STATE_COMPLETED, Ordering::Relaxed);
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
        self.seek_request_ms.store(-1, Ordering::SeqCst);
        self.flush_generation.fetch_add(1, Ordering::Release);
        #[cfg(target_arch = "wasm32")]
        if !self.renderer_ptr.is_null() {
            unsafe {
                (*self.renderer_ptr).acknowledge_flush_if_needed();
            }
        }

        self.telemetry
            .post_event(EventType::Position, MapEventData { position_ms: dur });
        self.telemetry
            .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
        self.telemetry
            .post_event(EventType::IsCompleted, MapEventData { is_completed: 1 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_COMPLETED,
            },
        );
        if let Ok(guard) = self.completion_cb.read() {
            if let Some((cb, udata)) = *guard {
                unsafe {
                    cb(udata as *mut c_void);
                }
            }
        }
    }

    fn dispatch_seek_to_decoder(&mut self, position_ms: i64) {
        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur > 0 && position_ms >= dur {
            self.complete_at_duration(dur);
            return;
        }

        self.decoder_eof.store(false, Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::IsCompleted, MapEventData { is_completed: 0 });
        if self.state.load(Ordering::Relaxed) == STATE_COMPLETED {
            self.state.store(STATE_PAUSED, Ordering::Relaxed);
            self.telemetry.post_event(
                EventType::State,
                MapEventData {
                    state: STATE_PAUSED,
                },
            );
        }
        self.flush_generation.fetch_add(1, Ordering::Release);
        #[cfg(target_arch = "wasm32")]
        if !self.renderer_ptr.is_null() {
            unsafe {
                (*self.renderer_ptr).acknowledge_flush_if_needed();
            }
        }

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

        self.seek_request_ms.store(position_ms, Ordering::SeqCst);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();
    }

    pub fn stream_seek(&mut self, position_ms: i64, new_stream_offset: i64) -> i32 {
        let (is_hit, is_contiguous) = {
            if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
                trip.try_seek_cached(new_stream_offset as u64)
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
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.mark_eof();
            let (_, cvar) = &*self.decoder_wake;
            cvar.notify_all();
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_get_status(&self, out_status: &mut MiniaudioStreamStatus) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            let r = trip.get_range();
            let cap = trip.ring_capacity();
            out_status.buffer_capacity = cap;
            out_status.buffer_fill = (r.end_byte.saturating_sub(r.start_byte)).max(0) as usize;
            out_status.fill_percentage = r.fill_percentage * 100.0;
            out_status.is_buffering =
                (self.state.load(Ordering::Relaxed) == STATE_BUFFERING) as i32;
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
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            let r = trip.get_range();
            out_range.start_ms = 0;
            out_range.duration_ms = duration;
            out_range.fill_percentage = r.fill_percentage * 100.0;
            out_range.stream_percentage = r.stream_percentage * 100.0;
            if r.total_bytes > 0 && duration > 0 {
                out_range.end_ms =
                    ((r.end_byte as f64 / r.total_bytes as f64) * duration as f64) as i64;
            } else {
                out_range.end_ms = 0;
            }
            out_range.is_buffering = (self.state.load(Ordering::Relaxed) == STATE_BUFFERING) as i32;
            out_range.is_eof = r.is_eof;
            MAP_SUCCESS
        } else {
            out_range.start_ms = 0;
            out_range.end_ms = duration.max(0);
            out_range.duration_ms = duration.max(0);
            out_range.fill_percentage = if duration > 0 { 100.0 } else { 0.0 };
            out_range.stream_percentage = if duration > 0 { 100.0 } else { 0.0 };
            out_range.is_buffering = 0;
            out_range.is_eof = 1;
            MAP_SUCCESS
        }
    }

    pub fn stream_get_seek_byte(&self, position_ms: i64) -> i64 {
        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur <= 0 {
            return -1;
        }
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            if let Some(tot) = trip.total_size() {
                let start = trip.audio_start() as i64;
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
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.audio_start() as i64
        } else {
            0
        }
    }

    pub fn stream_get_pinned_head_size(&self) -> i64 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.head_size() as i64
        } else {
            0
        }
    }

    pub fn get_meta_bytes_version(&self) -> u32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.meta_version()
        } else {
            0
        }
    }

    pub fn get_meta_bytes_size(&self) -> usize {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.get_meta_bytes().len()
        } else {
            0
        }
    }

    pub fn copy_meta_bytes(&self, out: &mut [u8]) -> usize {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.copy_meta_bytes(out)
        } else {
            0
        }
    }

    pub fn set_icy_meta(&mut self, data: &[u8]) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.set_icy_meta(data);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn probe_tail(&mut self, tail_data: &[u8], tail_offset: i64) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.probe_tail(tail_data, tail_offset as u64);
            if self.duration_ms.load(Ordering::Relaxed) <= 0 {
                let sr = self.sample_rate.load(Ordering::Relaxed);
                if let Ok(b_guard) = self.boundary_info.read() {
                    if let Some(boundary) = *b_guard {
                        if let Some(dur) = FormatSniffer::extract_tail_duration_ms(
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

    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn read_pcm_frames(
        &mut self,
        frames_out: *mut f32,
        frame_count: u32,
        out_frames_read: *mut u32,
    ) -> i32 {
        if frames_out.is_null() || out_frames_read.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        if !self.renderer_ptr.is_null() {
            unsafe {
                (*self.renderer_ptr).render_pcm(frames_out, frame_count as usize);
            }
        }
        unsafe {
            *out_frames_read = frame_count;
        }
        MAP_SUCCESS
    }

    pub fn play(&mut self) -> i32 {
        let cur = self.state.load(Ordering::Relaxed);
        crate::map_log!(3, "play() called (current_state={})", cur);
        if cur == STATE_OPENING || cur == STATE_ERROR {
            return MAP_ERROR_INVALID_STATE;
        }

        if let Ok(guard) = self.trip_buffer.read() {
            if let Some(ref trip) = *guard {
                trip.clear_abort();
            }
        }
        self.decoder_eof.store(false, Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::IsCompleted, MapEventData { is_completed: 0 });

        if !self.device_ctx.is_null() {
            unsafe {
                map_device_start(self.device_ctx);
            }
        }

        self.state.store(STATE_PLAYING, Ordering::Relaxed);
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
        if cur == STATE_OPENING || cur == STATE_ERROR {
            return MAP_ERROR_INVALID_STATE;
        }

        #[cfg(target_arch = "wasm32")]
        if !self.device_ctx.is_null() {
            unsafe {
                map_device_stop(self.device_ctx);
            }
        }

        self.state.store(STATE_PAUSED, Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_PAUSED,
            },
        );

        MAP_SUCCESS
    }

    pub fn stop(&mut self) -> i32 {
        crate::map_log!(3, "stop() called");
        #[cfg(target_arch = "wasm32")]
        if !self.device_ctx.is_null() {
            unsafe {
                map_device_stop(self.device_ctx);
            }
        }

        self.network_streamer_abort.store(true, Ordering::Release);
        self.decoder_eof.store(false, Ordering::Relaxed);
        if let Ok(guard) = self.trip_buffer.read() {
            if let Some(ref trip) = *guard {
                trip.abort();
                if trip.is_live() {
                    self.stream_reinit_needed.store(true, Ordering::Release);
                }
            }
        }
        self.telemetry
            .post_event(EventType::IsCompleted, MapEventData { is_completed: 0 });
        if self.state.load(Ordering::Relaxed) == STATE_COMPLETED {
            self.state.store(STATE_PAUSED, Ordering::Relaxed);
            self.telemetry.post_event(
                EventType::State,
                MapEventData {
                    state: STATE_PAUSED,
                },
            );
        }
        self.flush_generation.fetch_add(1, Ordering::Release);
        #[cfg(target_arch = "wasm32")]
        if !self.renderer_ptr.is_null() {
            unsafe {
                (*self.renderer_ptr).acknowledge_flush_if_needed();
            }
        }

        self.state.store(STATE_STOPPED, Ordering::Relaxed);
        self.position_ms.store(0, Ordering::Relaxed);
        self.position_frames.store(0, Ordering::Relaxed);
        self.silence_saved_ms.store(0, Ordering::Relaxed);
        if !self.is_live_stream() && self.engine.lock().unwrap().is_some() {
            self.seek_request_ms.store(0, Ordering::SeqCst);
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
            .post_event(EventType::Position, MapEventData { position_ms: 0 });
        self.telemetry.post_event(
            EventType::State,
            MapEventData {
                state: STATE_STOPPED,
            },
        );

        MAP_SUCCESS
    }

    pub fn seek(&mut self, position_ms: i64) -> i32 {
        crate::map_log!(4, "seek(position_ms={})", position_ms);
        let cur = self.state.load(Ordering::Relaxed);
        if cur == STATE_OPENING || cur == STATE_ERROR {
            return MAP_ERROR_INVALID_STATE;
        }
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
        let r = rate.clamp(0.25, 4.0);
        crate::map_log!(4, "set_rate(rate={})", r);
        self.rate.store(r.to_bits(), Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::Rate, MapEventData { rate: r });
        MAP_SUCCESS
    }

    pub fn set_pitch(&mut self, pitch: f32) -> i32 {
        let p = pitch.clamp(0.5, 2.0);
        crate::map_log!(4, "set_pitch(pitch={})", p);
        self.pitch.store(p.to_bits(), Ordering::Relaxed);
        self.telemetry
            .post_event(EventType::Pitch, MapEventData { pitch: p });
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

    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn set_device(&mut self, device_id: *const c_char) -> i32 {
        crate::map_log!(3, "set_device requested");
        if self.device_ctx.is_null() {
            return MAP_ERROR_INVALID_STATE;
        }
        let ret = unsafe { map_device_set_device(self.device_ctx, device_id) };
        self.post_current_device_telemetry();
        ret
    }

    pub fn get_current_device(&self, out_device: &mut MapDeviceInfo) -> i32 {
        if self.device_ctx.is_null() {
            return MAP_ERROR_INVALID_STATE;
        }
        unsafe {
            map_device_get_current_device_info(self.device_ctx, out_device as *mut MapDeviceInfo)
        }
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
        *self.eq_params.write().unwrap() = *params;
        self.send_dsp_command(DspCommand::SetEqualizerParams(*params));
        self.telemetry
            .post_event(EventType::Equalizer, MapEventData { equalizer: *params });
        MAP_SUCCESS
    }

    pub fn set_equalizer_band(&mut self, band: u32, gain_db: f32) -> i32 {
        crate::map_log!(4, "set_equalizer_band(band={}, gain_db={})", band, gain_db);
        self.eq_params
            .write()
            .unwrap()
            .set_band(band as usize, gain_db);
        self.send_dsp_command(DspCommand::SetEqualizerBand {
            band: band as usize,
            gain_db,
        });
        MAP_SUCCESS
    }

    pub fn get_equalizer(&self, out: &mut EqualizerParams) -> i32 {
        *out = *self.eq_params.read().unwrap();
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
        *self.replay_gain.write().unwrap() = rg;
        self.send_dsp_command(DspCommand::SetReplayGain(rg));
        self.telemetry
            .post_event(EventType::ReplayGain, MapEventData { replay_gain: rg });
        MAP_SUCCESS
    }

    pub fn clear_replay_gain(&mut self) -> i32 {
        crate::map_log!(4, "clear_replay_gain()");
        let rg = ReplayGainConfig::default();
        *self.replay_gain.write().unwrap() = rg;
        self.send_dsp_command(DspCommand::SetReplayGain(rg));
        self.telemetry
            .post_event(EventType::ReplayGain, MapEventData { replay_gain: rg });
        MAP_SUCCESS
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

    pub fn set_crossfeed(&mut self, mode: i32) -> i32 {
        crate::map_log!(4, "set_crossfeed(mode={})", mode);
        let cf_mode = match mode {
            1 => CrossfeedMode::MoffatBauer,
            2 => CrossfeedMode::ChuMoy,
            _ => CrossfeedMode::Off,
        };
        self.crossfeed_mode.store(mode, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetCrossfeed(cf_mode));
        self.telemetry.post_event(
            EventType::Crossfeed,
            MapEventData {
                crossfeed_mode: mode,
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
        *self.reverb_config.write().unwrap() = rev;
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
        *self.silence_config.write().unwrap() = *config;
        self.telemetry.post_event(
            EventType::SilenceConfig,
            MapEventData {
                silence_config: *config,
            },
        );
        MAP_SUCCESS
    }

    pub fn get_silence_config(&self, out: &mut SilenceConfig) -> i32 {
        *out = *self.silence_config.read().unwrap();
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
    pub fn render_pcm(&self, output_frames: *mut f32, frame_count: usize) {
        if !self.renderer_ptr.is_null() && !output_frames.is_null() && frame_count > 0 {
            unsafe {
                (*self.renderer_ptr).render_pcm(output_frames, frame_count);
            }
        }
    }

    pub fn get_status(&self, out: &mut MiniaudioPlayerStatus) -> i32 {
        out.position_ms = self.position_ms.load(Ordering::Relaxed);
        out.duration_ms = self.duration_ms.load(Ordering::Relaxed);
        let st = self.state.load(Ordering::Relaxed);
        out.state = st;
        out.is_playing = (st == STATE_PLAYING) as i32;
        out.is_buffering = (st == STATE_BUFFERING) as i32;
        out.is_completed = (st == STATE_COMPLETED) as i32;
        out.volume = f32::from_bits(self.volume.load(Ordering::Relaxed));
        out.rate = f32::from_bits(self.rate.load(Ordering::Relaxed));
        out.pitch = f32::from_bits(self.pitch.load(Ordering::Relaxed));
        out.bitrate = self.bitrate.load(Ordering::Relaxed);
        out.sample_rate = self.sample_rate.load(Ordering::Relaxed);
        out.channels = self.channels.load(Ordering::Relaxed);

        out.equalizer = *self.eq_params.read().unwrap();
        out.preamp_db = f32::from_bits(self.preamp_db.load(Ordering::Relaxed));
        out.replay_gain = *self.replay_gain.read().unwrap();
        out.balance = f32::from_bits(self.balance.load(Ordering::Relaxed));
        out.mono_enabled = self.mono_enabled.load(Ordering::Relaxed) as i32;
        out.crossfeed_mode = self.crossfeed_mode.load(Ordering::Relaxed);
        out.spatializer_enabled = self.spatializer_enabled.load(Ordering::Relaxed) as i32;
        out.spatializer_width = f32::from_bits(self.spatializer_width.load(Ordering::Relaxed));
        out.reverb = *self.reverb_config.read().unwrap();
        out.limiter_enabled = self.limiter_enabled.load(Ordering::Relaxed) as i32;
        out.visualizer = self.visualizer_seqlock.read();

        out.visualizer_enabled = self.visualizer_enabled.load(Ordering::Relaxed) as i32;
        out.silence = *self.silence_config.read().unwrap();
        out.silence_saved_ms = self.silence_saved_ms.load(Ordering::Relaxed);

        let _ = self.get_current_device(&mut out.device);

        MAP_SUCCESS
    }

    pub fn destroy(&mut self) {
        let _ = self.stop();
        self.network_streamer_abort.store(true, Ordering::Release);
        self.telemetry.stop();
        if let Ok(mut cb) = self.completion_cb.write() {
            *cb = None;
        }
        self.decoder_running.store(false, Ordering::Relaxed);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        if let Some(handle) = self.decoder_thread.take() {
            let _ = handle.join();
        }

        if !self.device_ctx.is_null() {
            unsafe {
                map_device_destroy(self.device_ctx);
            }
            self.device_ctx = std::ptr::null_mut();
        }

        if !self.renderer_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.renderer_ptr));
            }
            self.renderer_ptr = std::ptr::null_mut();
        }
    }
}

impl Drop for PlayerCoordinator {
    fn drop(&mut self) {
        self.destroy();
    }
}
