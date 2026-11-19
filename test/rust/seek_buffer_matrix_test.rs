//! Comprehensive 28-track x 3-mode (`Local`, `RemoteFull`, `RemoteLimited`)
//! Seek, Buffered-Range Alignment, Anti-Buffering, and Anti-Track-Switch Matrix Test Suite.
//!
//! Also includes the dedicated regression test for:
//! `02_Bailando_con_tu_recuerdo.opus`: seek(23_000ms) must anchor the buffer cleanly
//! at the seek point (NOT displaced back to 20.4s) and seeking to 96% of the loaded
//! buffer must NOT trigger buffering.

mod common;

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use common::FixtureResolver;
use miniaudio_player::bridge::ffi::MiniaudioBufferedRange;
use miniaudio_player::buffer::{CustomDartByteSource, CustomSourceRegistry};
use miniaudio_player::core::control_coordinator::ControlCoordinator;
use miniaudio_player::core::dual_source::{AudioSourceCore, CustomSourceFactory};
use miniaudio_player::core::engine_actor::EngineActorHandle;
use miniaudio_player::core::PlaybackState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NetworkMode {
    Local,
    RemoteFull,
    RemoteLimited,
}

impl NetworkMode {
    fn label(self) -> &'static str {
        match self {
            Self::Local => "Local",
            Self::RemoteFull => "Remoto Full",
            Self::RemoteLimited => "Remoto Limitado",
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct TrackSpec {
    rel_path: &'static str,
    _format_label: &'static str,
    /// Maximum acceptable backward offset `target_seek_ms - buf.start_ms` when
    /// a remote seek re-anchors the circular buffer at `target_seek_ms`.
    seek_anchor_back_tol_ms: i64,
    /// Step 3/4b seeks to 96% of `[buf.start_ms, buf.end_ms]`.
    is_hls: bool,
}

/// Canonical 28 playable tracks matching `example/lib/models/mock_data.dart`
/// (all 27 standalone audio files plus unencrypted HLS #28; #26 is AES-128 encrypted and excluded).
const CATALOG_28: &[TrackSpec] = &[
    TrackSpec { rel_path: "01_Apex_Momentum.mp3", _format_label: "MP3 VBR", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "02_Bailando_con_tu_recuerdo.opus", _format_label: "Opus", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "03_Before_The_Dawn_cbr_noxing.mp3", _format_label: "MP3 CBR", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "04_Belaya_Tishina.flac", _format_label: "FLAC 24b", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "05_Burning_in_the_Electric_Light.ogg", _format_label: "Vorbis", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "06_Calculated_Motion_aac.m4a", _format_label: "M4A AAC", seek_anchor_back_tol_ms: 2000, is_hls: false },
    TrackSpec { rel_path: "07_Fevered_Strings_alac.m4a", _format_label: "M4A ALAC", seek_anchor_back_tol_ms: 2000, is_hls: false },
    TrackSpec { rel_path: "08_Firelight_Promise_24bit_mono.wav", _format_label: "WAV 24m", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "09_Flesh_and_Chrome.wv", _format_label: "WavPack", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "10_La_cicatriz_del_andén.aac", _format_label: "AAC ADTS", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "11_Mar_de_cristal.mka", _format_label: "MKA FLAC", seek_anchor_back_tol_ms: 6000, is_hls: false },
    TrackSpec { rel_path: "12_Mi_más_bonita_coincidencia_24bit_stereo.wav", _format_label: "WAV 24s", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "13_Overture_for_the_Floor.webm", _format_label: "WebM Opus", seek_anchor_back_tol_ms: 6000, is_hls: false },
    TrackSpec { rel_path: "14_Painting_the_Sky.mkv", _format_label: "MKV Opus", seek_anchor_back_tol_ms: 6000, is_hls: false },
    TrackSpec { rel_path: "15_Resting_At_Your_Feet.mp2", _format_label: "MP2", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "16_Ribbons_on_Anchors.oga", _format_label: "OGA Vorbis", seek_anchor_back_tol_ms: 1500, is_hls: false },
    TrackSpec { rel_path: "17_Running_To_Meet_The_Sun.wav", _format_label: "WAV 16b", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "18_Running_With_Daylight.aif", _format_label: "AIF", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "19_Spin_Me_In_The_Dark.rf64", _format_label: "RF64", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "20_Swallowing_This_Glitter_Pill.w64", _format_label: "Wave64", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "21_The_Great_Equalizer.bwf", _format_label: "BWF", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "22_The_Midnight_Pursuit.rifx", _format_label: "RIFX BE", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "23_Tracing_Lines.aifc", _format_label: "AIFC", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "24_Tracks_Into_The_Dawn.aiff", _format_label: "AIFF", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "25_Velocity_of_One.ape", _format_label: "APE", seek_anchor_back_tol_ms: 2500, is_hls: false },
    TrackSpec { rel_path: "27_¡Yo_me_opongo_.caf", _format_label: "CAF", seek_anchor_back_tol_ms: 800, is_hls: false },
    TrackSpec { rel_path: "hls/28_Разводят_мосты.m3u8", _format_label: "HLS VOD", seek_anchor_back_tol_ms: 11000, is_hls: true },
    TrackSpec { rel_path: "29_駆け抜けて、この空を.dsf", _format_label: "DSF DSD64", seek_anchor_back_tol_ms: 800, is_hls: false },
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

struct MultiFileHttpServer {
    port: u16,
    stop: Arc<AtomicBool>,
    rtt_ms: Arc<AtomicUsize>,
    bytes_per_sec: Arc<AtomicUsize>,
    range_requests: Arc<AtomicUsize>,
    thread: Option<JoinHandle<()>>,
}

impl MultiFileHttpServer {
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

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind http fixture server");
        listener.set_nonblocking(true).expect("set nonblocking");
        let port = listener.local_addr().expect("local_addr").port();
        let stop = Arc::new(AtomicBool::new(false));
        let rtt_ms = Arc::new(AtomicUsize::new(0));
        let bytes_per_sec = Arc::new(AtomicUsize::new(0));
        let range_requests = Arc::new(AtomicUsize::new(0));

        let stop_c = stop.clone();
        let rtt_c = rtt_ms.clone();
        let bps_c = bytes_per_sec.clone();
        let rr_c = range_requests.clone();

        let thread = thread::Builder::new()
            .name("test-matrix-http".to_string())
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
                            let rr = rr_c.clone();
                            workers.retain(|w| !w.is_finished());
                            workers.push(thread::spawn(move || {
                                Self::handle_client(stream, f, s, rtt, bps, rr);
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
            .expect("spawn http thread");

        Self {
            port,
            stop,
            rtt_ms,
            bytes_per_sec,
            range_requests,
            thread: Some(thread),
        }
    }

    fn set_profile(&self, rtt_ms: usize, bytes_per_sec: usize) {
        self.rtt_ms.store(rtt_ms, Ordering::Release);
        self.bytes_per_sec.store(bytes_per_sec, Ordering::Release);
    }

    fn reset_range_requests(&self) {
        self.range_requests.store(0, Ordering::Release);
    }

    fn handle_client(
        mut stream: TcpStream,
        files: Arc<HashMap<String, Arc<[u8]>>>,
        stop: Arc<AtomicBool>,
        rtt_ms: Arc<AtomicUsize>,
        bytes_per_sec: Arc<AtomicUsize>,
        range_requests: Arc<AtomicUsize>,
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
            range_requests.fetch_add(1, Ordering::AcqRel);
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
                Self::write_throttled(&mut stream, slice, limit_bps, &stop);
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
        Self::write_throttled(&mut stream, data, limit_bps, &stop);
    }

    fn write_throttled(
        stream: &mut TcpStream,
        data: &[u8],
        bytes_per_sec: usize,
        stop: &AtomicBool,
    ) {
        if bytes_per_sec == 0 {
            let _ = stream.write_all(data);
            return;
        }
        // Write 16 KB chunks paced to `bytes_per_sec` after sending an initial 48 KB fast burst
        // so opening headers + first audio frames load quickly while the tail stays streaming.
        let chunk_sz = 16 * 1024;
        let sleep_us = ((chunk_sz as u128 * 1_000_000) / bytes_per_sec as u128).max(1000) as u64;
        let mut sent = 0usize;
        while sent < data.len() && !stop.load(Ordering::Acquire) {
            let end = (sent + chunk_sz).min(data.len());
            if stream.write_all(&data[sent..end]).is_err() {
                return;
            }
            sent = end;
            if sent < data.len() && sent > 48 * 1024 {
                thread::sleep(Duration::from_micros(sleep_us));
            }
        }
    }
}

impl Drop for MultiFileHttpServer {
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
        let (engine, _notify_rx, hint_rx) = EngineActorHandle::spawn(
            48_000,
            2,
            512,
            8,
            None,
            Some(trigger),
            false,
            0,
            Vec::new(),
        )
        .expect("Failed to spawn EngineActorHandle");

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

    fn active_deck_status(&self) -> (i64, i64, bool, i64, i64, bool, u64, i64, bool) {
        self.engine
            .exec(|ply| {
                let d = ply.music_manager.active_deck_ref();
                let mut br = MiniaudioBufferedRange::default();
                let _ = d.get_buffered_range(&mut br);
                let flush_seq = d
                    .stream_session
                    .read()
                    .ok()
                    .and_then(|g| g.as_ref().map(|s| s.flush_seq()))
                    .unwrap_or(0);
                (
                    d.position_ms.load(Ordering::Acquire),
                    d.duration_ms.load(Ordering::Acquire),
                    d.seek_request_ms.load(Ordering::Acquire) >= 0,
                    br.start_ms,
                    br.end_ms,
                    d.is_buffering.load(Ordering::Acquire) || br.is_buffering != 0,
                    flush_seq,
                    ply.music_manager.current_index(),
                    ply.music_manager.inner.crossfade.is_active(),
                )
            })
            .expect("engine exec active_deck_status failed")
    }

    fn wait_seek_settled(&self, timeout: Duration) -> Result<(), String> {
        let start = Instant::now();
        while start.elapsed() < timeout {
            let (_, _, seek_pending, _, _, _, _, _, _) = self.active_deck_status();
            if !seek_pending {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(8));
        }
        Err("Timeout esperando seek_request_ms < 0".to_string())
    }

    /// Waits for `duration_ms` watching `EngineUiSnapshots::is_buffering` every 5 ms so even
    /// brief buffering glitches are caught immediately.
    fn watch_playback(&self, duration: Duration) -> (bool, i64, i64, bool) {
        let start = Instant::now();
        let mut saw_buffering = self.engine.snapshots().is_buffering();
        while start.elapsed() < duration {
            if self.engine.snapshots().is_buffering() {
                saw_buffering = true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        let (pos, _, _, _, _, buf_flag, _, idx, xf) = self.active_deck_status();
        if buf_flag {
            saw_buffering = true;
        }
        (saw_buffering, pos, idx, xf)
    }

    /// Waits until `buffered_range` holds at least `min_span_ms` above `target_ms` (or reaches near `dur`)
    /// and buffering recovery has fully settled.
    fn wait_buffer_ready(
        &self,
        target_ms: i64,
        min_ahead_ms: i64,
        dur_ms: i64,
        timeout: Duration,
    ) -> Result<(i64, i64), String> {
        let start = Instant::now();
        while start.elapsed() < timeout {
            let (_, _, seek_pending, b_start, b_end, is_buf, _, _, _) = self.active_deck_status();
            let ui_buf = self.engine.snapshots().is_buffering();
            let want_end = (target_ms + min_ahead_ms).min(dur_ms.saturating_sub(250));
            if !seek_pending
                && !is_buf
                && !ui_buf
                && b_end > b_start
                && (b_end >= want_end || b_end >= dur_ms - 500)
            {
                return Ok((b_start, b_end));
            }
            thread::sleep(Duration::from_millis(20));
        }
        let (_, _, seek_pending, b_start, b_end, is_buf, _, _, _) = self.active_deck_status();
        Err(format!(
            "Timeout esperando buffer desde {}ms (seek_pending={}, range=[{}..{}], is_buf={})",
            target_ms, seek_pending, b_start, b_end, is_buf
        ))
    }
}

impl Drop for PlayerHarness {
    fn drop(&mut self) {
        self.custom_registry.abort_all();
        self.coordinator.shutdown();
        self.engine.shutdown();
    }
}

fn validate_anchored_buffer(
    step_label: &str,
    target_ms: i64,
    b_start: i64,
    b_end: i64,
    dur_ms: i64,
    tol_back_ms: i64,
    is_streaming: bool,
) -> Result<(), String> {
    if b_end <= b_start {
        return Err(format!(
            "{}: rango buffer vacio [{}..{}] para seek {}ms",
            step_label, b_start, b_end, target_ms
        ));
    }
    if b_start > target_ms + 300 {
        return Err(format!(
            "{}: buf.start={}ms adelanta el punto seek {}ms",
            step_label, b_start, target_ms
        ));
    }
    if b_end < target_ms.min(dur_ms - 500) {
        return Err(format!(
            "{}: buf.end={}ms menor que punto seek {}ms (dur={})",
            step_label, b_end, target_ms, dur_ms
        ));
    }
    if is_streaming && b_start > 500 {
        // Buffer re-anclado: debe arrancar pegado al seek y NUNCA desplazado varios segundos atras.
        let back_diff = target_ms - b_start;
        if back_diff > tol_back_ms {
            return Err(format!(
                "{}: buf.start displaced ({}ms para seek {}ms, delta={}ms > tol={}ms)",
                step_label, b_start, target_ms, back_diff, tol_back_ms
            ));
        }
    }
    Ok(())
}

fn run_five_step_chain(
    spec: &TrackSpec,
    mode: NetworkMode,
    server: &MultiFileHttpServer,
) -> Result<String, String> {
    let music_dir = FixtureResolver::fixtures_dir();
    let local_second = music_dir.join("17_Running_To_Meet_The_Sun.wav");
    let primary_uri = match mode {
        NetworkMode::Local => music_dir.join(spec.rel_path).to_string_lossy().into_owned(),
        NetworkMode::RemoteFull | NetworkMode::RemoteLimited => {
            format!("http://127.0.0.1:{}/{}", server.port, percent_encode_rel(spec.rel_path))
        }
    };
    let second_uri = match mode {
        NetworkMode::Local => local_second.to_string_lossy().into_owned(),
        NetworkMode::RemoteFull | NetworkMode::RemoteLimited => {
            format!("http://127.0.0.1:{}/17_Running_To_Meet_The_Sun.wav", server.port)
        }
    };

    if mode == NetworkMode::RemoteLimited {
        let size_bytes = std::fs::metadata(music_dir.join(spec.rel_path))
            .map(|m| m.len())
            .unwrap_or(0);
        // Large uncompressed/lossless files (> 8 MB, up to ~2.8 Mbps DSF/24b) get ~600 KB/s;
        // lossy / compressed files <= 8 MB get ~160 KB/s so the buffer genuinely streams partially.
        let bps = if size_bytes > 8 * 1024 * 1024 {
            600 * 1024
        } else {
            160 * 1024
        };
        server.set_profile(35, bps);
    } else {
        server.set_profile(0, 0);
    }

    let harness = PlayerHarness::spawn();
    harness
        .coordinator
        .set_queue(
            vec![
                AudioSourceCore {
                    id: 1,
                    source: primary_uri,
                    headers: None,
                    data_bytes: None,
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
                AudioSourceCore {
                    id: 2,
                    source: second_uri,
                    headers: None,
                    data_bytes: None,
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
            ],
            harness.custom_factory(),
        )
        .map_err(|e| format!("set_queue failed: {}", e))?;

    // STEP 1: Reproducir pista y validar que cargue el buffer desde 0:00.
    harness
        .coordinator
        .play(Some(1), Some(0), None, None, false)
        .map_err(|e| format!("Step 1 play failed: {}", e))?;

    let open_start = Instant::now();
    let mut dur_ms = 0i64;
    while open_start.elapsed() < Duration::from_secs(12) {
        let (_, dur, _, _, b_end, _, _, _, _) = harness.active_deck_status();
        if dur > 0 && b_end > 500 {
            dur_ms = dur;
            break;
        }
        thread::sleep(Duration::from_millis(15));
    }
    if dur_ms <= 0 {
        return Err("Step 1: track never loaded duration/buffer > 0".to_string());
    }
    let is_streaming = mode != NetworkMode::Local && !(mode == NetworkMode::Local && spec.is_hls);
    let (s1_start, s1_end) = harness.wait_buffer_ready(0, 2500, dur_ms, Duration::from_secs(10))?;
    if s1_start > 500 {
        return Err(format!(
            "Step 1: buffer no inicio en 0:00 (start={}ms, end={}ms)",
            s1_start, s1_end
        ));
    }
    let (_, _, _, _, _, _, _, idx1, _) = harness.active_deck_status();
    if idx1 != 0 {
        return Err(format!("Step 1: track index cambiado a {}", idx1));
    }

    // STEP 2: Seek al 75% de la pista y validar carga del buffer desde el punto de seek.
    let t75 = (dur_ms * 75) / 100;
    harness
        .coordinator
        .seek(t75)
        .map_err(|e| format!("Step 2 seek(75%) failed: {}", e))?;
    harness.wait_seek_settled(Duration::from_secs(12))?;
    let (s2_start, s2_end) =
        harness.wait_buffer_ready(t75, 2500, dur_ms, Duration::from_secs(12))?;
    validate_anchored_buffer(
        "Step 2 (seek 75%)",
        t75,
        s2_start,
        s2_end,
        dur_ms,
        spec.seek_anchor_back_tol_ms,
        is_streaming,
    )?;

    // STEP 3: Seek al 96% del rango del buffer cargado y validar que NO haga buffering.
    let span2 = (s2_end - s2_start).max(1);
    let t96_1 = (s2_start + (span2 * 96) / 100).min(dur_ms.saturating_sub(1500));
    let (_, _, _, _, _, _, flush_before_s3, _, _) = harness.active_deck_status();
    server.reset_range_requests();
    harness
        .coordinator
        .seek(t96_1)
        .map_err(|e| format!("Step 3 seek(96% buf) failed: {}", e))?;
    // Watch buffering WHILE seek settles and for 350ms of post-seek playback.
    let mut saw_buf_s3 = false;
    let s3_wait = Instant::now();
    let mut saw_buf_during_seek_s3 = false;
    loop {
        if harness.engine.snapshots().is_buffering() {
            saw_buf_during_seek_s3 = true;
            saw_buf_s3 = true;
        }
        let (_, _, sp, _, _, _, _, _, _) = harness.active_deck_status();
        if !sp {
            break;
        }
        if s3_wait.elapsed() > Duration::from_secs(10) {
            return Err("Step 3: timeout settling seek(96% buf)".to_string());
        }
        thread::sleep(Duration::from_millis(5));
    }
    let (watch_buf_s3, pos_s3, idx_s3, _) = harness.watch_playback(Duration::from_millis(350));
    saw_buf_s3 |= watch_buf_s3;
    let (_, _, _, s3_now_s, s3_now_e, _, flush_after_s3, _, _) = harness.active_deck_status();
    if saw_buf_s3 {
        return Err(format!(
            "Step 3: is_buffering=true tras seek al 96% ({}ms in [{}..{}], dur={}, during_seek={}, watch_pos={}, now_buf=[{}..{}], flushes={}->{})",
            t96_1, s2_start, s2_end, dur_ms, saw_buf_during_seek_s3, pos_s3, s3_now_s, s3_now_e, flush_before_s3, flush_after_s3
        ));
    }
    if is_streaming && !spec.is_hls && flush_after_s3 != flush_before_s3 {
        return Err(format!(
            "Step 3: flush_circular inesperado ({} -> {}) al buscar al 96% del buffer ({}ms in [{}..{}])",
            flush_before_s3, flush_after_s3, t96_1, s2_start, s2_end
        ));
    }
    if idx_s3 != 0 {
        return Err(format!("Step 3: cambio inesperado a indice {}", idx_s3));
    }

    // STEP 4: Seek al 25%, validar carga desde 25%, luego seek al 96% del buffer y validar NO buffering.
    let t25 = (dur_ms * 25) / 100;
    harness
        .coordinator
        .seek(t25)
        .map_err(|e| format!("Step 4a seek(25%) failed: {}", e))?;
    harness.wait_seek_settled(Duration::from_secs(12))?;
    let (s4_start, s4_end) =
        harness.wait_buffer_ready(t25, 2500, dur_ms, Duration::from_secs(12))?;
    validate_anchored_buffer(
        "Step 4a (seek 25%)",
        t25,
        s4_start,
        s4_end,
        dur_ms,
        spec.seek_anchor_back_tol_ms,
        is_streaming,
    )?;

    let span4 = (s4_end - s4_start).max(1);
    let t96_2 = (s4_start + (span4 * 96) / 100).min(dur_ms.saturating_sub(1500));
    let (_, _, _, _, _, _, flush_before_s4b, _, _) = harness.active_deck_status();
    harness
        .coordinator
        .seek(t96_2)
        .map_err(|e| format!("Step 4b seek(96% buf) failed: {}", e))?;
    let mut saw_buf_s4b = false;
    let s4b_wait = Instant::now();
    let mut saw_buf_during_seek_s4b = false;
    loop {
        if harness.engine.snapshots().is_buffering() {
            saw_buf_during_seek_s4b = true;
            saw_buf_s4b = true;
        }
        let (_, _, sp, _, _, _, _, _, _) = harness.active_deck_status();
        if !sp {
            break;
        }
        if s4b_wait.elapsed() > Duration::from_secs(10) {
            return Err("Step 4b: timeout settling seek(96% buf)".to_string());
        }
        thread::sleep(Duration::from_millis(5));
    }
    let (watch_buf_s4b, pos_s4b, idx_s4b, _) = harness.watch_playback(Duration::from_millis(350));
    saw_buf_s4b |= watch_buf_s4b;
    let (_, _, _, s4b_now_s, s4b_now_e, _, flush_after_s4b, _, _) = harness.active_deck_status();
    if saw_buf_s4b {
        return Err(format!(
            "Step 4b: is_buffering=true tras seek al 96% ({}ms in [{}..{}], during_seek={}, watch_pos={}, now_buf=[{}..{}], flushes={}->{})",
            t96_2, s4_start, s4_end, saw_buf_during_seek_s4b, pos_s4b, s4b_now_s, s4b_now_e, flush_before_s4b, flush_after_s4b
        ));
    }
    if is_streaming && !spec.is_hls && flush_after_s4b != flush_before_s4b {
        return Err(format!(
            "Step 4b: flush_circular inesperado ({} -> {}) al buscar al 96% del buffer ({}ms in [{}..{}])",
            flush_before_s4b, flush_after_s4b, t96_2, s4_start, s4_end
        ));
    }
    if idx_s4b != 0 {
        return Err(format!("Step 4b: cambio inesperado a indice {}", idx_s4b));
    }

    // STEP 5: Seek al 90% -> validar carga -> seek al 70% del buffer -> reproducir un momento -> seek al 50% -> NO cambia de pista.
    let t90 = (dur_ms * 90) / 100;
    harness
        .coordinator
        .seek(t90)
        .map_err(|e| format!("Step 5a seek(90%) failed: {}", e))?;
    harness.wait_seek_settled(Duration::from_secs(12))?;
    let (s5_start, s5_end) =
        harness.wait_buffer_ready(t90, 1500, dur_ms, Duration::from_secs(12))?;
    validate_anchored_buffer(
        "Step 5a (seek 90%)",
        t90,
        s5_start,
        s5_end,
        dur_ms,
        spec.seek_anchor_back_tol_ms,
        is_streaming,
    )?;

    let span5 = (s5_end - s5_start).max(1);
    let t70_buf = (s5_start + (span5 * 70) / 100).min(dur_ms.saturating_sub(1200));
    harness
        .coordinator
        .seek(t70_buf)
        .map_err(|e| format!("Step 5b seek(70% buf) failed: {}", e))?;
    harness.wait_seek_settled(Duration::from_secs(10))?;

    // Dejar sonar un momento (entrando en zona auto-crossfade si aplica) sin dejar que termine antes del seek(50%).
    let max_safe_play = (dur_ms - t70_buf - 600).clamp(250, 900);
    thread::sleep(Duration::from_millis(max_safe_play as u64));

    let t50 = (dur_ms * 50) / 100;
    harness
        .coordinator
        .seek(t50)
        .map_err(|e| format!("Step 5c seek(50%) failed: {}", e))?;
    harness.wait_seek_settled(Duration::from_secs(10))?;

    let (_, final_pos, final_idx, final_xf) = harness.watch_playback(Duration::from_millis(500));
    let st = harness.engine.snapshots().playback_state();
    if final_idx != 0 {
        return Err(format!(
            "Step 5c: cambio indebido a siguiente pista (index={}, pos={}ms)",
            final_idx, final_pos
        ));
    }
    if final_xf {
        return Err("Step 5c: crossfade sigue activo tras seek(50%)".to_string());
    }
    if st != PlaybackState::Playing {
        return Err(format!("Step 5c: estado {:?} != Playing", st));
    }
    if (final_pos - t50).abs() > 4000 {
        return Err(format!(
            "Step 5c: pos final {}ms lejos de seek 50% ({}ms)",
            final_pos, t50
        ));
    }

    Ok(format!(
        "dur={}ms s1=[{}..{}] s2=[{}..{}] t96_1={} s4=[{}..{}] t96_2={} s5=[{}..{}] final={}",
        dur_ms, s1_start, s1_end, s2_start, s2_end, t96_1, s4_start, s4_end, t96_2, s5_start, s5_end, final_pos
    ))
}

#[test]
fn test_bailando_opus_seek_23s_and_near_buffer_end_no_displacement_no_buffering() {
    let music_dir = FixtureResolver::fixtures_dir();
    let server = MultiFileHttpServer::start(music_dir);
    let opus = CATALOG_28[1];

    for mode in [NetworkMode::RemoteLimited, NetworkMode::RemoteFull] {
        if mode == NetworkMode::RemoteLimited {
            server.set_profile(35, 140 * 1024);
        } else {
            server.set_profile(0, 0);
        }
        let harness = PlayerHarness::spawn();
        let url = format!(
            "http://127.0.0.1:{}/{}",
            server.port,
            percent_encode_rel(opus.rel_path)
        );
        let next_url = format!(
            "http://127.0.0.1:{}/17_Running_To_Meet_The_Sun.wav",
            server.port
        );
        harness
            .coordinator
            .set_queue(
                vec![
                    AudioSourceCore {
                        id: 1,
                        source: url,
                        headers: None,
                        data_bytes: None,
                        replay_gain_db: None,
                        replay_peak: None,
                        resolve_in_dart: false,
                    },
                    AudioSourceCore {
                        id: 2,
                        source: next_url,
                        headers: None,
                        data_bytes: None,
                        replay_gain_db: None,
                        replay_peak: None,
                        resolve_in_dart: false,
                    },
                ],
                harness.custom_factory(),
            )
            .unwrap();
        harness.coordinator.play(Some(1), Some(0), None, None, false).unwrap();
        let mut dur_ms = 0i64;
        for _ in 0..200 {
            let (_, dur, _, _, end, _, _, _, _) = harness.active_deck_status();
            if dur > 0 && end > 1000 {
                dur_ms = dur;
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert!(dur_ms > 100_000, "Bailando Opus duration invalid: {}", dur_ms);

        // User-reported exact repro: seek to 23_000 ms (0:23)
        harness.coordinator.seek(23_000).unwrap();
        harness.wait_seek_settled(Duration::from_secs(10)).unwrap();
        let (b_start, b_end) = harness
            .wait_buffer_ready(23_000, 3_000, dur_ms, Duration::from_secs(10))
            .expect("Buffer should load around 23_000ms");
        if mode == NetworkMode::RemoteLimited || b_start > 500 {
            assert!(
                (21_800..=23_100).contains(&b_start),
                "[{}] Bailando seek(23000): buf.start={}ms displaced (expected ~22000..23000, bug was 20400ms, end={})",
                mode.label(),
                b_start,
                b_end
            );
        } else {
            assert!(
                b_start == 0 && b_end >= 26_000,
                "[{}] Bailando seek(23000) cache hit should preserve [0..{}], got start={}",
                mode.label(),
                b_end,
                b_start
            );
        }

        // Seek near the end of loaded buffer (96%) -> must NOT trigger buffering or ring flush
        let t96 = b_start + ((b_end - b_start) * 96) / 100;
        let (_, _, _, _, _, _, flush_before, _, _) = harness.active_deck_status();
        harness.coordinator.seek(t96).unwrap();
        let mut saw_buf = false;
        for _ in 0..1000 {
            if harness.engine.snapshots().is_buffering() {
                saw_buf = true;
            }
            let (_, _, sp, _, _, _, _, _, _) = harness.active_deck_status();
            if !sp {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        let (watch_buf, pos_after, idx_after, _) =
            harness.watch_playback(Duration::from_millis(350));
        saw_buf |= watch_buf;
        let (_, _, _, _, _, _, flush_after, _, _) = harness.active_deck_status();
        assert!(
            !saw_buf,
            "[{}] Bailando seek(96% buf = {}ms inside [{}..{}]) triggered buffering!",
            mode.label(),
            t96,
            b_start,
            b_end
        );
        assert_eq!(
            flush_after, flush_before,
            "[{}] Bailando seek(96% buf = {}ms inside [{}..{}]) flushed circular buffer ({} -> {})!",
            mode.label(),
            t96,
            b_start,
            b_end,
            flush_before,
            flush_after
        );
        assert_eq!(idx_after, 0);
        assert!((pos_after - t96).abs() < 3000, "pos_after={} vs t96={}", pos_after, t96);
    }
}

#[test]
fn test_28_tracks_seek_buffer_matrix_local_remote_full_remote_limited() {
    let music_dir = FixtureResolver::fixtures_dir();
    let server = MultiFileHttpServer::start(music_dir);
    let mut failures: Vec<String> = Vec::new();
    let mut passes = 0usize;

    for (idx, spec) in CATALOG_28.iter().enumerate() {
        for mode in [
            NetworkMode::Local,
            NetworkMode::RemoteFull,
            NetworkMode::RemoteLimited,
        ] {
            let tag = format!("[{:02} {} | {}]", idx + 1, spec.rel_path, mode.label());
            match run_five_step_chain(spec, mode, &server) {
                Ok(info) => {
                    passes += 1;
                    eprintln!("PASS {} -> {}", tag, info);
                }
                Err(err) => {
                    eprintln!("FAIL {} -> {}", tag, err);
                    failures.push(format!("{}: {}", tag, err));
                }
            }
        }
    }

    eprintln!(
        "\n=== MATRIX SUMMARY: {}/{} PASSED, {} FAILED ===",
        passes,
        CATALOG_28.len() * 3,
        failures.len()
    );
    assert!(
        failures.is_empty(),
        "Matrix failures ({}):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn test_step5_active_auto_crossfade_seek_50_aborts_cleanly_no_track_switch() {
    let music_dir = FixtureResolver::fixtures_dir();
    let server = MultiFileHttpServer::start(music_dir.clone());
    let opus = CATALOG_28[1];

    for mode in [
        NetworkMode::Local,
        NetworkMode::RemoteFull,
        NetworkMode::RemoteLimited,
    ] {
        if mode == NetworkMode::RemoteLimited {
            server.set_profile(35, 160 * 1024);
        } else {
            server.set_profile(0, 0);
        }
        let harness = PlayerHarness::spawn();
        let primary_uri = match mode {
            NetworkMode::Local => music_dir.join(opus.rel_path).to_string_lossy().into_owned(),
            _ => format!("http://127.0.0.1:{}/{}", server.port, percent_encode_rel(opus.rel_path)),
        };
        let second_uri = match mode {
            NetworkMode::Local => music_dir.join("17_Running_To_Meet_The_Sun.wav").to_string_lossy().into_owned(),
            _ => format!("http://127.0.0.1:{}/17_Running_To_Meet_The_Sun.wav", server.port),
        };
        harness
            .coordinator
            .set_queue(
                vec![
                    AudioSourceCore {
                        id: 1,
                        source: primary_uri,
                        headers: None,
                        data_bytes: None,
                        replay_gain_db: None,
                        replay_peak: None,
                        resolve_in_dart: false,
                    },
                    AudioSourceCore {
                        id: 2,
                        source: second_uri,
                        headers: None,
                        data_bytes: None,
                        replay_gain_db: None,
                        replay_peak: None,
                        resolve_in_dart: false,
                    },
                ],
                harness.custom_factory(),
            )
            .unwrap();
        harness.coordinator.play(Some(1), Some(0), None, None, false).unwrap();
        let mut dur_ms = 0i64;
        for _ in 0..200 {
            let (_, dur, _, _, end, _, _, _, _) = harness.active_deck_status();
            if dur > 0 && end > 1000 {
                dur_ms = dur;
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert!(dur_ms > 20_000);

        // Seek inside the active 5000ms auto-crossfade window, let crossfade run briefly, then seek to 50%.
        let near_end = dur_ms - 3_200;
        harness.coordinator.seek(near_end).unwrap();
        harness.wait_seek_settled(Duration::from_secs(10)).unwrap();

        let xfade_wait = Instant::now();
        while xfade_wait.elapsed() < Duration::from_secs(2) {
            if harness.engine.snapshots().is_xfading() {
                break;
            }
            thread::sleep(Duration::from_millis(15));
        }
        assert!(
            harness.engine.snapshots().is_xfading(),
            "[{}] Esperaba AutoCrossfade activo en {}ms (dur={})",
            mode.label(),
            near_end,
            dur_ms
        );
        thread::sleep(Duration::from_millis(450));

        let t50 = dur_ms / 2;
        harness.coordinator.seek(t50).unwrap();
        harness.wait_seek_settled(Duration::from_secs(10)).unwrap();

        let (_, final_pos, final_idx, final_xf) = harness.watch_playback(Duration::from_millis(600));
        assert_eq!(
            final_idx, 0,
            "[{}] AutoCrossfade no se aborto al hacer seek(50%), cambio a {}",
            mode.label(),
            final_idx
        );
        assert!(
            !final_xf,
            "[{}] Crossfade sigue activo tras seek(50%)",
            mode.label()
        );
        assert_eq!(harness.engine.snapshots().playback_state(), PlaybackState::Playing);
        assert!(
            (final_pos - t50).abs() < 3500,
            "[{}] Posicion final {}ms lejos de 50% ({}ms)",
            mode.label(),
            final_pos,
            t50
        );
    }
}
