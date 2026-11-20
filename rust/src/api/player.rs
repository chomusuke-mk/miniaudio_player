//! Native Miniaudio Player API exposed to Flutter/Dart via flutter_rust_bridge.
//!
//! Exposes `RustMiniaudioPlayer` orchestrating music decks, RAM sound effects,
//! multi-destination output matrix, and microphone capture sidechain.

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use crate::sync::thread::{self, JoinHandle};
use std::time::Duration;
use crate::sync::MonotonicInstant as Instant;

use crate::buffer::{
    CustomDartByteSource, CustomSourceRegistry, DartResolveRegistry, ResolvedCoreSource,
};
use crate::core::control_coordinator::ControlCoordinator;
use crate::core::dual_source::{AudioSourceCore, CustomSourceFactory};
use crate::core::engine_actor::{
    snapshot_queue_ids, EngineActorHandle, EngineUiSnapshots, RtEngineNotice,
    TrackTransitionSnapshot,
};
use crate::core::hw_supervisor::{device_id_matches, HardwareDeviceSupervisor};
use crate::core::recording::RecordingEncoding;
use crate::core::types::PlaybackState;
use crate::core::voice_pool::{EffectCatalogItem, EffectConfig};
use crate::dsp::equalizer::EqualizerParams;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::SilenceConfig;
use crate::frb_generated::StreamSink;
use crate::map_log;
use crate::sync::{lock_unpoisoned, read_unpoisoned, write_unpoisoned};

use super::types::*;

#[flutter_rust_bridge::frb(ignore)]
struct FrbTapChunkSink {
    sink: StreamSink<RustAudioTapChunk>,
}

#[flutter_rust_bridge::frb(ignore)]
impl crate::core::tap::TapChunkSink for FrbTapChunkSink {
    fn send_chunk(&self, chunk: crate::core::tap::TapChunk) -> bool {
        let msg = RustAudioTapChunk {
            source: chunk.source,
            format: chunk.format as i32,
            sample_rate: chunk.sample_rate,
            channels: chunk.channels as u32,
            frame_count: chunk.frame_count,
            dropped_frames: chunk.dropped_frames,
            bytes: chunk.bytes,
        };
        self.sink.add(msg).is_ok()
    }
}

#[flutter_rust_bridge::frb(ignore)]
const SENTINEL_NONE: i64 = i64::MIN;
const OPT_BOOL_FALSE: u8 = 1;
const OPT_BOOL_TRUE: u8 = 2;

#[flutter_rust_bridge::frb(ignore)]
fn parse_recording_format(format: i32) -> Result<RecordingEncoding, String> {
    RecordingEncoding::from_wire_code(format)
}

#[inline]
fn encode_opt_bool(v: bool) -> u8 {
    if v { OPT_BOOL_TRUE } else { OPT_BOOL_FALSE }
}

#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct ComplexTelemetryCache {
    replay_gain: Option<(u32, u32)>,
    metadata: Option<RustAudioMetadata>,
    audio_info: Option<RustAudioInfo>,
    visualizer: Option<RustVisualizerData>,
}

#[flutter_rust_bridge::frb(ignore)]
struct AtomicTelemetryFilter {
    state: AtomicI64,
    pos: AtomicI64,
    index: AtomicI64,
    buffered_start: AtomicI64,
    buffered_end: AtomicI64,
    is_buffering: AtomicU8,
    buffer_is_buffering: AtomicU8,
    is_xfading: AtomicU8,
    is_recording: AtomicU8,
    recorded_duration: AtomicU64,
    is_ducking: AtomicU8,
    is_playing: AtomicU8,
    active_voices: AtomicI64,
    complex: Mutex<ComplexTelemetryCache>,
}

#[flutter_rust_bridge::frb(ignore)]
impl Default for AtomicTelemetryFilter {
    fn default() -> Self {
        Self {
            state: AtomicI64::new(0),
            pos: AtomicI64::new(0),
            index: AtomicI64::new(-1),
            buffered_start: AtomicI64::new(SENTINEL_NONE),
            buffered_end: AtomicI64::new(SENTINEL_NONE),
            is_buffering: AtomicU8::new(OPT_BOOL_FALSE),
            buffer_is_buffering: AtomicU8::new(OPT_BOOL_FALSE),
            is_xfading: AtomicU8::new(OPT_BOOL_FALSE),
            is_recording: AtomicU8::new(OPT_BOOL_FALSE),
            recorded_duration: AtomicU64::new(0),
            is_ducking: AtomicU8::new(OPT_BOOL_FALSE),
            is_playing: AtomicU8::new(OPT_BOOL_FALSE),
            active_voices: AtomicI64::new(SENTINEL_NONE),
            complex: Mutex::new(ComplexTelemetryCache::default()),
        }
    }
}

#[flutter_rust_bridge::frb(ignore)]
impl AtomicTelemetryFilter {
    fn reset(&self) {
        self.state.store(0, Ordering::Release);
        self.pos.store(0, Ordering::Release);
        self.index.store(-1, Ordering::Release);
        self.buffered_start.store(SENTINEL_NONE, Ordering::Release);
        self.buffered_end.store(SENTINEL_NONE, Ordering::Release);
        self.is_buffering.store(OPT_BOOL_FALSE, Ordering::Release);
        self.buffer_is_buffering
            .store(OPT_BOOL_FALSE, Ordering::Release);
        self.is_xfading.store(OPT_BOOL_FALSE, Ordering::Release);
        self.is_recording.store(OPT_BOOL_FALSE, Ordering::Release);
        self.recorded_duration.store(0, Ordering::Release);
        self.is_ducking.store(OPT_BOOL_FALSE, Ordering::Release);
        self.is_playing.store(OPT_BOOL_FALSE, Ordering::Release);
        self.active_voices.store(SENTINEL_NONE, Ordering::Release);
        *lock_unpoisoned(&self.complex) = ComplexTelemetryCache::default();
    }

    #[inline]
    fn should_emit_opt_bool(slot: &AtomicU8, val: bool) -> bool {
        let encoded = encode_opt_bool(val);
        slot.swap(encoded, Ordering::AcqRel) != encoded
    }

    #[inline]
    fn should_emit_i64(slot: &AtomicI64, val: i64) -> bool {
        slot.swap(val, Ordering::AcqRel) != val
    }

    #[inline]
    fn should_emit_u64(slot: &AtomicU64, val: u64) -> bool {
        slot.swap(val, Ordering::AcqRel) != val
    }

    fn should_emit(&self, event: &RustPlayerEvent) -> bool {
        match event {
            RustPlayerEvent::PlaybackState(s) => Self::should_emit_i64(&self.state, *s as i64),
            RustPlayerEvent::CurrentIndex(idx) => {
                if Self::should_emit_i64(&self.index, *idx as i64) {
                    self.buffered_start.store(SENTINEL_NONE, Ordering::Release);
                    self.buffered_end.store(SENTINEL_NONE, Ordering::Release);
                    let mut complex = lock_unpoisoned(&self.complex);
                    complex.audio_info = None;
                    complex.metadata = None;
                    true
                } else {
                    false
                }
            }
            RustPlayerEvent::IsPlaying(b) => Self::should_emit_opt_bool(&self.is_playing, *b),
            RustPlayerEvent::IsBuffering(b) => Self::should_emit_opt_bool(&self.is_buffering, *b),
            RustPlayerEvent::IsCrossfading(b) => Self::should_emit_opt_bool(&self.is_xfading, *b),
            RustPlayerEvent::IsRecording(b) => Self::should_emit_opt_bool(&self.is_recording, *b),
            RustPlayerEvent::RecordedDuration(d) => {
                Self::should_emit_u64(&self.recorded_duration, *d)
            }
            RustPlayerEvent::IsDuckingActive(b) => Self::should_emit_opt_bool(&self.is_ducking, *b),
            RustPlayerEvent::ActiveVoices(v) => {
                Self::should_emit_i64(&self.active_voices, *v as i64)
            }
            RustPlayerEvent::Buffer(r) => {
                let prev_start = self.buffered_start.swap(r.start_ms, Ordering::AcqRel);
                let prev_end = self.buffered_end.swap(r.end_ms, Ordering::AcqRel);
                let encoded_buf = encode_opt_bool(r.is_buffering);
                let prev_buf = self
                    .buffer_is_buffering
                    .swap(encoded_buf, Ordering::AcqRel);
                prev_start != r.start_ms || prev_end != r.end_ms || prev_buf != encoded_buf
            }
            RustPlayerEvent::Position(p) => {
                let mut prev = self.pos.load(Ordering::Acquire);
                loop {
                    if (*p - prev).abs() < 10 && !(*p == 0 && prev != 0) {
                        break false;
                    }
                    match self.pos.compare_exchange_weak(
                        prev,
                        *p,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    ) {
                        Ok(_) => break true,
                        Err(actual) => prev = actual,
                    }
                }
            }
            RustPlayerEvent::ReplayGain(rg) => {
                let key = (rg.gain_db.to_bits(), rg.peak.to_bits());
                let mut complex = lock_unpoisoned(&self.complex);
                if complex.replay_gain == Some(key) {
                    false
                } else {
                    complex.replay_gain = Some(key);
                    true
                }
            }
            RustPlayerEvent::AudioInfo(info) => {
                let mut complex = lock_unpoisoned(&self.complex);
                if complex.audio_info.as_ref() == Some(info) {
                    false
                } else {
                    complex.audio_info = Some(info.clone());
                    true
                }
            }
            RustPlayerEvent::AudioMetadata(m) => {
                let mut complex = lock_unpoisoned(&self.complex);
                if complex.metadata.as_ref() == Some(m) {
                    false
                } else {
                    complex.metadata = Some(m.clone());
                    true
                }
            }
            RustPlayerEvent::Visualizer(v) => {
                let mut complex = lock_unpoisoned(&self.complex);
                if complex.visualizer.as_ref() == Some(v) {
                    false
                } else {
                    complex.visualizer = Some(v.clone());
                    true
                }
            }
            _ => true,
        }
    }
}

#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct EventSinkState {
    sink: Option<StreamSink<RustPlayerEvent>>,
    pending: Vec<RustPlayerEvent>,
}

/// Dispatches engine events to the Flutter Rust Bridge stream sink with deduplication filtering.
#[derive(Clone)]
pub struct EventReporter {
    sink_state: Arc<Mutex<EventSinkState>>,
    filter: Arc<AtomicTelemetryFilter>,
}

impl EventReporter {
    /// Creates a new empty `EventReporter` instance.
    pub fn new() -> Self {
        Self {
            sink_state: Arc::new(Mutex::new(EventSinkState::default())),
            filter: Arc::new(AtomicTelemetryFilter::default()),
        }
    }

    /// Attaches an active Flutter Rust Bridge stream sink, flushing any queued events atomically.
    pub fn set_sink(&self, sink: StreamSink<RustPlayerEvent>) {
        let mut state = lock_unpoisoned(&self.sink_state);
        for ev in state.pending.drain(..) {
            let _ = sink.add(ev);
        }
        state.sink = Some(sink);
    }

    /// Detaches the active stream sink.
    pub fn clear_sink(&self) {
        let mut state = lock_unpoisoned(&self.sink_state);
        state.sink = None;
    }

    fn push_filtered_events<I>(&self, state: &mut EventSinkState, events: I)
    where
        I: IntoIterator<Item = RustPlayerEvent>,
    {
        for event in events {
            if !self.filter.should_emit(&event) {
                continue;
            }
            if let Some(ref sink) = state.sink {
                let _ = sink.add(event);
            } else {
                state.pending.push(event);
            }
        }
    }

    /// Atomically evaluates deduplication filters and emits an ordered sequence of events
    /// under `sink_state`, guaranteeing strict cross-thread event ordering.
    pub(crate) fn emit_batch<I>(&self, events: I)
    where
        I: IntoIterator<Item = RustPlayerEvent>,
    {
        let mut state = lock_unpoisoned(&self.sink_state);
        self.push_filtered_events(&mut state, events);
    }

    /// Emits edge-triggered notices unconditionally and conditionally emits level-triggered
    /// snapshot events only if `snapshots` has not been republished since `read_seq`,
    /// eliminating TOCTOU stale overwrites against synchronous action emissions.
    pub(crate) fn emit_snapshot_tick<E, S>(
        &self,
        snapshots: &EngineUiSnapshots,
        read_seq: u64,
        edge_events: E,
        snapshot_events: S,
    ) -> bool
    where
        E: IntoIterator<Item = RustPlayerEvent>,
        S: IntoIterator<Item = RustPlayerEvent>,
    {
        let mut state = lock_unpoisoned(&self.sink_state);
        self.push_filtered_events(&mut state, edge_events);
        if !snapshots.is_consistent_since(read_seq) {
            return false;
        }
        self.push_filtered_events(&mut state, snapshot_events);
        true
    }

    /// Atomically resets telemetry deduplication caches and emits initial baseline events.
    pub(crate) fn reset_and_emit_batch<I>(&self, events: I)
    where
        I: IntoIterator<Item = RustPlayerEvent>,
    {
        let mut state = lock_unpoisoned(&self.sink_state);
        self.filter.reset();
        self.push_filtered_events(&mut state, events);
    }

    /// Emits an event to Dart if it passes the deduplication filter.
    pub fn emit(&self, event: RustPlayerEvent) {
        self.emit_batch(std::iter::once(event));
    }
}

/// Primary native audio engine instance exposed to Dart via Flutter Rust Bridge.
pub struct RustMiniaudioPlayer {
    engine: EngineActorHandle,
    coordinator: ControlCoordinator,
    hw: HardwareDeviceSupervisor,
    reporter: EventReporter,
    custom_registry: CustomSourceRegistry,
    resolve_registry: Arc<DartResolveRegistry>,
    monitor_running: Arc<AtomicBool>,
    monitor_thread: Mutex<Option<JoinHandle<()>>>,
    device_trigger: Arc<(Mutex<bool>, Condvar)>,
    watcher_thread: Mutex<Option<JoinHandle<()>>>,
    metadata_enabled: Arc<AtomicBool>,
    disposed: AtomicBool,
}

unsafe impl Send for RustMiniaudioPlayer {}
unsafe impl Sync for RustMiniaudioPlayer {}

impl Drop for RustMiniaudioPlayer {
    fn drop(&mut self) {
        self.dispose();
    }
}

fn emit_track_transition_core(
    reporter: &EventReporter,
    meta_enabled: bool,
    emit_queue: Option<&dyn Fn()>,
    snap: TrackTransitionSnapshot,
    emit_shuffle: bool,
) {
    let mut events = Vec::with_capacity(13);
    if snap.queue_changed {
        if let Some(queue_ids) = snap.queue_ids {
            events.push(RustPlayerEvent::Queue {
                queue: queue_ids,
                current_index: snap.cur_idx as i32,
            });
        } else if let Some(cb) = emit_queue {
            cb();
        }
    }
    if let Some((gain_db, peak)) = snap.replay_gain {
        events.push(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
            gain_db,
            peak,
        }));
    }
    if emit_shuffle || snap.emit_shuffle {
        events.push(RustPlayerEvent::IsShuffled(snap.is_shuffled));
    }
    events.push(RustPlayerEvent::CurrentIndex(snap.cur_idx as i32));
    if meta_enabled {
        events.push(RustPlayerEvent::AudioMetadata(RustAudioMetadata::default()));
        if let Some(meta) = snap.initial_meta {
            events.push(RustPlayerEvent::AudioMetadata(meta));
        }
    }
    events.push(RustPlayerEvent::Position(snap.initial_pos));
    if snap.initial_info.sample_rate > 0 {
        events.push(RustPlayerEvent::AudioInfo(snap.initial_info));
    }
    if let Some((start_ms, end_ms, is_buffering)) = snap.buffered_range {
        events.push(RustPlayerEvent::IsBuffering(is_buffering));
        events.push(RustPlayerEvent::Buffer(RustBuffer {
            start_ms,
            end_ms,
            is_buffering,
        }));
    }
    events.push(RustPlayerEvent::PlaybackState(snap.playback_state));
    events.push(RustPlayerEvent::IsPlaying(snap.is_playing));
    events.push(RustPlayerEvent::IsCrossfading(snap.is_xfading));
    reporter.emit_batch(events);
}

impl RustMiniaudioPlayer {
    /// Initializes and boots the native miniaudio engine, DSP pipeline, and mixer.
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        config: RustPlayerConfig,
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        initial_outputs: Vec<RustAudioOutput>,
    ) -> Result<RustMiniaudioPlayer, String> {
        crate::sync::init_wasm_thread_spawner();
        let device_trigger = Arc::new((Mutex::new(true), Condvar::new()));
        #[cfg(target_arch = "wasm32")]
        crate::bridge::ffi::register_web_device_trigger(device_trigger.clone());
        let (engine, notify_rx, hint_rx) = EngineActorHandle::spawn(
            sample_rate,
            channels,
            period_size,
            config.max_voices as usize,
            config.max_ram_bytes,
            Some(device_trigger.clone()),
            config.pause_on_device_change,
            config.visualizer_source,
            initial_outputs.clone(),
        )?;

        let reporter = EventReporter::new();
        reporter.emit(RustPlayerEvent::Outputs(initial_outputs));
        reporter.emit(RustPlayerEvent::VisualizerSource(config.visualizer_source));
        let custom_registry = CustomSourceRegistry::new();
        let resolve_registry = Arc::new(DartResolveRegistry::new({
            let rc = reporter.clone();
            Arc::new(move |req| {
                rc.emit(RustPlayerEvent::DartResolveRequest(req.into()));
            })
        }));
        engine
            .effects()
            .attach_dart_resolver(resolve_registry.clone());
        {
            let factory_init = Self::build_custom_source_factory(&reporter, &custom_registry);
            let resolver_init = resolve_registry.clone();
            // Post via exec_async so RustMiniaudioPlayer::new never spins on the
            // Web main thread before newly spawned Web Workers can enter the JS loop.
            engine.exec_async(move |ply| {
                ply.music_manager.set_custom_source_factory(factory_init);
                ply.music_manager.set_dart_resolver(resolver_init);
            });
        }
        let monitor_running = Arc::new(AtomicBool::new(true));
        let metadata_enabled = Arc::new(AtomicBool::new(false));
        let coordinator = ControlCoordinator::spawn(
            engine.clone(),
            custom_registry.clone(),
            hint_rx,
            {
                let coord_reporter = reporter.clone();
                let coord_meta = metadata_enabled.clone();
                Arc::new(move |snap| {
                    emit_track_transition_core(
                        &coord_reporter,
                        coord_meta.load(Ordering::Relaxed),
                        None,
                        snap,
                        false,
                    );
                })
            },
        );

        let hw = HardwareDeviceSupervisor::new(
            engine.clone(),
            engine.reaper().clone(),
            device_trigger.clone(),
        );

        let watcher_trigger = device_trigger.clone();
        let watcher_running = monitor_running.clone();
        let watcher_reporter = reporter.clone();
        let watcher_hw = hw.clone();
        let watcher_coordinator = coordinator.clone();
        let watcher_snapshots = engine.snapshots().clone();

        // Background device watcher: reacts to hardware changes with ultra-low latency (<15ms on disconnect, <=200ms on connect/change)
        // and runs asynchronously to never block real-time audio, telemetry, or UI threads.
        let watcher_thread = thread::Builder::new()
            .name("map-device-watcher".to_string())
            .spawn(move || {
                let (lock, cvar) = &*watcher_trigger;
                let mut last_out_devices: Option<Vec<RustAudioDevice>> = None;
                let mut last_in_devices: Option<Vec<RustAudioDevice>> = None;
                let mut last_default_out_id: Option<String> = None;
                let mut last_default_in_id: Option<String> = None;

                while watcher_running.load(Ordering::Relaxed) {
                    let mut triggered = lock_unpoisoned(lock);
                    while !*triggered && watcher_running.load(Ordering::Relaxed) {
                        let (new_triggered, _) = cvar
                            .wait_timeout(triggered, Duration::from_millis(200))
                            .unwrap_or_else(|e| e.into_inner());
                        triggered = new_triggered;
                        if *triggered {
                            break;
                        }
                    }
                    if !watcher_running.load(Ordering::Relaxed) {
                        break;
                    }
                    let urgent_disconnect = *triggered;
                    *triggered = false;
                    drop(triggered);

                    map_log!(
                        4,
                        "[WATCHER] Woke up (reason: urgent_disconnect={})",
                        urgent_disconnect
                    );

                    // If not an urgent hardware disconnection, sleep 50ms for USB bus to negotiate
                    if !urgent_disconnect {
                        thread::sleep(Duration::from_millis(50));
                    }

                    let t_scan = Instant::now();
                    let Ok((out_devs, in_devs)) = Self::get_all_devices_sync() else {
                        map_log!(2, "[WATCHER] Device enumeration failed or transient daemon error");
                        continue;
                    };
                    map_log!(
                        4,
                        "[WATCHER] Enumeration completed in {}ms: {} outputs, {} inputs",
                        t_scan.elapsed().as_millis(),
                        out_devs.len(),
                        in_devs.len()
                    );

                    // =========================================================================
                    // 1. RECONCILIATION OF OUTPUTS
                    // =========================================================================
                    let is_first_out_check = last_out_devices.is_none();
                    let out_devices_changed = last_out_devices.as_ref() != Some(&out_devs);

                    if is_first_out_check || out_devices_changed {
                        let prev_out_devices = last_out_devices.replace(out_devs.clone());
                        map_log!(
                            3,
                            "[WATCHER:OUTPUTS] Output hardware list changed! (first_check={}, found={})",
                            is_first_out_check,
                            out_devs.len()
                        );
                        for (i, d) in out_devs.iter().enumerate() {
                            map_log!(
                                3,
                                "  [WATCHER:OUT #{}] id='{}', name='{}', effective_id='{}', is_default={}, is_auto={}",
                                i, d.id, d.name, d.effective_id, d.is_default, d.is_auto
                            );
                        }
                        watcher_reporter.emit(RustPlayerEvent::OutputDevices(out_devs.clone()));

                        let cur_out_def = out_devs.iter().find(|d| d.is_default && !d.is_auto);
                        let cur_out_def_id = cur_out_def.map(|d| d.effective_id.clone());
                        let default_out_changed = last_default_out_id.is_some()
                            && last_default_out_id != cur_out_def_id;
                        let initial_or_dormant_attach =
                            last_default_out_id.is_none() && cur_out_def_id.is_some();

                        if default_out_changed {
                            map_log!(
                                2,
                                "[WATCHER:DEFAULT_OUT] Default output endpoint CHANGED: last={:?}, current={:?}",
                                last_default_out_id,
                                cur_out_def_id
                            );
                        } else if initial_or_dormant_attach {
                            map_log!(
                                3,
                                "[WATCHER:DEFAULT_OUT] Default output initial attach: {:?}",
                                cur_out_def_id
                            );
                        }
                        last_default_out_id = cur_out_def_id.clone();

                        let mut outputs = watcher_snapshots.outputs();
                        let mut outputs_mutated = false;
                        let mut device_disconnected = false;

                        // Only evict non-AUTO devices that were physically present before and have disappeared
                        if let Some(ref prev_devs) = prev_out_devices {
                            outputs.retain(|out| {
                                if out.device_id != "AUTO" {
                                    let was_in_prev = prev_devs
                                        .iter()
                                        .any(|d| device_id_matches(d, &out.device_id));
                                    let is_in_cur = out_devs
                                        .iter()
                                        .any(|d| device_id_matches(d, &out.device_id));
                                    if was_in_prev && !is_in_cur {
                                        device_disconnected = true;
                                        outputs_mutated = true;
                                        map_log!(
                                            2,
                                            "[WATCHER:EVICT_OUT] Evicting disconnected physical output device ID '{}'",
                                            out.device_id
                                        );
                                        return false;
                                    }
                                }
                                true
                            });
                        }

                        let has_auto_output = outputs.iter().any(|o| o.device_id == "AUTO");
                        let should_pause =
                            device_disconnected || (has_auto_output && default_out_changed);
                        let need_pause_check =
                            should_pause && watcher_snapshots.pause_on_device_change();
                        let need_reconcile = outputs_mutated
                            || (has_auto_output
                                && (default_out_changed || initial_or_dormant_attach));

                        if need_pause_check || need_reconcile {
                            let (auto_paused, reconciled_outs) =
                                watcher_hw.reconcile_outputs_from_watcher(
                                    &watcher_coordinator,
                                    prev_out_devices,
                                    out_devs.clone(),
                                    cur_out_def_id.clone(),
                                    default_out_changed,
                                    initial_or_dormant_attach,
                                );
                            if auto_paused {
                                watcher_reporter.emit(RustPlayerEvent::PlaybackState(
                                    crate::core::types::PlaybackState::Paused.as_i32(),
                                ));
                                watcher_reporter.emit(RustPlayerEvent::IsPlaying(false));
                            }
                            if let Some(outs) = reconciled_outs {
                                watcher_reporter.emit(RustPlayerEvent::Outputs(outs));
                            }
                        }
                    }

                    // =========================================================================
                    // 2. RECONCILIATION OF INPUTS (Deterministic Symmetry)
                    // =========================================================================
                    #[cfg(target_arch = "wasm32")]
                    {
                        for msg in crate::bridge::ffi::wasm_take_failed_capture_messages() {
                            watcher_reporter.emit(RustPlayerEvent::Error {
                                code: crate::bridge::ffi::MAP_ERROR_ACCESS_DENIED,
                                message: format!("Microphone capture unavailable: {}", msg),
                            });
                        }
                    }

                    let has_failed_web_capture = {
                        #[cfg(target_arch = "wasm32")]
                        {
                            crate::bridge::ffi::wasm_has_failed_capture_devices()
                        }
                        #[cfg(not(target_arch = "wasm32"))]
                        {
                            false
                        }
                    };

                    let is_first_in_check = last_in_devices.is_none();
                    let in_devices_changed = last_in_devices.as_ref() != Some(&in_devs);

                    if is_first_in_check || in_devices_changed || has_failed_web_capture {
                        let prev_in_devices = last_in_devices.replace(in_devs.clone());
                        if is_first_in_check || in_devices_changed {
                            map_log!(
                                3,
                                "[WATCHER:INPUTS] Input hardware list changed! (first_check={}, found={})",
                                is_first_in_check,
                                in_devs.len()
                            );
                            for (i, d) in in_devs.iter().enumerate() {
                                map_log!(
                                    3,
                                    "  [WATCHER:IN #{}] id='{}', name='{}', effective_id='{}', is_default={}, is_auto={}",
                                    i, d.id, d.name, d.effective_id, d.is_default, d.is_auto
                                );
                            }
                            watcher_reporter.emit(RustPlayerEvent::InputDevices(in_devs.clone()));
                        }

                        let cur_in_def = in_devs.iter().find(|d| d.is_default && !d.is_auto);
                        let cur_in_def_id = cur_in_def.map(|d| d.effective_id.clone());
                        let default_in_changed = last_default_in_id.is_some()
                            && last_default_in_id != cur_in_def_id;
                        let initial_or_dormant_attach_in =
                            last_default_in_id.is_none() && cur_in_def_id.is_some();
                        if default_in_changed {
                            map_log!(
                                2,
                                "[WATCHER:DEFAULT_IN] Default input endpoint CHANGED: last={:?}, current={:?}",
                                last_default_in_id,
                                cur_in_def_id
                            );
                        } else if initial_or_dormant_attach_in {
                            map_log!(
                                3,
                                "[WATCHER:DEFAULT_IN] Default input initial attach: {:?}",
                                cur_in_def_id
                            );
                        }
                        last_default_in_id = cur_in_def_id.clone();

                        let mut inputs = watcher_snapshots.inputs();
                        let mut inputs_mutated = has_failed_web_capture;

                        if let Some(ref prev_devs) = prev_in_devices {
                            inputs.retain(|inp| {
                                if inp.device_id != "AUTO" {
                                    let was_in_prev = prev_devs
                                        .iter()
                                        .any(|d| device_id_matches(d, &inp.device_id));
                                    let is_in_cur = in_devs
                                        .iter()
                                        .any(|d| device_id_matches(d, &inp.device_id));
                                    if was_in_prev && !is_in_cur {
                                        inputs_mutated = true;
                                        map_log!(
                                            2,
                                            "[WATCHER:EVICT_IN] Evicting missing physical input device ID '{}'",
                                            inp.device_id
                                        );
                                        return false;
                                    }
                                }
                                true
                            });
                        }

                        let has_auto_input = inputs.iter().any(|i| i.device_id == "AUTO");
                        let need_reconcile_in = inputs_mutated
                            || (has_auto_input
                                && (default_in_changed || initial_or_dormant_attach_in));

                        if need_reconcile_in {
                            if let Some(reconciled_ins) = watcher_hw.reconcile_inputs_from_watcher(
                                prev_in_devices,
                                in_devs.clone(),
                                cur_in_def_id.clone(),
                                default_in_changed,
                                initial_or_dormant_attach_in,
                            ) {
                                watcher_reporter.emit(RustPlayerEvent::Inputs(reconciled_ins));
                            }
                        }
                    }
                }
            })
            .ok();

        let worker_snapshots = engine.snapshots().clone();
        let worker_effects = engine.effects().clone();
        let worker_reporter = reporter.clone();
        let worker_running = monitor_running.clone();
        let meta_enabled = metadata_enabled.clone();

        // Dedicated metadata single-emission state registers to guarantee zero per-tick parsing/serialization overhead
        let mut last_emitted_meta_deck = -1i32;
        let mut last_emitted_meta_deck_id = usize::MAX;
        let mut last_emitted_meta_open_gen = u64::MAX;
        let mut last_emitted_meta_version = u32::MAX;
        let mut last_emitted_meta_flush = u64::MAX;
        let mut last_meta_enabled = false;
        let mut edge_events: Vec<RustPlayerEvent> = Vec::with_capacity(8);
        let mut tick_events: Vec<RustPlayerEvent> = Vec::with_capacity(24);
        let mut pending_notices: Vec<RustPlayerEvent> = Vec::with_capacity(8);

        let mut tick_telemetry = move || -> bool {
            if !worker_running.load(Ordering::Relaxed) {
                return false;
            }
            edge_events.clear();
            tick_events.clear();

            for notice in notify_rx.try_iter() {
                match notice {
                    RtEngineNotice::IsCrossfading(v) => {
                        // Defer crossfade/ReplayGain notices until after CurrentIndex is
                        // pushed from the consistent snapshot so Dart listeners always see
                        // the updated track before its completion/gain transitions fire.
                        pending_notices.push(RustPlayerEvent::IsCrossfading(v));
                    }
                    RtEngineNotice::ReplayGain { gain_db, peak } => {
                        pending_notices.push(RustPlayerEvent::ReplayGain(
                            RustReplayGainConfig { gain_db, peak },
                        ));
                    }
                    RtEngineNotice::NeedMoreTracks {
                        current_track_id,
                        remaining_tracks,
                    } => {
                        edge_events.push(RustPlayerEvent::NeedMoreTracks {
                            current_track_id,
                            remaining_tracks,
                        });
                    }
                    RtEngineNotice::RecordingError { message, code } => {
                        edge_events.push(RustPlayerEvent::IsRecording(false));
                        edge_events.push(RustPlayerEvent::RecordingState {
                            is_recording: false,
                            source: 0,
                        });
                        edge_events.push(RustPlayerEvent::Error { message, code });
                    }
                }
            }

            // Drain completed voices and process LRU RAM eviction completely lock-free.
            if worker_effects.has_pending_completions() {
                let (completed_ids, eviction_info) =
                    worker_effects.drain_completed_and_evict();
                for v_id in completed_ids {
                    edge_events.push(RustPlayerEvent::VoiceCompleted(v_id));
                }
                if let Some((ids, allocated_bytes)) = eviction_info {
                    edge_events.push(RustPlayerEvent::LoadedEffects {
                        ids,
                        allocated_bytes,
                    });
                }
            }

            let Some(read_seq) = worker_snapshots.begin_consistent_read() else {
                if !edge_events.is_empty() {
                    worker_reporter.emit_batch(edge_events.drain(..));
                }
                return true;
            };

            let playback_state = worker_snapshots.playback_state();
            let is_buffering = worker_snapshots.is_buffering();
            let pos = worker_snapshots.position_ms();
            let audio_info = worker_snapshots.audio_info();
            let buffered_range = worker_snapshots.buffered_range();
            let idx = worker_snapshots.current_index();
            let is_xfading = worker_snapshots.is_xfading();
            let is_rec = worker_snapshots.is_recording();
            let rec_dur_ms = worker_snapshots.recorded_duration_ms();
            let is_ducking = worker_snapshots.is_ducking();
            let mic_rms = worker_snapshots.mic_rms_db();

            let cur_meta_enabled = meta_enabled.load(Ordering::Relaxed);
            let active_deck_idx = worker_snapshots.active_deck();
            let active_deck_id = worker_snapshots.active_deck_id();
            let active_open_gen = worker_snapshots.active_open_gen();
            let cur_flush = worker_snapshots.flush_generation();
            let cur_meta_ver = worker_snapshots.meta_version();

            let should_emit_meta = cur_meta_enabled
                && (!last_meta_enabled
                    || active_deck_idx != last_emitted_meta_deck
                    || active_deck_id != last_emitted_meta_deck_id
                    || active_open_gen != last_emitted_meta_open_gen
                    || cur_flush != last_emitted_meta_flush
                    || cur_meta_ver != last_emitted_meta_version);

            let meta_to_send = if should_emit_meta {
                worker_snapshots.parsed_metadata()
            } else {
                None
            };
            let (rg_gain_db, rg_peak) = worker_snapshots.unpack_rg();
            let active_voices = worker_effects.active_voices_count();

            let vis_data = if worker_snapshots.visualizer_enabled() {
                Some(worker_snapshots.read_visualizer())
            } else {
                None
            };

            if !worker_snapshots.is_consistent_since(read_seq) {
                if !edge_events.is_empty() {
                    worker_reporter.emit_batch(edge_events.drain(..));
                }
                return true;
            }

            let is_playing = playback_state == PlaybackState::Playing;

            tick_events.push(RustPlayerEvent::PlaybackState(playback_state.as_i32()));
            tick_events.push(RustPlayerEvent::IsPlaying(is_playing));
            tick_events.push(RustPlayerEvent::IsBuffering(is_buffering));
            tick_events.push(RustPlayerEvent::Position(pos));
            tick_events.push(RustPlayerEvent::CurrentIndex(idx as i32));
            if audio_info.sample_rate > 0 {
                tick_events.push(RustPlayerEvent::AudioInfo(audio_info));
            }
            tick_events.push(RustPlayerEvent::ActiveVoices(active_voices));
            if let Some((start_ms, end_ms, range_buffering)) = buffered_range {
                tick_events.push(RustPlayerEvent::Buffer(RustBuffer {
                    start_ms,
                    end_ms,
                    is_buffering: range_buffering,
                }));
            }
            if !pending_notices.is_empty() {
                tick_events.extend(pending_notices.iter().cloned());
            }
            tick_events.push(RustPlayerEvent::IsCrossfading(is_xfading));
            tick_events.push(RustPlayerEvent::IsRecording(is_rec));
            if is_rec {
                tick_events.push(RustPlayerEvent::RecordedDuration(rec_dur_ms));
            }
            tick_events.push(RustPlayerEvent::IsDuckingActive(is_ducking));
            if mic_rms > -90.0 {
                tick_events.push(RustPlayerEvent::MicRmsLevel(mic_rms));
            }
            if should_emit_meta {
                if let Some(meta) = meta_to_send {
                    tick_events.push(RustPlayerEvent::AudioMetadata(meta));
                } else {
                    tick_events.push(RustPlayerEvent::AudioMetadata(
                        RustAudioMetadata::default(),
                    ));
                }
            } else if !cur_meta_enabled && last_meta_enabled {
                tick_events
                    .push(RustPlayerEvent::AudioMetadata(RustAudioMetadata::default()));
            }
            tick_events.push(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                gain_db: rg_gain_db,
                peak: rg_peak,
            }));
            if let Some(vis) = vis_data {
                tick_events.push(RustPlayerEvent::Visualizer(
                    RustVisualizerData::from(vis),
                ));
            }
            if worker_reporter.emit_snapshot_tick(
                &worker_snapshots,
                read_seq,
                edge_events.drain(..),
                tick_events.drain(..),
            ) {
                pending_notices.clear();
                if should_emit_meta {
                    last_emitted_meta_deck = active_deck_idx;
                    last_emitted_meta_deck_id = active_deck_id;
                    last_emitted_meta_open_gen = active_open_gen;
                    last_emitted_meta_version = cur_meta_ver;
                    last_emitted_meta_flush = cur_flush;
                    last_meta_enabled = true;
                } else if !cur_meta_enabled && last_meta_enabled {
                    last_meta_enabled = false;
                    last_emitted_meta_version = u32::MAX;
                }
            }
            true
        };

        let monitor_snapshots = engine.snapshots().clone();
        let monitor_thread = thread::Builder::new()
            .name("map-telemetry-monitor".to_string())
            .spawn(move || {
                let mut wake_seq = 0u64;
                loop {
                    monitor_snapshots.wait_for_telemetry_tick(Duration::from_millis(16), &mut wake_seq);
                    if !tick_telemetry() {
                        break;
                    }
                }
            })
            .ok();

        Ok(RustMiniaudioPlayer {
            engine,
            coordinator,
            hw,
            reporter,
            custom_registry,
            resolve_registry,
            monitor_running,
            monitor_thread: Mutex::new(monitor_thread),
            device_trigger,
            watcher_thread: Mutex::new(watcher_thread),
            metadata_enabled,
            disposed: AtomicBool::new(false),
        })
    }

    fn notify_device_watcher(&self) {
        let (lock, cvar) = &*self.device_trigger;
        let mut flag = lock_unpoisoned(lock);
        *flag = true;
        cvar.notify_all();
    }

    /// Subscribes a Dart StreamSink to real-time engine events and telemetry updates.
    pub fn subscribe_events(
        &self,
        sink: StreamSink<RustPlayerEvent>,
    ) -> Result<(), String> {
        self.reporter.set_sink(sink);

        let snap = self.engine.snapshots();
        self.reporter.emit(RustPlayerEvent::Outputs(snap.outputs()));
        self.reporter
            .emit(RustPlayerEvent::VisualizerSource(snap.visualizer_source()));
        self.reporter.emit(RustPlayerEvent::Inputs(snap.inputs()));

        // Asynchronously notify background device watcher to deliver initial device snapshot
        self.notify_device_watcher();
        Ok(())
    }

    fn emit_event(&self, event: RustPlayerEvent) {
        self.reporter.emit(event);
    }

    fn emit_queue(&self) {
        if let Ok((queue, current_index)) = self.engine.exec(|ply| snapshot_queue_ids(ply)) {
            self.emit_event(RustPlayerEvent::Queue {
                queue,
                current_index,
            });
        }
    }

    fn emit_queue_and_index<const N: usize>(&self, trailing: [RustPlayerEvent; N]) {
        let mut batch = Vec::with_capacity(1 + N);
        if let Ok((queue, current_index)) = self.engine.exec(|ply| snapshot_queue_ids(ply)) {
            batch.push(RustPlayerEvent::Queue {
                queue,
                current_index,
            });
        }
        batch.extend(trailing);
        self.reporter.emit_batch(batch);
    }

    // =========================================================================
    // Transport & Playback Methods
    // =========================================================================

    /// Universal playback command: starts, resumes, or switches tracks by ID or position,
    /// optionally applying shuffle and/or seeking to an initial offset.
    pub fn play(
        &self,
        id: Option<i64>,
        position: Option<usize>,
        shuffled: Option<bool>,
        seek_ms: Option<i64>,
    ) -> Result<(), String> {
        let include_meta = self.metadata_enabled.load(Ordering::Relaxed);
        let _ = self
            .coordinator
            .play(id, position, shuffled, seek_ms, include_meta)?;
        Ok(())
    }

    /// Pauses playback on the active audio deck without releasing resources.
    pub fn pause(&self) {
        map_log!(3, "[NATIVE:PAUSE:START] pause() requested from Dart. Cancelling pending opens and dispatching to engine actor...");
        let t0 = Instant::now();
        if let Ok((state, is_xfading)) = self.coordinator.pause() {
            map_log!(
                3,
                "[NATIVE:PAUSE:DONE] pause() completed in {}ms. Emitting events...",
                t0.elapsed().as_millis()
            );
            self.reporter.emit_batch([
                RustPlayerEvent::PlaybackState(state),
                RustPlayerEvent::IsPlaying(false),
                RustPlayerEvent::IsCrossfading(is_xfading),
            ]);
        }
    }

    /// Stops playback and resets elapsed position to the beginning.
    pub fn stop(&self) {
        map_log!(3, "[NATIVE:STOP:START] stop() requested from Dart. Cancelling pending opens and dispatching to engine actor...");
        let t0 = Instant::now();
        if let Ok((state, is_xfading)) = self.coordinator.stop() {
            map_log!(
                3,
                "[NATIVE:STOP:DONE] stop() completed in {}ms. Emitting events...",
                t0.elapsed().as_millis()
            );
            self.reporter.emit_batch([
                RustPlayerEvent::PlaybackState(state),
                RustPlayerEvent::Position(0),
                RustPlayerEvent::IsPlaying(false),
                RustPlayerEvent::IsCrossfading(is_xfading),
                RustPlayerEvent::Visualizer(RustVisualizerData::default()),
            ]);
        }
    }

    /// Seeks to the specified position in milliseconds within the current track.
    pub fn seek(&self, position_ms: i64) -> Result<(), String> {
        map_log!(3, "[NATIVE:SEEK:START] seek({}ms) requested. Cancelling stale auto-advance and dispatching to engine actor...", position_ms);
        let t0 = Instant::now();
        let (cur_idx, state, is_playing, is_xfading) = self.coordinator.seek(position_ms)?;
        map_log!(
            3,
            "[NATIVE:SEEK:DONE] seek() completed in {}ms. Emitting events...",
            t0.elapsed().as_millis()
        );
        self.reporter.emit_batch([
            RustPlayerEvent::Position(position_ms),
            RustPlayerEvent::CurrentIndex(cur_idx as i32),
            RustPlayerEvent::PlaybackState(state),
            RustPlayerEvent::IsPlaying(is_playing),
            RustPlayerEvent::IsCrossfading(is_xfading),
        ]);
        Ok(())
    }

    // =========================================================================
    // Queue Management Methods
    // =========================================================================

    fn build_custom_source_factory(
        reporter: &EventReporter,
        custom_registry: &CustomSourceRegistry,
    ) -> CustomSourceFactory {
        let reporter_clone = reporter.clone();
        let registry_clone = custom_registry.clone();
        Arc::new(move |stream_id: u32, total_size: Option<u64>| {
            let rc = reporter_clone.clone();
            let req_sender = Arc::new(move |req: crate::buffer::DartReadRequest| {
                rc.emit(RustPlayerEvent::DartReadRequest(req.into()));
            });
            CustomDartByteSource::with_registry(
                stream_id,
                total_size,
                true,
                req_sender,
                Some(registry_clone.clone()),
            )
        })
    }

    /// Replaces the entire playback queue with `queue` without starting playback.
    pub fn set_queue(&self, queue: Vec<RustAudioSource>) -> Result<(), String> {
        let core_queue: Vec<AudioSourceCore> = queue.into_iter().map(Into::into).collect();
        self.custom_registry.abort_all();
        let custom_factory =
            Self::build_custom_source_factory(&self.reporter, &self.custom_registry);
        let (g, p) = self
            .coordinator
            .set_queue(core_queue, custom_factory)?;
        let queue_evt = self
            .engine
            .exec(|ply| snapshot_queue_ids(ply))
            .ok()
            .map(|(queue, current_index)| RustPlayerEvent::Queue {
                queue,
                current_index,
            });
        self.reporter.reset_and_emit_batch(queue_evt.into_iter().chain([
            RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                gain_db: g,
                peak: p,
            }),
            RustPlayerEvent::CurrentIndex(-1),
            RustPlayerEvent::Position(0),
            RustPlayerEvent::AudioInfo(RustAudioInfo::default()),
            RustPlayerEvent::PlaybackState(0),
            RustPlayerEvent::IsPlaying(false),
        ]));
        Ok(())
    }

    /// Appends a batch of audio sources to the end of the playlist queue.
    pub fn append(&self, sources: Vec<RustAudioSource>) {
        let core_sources: Vec<AudioSourceCore> = sources.into_iter().map(Into::into).collect();
        if self.coordinator.append(core_sources).is_ok() {
            self.emit_queue();
        }
    }

    /// Inserts an audio source directly after the currently playing track.
    pub fn insert_next(&self, source: RustAudioSource) {
        let core_src: AudioSourceCore = source.into();
        if self.coordinator.insert_next(core_src).is_ok() {
            self.emit_queue();
        }
    }

    /// Removes an audio source at the specified index from the playlist queue.
    pub fn remove_at(&self, index: usize) -> bool {
        let include_meta = self.metadata_enabled.load(Ordering::Relaxed);
        let Ok((res, idx, transition_emitted)) = self.coordinator.remove_at(index, include_meta)
        else {
            return false;
        };
        if res && !transition_emitted {
            if idx < 0 {
                self.emit_queue_and_index([
                    RustPlayerEvent::CurrentIndex(-1),
                    RustPlayerEvent::PlaybackState(0),
                    RustPlayerEvent::IsPlaying(false),
                ]);
            } else {
                self.emit_queue_and_index([RustPlayerEvent::CurrentIndex(idx as i32)]);
            }
        }
        res
    }

    /// Reorders a track within the queue from `old_index` to `new_index`.
    pub fn reorder(&self, old_index: usize, new_index: usize) -> bool {
        let Ok(res) = self.coordinator.reorder(old_index, new_index) else {
            return false;
        };
        if res {
            let idx = self.engine.snapshots().current_index();
            self.emit_queue_and_index([RustPlayerEvent::CurrentIndex(idx as i32)]);
        }
        res
    }

    /// Reorders the playlist queue to match the specified list of track IDs.
    pub fn reorder_by_ids(&self, ids: Vec<i64>) -> bool {
        let Ok(res) = self.coordinator.reorder_by_ids(ids) else {
            return false;
        };
        if res {
            let idx = self.engine.snapshots().current_index();
            self.emit_queue_and_index([RustPlayerEvent::CurrentIndex(idx as i32)]);
        }
        res
    }

    /// Clears pending tracks from the queue, optionally preserving the currently active track.
    pub fn clear_queue(&self, keep_current: bool) {
        if let Ok(idx) = self.coordinator.clear_queue(keep_current) {
            if idx < 0 {
                self.emit_queue_and_index([
                    RustPlayerEvent::CurrentIndex(-1),
                    RustPlayerEvent::PlaybackState(0),
                    RustPlayerEvent::IsPlaying(false),
                ]);
            } else {
                self.emit_queue_and_index([RustPlayerEvent::CurrentIndex(idx as i32)]);
            }
        }
    }

    /// Skips to the next track in the queue, optionally overriding crossfade duration.
    pub fn next(&self, crossfade_duration_ms: Option<u64>) -> Result<(), String> {
        let include_meta = self.metadata_enabled.load(Ordering::Relaxed);
        let _ = self.coordinator.next(crossfade_duration_ms, include_meta)?;
        Ok(())
    }

    /// Rewinds or skips to the previous track in the queue.
    pub fn previous(&self) -> Result<(), String> {
        let include_meta = self.metadata_enabled.load(Ordering::Relaxed);
        let _ = self.coordinator.previous(include_meta)?;
        Ok(())
    }

    /// Sets the queue loop policy (0: off, 1: one, 2: all).
    pub fn set_loop_mode(&self, mode: i32) {
        if let Ok(true) = self.coordinator.set_loop_mode(mode) {
            self.emit_event(RustPlayerEvent::LoopMode(mode));
        }
    }

    /// Enables or disables playlist shuffle mode.
    pub fn set_shuffle(&self, enabled: bool) {
        if let Ok(Some(idx)) = self.coordinator.set_shuffle(enabled) {
            self.emit_queue_and_index([
                RustPlayerEvent::IsShuffled(enabled),
                RustPlayerEvent::CurrentIndex(idx as i32),
            ]);
        }
    }

    /// Enables or disables continuous auto-refill infinite mix mode and sets queue replenishment threshold.
    pub fn set_infinite_mix(&self, config: RustInfiniteMixConfig) {
        let enabled = config.enabled;
        let threshold = config.remaining_tracks_threshold as usize;
        if self
            .engine
            .exec(move |ply| {
                ply.music_manager
                    .inner
                    .infinite_mix_enabled
                    .store(enabled, Ordering::Release);
                ply.music_manager
                    .inner
                    .infinite_mix_threshold
                    .store(threshold, Ordering::Release);
                if enabled {
                    ply.music_manager
                        .inner
                        .last_notified_infinite_mix_id
                        .store(-1, Ordering::Release);
                }
            })
            .is_ok()
        {
            self.emit_event(RustPlayerEvent::InfiniteMix(config));
        }
    }

    /// Configures automatic and manual crossfade durations and curve formulas.
    pub fn set_crossfade(&self, config: RustCrossfadeConfig) {
        let auto_ms = config.auto_duration_ms;
        let manual_ms = config.manual_duration_ms;
        let curve = config.curve;
        if self
            .engine
            .exec(move |ply| ply.music_manager.set_crossfade(auto_ms, manual_ms, curve))
            .is_ok()
        {
            self.emit_event(RustPlayerEvent::CrossfadeConfig(config));
        }
    }

    // =========================================================================
    // DSP & Audio Modulation Methods
    // =========================================================================

    /// Sets the master output volume level (0.0 to 1.0+).
    pub fn set_volume(&self, volume: f32) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.music_dsp.volume;
            if (prev - volume).abs() > 1e-5 {
                ply.set_volume(volume);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Volume(volume));
        }
    }

    /// Sets the playback speed multiplier with automatic pitch compensation.
    pub fn set_rate(&self, rate: f32) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.music_manager.rate();
            if (prev - rate).abs() > 1e-5 {
                ply.music_manager.set_rate(rate);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Rate(rate));
        }
    }

    /// Sets the pitch shift frequency multiplier independently of playback speed.
    pub fn set_pitch(&self, pitch: f32) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.music_manager.pitch();
            if (prev - pitch).abs() > 1e-5 {
                ply.music_manager.set_pitch(pitch);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Pitch(pitch));
        }
    }

    /// Sets the stereo pan balance from -1.0 (hard left) to +1.0 (hard right).
    pub fn set_balance(&self, balance: f32) {
        if let Ok(Some(actual)) = self.engine.exec(move |ply| {
            let prev = ply.music_dsp.balance;
            ply.music_dsp.set_balance(balance);
            let actual = ply.music_dsp.balance;
            if (prev - actual).abs() > 1e-5 {
                Some(actual)
            } else {
                None
            }
        }) {
            self.emit_event(RustPlayerEvent::Balance(actual));
        }
    }

    /// Toggles mono downmixing of multi-channel audio.
    pub fn set_mono(&self, enabled: bool) {
        if let Ok(true) = self.engine.exec(move |ply| {
            if ply.music_dsp.mono != enabled {
                ply.music_dsp.set_mono(enabled);
                ply.inherit_dsp.set_mono(enabled);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Mono(enabled));
        }
    }

    /// Sets the equalizer pre-amplification gain in decibels.
    pub fn set_preamp(&self, preamp_db: f32) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.music_dsp.equalizer.preamp_db();
            if (prev - preamp_db).abs() > 1e-5 {
                ply.music_dsp.set_preamp(preamp_db);
                ply.inherit_dsp.set_preamp(preamp_db);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Preamp(preamp_db));
        }
    }

    /// Sets the Bauer binaural headphone crossfeed configuration.
    pub fn set_crossfeed(&self, config: RustCrossfeedConfig) {
        let core_cfg: crate::dsp::crossfeed::CrossfeedConfig = config.clone().into();
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.music_manager.inner.deck_a.crossfeed_config;
            if prev != core_cfg {
                ply.music_manager.inner.deck_a.set_crossfeed(core_cfg);
                ply.music_manager.inner.deck_b.set_crossfeed(core_cfg);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Crossfeed(config));
        }
    }

    /// Enables or disables 3D stereo widening spatializer with width multiplier.
    pub fn set_spatializer(&self, enabled: bool, width: f32) {
        let w = width.clamp(0.0, 2.0);
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev_en = ply.music_dsp.equalizer.spatializer_enabled();
            let prev_w = ply.music_dsp.equalizer.spatializer_width();
            if prev_en != enabled || (prev_w - w).abs() > 1e-5 {
                ply.music_dsp.equalizer.set_spatializer(enabled, w);
                ply.inherit_dsp.equalizer.set_spatializer(enabled, w);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Spatializer { enabled, width: w });
        }
    }

    /// Sets, updates, or clears ReplayGain normalization settings for a queue item or current track.
    pub fn set_replay_gain(
        &self,
        config: Option<RustReplayGainConfig>,
        id: Option<i64>,
        position: Option<usize>,
    ) -> Result<(), String> {
        let rg_update = self.engine.exec(move |ply| {
            let target_idx = {
                let q = read_unpoisoned(&ply.music_manager.inner.queue);
                if let Some(target_id) = id {
                    q.iter().position(|it| it.id == target_id)
                } else if let Some(pos) = position {
                    if pos < q.len() {
                        Some(pos)
                    } else {
                        None
                    }
                } else {
                    let cur = ply.music_manager.inner.current_index.load(Ordering::Relaxed);
                    if cur >= 0 && (cur as usize) < q.len() {
                        Some(cur as usize)
                    } else if !q.is_empty() {
                        Some(0)
                    } else {
                        None
                    }
                }
            };

            if let Some(idx) = target_idx {
                let (new_gain, new_peak) = match config {
                    Some(ref c) => (Some(c.gain_db), Some(c.peak)),
                    None => (None, None),
                };
                let target_id = {
                    let mut q = write_unpoisoned(&ply.music_manager.inner.queue);
                    if idx < q.len() {
                        q[idx].replay_gain_db = new_gain;
                        q[idx].replay_peak = new_peak;
                        Some(q[idx].id)
                    } else {
                        None
                    }
                };
                if let Some(tid) = target_id {
                    let mut cq = write_unpoisoned(&ply.music_manager.inner.canonical_queue);
                    if let Some(item) = cq.iter_mut().find(|it| it.id == tid) {
                        item.replay_gain_db = new_gain;
                        item.replay_peak = new_peak;
                    }
                }
                let cur = ply.music_manager.inner.current_index.load(Ordering::Relaxed);
                let is_target_active = if cur >= 0 {
                    cur as usize == idx
                } else {
                    idx == 0
                };
                let fg_rg = ply.recalculate_and_apply_replay_gain();
                if is_target_active {
                    return Some(fg_rg);
                }
            }
            None
        })?;

        if let Some((g, p)) = rg_update {
            self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
                gain_db: g,
                peak: p,
            }));
        }
        Ok(())
    }

    /// Sets the global ReplayGain operating mode (0: disabled, 1: track, 2: forced).
    pub fn set_replay_gain_mode(&self, mode: u32) -> Result<(), String> {
        let (g, p) = self
            .engine
            .exec(move |ply| ply.set_replay_gain_mode(mode))?;
        self.emit_event(RustPlayerEvent::ReplayGainMode(mode));
        self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
            gain_db: g,
            peak: p,
        }));
        Ok(())
    }

    /// Sets the fallback or forced ReplayGain adjustment in dB and peak.
    pub fn set_default_replay_gain(&self, gain_db: f32, peak: f32) -> Result<(), String> {
        let (g, p) = self
            .engine
            .exec(move |ply| ply.set_default_replay_gain(gain_db, peak))?;
        self.emit_event(RustPlayerEvent::DefaultReplayGain(gain_db));
        self.emit_event(RustPlayerEvent::ReplayGain(RustReplayGainConfig {
            gain_db: g,
            peak: p,
        }));
        Ok(())
    }

    /// Configures automatic silence skipping and trimming parameters.
    pub fn set_silence_config(&self, config: RustSilenceConfig) -> Result<(), String> {
        let sc = SilenceConfig::from(config.clone());
        self.engine.exec(move |ply| {
            ply.music_manager.inner.deck_a.set_silence_config(&sc);
            ply.music_manager.inner.deck_b.set_silence_config(&sc);
        })?;
        self.emit_event(RustPlayerEvent::SilenceConfig(config));
        Ok(())
    }

    /// Updates 10-band graphic equalizer band gain levels and enabled bypass state.
    pub fn set_equalizer(&self, params: RustEqualizerParams) -> Result<(), String> {
        let eq = EqualizerParams::from(params.clone());
        self.engine.exec(move |ply| {
            ply.music_dsp.set_equalizer(&eq);
            ply.inherit_dsp.set_equalizer(&eq);
            ply.music_manager.inner.deck_a.set_equalizer(&eq);
            ply.music_manager.inner.deck_b.set_equalizer(&eq);
        })?;
        self.emit_event(RustPlayerEvent::Equalizer(params));
        Ok(())
    }

    /// Updates studio reverberation acoustic parameters.
    pub fn set_reverb(&self, params: RustReverbParams) -> Result<(), String> {
        let conf = ReverbConfig {
            enabled: if params.enabled { 1 } else { 0 },
            room_size: params.room_size,
            damping: params.damping,
            width: params.width,
            wet: params.wet,
            dry: params.dry,
        };
        self.engine.exec(move |ply| {
            ply.music_dsp.set_reverb(conf);
            ply.inherit_dsp.set_reverb(conf);
        })?;
        self.emit_event(RustPlayerEvent::Reverb(params));
        Ok(())
    }

    /// Enables or disables the output brickwall peak limiter.
    pub fn set_limiter(&self, enabled: bool) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.master_limiter.is_enabled();
            if prev != enabled {
                ply.master_limiter.set_enabled(enabled);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::Limiter(enabled));
        }
    }

    /// Enables or disables the FFT audio visualizer and spectrum analysis stream.
    pub fn set_visualizer_enabled(&self, enabled: bool) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply.output_manager.visualizer_enabled.load(Ordering::Relaxed);
            if prev != enabled {
                ply.output_manager.set_visualizer_enabled(enabled);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::VisualizerEnabled(enabled));
            if !enabled {
                self.emit_event(RustPlayerEvent::Visualizer(RustVisualizerData::default()));
            }
        }
    }

    /// Configures the audio bus feeding the real-time FFT spectrum visualizer.
    pub fn set_visualizer_source(&self, source: i32) {
        if self
            .engine
            .exec(move |ply| {
                let src = AudioOutputSource::from(source);
                ply.output_manager.set_visualizer_source(src);
            })
            .is_ok()
        {
            self.emit_event(RustPlayerEvent::VisualizerSource(source));
        }
    }

    /// Enables or disables forwarding of audio metadata payloads.
    pub fn set_metadata_enabled(&self, enabled: bool) {
        let prev = self.metadata_enabled.swap(enabled, Ordering::Relaxed);
        if prev != enabled {
            self.emit_event(RustPlayerEvent::MetadataEnabled(enabled));
            if enabled {
                if let Some(meta) = self.engine.snapshots().parsed_metadata() {
                    self.emit_event(RustPlayerEvent::AudioMetadata(meta));
                }
            } else {
                self.emit_event(RustPlayerEvent::AudioMetadata(RustAudioMetadata::default()));
            }
        }
    }

    /// Adjusts the audio stream buffer frame size.
    pub fn set_buffer_size(&self, buffer_size_frames: u32) {
        if self
            .engine
            .exec(move |ply| {
                ply.music_manager.inner.deck_a.set_buffer_size(buffer_size_frames);
                ply.music_manager.inner.deck_b.set_buffer_size(buffer_size_frames);
            })
            .is_ok()
        {
            self.emit_event(RustPlayerEvent::BufferSize(buffer_size_frames));
        }
    }

    // =========================================================================
    // RAM Sound Effects Methods
    // =========================================================================

    /// Declaratively registers the catalog of sound effects with the autonomous RAM engine.
    pub fn set_effects(&self, effects: Vec<RustAudioEffect>) -> Result<(), String> {
        let catalog: Vec<EffectCatalogItem> = effects.into_iter().map(Into::into).collect();
        let fx = self.engine.effects();
        fx.set_effects(catalog)?;
        let loaded_ids = fx.loaded_effect_ids();
        let ram_bytes = fx.allocated_ram_bytes();
        self.emit_event(RustPlayerEvent::LoadedEffects {
            ids: loaded_ids,
            allocated_bytes: ram_bytes,
        });
        Ok(())
    }

    /// Returns the list of currently loaded sound effect IDs in RAM.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_loaded_effect_ids(&self) -> Vec<String> {
        self.engine.effects().loaded_effect_ids()
    }

    /// Returns the total RAM bytes occupied by decoded sound effect buffers.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_allocated_ram_bytes(&self) -> usize {
        self.engine.effects().allocated_ram_bytes()
    }

    /// Returns the current number of concurrently playing sound effect voices.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_active_voices_count(&self) -> u32 {
        self.engine.effects().active_voices_count()
    }

    /// Triggers playback of a registered sound effect (decoding on demand if not in RAM),
    /// returning the assigned voice ID.
    pub fn play_effect(
        &self,
        id: String,
        config: RustEffectConfig,
    ) -> Result<u32, String> {
        let core_config = EffectConfig::from(config);
        let fx = self.engine.effects();
        let (voice_id, ram_changed) = fx.play_effect(&id, core_config)?;
        if ram_changed {
            self.emit_event(RustPlayerEvent::LoadedEffects {
                ids: fx.loaded_effect_ids(),
                allocated_bytes: fx.allocated_ram_bytes(),
            });
        }
        Ok(voice_id)
    }

    /// Stops an active sound effect voice with an optional fade-out ramp in milliseconds.
    pub fn stop_effect(&self, voice_id: u32, fade_out_ms: u64) {
        let sr = self.engine.snapshots().sample_rate;
        let fade_samples = (fade_out_ms as f64 * (sr as f64 / 1000.0)) as usize;
        self.engine.effects().stop_effect(voice_id, fade_samples);
    }

    /// Stops all actively playing sound effect voices with an optional fade-out ramp in milliseconds.
    pub fn stop_all_effects(&self, fade_out_ms: u64) {
        let sr = self.engine.snapshots().sample_rate;
        let fade_samples = (fade_out_ms as f64 * (sr as f64 / 1000.0)) as usize;
        self.engine.effects().stop_all_effects(fade_samples);
    }

    /// Modulates the volume of an active sound effect voice.
    pub fn set_effect_volume(&self, voice_id: u32, volume: f32) {
        self.engine.effects().set_voice_volume(voice_id, volume);
    }

    /// Modulates the pitch multiplier of an active sound effect voice.
    pub fn set_effect_pitch(&self, voice_id: u32, pitch: f32) {
        self.engine.effects().set_voice_pitch(voice_id, pitch);
    }

    /// Adjusts stereo pan balance of an active sound effect voice.
    pub fn set_effect_balance(&self, voice_id: u32, balance: f32) {
        self.engine.effects().set_voice_balance(voice_id, balance);
    }

    /// Updates the 3D spatial emitter parameters for an active sound effect voice.
    pub fn set_effect_emitter(&self, voice_id: u32, emitter: Option<RustSpatialEmitter>) {
        self.engine
            .effects()
            .set_voice_emitter(voice_id, emitter.map(Into::into));
    }

    /// Updates the global 3D audio listener position, velocity, and orientation vectors.
    pub fn set_listener(&self, listener: RustSpatialListener) {
        self.engine.effects().set_listener(listener.into());
    }

    /// Configures global Doppler factor and medium speed of sound in meters per second.
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        self.engine
            .effects()
            .set_doppler_parameters(factor, speed_of_sound);
    }

    // =========================================================================
    // Multiple Outputs & Live Recording Methods
    // =========================================================================

    /// Replaces the active audio output destinations in the multi-sink matrix.
    pub fn set_outputs(&self, outputs: Vec<RustAudioOutput>) -> Result<(), String> {
        map_log!(
            3,
            "[NATIVE:SET_OUTPUTS:START] set_outputs() called with {} outputs. Opening hardware off-clock...",
            outputs.len()
        );
        let t0 = Instant::now();
        self.hw.set_outputs(outputs.clone())?;
        map_log!(
            3,
            "[NATIVE:SET_OUTPUTS:DONE] set_outputs() finished in {}ms. Emitting event...",
            t0.elapsed().as_millis()
        );

        self.emit_event(RustPlayerEvent::Outputs(outputs));
        self.notify_device_watcher();
        Ok(())
    }

    /// Adds or routes an audio output destination to the output matrix.
    pub fn add_output(&self, output: RustAudioOutput) -> Result<(), String> {
        if let Some(current) = self.hw.add_output(output)? {
            self.emit_event(RustPlayerEvent::Outputs(current));
            self.notify_device_watcher();
        }
        Ok(())
    }

    /// Removes an audio output destination from the output matrix.
    pub fn remove_output(&self, output: RustAudioOutput) -> Result<(), String> {
        if let Some(current) = self.hw.remove_output(output)? {
            self.emit_event(RustPlayerEvent::Outputs(current));
            self.notify_device_watcher();
        }
        Ok(())
    }

    /// Begins recording rendered audio to a supported container at `path` with a selective source.
    pub fn start_recording(&self, path: String, format: i32, source: i32) -> Result<(), String> {
        let fmt = parse_recording_format(format)?;
        let src = AudioOutputSource::from(source);
        self.hw.start_recording(path, fmt, src)?;
        self.reporter.emit_batch([
            RustPlayerEvent::RecordedDuration(0),
            RustPlayerEvent::IsRecording(true),
            RustPlayerEvent::RecordingState {
                is_recording: true,
                source,
            },
        ]);
        Ok(())
    }

    /// Starts live lock-free recording targeting a detached POSIX file descriptor (Android `content://`).
    pub fn start_recording_fd(
        &self,
        display_path: String,
        fd: i32,
        format: i32,
        source: i32,
    ) -> Result<(), String> {
        let fmt = parse_recording_format(format)?;
        let src = AudioOutputSource::from(source);
        self.hw.start_recording_fd(display_path, fd, fmt, src)?;
        self.reporter.emit_batch([
            RustPlayerEvent::RecordedDuration(0),
            RustPlayerEvent::IsRecording(true),
            RustPlayerEvent::RecordingState {
                is_recording: true,
                source,
            },
        ]);
        Ok(())
    }

    /// Stops active file recording and returns the finalization metrics.
    pub fn stop_recording(&self) -> Result<RustRecordingResult, String> {
        let (path, dur_ms, bytes_written, sample_count, dropped_frames) =
            self.hw.stop_recording()?;
        self.reporter.emit_batch([
            RustPlayerEvent::RecordedDuration(dur_ms),
            RustPlayerEvent::IsRecording(false),
            RustPlayerEvent::RecordingState {
                is_recording: false,
                source: 0,
            },
        ]);

        Ok(RustRecordingResult {
            path,
            duration_ms: dur_ms,
            bytes_written,
            sample_count,
            dropped_frames,
        })
    }

    // =========================================================================
    // Capture & Multi-Input Methods
    // =========================================================================

    /// Replaces active audio inputs with the given set and synchronizes physical capture nodes.
    pub fn set_inputs(&self, inputs: Vec<RustAudioInput>) -> Result<(), String> {
        map_log!(
            3,
            "[NATIVE:SET_INPUTS:START] set_inputs() called with {} inputs. Opening capture hardware off-clock...",
            inputs.len()
        );
        let t0 = Instant::now();
        let current = self.hw.set_inputs(inputs)?;
        map_log!(
            3,
            "[NATIVE:SET_INPUTS:DONE] set_inputs() finished in {}ms. Emitting event...",
            t0.elapsed().as_millis()
        );

        self.emit_event(RustPlayerEvent::Inputs(current));
        Ok(())
    }

    /// Adds an audio input capture node.
    pub fn add_input(&self, input: RustAudioInput) -> Result<(), String> {
        let current = self.hw.add_input(input)?;
        self.emit_event(RustPlayerEvent::Inputs(current));
        Ok(())
    }

    /// Removes an audio input capture node by matching device identifier.
    pub fn remove_input(&self, input: RustAudioInput) -> Result<(), String> {
        let current = self.hw.remove_input(input.device_id)?;
        self.emit_event(RustPlayerEvent::Inputs(current));
        Ok(())
    }

    /// Configures runtime parameters for an existing capture node without reopening hardware.
    pub fn configure_input(
        &self,
        device_id: String,
        config: RustAudioInputConfig,
    ) -> Result<(), String> {
        let current = self.hw.configure_input(device_id, config)?;
        self.emit_event(RustPlayerEvent::Inputs(current));
        Ok(())
    }

    /// Toggles whether playback automatically pauses when an output audio device changes or disconnects.
    pub fn set_pause_on_device_change(&self, enabled: bool) {
        if let Ok(true) = self.engine.exec(move |ply| {
            let prev = ply
                .output_manager
                .pause_on_device_change
                .load(Ordering::Relaxed);
            if prev != enabled {
                ply.output_manager.set_pause_on_device_change(enabled);
                true
            } else {
                false
            }
        }) {
            self.emit_event(RustPlayerEvent::PauseOnDeviceChange(enabled));
        }
    }

    // =========================================================================
    // Device Enumeration Methods
    // =========================================================================

    /// Synchronously scans and enumerates connected playback output and capture devices in a single pass.
    pub fn get_all_devices_sync() -> Result<(Vec<RustAudioDevice>, Vec<RustAudioDevice>), String> {
        let (raw_playback, raw_capture) = crate::bridge::ffi::safe_enumerate_all_devices()
            .map_err(|e| format!("Unified device enumeration failed with code {}", e))?;

        let mut out_devs = Vec::with_capacity(raw_playback.len() + 1);
        let mut default_out_name = String::new();
        let mut default_out_effective_id = String::new();

        for d in &raw_playback {
            let dev = RustAudioDevice::from(d);
            if dev.is_default && default_out_name.is_empty() {
                default_out_name = dev.name.clone();
                default_out_effective_id = dev.effective_id.clone();
            }
            out_devs.push(dev);
        }

        if default_out_name.is_empty() && !out_devs.is_empty() {
            default_out_name = out_devs[0].name.clone();
            default_out_effective_id = out_devs[0].effective_id.clone();
        }

        let auto_out = RustAudioDevice {
            id: "AUTO".to_string(),
            effective_id: default_out_effective_id,
            name: if default_out_name.is_empty() { "SYSTEM DEFAULT".to_string() } else { default_out_name },
            is_default: true,
            is_auto: true,
        };
        out_devs.insert(0, auto_out);

        let mut in_devs = Vec::with_capacity(raw_capture.len() + 1);
        let mut default_in_name = String::new();
        let mut default_in_effective_id = String::new();

        for d in &raw_capture {
            let dev = RustAudioDevice::from(d);
            if dev.is_default && default_in_name.is_empty() {
                default_in_name = dev.name.clone();
                default_in_effective_id = dev.effective_id.clone();
            }
            in_devs.push(dev);
        }

        if default_in_name.is_empty() && !in_devs.is_empty() {
            default_in_name = in_devs[0].name.clone();
            default_in_effective_id = in_devs[0].effective_id.clone();
        }

        let auto_in = RustAudioDevice {
            id: "AUTO".to_string(),
            effective_id: default_in_effective_id,
            name: if default_in_name.is_empty() { "DEFAULT MICROPHONE".to_string() } else { default_in_name },
            is_default: true,
            is_auto: true,
        };
        in_devs.insert(0, auto_in);

        Ok((out_devs, in_devs))
    }

    /// Synchronously scans and enumerates connected playback output audio devices.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_output_devices_sync() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_all_devices_sync().map(|(out_devs, _)| out_devs)
    }

    /// Asynchronously enumerates connected playback output audio devices.
    pub fn get_output_devices() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_output_devices_sync()
    }

    /// Synchronously scans and enumerates connected microphone capture devices.
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_input_devices_sync() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_all_devices_sync().map(|(_, in_devs)| in_devs)
    }

    /// Asynchronously enumerates connected microphone capture devices.
    pub fn get_input_devices() -> Result<Vec<RustAudioDevice>, String> {
        Self::get_input_devices_sync()
    }

    /// Responds to a pending custom stream byte read request from Dart.
    #[flutter_rust_bridge::frb(sync)]
    pub fn respond_dart_read_request(
        &self,
        request_id: u64,
        bytes: Vec<u8>,
        is_eof: bool,
    ) -> Result<(), String> {
        let _ = self
            .custom_registry
            .resolve_request(request_id, bytes, is_eof);
        Ok(())
    }

    /// Responds to a pending unified source resolution request (`asset://`,
    /// `package:`, `content://`, `android.resource://`, `ws://`, etc.) from Dart.
    #[flutter_rust_bridge::frb(sync)]
    pub fn respond_dart_resolve_request(
        &self,
        request_id: u64,
        resolved: RustResolvedSource,
    ) -> Result<(), String> {
        let _ = self
            .resolve_registry
            .resolve_request(request_id, resolved);
        Ok(())
    }

    // =========================================================================
    // Multi-Bus Audio Tap (Push Broadcast & Zero-Alloc Pull)
    // =========================================================================

    /// Opens a lock-free Push stream on an audio output bus (`0`: All .. `4`: VoiceOnly).
    pub fn open_push_audio_tap(
        &self,
        client_key: u64,
        source: i32,
        format: i32,
        frame_duration_ms: u32,
        sink: StreamSink<RustAudioTapChunk>,
    ) -> Result<(), String> {
        if self.disposed.load(Ordering::Acquire) {
            return Err("AudioEngineDisposed: engine has been disposed".to_string());
        }
        let fmt = crate::core::tap::TapSampleFormat::from_i32(format)?;
        self.engine.tap_registry().add_push_tap(
            client_key,
            source,
            fmt,
            frame_duration_ms,
            Arc::new(FrbTapChunkSink { sink }),
        )
    }

    /// Unregisters a Push audio tap stream subscriber by its client key.
    pub fn close_push_audio_tap(&self, client_key: u64) -> Result<(), String> {
        self.engine.tap_registry().remove_push_tap(client_key);
        Ok(())
    }

    /// Creates a zero-allocation Pull audio tap handle for reusable buffer polling.
    pub fn create_pull_audio_tap(
        &self,
        source: i32,
        format: i32,
    ) -> Result<RustPullAudioTapInfo, String> {
        if self.disposed.load(Ordering::Acquire) {
            return Err("AudioEngineDisposed: engine has been disposed".to_string());
        }
        let fmt = crate::core::tap::TapSampleFormat::from_i32(format)?;
        let handle = self.engine.tap_registry().create_pull_tap(source, fmt)?;
        Ok(RustPullAudioTapInfo {
            tap_id: handle.tap_id,
            source,
            format: fmt as i32,
            sample_rate: handle.sample_rate,
            channels: handle.channels as u32,
        })
    }

    /// Explicitly closes a Pull audio tap handle by ID and updates the active bus bitmask.
    pub fn close_pull_audio_tap(&self, tap_id: u32) -> Result<(), String> {
        self.engine.tap_registry().close_pull_tap(tap_id);
        Ok(())
    }

    /// Returns cumulative dropped frames observed by a Pull tap handle (wait/block-free).
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_pull_audio_tap_dropped(&self, tap_id: u32) -> u64 {
        crate::core::tap::lookup_pull_tap_nonblocking(tap_id)
            .map(|h| h.total_dropped_frames())
            .unwrap_or(0)
    }

    /// Returns the bitmask of active tapped buses (`0` when no taps are open).
    #[flutter_rust_bridge::frb(sync)]
    pub fn get_active_tap_bus_mask(&self) -> u8 {
        self.engine.tap_registry().active_bus_mask()
    }

    // =========================================================================
    // Lifecycle Disposal
    // =========================================================================

    /// Releases all native audio devices, worker threads, DSP chains, and memory.
    #[flutter_rust_bridge::frb(sync)]
    pub fn dispose(&self) {
        if self.disposed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.monitor_running.store(false, Ordering::Release);
        self.engine.snapshots().notify_telemetry_waiters();
        self.notify_device_watcher();
        self.custom_registry.abort_all();
        self.resolve_registry.cancel_all();
        self.reporter.clear_sink();
        self.engine.tap_registry().shutdown();
        self.coordinator.shutdown();
        if let Some(jh) = lock_unpoisoned(&self.monitor_thread).take() {
            let _ = jh.join();
        }
        if let Some(jh) = lock_unpoisoned(&self.watcher_thread).take() {
            let _ = jh.join();
        }
        self.engine.shutdown();
    }
}

// =========================================================================
// Top-Level Static Analysis & Utility Functions
// =========================================================================

/// Sets the global native diagnostic logging verbosity level.
#[flutter_rust_bridge::frb(sync)]
pub fn set_log_level(level: i32) {
    crate::LOG_LEVEL.store(level, Ordering::Relaxed);
}

/// Asynchronously analyzes acoustic, loudness, waveform, and metadata properties of any audio source.
pub fn analyze_audio_source(
    source: RustAudioSource,
    pre_resolved: Option<RustResolvedSource>,
    config: RustAnalysisConfig,
) -> Result<RustAudioAnalysisResult, String> {
    let resolved = pre_resolved.map(ResolvedCoreSource::from_rust);
    crate::dsp::analysis::analyze_audio_source_with_resolved(source.into(), resolved, config)
}

/// Synchronously analyzes acoustic, loudness, waveform, and metadata properties of a local audio source.
#[flutter_rust_bridge::frb(sync)]
pub fn analyze_audio_source_sync(
    source: RustAudioSource,
    config: RustAnalysisConfig,
) -> Result<RustAudioAnalysisResult, String> {
    crate::dsp::analysis::analyze_audio_source(source.into(), config)
}

/// Encodes one lossless WavPack (`.wv`) stream block from interleaved little-endian PCM bytes
/// (`pcm16` i16-LE or `float32` f32-LE) for Web OPFS and custom Dart recording buffers.
pub fn encode_wavpack_block(
    sample_rate: u32,
    channels: u16,
    is_float: bool,
    block_index: u64,
    pcm_bytes: Vec<u8>,
) -> Result<Vec<u8>, String> {
    crate::core::recording::encode_wavpack_block_wire_bytes(
        sample_rate,
        channels,
        is_float,
        block_index,
        &pcm_bytes,
    )
}

#[cfg(test)]
mod p0_tests {
    use super::*;
    use crate::api::types::RustBuffer;

    #[test]
    fn atomic_telemetry_filter_emits_on_start_ms_change_and_resets_on_track_change() {
        let filter = AtomicTelemetryFilter::default();

        let b0 = RustPlayerEvent::Buffer(RustBuffer {
            start_ms: 0,
            end_ms: 30_000,
            is_buffering: false,
        });
        assert!(filter.should_emit(&b0));
        assert!(!filter.should_emit(&b0), "identical buffer range should be deduplicated");

        // Advance only `start_ms` (e.g. ring eviction or forward flush): must emit even when `end_ms` is unchanged.
        let b1 = RustPlayerEvent::Buffer(RustBuffer {
            start_ms: 12_500,
            end_ms: 30_000,
            is_buffering: false,
        });
        assert!(filter.should_emit(&b1));
        assert!(!filter.should_emit(&b1));

        // Changing `CurrentIndex` clears buffered_start/buffered_end sentinels so new track re-emits `0..0`.
        assert!(filter.should_emit(&RustPlayerEvent::CurrentIndex(1)));
        let b_reset = RustPlayerEvent::Buffer(RustBuffer {
            start_ms: 12_500,
            end_ms: 30_000,
            is_buffering: false,
        });
        assert!(filter.should_emit(&b_reset));
    }

    #[test]
    fn atomic_telemetry_filter_does_not_alias_is_buffering_and_buffer_events() {
        let filter = AtomicTelemetryFilter::default();

        // Enter buffering with range [5_000 .. 12_000]. Both events must emit.
        assert!(filter.should_emit(&RustPlayerEvent::IsBuffering(true)));
        assert!(filter.should_emit(&RustPlayerEvent::Buffer(RustBuffer {
            start_ms: 5_000,
            end_ms: 12_000,
            is_buffering: true,
        })));

        // Seek finishes decoding before the next block arrives: range stays [5_000 .. 12_000]
        // while `IsBuffering(false)` is queued just before `Buffer(..., is_buffering: false)`.
        // Previously both events mutated one shared AtomicU8, causing `Buffer` to be dropped.
        assert!(filter.should_emit(&RustPlayerEvent::IsBuffering(false)));
        assert!(
            filter.should_emit(&RustPlayerEvent::Buffer(RustBuffer {
                start_ms: 5_000,
                end_ms: 12_000,
                is_buffering: false,
            })),
            "Buffer event must still emit when is_buffering flips to false on unchanged range"
        );
    }
}
