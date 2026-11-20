//! Track-Switch & Queue-Selection Latency Benchmark Suite
//! (`[Local, RemotoFull, RemotoLimitado, RemotoUltraLento]`).
//!
//! Covers all 4 requested scenarios across every network profile plus cold-standby EOF
//! and chained rapid-click preemption on `RemotoUltraLento`:
//! - S1: Initial `play()` from stopped (`-1 -> 0`)
//! - S2: Natural track completion after seeking to `95%` (`auto_crossfade = 0` & `5000ms`),
//!       measuring elapsed time from Track 0 reaching EOF until Track 1 is marked in queue
//! - S3: Manual `next()` while playing
//! - S4: Manual `play(other_id)` targeting a track different from next (never prewarmed)
//! - S5: Chained clicks (`next()` -> 50ms -> `play(Track 3)`) under `RemotoUltraLento`
//!
//! Run with `MAP_PERF_BASELINE=1` before fixes to capture baseline timings without failing
//! latency assertions; run without it to enforce strict `< 50 ms` queue selection guarantees.

mod common;

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::buffer::{CustomDartByteSource, CustomSourceRegistry};
use miniaudio_player::core::control_coordinator::ControlCoordinator;
use miniaudio_player::core::dual_source::{AudioSourceCore, CustomSourceFactory};
use miniaudio_player::core::engine_actor::EngineActorHandle;
use miniaudio_player::core::PlaybackState;

const STRICT_QUEUE_MARK_BUDGET_MS: u128 = 50;

#[derive(Clone, Copy)]
struct FormatRouteSpec {
    route: &'static str,
    rel_file: &'static str,
    format_label: &'static str,
    extra_open_delay_ms: usize,
}

/// 15 real distinct audio formats from `example/assets/music/` mapped to clean ASCII routes.
const MIXED_WEB_CATALOG_15: &[FormatRouteSpec] = &[
    FormatRouteSpec { route: "01_mp3_vbr.mp3", rel_file: "01_Apex_Momentum.mp3", format_label: "MP3_VBR", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "02_opus.opus", rel_file: "02_Bailando_con_tu_recuerdo.opus", format_label: "OPUS", extra_open_delay_ms: 600 },
    FormatRouteSpec { route: "03_mp3_cbr.mp3", rel_file: "03_Before_The_Dawn_cbr_noxing.mp3", format_label: "MP3_CBR", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "04_flac.flac", rel_file: "04_Belaya_Tishina.flac", format_label: "FLAC", extra_open_delay_ms: 700 },
    FormatRouteSpec { route: "05_ogg.ogg", rel_file: "05_Burning_in_the_Electric_Light.ogg", format_label: "OGG_VORBIS", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "06_aac.m4a", rel_file: "06_Calculated_Motion_aac.m4a", format_label: "M4A_AAC", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "07_alac.m4a", rel_file: "07_Fevered_Strings_alac.m4a", format_label: "M4A_ALAC", extra_open_delay_ms: 700 },
    FormatRouteSpec { route: "09_wv.wv", rel_file: "09_Flesh_and_Chrome.wv", format_label: "WAVPACK", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "10_adts.aac", rel_file: "10_La_cicatriz_del_andén.aac", format_label: "AAC_ADTS", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "11_mka.mka", rel_file: "11_Mar_de_cristal.mka", format_label: "MKA_FLAC", extra_open_delay_ms: 700 },
    FormatRouteSpec { route: "13_webm.webm", rel_file: "13_Overture_for_the_Floor.webm", format_label: "WEBM_OPUS", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "14_mkv.mkv", rel_file: "14_Painting_the_Sky.mkv", format_label: "MKV_OPUS", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "15_mp2.mp2", rel_file: "15_Resting_At_Your_Feet.mp2", format_label: "MP2", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "16_oga.oga", rel_file: "16_Ribbons_on_Anchors.oga", format_label: "OGA_VORBIS", extra_open_delay_ms: 0 },
    FormatRouteSpec { route: "17_wav.wav", rel_file: "17_Running_To_Meet_The_Sun.wav", format_label: "WAV_16B", extra_open_delay_ms: 650 },
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NetworkProfile {
    Local,
    RemotoFull,
    RemotoLimitado,
    RemotoUltraLento,
}

impl NetworkProfile {
    fn label(self) -> &'static str {
        match self {
            Self::Local => "Local",
            Self::RemotoFull => "RemotoFull",
            Self::RemotoLimitado => "RemotoLimitado",
            Self::RemotoUltraLento => "RemotoUltraLento",
        }
    }

    /// Returns `(open_delay_ms, rtt_ms, bytes_per_sec, burst_free_bytes)`.
    fn net_params(self) -> (usize, usize, usize, usize) {
        match self {
            Self::Local => (0, 0, 0, usize::MAX),
            Self::RemotoFull => (0, 0, 0, usize::MAX),
            Self::RemotoLimitado => (40, 40, 160 * 1024, 32 * 1024),
            Self::RemotoUltraLento => (600, 250, 24 * 1024, 0),
        }
    }
}

#[derive(Clone, Copy)]
struct ServerProfile {
    open_delay_ms: usize,
    rtt_ms: usize,
    bytes_per_sec: usize,
    burst_free_bytes: usize,
}

enum RouteBacking {
    Memory(Arc<[u8]>),
    DiskFile(PathBuf, usize),
}

impl RouteBacking {
    fn len(&self) -> usize {
        match self {
            Self::Memory(b) => b.len(),
            Self::DiskFile(_, len) => *len,
        }
    }
}

struct PerfHttpServer {
    port: u16,
    stop: Arc<AtomicBool>,
    profile: Arc<Mutex<ServerProfile>>,
    extra_delays: Arc<Mutex<HashMap<String, usize>>>,
    thread: Option<JoinHandle<()>>,
}

impl PerfHttpServer {
    fn start(fixtures_dir: PathBuf, synthetic_files: Vec<(&'static str, Vec<u8>)>) -> Self {
        let mut map: HashMap<String, RouteBacking> = HashMap::new();
        for rel in [
            "02_Bailando_con_tu_recuerdo.opus",
            "05_Burning_in_the_Electric_Light.ogg",
            "01_Apex_Momentum.mp3",
            "06_Calculated_Motion_aac.m4a",
        ] {
            let full = fixtures_dir.join(rel);
            let data = std::fs::read(&full)
                .unwrap_or_else(|e| panic!("Failed to read fixture {:?}: {}", full, e));
            map.insert(rel.to_string(), RouteBacking::Memory(Arc::from(data)));
        }
        for spec in MIXED_WEB_CATALOG_15 {
            let full = fixtures_dir.join(spec.rel_file);
            let meta = std::fs::metadata(&full)
                .unwrap_or_else(|e| panic!("Failed to stat fixture {:?}: {}", full, e));
            map.insert(
                spec.route.to_string(),
                RouteBacking::DiskFile(full, meta.len() as usize),
            );
        }
        for (rel, bytes) in synthetic_files {
            map.insert(rel.to_string(), RouteBacking::Memory(Arc::from(bytes)));
        }
        let files = Arc::new(map);

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind perf http server");
        listener.set_nonblocking(true).expect("set nonblocking");
        let port = listener.local_addr().expect("local_addr").port();
        let stop = Arc::new(AtomicBool::new(false));
        let profile = Arc::new(Mutex::new(ServerProfile {
            open_delay_ms: 0,
            rtt_ms: 0,
            bytes_per_sec: 0,
            burst_free_bytes: usize::MAX,
        }));
        let extra_delays: Arc<Mutex<HashMap<String, usize>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let stop_c = stop.clone();
        let prof_c = profile.clone();
        let extra_c = extra_delays.clone();

        let thread = thread::Builder::new()
            .name("test-perf-http".to_string())
            .spawn(move || {
                let mut workers: Vec<JoinHandle<()>> = Vec::new();
                while !stop_c.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let _ = stream.set_nonblocking(false);
                            let f = files.clone();
                            let s = stop_c.clone();
                            let p = prof_c.clone();
                            let ex = extra_c.clone();
                            workers.retain(|w| !w.is_finished());
                            workers.push(thread::spawn(move || {
                                Self::handle_client(stream, f, s, p, ex);
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
            .expect("spawn perf http thread");

        Self {
            port,
            stop,
            profile,
            extra_delays,
            thread: Some(thread),
        }
    }

    fn set_custom(
        &self,
        open_delay_ms: usize,
        rtt_ms: usize,
        bytes_per_sec: usize,
        burst_free_bytes: usize,
    ) {
        let mut guard = self.profile.lock().expect("profile lock");
        *guard = ServerProfile {
            open_delay_ms,
            rtt_ms,
            bytes_per_sec,
            burst_free_bytes,
        };
    }

    fn set_extra_delay(&self, route: &str, delay_ms: usize) {
        self.extra_delays
            .lock()
            .expect("extra_delays lock")
            .insert(route.to_string(), delay_ms);
    }

    fn set_profile(&self, net: NetworkProfile) {
        self.extra_delays.lock().expect("extra_delays lock").clear();
        let (open_delay_ms, rtt_ms, bytes_per_sec, burst_free_bytes) = net.net_params();
        self.set_custom(open_delay_ms, rtt_ms, bytes_per_sec, burst_free_bytes);
    }

    fn sleep_interruptible(dur: Duration, stop: &AtomicBool) -> bool {
        let start = Instant::now();
        while start.elapsed() < dur {
            if stop.load(Ordering::Acquire) {
                return false;
            }
            thread::sleep((dur - start.elapsed()).min(Duration::from_millis(25)));
        }
        !stop.load(Ordering::Acquire)
    }

    fn handle_client(
        mut stream: TcpStream,
        files: Arc<HashMap<String, RouteBacking>>,
        stop: Arc<AtomicBool>,
        profile: Arc<Mutex<ServerProfile>>,
        extra_delays: Arc<Mutex<HashMap<String, usize>>>,
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
        let rel_path = raw_path
            .split('?')
            .next()
            .unwrap_or(raw_path)
            .trim_start_matches('/')
            .to_string();

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

        let cfg = *profile.lock().expect("profile lock");
        let extra_open = extra_delays
            .lock()
            .expect("extra_delays lock")
            .get(&rel_path)
            .copied()
            .unwrap_or(0);
        let is_open_probe = method == "HEAD"
            || range_hdr
                .as_deref()
                .is_none_or(|r| r.starts_with("bytes=0-"));
        let delay_ms = cfg.rtt_ms
            + if is_open_probe {
                cfg.open_delay_ms + extra_open
            } else {
                0
            };
        if delay_ms > 0 && !Self::sleep_interruptible(Duration::from_millis(delay_ms as u64), &stop)
        {
            return;
        }

        let Some(backing) = files.get(&rel_path) else {
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            return;
        };
        let total_len = backing.len();

        if method == "HEAD" {
            let hdr = format!(
                "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                total_len
            );
            let _ = stream.write_all(hdr.as_bytes());
            return;
        }

        if let Some(r) = range_hdr.and_then(|s| s.strip_prefix("bytes=").map(str::to_string)) {
            let (a, b) = r.split_once('-').unwrap_or(("0", ""));
            let start: usize = a.parse().unwrap_or(0);
            let end: usize = if b.is_empty() {
                total_len.saturating_sub(1)
            } else {
                b.parse()
                    .unwrap_or(total_len.saturating_sub(1))
                    .min(total_len.saturating_sub(1))
            };
            if start <= end && start < total_len {
                let slice_len = end - start + 1;
                let hdr = format!(
                    "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                    slice_len, start, end, total_len
                );
                if stream.write_all(hdr.as_bytes()).is_err() {
                    return;
                }
                Self::write_backing_throttled(
                    &mut stream,
                    backing,
                    start,
                    end + 1,
                    cfg.bytes_per_sec,
                    cfg.burst_free_bytes,
                    &stop,
                );
                return;
            }
        }

        let hdr = format!(
            "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            total_len
        );
        if stream.write_all(hdr.as_bytes()).is_err() {
            return;
        }
        Self::write_backing_throttled(
            &mut stream,
            backing,
            0,
            total_len,
            cfg.bytes_per_sec,
            cfg.burst_free_bytes,
            &stop,
        );
    }

    fn write_backing_throttled(
        stream: &mut TcpStream,
        backing: &RouteBacking,
        from: usize,
        to: usize,
        bytes_per_sec: usize,
        burst_free_bytes: usize,
        stop: &AtomicBool,
    ) {
        let total_slice = to.saturating_sub(from);
        if total_slice == 0 {
            return;
        }
        match backing {
            RouteBacking::Memory(mem) => {
                Self::write_slice_throttled(
                    stream,
                    &mem[from..to],
                    bytes_per_sec,
                    burst_free_bytes,
                    stop,
                );
            }
            RouteBacking::DiskFile(path, _) => {
                let Ok(mut f) = File::open(path) else {
                    return;
                };
                if f.seek(SeekFrom::Start(from as u64)).is_err() {
                    return;
                }
                let chunk_sz = if bytes_per_sec == 0 { 64 * 1024 } else { 8 * 1024 };
                let sleep_us = if bytes_per_sec == 0 {
                    0
                } else {
                    ((chunk_sz as u128 * 1_000_000) / bytes_per_sec as u128).max(1000) as u64
                };
                let mut buf = vec![0u8; chunk_sz];
                let mut remaining = total_slice;
                let mut sent = 0usize;
                while remaining > 0 && !stop.load(Ordering::Acquire) {
                    let to_read = remaining.min(chunk_sz);
                    let Ok(n) = f.read(&mut buf[..to_read]) else {
                        return;
                    };
                    if n == 0 {
                        break;
                    }
                    if stream.write_all(&buf[..n]).is_err() {
                        return;
                    }
                    remaining -= n;
                    sent += n;
                    if remaining > 0
                        && bytes_per_sec > 0
                        && sent > burst_free_bytes
                        && !Self::sleep_interruptible(Duration::from_micros(sleep_us), stop)
                    {
                        return;
                    }
                }
            }
        }
    }

    fn write_slice_throttled(
        stream: &mut TcpStream,
        data: &[u8],
        bytes_per_sec: usize,
        burst_free_bytes: usize,
        stop: &AtomicBool,
    ) {
        if bytes_per_sec == 0 {
            let _ = stream.write_all(data);
            return;
        }
        let chunk_sz = 8 * 1024;
        let sleep_us = ((chunk_sz as u128 * 1_000_000) / bytes_per_sec as u128).max(1000) as u64;
        let mut sent = 0usize;
        while sent < data.len() && !stop.load(Ordering::Acquire) {
            let end = (sent + chunk_sz).min(data.len());
            if stream.write_all(&data[sent..end]).is_err() {
                return;
            }
            sent = end;
            if sent < data.len()
                && sent > burst_free_bytes
                && !Self::sleep_interruptible(Duration::from_micros(sleep_us), stop)
            {
                return;
            }
        }
    }
}

impl Drop for PerfHttpServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(jh) = self.thread.take() {
            let _ = jh.join();
        }
    }
}

struct PerfHarness {
    engine: EngineActorHandle,
    coordinator: ControlCoordinator,
    custom_registry: CustomSourceRegistry,
    events: Arc<Mutex<Vec<(i64, Instant, bool)>>>,
    events_wake: Arc<(Mutex<()>, Condvar)>,
    monitor_stop: Arc<AtomicBool>,
    monitor_jh: Option<JoinHandle<()>>,
}

impl PerfHarness {
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

        let events: Arc<Mutex<Vec<(i64, Instant, bool)>>> = Arc::new(Mutex::new(Vec::new()));
        let events_wake = Arc::new((Mutex::new(()), Condvar::new()));
        let events_cb = events.clone();
        let wake_cb = events_wake.clone();

        let custom_registry = CustomSourceRegistry::new();
        let coordinator = ControlCoordinator::spawn(
            engine.clone(),
            custom_registry.clone(),
            hint_rx,
            Arc::new(move |snap| {
                let has_audio = snap.initial_info.sample_rate > 0;
                events_cb
                    .lock()
                    .expect("events lock")
                    .push((snap.cur_idx, Instant::now(), has_audio));
                let (_g, cv) = &*wake_cb;
                cv.notify_all();
            }),
        );

        let monitor_stop = Arc::new(AtomicBool::new(false));
        let mon_stop_c = monitor_stop.clone();
        let mon_snaps = engine.snapshots().clone();
        let mon_events = events.clone();
        let mon_wake = events_wake.clone();

        // Mirrors `map-telemetry-monitor` waiting on `EngineUiSnapshots` condition variable.
        let monitor_jh = thread::Builder::new()
            .name("test-perf-mon".to_string())
            .spawn(move || {
                let mut last_idx = mon_snaps.current_index();
                let mut wake_seq = 0u64;
                while !mon_stop_c.load(Ordering::Acquire) {
                    mon_snaps.wait_for_telemetry_tick(Duration::from_millis(8), &mut wake_seq);
                    let cur = mon_snaps.current_index();
                    if cur != last_idx {
                        last_idx = cur;
                        let has_audio = mon_snaps.audio_info().sample_rate > 0;
                        mon_events
                            .lock()
                            .expect("events lock")
                            .push((cur, Instant::now(), has_audio));
                        let (_g, cv) = &*mon_wake;
                        cv.notify_all();
                    }
                }
            })
            .expect("spawn perf monitor");

        Self {
            engine,
            coordinator,
            custom_registry,
            events,
            events_wake,
            monitor_stop,
            monitor_jh: Some(monitor_jh),
        }
    }

    fn await_event_for(
        &self,
        target_idx: i64,
        since: Instant,
        timeout: Duration,
    ) -> Option<Instant> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(ts) = self.earliest_event_for(target_idx, since) {
                return Some(ts);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            let (lock, cv) = &*self.events_wake;
            let guard = lock.lock().expect("wake lock");
            if let Some(ts) = self.earliest_event_for(target_idx, since) {
                return Some(ts);
            }
            let rem = deadline.saturating_duration_since(Instant::now());
            let _ = cv.wait_timeout(guard, rem.min(Duration::from_millis(5)));
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

    fn clear_events(&self) {
        self.events.lock().expect("events lock").clear();
    }

    fn earliest_event_for(&self, target_idx: i64, since: Instant) -> Option<Instant> {
        self.events
            .lock()
            .expect("events lock")
            .iter()
            .filter(|&&(idx, ts, _)| idx == target_idx && ts >= since)
            .map(|&(_, ts, _)| ts)
            .min()
    }

    fn wait_track_audio_ready(&self, expected_idx: i64, timeout: Duration) -> Result<i64, String> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            let ready = self
                .engine
                .exec(move |ply| {
                    let cur_idx = ply.music_manager.current_index();
                    let st = PlaybackState::from_i32(
                        ply.music_manager.inner.playback_state.load(Ordering::Relaxed),
                    );
                    let deck = ply.music_manager.active_deck_ref();
                    let dur = deck.duration_ms.load(Ordering::Acquire);
                    let pos = deck.position_ms.load(Ordering::Acquire);
                    let item_ok = deck.queue_item_id == read_current_item_id(&ply.music_manager.inner);
                    if cur_idx == expected_idx
                        && st == PlaybackState::Playing
                        && item_ok
                        && dur > 0
                        && pos >= 0
                    {
                        Some(dur)
                    } else {
                        None
                    }
                })
                .ok()
                .flatten();
            if let Some(dur) = ready {
                return Ok(dur);
            }
            thread::sleep(Duration::from_millis(8));
        }
        let diag = self
            .engine
            .exec(|ply| {
                let d = ply.music_manager.active_deck_ref();
                (
                    ply.music_manager.current_index(),
                    ply.music_manager.inner.playback_state.load(Ordering::Relaxed),
                    ply.music_manager.inner.pending_open_active.load(Ordering::Acquire),
                    d.queue_item_id,
                    read_current_item_id(&ply.music_manager.inner),
                    d.duration_ms.load(Ordering::Acquire),
                    d.position_ms.load(Ordering::Acquire),
                    d.state.load(Ordering::Acquire),
                    d.is_buffering.load(Ordering::Acquire),
                    d.track_exhausted.load(Ordering::Acquire),
                )
            })
            .ok();
        Err(format!(
            "Timeout waiting for active audio ready at index {} (snap_idx={}, diag={:?}, io_stats={:?})",
            expected_idx,
            self.engine.snapshots().current_index(),
            diag,
            self.coordinator.io_pool_stats(),
        ))
    }
}

fn read_current_item_id(inner: &miniaudio_player::core::dual_source::DualSource) -> Option<i64> {
    let idx = inner.current_index.load(Ordering::Acquire);
    if idx < 0 {
        return None;
    }
    inner
        .queue
        .read()
        .ok()
        .and_then(|q| q.get(idx as usize).map(|it| it.id))
}

impl Drop for PerfHarness {
    fn drop(&mut self) {
        self.monitor_stop.store(true, Ordering::Release);
        if let Some(jh) = self.monitor_jh.take() {
            let _ = jh.join();
        }
        self.custom_registry.abort_all();
        self.coordinator.shutdown();
        self.engine.shutdown();
    }
}

#[derive(Clone)]
struct BenchRow {
    profile: String,
    scenario: String,
    t_snap_ms: u128,
    t_event_ms: u128,
    t_audio_ms: u128,
}

fn build_queue_4(profile: NetworkProfile, port: u16) -> Vec<AudioSourceCore> {
    let dir = FixtureResolver::fixtures_dir();
    let rels = [
        "02_Bailando_con_tu_recuerdo.opus",
        "05_Burning_in_the_Electric_Light.ogg",
        "01_Apex_Momentum.mp3",
        "06_Calculated_Motion_aac.m4a",
    ];
    rels.iter()
        .enumerate()
        .map(|(i, rel)| {
            let uri = match profile {
                NetworkProfile::Local => dir.join(rel).to_string_lossy().into_owned(),
                NetworkProfile::RemotoFull
                | NetworkProfile::RemotoLimitado
                | NetworkProfile::RemotoUltraLento => format!("http://127.0.0.1:{}/{}", port, rel),
            };
            AudioSourceCore {
                id: (i as i64) + 1,
                source: uri,
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            }
        })
        .collect()
}

fn measure_rpc_transition<F>(
    harness: &PerfHarness,
    expected_idx: i64,
    rpc_timeout: Duration,
    rpc_fn: F,
) -> (u128, u128, u128)
where
    F: FnOnce(&ControlCoordinator) + Send + 'static,
{
    harness.clear_events();
    let t0 = Instant::now();
    let coord = harness.coordinator.clone();
    let jh = thread::spawn(move || {
        rpc_fn(&coord);
    });

    let mut snap_ms: Option<u128> = None;
    let mut event_ms: Option<u128> = None;
    let mut audio_ms: Option<u128> = None;

    while t0.elapsed() < rpc_timeout {
        if snap_ms.is_none() && harness.engine.snapshots().current_index() == expected_idx {
            snap_ms = Some(t0.elapsed().as_millis());
        }
        if event_ms.is_none() {
            if let Some(ev_ts) = harness.earliest_event_for(expected_idx, t0) {
                event_ms = Some(ev_ts.saturating_duration_since(t0).as_millis());
            }
        }
        if snap_ms.is_some() && event_ms.is_some() && jh.is_finished() {
            let info = harness.engine.snapshots().audio_info();
            if info.sample_rate > 0 && harness.engine.snapshots().current_index() == expected_idx {
                audio_ms.get_or_insert_with(|| t0.elapsed().as_millis());
                break;
            }
        }
        if audio_ms.is_none() && jh.is_finished() && snap_ms.is_some() && event_ms.is_some() {
            audio_ms = Some(t0.elapsed().as_millis());
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }

    let _ = jh.join();
    // Ensure new audio actually finished loading before moving to next test step.
    if audio_ms.is_none() {
        let _ = harness.wait_track_audio_ready(expected_idx, Duration::from_secs(15));
        audio_ms = Some(t0.elapsed().as_millis());
    }

    let final_snap = snap_ms.unwrap_or_else(|| t0.elapsed().as_millis());
    let final_event = event_ms.unwrap_or_else(|| t0.elapsed().as_millis());
    (final_snap, final_event, audio_ms.unwrap_or(final_snap))
}

fn wait_until_playing_past_seek(
    harness: &PerfHarness,
    seek_target_ms: i64,
    timeout: Duration,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let ok = harness
            .engine
            .exec(move |ply| {
                let d = ply.music_manager.active_deck_ref();
                let seek_pending = d.seek_request_ms.load(Ordering::Acquire) >= 0;
                let pos = d.position_ms.load(Ordering::Acquire);
                let is_buf = d.is_buffering.load(Ordering::Acquire);
                !seek_pending && !is_buf && pos >= seek_target_ms.saturating_sub(1500)
            })
            .unwrap_or(false);
        if ok {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(15));
    }
    Err("Timeout waiting for 95% seek settle".to_string())
}

fn measure_eof_advance_pair(
    harness: &PerfHarness,
    from_idx: i64,
    to_idx: i64,
    dur_ms: i64,
    seek_target_ms: i64,
    wait_timeout: Duration,
) -> Result<(u128, u128, u128, u128), String> {
    wait_until_playing_past_seek(harness, seek_target_ms, Duration::from_secs(15))?;
    harness.clear_events();

    let start = Instant::now();
    let mut eof_at: Option<Instant> = None;
    let mut snap_at: Option<Instant> = None;
    let mut event_at: Option<Instant> = None;

    while start.elapsed() < wait_timeout {
        let now = Instant::now();
        let snap_idx = harness.engine.snapshots().current_index();
        let snap_pos = harness.engine.snapshots().position_ms();

        if eof_at.is_none() && snap_idx == from_idx {
            if snap_pos >= dur_ms {
                eof_at = Some(now);
            } else if snap_pos >= (dur_ms * 95) / 100 {
                let exhausted = harness
                    .engine
                    .exec(|ply| {
                        ply.music_manager
                            .active_deck_ref()
                            .track_exhausted
                            .load(Ordering::Acquire)
                    })
                    .unwrap_or(false);
                if exhausted {
                    eof_at = Some(now);
                }
            }
        }

        if snap_idx == to_idx {
            eof_at.get_or_insert(now);
            if snap_at.is_none() {
                snap_at = Some(now);
            }
        }

        if let Some(eof_ts) = eof_at {
            if event_at.is_none() {
                event_at = harness.earliest_event_for(to_idx, eof_ts);
                if event_at.is_none() && snap_idx == to_idx {
                    let window_start = eof_ts
                        .checked_sub(Duration::from_millis(12))
                        .unwrap_or(eof_ts);
                    event_at = harness.earliest_event_for(to_idx, window_start);
                }
            }
            if snap_at.is_some() && event_at.is_some() {
                break;
            }
        }
        thread::sleep(Duration::from_millis(1));
    }

    let eof_ts = eof_at.ok_or_else(|| {
        format!(
            "Timeout esperando EOF de track {} -> {} (pos={}, dur={}, idx={})",
            from_idx,
            to_idx,
            harness.engine.snapshots().position_ms(),
            dur_ms,
            harness.engine.snapshots().current_index()
        )
    })?;
    let snap_ts = snap_at
        .ok_or_else(|| format!("Timeout esperando snap_idx == {} tras EOF", to_idx))?;
    let event_ts = event_at.unwrap_or(snap_ts);
    let us = event_ts.saturating_duration_since(eof_ts).as_micros();

    harness.wait_track_audio_ready(to_idx, Duration::from_secs(20))?;
    let audio_ts = Instant::now();

    Ok((
        snap_ts.saturating_duration_since(eof_ts).as_millis(),
        event_ts.saturating_duration_since(eof_ts).as_millis(),
        us,
        audio_ts.saturating_duration_since(eof_ts).as_millis(),
    ))
}

fn measure_eof_advance(
    harness: &PerfHarness,
    dur_ms: i64,
    seek_target_ms: i64,
    wait_timeout: Duration,
) -> Result<(u128, u128, u128), String> {
    let (s, e, _, a) =
        measure_eof_advance_pair(harness, 0, 1, dur_ms, seek_target_ms, wait_timeout)?;
    Ok((s, e, a))
}

fn is_baseline_mode() -> bool {
    std::env::var("MAP_PERF_BASELINE").is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true"))
}

fn assert_budget(row: &BenchRow) {
    println!(
        "  [ROW] {:<22} | {:<40} | snap={:>4} ms | evt={:>4} ms | audio={:>4} ms",
        row.profile, row.scenario, row.t_snap_ms, row.t_event_ms, row.t_audio_ms
    );
    if is_baseline_mode() {
        return;
    }
    assert!(
        row.t_snap_ms < STRICT_QUEUE_MARK_BUDGET_MS,
        "[{} / {}] Snapshot current_index tarda demasiado: {} ms (budget < {} ms)",
        row.profile,
        row.scenario,
        row.t_snap_ms,
        STRICT_QUEUE_MARK_BUDGET_MS
    );
    assert!(
        row.t_event_ms < STRICT_QUEUE_MARK_BUDGET_MS,
        "[{} / {}] Evento CurrentIndex tarda demasiado: {} ms (budget < {} ms)",
        row.profile,
        row.scenario,
        row.t_event_ms,
        STRICT_QUEUE_MARK_BUDGET_MS
    );
}

#[test]
fn track_switch_performance_matrix_test() {
    if let Ok(lvl) = std::env::var("MAP_LOG") {
        if let Ok(v) = lvl.parse::<i32>() {
            miniaudio_player::LOG_LEVEL.store(v, Ordering::Relaxed);
        }
    }
    let only_part = std::env::var("MAP_PERF_PART").unwrap_or_else(|_| "all".to_string());
    let dir = FixtureResolver::fixtures_dir();
    let wav_20s_a = SignalGenerator::pcm16_wav_sine_bytes(22_050 * 20, 22_050, 1, 330.0, 0.5);
    let wav_20s_b = SignalGenerator::pcm16_wav_sine_bytes(22_050 * 20, 22_050, 1, 523.25, 0.5);
    let server = PerfHttpServer::start(
        dir,
        vec![
            ("cold_a.wav", wav_20s_a),
            ("cold_b.wav", wav_20s_b),
        ],
    );

    let mut rows: Vec<BenchRow> = Vec::new();
    let profiles = [
        NetworkProfile::Local,
        NetworkProfile::RemotoFull,
        NetworkProfile::RemotoLimitado,
        NetworkProfile::RemotoUltraLento,
    ];

    // -------------------------------------------------------------------------
    // Part A: Real music tracks across [Local, RemotoFull, RemotoLimitado, RemotoUltraLento]
    // Scenarios: S1 (initial play), S3 (manual next), S4 (play different track)
    // -------------------------------------------------------------------------
    if only_part == "all" || only_part == "a" {
    for profile in profiles {
        server.set_profile(profile);
        let harness = PerfHarness::spawn();
        harness
            .engine
            .exec(|ply| ply.music_manager.set_crossfade(0, 0, 0))
            .expect("set_crossfade failed");
        let queue = build_queue_4(profile, server.port);
        let track4_id = queue[3].id;
        harness
            .coordinator
            .set_queue(queue, harness.custom_factory())
            .expect("set_queue failed");

        // S1: Initial play() (-1 -> 0)
        let (s1_snap, s1_evt, s1_aud) =
            measure_rpc_transition(&harness, 0, Duration::from_secs(20), |coord| {
                let events_res = coord.play(None, Some(0), None, None, false);
                let _ = events_res;
            });
        harness
            .wait_track_audio_ready(0, Duration::from_secs(15))
            .expect("S1 audio ready");
        let r1 = BenchRow {
            profile: profile.label().to_string(),
            scenario: "S1: play() inicial (-1 -> 0)".to_string(),
            t_snap_ms: s1_snap,
            t_event_ms: s1_evt,
            t_audio_ms: s1_aud,
        };
        assert_budget(&r1);
        rows.push(r1);

        // S3: Manual next() while Track 0 is playing -> Track 1
        // Notice: on RemotoUltraLento we call next() right away (standby likely still warming or cold),
        // exercising cold/warming next().
        let (s3_snap, s3_evt, s3_aud) =
            measure_rpc_transition(&harness, 1, Duration::from_secs(20), |coord| {
                let _ = coord.next(None, false);
            });
        harness
            .wait_track_audio_ready(1, Duration::from_secs(15))
            .expect("S3 audio ready");
        let r3 = BenchRow {
            profile: profile.label().to_string(),
            scenario: "S3: next() manual (0 -> 1)".to_string(),
            t_snap_ms: s3_snap,
            t_event_ms: s3_evt,
            t_audio_ms: s3_aud,
        };
        assert_budget(&r3);
        rows.push(r3);

        // Wait a tiny moment to let Track 2 prewarm start, then jump to Track 3 (index 3, NEVER prewarmed!)
        thread::sleep(Duration::from_millis(60));
        let (s4_snap, s4_evt, s4_aud) =
            measure_rpc_transition(&harness, 3, Duration::from_secs(20), move |coord| {
                let _ = coord.play(Some(track4_id), None, None, None, false);
            });
        harness
            .wait_track_audio_ready(3, Duration::from_secs(15))
            .expect("S4 audio ready");
        let r4 = BenchRow {
            profile: profile.label().to_string(),
            scenario: "S4: play(otra_pista) (1 -> 3)".to_string(),
            t_snap_ms: s4_snap,
            t_event_ms: s4_evt,
            t_audio_ms: s4_aud,
        };
        assert_budget(&r4);
        rows.push(r4);
    }
    }

    // -------------------------------------------------------------------------
    // Part B: S2 — Real track playing -> seek(95%) -> natural EOF -> Track 1 marked
    // Tested for both Gapless (auto_crossfade = 0) & Crossfade (auto_crossfade = 5000ms)
    // across all 4 profiles.
    // -------------------------------------------------------------------------
    if only_part == "all" || only_part == "b" {
    for (xfade_ms, xfade_label) in [(0u64, "gapless"), (5000u64, "xfade5s")] {
        for profile in profiles {
            server.set_profile(profile);
            let harness = PerfHarness::spawn();
            harness
                .engine
                .exec(move |ply| ply.music_manager.set_crossfade(xfade_ms, 0, 0))
                .expect("set_crossfade failed");
            let queue = build_queue_4(profile, server.port);
            harness
                .coordinator
                .set_queue(queue, harness.custom_factory())
                .expect("set_queue failed");
            harness
                .coordinator
                .play(None, Some(0), None, None, false)
                .expect("S2 play failed");
            let dur_ms = harness
                .wait_track_audio_ready(0, Duration::from_secs(20))
                .expect("S2 track 0 ready");
            let seek_95 = (dur_ms * 95) / 100;
            harness
                .coordinator
                .seek(seek_95)
                .expect("S2 seek(95%) failed");

            let (s2_snap, s2_evt, s2_aud) =
                measure_eof_advance(&harness, dur_ms, seek_95, Duration::from_secs(30))
                    .expect("S2 EOF advance failed");
            let r2 = BenchRow {
                profile: profile.label().to_string(),
                scenario: format!("S2 ({}): 95% -> EOF (0 -> 1)", xfade_label),
                t_snap_ms: s2_snap,
                t_event_ms: s2_evt,
                t_audio_ms: s2_aud,
            };
            assert_budget(&r2);
            rows.push(r2);
        }
    }
    }

    // -------------------------------------------------------------------------
    // Part C: S2 Cold-Standby on RemotoUltraLento (Track 0 finishes BEFORE Track 1 opens)
    // Proves EOF queue selection happens immediately even when Track 1 takes ~2.5s to open.
    // -------------------------------------------------------------------------
    if only_part == "all" || only_part == "c" {
    for (xfade_ms, xfade_label) in [(0u64, "gapless"), (5000u64, "xfade5s")] {
        // Phase 1: open Track 0 cleanly, seek to 95% (only 1,000 ms remaining on 20s WAV!)
        server.set_custom(40, 20, 200 * 1024, 32 * 1024);
        let harness = PerfHarness::spawn();
        harness
            .engine
            .exec(move |ply| ply.music_manager.set_crossfade(xfade_ms, 0, 0))
            .expect("set_crossfade failed");
        let queue = vec![
            AudioSourceCore {
                id: 11,
                source: format!("http://127.0.0.1:{}/cold_a.wav", server.port),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
            AudioSourceCore {
                id: 12,
                source: format!("http://127.0.0.1:{}/cold_b.wav", server.port),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            },
        ];
        harness
            .coordinator
            .set_queue(queue, harness.custom_factory())
            .expect("set_queue cold failed");
        harness
            .coordinator
            .play(None, Some(0), None, None, false)
            .expect("cold play failed");
        let dur_ms = harness
            .wait_track_audio_ready(0, Duration::from_secs(10))
            .expect("cold track 0 ready");

        // Switch server to ultra-slow (2000ms header open delay + 300ms RTT + 24 KB/s) AND invalidate
        // any standby that finished during fast startup, right as we seek to 95% (1000ms before EOF).
        server.set_custom(2000, 300, 24 * 1024, 0);
        harness
            .engine
            .exec(|ply| {
                ply.music_manager.inner.invalidate_standby();
                ply.music_manager.inner.standby_deck_mut().stop();
            })
            .expect("invalidate standby failed");

        let seek_95 = (dur_ms * 95) / 100;
        harness
            .coordinator
            .seek(seek_95)
            .expect("cold seek(95%) failed");

        let (s2c_snap, s2c_evt, s2c_aud) =
            measure_eof_advance(&harness, dur_ms, seek_95, Duration::from_secs(20))
                .expect("S2 cold EOF advance failed");
        let r2c = BenchRow {
            profile: "RemotoUltraLento(Cold)".to_string(),
            scenario: format!("S2 ({}): EOF sin standby (0 -> 1)", xfade_label),
            t_snap_ms: s2c_snap,
            t_event_ms: s2c_evt,
            t_audio_ms: s2c_aud,
        };
        assert_budget(&r2c);
        rows.push(r2c);
    }
    }

    // -------------------------------------------------------------------------
    // Part D: S5 — Chained Clicks under RemotoUltraLento (next() -> 50ms -> play(Track 3))
    // -------------------------------------------------------------------------
    if only_part == "all" || only_part == "d" {
    {
        server.set_custom(1200, 250, 24 * 1024, 0);
        let harness = PerfHarness::spawn();
        harness
            .engine
            .exec(|ply| ply.music_manager.set_crossfade(0, 0, 0))
            .expect("set_crossfade failed");
        let queue = build_queue_4(NetworkProfile::RemotoUltraLento, server.port);
        let track4_id = queue[3].id;
        harness
            .coordinator
            .set_queue(queue, harness.custom_factory())
            .expect("set_queue failed");
        harness
            .coordinator
            .play(None, Some(0), None, None, false)
            .expect("S5 play 0 failed");
        harness
            .wait_track_audio_ready(0, Duration::from_secs(20))
            .expect("S5 track 0 ready");

        harness
            .engine
            .exec(|ply| {
                ply.music_manager.inner.invalidate_standby();
                ply.music_manager.inner.standby_deck_mut().stop();
            })
            .expect("invalidate standby");

        harness.clear_events();
        let t_click1 = Instant::now();
        let coord1 = harness.coordinator.clone();
        let jh1 = thread::spawn(move || {
            let _ = coord1.next(None, false);
        });

        let mut click1_snap_ms = None;
        while t_click1.elapsed() < Duration::from_millis(50) {
            if click1_snap_ms.is_none() && harness.engine.snapshots().current_index() == 1 {
                click1_snap_ms = Some(t_click1.elapsed().as_millis());
            }
            thread::sleep(Duration::from_millis(1));
        }

        let t_click2 = Instant::now();
        let coord2 = harness.coordinator.clone();
        let jh2 = thread::spawn(move || {
            let _ = coord2.play(Some(track4_id), None, None, None, false);
        });

        let mut click2_snap_ms = None;
        let mut click2_event_ms = None;
        while t_click2.elapsed() < Duration::from_secs(20) {
            if click2_snap_ms.is_none() && harness.engine.snapshots().current_index() == 3 {
                click2_snap_ms = Some(t_click2.elapsed().as_millis());
            }
            if click2_event_ms.is_none() {
                if let Some(ts) = harness.earliest_event_for(3, t_click2) {
                    click2_event_ms = Some(ts.saturating_duration_since(t_click2).as_millis());
                }
            }
            if click2_snap_ms.is_some() && click2_event_ms.is_some() && jh1.is_finished() && jh2.is_finished() {
                break;
            }
            thread::sleep(Duration::from_millis(1));
        }
        let _ = jh1.join();
        let _ = jh2.join();
        harness
            .wait_track_audio_ready(3, Duration::from_secs(20))
            .expect("S5 track 3 audio ready");
        let click2_audio_ms = t_click2.elapsed().as_millis();

        let r5a = BenchRow {
            profile: "RemotoUltraLento".to_string(),
            scenario: "S5a: clic 1 next() antes del 2do clic".to_string(),
            t_snap_ms: click1_snap_ms.unwrap_or_else(|| t_click1.elapsed().as_millis()),
            t_event_ms: harness
                .earliest_event_for(1, t_click1)
                .map(|ts| ts.saturating_duration_since(t_click1).as_millis())
                .unwrap_or_else(|| t_click1.elapsed().as_millis()),
            t_audio_ms: 0,
        };
        if !is_baseline_mode() {
            assert_budget(&r5a);
        }
        rows.push(r5a);

        let r5b = BenchRow {
            profile: "RemotoUltraLento".to_string(),
            scenario: "S5b: clic 2 play(Track 3) tras 50ms".to_string(),
            t_snap_ms: click2_snap_ms.unwrap_or(click2_audio_ms),
            t_event_ms: click2_event_ms.unwrap_or(click2_audio_ms),
            t_audio_ms: click2_audio_ms,
        };
        assert_budget(&r5b);
        rows.push(r5b);
    }
    }

    println!("\n=== TRACK-SWITCH LATENCY SUMMARY (mode={}) ===", if is_baseline_mode() { "BASELINE" } else { "POST-FIX" });
    println!(
        "{:<24} | {:<40} | {:>10} | {:>11} | {:>11}",
        "Perfil", "Escenario", "t_snap(ms)", "t_event(ms)", "t_audio(ms)"
    );
    println!("{}", "-".repeat(106));
    for r in &rows {
        println!(
            "{:<24} | {:<40} | {:>10} | {:>11} | {:>11}",
            r.profile, r.scenario, r.t_snap_ms, r.t_event_ms, r.t_audio_ms
        );
    }
}

#[derive(Clone, Copy)]
enum MixedStepSpec {
    PlayPos { target: usize, settle_first: bool },
    PlayId { target: usize, settle_first: bool },
    Next { settle_first: bool },
    Autoplay,
}

#[derive(Clone)]
struct SuccessionRecord {
    step: usize,
    op_label: &'static str,
    from_idx: i64,
    to_idx: usize,
    from_fmt: &'static str,
    to_fmt: &'static str,
    settled_before: bool,
    latency_ms: u128,
    latency_us: u128,
}

fn build_mixed_108_schedule(queue_len: usize) -> Vec<MixedStepSpec> {
    let mut steps = Vec::with_capacity(108);
    // Step 1: initial play into index 0 (MP3 VBR)
    steps.push(MixedStepSpec::PlayPos {
        target: 0,
        settle_first: false,
    });
    let mut cur = 0usize;

    let autoplay_sources: [usize; 10] = [0, 1, 2, 4, 5, 9, 10, 12, 13, 14];
    let jump_offsets: [usize; 7] = [3, 7, 11, 5, 13, 2, 8];

    for (round, &ap_from) in autoplay_sources.iter().enumerate() {
        // 8 or 9 mixed rapid/settled steps before reaching `ap_from` for Autoplay
        let pre_count = if round < 7 { 8 } else { 7 };
        for i in 0..pre_count {
            let settle = i == 3;
            match (round + i) % 3 {
                0 => {
                    cur = (cur + 1) % queue_len;
                    steps.push(MixedStepSpec::Next {
                        settle_first: settle,
                    });
                }
                1 => {
                    let mut target = (cur + jump_offsets[(round + i) % jump_offsets.len()]) % queue_len;
                    if target == cur {
                        target = (cur + 1) % queue_len;
                    }
                    cur = target;
                    steps.push(MixedStepSpec::PlayPos {
                        target,
                        settle_first: settle,
                    });
                }
                _ => {
                    let mut target = (cur + queue_len - ((jump_offsets[(round * 2 + i) % jump_offsets.len()]) % queue_len)) % queue_len;
                    if target == cur {
                        target = (cur + 2) % queue_len;
                    }
                    cur = target;
                    steps.push(MixedStepSpec::PlayId {
                        target,
                        settle_first: settle,
                    });
                }
            }
        }

        // Navigate explicitly onto `ap_from` if not already there
        if cur != ap_from {
            steps.push(MixedStepSpec::PlayId {
                target: ap_from,
                settle_first: false,
            });
        } else {
            // Take one extra `Next` + `PlayPos(ap_from)` so step count remains >= 100 cleanly
            steps.push(MixedStepSpec::Next {
                settle_first: false,
            });
            steps.push(MixedStepSpec::PlayPos {
                target: ap_from,
                settle_first: false,
            });
        }

        // Real Autoplay transition: `ap_from` -> `(ap_from + 1) % queue_len`
        steps.push(MixedStepSpec::Autoplay);
        cur = (ap_from + 1) % queue_len;

        // Immediately fire `Next` or `PlayPos` right after Autoplay emits `CurrentIndex(cur)`
        if round % 2 == 0 {
            cur = (cur + 1) % queue_len;
            steps.push(MixedStepSpec::Next {
                settle_first: false,
            });
        } else {
            let mut target = (cur + 4) % queue_len;
            if target == cur {
                target = (cur + 1) % queue_len;
            }
            cur = target;
            steps.push(MixedStepSpec::PlayPos {
                target,
                settle_first: false,
            });
        }
    }

    // Pad with alternating rapid `Next` and `PlayId` until at least 108 mixed transitions
    let mut pad_i = 0usize;
    while steps.len() < 108 {
        if pad_i % 2 == 0 {
            cur = (cur + 1) % queue_len;
            steps.push(MixedStepSpec::Next {
                settle_first: false,
            });
        } else {
            let mut target = (cur + 6) % queue_len;
            if target == cur {
                target = (cur + 1) % queue_len;
            }
            cur = target;
            steps.push(MixedStepSpec::PlayId {
                target,
                settle_first: false,
            });
        }
        pad_i += 1;
    }

    steps
}

fn summarize_us(sorted_us: &[u128]) -> (f64, f64, f64, f64, f64, f64) {
    if sorted_us.is_empty() {
        return (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    }
    let n = sorted_us.len();
    let sum: u128 = sorted_us.iter().sum();
    let avg_ms = (sum as f64) / (n as f64) / 1000.0;
    let min_ms = sorted_us[0] as f64 / 1000.0;
    let pct = |p: usize| -> f64 {
        let idx = ((n - 1) * p) / 100;
        sorted_us[idx] as f64 / 1000.0
    };
    let max_ms = sorted_us[n - 1] as f64 / 1000.0;
    (min_ms, avg_ms, pct(50), pct(95), pct(99), max_ms)
}

#[test]
fn mixed_100_step_web_throttled_succession_test() {
    let dir = FixtureResolver::fixtures_dir();
    let server = PerfHttpServer::start(dir, Vec::new());

    // Configure throttled HTTP server (45ms RTT, 140ms open delay, 160 KB/s, 32 KB burst)
    // plus +600..700ms extra open delay on 5 distinct formats (OPUS, FLAC, M4A_ALAC, MKA, WAV).
    server.set_custom(140, 45, 160 * 1024, 32 * 1024);
    for spec in MIXED_WEB_CATALOG_15 {
        if spec.extra_open_delay_ms > 0 {
            server.set_extra_delay(spec.route, spec.extra_open_delay_ms);
        }
    }

    // -------------------------------------------------------------------------
    // Phase 1: Rust-authoritative queue mutations (including active-track remove_at)
    // -------------------------------------------------------------------------
    {
        let q_harness = PerfHarness::spawn();
        q_harness
            .engine
            .exec(|ply| ply.music_manager.set_crossfade(0, 0, 0))
            .expect("set_crossfade");
        let mut q_init: Vec<AudioSourceCore> = MIXED_WEB_CATALOG_15
            .iter()
            .take(5)
            .enumerate()
            .map(|(i, spec)| AudioSourceCore {
                id: (i as i64) + 100,
                source: format!("http://127.0.0.1:{}/{}", server.port, spec.route),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            })
            .collect();
        q_harness
            .coordinator
            .set_queue(q_init.clone(), q_harness.custom_factory())
            .expect("set_queue");

        let play_coord = q_harness.coordinator.clone();
        q_harness.clear_events();
        let t_p = Instant::now();
        let jh = thread::spawn(move || {
            let _ = play_coord.play(None, Some(0), None, None, false);
        });
        let ev_ts = q_harness
            .await_event_for(0, t_p, Duration::from_secs(3))
            .expect("initial play index 0");
        assert!(
            ev_ts.saturating_duration_since(t_p).as_millis() < STRICT_QUEUE_MARK_BUDGET_MS,
            "initial play exceeded budget"
        );
        let _ = jh.join();

        q_harness
            .coordinator
            .insert_next(AudioSourceCore {
                id: 500,
                source: format!("http://127.0.0.1:{}/{}", server.port, MIXED_WEB_CATALOG_15[5].route),
                headers: None,
                data_bytes: None,
                replay_gain_db: None,
                replay_peak: None,
                resolve_in_dart: false,
            })
            .expect("insert_next");
        assert!(q_harness.coordinator.reorder(1, 4).expect("reorder"));

        // Jump onto index 1 (OPUS +600ms delay) then remove active index 1 immediately:
        // provisional queue+index replacement MUST emit < 50 ms even before slow track opens!
        let _ = q_harness.coordinator.play(None, Some(1), None, None, false);
        q_harness.clear_events();
        let rem_coord = q_harness.coordinator.clone();
        let t_rem = Instant::now();
        let rem_jh = thread::spawn(move || rem_coord.remove_at(1, false));
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut saw_queue_change = false;
        while Instant::now() < deadline {
            let found = q_harness
                .events
                .lock()
                .expect("events lock")
                .iter()
                .any(|&(idx, ts, _)| idx == 1 && ts >= t_rem);
            if found && t_rem.elapsed().as_millis() < 200 {
                saw_queue_change = true;
                let dt = q_harness
                    .earliest_event_for(1, t_rem)
                    .unwrap()
                    .saturating_duration_since(t_rem)
                    .as_millis();
                assert!(
                    dt < STRICT_QUEUE_MARK_BUDGET_MS,
                    "remove_at active track provisional emit took {} ms",
                    dt
                );
                break;
            }
            thread::sleep(Duration::from_millis(1));
        }
        assert!(saw_queue_change, "remove_at did not emit provisional replacement index");
        let _ = rem_jh.join();
        q_init.clear();
    }

    // -------------------------------------------------------------------------
    // Phase 2: >= 100 mixed web-queue successions (play + next + autoplay)
    // across 15 formats under HTTP bandwidth & RTT throttling
    // -------------------------------------------------------------------------
    let schedule = build_mixed_108_schedule(MIXED_WEB_CATALOG_15.len());
    assert!(
        schedule.len() >= 100,
        "Expected >= 100 transitions, got {}",
        schedule.len()
    );

    let harness = PerfHarness::spawn();
    harness
        .engine
        .exec(|ply| {
            ply.music_manager.set_crossfade(0, 0, 0);
            ply.music_manager.set_loop_mode(2); // LoopMode::All for seamless wrap-around
        })
        .expect("configure engine");

    let queue: Vec<AudioSourceCore> = MIXED_WEB_CATALOG_15
        .iter()
        .enumerate()
        .map(|(i, spec)| AudioSourceCore {
            id: (i as i64) + 1000,
            source: format!("http://127.0.0.1:{}/{}", server.port, spec.route),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        })
        .collect();
    let ids: Vec<i64> = queue.iter().map(|q| q.id).collect();
    harness
        .coordinator
        .set_queue(queue, harness.custom_factory())
        .expect("set_queue 15");

    let mut records: Vec<SuccessionRecord> = Vec::with_capacity(schedule.len());
    let mut rpc_handles: Vec<JoinHandle<()>> = Vec::new();
    let mut cur_idx: i64 = -1;

    for (idx_0, step) in schedule.iter().enumerate() {
        let step_num = idx_0 + 1;

        match *step {
            MixedStepSpec::PlayPos {
                target,
                settle_first,
            } => {
                if settle_first && cur_idx >= 0 {
                    harness
                        .wait_track_audio_ready(cur_idx, Duration::from_secs(20))
                        .unwrap_or_else(|e| panic!("Step {} settle failed: {}", step_num, e));
                }
                assert_ne!(target as i64, cur_idx, "Schedule bug at step {}", step_num);
                let from_fmt = if cur_idx >= 0 {
                    MIXED_WEB_CATALOG_15[cur_idx as usize].format_label
                } else {
                    "STOPPED"
                };
                harness.clear_events();
                let t0 = Instant::now();
                let coord = harness.coordinator.clone();
                rpc_handles.retain(|h| !h.is_finished());
                rpc_handles.push(thread::spawn(move || {
                    let _ = coord.play(None, Some(target), None, None, false);
                }));
                let ev_ts = harness
                    .await_event_for(target as i64, t0, Duration::from_secs(5))
                    .unwrap_or_else(|| {
                        panic!("Step {} (play_pos -> {}) timed out waiting for index", step_num, target)
                    });
                let us = ev_ts.saturating_duration_since(t0).as_micros();
                let ms = ev_ts.saturating_duration_since(t0).as_millis();
                assert!(
                    ms < STRICT_QUEUE_MARK_BUDGET_MS,
                    "Step {} play_pos({}->{}) took {} ms (budget < {} ms)",
                    step_num, cur_idx, target, ms, STRICT_QUEUE_MARK_BUDGET_MS
                );
                records.push(SuccessionRecord {
                    step: step_num,
                    op_label: "play_pos",
                    from_idx: cur_idx,
                    to_idx: target,
                    from_fmt,
                    to_fmt: MIXED_WEB_CATALOG_15[target].format_label,
                    settled_before: settle_first,
                    latency_ms: ms,
                    latency_us: us,
                });
                cur_idx = target as i64;
            }
            MixedStepSpec::PlayId {
                target,
                settle_first,
            } => {
                if settle_first && cur_idx >= 0 {
                    harness
                        .wait_track_audio_ready(cur_idx, Duration::from_secs(20))
                        .unwrap_or_else(|e| panic!("Step {} settle failed: {}", step_num, e));
                }
                assert_ne!(target as i64, cur_idx, "Schedule bug at step {}", step_num);
                let from_fmt = if cur_idx >= 0 {
                    MIXED_WEB_CATALOG_15[cur_idx as usize].format_label
                } else {
                    "STOPPED"
                };
                let target_id = ids[target];
                harness.clear_events();
                let t0 = Instant::now();
                let coord = harness.coordinator.clone();
                rpc_handles.retain(|h| !h.is_finished());
                rpc_handles.push(thread::spawn(move || {
                    let _ = coord.play(Some(target_id), None, None, None, false);
                }));
                let ev_ts = harness
                    .await_event_for(target as i64, t0, Duration::from_secs(5))
                    .unwrap_or_else(|| {
                        panic!("Step {} (play_id -> {}) timed out waiting for index", step_num, target)
                    });
                let us = ev_ts.saturating_duration_since(t0).as_micros();
                let ms = ev_ts.saturating_duration_since(t0).as_millis();
                assert!(
                    ms < STRICT_QUEUE_MARK_BUDGET_MS,
                    "Step {} play_id({}->{}) took {} ms (budget < {} ms)",
                    step_num, cur_idx, target, ms, STRICT_QUEUE_MARK_BUDGET_MS
                );
                records.push(SuccessionRecord {
                    step: step_num,
                    op_label: "play_id",
                    from_idx: cur_idx,
                    to_idx: target,
                    from_fmt,
                    to_fmt: MIXED_WEB_CATALOG_15[target].format_label,
                    settled_before: settle_first,
                    latency_ms: ms,
                    latency_us: us,
                });
                cur_idx = target as i64;
            }
            MixedStepSpec::Next { settle_first } => {
                if settle_first && cur_idx >= 0 {
                    harness
                        .wait_track_audio_ready(cur_idx, Duration::from_secs(20))
                        .unwrap_or_else(|e| panic!("Step {} settle failed: {}", step_num, e));
                }
                let target = ((cur_idx.max(0) as usize) + 1) % MIXED_WEB_CATALOG_15.len();
                let from_fmt = MIXED_WEB_CATALOG_15[cur_idx as usize].format_label;
                harness.clear_events();
                let t0 = Instant::now();
                let coord = harness.coordinator.clone();
                rpc_handles.retain(|h| !h.is_finished());
                rpc_handles.push(thread::spawn(move || {
                    let _ = coord.next(None, false);
                }));
                let ev_ts = harness
                    .await_event_for(target as i64, t0, Duration::from_secs(5))
                    .unwrap_or_else(|| {
                        panic!("Step {} (next -> {}) timed out waiting for index", step_num, target)
                    });
                let us = ev_ts.saturating_duration_since(t0).as_micros();
                let ms = ev_ts.saturating_duration_since(t0).as_millis();
                assert!(
                    ms < STRICT_QUEUE_MARK_BUDGET_MS,
                    "Step {} next({}->{}) took {} ms (budget < {} ms)",
                    step_num, cur_idx, target, ms, STRICT_QUEUE_MARK_BUDGET_MS
                );
                records.push(SuccessionRecord {
                    step: step_num,
                    op_label: "next",
                    from_idx: cur_idx,
                    to_idx: target,
                    from_fmt,
                    to_fmt: MIXED_WEB_CATALOG_15[target].format_label,
                    settled_before: settle_first,
                    latency_ms: ms,
                    latency_us: us,
                });
                cur_idx = target as i64;
            }
            MixedStepSpec::Autoplay => {
                let dur_ms = harness
                    .wait_track_audio_ready(cur_idx, Duration::from_secs(25))
                    .unwrap_or_else(|e| panic!("Step {} autoplay track ready failed: {}", step_num, e));
                let target = ((cur_idx as usize) + 1) % MIXED_WEB_CATALOG_15.len();
                let from_fmt = MIXED_WEB_CATALOG_15[cur_idx as usize].format_label;
                let seek_tail = (dur_ms - 1800).clamp(0, (dur_ms * 99) / 100);
                harness
                    .coordinator
                    .seek(seek_tail)
                    .unwrap_or_else(|e| panic!("Step {} autoplay seek failed: {}", step_num, e));

                let (_, ev_ms, ev_us, _) = measure_eof_advance_pair(
                    &harness,
                    cur_idx,
                    target as i64,
                    dur_ms,
                    seek_tail,
                    Duration::from_secs(30),
                )
                .unwrap_or_else(|e| panic!("Step {} autoplay EOF failed: {}", step_num, e));
                assert!(
                    ev_ms < STRICT_QUEUE_MARK_BUDGET_MS,
                    "Step {} autoplay({}->{}) took {} ms (budget < {} ms)",
                    step_num, cur_idx, target, ev_ms, STRICT_QUEUE_MARK_BUDGET_MS
                );
                records.push(SuccessionRecord {
                    step: step_num,
                    op_label: "autoplay",
                    from_idx: cur_idx,
                    to_idx: target,
                    from_fmt,
                    to_fmt: MIXED_WEB_CATALOG_15[target].format_label,
                    settled_before: true,
                    latency_ms: ev_ms,
                    latency_us: ev_us,
                });
                cur_idx = target as i64;
            }
        }
    }

    // Drain any in-flight RPC threads cleanly before summary & teardown
    for h in rpc_handles {
        let _ = h.join();
    }

    let mut all_us: Vec<u128> = records.iter().map(|r| r.latency_us).collect();
    all_us.sort_unstable();
    let (all_min, all_avg, all_p50, all_p95, all_p99, all_max) = summarize_us(&all_us);

    println!(
        "\n=== RUST >=100-STEP MIXED THROTTLED WEB SUCCESSION BENCHMARK (N={}) ===",
        records.len()
    );
    println!(
        "Global: min={:.3} ms | avg(promedio)={:.3} ms | p50={:.3} ms | p95={:.3} ms | p99={:.3} ms | max={:.3} ms",
        all_min, all_avg, all_p50, all_p95, all_p99, all_max
    );

    for op in ["play_pos", "play_id", "next", "autoplay"] {
        let mut op_us: Vec<u128> = records
            .iter()
            .filter(|r| r.op_label == op)
            .map(|r| r.latency_us)
            .collect();
        op_us.sort_unstable();
        let (o_min, o_avg, o_p50, o_p95, o_p99, o_max) = summarize_us(&op_us);
        println!(
            "  Op {:<8} (n={:>2}): min={:.3} ms | avg={:.3} ms | p50={:.3} ms | p95={:.3} ms | p99={:.3} ms | max={:.3} ms",
            op,
            op_us.len(),
            o_min,
            o_avg,
            o_p50,
            o_p95,
            o_p99,
            o_max
        );
    }

    println!("  Unique Autoplay format transitions:");
    for r in records.iter().filter(|r| r.op_label == "autoplay") {
        println!(
            "    step {:>3} | autoplay | {:>2}({:<10}) -> {:>2}({:<10}) | {:>3} ms ({:>5} us)",
            r.step, r.from_idx, r.from_fmt, r.to_idx, r.to_fmt, r.latency_ms, r.latency_us
        );
    }

    let mut ranked = records.clone();
    ranked.sort_by(|a, b| b.latency_us.cmp(&a.latency_us));
    println!("  Top 15 slowest unique cases:");
    for r in ranked.iter().take(15) {
        println!(
            "    step {:>3} | {:<8} | {:>2}({:<10}) -> {:>2}({:<10}) | settled={} | {:>3} ms ({:>5} us)",
            r.step,
            r.op_label,
            r.from_idx,
            r.from_fmt,
            r.to_idx,
            r.to_fmt,
            r.settled_before,
            r.latency_ms,
            r.latency_us
        );
    }

    assert!(
        all_avg < 10.0,
        "Rust 108-step average latency too high: {:.3} ms (expected < 10.0 ms)",
        all_avg
    );
}
