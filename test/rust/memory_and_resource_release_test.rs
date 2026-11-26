//! Native Memory Usage and Deterministic Resource Release Tests.
//!
//! Verifies that:
//! 1. HTTP Range (`probe_fetcher`) and non-Range `StreamSession` instances do not leak via `Arc`
//!    reference cycles when decks reopen (`begin_open`), stop, or drop (`StreamingDeck::destroy`).
//! 2. Offline analysis decks allocate bounded `StreamSession` ring buffers (`<= 1 MiB` for standard
//!    headers) and release them cleanly after `analyze_audio_source`.
//! 3. `TelemetryDispatcher` does not spawn background OS worker threads unless a callback is
//!    registered, and tears down its worker cleanly on `stop()` / `drop()`.
//! 4. `EventReporter` coalesces and bounds queued events when no Dart stream sink is attached and
//!    releases retained metadata payloads on `clear_sink()`.
//! 5. Repeated local + HTTP track switches, acoustic analysis passes, and `RustMiniaudioPlayer`
//!    create/dispose lifecycles keep exact live Rust heap bytes, trimmed native RSS, and OS thread
//!    count flat rather than climbing linearly.
//! 6. `wasm_ureq_protocol::WasmStreamShared` drops cleanly without retaining linear memory buffers
//!    and computes wrap-around ring coordinates and response headers accurately.

mod common;

use std::alloc::{GlobalAlloc, Layout, System};
use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once, OnceLock, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use common::FixtureResolver;
use miniaudio_player::api::player::{EventReporter, RustMiniaudioPlayer};
use miniaudio_player::api::types::{
    RustAnalysisConfig, RustAudioMetadata, RustAudioPicture, RustAudioSource, RustPictureType,
    RustPlayerConfig, RustPlayerEvent,
};
use miniaudio_player::buffer::StreamBuffer;
use miniaudio_player::core::dual_source::{AudioSourceCore, StreamingDeck, MAP_ERROR_ABORTED};
use miniaudio_player::dsp::analysis::analyze_audio_source;
use miniaudio_player::net::wasm_ureq_protocol::{
    advance_ring_pos, decode_header_wire_bytes, ring_available, WasmStreamShared, CTRL_WAKE_RUST,
    HDR_CAP, RING_CAP, RING_MOD,
};
use miniaudio_player::sync::{TelemetryDispatcher, TelemetryEvent};

static LIVE_ALLOC_BYTES: AtomicUsize = AtomicUsize::new(0);

struct TrackingAllocator;

unsafe impl GlobalAlloc for TrackingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            LIVE_ALLOC_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE_ALLOC_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) };
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() {
            LIVE_ALLOC_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new_ptr = unsafe { System.realloc(ptr, layout, new_size) };
        if !new_ptr.is_null() {
            let old_size = layout.size();
            if new_size >= old_size {
                LIVE_ALLOC_BYTES.fetch_add(new_size - old_size, Ordering::Relaxed);
            } else {
                LIVE_ALLOC_BYTES.fetch_sub(old_size - new_size, Ordering::Relaxed);
            }
        }
        new_ptr
    }
}

#[global_allocator]
static GLOBAL_TRACKING_ALLOC: TrackingAllocator = TrackingAllocator;

#[inline]
fn live_alloc_bytes() -> usize {
    LIVE_ALLOC_BYTES.load(Ordering::Acquire)
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
extern "C" {
    fn malloc_trim(pad: usize) -> i32;
    fn mallopt(param: i32, value: i32) -> i32;
}

fn cap_native_malloc_arenas() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            const M_ARENA_MAX: i32 = -8;
            unsafe {
                let _ = mallopt(M_ARENA_MAX, 2);
            }
        });
    }
}

fn trim_native_allocator() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    unsafe {
        let _ = malloc_trim(0);
    }
}

/// Serializes process-wide `/proc/self/status` RSS, heap counter, and OS thread-count assertions.
static RESOURCE_TEST_LOCK: Mutex<()> = Mutex::new(());

type FixtureCatalog = Vec<(String, &'static str, Arc<[u8]>)>;
static FIXTURE_CATALOG: OnceLock<FixtureCatalog> = OnceLock::new();

const FIXTURES: &[(&str, &str)] = &[
    ("01_Apex_Momentum.mp3", "audio/mpeg"),
    ("04_Belaya_Tishina.flac", "audio/flac"),
    ("05_Burning_in_the_Electric_Light.ogg", "audio/ogg"),
    ("17_Running_To_Meet_The_Sun.wav", "audio/wav"),
];

fn shared_fixture_catalog() -> &'static FixtureCatalog {
    FIXTURE_CATALOG.get_or_init(|| {
        let mut loaded: FixtureCatalog = Vec::with_capacity(FIXTURES.len());
        for &(name, mime) in FIXTURES {
            let path = FixtureResolver::resolve(name);
            let bytes = std::fs::read(&path)
                .unwrap_or_else(|e| panic!("Failed reading fixture {:?}: {}", path, e));
            loaded.push((name.to_string(), mime, Arc::from(bytes)));
        }
        loaded
    })
}

struct EmbeddedHttpServer {
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
    acceptor: Option<JoinHandle<()>>,
    workers: Arc<Mutex<Vec<JoinHandle<()>>>>,
}

impl EmbeddedHttpServer {
    fn start() -> Self {
        let catalog: &'static FixtureCatalog = shared_fixture_catalog();

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback HTTP server");
        let addr = listener.local_addr().expect("loopback local_addr");
        let stop = Arc::new(AtomicBool::new(false));
        let stop_accept = stop.clone();
        let workers: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::new(Mutex::new(Vec::new()));
        let workers_accept = workers.clone();

        let acceptor = thread::Builder::new()
            .name("test-http-accept".to_string())
            .spawn(move || {
                for stream_res in listener.incoming() {
                    if stop_accept.load(Ordering::Acquire) {
                        break;
                    }
                    let Ok(stream) = stream_res else {
                        continue;
                    };
                    if let Ok(jh) = thread::Builder::new()
                        .name("test-http-conn".to_string())
                        .spawn(move || handle_http_connection(stream, catalog))
                    {
                        let mut guard = workers_accept.lock().unwrap_or_else(|e| e.into_inner());
                        guard.retain(|h| !h.is_finished());
                        guard.push(jh);
                    }
                }
            })
            .expect("spawn HTTP acceptor");

        Self {
            addr,
            stop,
            acceptor: Some(acceptor),
            workers,
        }
    }

    fn range_url(&self, filename: &str) -> String {
        format!("http://{}/range/{}", self.addr, filename)
    }

    fn norange_url(&self, filename: &str) -> String {
        format!("http://{}/norange/{}", self.addr, filename)
    }

    fn wait_handlers_finished(&self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = {
                let mut guard = self.workers.lock().unwrap_or_else(|e| e.into_inner());
                let mut finished = Vec::new();
                let mut active = Vec::new();
                for h in guard.drain(..) {
                    if h.is_finished() {
                        finished.push(h);
                    } else {
                        active.push(h);
                    }
                }
                *guard = active;
                let count = guard.len();
                drop(guard);
                for h in finished {
                    let _ = h.join();
                }
                count
            };
            if remaining == 0 || Instant::now() >= deadline {
                break;
            }
            thread::sleep(Duration::from_millis(15));
        }
    }
}

impl Drop for EmbeddedHttpServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.addr);
        if let Some(acc) = self.acceptor.take() {
            let _ = acc.join();
        }
        let handles: Vec<JoinHandle<()>> = {
            let mut guard = self.workers.lock().unwrap_or_else(|e| e.into_inner());
            std::mem::take(&mut *guard)
        };
        for h in handles {
            let _ = h.join();
        }
    }
}

fn handle_http_connection(mut stream: TcpStream, catalog: &[(String, &'static str, Arc<[u8]>)]) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));

    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });

    let mut request_line = String::new();
    if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
        return;
    }
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();

    let mut range_hdr: Option<String> = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            break;
        }
        if let Some((k, v)) = trimmed.split_once(':') {
            if k.trim().eq_ignore_ascii_case("range") {
                range_hdr = Some(v.trim().to_string());
            }
        }
    }

    let (allow_range, filename) = if let Some(rest) = path.strip_prefix("/range/") {
        (true, rest)
    } else if let Some(rest) = path.strip_prefix("/norange/") {
        (false, rest)
    } else {
        let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };

    let Some((_, mime, bytes)) = catalog.iter().find(|(n, _, _)| n == filename) else {
        let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };

    let total = bytes.len();
    if allow_range {
        if let Some(rh) = range_hdr {
            if let Some((s, e)) = parse_byte_range(&rh, total) {
                let slice = &bytes[s..=e];
                let hdr = format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Type: {}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {}-{}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    mime, s, e, total, slice.len()
                );
                if stream.write_all(hdr.as_bytes()).is_ok() {
                    let _ = write_chunked_interruptible(&mut stream, slice);
                }
                return;
            }
            let hdr = format!(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                total
            );
            let _ = stream.write_all(hdr.as_bytes());
            return;
        }
    }

    let accept_ranges = if allow_range { "bytes" } else { "none" };
    let hdr = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nAccept-Ranges: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        mime, accept_ranges, total
    );
    if stream.write_all(hdr.as_bytes()).is_ok() {
        let _ = write_chunked_interruptible(&mut stream, bytes);
    }
}

fn write_chunked_interruptible(stream: &mut TcpStream, data: &[u8]) -> std::io::Result<()> {
    for chunk in data.chunks(64 * 1024) {
        stream.write_all(chunk)?;
    }
    Ok(())
}

fn parse_byte_range(header: &str, total: usize) -> Option<(usize, usize)> {
    if total == 0 {
        return None;
    }
    let spec = header.trim().strip_prefix("bytes=")?;
    let (s_str, e_str) = spec.split_once('-')?;
    if s_str.is_empty() {
        let suffix: usize = e_str.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        let start = total.saturating_sub(suffix);
        return Some((start, total - 1));
    }
    let start: usize = s_str.parse().ok()?;
    let end: usize = if e_str.is_empty() {
        total - 1
    } else {
        e_str.parse().ok()?
    };
    if start >= total || start > end {
        return None;
    }
    Some((start, end.min(total - 1)))
}

#[cfg(target_os = "linux")]
fn read_proc_status_metrics() -> Option<(usize, usize)> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let mut rss_kb: Option<usize> = None;
    let mut threads: Option<usize> = None;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            let num_str = rest.split_whitespace().next()?;
            rss_kb = num_str.parse::<usize>().ok();
        } else if let Some(rest) = line.strip_prefix("Threads:") {
            let num_str = rest.split_whitespace().next()?;
            threads = num_str.parse::<usize>().ok();
        }
    }
    Some((rss_kb? * 1024, threads?))
}

#[cfg(not(target_os = "linux"))]
fn read_proc_status_metrics() -> Option<(usize, usize)> {
    None
}

fn wait_weak_released(
    body: &Weak<StreamBuffer>,
    head: &Weak<StreamBuffer>,
    metadata: &Weak<StreamBuffer>,
    timeout: Duration,
) -> (usize, usize, usize) {
    let deadline = Instant::now() + timeout;
    loop {
        let counts = (body.strong_count(), head.strong_count(), metadata.strong_count());
        if counts == (0, 0, 0) || Instant::now() >= deadline {
            return counts;
        }
        thread::sleep(Duration::from_millis(15));
    }
}

fn wait_threads_settle(target_max: usize, timeout: Duration) -> Option<(usize, usize)> {
    let deadline = Instant::now() + timeout;
    loop {
        let m = read_proc_status_metrics()?;
        if m.1 <= target_max || Instant::now() >= deadline {
            return Some(m);
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn poll_until(timeout: Duration, mut pred: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while !pred() {
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(15));
    }
    true
}

#[test]
fn test_network_stream_session_is_freed_on_deck_reopen_and_drop() {
    let _guard = RESOURCE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let server = EmbeddedHttpServer::start();

    type WeakSessionEntry = (
        &'static str,
        Weak<StreamBuffer>,
        Weak<StreamBuffer>,
        Weak<StreamBuffer>,
    );
    let mut sessions_weak: Vec<WeakSessionEntry> = Vec::new();

    // 1. Playback deck opening Range-capable HTTP streams -> begin_open() + destroy() must drop all Arcs.
    {
        let mut deck = StreamingDeck::new_deck(48_000, 2, 1024).expect("new_deck");
        for &(file, kind) in &[("01_Apex_Momentum.mp3", "playback-range-1"), ("04_Belaya_Tishina.flac", "playback-range-2")] {
            let res = deck.open_network_with_cancel(&server.range_url(file), None, None);
            assert_eq!(res, 0, "open_network_with_cancel failed for {}: {}", file, res);
            let session = deck
                .stream_session
                .read()
                .unwrap()
                .as_ref()
                .expect("stream_session present")
                .clone();
            assert!(
                session.has_probe_fetcher(),
                "Range HTTP fixture {} must install probe_fetcher (exercises Arc cycle path)",
                file
            );
            sessions_weak.push((
                kind,
                Arc::downgrade(&session.body),
                Arc::downgrade(&session.head),
                Arc::downgrade(&session.metadata),
            ));
            drop(session);
        }

        // Non-Range HTTP stream must also release cleanly.
        let res = deck.open_network_with_cancel(&server.norange_url("05_Burning_in_the_Electric_Light.ogg"), None, None);
        assert_eq!(res, 0, "non-Range open failed: {}", res);
        let nonrange_session = deck
            .stream_session
            .read()
            .unwrap()
            .as_ref()
            .expect("non-range stream_session")
            .clone();
        sessions_weak.push((
            "playback-norange",
            Arc::downgrade(&nonrange_session.body),
            Arc::downgrade(&nonrange_session.head),
            Arc::downgrade(&nonrange_session.metadata),
        ));
        drop(nonrange_session);

        // `begin_open` / `open_file` replaces active HTTP session immediately.
        let wav_path = FixtureResolver::resolve_str("17_Running_To_Meet_The_Sun.wav");
        assert_eq!(deck.open_file(&wav_path), 0);
        assert_ne!(deck.play(), MAP_ERROR_ABORTED);
        deck.stop();
        deck.destroy();
    }

    // 2. Analysis deck opening Range-capable HTTP stream must cap ring <= 1 MiB (when header fits)
    //    and drop completely once the analysis deck is dropped.
    {
        let mut analysis_deck =
            StreamingDeck::new_analysis_deck(48_000, 2).expect("new_analysis_deck");
        let res = analysis_deck.open_network_with_cancel(
            &server.range_url("04_Belaya_Tishina.flac"),
            None,
            None,
        );
        assert_eq!(res, 0, "analysis open_network failed: {}", res);
        let session = analysis_deck
            .stream_session
            .read()
            .unwrap()
            .as_ref()
            .expect("analysis stream_session")
            .clone();
        let (_, _, cap) = session.body.circular_metrics();
        assert!(
            cap <= 2 * 1024 * 1024,
            "Analysis deck should not allocate full 8 MiB ring unnecessarily (got {} bytes)",
            cap
        );
        sessions_weak.push((
            "analysis-range",
            Arc::downgrade(&session.body),
            Arc::downgrade(&session.head),
            Arc::downgrade(&session.metadata),
        ));
        drop(session);
        analysis_deck.destroy();
    }

    for (label, body_w, head_w, meta_w) in &sessions_weak {
        let counts = wait_weak_released(body_w, head_w, meta_w, Duration::from_secs(3));
        assert_eq!(
            counts,
            (0, 0, 0),
            "StreamSession leaked for '{}': remaining strong counts (body, head, metadata) = {:?}",
            label,
            counts
        );
    }
    server.wait_handlers_finished(Duration::from_secs(2));
}

#[test]
fn test_telemetry_dispatcher_lazy_thread_spawn_and_cleanup() {
    let _guard = RESOURCE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // Wait briefly for any prior test threads to settle before sampling baseline.
    let before = wait_threads_settle(usize::MAX, Duration::from_millis(50));

    let dispatchers: Vec<TelemetryDispatcher> =
        (0..16).map(|_| TelemetryDispatcher::new()).collect();
    for d in &dispatchers {
        for i in 0..50 {
            d.post(TelemetryEvent::Position(i * 10));
        }
    }

    if let (Some((_, threads_before)), Some((_, threads_during))) =
        (before, read_proc_status_metrics())
    {
        assert!(
            threads_during <= threads_before + 2,
            "TelemetryDispatcher without callbacks should spawn lazily (before={}, with_16_dispatchers={})",
            threads_before,
            threads_during
        );
    }

    // Attaching a callback lazily starts the worker and delivers events, and stop() cleans it up.
    let delivered = Arc::new(AtomicUsize::new(0));
    let delivered_cb = delivered.clone();
    dispatchers[0].set_typed_callback(Some(Box::new(move |_| {
        delivered_cb.fetch_add(1, Ordering::Relaxed);
    })));
    dispatchers[0].post(TelemetryEvent::IsPlaying(true));
    assert!(
        poll_until(Duration::from_secs(2), || delivered.load(Ordering::Relaxed) >= 1),
        "Lazy TelemetryDispatcher failed to deliver event after callback registration"
    );

    for d in dispatchers {
        d.stop();
    }
}

#[test]
fn test_event_reporter_bounds_pending_queue_without_sink() {
    let _guard = RESOURCE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let reporter = EventReporter::new();

    let make_meta = |i: usize| RustAudioMetadata {
        title: Some(format!("Track {}", i)),
        pictures: vec![RustAudioPicture {
            picture_type: RustPictureType::CoverFront,
            mime_type: None,
            description: None,
            bytes: vec![(i & 0xFF) as u8; 128 * 1024],
        }],
        ..Default::default()
    };

    // Warmup allocation containers before baseline sampling.
    reporter.emit(RustPlayerEvent::AudioMetadata(make_meta(0)));
    reporter.clear_sink();
    trim_native_allocator();
    let base_live = live_alloc_bytes();

    // Emit 64 distinct 128 KiB metadata payloads (~8 MiB total if uncoalesced) plus 200 positions.
    for i in 1..=64 {
        reporter.emit(RustPlayerEvent::AudioMetadata(make_meta(i)));
    }
    for i in 1..=200i64 {
        reporter.emit(RustPlayerEvent::Position(i * 100));
    }

    let during_live = live_alloc_bytes().saturating_sub(base_live);
    println!(
        "[RESOURCE_TEST] EventReporter pending without sink: during_delta={:.1} KiB",
        during_live as f64 / 1024.0
    );
    assert!(
        during_live < 1024 * 1024,
        "EventReporter retained unbounded pending events without sink: delta={} bytes",
        during_live
    );

    reporter.clear_sink();
    trim_native_allocator();
    let after_clear_live = live_alloc_bytes().saturating_sub(base_live);
    assert!(
        after_clear_live < 256 * 1024,
        "EventReporter::clear_sink() did not release cached/pending metadata: remaining={} bytes",
        after_clear_live
    );
}

#[test]
fn test_native_http_and_local_track_switches_and_analysis_stabilize_memory_and_threads() {
    let _guard = RESOURCE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    cap_native_malloc_arenas();
    let server = EmbeddedHttpServer::start();

    let player = RustMiniaudioPlayer::new(
        RustPlayerConfig::default(),
        48_000,
        2,
        1024,
        vec![],
    )
    .expect("create headless RustMiniaudioPlayer");
    player.set_metadata_enabled(true);

    let local_mp3 = FixtureResolver::resolve_str("01_Apex_Momentum.mp3");
    let local_flac = FixtureResolver::resolve_str("04_Belaya_Tishina.flac");
    let queue_sources = vec![
        RustAudioSource {
            id: 1,
            source: server.range_url("01_Apex_Momentum.mp3"),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
        RustAudioSource {
            id: 2,
            source: server.range_url("04_Belaya_Tishina.flac"),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
        RustAudioSource {
            id: 3,
            source: server.norange_url("05_Burning_in_the_Electric_Light.ogg"),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
        RustAudioSource {
            id: 4,
            source: local_mp3,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
        RustAudioSource {
            id: 5,
            source: local_flac,
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
    ];
    player.set_queue(queue_sources).expect("set_queue");

    let analysis_cfg = RustAnalysisConfig {
        replay_gain: true,
        waveform: true,
        metadata: true,
        chromaprint: false,
        waveform_points: 64,
        target_lufs: -18.0,
        max_duration_ms: Some(1500),
    };
    let analysis_sources = [
        AudioSourceCore {
            id: 100,
            source: server.range_url("01_Apex_Momentum.mp3"),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
        AudioSourceCore {
            id: 101,
            source: server.range_url("04_Belaya_Tishina.flac"),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
            resolve_in_dart: false,
        },
    ];

    // Warmup 1 full 5-track cycle + 2 HTTP analyses to establish symmetric allocator & pool steady state.
    for i in 0..5 {
        let id = (i % 5) as i64 + 1;
        player.play(Some(id), None, None, None).expect("warmup play");
        let _ = player.seek(1500);
        player.stop();
        if i < 2 {
            let _ = analyze_audio_source(analysis_sources[i % 2].clone(), analysis_cfg.clone())
                .expect("warmup analyze");
        }
    }
    server.wait_handlers_finished(Duration::from_secs(2));
    thread::sleep(Duration::from_millis(200));
    trim_native_allocator();
    let base_live = live_alloc_bytes();
    let baseline = read_proc_status_metrics();

    // Stress 20 track switches across Range HTTP, non-Range HTTP, and local files + 10 HTTP analyses.
    for i in 0..20 {
        let id = (i % 5) as i64 + 1;
        player.play(Some(id), None, None, None).expect("switch play");
        if i % 2 == 0 {
            let _ = player.seek(2000);
        }
        player.stop();
        if i % 2 == 0 {
            let res = analyze_audio_source(
                analysis_sources[(i / 2) % analysis_sources.len()].clone(),
                analysis_cfg.clone(),
            )
            .expect("http analyze");
            assert!(res.audio_info.sample_rate > 0);
        }
    }

    player.stop();
    server.wait_handlers_finished(Duration::from_secs(2));
    if let Some((_, base_t)) = baseline {
        let _ = wait_threads_settle(base_t + 2, Duration::from_millis(600));
    }
    trim_native_allocator();
    let after_live = live_alloc_bytes();
    let settled = read_proc_status_metrics();

    let live_delta = after_live.saturating_sub(base_live);
    if let (Some((base_rss, base_threads)), Some((after_rss, after_threads))) = (baseline, settled) {
        let rss_delta = after_rss.saturating_sub(base_rss);
        println!(
            "[RESOURCE_TEST] switches+analysis: live_heap {:.2} -> {:.2} MiB (delta={:.2} MiB), trimmed_rss={:.1} -> {:.1} MiB (delta={:.1} MiB), threads {} -> {}",
            base_live as f64 / (1024.0 * 1024.0),
            after_live as f64 / (1024.0 * 1024.0),
            live_delta as f64 / (1024.0 * 1024.0),
            base_rss as f64 / (1024.0 * 1024.0),
            after_rss as f64 / (1024.0 * 1024.0),
            rss_delta as f64 / (1024.0 * 1024.0),
            base_threads,
            after_threads
        );
        assert!(
            rss_delta < 32 * 1024 * 1024,
            "Trimmed RSS grew too much after 20 track switches + 10 HTTP analyses: delta={} MiB (base={}, after={})",
            rss_delta / (1024 * 1024),
            base_rss,
            after_rss
        );
        assert!(
            after_threads <= base_threads + 4,
            "Live thread count grew across switches: before={}, after={}",
            base_threads,
            after_threads
        );
    }
    assert!(
        live_delta < 4 * 1024 * 1024,
        "Live Rust heap grew across 20 switches + 10 analyses: base={} bytes, after={} bytes, delta={} bytes",
        base_live,
        after_live,
        live_delta
    );

    player.dispose();
    if let Some((_, base_t)) = baseline {
        let _ = wait_threads_settle(base_t, Duration::from_millis(600));
    }
    trim_native_allocator();
    let post_dispose_live = live_alloc_bytes();
    if let (Some((_, base_threads)), Some((_, final_threads))) =
        (baseline, read_proc_status_metrics())
    {
        assert!(
            final_threads <= base_threads + 2,
            "Threads remained alive after player.dispose(): baseline={}, after_dispose={}",
            base_threads,
            final_threads
        );
    }
    assert!(
        post_dispose_live <= base_live + 2 * 1024 * 1024,
        "Live Rust heap remained elevated after player.dispose(): base={} bytes, post_dispose={} bytes",
        base_live,
        post_dispose_live
    );
}

#[test]
fn test_player_create_and_dispose_cycles_release_threads_and_memory() {
    let _guard = RESOURCE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    cap_native_malloc_arenas();
    let server = EmbeddedHttpServer::start();
    let wav_path = FixtureResolver::resolve_str("17_Running_To_Meet_The_Sun.wav");
    let range_mp3 = server.range_url("01_Apex_Momentum.mp3");

    let run_cycle = |cycle_idx: usize| {
        let player = RustMiniaudioPlayer::new(
            RustPlayerConfig::default(),
            48_000,
            2,
            1024,
            vec![],
        )
        .unwrap_or_else(|e| panic!("cycle {} new() failed: {}", cycle_idx, e));
        player
            .set_queue(vec![
                RustAudioSource {
                    id: 1,
                    source: range_mp3.clone(),
                    headers: None,
                    data_bytes: None,
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
                RustAudioSource {
                    id: 2,
                    source: wav_path.clone(),
                    headers: None,
                    data_bytes: None,
                    replay_gain_db: None,
                    replay_peak: None,
                    resolve_in_dart: false,
                },
            ])
            .expect("cycle set_queue");
        player.play(Some(1), None, None, None).expect("cycle play HTTP");
        let _ = player.seek(1000);
        player.play(Some(2), None, None, None).expect("cycle play WAV");
        player.stop();
        player.dispose();
    };

    // Warmup 2 lifecycles before baseline measurement.
    for i in 0..2 {
        run_cycle(i);
    }
    server.wait_handlers_finished(Duration::from_secs(2));
    thread::sleep(Duration::from_millis(200));
    trim_native_allocator();
    let base_live = live_alloc_bytes();
    let baseline = read_proc_status_metrics();

    for i in 2..10 {
        run_cycle(i);
    }
    server.wait_handlers_finished(Duration::from_secs(2));
    if let Some((_, base_t)) = baseline {
        let _ = wait_threads_settle(base_t + 1, Duration::from_millis(750));
    }
    trim_native_allocator();
    let after_live = live_alloc_bytes();
    let after = read_proc_status_metrics();

    let live_delta = after_live.saturating_sub(base_live);
    if let (Some((base_rss, base_threads)), Some((after_rss, after_threads))) = (baseline, after) {
        let rss_delta = after_rss.saturating_sub(base_rss);
        println!(
            "[RESOURCE_TEST] create/dispose x8: live_heap {:.2} -> {:.2} MiB (delta={:.2} MiB), trimmed_rss={:.1} -> {:.1} MiB (delta={:.1} MiB), threads {} -> {}",
            base_live as f64 / (1024.0 * 1024.0),
            after_live as f64 / (1024.0 * 1024.0),
            live_delta as f64 / (1024.0 * 1024.0),
            base_rss as f64 / (1024.0 * 1024.0),
            after_rss as f64 / (1024.0 * 1024.0),
            rss_delta as f64 / (1024.0 * 1024.0),
            base_threads,
            after_threads
        );
        assert!(
            rss_delta < 24 * 1024 * 1024,
            "Trimmed RSS grew across 8 player create/dispose cycles: delta={} MiB",
            rss_delta / (1024 * 1024)
        );
        assert!(
            after_threads <= base_threads + 2,
            "Thread leak across player create/dispose cycles: base={}, after={}",
            base_threads,
            after_threads
        );
    }
    assert!(
        live_delta < 2 * 1024 * 1024,
        "Live Rust heap grew across 8 player create/dispose cycles: base={} bytes, after={} bytes, delta={} bytes",
        base_live,
        after_live,
        live_delta
    );
}

#[test]
fn test_wasm_ureq_protocol_shared_buffer_drop_and_ring_math() {
    let weak = {
        let shared = Arc::new(WasmStreamShared::new(42));
        assert_eq!(shared.id, 42);
        assert!(shared.ctrl_ptr() > 0);
        assert!(shared.ring_ptr() > 0);
        assert!(shared.hdr_ptr() > 0);
        shared.ctrl[CTRL_WAKE_RUST].store(3, Ordering::Release);
        assert_eq!(shared.ctrl[CTRL_WAKE_RUST].load(Ordering::Acquire), 3);
        let w = Arc::downgrade(&shared);
        assert_eq!(w.strong_count(), 1);
        w
    };
    assert_eq!(weak.strong_count(), 0, "WasmStreamShared did not deallocate on drop");

    // Verify mirror-bit SPSC coordinate wrapping across RING_CAP / RING_MOD.
    let r = (RING_CAP as u32) - 1024;
    let w = advance_ring_pos(r, 2048);
    assert_eq!(ring_available(w, r), 2048);
    let w_full = advance_ring_pos(0, RING_CAP);
    assert_eq!(ring_available(w_full, 0), RING_CAP);
    assert_eq!(advance_ring_pos(RING_MOD - 16, 32), 16);

    // Verify header wire decoding.
    let wire = b"Content-Type\0audio/mpeg\nAccept-Ranges\0bytes\n\nContent-Length\0 12345 \n";
    let decoded = decode_header_wire_bytes(wire);
    assert_eq!(
        decoded,
        vec![
            ("content-type".to_string(), "audio/mpeg".to_string()),
            ("accept-ranges".to_string(), "bytes".to_string()),
            ("content-length".to_string(), "12345".to_string()),
        ]
    );
    const { assert!(HDR_CAP >= 8192); }
}
