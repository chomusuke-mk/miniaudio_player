//! Comprehensive 28-Track HTTP Range (`206`) & Byte-Transfer Audit Test Suite.
//!
//! Verifies across every audio container/codec fixture in `example/assets/music/` (27 standalone
//! formats + unencrypted HLS VOD) that:
//! 1. Initial streaming opens issue strictly minimal HTTP `206` requests (`0` for faststart MP4/CAF,
//!    `<= 1` for tail-scanned/tail-chunk formats, `<= 6` for VBR ADTS duration sampling).
//! 2. Out-of-buffer seeks on MP4/M4A (AAC & ALAC) issue a single `206` stream reposition (no
//!    double full-tail `206`), and on-demand seeks on VBR formats (Opus, Vorbis, FLAC, WavPack,
//!    MKV/MKA, MP3, ADTS) resolve accurately within strict `206` request budgets.
//! 3. Acoustic/metadata analysis (`analyze_audio_source`) over HTTP obeys identical tight `206`
//!    budgets while preserving duration and metadata extraction.

mod common;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use common::FixtureResolver;
use miniaudio_player::api::types::{RustAnalysisConfig, RustAudioSource};
use miniaudio_player::bridge::ffi::MiniaudioBufferedRange;
use miniaudio_player::buffer::{CustomDartByteSource, CustomSourceRegistry};
use miniaudio_player::core::control_coordinator::ControlCoordinator;
use miniaudio_player::core::dual_source::{AudioSourceCore, CustomSourceFactory};
use miniaudio_player::core::engine_actor::EngineActorHandle;
use miniaudio_player::dsp::analysis::analyze_audio_source;

#[derive(Debug, Clone, Copy)]
struct AuditTrackSpec {
    rel_path: &'static str,
    format_label: &'static str,
    max_open_206: usize,
    is_hls: bool,
}

/// Canonical 28 playable tracks matching `seek_buffer_matrix_test.rs`.
const CATALOG_28: &[AuditTrackSpec] = &[
    AuditTrackSpec { rel_path: "01_Apex_Momentum.mp3", format_label: "MP3 VBR", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "02_Bailando_con_tu_recuerdo.opus", format_label: "Opus", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "03_Before_The_Dawn_cbr_noxing.mp3", format_label: "MP3 CBR", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "04_Belaya_Tishina.flac", format_label: "FLAC 24b", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "05_Burning_in_the_Electric_Light.ogg", format_label: "Vorbis", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "06_Calculated_Motion_aac.m4a", format_label: "M4A AAC", max_open_206: 0, is_hls: false },
    AuditTrackSpec { rel_path: "07_Fevered_Strings_alac.m4a", format_label: "M4A ALAC", max_open_206: 0, is_hls: false },
    AuditTrackSpec { rel_path: "08_Firelight_Promise_24bit_mono.wav", format_label: "WAV 24m", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "09_Flesh_and_Chrome.wv", format_label: "WavPack", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "10_La_cicatriz_del_andén.aac", format_label: "AAC ADTS", max_open_206: 6, is_hls: false },
    AuditTrackSpec { rel_path: "11_Mar_de_cristal.mka", format_label: "MKA FLAC", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "12_Mi_más_bonita_coincidencia_24bit_stereo.wav", format_label: "WAV 24s", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "13_Overture_for_the_Floor.webm", format_label: "WebM Opus", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "14_Painting_the_Sky.mkv", format_label: "MKV Opus", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "15_Resting_At_Your_Feet.mp2", format_label: "MP2", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "16_Ribbons_on_Anchors.oga", format_label: "OGA Vorbis", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "17_Running_To_Meet_The_Sun.wav", format_label: "WAV 16b", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "18_Running_With_Daylight.aif", format_label: "AIF", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "19_Spin_Me_In_The_Dark.rf64", format_label: "RF64", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "20_Swallowing_This_Glitter_Pill.w64", format_label: "Wave64", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "21_The_Great_Equalizer.bwf", format_label: "BWF", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "22_The_Midnight_Pursuit.rifx", format_label: "RIFX BE", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "23_Tracing_Lines.aifc", format_label: "AIFC", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "24_Tracks_Into_The_Dawn.aiff", format_label: "AIFF", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "25_Velocity_of_One.ape", format_label: "APE", max_open_206: 1, is_hls: false },
    AuditTrackSpec { rel_path: "27_¡Yo_me_opongo_.caf", format_label: "CAF", max_open_206: 0, is_hls: false },
    AuditTrackSpec { rel_path: "hls/28_Разводят_мосты.m3u8", format_label: "HLS VOD", max_open_206: 0, is_hls: true },
    AuditTrackSpec { rel_path: "29_駆け抜けて、この空を.dsf", format_label: "DSF DSD64", max_open_206: 1, is_hls: false },
];

fn percent_encode_rel(rel: &str) -> String {
    rel.split('/')
        .map(|seg| {
            let mut out = String::with_capacity(seg.len());
            for &b in seg.as_bytes() {
                if b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.') {
                    out.push(b as char);
                } else {
                    out.push_str(&format!("%{:02X}", b));
                }
            }
            out
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn decode_url_path(raw: &str) -> String {
    let stripped = raw.split('?').next().unwrap_or(raw).trim_start_matches('/');
    let bytes = stripped.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Debug, Clone, Default)]
struct PathStats {
    count_200: usize,
    count_206: usize,
    bytes_200: u64,
    bytes_206: u64,
    ranges_206: Vec<(u64, u64)>,
}

struct AuditHttpServer {
    port: u16,
    stop: Arc<AtomicBool>,
    rtt_ms: Arc<AtomicUsize>,
    bytes_per_sec: Arc<AtomicUsize>,
    generation: Arc<AtomicU64>,
    stats: Arc<Mutex<HashMap<String, PathStats>>>,
    thread: Option<JoinHandle<()>>,
}

impl AuditHttpServer {
    fn start(fixtures_dir: PathBuf) -> Self {
        let mut map: HashMap<String, Arc<[u8]>> = HashMap::new();
        for spec in CATALOG_28 {
            let full = fixtures_dir.join(spec.rel_path);
            let data = std::fs::read(&full)
                .unwrap_or_else(|e| panic!("Failed to read fixture {:?}: {}", full, e));
            map.insert(spec.rel_path.to_string(), Arc::from(data));
        }
        for seg_idx in 0..=18 {
            let seg_rel = format!("hls/28_seg_{}.ts", seg_idx);
            let full = fixtures_dir.join(&seg_rel);
            let data = std::fs::read(&full)
                .unwrap_or_else(|e| panic!("Failed to read HLS segment {:?}: {}", full, e));
            map.insert(seg_rel, Arc::from(data));
        }
        let files = Arc::new(map);

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind audit http server");
        listener.set_nonblocking(true).expect("set nonblocking");
        let port = listener.local_addr().expect("local_addr").port();
        let stop = Arc::new(AtomicBool::new(false));
        let rtt_ms = Arc::new(AtomicUsize::new(0));
        let bytes_per_sec = Arc::new(AtomicUsize::new(0));
        let generation = Arc::new(AtomicU64::new(0));
        let stats: Arc<Mutex<HashMap<String, PathStats>>> = Arc::new(Mutex::new(HashMap::new()));

        let stop_c = stop.clone();
        let rtt_c = rtt_ms.clone();
        let bps_c = bytes_per_sec.clone();
        let gen_c = generation.clone();
        let stats_c = stats.clone();

        let thread = thread::Builder::new()
            .name("test-audit-http".to_string())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::new();
                while !stop_c.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let _ = stream.set_nonblocking(false);
                            let f = files.clone();
                            let s = stop_c.clone();
                            let rtt = rtt_c.clone();
                            let bps = bps_c.clone();
                            let g = gen_c.clone();
                            let st = stats_c.clone();
                            workers.retain(|w| !w.is_finished());
                            workers.push(thread::spawn(move || {
                                Self::handle_client(stream, f, s, rtt, bps, g, st);
                            }));
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(2));
                        }
                        Err(_) => break,
                    }
                }
                for w in workers {
                    let _ = w.join();
                }
            })
            .expect("spawn audit http thread");

        Self {
            port,
            stop,
            rtt_ms,
            bytes_per_sec,
            generation,
            stats,
            thread: Some(thread),
        }
    }

    fn set_profile(&self, rtt_ms: usize, bytes_per_sec: usize) {
        self.rtt_ms.store(rtt_ms, Ordering::Release);
        self.bytes_per_sec.store(bytes_per_sec, Ordering::Release);
    }

    fn reset_stats(&self) {
        let mut guard = self.stats.lock().unwrap();
        self.generation.fetch_add(1, Ordering::AcqRel);
        guard.clear();
    }

    fn stats_for(&self, rel_path: &str) -> PathStats {
        self.stats
            .lock()
            .unwrap()
            .get(rel_path)
            .cloned()
            .unwrap_or_default()
    }

    fn hls_totals(&self) -> PathStats {
        let guard = self.stats.lock().unwrap();
        let mut agg = PathStats::default();
        for (path, st) in guard.iter() {
            if path.starts_with("hls/") {
                agg.count_200 += st.count_200;
                agg.count_206 += st.count_206;
                agg.bytes_200 += st.bytes_200;
                agg.bytes_206 += st.bytes_206;
            }
        }
        agg
    }

    fn handle_client(
        mut stream: TcpStream,
        files: Arc<HashMap<String, Arc<[u8]>>>,
        stop: Arc<AtomicBool>,
        rtt_ms: Arc<AtomicUsize>,
        bytes_per_sec: Arc<AtomicUsize>,
        generation: Arc<AtomicU64>,
        stats: Arc<Mutex<HashMap<String, PathStats>>>,
    ) {
        let Ok(cloned) = stream.try_clone() else {
            return;
        };
        let mut br = BufReader::new(cloned);
        let mut req_line = String::new();
        if br.read_line(&mut req_line).is_err() || req_line.is_empty() {
            return;
        }
        let mut parts = req_line.split_whitespace();
        let method = parts.next().unwrap_or("GET").to_ascii_uppercase();
        let raw_path = parts.next().unwrap_or("/");
        let rel_path = decode_url_path(raw_path);

        let mut range_hdr: Option<String> = None;
        loop {
            let mut h = String::new();
            if br.read_line(&mut h).is_err() || h.trim().is_empty() {
                break;
            }
            let low = h.to_ascii_lowercase();
            if let Some(rest) = low.strip_prefix("range:") {
                range_hdr = Some(rest.trim().to_string());
            }
        }

        let req_gen = generation.load(Ordering::Acquire);
        let rtt = rtt_ms.load(Ordering::Acquire);
        if rtt > 0 {
            thread::sleep(Duration::from_millis(rtt as u64));
        }
        if stop.load(Ordering::Acquire) {
            return;
        }

        let Some(data) = files.get(&rel_path) else {
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            return;
        };

        if method == "HEAD" {
            let hdr = format!(
                "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                data.len()
            );
            let _ = stream.write_all(hdr.as_bytes());
            return;
        }

        let limit_bps = bytes_per_sec.load(Ordering::Acquire);
        if let Some(r) = range_hdr.and_then(|s| s.strip_prefix("bytes=").map(str::to_string)) {
            let (a, b) = r.split_once('-').unwrap_or(("0", ""));
            let start: usize = a.parse().unwrap_or(0);
            let end: usize = if b.is_empty() {
                data.len().saturating_sub(1)
            } else {
                b.parse()
                    .unwrap_or(data.len().saturating_sub(1))
                    .min(data.len().saturating_sub(1))
            };
            if start <= end && start < data.len() {
                let slice = &data[start..=end];
                let hdr = format!(
                    "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                    slice.len(),
                    start,
                    end,
                    data.len()
                );
                if stream.write_all(hdr.as_bytes()).is_err() {
                    return;
                }
                {
                    let mut guard = stats.lock().unwrap();
                    if generation.load(Ordering::Acquire) == req_gen {
                        let entry = guard.entry(rel_path.clone()).or_default();
                        entry.count_206 += 1;
                        entry.ranges_206.push((start as u64, end as u64));
                    }
                }
                Self::write_throttled(
                    &mut stream,
                    slice,
                    limit_bps,
                    &stop,
                    &generation,
                    req_gen,
                    &stats,
                    &rel_path,
                    true,
                );
                return;
            }
        }

        let hdr = format!(
            "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            data.len()
        );
        if stream.write_all(hdr.as_bytes()).is_err() {
            return;
        }
        {
            let mut guard = stats.lock().unwrap();
            if generation.load(Ordering::Acquire) == req_gen {
                let entry = guard.entry(rel_path.clone()).or_default();
                entry.count_200 += 1;
            }
        }
        Self::write_throttled(
            &mut stream,
            data,
            limit_bps,
            &stop,
            &generation,
            req_gen,
            &stats,
            &rel_path,
            false,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn write_throttled(
        stream: &mut TcpStream,
        data: &[u8],
        bytes_per_sec: usize,
        stop: &AtomicBool,
        generation: &AtomicU64,
        req_gen: u64,
        stats: &Mutex<HashMap<String, PathStats>>,
        rel_path: &str,
        is_partial: bool,
    ) {
        let record_bytes = |n: usize| {
            if n == 0 {
                return;
            }
            let mut guard = stats.lock().unwrap();
            if generation.load(Ordering::Acquire) != req_gen {
                return;
            }
            let entry = guard.entry(rel_path.to_string()).or_default();
            if is_partial {
                entry.bytes_206 += n as u64;
            } else {
                entry.bytes_200 += n as u64;
            }
        };

        if bytes_per_sec == 0 {
            if stream.write_all(data).is_ok() {
                record_bytes(data.len());
            }
            return;
        }
        let chunk_sz = 16 * 1024;
        let sleep_us = ((chunk_sz as u128 * 1_000_000) / bytes_per_sec as u128).max(1000) as u64;
        let mut sent = 0usize;
        while sent < data.len() && !stop.load(Ordering::Acquire) {
            let end = (sent + chunk_sz).min(data.len());
            if stream.write_all(&data[sent..end]).is_err() {
                return;
            }
            let chunk_written = end - sent;
            sent = end;
            record_bytes(chunk_written);
            if sent < data.len() && sent > 48 * 1024 {
                thread::sleep(Duration::from_micros(sleep_us));
            }
        }
    }
}

impl Drop for AuditHttpServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(jh) = self.thread.take() {
            let _ = jh.join();
        }
    }
}

struct PlayerHarness {
    engine: EngineActorHandle,
    coordinator: ControlCoordinator,
    custom_registry: CustomSourceRegistry,
}

impl PlayerHarness {
    fn spawn() -> Self {
        let trigger = Arc::new((Mutex::new(false), Condvar::new()));
        let (engine, _notify_rx, hint_rx) =
            EngineActorHandle::spawn(48_000, 2, 512, 8, None, Some(trigger), false, 0, Vec::new())
                .expect("spawn EngineActorHandle");

        let custom_registry = CustomSourceRegistry::new();
        let coordinator = ControlCoordinator::spawn(
            engine.clone(),
            custom_registry.clone(),
            hint_rx,
            Arc::new(|_snap| {}),
        );

        Self {
            engine,
            coordinator,
            custom_registry,
        }
    }

    fn custom_factory(&self) -> CustomSourceFactory {
        let reg = self.custom_registry.clone();
        Arc::new(move |stream_id, total_size| {
            CustomDartByteSource::with_registry(
                stream_id,
                total_size,
                true,
                Arc::new(|_| {}),
                Some(reg.clone()),
            )
        })
    }

    fn active_deck_status(&self) -> (i64, i64, bool, i64, i64, bool) {
        self.engine
            .exec(|ply| {
                let d = ply.music_manager.active_deck_ref();
                let mut br = MiniaudioBufferedRange::default();
                let _ = d.get_buffered_range(&mut br);
                (
                    d.position_ms.load(Ordering::Acquire),
                    d.duration_ms.load(Ordering::Acquire),
                    d.seek_request_ms.load(Ordering::Acquire) >= 0,
                    br.start_ms,
                    br.end_ms,
                    d.is_buffering.load(Ordering::Acquire) || br.is_buffering != 0,
                )
            })
            .expect("active_deck_status")
    }

    fn wait_open_ready(&self, timeout: Duration) -> (i64, i64, i64) {
        let start = Instant::now();
        while start.elapsed() < timeout {
            let (_, dur, _, b_start, b_end, _) = self.active_deck_status();
            if dur > 0 && b_end > 1_000 {
                return (dur, b_start, b_end);
            }
            thread::sleep(Duration::from_millis(15));
        }
        let (_, dur, _, b_start, b_end, _) = self.active_deck_status();
        panic!(
            "Timed out waiting for open ready (dur={}, range=[{}..{}])",
            dur, b_start, b_end
        );
    }

    fn wait_seek_and_advance(&self, target_ms: i64, dur_ms: i64, timeout: Duration) {
        let start = Instant::now();
        while start.elapsed() < timeout {
            let (_, _, seek_pending, b_start, b_end, is_buf) = self.active_deck_status();
            let ui_buf = self.engine.snapshots().is_buffering();
            let want_end = (target_ms + 2_000).min(dur_ms.saturating_sub(250));
            if !seek_pending
                && !is_buf
                && !ui_buf
                && b_end > b_start
                && (b_end >= want_end || b_end >= dur_ms - 500)
            {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let (pos, _, seek_pending, b_start, b_end, is_buf) = self.active_deck_status();
        panic!(
            "Timed out waiting for seek({}) ready (pos={}, sp={}, range=[{}..{}], is_buf={})",
            target_ms, pos, seek_pending, b_start, b_end, is_buf
        );
    }
}

impl Drop for PlayerHarness {
    fn drop(&mut self) {
        self.custom_registry.abort_all();
        self.coordinator.shutdown();
        self.engine.shutdown();
    }
}

#[test]
fn test_all_28_tracks_http_open_request_budget() {
    let music_dir = FixtureResolver::fixtures_dir();
    let server = AuditHttpServer::start(music_dir);
    let mut violations: Vec<String> = Vec::new();

    eprintln!(
        "\n=== HTTP OPEN AUDIT ACROSS ALL 28 TRACKS (playback open) ===\n\
         {:<4} {:<11} {:<45} {:>4} {:>4} {:>10} {:>10}",
        "#", "Format", "Track", "200s", "206s", "200_Bytes", "206_Bytes"
    );

    for (idx, spec) in CATALOG_28.iter().enumerate() {
        server.reset_stats();
        server.set_profile(0, 0);

        let url = format!(
            "http://127.0.0.1:{}/{}",
            server.port,
            percent_encode_rel(spec.rel_path)
        );
        {
            let harness = PlayerHarness::spawn();
            harness
                .coordinator
                .set_queue(
                    vec![AudioSourceCore {
                        id: 1,
                        source: url,
                        headers: None,
                        data_bytes: None,
                        replay_gain_db: None,
                        replay_peak: None,
                        resolve_in_dart: false,
                    }],
                    harness.custom_factory(),
                )
                .expect("set_queue");
            harness
                .coordinator
                .play(Some(1), Some(0), None, None, true)
                .expect("play");
            let (dur, b_start, b_end) = harness.wait_open_ready(Duration::from_secs(12));
            assert!(dur > 0 && b_end > b_start);
            thread::sleep(Duration::from_millis(120));
            let _ = harness.coordinator.stop();
        }
        // Allow detached Range socket close to record if any completed just before stop.
        thread::sleep(Duration::from_millis(25));

        let st = if spec.is_hls {
            server.hls_totals()
        } else {
            server.stats_for(spec.rel_path)
        };
        eprintln!(
            "{:<4} {:<11} {:<45} {:>4} {:>4} {:>10} {:>10}",
            idx + 1,
            spec.format_label,
            spec.rel_path,
            st.count_200,
            st.count_206,
            st.bytes_200,
            st.bytes_206
        );

        if st.count_206 > spec.max_open_206 {
            violations.push(format!(
                "{} ({}): open 206 count {} > max {} (ranges={:?})",
                spec.rel_path, spec.format_label, st.count_206, spec.max_open_206, st.ranges_206
            ));
        }
        if spec.is_hls && st.count_200 > 8 {
            violations.push(format!(
                "{} (HLS VOD): initial 200 count {} > 8",
                spec.rel_path, st.count_200
            ));
        }
    }

    assert!(
        violations.is_empty(),
        "HTTP open request budget exceeded:\n{}",
        violations.join("\n")
    );
}

#[test]
fn test_out_of_buffer_seek_http_requests_across_formats() {
    let music_dir = FixtureResolver::fixtures_dir();
    let server = AuditHttpServer::start(music_dir.clone());

    struct SeekAuditCase {
        rel_path: &'static str,
        label: &'static str,
        max_seek_206: usize,
        exact_seek_206: Option<usize>,
    }

    let cases = [
        SeekAuditCase {
            rel_path: "06_Calculated_Motion_aac.m4a",
            label: "M4A AAC",
            max_seek_206: 1,
            exact_seek_206: Some(1),
        },
        SeekAuditCase {
            rel_path: "07_Fevered_Strings_alac.m4a",
            label: "M4A ALAC",
            max_seek_206: 1,
            exact_seek_206: Some(1),
        },
        SeekAuditCase {
            rel_path: "01_Apex_Momentum.mp3",
            label: "MP3 VBR",
            max_seek_206: 2,
            exact_seek_206: None,
        },
        SeekAuditCase {
            rel_path: "02_Bailando_con_tu_recuerdo.opus",
            label: "Opus",
            max_seek_206: 4,
            exact_seek_206: None,
        },
        SeekAuditCase {
            rel_path: "04_Belaya_Tishina.flac",
            label: "FLAC 24b",
            max_seek_206: 6,
            exact_seek_206: None,
        },
        SeekAuditCase {
            rel_path: "05_Burning_in_the_Electric_Light.ogg",
            label: "Vorbis",
            max_seek_206: 4,
            exact_seek_206: None,
        },
        SeekAuditCase {
            rel_path: "09_Flesh_and_Chrome.wv",
            label: "WavPack",
            max_seek_206: 6,
            exact_seek_206: None,
        },
        SeekAuditCase {
            rel_path: "10_La_cicatriz_del_andén.aac",
            label: "AAC ADTS",
            max_seek_206: 2,
            exact_seek_206: None,
        },
        SeekAuditCase {
            rel_path: "11_Mar_de_cristal.mka",
            label: "MKA FLAC",
            max_seek_206: 2,
            exact_seek_206: None,
        },
    ];

    eprintln!("\n=== OUT-OF-BUFFER 50% SEEK HTTP 206 AUDIT ===");
    let mut violations: Vec<String> = Vec::new();

    for case in cases {
        let size_bytes = std::fs::metadata(music_dir.join(case.rel_path))
            .map(|m| m.len())
            .unwrap_or(0);
        let bps = if size_bytes > 8 * 1024 * 1024 {
            500 * 1024
        } else {
            140 * 1024
        };
        server.reset_stats();
        server.set_profile(25, bps);

        let url = format!(
            "http://127.0.0.1:{}/{}",
            server.port,
            percent_encode_rel(case.rel_path)
        );
        {
            let harness = PlayerHarness::spawn();
            harness
                .coordinator
                .set_queue(
                    vec![AudioSourceCore {
                        id: 1,
                        source: url,
                        headers: None,
                        data_bytes: None,
                        replay_gain_db: None,
                        replay_peak: None,
                        resolve_in_dart: false,
                    }],
                    harness.custom_factory(),
                )
                .expect("set_queue");
            harness
                .coordinator
                .play(Some(1), Some(0), None, None, false)
                .expect("play");
            let (dur, _, b_end) = harness.wait_open_ready(Duration::from_secs(12));
            let t_seek = if b_end < (dur * 50) / 100 {
                (dur * 55) / 100
            } else {
                (dur * 80) / 100
            };

            server.reset_stats();
            harness.coordinator.seek(t_seek).expect("seek");
            harness.wait_seek_and_advance(t_seek, dur, Duration::from_secs(12));
            // Let post-seek playback pull frames cleanly to expose any double-206 reopen.
            thread::sleep(Duration::from_millis(350));
            let pos_now = harness.active_deck_status().0;
            assert!(
                (pos_now - t_seek).abs() < 4_000,
                "{}: post-seek position {}ms drifted far from target {}ms",
                case.rel_path,
                pos_now,
                t_seek
            );
            let _ = harness.coordinator.stop();
        }
        thread::sleep(Duration::from_millis(25));

        let st = server.stats_for(case.rel_path);
        eprintln!(
            "  {:<10} {:<42} seek_206s={} bytes_206={} ranges={:?}",
            case.label, case.rel_path, st.count_206, st.bytes_206, st.ranges_206
        );

        if let Some(exact) = case.exact_seek_206 {
            if st.count_206 != exact {
                violations.push(format!(
                    "{} ({}): expected exact {} 206 on seek, got {} (ranges={:?})",
                    case.rel_path, case.label, exact, st.count_206, st.ranges_206
                ));
            }
        } else if st.count_206 > case.max_seek_206 {
            violations.push(format!(
                "{} ({}): seek 206 count {} > max {} (ranges={:?})",
                case.rel_path, case.label, st.count_206, case.max_seek_206, st.ranges_206
            ));
        }
    }

    assert!(
        violations.is_empty(),
        "HTTP out-of-buffer seek budget exceeded:\n{}",
        violations.join("\n")
    );
}

#[test]
fn test_analysis_http_request_budget_and_metadata_integrity() {
    let music_dir = FixtureResolver::fixtures_dir();
    let server = AuditHttpServer::start(music_dir);
    server.set_profile(0, 0);

    let targets: &[(&str, &str, usize, bool)] = &[
        ("01_Apex_Momentum.mp3", "MP3 VBR", 1, false),
        ("02_Bailando_con_tu_recuerdo.opus", "Opus", 1, true),
        ("04_Belaya_Tishina.flac", "FLAC 24b", 1, false),
        ("05_Burning_in_the_Electric_Light.ogg", "Vorbis", 1, false),
        ("06_Calculated_Motion_aac.m4a", "M4A AAC", 0, true),
        ("09_Flesh_and_Chrome.wv", "WavPack", 1, false),
        ("10_La_cicatriz_del_andén.aac", "AAC ADTS", 6, false),
        ("11_Mar_de_cristal.mka", "MKA FLAC", 1, false),
        ("17_Running_To_Meet_The_Sun.wav", "WAV 16b", 1, false),
        ("18_Running_With_Daylight.aif", "AIF", 1, false),
        ("25_Velocity_of_One.ape", "APE", 1, false),
        ("27_¡Yo_me_opongo_.caf", "CAF", 0, false),
        ("29_駆け抜けて、この空を.dsf", "DSF", 1, false),
    ];

    eprintln!("\n=== ANALYSIS HTTP 206 BUDGET AUDIT ===");
    let mut violations: Vec<String> = Vec::new();

    for &(rel_path, label, max_206, decode_acoustic) in targets {
        server.reset_stats();
        let url = format!(
            "http://127.0.0.1:{}/{}",
            server.port,
            percent_encode_rel(rel_path)
        );
        let src = RustAudioSource {
            id: 1,
            source: url,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        };
        let cfg = RustAnalysisConfig {
            replay_gain: decode_acoustic,
            waveform: decode_acoustic,
            chromaprint: false,
            metadata: true,
            waveform_points: 64,
            target_lufs: -18.0,
            max_duration_ms: if decode_acoustic { Some(5_000) } else { None },
        };
        let res = analyze_audio_source(src.into(), cfg)
            .unwrap_or_else(|e| panic!("analyze_audio_source failed for {}: {}", rel_path, e));
        assert!(
            res.audio_info.duration_ms.unwrap_or(0) > 0,
            "{}: expected duration_ms > 0",
            rel_path
        );
        assert!(res.has_metadata, "{}: expected metadata present", rel_path);

        let st = server.stats_for(rel_path);
        eprintln!(
            "  {:<10} {:<38} acoustic={} 200s={} 206s={} bytes_206={}",
            label, rel_path, decode_acoustic, st.count_200, st.count_206, st.bytes_206
        );
        if st.count_206 > max_206 {
            violations.push(format!(
                "{} ({}): analysis 206 count {} > max {} (ranges={:?})",
                rel_path, label, st.count_206, max_206, st.ranges_206
            ));
        }
    }

    assert!(
        violations.is_empty(),
        "HTTP analysis request budget exceeded:\n{}",
        violations.join("\n")
    );
}
