//! Central thread-safe player coordinator integrating decoding, DSP, buffering, and device output.

#[cfg(not(target_arch = "wasm32"))]
use std::fs::File;
#[cfg(not(target_arch = "wasm32"))]
use std::io::{Seek, SeekFrom};
use std::io::{ErrorKind, Read};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use crate::sync::thread::{self, JoinHandle};
use std::time::Duration;

use crate::bridge::ffi::*;
#[cfg(unix)]
use crate::buffer::FdOpenOutcome;
use crate::buffer::{
    ByteTimeMap, CustomByteSourceHandle, CustomDartByteSource, DartResolveRegistry, FileByteSource,
    ProbeFetcherFn, ResolvedCoreSource, StreamBuffer, StreamSession,
};
use crate::core::renderer::{AudioRenderer, DspCommand};
use crate::decoder::{
    BoundaryInfo, BoundaryStatus, ContainerFormat, StreamClassifier, SymphoniaEngine,
};
use crate::net::ureq;
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

fn encoding_format_to_extension(encoding_format: i32) -> Option<&'static str> {
    match encoding_format {
        1 => Some("wav"),
        2 => Some("flac"),
        3 => Some("mp3"),
        4 => Some("ogg"),
        5 => Some("aac"),
        6 => Some("mp4"),
        7 => Some("aiff"),
        8 => Some("mkv"),
        9 => Some("webm"),
        10 => Some("dsf"),
        11 => Some("ape"),
        12 => Some("wv"),
        13 => Some("caf"),
        14 => Some("m3u8"),
        _ => None,
    }
}

fn extension_hint_to_encoding_format(hint: &str) -> i32 {
    match hint {
        "wav" => 1,
        "flac" => 2,
        "mp3" => 3,
        "ogg" => 4,
        "aac" => 5,
        "mp4" => 6,
        "aiff" => 7,
        "mkv" => 8,
        "webm" => 9,
        "dsf" => 10,
        "ape" => 11,
        "wv" => 12,
        "caf" => 13,
        "m3u8" => 14,
        _ => 0,
    }
}

fn extract_tail_metadata_slice(
    container: ContainerFormat,
    tail_slice: &[u8],
    tail_offset: i64,
    audio_end: i64,
) -> Option<(Vec<u8>, u64)> {
    let rel = (audio_end - tail_offset) as usize;
    if rel < tail_slice.len() {
        Some((tail_slice[rel..].to_vec(), audio_end as u64))
    } else if matches!(
        container,
        ContainerFormat::OggVorbis | ContainerFormat::OggOpus | ContainerFormat::Matroska
    ) {
        Some((tail_slice.to_vec(), tail_offset as u64))
    } else {
        None
    }
}

#[derive(Clone, Copy)]
enum VbrProbeKind {
    Ogg {
        serial: u32,
        sample_rate: u32,
        pre_skip: u64,
        find_first_audio_from: Option<u64>,
    },
    Flac {
        sample_rate: u32,
        min_bs: u16,
        max_bs: u16,
    },
    MkvCluster {
        timecode_scale_ns: u64,
    },
    WavPack {
        sample_rate: u32,
    },
}

fn spawn_vbr_probe_thread(
    session: StreamSession,
    fetcher: Arc<dyn Fn(u64, usize) -> Option<Vec<u8>> + Send + Sync>,
    abort_arc: Arc<AtomicBool>,
    session_audio_start: u64,
    session_audio_end: u64,
    dur_cap: i64,
    kind: VbrProbeKind,
) {
    let span = session_audio_end.saturating_sub(session_audio_start);
    if span <= 65_536 {
        return;
    }
    let _ = thread::Builder::new()
        .name("miniaudio-vbr-probe".to_string())
        .spawn(move || {
            let mut offsets: Vec<u64> = match kind {
                VbrProbeKind::Flac { .. } => (1..=31u64)
                    .map(|k| session_audio_start + (span * k) / 32)
                    .collect(),
                VbrProbeKind::Ogg { .. } => {
                    let mut v = vec![
                        session_audio_start + span / 40,
                        session_audio_start + (span * 2) / 40,
                    ];
                    v.extend((1..=15u64).map(|k| session_audio_start + (span * k) / 16));
                    v
                }
                VbrProbeKind::MkvCluster { .. } | VbrProbeKind::WavPack { .. } => (1..=15u64)
                    .map(|k| session_audio_start + (span * k) / 16)
                    .collect(),
            };
            offsets.sort_unstable();
            offsets.dedup();

            let slice_len_cap: usize = match kind {
                VbrProbeKind::MkvCluster { .. } => 112 * 1024,
                VbrProbeKind::WavPack { .. } => 48 * 1024,
                VbrProbeKind::Ogg { .. } => 40 * 1024,
                VbrProbeKind::Flac { .. } => 24 * 1024,
            };

            let next_task = std::sync::atomic::AtomicUsize::new(0);
            let include_first_audio_scan =
                matches!(kind, VbrProbeKind::Ogg { find_first_audio_from: Some(_), .. });
            let total_tasks = offsets.len() + usize::from(include_first_audio_scan);
            let results: Mutex<Vec<(u64, i64)>> = Mutex::new(Vec::with_capacity(64));
            let flac_pts_acc: Mutex<Vec<(u64, u64)>> = Mutex::new(Vec::with_capacity(64));

            let worker_count = total_tasks.min(6).max(1);
            std::thread::scope(|scope| {
                for _ in 0..worker_count {
                    scope.spawn(|| loop {
                        if abort_arc.load(Ordering::Acquire) {
                            return;
                        }
                        let idx = next_task.fetch_add(1, Ordering::Relaxed);
                        if idx >= total_tasks {
                            return;
                        }
                        if include_first_audio_scan && idx == 0 {
                            if let VbrProbeKind::Ogg {
                                serial,
                                sample_rate,
                                pre_skip,
                                find_first_audio_from: Some(scan_start),
                            } = kind
                            {
                                let mut cur = scan_start;
                                for _step in 0..4 {
                                    if abort_arc.load(Ordering::Acquire) || cur >= session_audio_end
                                    {
                                        break;
                                    }
                                    let len = (session_audio_end - cur).min(262_144) as usize;
                                    let Some(sl) = fetcher(cur, len) else {
                                        break;
                                    };
                                    if let Some(first_pg) = ByteTimeMap::parse_ogg_first_audio_page(
                                        &sl, cur, serial, pre_skip,
                                    ) {
                                        session.refine_byte_time_audio_start(first_pg);
                                        let extra = ByteTimeMap::extract_ogg_anchors_in_slice(
                                            &sl,
                                            cur,
                                            serial,
                                            sample_rate,
                                            pre_skip,
                                        );
                                        if !extra.is_empty() {
                                            lock_unpoisoned(&results).extend(extra);
                                        }
                                        break;
                                    }
                                    cur = cur.saturating_add(len as u64).saturating_sub(4096);
                                }
                            }
                            continue;
                        }
                        let off_idx = idx - usize::from(include_first_audio_scan);
                        let off = offsets[off_idx];
                        let max_len = (session_audio_end - off).min(slice_len_cap as u64) as usize;
                        if max_len < 32 {
                            continue;
                        }
                        let Some(slice) = fetcher(off, max_len) else {
                            continue;
                        };
                        if abort_arc.load(Ordering::Acquire) {
                            return;
                        }
                        match kind {
                            VbrProbeKind::Ogg {
                                serial,
                                sample_rate,
                                pre_skip,
                                ..
                            } => {
                                let anchors = ByteTimeMap::extract_ogg_anchors_in_slice(
                                    &slice,
                                    off,
                                    serial,
                                    sample_rate,
                                    pre_skip,
                                );
                                if !anchors.is_empty() {
                                    lock_unpoisoned(&results).extend(anchors);
                                }
                            }
                            VbrProbeKind::Flac {
                                sample_rate,
                                min_bs,
                                max_bs,
                            } => {
                                let frames = ByteTimeMap::scan_flac_frames_in_slice(
                                    &slice,
                                    off,
                                    sample_rate,
                                    min_bs,
                                    max_bs,
                                    dur_cap,
                                );
                                if let Some(&(f_off, f_smp, f_ms)) = frames.first() {
                                    lock_unpoisoned(&results).push((f_off, f_ms));
                                    lock_unpoisoned(&flac_pts_acc).push((f_off, f_smp));
                                }
                            }
                            VbrProbeKind::MkvCluster { timecode_scale_ns } => {
                                if let Some(pt) = ByteTimeMap::extract_mkv_cluster_anchor_in_slice(
                                    &slice,
                                    off,
                                    timecode_scale_ns,
                                    dur_cap,
                                ) {
                                    lock_unpoisoned(&results).push(pt);
                                }
                            }
                            VbrProbeKind::WavPack { sample_rate } => {
                                if let Some(pt) = ByteTimeMap::extract_wavpack_anchor_in_slice(
                                    &slice,
                                    off,
                                    sample_rate,
                                    dur_cap,
                                ) {
                                    lock_unpoisoned(&results).push(pt);
                                }
                            }
                        }
                    });
                }
            });

            if abort_arc.load(Ordering::Acquire) {
                return;
            }
            let f_pts = std::mem::take(&mut *lock_unpoisoned(&flac_pts_acc));
            if !f_pts.is_empty() {
                session.record_flac_seek_points(&f_pts);
            }
            let mut raw_pts = std::mem::take(&mut *lock_unpoisoned(&results));
            if !raw_pts.is_empty() {
                raw_pts.sort_by_key(|&(b, _)| b);
                let mut monotonic = Vec::with_capacity(raw_pts.len());
                for pt in raw_pts {
                    if !monotonic
                        .last()
                        .is_some_and(|&(pb, pt_ms)| pt.0 <= pb || pt.1 < pt_ms)
                    {
                        monotonic.push(pt);
                    }
                }
                if !monotonic.is_empty() {
                    session.merge_byte_time_anchors(monotonic);
                }
            }
        });
}

/// Probes trailing metadata tags starting with the final 64 KB and expanding up to 4 MB when
/// trailing APEv2 / Lyrics3 / ID3v2 footer tags exceed 64 KB (e.g. embedded cover art).
fn resolve_tail_metadata_with_fetcher<F>(
    container: ContainerFormat,
    total_size: i64,
    audio_start: i64,
    mut fetch_range: F,
) -> (Option<(Vec<u8>, u64)>, Option<i64>)
where
    F: FnMut(i64, i64) -> Option<Vec<u8>>,
{
    const MAX_TAIL_META_SCAN: i64 = 4 * 1024 * 1024;
    let floor = audio_start.max(0);
    let probe_len = 65536i64.min(total_size - floor);
    if probe_len <= 0 {
        return (None, None);
    }

    let mut tail_offset = total_size - probe_len;
    let Some(mut buf) = fetch_range(tail_offset, total_size - 1) else {
        return (None, None);
    };
    if buf.is_empty() {
        return (None, None);
    }

    let mut last_status = BoundaryStatus::Unsupported;
    let mut audio_end = total_size;
    for _ in 0..4 {
        let (st, end_or_needed) = StreamClassifier::detect_tail_boundary(
            container,
            &buf,
            tail_offset,
            total_size,
            audio_start,
        );
        last_status = st;
        if st == BoundaryStatus::NeedMore
            && end_or_needed >= floor
            && end_or_needed < tail_offset
            && (total_size - end_or_needed) <= MAX_TAIL_META_SCAN
        {
            if let Some(prefix) = fetch_range(end_or_needed, tail_offset - 1) {
                if prefix.len() as i64 == tail_offset - end_or_needed {
                    let mut combined = prefix;
                    combined.extend_from_slice(&buf);
                    buf = combined;
                    tail_offset = end_or_needed;
                    continue;
                }
            }
        }
        audio_end = end_or_needed;
        break;
    }

    if last_status == BoundaryStatus::Found
        && audio_end > 0
        && audio_end <= total_size
        && audio_end >= tail_offset
    {
        let extracted = extract_tail_metadata_slice(container, &buf, tail_offset, audio_end);
        return (extracted, Some(audio_end));
    }
    (None, None)
}

fn infer_network_encoding_format(url: &str, content_type: Option<&str>) -> i32 {
    if let Some(hint) = StreamClassifier::extract_extension_hint(url) {
        let code = extension_hint_to_encoding_format(hint);
        if code != 0 {
            return code;
        }
    }
    let lower_ct = content_type.unwrap_or("").to_lowercase();

    if lower_ct.contains("audio/wav") || lower_ct.contains("audio/x-wav") {
        1
    } else if lower_ct.contains("audio/flac") {
        2
    } else if lower_ct.contains("audio/mpeg") || lower_ct.contains("audio/mp3") {
        3
    } else if lower_ct.contains("audio/ogg") || lower_ct.contains("audio/opus") {
        4
    } else if lower_ct.contains("audio/aac") {
        5
    } else if lower_ct.contains("audio/mp4") {
        6
    } else if lower_ct.contains("audio/aiff")
        || lower_ct.contains("audio/x-aiff")
        || lower_ct.contains("sound/aiff")
    {
        7
    } else if lower_ct.contains("matroska") {
        8
    } else if lower_ct.contains("webm") {
        9
    } else {
        0
    }
}

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

fn response_header_str<'a>(
    res: &'a ureq::http::Response<ureq::Body>,
    name: &str,
) -> Option<&'a str> {
    res.headers().get(name).and_then(|v| v.to_str().ok())
}

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

struct IcyDemuxReader {
    inner: Box<dyn Read + Send>,
    metaint: usize,
    bytes_until_meta: usize,
    session_slot: Arc<Mutex<Option<StreamSession>>>,
    latest_icy: Arc<Mutex<Option<Vec<u8>>>>,
    icy_metadata: Arc<RwLock<Option<crate::api::types::RustIcyMetadata>>>,
}

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
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(true)
    }
}

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

fn demux_or_wrap_hls_segment(
    seg_url: &str,
    content_type: Option<&str>,
    raw_bytes: Vec<u8>,
) -> Option<(Vec<u8>, i32)> {
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
    let fmt = infer_network_encoding_format(seg_url, content_type);
    Some((raw_bytes, fmt))
}

#[cfg(not(target_arch = "wasm32"))]
fn read_local_segment_bytes(path: &str, byte_range: Option<(u64, u64)>) -> Option<Vec<u8>> {
    if let Some((length, offset)) = byte_range {
        if length == 0 {
            return None;
        }
        let mut file = File::open(path).ok()?;
        file.seek(SeekFrom::Start(offset)).ok()?;
        let cap = usize::try_from(length)
            .unwrap_or(1024 * 1024)
            .min(16 * 1024 * 1024);
        let mut buf = Vec::with_capacity(cap);
        file.take(length).read_to_end(&mut buf).ok()?;
        if buf.is_empty() {
            None
        } else {
            Some(buf)
        }
    } else {
        std::fs::read(path).ok().filter(|b| !b.is_empty())
    }
}

fn fetch_hls_segment_audio(
    agent: &ureq::Agent,
    seg_url: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
    byte_range: Option<(u64, u64)>,
) -> Option<(Vec<u8>, i32)> {
    let mut req = apply_http_headers(agent.get(seg_url), headers);
    if let Some((length, offset)) = byte_range {
        if length == 0 {
            return None;
        }
        let end_inclusive = offset.saturating_add(length - 1);
        let range_hdr = format!("bytes={}-{}", offset, end_inclusive);
        req = req.header("Range", &range_hdr);
    }
    let res = req.call().ok()?;
    let status = res.status().as_u16();
    let content_type = response_header_str(&res, "content-type").map(|s| s.to_string());
    let raw_bytes = if let Some((length, offset)) = byte_range {
        let mut buf = Vec::new();
        if status == 206 {
            res.into_body()
                .into_reader()
                .take(length)
                .read_to_end(&mut buf)
                .ok()?;
            buf
        } else {
            let max_read = offset.saturating_add(length);
            res.into_body()
                .into_reader()
                .take(max_read)
                .read_to_end(&mut buf)
                .ok()?;
            crate::hls::slice_byte_range(&buf, length, offset)?
        }
    } else {
        let mut buf = Vec::new();
        res.into_body().into_reader().read_to_end(&mut buf).ok()?;
        buf
    };
    demux_or_wrap_hls_segment(seg_url, content_type.as_deref(), raw_bytes)
}

#[derive(Clone)]
enum HlsFetchBackend {
    Network {
        agent: Arc<ureq::Agent>,
        headers: Option<Vec<crate::api::types::RustHttpHeader>>,
    },
    #[cfg(not(target_arch = "wasm32"))]
    LocalFile,
    DartResolved {
        resolver: Arc<DartResolveRegistry>,
        headers: Option<Vec<crate::api::types::RustHttpHeader>>,
    },
}

impl HlsFetchBackend {
    fn to_streaming_backend(&self) -> Self {
        match self {
            Self::Network { headers, .. } => Self::Network {
                agent: Arc::new(build_network_agent()),
                headers: headers.clone(),
            },
            #[cfg(not(target_arch = "wasm32"))]
            Self::LocalFile => Self::LocalFile,
            Self::DartResolved { resolver, headers } => Self::DartResolved {
                resolver: resolver.clone(),
                headers: headers.clone(),
            },
        }
    }

    fn is_remote_http(&self) -> bool {
        match self {
            Self::Network { .. } => true,
            #[cfg(not(target_arch = "wasm32"))]
            Self::LocalFile => false,
            Self::DartResolved { .. } => false,
        }
    }

    fn fetch_playlist(&self, url: &str) -> Result<Vec<u8>, i32> {
        match self {
            Self::Network { agent, headers } => {
                let req = apply_http_headers(agent.get(url), headers.as_deref());
                match req.call() {
                    Ok(res) => {
                        let mut bytes = Vec::new();
                        res.into_body()
                            .into_reader()
                            .read_to_end(&mut bytes)
                            .map_err(|_| MAP_ERROR_DECODE_FAILED)?;
                        if bytes.is_empty() {
                            Err(MAP_ERROR_DECODE_FAILED)
                        } else {
                            Ok(bytes)
                        }
                    }
                    Err(ureq::Error::StatusCode(code)) => Err(if code == 404 {
                        MAP_ERROR_FILE_NOT_FOUND
                    } else if code == 401 || code == 403 {
                        MAP_ERROR_ACCESS_DENIED
                    } else {
                        MAP_ERROR_DECODE_FAILED
                    }),
                    Err(_) => Err(MAP_ERROR_FILE_NOT_FOUND),
                }
            }
            #[cfg(not(target_arch = "wasm32"))]
            Self::LocalFile => std::fs::read(url).map_err(|_| MAP_ERROR_FILE_NOT_FOUND),
            Self::DartResolved { resolver, headers } => {
                let resolved = resolver
                    .resolve(url, headers.as_deref(), None)
                    .map_err(|f| f.code)?;
                Self::read_resolved_bytes(resolved)
            }
        }
    }

    fn read_resolved_bytes(resolved: ResolvedCoreSource) -> Result<Vec<u8>, i32> {
        match resolved {
            ResolvedCoreSource::Bytes { data, .. } => Ok(data),
            #[cfg(not(target_arch = "wasm32"))]
            ResolvedCoreSource::Path(path) => {
                std::fs::read(&path).map_err(|_| MAP_ERROR_FILE_NOT_FOUND)
            }
            #[cfg(target_arch = "wasm32")]
            ResolvedCoreSource::Path(_path) => Err(MAP_ERROR_UNSUPPORTED),
            ResolvedCoreSource::Url(url) => {
                let agent = build_network_agent();
                let res = agent.get(&url).call().map_err(|_| MAP_ERROR_FILE_NOT_FOUND)?;
                let mut bytes = Vec::new();
                res.into_body()
                    .into_reader()
                    .read_to_end(&mut bytes)
                    .map_err(|_| MAP_ERROR_DECODE_FAILED)?;
                Ok(bytes)
            }
            #[cfg(unix)]
            ResolvedCoreSource::Fd { file, offset, length, .. } => {
                match ResolvedCoreSource::open_fd_slice(file, offset, length) {
                    Ok(FdOpenOutcome::MemoryBytes(b)) => Ok(b),
                    Ok(FdOpenOutcome::Seekable(mut src)) => {
                        let mut b = Vec::new();
                        src.read_to_end(&mut b).map_err(|_| MAP_ERROR_FILE_NOT_FOUND)?;
                        Ok(b)
                    }
                    Err(_) => Err(MAP_ERROR_FILE_NOT_FOUND),
                }
            }
            #[cfg(not(unix))]
            ResolvedCoreSource::Fd { .. } => Err(MAP_ERROR_UNSUPPORTED),
            ResolvedCoreSource::CustomStream { .. } => Err(MAP_ERROR_UNSUPPORTED),
            ResolvedCoreSource::Error { code, .. } => Err(code),
        }
    }

    fn fetch_segment_audio(
        &self,
        seg_url: &str,
        byte_range: Option<(u64, u64)>,
    ) -> Option<(Vec<u8>, i32)> {
        match self {
            Self::Network { agent, headers } => {
                fetch_hls_segment_audio(agent, seg_url, headers.as_deref(), byte_range)
            }
            #[cfg(not(target_arch = "wasm32"))]
            Self::LocalFile => {
                let raw_bytes = read_local_segment_bytes(seg_url, byte_range)?;
                demux_or_wrap_hls_segment(seg_url, None, raw_bytes)
            }
            Self::DartResolved { resolver, headers } => {
                let resolved = resolver.resolve(seg_url, headers.as_deref(), None).ok()?;
                let all_bytes = Self::read_resolved_bytes(resolved).ok()?;
                let sliced = if let Some((offset, len)) = byte_range {
                    let start = (offset as usize).min(all_bytes.len());
                    let end = start.saturating_add(len as usize).min(all_bytes.len());
                    all_bytes[start..end].to_vec()
                } else {
                    all_bytes
                };
                demux_or_wrap_hls_segment(seg_url, None, sliced)
            }
        }
    }
}

fn feed_hls_audio_chunked(
    session: &StreamSession,
    audio_bytes: &[u8],
    abort: &AtomicBool,
    dec_running: &AtomicBool,
    vod_epoch: Option<(&crate::buffer::HlsVodState, u64)>,
) -> bool {
    const FEED_CHUNK_BYTES: usize = 32768;
    let is_cancelled = || {
        abort.load(Ordering::Acquire)
            || !dec_running.load(Ordering::Acquire)
            || vod_epoch.is_some_and(|(v, ep)| v.is_epoch_stale(ep))
    };
    let mut offset = 0;
    while offset < audio_bytes.len() && !is_cancelled() {
        let step_end = (offset + FEED_CHUNK_BYTES).min(audio_bytes.len());
        match session.feed_chunk(&audio_bytes[offset..step_end]) {
            Ok(0) => {
                session.wait_for_free_space(step_end - offset, Duration::from_millis(250));
            }
            Ok(written) => offset += written,
            Err(crate::buffer::BufferError::Busy) => {
                session.wait_for_free_space(step_end - offset, Duration::from_millis(250));
            }
            Err(_) => return false,
        }
    }
    !abort.load(Ordering::Acquire) && dec_running.load(Ordering::Acquire)
}

fn sleep_interruptible(duration: Duration, abort: &AtomicBool, dec_running: &AtomicBool) -> bool {
    let deadline = MonotonicInstant::now() + duration;
    loop {
        if abort.load(Ordering::Acquire) || !dec_running.load(Ordering::Acquire) {
            return false;
        }
        let now = MonotonicInstant::now();
        if now >= deadline {
            return true;
        }
        thread::sleep((deadline - now).min(Duration::from_millis(50)));
    }
}

fn run_hls_vod_streamer(
    session: StreamSession,
    abort_stream: Arc<AtomicBool>,
    decoder_running: Arc<AtomicBool>,
    backend: HlsFetchBackend,
    vod: Arc<crate::buffer::HlsVodState>,
) {
    use crate::buffer::VodAction;
    let a_start = vod.audio_start_offset();
    let total_dur = vod.total_duration_ms();

    while !abort_stream.load(Ordering::Acquire) && decoder_running.load(Ordering::Acquire) {
        if let Some((seg_idx, epoch, seg_start_ms)) = vod.take_pending_jump() {
            session.flush(a_start);
            session.reset_hls_vod_window(a_start, seg_start_ms, total_dur);
            vod.mark_jump_accepted(epoch);
            let _ = seg_idx;
            continue;
        }

        match vod.next_action() {
            VodAction::JumpPending => continue,
            VodAction::FetchSegment(seg_idx, epoch) => {
                let Some(seg) = vod.segment(seg_idx).cloned() else {
                    vod.mark_eof_sent(epoch);
                    session.mark_eof();
                    continue;
                };
                let bytes_opt = vod.get_cached_segment(seg_idx).or_else(|| {
                    let (fetched, _) = backend.fetch_segment_audio(&seg.url, seg.byte_range)?;
                    vod.put_cached_segment(seg_idx, fetched.clone());
                    Some(fetched)
                });
                let Some(audio_bytes) = bytes_opt else {
                    thread::sleep(Duration::from_millis(40));
                    continue;
                };
                if vod.is_epoch_stale(epoch) {
                    continue;
                }
                let payload = if a_start > 0 && seg_idx == 0 && audio_bytes.len() > a_start as usize
                {
                    &audio_bytes[a_start as usize..]
                } else {
                    &audio_bytes[..]
                };
                if let Some((end_byte, end_ms)) =
                    vod.commit_segment_span(epoch, seg_idx, payload.len(), seg.duration_ms)
                {
                    session.push_segment_anchor(end_byte, end_ms);
                    if !feed_hls_audio_chunked(
                        &session,
                        payload,
                        &abort_stream,
                        &decoder_running,
                        Some((&vod, epoch)),
                    ) {
                        return;
                    }
                }
            }
            VodAction::Eof {
                already_marked,
                current_epoch,
            } => {
                if !already_marked {
                    session.mark_eof();
                    vod.mark_eof_sent(current_epoch);
                }
                vod.wait_for_demand(Duration::from_millis(35));
            }
            VodAction::Sleep => {
                vod.wait_for_demand(Duration::from_millis(35));
            }
        }
    }
}

fn spawn_hls_streamer_thread(
    session: StreamSession,
    abort_stream: Arc<AtomicBool>,
    decoder_running: Arc<AtomicBool>,
    backend: HlsFetchBackend,
    mut tracker: crate::hls::HlsPlaylistTracker,
    mut pending_targets: Vec<crate::hls::HlsSegmentTarget>,
    initial_cum_bytes: u64,
    initial_cum_ms: i64,
    vod_state: Option<Arc<crate::buffer::HlsVodState>>,
) {
    let max_unchanged: u32 = if backend.is_remote_http() { 12 } else { 3 };
    const MAX_RELOAD_ERRORS: u32 = 5;

    let _ = thread::Builder::new()
        .name("miniaudio-hls-streamer".to_string())
        .spawn(move || {
            if let Some(vod) = vod_state {
                run_hls_vod_streamer(session, abort_stream, decoder_running, backend, vod);
                return;
            }
            let mut consecutive_unchanged = 0u32;
            let mut consecutive_errors = 0u32;
            let mut last_reload_had_new = true;
            let mut cum_bytes = initial_cum_bytes;
            let mut cum_ms = initial_cum_ms;

            loop {
                for target in pending_targets.drain(..) {
                    if abort_stream.load(Ordering::Acquire)
                        || !decoder_running.load(Ordering::Acquire)
                    {
                        return;
                    }
                    if let Some((audio_bytes, _)) =
                        backend.fetch_segment_audio(&target.url, target.byte_range)
                    {
                        cum_bytes = cum_bytes.saturating_add(audio_bytes.len() as u64);
                        cum_ms = cum_ms.saturating_add(target.duration_ms as i64);
                        session.push_segment_anchor(cum_bytes, cum_ms);
                        if !feed_hls_audio_chunked(
                            &session,
                            &audio_bytes,
                            &abort_stream,
                            &decoder_running,
                            None,
                        ) {
                            return;
                        }
                    }
                }

                if !tracker.is_live() {
                    session.mark_eof();
                    return;
                }

                let wait_dur = tracker.poll_interval(last_reload_had_new);
                if !sleep_interruptible(wait_dur, &abort_stream, &decoder_running) {
                    return;
                }

                match backend.fetch_playlist(tracker.base_media_url()) {
                    Ok(playlist_bytes) => {
                        match crate::hls::M3u8Parser::parse(&playlist_bytes) {
                            Ok(crate::hls::ParsedHlsPlaylist::Media {
                                is_live,
                                target_duration,
                                media_sequence,
                                segments,
                                ..
                            }) => {
                                consecutive_errors = 0;
                                let new_targets = tracker.ingest_media_playlist(
                                    media_sequence,
                                    is_live,
                                    target_duration,
                                    &segments,
                                );
                                if new_targets.is_empty() {
                                    last_reload_had_new = false;
                                    consecutive_unchanged += 1;
                                    if !tracker.is_live() {
                                        session.mark_eof();
                                        return;
                                    }
                                    if consecutive_unchanged >= max_unchanged {
                                        crate::map_log!(
                                            2,
                                            "HLS live playlist unchanged for {} polls; marking EOF",
                                            consecutive_unchanged
                                        );
                                        session.mark_eof();
                                        return;
                                    }
                                } else {
                                    last_reload_had_new = true;
                                    consecutive_unchanged = 0;
                                    pending_targets = new_targets;
                                }
                            }
                            Ok(crate::hls::ParsedHlsPlaylist::Master { .. }) | Err(_) => {
                                last_reload_had_new = false;
                                consecutive_errors += 1;
                            }
                        }
                    }
                    Err(_) => {
                        last_reload_had_new = false;
                        consecutive_errors += 1;
                    }
                }

                if consecutive_errors >= MAX_RELOAD_ERRORS {
                    crate::map_log!(
                        1,
                        "HLS live manifest reload failed {} times; marking EOF",
                        consecutive_errors
                    );
                    session.mark_eof();
                    return;
                }
            }
        });
}

fn fetch_range_bytes_status(
    agent: &ureq::Agent,
    url: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
    start: i64,
    end_inclusive: i64,
) -> Result<Vec<u8>, Option<u16>> {
    if start < 0 || end_inclusive < start {
        return Err(None);
    }
    let range_hdr = format!("bytes={}-{}", start, end_inclusive);
    let req = apply_http_headers(agent.get(url), headers).header("Range", &range_hdr);
    let res = req.call().map_err(|_| None)?;
    let status = res.status().as_u16();
    if status != 206 {
        return Err(Some(status));
    }
    let expected = (end_inclusive - start + 1) as usize;
    let mut buf = Vec::with_capacity(expected.min(4 * 1024 * 1024));
    res.into_body()
        .into_reader()
        .take(expected as u64)
        .read_to_end(&mut buf)
        .map_err(|_| None)?;
    if buf.is_empty() && expected > 0 {
        return Err(None);
    }
    Ok(buf)
}

fn fetch_range_bytes(
    agent: &ureq::Agent,
    url: &str,
    headers: Option<&[crate::api::types::RustHttpHeader]>,
    start: i64,
    end_inclusive: i64,
) -> Option<Vec<u8>> {
    let expected = (end_inclusive - start + 1).max(0) as usize;
    fetch_range_bytes_status(agent, url, headers, start, end_inclusive)
        .ok()
        .filter(|buf| buf.len() == expected)
}

fn prefetch_initial_stream_bytes_cancellable(
    reader: &mut impl Read,
    content_length: i64,
    cancel: Option<&CancelToken>,
) -> (Vec<u8>, bool, bool) {
    let mut initial_data = Vec::with_capacity(131072);
    let mut read_buf = [0u8; 32768];
    let mut reached_eof = false;

    loop {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return (Vec::new(), true, false);
        }
        match reader.read(&mut read_buf) {
            Ok(0) => {
                reached_eof = true;
                break;
            }
            Ok(n) => {
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return (Vec::new(), true, false);
                }
                initial_data.extend_from_slice(&read_buf[..n]);
                if crate::hls::M3u8Parser::is_m3u8(&initial_data) {
                    break;
                }
                if initial_data.len() >= 65536 {
                    let (status, boundary) =
                        StreamClassifier::detect_head_boundary(&initial_data, content_length);
                    if status != BoundaryStatus::NeedMore {
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
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }

    if !crate::hls::M3u8Parser::is_m3u8(&initial_data)
        && content_length > 0
        && initial_data.len() < (content_length as usize).min(65536)
    {
        return (Vec::new(), cancel.is_some_and(|c| c.is_cancelled()), false);
    }

    (initial_data, false, reached_eof)
}

#[allow(clippy::too_many_arguments)]
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
    let _ = thread::Builder::new()
        .name("miniaudio-net-streamer".to_string())
        .spawn(move || {
            session.body.set_push_streaming(true);
            let mut chunk = vec![0u8; 32768];
            let mut range_retries = 0u32;
            let mut range_seek_failures = 0u32;
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
                                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
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
                                range_seek_failures = 0;
                            }
                            _ => {
                                range_seek_failures += 1;
                                if range_seek_failures >= 5 {
                                    session.mark_eof();
                                    session.body.set_push_streaming(false);
                                    break;
                                }
                                thread::sleep(Duration::from_millis(50));
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
                        Err(e) if e.kind() == ErrorKind::Interrupted => continue,
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

type ReopenSourceFn =
    Arc<dyn Fn() -> Option<Box<dyn symphonia::core::io::MediaSource>> + Send + Sync>;

struct SharedMemSource {
    data: Arc<Vec<u8>>,
    pos: usize,
}

impl SharedMemSource {
    fn new(data: Arc<Vec<u8>>) -> Self {
        Self { data, pos: 0 }
    }
}

impl std::io::Read for SharedMemSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.data.len() {
            return Ok(0);
        }
        let n = buf.len().min(self.data.len() - self.pos);
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

impl std::io::Seek for SharedMemSource {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        let len = self.data.len() as i64;
        let next = match pos {
            std::io::SeekFrom::Start(p) => p as i64,
            std::io::SeekFrom::Current(d) => (self.pos as i64).saturating_add(d),
            std::io::SeekFrom::End(d) => len.saturating_add(d),
        };
        if next < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "negative seek position",
            ));
        }
        self.pos = next as usize;
        Ok(self.pos as u64)
    }
}

impl symphonia::core::io::MediaSource for SharedMemSource {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        Some(self.data.len() as u64)
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
    in_rtrb_push: Arc<AtomicBool>,
    stream_reinit_needed: Arc<AtomicBool>,
    reopen_local_fn: Arc<Mutex<Option<ReopenSourceFn>>>,

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

    fn try_reopen_fresh_engine(&self, recover_hint: Option<&'static str>) -> Option<SymphoniaEngine> {
        if self.is_stream_arc.load(Ordering::Relaxed) {
            let guard = self.session_arc.read().ok()?;
            let session = guard.as_ref()?;
            if !(session.supports_range() || session.is_fully_buffered()) {
                return None;
            }
            session.set_decoding_audio(false);
            let allow_scan = session.is_fully_buffered();
            let reader = session.create_reader();
            let res = SymphoniaEngine::new_with_options(reader, recover_hint, allow_scan).ok();
            session.set_decoding_audio(true);
            return res;
        }

        let reopen = self
            .reopen_local_fn
            .lock()
            .ok()
            .and_then(|g| g.as_ref().cloned())?;
        let reader = reopen()?;
        SymphoniaEngine::from_boxed_with_options(reader, recover_hint, true).ok()
    }

    fn try_reopen_for_seek_recovery(
        &self,
        recover_hint: Option<&'static str>,
        restore_ms: u64,
    ) -> Option<SymphoniaEngine> {
        if self.is_stream_arc.load(Ordering::Relaxed) {
            let guard = self.session_arc.read().ok()?;
            let session = guard.as_ref()?;
            if !(session.supports_range() || session.is_fully_buffered() || restore_ms == 0) {
                return None;
            }
            session.set_decoding_audio(false);
            let allow_scan = session.is_fully_buffered();
            let reader = session.create_reader();
            let mut out = None;
            if let Ok(mut new_eng) =
                SymphoniaEngine::new_with_options(reader, recover_hint, allow_scan)
            {
                session.set_decoding_audio(true);
                if new_eng.seek_ms(restore_ms).is_ok() {
                    out = Some(new_eng);
                }
            } else {
                session.set_decoding_audio(true);
            }
            return out;
        }

        let mut new_eng = self.try_reopen_fresh_engine(recover_hint)?;
        new_eng.seek_ms(restore_ms).ok()?;
        Some(new_eng)
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

    fn try_hls_vod_seek<F: Fn() -> bool>(
        &self,
        session: &StreamSession,
        vod: &crate::buffer::HlsVodState,
        eng_lock: &mut Option<SymphoniaEngine>,
        target_seek: i64,
        is_superseded: &F,
    ) -> Result<u64, ()> {
        let target_seg = vod.segment_for_ms(target_seek);
        let seg_info = vod.segment(target_seg).ok_or(())?;
        let recover_hint = eng_lock.as_ref().and_then(|e| e.container_hint_ext());
        let (r_start, r_end, _) = session.body_metrics();

        // Fast-path: segment already resident cleanly inside circular cache with raw headerless framing.
        if session.head_len() == 0 {
            if let Some((byte_start, seg_start_ms)) = vod.find_in_ring_span(target_seg, r_start, r_end) {
                let _ = session.seek(byte_start);
                session.set_decoding_audio(false);
                let reader = session.create_reader_at(byte_start);
                let opened = SymphoniaEngine::new_with_options(reader, recover_hint, false);
                session.set_decoding_audio(true);
                if is_superseded() {
                    return Err(());
                }
                if let Ok(mut new_eng) = opened {
                    let rel_ms = (target_seek - seg_start_ms).max(0) as u64;
                    let walked_rel = if rel_ms >= 25 {
                        new_eng.advance_to_ms(rel_ms.saturating_sub(25)).unwrap_or(0)
                    } else {
                        0
                    };
                    let actual = (seg_start_ms.max(0) as u64).saturating_add(walked_rel);
                    new_eng.set_anchor_ms(actual);
                    *eng_lock = Some(new_eng);
                    vod.update_cursor_ms(actual as i64);
                    return Ok(actual);
                }
            }
        }

        // Segment jump: redirect VOD streamer directly to `target_seg` and reopen clean decoder.
        let epoch = vod.request_jump(target_seg);
        session.notify_data_signal();
        if !vod.wait_jump_accepted(epoch, || {
            is_superseded() || !self.running.load(Ordering::Acquire)
        }) {
            return Err(());
        }

        session.set_decoding_audio(false);
        let reader = session.create_reader();
        let opened = SymphoniaEngine::new_with_options(reader, recover_hint, false);
        session.set_decoding_audio(true);
        if is_superseded() {
            return Err(());
        }
        let mut new_eng = opened.map_err(|_| ())?;
        let seg_start_ms = seg_info.start_ms.max(0) as u64;
        let rel_ms = (target_seek - seg_info.start_ms).max(0) as u64;
        let walked_rel = if rel_ms >= 25 {
            new_eng.advance_to_ms(rel_ms.saturating_sub(25)).unwrap_or(0)
        } else {
            0
        };
        let actual = seg_start_ms.saturating_add(walked_rel);
        new_eng.set_anchor_ms(actual);
        *eng_lock = Some(new_eng);
        vod.update_cursor_ms(actual as i64);
        Ok(actual)
    }

    /// Processes a pending seek request if one exists.
    /// Returns `true` if the main worker loop should `continue` immediately.
    fn handle_pending_seek(&mut self) -> bool {
        let packed = self.seek_packed.swap(0, Ordering::AcqRel);
        if packed == 0 {
            return false;
        }
        let gen = (packed >> 40) as i64;
        if let Ok(sess_guard) = self.session_arc.read() {
            if let Some(ref session) = *sess_guard {
                session.acknowledge_seek_gen(gen as u64);
            }
        }
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

        let was_eof = self.decoder_eof_arc.swap(false, Ordering::Relaxed);
        let session_opt = self
            .session_arc
            .read()
            .ok()
            .and_then(|g| g.as_ref().cloned());
        if let Some(ref session) = session_opt {
            session.reset_probe_seek_tracking();
        }
        let probe_guard = session_opt.as_ref().map(|s| s.enter_probe());
        let flush_seq_before = session_opt.as_ref().map(|s| s.flush_seq()).unwrap_or(0);
        let mut seek_ok = true;
        let mut committed_seek_ms = target_seek;
        let mut actual_seek_ms_opt: Option<u64> = None;
        let mut fallback_pos_ms: Option<i64> = None;

        if let Ok(mut eng_lock) = self.engine_arc.lock() {
            if is_superseded() {
                drop(probe_guard);
                return true;
            }
            let mut reinit = false;
            if self.is_stream_arc.load(Ordering::Relaxed) {
                if let Some(vod) = session_opt.as_ref().and_then(|s| s.hls_vod()) {
                    if let Some(ref session) = session_opt {
                        match self.try_hls_vod_seek(
                            session,
                            &vod,
                            &mut eng_lock,
                            target_seek,
                            &is_superseded,
                        ) {
                            Ok(actual) => {
                                actual_seek_ms_opt = Some(actual);
                                reinit = true;
                            }
                            Err(()) => {
                                seek_ok = false;
                                fallback_pos_ms =
                                    eng_lock.as_ref().map(|eng| eng.position_ms() as i64);
                                reinit = true;
                            }
                        }
                    }
                }
            }
            if !reinit && target_seek == 0 && self.is_stream_arc.load(Ordering::Relaxed) {
                if let Some(ref session) = session_opt {
                    let target_off = session.audio_start_offset();
                    let (hit, contig) = session.try_seek_cached(target_off);
                    if !hit || !contig {
                        session.flush(target_off);
                    }
                    session.set_decoding_audio(false);
                    let allow_scan = session.is_fully_buffered();
                    let head_bytes = session.head_bytes_copy();
                    let flac_pts = session.flac_seek_points();
                    if let (false, Some(first_frame), false) = (
                        session.has_native_flac_seektable(),
                        ByteTimeMap::parse_flac_first_frame_offset(&head_bytes),
                        flac_pts.is_empty(),
                    ) {
                        if let Some((vhead, vdelta)) =
                            ByteTimeMap::build_synthetic_flac_head(&head_bytes, first_frame, &flac_pts)
                        {
                            if let Ok(new_eng) = SymphoniaEngine::new_patched_flac(
                                vhead,
                                vdelta,
                                session.create_reader(),
                            ) {
                                *eng_lock = Some(new_eng);
                                actual_seek_ms_opt = Some(0);
                                reinit = true;
                            }
                        }
                    }
                    if !reinit {
                        let reader = session.create_reader();
                        if let Ok(new_eng) = SymphoniaEngine::new_with_options(reader, None, allow_scan) {
                            *eng_lock = Some(new_eng);
                            actual_seek_ms_opt = Some(0);
                            reinit = true;
                        }
                    }
                    session.set_decoding_audio(true);
                }
            }
            if !reinit {
                if self.is_stream_arc.load(Ordering::Relaxed) {
                    if let (Some(ref session), Some(ref eng)) = (&session_opt, &*eng_lock) {
                        if eng.is_flac_stream() && !session.has_native_flac_seektable() {
                            Self::prepare_patched_flac_seek(
                                &mut eng_lock,
                                session,
                                target_seek,
                                &is_superseded,
                            );
                        }
                    }
                }
                let recover_hint = eng_lock.as_ref().and_then(|e| e.container_hint_ext());
                let pre_seek_ms = eng_lock.as_ref().map(|eng| eng.position_ms()).unwrap_or(0);
                let seek_res = eng_lock
                    .as_mut()
                    .map(|eng| eng.seek_ms_with_actual(target_seek as u64));
                match seek_res {
                    Some(Ok(actual_ms)) => {
                        let mut resolved_actual = actual_ms;
                        // Symphonia 0.6 MkvReader parses CueTime as nanoseconds and does not clear
                        // internal queued frames across seeks. If Cue seek overran into Cluster[k+1],
                        // re-open a clean MkvReader and land in Cluster[k] before `target_seek`.
                        if eng_lock.as_ref().is_some_and(|e| e.is_mkv_or_webm())
                            && actual_ms > (target_seek.max(0) as u64).saturating_add(400)
                            && target_seek > 0
                        {
                            for backoff in [5_200u64, 10_500, 16_000] {
                                if is_superseded() {
                                    break;
                                }
                                let probe_ms = (target_seek as u64).saturating_sub(backoff);
                                if let Some(ref session) = session_opt {
                                    session.reset_probe_seek_tracking();
                                }
                                if let Some(mut fresh) = self.try_reopen_fresh_engine(recover_hint) {
                                    if let Ok(r_ms) = fresh.seek_ms_with_actual(probe_ms) {
                                        if r_ms <= target_seek as u64 {
                                            let stop_ms = (target_seek as u64).saturating_sub(150);
                                            let walked = if r_ms < stop_ms {
                                                fresh.advance_to_ms(stop_ms).unwrap_or(r_ms)
                                            } else {
                                                r_ms
                                            };
                                            fresh.set_anchor_ms(target_seek as u64);
                                            resolved_actual = walked;
                                            *eng_lock = Some(fresh);
                                            break;
                                        }
                                    }
                                }
                                if probe_ms == 0 {
                                    break;
                                }
                            }
                        }
                        actual_seek_ms_opt = Some(resolved_actual);
                        crate::map_log!(
                            3,
                            "DecoderWorker seek_ms({}) succeeded (actual={}ms)",
                            target_seek,
                            resolved_actual
                        );
                    }
                    Some(Err(e)) => {
                        let is_ebml_ancestor = e.to_string().contains("not an ancestor");
                        let is_adts_overshoot = recover_hint == Some("aac")
                            && matches!(
                                e,
                                symphonia::core::errors::Error::SeekError(
                                    symphonia::core::errors::SeekErrorKind::OutOfRange
                                )
                            );
                        let mut recovered = false;
                        if was_eof || is_ebml_ancestor || is_adts_overshoot {
                            let restore_ms = if is_adts_overshoot {
                                pre_seek_ms.min(target_seek.max(0) as u64)
                            } else {
                                target_seek as u64
                            };
                            if let Some(new_eng) =
                                self.try_reopen_for_seek_recovery(recover_hint, restore_ms)
                            {
                                *eng_lock = Some(new_eng);
                                recovered = true;
                                if is_adts_overshoot {
                                    // ADTS seek overshot true end: restore clean pre-seek cursor so next decode continues instead of EOF skip.
                                    committed_seek_ms = restore_ms as i64;
                                    crate::map_log!(
                                        2,
                                        "DecoderWorker recovered ADTS OutOfRange seek_ms({}) -> restored {}ms",
                                        target_seek,
                                        restore_ms
                                    );
                                } else {
                                    crate::map_log!(
                                        3,
                                        "DecoderWorker recovered post-EOF seek_ms({}) via demuxer re-init",
                                        target_seek
                                    );
                                }
                            }
                        }
                        if !recovered {
                            crate::map_log!(
                                1,
                                "DecoderWorker seek_ms({}) failed: {:?}",
                                target_seek,
                                e
                            );
                            seek_ok = false;
                            fallback_pos_ms =
                                eng_lock.as_ref().map(|eng| eng.position_ms() as i64);
                        }
                    }
                    None => {}
                }
            }
        }
        if let (Some(ref session), Some(actual_ms)) = (&session_opt, actual_seek_ms_opt) {
            if seek_ok {
                if session.hls_vod().is_some() {
                    // HLS VOD anchors are maintained authoritatively by HlsVodState.
                } else if session.flush_seq() != flush_seq_before {
                    let flush_byte = session.last_flush_target();
                    if !session.has_byte_time_anchors()
                        || session.mapped_byte_to_ms(flush_byte, true) > target_seek
                    {
                        session.record_verified_byte_time_anchor(flush_byte, actual_ms as i64);
                    }
                } else if target_seek > 0 {
                    let (probe_seek_opt, probe_read_end) = session.probe_seek_tracking();
                    let est_byte = session.estimate_byte_for_ms(actual_ms as i64);
                    let target_byte_opt = probe_seek_opt
                        .filter(|&p| probe_read_end.saturating_sub(p) <= 192 * 1024)
                        .or_else(|| {
                            est_byte.map(|e| {
                                if probe_read_end > 0 {
                                    e.min(probe_read_end)
                                } else {
                                    e
                                }
                            })
                        });
                    if let Some(ab) = target_byte_opt {
                        let (r_start, r_end, _) = session.body_metrics();
                        if ab < r_start || ab >= r_end {
                            session.reanchor_circular_after_probe_seek(ab, probe_read_end);
                            if !session.has_byte_time_anchors()
                                || session.mapped_byte_to_ms(ab, true) > target_seek
                            {
                                session.record_verified_byte_time_anchor(ab, actual_ms as i64);
                            }
                        }
                    }
                }
            }
        }
        drop(probe_guard);

        // Discard stale seek commit completely if stop/begin_open or a newer seek arrived
        // while `eng.seek_ms` was running (otherwise slow linear seeks overwrite newer pos_ms).
        if is_superseded() {
            return true;
        }

        if !seek_ok {
            self.decoder_eof_arc.store(was_eof, Ordering::Relaxed);
            if let Some(real_pos) = fallback_pos_ms {
                self.pos_ms.store(real_pos, Ordering::Relaxed);
                let f = if cur_dev_sr > 0 {
                    (real_pos * cur_dev_sr * 1024) / 1000
                } else {
                    0
                };
                self.pos_frames.store(f, Ordering::Relaxed);
                self.tele.post_event(
                    EventType::Position,
                    MapEventData {
                        position_ms: real_pos,
                    },
                );
            }
            let _ = self
                .seek_req
                .compare_exchange(gen, -1, Ordering::AcqRel, Ordering::Acquire);
            return true;
        }

        self.track_exhausted.store(false, Ordering::Release);
        self.pipeline.reset(committed_seek_ms == 0);
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

        self.pos_ms.store(committed_seek_ms, Ordering::Relaxed);
        let f = if cur_dev_sr > 0 {
            (committed_seek_ms * cur_dev_sr * 1024) / 1000
        } else {
            0
        };
        self.pos_frames.store(f, Ordering::Relaxed);
        self.tele.post_event(
            EventType::Position,
            MapEventData {
                position_ms: committed_seek_ms,
            },
        );
        self.seek_req
            .compare_exchange(gen, -1, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
    }

    fn scan_flac_frames_at(
        session: &StreamSession,
        offset: u64,
        len: usize,
        sr: u32,
        min_bs: u16,
        max_bs: u16,
        dur_ms: i64,
        cached_only: bool,
    ) -> Vec<(u64, u64, i64)> {
        let mut buf = vec![0u8; len];
        let got = if cached_only {
            session.read_cached_body_at(offset, &mut buf)
        } else {
            match session.read_via_probe_cache(offset, &mut buf) {
                Some(Ok(n)) => n,
                _ => 0,
            }
        };
        if got < 16 {
            return Vec::new();
        }
        ByteTimeMap::scan_flac_frames_in_slice(&buf[..got], offset, sr, min_bs, max_bs, dur_ms)
    }

    fn prepare_patched_flac_seek<F: Fn() -> bool>(
        eng_lock: &mut Option<SymphoniaEngine>,
        session: &StreamSession,
        target_seek_ms: i64,
        is_superseded: &F,
    ) {
        let head_bytes = session.head_bytes_copy();
        let Some((sr, min_bs, max_bs)) = ByteTimeMap::parse_flac_stream_info(&head_bytes) else {
            return;
        };
        let Some(first_frame) = ByteTimeMap::parse_flac_first_frame_offset(&head_bytes) else {
            return;
        };
        let dur_ms = session.audio_end_offset().unwrap_or(0) as i64;
        let _ = dur_ms;
        let max_dur_ms = eng_lock
            .as_ref()
            .and_then(|e| e.duration_ms())
            .map(|d| d as i64)
            .unwrap_or(0);
        let target_sample = ((target_seek_ms.max(0) as u128 * sr as u128) / 1000) as u64;
        let mut found_pts: Vec<(u64, u64)> = vec![(first_frame, 0)];

        let (r_start, r_end, _) = session.body_metrics();
        let mut in_ram_bracket = false;
        if r_end > r_start.saturating_add(64) {
            let start_frames = Self::scan_flac_frames_at(
                session,
                r_start,
                24 * 1024,
                sr,
                min_bs,
                max_bs,
                max_dur_ms,
                true,
            );
            let end_probe = r_end.saturating_sub(24 * 1024).max(r_start);
            let end_frames = Self::scan_flac_frames_at(
                session,
                end_probe,
                (r_end - end_probe) as usize,
                sr,
                min_bs,
                max_bs,
                max_dur_ms,
                true,
            );
            for &(off, smp, _) in start_frames.iter().chain(end_frames.iter()) {
                found_pts.push((off, smp));
            }
            if let (Some(&(_, s_lo, _)), Some(&(_, s_hi, _))) =
                (start_frames.first(), end_frames.last())
            {
                if target_sample >= s_lo && target_sample <= s_hi {
                    in_ram_bracket = true;
                    let mut lo = r_start;
                    let mut hi = r_end;
                    for _ in 0..10 {
                        if is_superseded() || hi.saturating_sub(lo) <= 40 * 1024 {
                            break;
                        }
                        let mid = lo + (hi - lo) / 2;
                        let scan_len = ((hi - mid) as usize).clamp(4096, 24 * 1024);
                        let mid_frames = Self::scan_flac_frames_at(
                            session,
                            mid,
                            scan_len,
                            sr,
                            min_bs,
                            max_bs,
                            max_dur_ms,
                            true,
                        );
                        if mid_frames.is_empty() {
                            break;
                        }
                        for &(off, smp, _) in &mid_frames {
                            found_pts.push((off, smp));
                        }
                        let (first_o, first_s, _) = mid_frames[0];
                        let (_, last_s, _) = *mid_frames.last().unwrap();
                        if last_s < target_sample {
                            lo = mid.max(first_o);
                        } else if first_s > target_sample {
                            hi = first_o.saturating_add(64);
                        } else {
                            lo = first_o.saturating_sub(4096).max(r_start);
                            hi = (mid + scan_len as u64).min(r_end);
                            break;
                        }
                    }
                    let final_len = (hi.saturating_sub(lo) as usize).clamp(8 * 1024, 64 * 1024);
                    let bracket_frames = Self::scan_flac_frames_at(
                        session,
                        lo,
                        final_len.min((r_end - lo) as usize),
                        sr,
                        min_bs,
                        max_bs,
                        max_dur_ms,
                        true,
                    );
                    for &(off, smp, _) in &bracket_frames {
                        found_pts.push((off, smp));
                    }
                }
            }
        }

        if !in_ram_bracket && !is_superseded() && session.has_probe_fetcher() {
            if let Some(mut est_byte) = session.estimate_byte_for_ms(target_seek_ms) {
                let audio_end = session.audio_end_offset().unwrap_or(u64::MAX);
                for _attempt in 0..2 {
                    if is_superseded() {
                        break;
                    }
                    let probe_start = est_byte.saturating_sub(24 * 1024).max(first_frame);
                    let frames = Self::scan_flac_frames_at(
                        session,
                        probe_start,
                        64 * 1024,
                        sr,
                        min_bs,
                        max_bs,
                        max_dur_ms,
                        false,
                    );
                    if frames.is_empty() {
                        break;
                    }
                    for &(off, smp, ms) in &frames {
                        found_pts.push((off, smp));
                        session.record_verified_byte_time_anchor(off, ms);
                    }
                    let first_s = frames[0].1;
                    let last_s = frames.last().unwrap().1;
                    if target_sample >= first_s && target_sample <= last_s {
                        break;
                    }
                    // Extrapolate refinement using local sample density inside the probed page or average rate.
                    let local_bps = if frames.len() >= 2 && last_s > first_s {
                        let d_bytes = frames.last().unwrap().0.saturating_sub(frames[0].0) as f64;
                        let d_smp = (last_s - first_s) as f64;
                        (d_bytes / d_smp).max(0.1)
                    } else if max_dur_ms > 0 && audio_end > first_frame && audio_end != u64::MAX {
                        let tot_smp = (max_dur_ms as f64 / 1000.0) * sr as f64;
                        ((audio_end - first_frame) as f64 / tot_smp.max(1.0)).max(0.1)
                    } else {
                        break;
                    };
                    let ref_pt = if target_sample < first_s {
                        frames[0]
                    } else {
                        *frames.last().unwrap()
                    };
                    let delta_smp = target_sample as i128 - ref_pt.1 as i128;
                    let shift = (delta_smp as f64 * local_bps) as i64;
                    let next_est = (ref_pt.0 as i64).saturating_add(shift).max(first_frame as i64) as u64;
                    if next_est.abs_diff(probe_start + 32 * 1024) < 8_192 {
                        break;
                    }
                    est_byte = next_est;
                }
            }
        }

        if is_superseded() {
            return;
        }
        session.record_flac_seek_points(&found_pts);
        let all_pts = session.flac_seek_points();
        if all_pts.len() < 2 {
            return;
        }
        if let Some((vhead, vdelta)) =
            ByteTimeMap::build_synthetic_flac_head(&head_bytes, first_frame, &all_pts)
        {
            session.set_decoding_audio(false);
            if let Ok(new_eng) =
                SymphoniaEngine::new_patched_flac(vhead, vdelta, session.create_reader())
            {
                *eng_lock = Some(new_eng);
            }
            session.set_decoding_audio(true);
        }
    }

    /// Ensures a flushed live stream re-initializes its `SymphoniaEngine` once data arrives.
    /// Returns `true` if ready to proceed, `false` if waiting for stream bytes.
    fn ensure_stream_initialized(&mut self) -> bool {
        if !self.stream_reinit_needed.load(Ordering::Acquire) {
            return true;
        }

        let maybe_init = self.session_arc.read().ok().and_then(|guard| {
            let session = guard.as_ref()?;
            let has_data = session.head_size() > 0
                || session.range_end() > session.range_start()
                || session.is_eof();
            if has_data {
                Some((
                    session.create_reader(),
                    session.is_fully_buffered(),
                    session.enter_probe(),
                ))
            } else {
                None
            }
        });

        let Some((reader, allow_scan, _probe_guard)) = maybe_init else {
            return false;
        };

        if let Ok(new_eng) = SymphoniaEngine::new_with_options(reader, None, allow_scan) {
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

    fn has_rebuffer_cushion(&self) -> bool {
        let Ok(guard) = self.producer_arc.lock() else {
            return false;
        };
        let Some(ref prod) = *guard else {
            return false;
        };
        let cap = prod.capacity();
        let used = cap.saturating_sub(prod.slots_available());
        if !self.is_stream_arc.load(Ordering::Relaxed) || self.decoder_eof_arc.load(Ordering::Acquire) {
            return used > 0;
        }
        let sr = self.dev_sr_arc.load(Ordering::Relaxed).max(8000) as usize;
        let ch = (self.dev_ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
        let target_ms = if self.at_live_edge_arc.load(Ordering::Relaxed) {
            750
        } else {
            250
        };
        let required = ((sr * ch * target_ms) / 1000)
            .min(cap / 2)
            .max(2048)
            .min(cap);
        used >= required
    }

    fn check_buffering_recovery(&self) {
        if self.is_buffering.load(Ordering::Acquire) && self.has_rebuffer_cushion() {
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
        if self.is_stream_arc.load(Ordering::Relaxed) {
            let io_truncated = self
                .engine_arc
                .lock()
                .ok()
                .and_then(|g| g.as_ref().map(|e| e.last_eof_was_io_truncation()))
                .unwrap_or(false);
            if io_truncated {
                let is_buf_eof = self
                    .session_arc
                    .read()
                    .ok()
                    .and_then(|g| g.as_ref().map(|b| b.is_eof()))
                    .unwrap_or(true);

                if !is_buf_eof {
                    if PlaybackState::from_i32(self.state.load(Ordering::Relaxed))
                        == PlaybackState::Playing
                    {
                        self.set_buffering(true);
                    }
                    thread::sleep(Duration::from_millis(15));
                    return;
                }
            }
        }

        if !self.decoder_eof_arc.swap(true, Ordering::SeqCst) {
            crate::map_log!(3, "DecoderWorker reached EOF");
        }

        self.pipeline.flush_resampler_into_pending();
        if !self.try_drain_pending() {
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
                            let preempted = self.seek_req.load(Ordering::Acquire) >= 0;
                            if !preempted
                                && self.is_producer_empty()
                                && PlaybackState::from_i32(self.state.load(Ordering::Relaxed)) == PlaybackState::Playing
                            {
                                self.set_buffering(true);
                            }
                            if !preempted {
                                thread::sleep(Duration::from_millis(10));
                            }
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

            if self.seek_req.load(Ordering::Acquire) >= 0 {
                return;
            }

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

            let _drained = self.try_drain_pending();
            self.check_buffering_recovery();
        } else if !eof_reached {
            self.wait_for_wake(5);
        }
    }

    #[inline]
    fn try_drain_pending(&mut self) -> bool {
        // Peterson handshake with `dispatch_seek_to_decoder`: publish `in_rtrb_push`
        // before sampling `seek_req` so seek cannot flush `rtrb` while stale pre-seek
        // samples are still in flight into `producer_arc`.
        self.in_rtrb_push.store(true, Ordering::SeqCst);
        let pending_seek = self.seek_req.load(Ordering::SeqCst) >= 0;
        let cur_flush = self.flush_generation.load(Ordering::SeqCst);
        let fl_pending = self.flush_acknowledged.load(Ordering::Acquire) < cur_flush;
        let drained = if pending_seek || fl_pending {
            false
        } else {
            self.pipeline.drain_pending_to(&self.producer_arc)
        };
        self.in_rtrb_push.store(false, Ordering::Release);
        drained
    }

    fn run(&mut self) {
        while self.running.load(Ordering::Relaxed) {
            self.poll_renderer_flags();

            if self.is_stream_arc.load(Ordering::Relaxed) {
                if let Ok(sess_guard) = self.session_arc.read() {
                    if let Some(ref session) = *sess_guard {
                        let latest = session.latest_seek_gen();
                        if self.seek_req.load(Ordering::SeqCst) < 0 {
                            session.acknowledge_seek_gen(latest);
                        }
                    }
                }
            }

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

            if !self.try_drain_pending() {
                self.wait_for_wake(3);
                continue;
            }

            if self.available_producer_slots() < 2048 {
                self.wait_for_wake(3);
                continue;
            }

            if self.seek_req.load(Ordering::Acquire) >= 0 {
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
    /// Optional descriptive error captured during the last failed source open.
    pub last_open_error_message: Arc<RwLock<Option<String>>>,
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

    /// Generation counter requested by seek flushes.
    pub flush_generation: Arc<AtomicU64>,
    /// Generation counter acknowledging completed seek flushes by the audio thread.
    pub flush_acknowledged: Arc<AtomicU64>,
    /// Guard flag indicating `DecoderWorker` is actively pushing samples into `rtrb`.
    pub in_rtrb_push: Arc<AtomicBool>,
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
    pub seek_epoch: Arc<AtomicU64>,
    pub decoder_eof: Arc<AtomicBool>,
    pub stream_reinit_needed: Arc<AtomicBool>,
    reopen_local_fn: Arc<Mutex<Option<ReopenSourceFn>>>,
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
    pub fn new_deck(
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
        let last_open_error_message = Arc::new(RwLock::new(None));
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
        let in_rtrb_push = Arc::new(AtomicBool::new(false));
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
        let reopen_local_fn = Arc::new(Mutex::new(None));
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
            notification_callback: Some(notif_cb),
            anti_pop: Default::default(),
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
            last_open_error_message,
            custom_source_handle,
            telemetry,
            silence_config,
            audio_producer,
            cmd_producer,
            visualizer_seqlock,
            flush_generation,
            flush_acknowledged,
            in_rtrb_push,
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
            reopen_local_fn,
            network_streamer_abort,
            decoder_running,
            decoder_wake,
            decoder_thread: None,
            open_generation: Arc::new(AtomicU64::new(0)),
            seek_epoch: Arc::new(AtomicU64::new(0)),
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
            in_rtrb_push: self.in_rtrb_push.clone(),
            stream_reinit_needed: self.stream_reinit_needed.clone(),
            reopen_local_fn: self.reopen_local_fn.clone(),
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

    /// Records a descriptive human-readable error message alongside `err_code`.
    pub fn mark_open_error_with_message(&self, err_code: i32, message: &str) -> i32 {
        if let Ok(mut guard) = self.last_open_error_message.write() {
            *guard = Some(format!("{} (code: {})", message, err_code));
        }
        crate::map_log!(1, "Source open error [{}]: {}", err_code, message);
        self.mark_open_error(err_code)
    }

    /// Takes the last descriptive source-open failure message, if recorded.
    pub fn take_last_open_error_message(&self) -> Option<String> {
        self.last_open_error_message
            .write()
            .ok()
            .and_then(|mut g| g.take())
    }

    pub fn begin_open(&mut self) -> i32 {
        let _ = self.stop();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        self.seek_epoch.fetch_add(1, Ordering::AcqRel);
        self.clear_pending_seek();
        self.network_streamer_abort.store(true, Ordering::Release);
        self.is_stream.store(false, Ordering::Release);
        if let Ok(mut guard) = self.last_open_error_message.write() {
            *guard = None;
        }
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
        *lock_unpoisoned(&self.reopen_local_fn) = None;
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
            || trimmed.starts_with("data:")
        {
            let url = if let Some(stripped) = trimmed.strip_prefix("icy://") {
                format!("http://{}", stripped)
            } else {
                trimmed.to_string()
            };
            self.open_network_with_cancel(&url, headers, cancel)
        } else {
            let res = self.open_file(trimmed);
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            res
        }
    }

    fn open_hls_playlist_bytes(
        &mut self,
        url: &str,
        m3u8_bytes: &[u8],
        cancel: Option<&CancelToken>,
        backend: &HlsFetchBackend,
        vod_use_memory: bool,
    ) -> i32 {
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        crate::map_log!(3, "open_hls_playlist: url={}", url);
        let parsed = match crate::hls::M3u8Parser::parse(m3u8_bytes) {
            Ok(p) => p,
            Err(_) => {
                crate::map_log!(1, "open_hls_playlist failed: invalid m3u8 playlist");
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };

        let (base_media_url, media_playlist) = match parsed {
            crate::hls::ParsedHlsPlaylist::Master { variants } => {
                crate::map_log!(
                    4,
                    "open_hls_playlist: Master playlist with {} variants",
                    variants.len()
                );
                let Some(first_var) = variants.first() else {
                    crate::map_log!(1, "open_hls_playlist failed: no variants in master playlist");
                    return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                };
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                let media_url = crate::hls::resolve_hls_uri(url, &first_var.uri);
                let media_bytes = match backend.fetch_playlist(&media_url) {
                    Ok(b) => b,
                    Err(code) => {
                        if cancel.is_some_and(|c| c.is_cancelled()) {
                            return self.mark_open_error(MAP_ERROR_ABORTED);
                        }
                        crate::map_log!(
                            1,
                            "open_hls_playlist failed to fetch media playlist from {}",
                            media_url
                        );
                        return self.mark_open_error(code);
                    }
                };
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                match crate::hls::M3u8Parser::parse(&media_bytes) {
                    Ok(p) => (media_url, p),
                    Err(_) => {
                        crate::map_log!(
                            1,
                            "open_hls_playlist failed: invalid variant media playlist"
                        );
                        return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                    }
                }
            }
            media => (url.to_string(), media),
        };

        let crate::hls::ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence,
            segments,
            total_duration_seconds,
        } = media_playlist
        else {
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        };

        crate::map_log!(
            3,
            "open_hls_playlist: Media playlist parsed (segments={}, is_live={}, duration={:.2}s)",
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

        if !is_live && vod_use_memory {
            let max_segs = segments.len().min(512);
            let mut combined_audio = Vec::new();
            let mut hint_ext: Option<&'static str> = None;

            for seg in segments.iter().take(max_segs) {
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    return self.mark_open_error(MAP_ERROR_ABORTED);
                }
                let seg_url = crate::hls::resolve_hls_uri(&base_media_url, &seg.uri);
                let Some((audio_bytes, fmt)) =
                    backend.fetch_segment_audio(&seg_url, seg.byte_range)
                else {
                    if combined_audio.is_empty() {
                        return self.mark_open_error(MAP_ERROR_FILE_NOT_FOUND);
                    }
                    break;
                };
                if hint_ext.is_none() {
                    hint_ext = encoding_format_to_extension(fmt);
                }
                combined_audio.extend_from_slice(&audio_bytes);
            }

            if combined_audio.is_empty() {
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }

            let res_code = self.open_memory_with_hint(&combined_audio, hint_ext);
            if res_code == MAP_SUCCESS && total_duration_seconds > 0.0 {
                let dur_ms = (total_duration_seconds * 1000.0) as i64;
                self.duration_ms.store(dur_ms, Ordering::SeqCst);
                self.telemetry
                    .post_event(EventType::Duration, MapEventData { duration_ms: dur_ms });
            }
            return res_code;
        }

        let first_seg = &segments[0];
        let first_dur_ms = (first_seg.duration_seconds.max(0.0) * 1000.0).round() as i64;
        let total_vod_dur_ms = if !is_live && total_duration_seconds > 0.0 {
            (total_duration_seconds * 1000.0).round() as i64
        } else {
            0
        };
        let first_seg_url = crate::hls::resolve_hls_uri(&base_media_url, &first_seg.uri);
        let Some((first_audio, seg_fmt)) =
            backend.fetch_segment_audio(&first_seg_url, first_seg.byte_range)
        else {
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
        };
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }

        let vod_segments: Option<Vec<crate::buffer::HlsVodSegment>> = if !is_live {
            let mut cum_ms = 0i64;
            Some(
                segments
                    .iter()
                    .map(|s| {
                        let d_ms = (s.duration_seconds.max(0.0) * 1000.0).round() as i64;
                        let entry = crate::buffer::HlsVodSegment {
                            url: crate::hls::resolve_hls_uri(&base_media_url, &s.uri),
                            byte_range: s.byte_range,
                            start_ms: cum_ms,
                            duration_ms: d_ms,
                        };
                        cum_ms = cum_ms.saturating_add(d_ms);
                        entry
                    })
                    .collect(),
            )
        } else {
            None
        };

        let first_len = first_audio.len() as u64;
        let first_seg_copy = if !is_live {
            first_audio.clone()
        } else {
            Vec::new()
        };
        let mut attached_vod: Option<Arc<crate::buffer::HlsVodState>> = None;
        let res_code = self.open_stream_ex_with_setup(
            &first_audio,
            None,
            -1,
            is_live,
            4 * 1024 * 1024,
            seg_fmt,
            |_, _, session, boundary| {
                let a_start = boundary.audio_start.max(0) as u64;
                session.configure_byte_time_map(a_start, 0, total_vod_dur_ms);
                if first_dur_ms > 0 {
                    session.push_segment_anchor(first_len, first_dur_ms);
                }
                if let Some(ref segs) = vod_segments {
                    let vod = crate::buffer::HlsVodState::new(
                        segs.clone(),
                        total_vod_dur_ms,
                        a_start,
                        first_seg_copy.clone(),
                        first_len,
                        first_dur_ms,
                    );
                    session.set_hls_vod(vod.clone());
                    attached_vod = Some(vod);
                }
            },
        );
        if res_code != MAP_SUCCESS {
            return res_code;
        }

        if total_vod_dur_ms > 0 {
            self.duration_ms.store(total_vod_dur_ms, Ordering::SeqCst);
            self.telemetry.post_event(
                EventType::Duration,
                MapEventData {
                    duration_ms: total_vod_dur_ms,
                },
            );
            if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
                session.configure_byte_time_map(session.audio_start_offset(), 0, total_vod_dur_ms);
            }
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
        }

        if is_live && self.is_analysis {
            crate::map_log!(
                3,
                "open_hls_playlist: livestream detected on analysis deck; skipping background HLS streamer thread for {}",
                url
            );
            return MAP_SUCCESS;
        }

        self.network_streamer_abort.store(true, Ordering::Release);
        let new_abort = Arc::new(AtomicBool::new(false));
        self.network_streamer_abort = new_abort.clone();

        if let Some(session) = read_unpoisoned(&self.stream_session).clone() {
            let tracker = crate::hls::HlsPlaylistTracker::new(
                base_media_url,
                is_live,
                target_duration,
                media_sequence,
                &segments,
            );
            let pending_targets = tracker.resolve_targets(&segments[1..]);
            spawn_hls_streamer_thread(
                session,
                new_abort,
                self.decoder_running.clone(),
                backend.to_streaming_backend(),
                tracker,
                pending_targets,
                first_len,
                first_dur_ms,
                attached_vod,
            );
        }

        MAP_SUCCESS
    }

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
        let _ = reader.read_to_end(&mut m3u8_bytes);
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return self.mark_open_error(MAP_ERROR_ABORTED);
        }
        let backend = HlsFetchBackend::Network {
            agent: Arc::new(agent),
            headers: headers.map(|h| h.to_vec()),
        };
        self.open_hls_playlist_bytes(url, &m3u8_bytes, cancel, &backend, false)
    }

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
        let accept_ranges =
            response_header_str(&res, "accept-ranges").map(|s| s.to_ascii_lowercase());
        let mut range_supported = accept_ranges
            .as_deref()
            .is_some_and(|s| s.contains("bytes"));
        let range_explicitly_none = accept_ranges
            .as_deref()
            .is_some_and(|s| s.contains("none"));
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

        let (initial_data, was_aborted, reached_eof) =
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

        let effective_content_length = if content_length > 0 {
            content_length
        } else if reached_eof {
            initial_data.len() as i64
        } else {
            -1
        };

        let mut tail_data: Option<Vec<u8>> = None;
        let mut forced_audio_end: Option<u64> = None;

        if !reached_eof
            && effective_content_length > 0
            && (initial_data.len() as i64) < effective_content_length
        {
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
            let (_status, boundary) =
                StreamClassifier::detect_head_boundary(&initial_data, effective_content_length);
            let mut range_already_proven = false;
            let mut range_rejected = false;
            let mut fetch_probe_range = |s: i64, e: i64| -> Option<Vec<u8>> {
                if range_rejected {
                    return None;
                }
                let expected = (e - s + 1).max(0) as usize;
                match fetch_range_bytes_status(&agent, url, headers, s, e) {
                    Ok(bytes) if bytes.len() == expected => {
                        range_already_proven = true;
                        Some(bytes)
                    }
                    Ok(_) => None,
                    Err(Some(status)) if status != 416 => {
                        range_rejected = true;
                        None
                    }
                    Err(_) => None,
                }
            };
            if boundary.audio_end > 0
                && boundary.audio_end < effective_content_length
                && (effective_content_length - boundary.audio_end) <= 4 * 1024 * 1024
            {
                if let Some(tail) = fetch_probe_range(boundary.audio_end, effective_content_length - 1)
                {
                    tail_data = Some(tail);
                    forced_audio_end = Some(boundary.audio_end as u64);
                    range_supported = true;
                }
            } else if StreamClassifier::container_needs_tail_scan(boundary.container) {
                let (extracted, ae_opt) = resolve_tail_metadata_with_fetcher(
                    boundary.container,
                    effective_content_length,
                    boundary.audio_start,
                    |s, e| fetch_probe_range(s, e),
                );
                if range_already_proven {
                    range_supported = true;
                }
                if let Some((bytes, _off)) = extracted {
                    tail_data = Some(bytes);
                }
                if let Some(ae) = ae_opt {
                    forced_audio_end = Some(ae as u64);
                }
            }
            if range_rejected {
                range_supported = false;
            } else if !range_supported && !range_explicitly_none && !range_already_proven {
                if fetch_range_bytes(&agent, url, headers, 0, 0).is_some() {
                    range_supported = true;
                }
            }
            if cancel.is_some_and(|c| c.is_cancelled()) {
                return self.mark_open_error(MAP_ERROR_ABORTED);
            }
        } else if reached_eof && effective_content_length > 0 {
            let (_status, boundary) =
                StreamClassifier::detect_head_boundary(&initial_data, effective_content_length);
            if boundary.audio_end > 0
                && boundary.audio_end < effective_content_length
                && (effective_content_length - boundary.audio_end) <= 4 * 1024 * 1024
            {
                let off = boundary.audio_end as usize;
                tail_data = Some(initial_data[off..].to_vec());
                forced_audio_end = Some(boundary.audio_end as u64);
            } else if StreamClassifier::container_needs_tail_scan(boundary.container) {
                let (extracted, ae_opt) = resolve_tail_metadata_with_fetcher(
                    boundary.container,
                    effective_content_length,
                    boundary.audio_start,
                    |s, e| {
                        let s = s.max(0) as usize;
                        let e = (e + 1).max(0) as usize;
                        initial_data.get(s..e.min(initial_data.len())).map(|sl| sl.to_vec())
                    },
                );
                if let Some((bytes, _off)) = extracted {
                    tail_data = Some(bytes);
                }
                if let Some(ae) = ae_opt {
                    forced_audio_end = Some(ae as u64);
                }
            }
        }

        let preserved_icy = self.icy_metadata.read().ok().and_then(|g| g.clone());
        let is_live = effective_content_length <= 0;
        let is_analysis_deck = self.is_analysis;
        let mut reader_opt = Some(reader);
        let tail_ref = tail_data.as_deref();
        let forced_ae = forced_audio_end;
        let res_code = self.open_stream_ex_with_setup(
            &initial_data,
            tail_ref,
            effective_content_length,
            is_live,
            StreamSession::DEFAULT_RING_CAPACITY,
            encoding_format,
            |abort_slot, dec_running, session, boundary| {
                if range_supported && !is_live {
                    session.set_supports_range(true);
                    let range_url = url.to_string();
                    let range_headers = headers.map(|h| h.to_vec());
                    let range_agent = build_network_probe_agent();
                    let session_flag = session.clone();
                    let tot_u64 = effective_content_length.max(0) as u64;
                    let fetcher: ProbeFetcherFn = Arc::new(move |offset, len| {
                        if !session_flag.supports_range() || len == 0 {
                            return None;
                        }
                        let max_end = if tot_u64 > 0 {
                            tot_u64.saturating_sub(1)
                        } else {
                            u64::MAX
                        };
                        if offset > max_end {
                            return Some(Vec::new());
                        }
                        let end_inc = offset
                            .saturating_add((len as u64).saturating_sub(1))
                            .min(max_end);
                        match fetch_range_bytes_status(
                            &range_agent,
                            &range_url,
                            range_headers.as_deref(),
                            offset as i64,
                            end_inc as i64,
                        ) {
                            Ok(bytes) => Some(bytes),
                            Err(Some(status)) if status != 416 => {
                                session_flag.set_supports_range(false);
                                None
                            }
                            Err(_) => None,
                        }
                    });
                    session.set_probe_fetcher(Some(fetcher));
                }
                if let Some(ae) = forced_ae {
                    session.set_has_container_tail(
                        boundary.container == crate::decoder::ContainerFormat::Mp4,
                    );
                    session.set_audio_end(ae);
                    if let Some(td) = tail_ref {
                        let td_off = if ae < effective_content_length as u64 {
                            ae
                        } else {
                            (effective_content_length - td.len() as i64).max(0) as u64
                        };
                        session.set_tail(td, Some(td_off));
                    }
                    boundary.audio_end = ae as i64;
                }
                if let Ok(guard) = latest_icy.lock() {
                    if let Some(ref icy_bytes) = *guard {
                        session.set_icy_meta(icy_bytes);
                    }
                }
                if let Ok(mut slot) = session_slot.lock() {
                    *slot = Some(session.clone());
                }

                if reached_eof && (initial_data.len() as i64) >= effective_content_length {
                    session.mark_eof();
                    return;
                }

                if is_live && is_analysis_deck {
                    crate::map_log!(
                        3,
                        "open_network: livestream detected on analysis deck; skipping background network streamer thread for {}",
                        url
                    );
                    return;
                }

                abort_slot.store(true, Ordering::Release);
                let new_abort = Arc::new(AtomicBool::new(false));
                *abort_slot = new_abort.clone();

                if let Some(net_reader) = reader_opt.take() {
                    spawn_network_streamer_thread(
                        net_reader,
                        session.clone(),
                        new_abort,
                        dec_running.clone(),
                        url.to_string(),
                        headers.map(|h| h.to_vec()),
                        effective_content_length,
                        is_live,
                    );
                }
            },
        );
        if let Ok(mut guard) = self.icy_metadata.write() {
            if guard.is_none() {
                *guard = preserved_icy;
            }
        }
        if res_code != MAP_SUCCESS {
            return res_code;
        }

        crate::map_log!(
            3,
            "Network stream opened: {} (content_length={}, is_live={})",
            url,
            effective_content_length,
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
                let (extracted, ae_opt) = resolve_tail_metadata_with_fetcher(
                    boundary.container,
                    total_size,
                    boundary.audio_start,
                    |s, e| {
                        let len = (e - s + 1).max(0) as usize;
                        if reader.seek(SeekFrom::Start(s as u64)).is_err() {
                            return None;
                        }
                        let mut tbuf = vec![0u8; len];
                        let mut tgot = 0;
                        while tgot < tbuf.len() {
                            match reader.read(&mut tbuf[tgot..]) {
                                Ok(0) => break,
                                Ok(n) => tgot += n,
                                Err(err) if err.kind() == ErrorKind::Interrupted => continue,
                                Err(_) => break,
                            }
                        }
                        tbuf.truncate(tgot);
                        Some(tbuf)
                    },
                );
                if let Some((bytes, off)) = extracted {
                    tail_out = Some((bytes, Some(off)));
                }
                if let Some(ae) = ae_opt {
                    boundary.audio_end = ae;
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
            self.open_network_with_cancel(path, None, None)
        }

        #[cfg(not(target_arch = "wasm32"))]
        {
            if path.to_ascii_lowercase().ends_with(".m3u8") {
                if let Ok(m3u8_bytes) = std::fs::read(path) {
                    if crate::hls::M3u8Parser::is_m3u8(&m3u8_bytes) {
                        let backend = HlsFetchBackend::LocalFile;
                        return self.open_hls_playlist_bytes(
                            path,
                            &m3u8_bytes,
                            None,
                            &backend,
                            true,
                        );
                    }
                }
            }

            let source = match crate::buffer::FileByteSource::open(std::path::Path::new(path)) {
                Ok(s) => s,
                Err(e) => {
                    let code = if e.kind() == ErrorKind::PermissionDenied {
                        MAP_ERROR_ACCESS_DENIED
                    } else {
                        MAP_ERROR_FILE_NOT_FOUND
                    };
                    return self.mark_open_error_with_message(
                        code,
                        &format!("Failed to open audio file '{}': {}", path, e),
                    );
                }
            };

            let ext = std::path::Path::new(path)
                .extension()
                .and_then(|e| e.to_str());
            let reopen_path = path.to_string();
            *lock_unpoisoned(&self.reopen_local_fn) = Some(Arc::new(move || {
                crate::buffer::FileByteSource::open(std::path::Path::new(&reopen_path))
                    .ok()
                    .map(|s| Box::new(s) as Box<dyn symphonia::core::io::MediaSource>)
            }));
            let rc = self.open_seekable_file_byte_source(source, ext, path);
            if rc != MAP_SUCCESS {
                *lock_unpoisoned(&self.reopen_local_fn) = None;
            }
            rc
        }
    }

    /// Shared opener for any seekable [`FileByteSource`] (local files or Android
    /// `content://`/`android.resource://` FDs) using $O(1)$ RAM and zero duplicate opens.
    pub fn open_seekable_file_byte_source(
        &mut self,
        #[cfg_attr(target_arch = "wasm32", allow(unused_mut))] mut source: FileByteSource,
        ext_hint: Option<&str>,
        label: &str,
    ) -> i32 {
        #[cfg(target_arch = "wasm32")]
        {
            let _ = (source, ext_hint, label);
            self.mark_open_error(MAP_ERROR_UNSUPPORTED)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let file_size = symphonia::core::io::MediaSource::byte_len(&source).unwrap_or(0);
            let (initial_buf, tail_data, boundary) =
                Self::extract_seekable_head_and_tail(&mut source, file_size as i64);
            let _ = source.seek(SeekFrom::Start(0));

            let effective_hint = boundary.container.hint_extension().or(ext_hint);
            crate::map_log!(
                4,
                "open_file sniffed: source={}, container={:?}, effective_hint={:?}, size={}",
                label,
                boundary.container,
                effective_hint,
                file_size
            );

            let eng = match SymphoniaEngine::new(source, effective_hint) {
                Ok(e) => e,
                Err(e) => {
                    return self.mark_open_error_with_message(
                        MAP_ERROR_DECODE_FAILED,
                        &format!("Failed to decode '{}': {:?}", label, e),
                    );
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
            crate::map_log!(3, "open_seekable_file_byte_source successfully opened: {}", label);
            MAP_SUCCESS
        }
    }

    pub fn open_memory_with_hint(&mut self, data: &[u8], hint_ext: Option<&str>) -> i32 {
        self.open_memory_owned_with_hint(data.to_vec(), hint_ext)
    }

    /// Zero-copy memory decoder transferring ownership of `data` directly to `Cursor<Vec<u8>>`.
    pub fn open_memory_owned_with_hint(&mut self, data: Vec<u8>, hint_ext: Option<&str>) -> i32 {
        let _ = self.begin_open();
        self.open_generation.fetch_add(1, Ordering::AcqRel);
        crate::map_log!(3, "open_memory_owned: size={}, hint={:?}", data.len(), hint_ext);

        let total_size = data.len() as i64;
        let (_status, boundary) = StreamClassifier::detect_head_boundary(&data, total_size);
        let effective_hint = boundary.container.hint_extension().or(hint_ext);
        crate::map_log!(
            4,
            "open_memory sniffed: container={:?}, effective_hint={:?}",
            boundary.container,
            effective_hint
        );

        let head_keep = if boundary.audio_start > 0 {
            ((boundary.audio_start as usize) + 16384).min(data.len())
        } else {
            data.len().min(65536)
        };
        let preview_buf = data[..head_keep].to_vec();

        let mut tail_owned: Option<(Vec<u8>, Option<u64>)> = None;
        if total_size > 0 {
            if boundary.audio_end > 0
                && boundary.audio_end < total_size
                && (total_size - boundary.audio_end) <= 4 * 1024 * 1024
            {
                let off = boundary.audio_end as usize;
                tail_owned = Some((data[off..].to_vec(), Some(off as u64)));
            } else if StreamClassifier::container_needs_tail_scan(boundary.container) {
                let (extracted, _) = resolve_tail_metadata_with_fetcher(
                    boundary.container,
                    total_size,
                    boundary.audio_start,
                    |s, e| {
                        let s = s.max(0) as usize;
                        let e = (e + 1).max(0) as usize;
                        data.get(s..e.min(data.len())).map(|sl| sl.to_vec())
                    },
                );
                if let Some((bytes, off)) = extracted {
                    tail_owned = Some((bytes, Some(off)));
                }
            }
        }

        let session = StreamSession::new(65536, Some(data.len() as u64), false);
        let classified_boundary = session.ingest_classified(
            &preview_buf,
            tail_owned.as_ref().map(|(v, off)| (v.as_slice(), *off)),
        );
        session.mark_eof();

        let total_len = data.len() as u64;
        let shared_data = Arc::new(data);
        let cursor = SharedMemSource::new(Arc::clone(&shared_data));
        let eng = match SymphoniaEngine::new(cursor, effective_hint) {
            Ok(e) => e,
            Err(e) => {
                crate::map_log!(1, "open_memory failed: decode error: {:?}", e);
                return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
            }
        };

        *lock_unpoisoned(&self.reopen_local_fn) = Some(Arc::new(move || {
            Some(Box::new(SharedMemSource::new(Arc::clone(&shared_data)))
                as Box<dyn symphonia::core::io::MediaSource>)
        }));
        *write_unpoisoned(&self.boundary_info) = Some(classified_boundary);
        *write_unpoisoned(&self.stream_session) = Some(session);

        self.init_engine(eng, false, total_len, &preview_buf);
        crate::map_log!(3, "open_memory_owned successfully opened: size={}", total_len);
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
        self.open_stream_ex_with_setup(
            initial_data,
            tail_data,
            total_size,
            is_live,
            buffer_capacity_bytes,
            encoding_format,
            |_, _, _, _| {},
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn open_stream_ex_with_setup<F>(
        &mut self,
        initial_data: &[u8],
        tail_data: Option<&[u8]>,
        total_size: i64,
        is_live: bool,
        buffer_capacity_bytes: usize,
        encoding_format: i32,
        on_session_ready: F,
    ) -> i32
    where
        F: FnOnce(
            &mut Arc<AtomicBool>,
            &Arc<AtomicBool>,
            &StreamSession,
            &mut crate::decoder::BoundaryInfo,
        ),
    {
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

        let mut boundary = session.ingest_classified(initial_data, tail_data.map(|t| (t, None)));
        on_session_ready(
            &mut self.network_streamer_abort,
            &self.decoder_running,
            &session,
            &mut boundary,
        );
        let container = boundary.container;
        if !initial_data.is_empty() {
            *write_unpoisoned(&self.boundary_info) = Some(boundary);
        }

        let hint = container
            .hint_extension()
            .or_else(|| encoding_format_to_extension(encoding_format));

        let allow_scan = session.is_fully_buffered();
        let reader = session.create_reader();
        let eng = {
            let _probe = session.enter_probe();
            match SymphoniaEngine::new_with_options(reader, hint, allow_scan) {
                Ok(e) => e,
                Err(e) => {
                    drop(_probe);
                    self.network_streamer_abort.store(true, Ordering::Release);
                    session.abort();
                    crate::map_log!(
                        1,
                        "open_stream_ex failed: SymphoniaEngine::new failed for hint={:?}: {:?}",
                        hint,
                        e
                    );
                    return self.mark_open_error(MAP_ERROR_DECODE_FAILED);
                }
            }
        };
        session.set_decoding_audio(true);

        let tot = session.total_size().unwrap_or(0);
        *write_unpoisoned(&self.stream_session) = Some(session);
        self.init_engine(eng, true, tot, initial_data);
        crate::map_log!(3, "open_stream_ex successfully opened (hint={:?})", hint);
        MAP_SUCCESS
    }

    pub fn open_custom_source_with_cancel(
        &mut self,
        source: CustomDartByteSource,
        handle: CustomByteSourceHandle,
        total_size: Option<u64>,
        is_seekable: bool,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        self.open_custom_source_with_hint_cancel(
            source,
            handle,
            total_size,
            is_seekable,
            None,
            cancel,
        )
    }

    pub fn open_custom_source_with_hint_cancel(
        &mut self,
        source: CustomDartByteSource,
        handle: CustomByteSourceHandle,
        total_size: Option<u64>,
        is_seekable: bool,
        hint_ext: Option<&str>,
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
            "open_custom_source: total_size={:?}, is_seekable={}, hint={:?}",
            total_size,
            is_seekable,
            hint_ext
        );

        let abort_handle = handle.clone();
        *write_unpoisoned(&self.custom_source_handle) = Some(handle);
        let _cancel_guard = cancel.map(|c| {
            let h = abort_handle.clone();
            c.on_cancel(move || h.abort())
        });

        let eng = match SymphoniaEngine::new(source, hint_ext) {
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

        let mut parsed_mp4_anchors: Option<Vec<(u64, i64)>> = None;
        let mut parsed_flac_anchors: Option<Vec<(u64, i64)>> = None;
        let mut parsed_mkv_anchors: Option<Vec<(u64, i64)>> = None;
        let tail_snapshot = if !is_live && is_stream {
            self.stream_session
                .read()
                .ok()
                .and_then(|g| g.as_ref().map(|s| s.tail_data()))
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        if !is_live && is_stream {
            let mut mp4_res = if !initial_data.is_empty() {
                ByteTimeMap::extract_mp4_anchors(initial_data)
            } else {
                None
            };
            if mp4_res.is_none() && !tail_snapshot.is_empty() {
                mp4_res = ByteTimeMap::extract_mp4_anchors(&tail_snapshot);
            }
            if let Some((mp4_dur_ms, anchors)) = mp4_res {
                if dur <= 0 && mp4_dur_ms > 0 {
                    dur = mp4_dur_ms;
                }
                parsed_mp4_anchors = Some(anchors);
            } else if !initial_data.is_empty() {
                let head_audio_start = if let Ok(guard) = self.stream_session.read() {
                    guard
                        .as_ref()
                        .map(|s| s.audio_start_offset())
                        .unwrap_or_else(|| boundary.audio_start.max(0) as u64)
                } else {
                    boundary.audio_start.max(0) as u64
                };
                if let Some((flac_dur_ms, anchors)) =
                    ByteTimeMap::extract_flac_anchors(initial_data, head_audio_start)
                {
                    if dur <= 0 && flac_dur_ms > 0 {
                        dur = flac_dur_ms;
                    }
                    parsed_flac_anchors = Some(anchors);
                } else if let Some(mkv_cues) =
                    ByteTimeMap::extract_mkv_anchors(initial_data, &tail_snapshot)
                {
                    parsed_mkv_anchors = Some(mkv_cues);
                }
            }
        }

        // Compute audio payload size (excluding huge ID3v2/FLAC cover art headers) for accurate bitrate
        let (session_audio_start, session_audio_end) = if let Ok(guard) = self.stream_session.read()
        {
            if let Some(ref session) = *guard {
                let s = session.audio_start_offset();
                let e = session
                    .audio_end_offset()
                    .filter(|&end| end > s && (total_bytes == 0 || end <= total_bytes))
                    .unwrap_or(total_bytes);
                (s, e)
            } else {
                let s = boundary.audio_start.max(0) as u64;
                let e = if boundary.audio_end > 0 && (boundary.audio_end as u64) <= total_bytes {
                    boundary.audio_end as u64
                } else {
                    total_bytes
                };
                (s, e)
            }
        } else {
            let s = boundary.audio_start.max(0) as u64;
            let e = if boundary.audio_end > 0 && (boundary.audio_end as u64) <= total_bytes {
                boundary.audio_end as u64
            } else {
                total_bytes
            };
            (s, e)
        };
        let audio_payload_bytes = if total_bytes > 0 {
            if session_audio_end > session_audio_start {
                session_audio_end - session_audio_start
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
                    if !is_live {
                        session.configure_byte_time_map(
                            session_audio_start,
                            session_audio_end,
                            dur,
                        );
                        session.set_has_native_flac_seektable(parsed_flac_anchors.is_some());
                        if let Some(pts) = parsed_mp4_anchors {
                            session.set_byte_time_anchors(pts);
                        } else if let Some(pts) = parsed_flac_anchors {
                            session.set_byte_time_anchors(pts);
                        } else {
                            let mkv_info = ByteTimeMap::parse_mkv_stream_info(initial_data);
                            if let Some((_, _, Some(first_cluster))) = mkv_info {
                                session.refine_byte_time_audio_start(first_cluster);
                            }
                            let mkv_cues_complete =
                                parsed_mkv_anchors.as_ref().is_some_and(|v| v.len() >= 4);
                            if let Some(pts) = parsed_mkv_anchors {
                                session.set_byte_time_anchors(pts);
                            }

                            let ogg_info = ByteTimeMap::parse_ogg_stream_info(initial_data);
                            let flac_info = if ogg_info.is_none() {
                                ByteTimeMap::parse_flac_stream_info(initial_data)
                            } else {
                                None
                            };
                            let wavpack_first = if ogg_info.is_none()
                                && flac_info.is_none()
                                && container_str == "WavPack"
                            {
                                ByteTimeMap::parse_wavpack_first_block_offset(initial_data)
                            } else {
                                None
                            };

                            if let Some((serial, _sr, pre_skip)) = ogg_info {
                                if let Some(first_pg) = ByteTimeMap::parse_ogg_first_audio_page(
                                    initial_data,
                                    0,
                                    serial,
                                    pre_skip,
                                ) {
                                    session.refine_byte_time_audio_start(first_pg);
                                }
                            } else if flac_info.is_some() {
                                if let Some(first_frame) =
                                    ByteTimeMap::parse_flac_first_frame_offset(initial_data)
                                {
                                    session.refine_byte_time_audio_start(first_frame);
                                    session.record_flac_seek_points(&[(first_frame, 0)]);
                                }
                            } else if let Some(wv_off) = wavpack_first {
                                session.refine_byte_time_audio_start(wv_off);
                            }

                            if !self.is_analysis
                                && !mkv_cues_complete
                                && session_audio_end > session_audio_start + 65_536
                                && !initial_data.is_empty()
                            {
                                if let Some(fetcher) = session.probe_fetcher() {
                                    let probe_kind = if let Some((serial, ogg_sr, pre_skip)) =
                                        ogg_info
                                    {
                                        let has_first = ByteTimeMap::parse_ogg_first_audio_page(
                                            initial_data,
                                            0,
                                            serial,
                                            pre_skip,
                                        )
                                        .is_some();
                                        let scan_from = if has_first {
                                            None
                                        } else {
                                            Some(initial_data.len().saturating_sub(32) as u64)
                                        };
                                        Some(VbrProbeKind::Ogg {
                                            serial,
                                            sample_rate: ogg_sr,
                                            pre_skip,
                                            find_first_audio_from: scan_from,
                                        })
                                    } else if let Some((flac_sr, min_bs, max_bs)) = flac_info {
                                        Some(VbrProbeKind::Flac {
                                            sample_rate: flac_sr,
                                            min_bs,
                                            max_bs,
                                        })
                                    } else if let Some((_, scale_ns, _)) = mkv_info {
                                        Some(VbrProbeKind::MkvCluster {
                                            timecode_scale_ns: scale_ns,
                                        })
                                    } else if wavpack_first.is_some() && sr > 0 {
                                        Some(VbrProbeKind::WavPack { sample_rate: sr })
                                    } else {
                                        None
                                    };

                                    if let Some(kind) = probe_kind {
                                        spawn_vbr_probe_thread(
                                            session.clone(),
                                            fetcher,
                                            self.network_streamer_abort.clone(),
                                            session_audio_start,
                                            session_audio_end,
                                            dur,
                                            kind,
                                        );
                                    }
                                }
                            }
                        }
                    }
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

    #[inline]
    fn enqueue_seek(&self, position_ms: i64) -> u64 {
        let clamped = (position_ms.max(0) as u64) & 0xFF_FFFF_FFFF;
        let mut gen = self.seek_counter.fetch_add(1, Ordering::AcqRel) & 0xFF_FFFF;
        if gen == 0 {
            gen = (self.seek_counter.fetch_add(1, Ordering::AcqRel) & 0xFF_FFFF).max(1);
        }
        let packed = (gen << 40) | clamped;
        self.seek_packed.store(packed, Ordering::SeqCst);
        self.seek_request_ms.store(gen as i64, Ordering::SeqCst);
        gen
    }

    #[inline]
    fn clear_pending_seek(&self) {
        self.seek_packed.store(0, Ordering::Release);
        self.seek_request_ms.store(-1, Ordering::Release);
    }

    #[inline]
    fn wait_rtrb_push_idle(&self) {
        let mut spins = 0u32;
        while self.in_rtrb_push.load(Ordering::SeqCst) && spins < 4096 {
            std::hint::spin_loop();
            spins += 1;
        }
    }

    fn complete_at_duration(&mut self, dur: i64) {
        self.seek_epoch.fetch_add(1, Ordering::AcqRel);
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
        let gen = (self.seek_counter.fetch_add(1, Ordering::AcqRel) & 0xFF_FFFF).max(1);
        if let Ok(sess_guard) = self.stream_session.read() {
            if let Some(ref session) = *sess_guard {
                session.publish_seek_gen(gen);
            }
        }
        self.flush_generation.fetch_add(1, Ordering::SeqCst);
        self.wait_rtrb_push_idle();
        self.acknowledge_renderer_flush();

        self.telemetry
            .post_event(EventType::Position, MapEventData { position_ms: dur });
    }

    fn dispatch_seek_to_decoder(&mut self, position_ms: i64) {
        self.seek_epoch.fetch_add(1, Ordering::AcqRel);
        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur > 0 && position_ms >= dur {
            self.complete_at_duration(dur);
            return;
        }

        // Enqueue seek before flushing renderer and wait for any in-flight `rtrb`
        // producer write to complete so stale pre-seek samples never leak into post-seek output.
        let gen = self.enqueue_seek(position_ms);
        if let Ok(sess_guard) = self.stream_session.read() {
            if let Some(ref session) = *sess_guard {
                session.publish_seek_gen(gen);
            }
        }
        self.wait_rtrb_push_idle();
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

        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();
    }

    pub fn get_buffered_range(&self, out_range: &mut MiniaudioBufferedRange) -> i32 {
        let duration = self.duration_ms.load(Ordering::Relaxed);
        if self.is_stream.load(Ordering::Relaxed) {
            if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
                let (start_ms, end_ms) = session.mapped_buffered_range(duration);
                out_range.start_ms = start_ms;
                out_range.end_ms = end_ms;
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

    pub fn get_meta_bytes_version(&self) -> u32 {
        if let Some(ref session) = *read_unpoisoned(&self.stream_session) {
            session.meta_version()
        } else {
            0
        }
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
            .unwrap_or_else(|| StreamBuffer::new_sparse(4096, None));

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

        self.seek_epoch.fetch_add(1, Ordering::AcqRel);
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

    pub fn set_pause_on_device_change(&mut self, enabled: i32) -> i32 {
        crate::map_log!(4, "set_pause_on_device_change(enabled={})", enabled != 0);
        self.pause_on_device_change
            .store(enabled != 0, Ordering::Relaxed);
        MAP_SUCCESS
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

    /// Returns the number of decoded PCM frames currently buffered in `AudioRenderer`.
    #[inline]
    pub fn buffered_audio_frames(&self) -> usize {
        let ch = (self.device_channels.load(Ordering::Relaxed) as usize).clamp(1, 8);
        let samples = self
            .renderer
            .as_ref()
            .map(|r| r.consumer.samples_available())
            .unwrap_or(0);
        samples / ch
    }

    /// Waits briefly until the background `DecoderWorker` populates an initial PCM cushion
    /// (or reaches EOF, cancellation, or timeout), avoiding cold-start dropouts when `play()` commits.
    pub fn wait_for_initial_pcm(
        &self,
        min_frames: usize,
        max_wait: std::time::Duration,
        cancel: Option<&CancelToken>,
    ) {
        let deadline = MonotonicInstant::now() + max_wait;
        while self.buffered_audio_frames() < min_frames {
            if self.decoder_eof.load(Ordering::Acquire)
                || self.track_exhausted.load(Ordering::Acquire)
                || cancel.is_some_and(|c| c.is_cancelled())
                || MonotonicInstant::now() >= deadline
            {
                break;
            }
            crate::sync::thread::sleep(std::time::Duration::from_millis(2));
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
    /// Whether Rust must request source resolution from Dart before opening.
    pub resolve_in_dart: bool,
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
    /// Returns the instantaneous `(gain_a, gain_b)` mix weights without advancing the fade frame counter.
    pub fn current_gains(&self) -> (f32, f32) {
        self.gains_step(0, false)
    }

    pub fn advance_and_get_gains(&self, frame_count: u64) -> (f32, f32) {
        self.gains_step(frame_count, true)
    }

    fn gains_step(&self, frame_count: u64, advance: bool) -> (f32, f32) {
        let cur = if advance {
            self.current_frame.fetch_add(frame_count, Ordering::Relaxed)
        } else {
            self.current_frame.load(Ordering::Relaxed)
        };
        let tot = self.total_frames.load(Ordering::Relaxed).max(1);
        let curve = self.curve.load(Ordering::Relaxed);
        let progress = (cur as f32 / tot as f32).min(1.0);
        if advance && cur + frame_count >= tot {
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
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    /// Track ID currently decoded and paused in the standby deck (`-1` if none/invalidated).
    pub standby_ready_id: Arc<AtomicI64>,
    /// Normalized source URI matching `standby_ready_id` for source-reuse invalidation.
    pub standby_ready_source: Arc<RwLock<Option<String>>>,
    /// Logically committed queue cursor used for FIFO rapid-skip serialization.
    pub planned_index: Arc<AtomicI64>,
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
            dart_resolver: None,
            standby_ready_id: Arc::new(AtomicI64::new(-1)),
            standby_ready_source: Arc::new(RwLock::new(None)),
            planned_index: Arc::new(AtomicI64::new(-1)),
            default_replay_gain: (0.0, 1.0),
            replay_gain_mode: 1,
        })
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

    pub fn open_deck_source_with_cancel(
        deck: &mut StreamingDeck,
        item: &AudioSourceCore,
        custom_factory: Option<&CustomSourceFactory>,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        Self::open_deck_with_pre_resolved(deck, item, None, custom_factory, None, cancel)
    }

    /// Opens an [`AudioSourceCore`] onto `deck`, using `pre_resolved` if supplied
    /// (static analysis), querying `dart_resolver` when `item.resolve_in_dart`
    /// is set, or opening directly via path/HTTP/`data:`/`custom:`.
    pub fn open_deck_with_pre_resolved(
        deck: &mut StreamingDeck,
        item: &AudioSourceCore,
        pre_resolved: Option<ResolvedCoreSource>,
        custom_factory: Option<&CustomSourceFactory>,
        dart_resolver: Option<&Arc<DartResolveRegistry>>,
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
        } else if let Some(resolved) = pre_resolved {
            Self::open_resolved_core_source(
                deck,
                &item.source,
                item.headers.as_deref(),
                resolved,
                custom_factory,
                dart_resolver,
                cancel,
            )
        } else if item.resolve_in_dart {
            if let Some(resolver) = dart_resolver {
                match resolver.resolve(&item.source, item.headers.as_deref(), cancel) {
                    Ok(resolved) => Self::open_resolved_core_source(
                        deck,
                        &item.source,
                        item.headers.as_deref(),
                        resolved,
                        custom_factory,
                        dart_resolver,
                        cancel,
                    ),
                    Err(failure) => {
                        if failure.code == MAP_ERROR_ABORTED || cancel.is_some_and(|c| c.is_cancelled()) {
                            deck.mark_open_error(MAP_ERROR_ABORTED)
                        } else {
                            deck.mark_open_error_with_message(failure.code, &failure.message)
                        }
                    }
                }
            } else {
                deck.mark_open_error_with_message(
                    MAP_ERROR_UNSUPPORTED,
                    &format!(
                        "Source '{}' requires asynchronous Dart resolution which is unavailable in synchronous/headless context",
                        item.source
                    ),
                )
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

    fn open_resolved_core_source(
        deck: &mut StreamingDeck,
        source_uri: &str,
        headers: Option<&[crate::api::types::RustHttpHeader]>,
        resolved: ResolvedCoreSource,
        custom_factory: Option<&CustomSourceFactory>,
        dart_resolver: Option<&Arc<DartResolveRegistry>>,
        cancel: Option<&CancelToken>,
    ) -> i32 {
        match resolved {
            ResolvedCoreSource::Path(path) => {
                let res = deck.open_source_with_cancel(&path, headers, cancel);
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    deck.mark_open_error(MAP_ERROR_ABORTED)
                } else {
                    res
                }
            }
            ResolvedCoreSource::Url(url) => {
                let res = deck.open_source_with_cancel(&url, headers, cancel);
                if cancel.is_some_and(|c| c.is_cancelled()) {
                    deck.mark_open_error(MAP_ERROR_ABORTED)
                } else {
                    res
                }
            }
            #[cfg(unix)]
            ResolvedCoreSource::Fd {
                file,
                offset,
                length,
                hint_ext,
            } => match ResolvedCoreSource::open_fd_slice(file, offset, length) {
                Ok(FdOpenOutcome::Seekable(byte_source)) => {
                    let ext = hint_ext
                        .as_deref()
                        .or_else(|| StreamClassifier::extract_extension_hint(source_uri));
                    deck.open_seekable_file_byte_source(byte_source, ext, source_uri)
                }
                Ok(FdOpenOutcome::MemoryBytes(bytes)) => {
                    let ext = hint_ext
                        .as_deref()
                        .or_else(|| StreamClassifier::extract_extension_hint(source_uri));
                    deck.open_memory_owned_with_hint(bytes, ext)
                }
                Err(msg) => deck.mark_open_error_with_message(MAP_ERROR_FILE_NOT_FOUND, &msg),
            },
            #[cfg(not(unix))]
            ResolvedCoreSource::Fd { .. } => {
                let f = ResolvedCoreSource::open_fd_slice_unsupported();
                deck.mark_open_error_with_message(f.code, &f.message)
            }
            ResolvedCoreSource::Bytes { data, hint_ext } => {
                let is_m3u8 = hint_ext.as_deref() == Some("m3u8")
                    || source_uri.to_ascii_lowercase().ends_with(".m3u8");
                if is_m3u8 && crate::hls::M3u8Parser::is_m3u8(&data) {
                    if let Some(resolver) = dart_resolver {
                        let backend = HlsFetchBackend::DartResolved {
                            resolver: resolver.clone(),
                            headers: headers.map(|h| h.to_vec()),
                        };
                        return deck.open_hls_playlist_bytes(
                            source_uri,
                            &data,
                            cancel,
                            &backend,
                            true,
                        );
                    }
                }
                let ext = hint_ext
                    .as_deref()
                    .or_else(|| StreamClassifier::extract_extension_hint(source_uri));
                deck.open_memory_owned_with_hint(data, ext)
            }
            ResolvedCoreSource::CustomStream {
                stream_id,
                total_bytes,
                hint_ext,
            } => {
                if let Some(factory) = custom_factory {
                    let is_seekable = total_bytes.is_some();
                    let (mut src, handle) = factory(stream_id, total_bytes);
                    src.set_seekable(is_seekable);
                    let ext = hint_ext
                        .as_deref()
                        .or_else(|| StreamClassifier::extract_extension_hint(source_uri));
                    deck.open_custom_source_with_hint_cancel(
                        src,
                        handle,
                        total_bytes,
                        is_seekable,
                        ext,
                        cancel,
                    )
                } else {
                    deck.mark_open_error_with_message(
                        MAP_ERROR_UNSUPPORTED,
                        "Custom stream resolution requires an active MiniaudioPlayer CustomSourceFactory",
                    )
                }
            }
            ResolvedCoreSource::Error { code, message } => {
                deck.mark_open_error_with_message(code, &message)
            }
        }
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
                    drop(q);
                    self.abort_active_crossfade();
                    self.standby_ready_id.store(-1, Ordering::Release);
                    *write_unpoisoned(&self.standby_ready_source) = None;
                    self.deck_a.stop();
                    self.deck_a.clear_queue_item_assignment();
                    self.deck_b.stop();
                    self.deck_b.clear_queue_item_assignment();
                    return Some(removed);
                }
            }
        }
        drop(q);
        self.verify_or_abort_crossfade();
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

    pub fn set_loop_mode(&mut self, mode: i32) {
        self.loop_mode.store(mode.clamp(0, 2), Ordering::Release);
        self.verify_or_abort_crossfade();
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

    pub fn pause(&mut self) {
        self.active_deck_mut().pause();
        if self.crossfade.is_active() || self.crossfade_target_id.load(Ordering::Acquire) >= 0 {
            self.standby_deck_mut().pause();
        }
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

