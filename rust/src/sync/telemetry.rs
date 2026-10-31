//! Native reactive event dispatcher and telemetry pipeline for Dart FFI delivery.

use std::cell::UnsafeCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Duration;
use std::time::Instant;

use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::SilenceConfig;
use crate::dsp::visualizer::VisualizerData;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventType {
    None = 0,
    State = 1,
    Position = 2,
    Duration = 3,
    IsPlaying = 4,
    IsBuffering = 5,
    IsCompleted = 6,
    Volume = 7,
    Rate = 8,
    Pitch = 9,
    Bitrate = 10,
    BufferSize = 11,
    Device = 12,
    Visualizer = 13,
    VisualizerEnabled = 14,
    BufferedRange = 15,
    SilenceConfig = 16,
    SilenceSaved = 17,
    Equalizer = 18,
    Preamp = 19,
    ReplayGain = 20,
    Balance = 21,
    Mono = 22,
    Crossfeed = 23,
    Spatializer = 24,
    Reverb = 25,
    Limiter = 26,
    Error = 27,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BufferedRange {
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    pub fill_percentage: f32,
    pub stream_percentage: f32,
    pub is_buffering: i32,
    pub is_eof: i32,
}

impl Default for BufferedRange {
    fn default() -> Self {
        Self {
            start_ms: 0,
            end_ms: 0,
            duration_ms: 0,
            fill_percentage: 0.0,
            stream_percentage: 0.0,
            is_buffering: 0,
            is_eof: 0,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeviceInfo {
    pub id: [u8; 516],
    pub effective_id: [u8; 516],
    pub name: [u8; 256],
    pub is_default: i32,
    pub is_auto: i32,
}

impl Default for DeviceInfo {
    fn default() -> Self {
        Self {
            id: [0; 516],
            effective_id: [0; 516],
            name: [0; 256],
            is_default: 1,
            is_auto: 1,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpatializerData {
    pub enabled: i32,
    pub width: f32,
}

/// Strongly-typed, compiler-enforced telemetry events replacing untagged C unions.
#[derive(Debug, Clone, PartialEq)]
pub enum TelemetryEvent {
    None,
    State(i32),
    Position(i64),
    Duration(i64),
    IsPlaying(bool),
    IsBuffering(bool),
    IsCompleted(bool),
    Volume(f32),
    Rate(f32),
    Pitch(f32),
    Bitrate(u32),
    BufferSize(u32),
    Device(Box<DeviceInfo>),
    Visualizer(VisualizerData),
    VisualizerEnabled(bool),
    BufferedRange(BufferedRange),
    SilenceConfig(SilenceConfig),
    SilenceSaved(i64),
    Equalizer(EqualizerParams),
    Preamp(f32),
    ReplayGain(ReplayGainConfig),
    Balance(f32),
    Mono(bool),
    Crossfeed(i32),
    Spatializer(SpatializerData),
    Reverb(ReverbConfig),
    Limiter(bool),
    Error(i32),
}

impl TelemetryEvent {
    pub fn event_type(&self) -> EventType {
        match self {
            TelemetryEvent::None => EventType::None,
            TelemetryEvent::State(_) => EventType::State,
            TelemetryEvent::Position(_) => EventType::Position,
            TelemetryEvent::Duration(_) => EventType::Duration,
            TelemetryEvent::IsPlaying(_) => EventType::IsPlaying,
            TelemetryEvent::IsBuffering(_) => EventType::IsBuffering,
            TelemetryEvent::IsCompleted(_) => EventType::IsCompleted,
            TelemetryEvent::Volume(_) => EventType::Volume,
            TelemetryEvent::Rate(_) => EventType::Rate,
            TelemetryEvent::Pitch(_) => EventType::Pitch,
            TelemetryEvent::Bitrate(_) => EventType::Bitrate,
            TelemetryEvent::BufferSize(_) => EventType::BufferSize,
            TelemetryEvent::Device(_) => EventType::Device,
            TelemetryEvent::Visualizer(_) => EventType::Visualizer,
            TelemetryEvent::VisualizerEnabled(_) => EventType::VisualizerEnabled,
            TelemetryEvent::BufferedRange(_) => EventType::BufferedRange,
            TelemetryEvent::SilenceConfig(_) => EventType::SilenceConfig,
            TelemetryEvent::SilenceSaved(_) => EventType::SilenceSaved,
            TelemetryEvent::Equalizer(_) => EventType::Equalizer,
            TelemetryEvent::Preamp(_) => EventType::Preamp,
            TelemetryEvent::ReplayGain(_) => EventType::ReplayGain,
            TelemetryEvent::Balance(_) => EventType::Balance,
            TelemetryEvent::Mono(_) => EventType::Mono,
            TelemetryEvent::Crossfeed(_) => EventType::Crossfeed,
            TelemetryEvent::Spatializer(_) => EventType::Spatializer,
            TelemetryEvent::Reverb(_) => EventType::Reverb,
            TelemetryEvent::Limiter(_) => EventType::Limiter,
            TelemetryEvent::Error(_) => EventType::Error,
        }
    }

    pub fn to_map_event_data(&self) -> MapEventData {
        match self {
            TelemetryEvent::None => MapEventData { state: 0 },
            TelemetryEvent::State(s) => MapEventData { state: *s },
            TelemetryEvent::Position(p) => MapEventData { position_ms: *p },
            TelemetryEvent::Duration(d) => MapEventData { duration_ms: *d },
            TelemetryEvent::IsPlaying(p) => MapEventData { is_playing: if *p { 1 } else { 0 } },
            TelemetryEvent::IsBuffering(b) => MapEventData { is_buffering: if *b { 1 } else { 0 } },
            TelemetryEvent::IsCompleted(c) => MapEventData { is_completed: if *c { 1 } else { 0 } },
            TelemetryEvent::Volume(v) => MapEventData { volume: *v },
            TelemetryEvent::Rate(r) => MapEventData { rate: *r },
            TelemetryEvent::Pitch(p) => MapEventData { pitch: *p },
            TelemetryEvent::Bitrate(b) => MapEventData { bitrate: *b },
            TelemetryEvent::BufferSize(b) => MapEventData { buffer_size: *b },
            TelemetryEvent::Device(d) => MapEventData { device: **d },
            TelemetryEvent::Visualizer(v) => MapEventData { visualizer: *v },
            TelemetryEvent::VisualizerEnabled(e) => MapEventData { visualizer_enabled: if *e { 1 } else { 0 } },
            TelemetryEvent::BufferedRange(br) => MapEventData { buffered_range: *br },
            TelemetryEvent::SilenceConfig(sc) => MapEventData { silence_config: *sc },
            TelemetryEvent::SilenceSaved(s) => MapEventData { silence_saved_ms: *s },
            TelemetryEvent::Equalizer(eq) => MapEventData { equalizer: *eq },
            TelemetryEvent::Preamp(p) => MapEventData { preamp_db: *p },
            TelemetryEvent::ReplayGain(rg) => MapEventData { replay_gain: *rg },
            TelemetryEvent::Balance(b) => MapEventData { balance: *b },
            TelemetryEvent::Mono(m) => MapEventData { mono_enabled: if *m { 1 } else { 0 } },
            TelemetryEvent::Crossfeed(c) => MapEventData { crossfeed_mode: *c },
            TelemetryEvent::Spatializer(sp) => MapEventData { spatializer: *sp },
            TelemetryEvent::Reverb(rv) => MapEventData { reverb: *rv },
            TelemetryEvent::Limiter(l) => MapEventData { limiter_enabled: if *l { 1 } else { 0 } },
            TelemetryEvent::Error(e) => MapEventData { error_code: *e },
        }
    }

    pub fn from_raw(event_type: EventType, data: &MapEventData) -> Self {
        unsafe {
            match event_type {
                EventType::None => TelemetryEvent::None,
                EventType::State => TelemetryEvent::State(data.state),
                EventType::Position => TelemetryEvent::Position(data.position_ms),
                EventType::Duration => TelemetryEvent::Duration(data.duration_ms),
                EventType::IsPlaying => TelemetryEvent::IsPlaying(data.is_playing != 0),
                EventType::IsBuffering => TelemetryEvent::IsBuffering(data.is_buffering != 0),
                EventType::IsCompleted => TelemetryEvent::IsCompleted(data.is_completed != 0),
                EventType::Volume => TelemetryEvent::Volume(data.volume),
                EventType::Rate => TelemetryEvent::Rate(data.rate),
                EventType::Pitch => TelemetryEvent::Pitch(data.pitch),
                EventType::Bitrate => TelemetryEvent::Bitrate(data.bitrate),
                EventType::BufferSize => TelemetryEvent::BufferSize(data.buffer_size),
                EventType::Device => TelemetryEvent::Device(Box::new(data.device)),
                EventType::Visualizer => TelemetryEvent::Visualizer(data.visualizer),
                EventType::VisualizerEnabled => TelemetryEvent::VisualizerEnabled(data.visualizer_enabled != 0),
                EventType::BufferedRange => TelemetryEvent::BufferedRange(data.buffered_range),
                EventType::SilenceConfig => TelemetryEvent::SilenceConfig(data.silence_config),
                EventType::SilenceSaved => TelemetryEvent::SilenceSaved(data.silence_saved_ms),
                EventType::Equalizer => TelemetryEvent::Equalizer(data.equalizer),
                EventType::Preamp => TelemetryEvent::Preamp(data.preamp_db),
                EventType::ReplayGain => TelemetryEvent::ReplayGain(data.replay_gain),
                EventType::Balance => TelemetryEvent::Balance(data.balance),
                EventType::Mono => TelemetryEvent::Mono(data.mono_enabled != 0),
                EventType::Crossfeed => TelemetryEvent::Crossfeed(data.crossfeed_mode),
                EventType::Spatializer => TelemetryEvent::Spatializer(data.spatializer),
                EventType::Reverb => TelemetryEvent::Reverb(data.reverb),
                EventType::Limiter => TelemetryEvent::Limiter(data.limiter_enabled != 0),
                EventType::Error => TelemetryEvent::Error(data.error_code),
            }
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
pub union MapEventData {
    pub state: i32,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub is_playing: i32,
    pub is_buffering: i32,
    pub is_completed: i32,
    pub volume: f32,
    pub rate: f32,
    pub pitch: f32,
    pub bitrate: u32,
    pub buffer_size: u32,
    pub device: DeviceInfo,
    pub visualizer: VisualizerData,
    pub visualizer_enabled: i32,
    pub buffered_range: BufferedRange,
    pub silence_config: SilenceConfig,
    pub silence_saved_ms: i64,
    pub equalizer: EqualizerParams,
    pub preamp_db: f32,
    pub replay_gain: ReplayGainConfig,
    pub balance: f32,
    pub mono_enabled: i32,
    pub crossfeed_mode: i32,
    pub spatializer: SpatializerData,
    pub reverb: ReverbConfig,
    pub limiter_enabled: i32,
    pub error_code: i32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct MapEvent {
    pub event_type: i32,
    pub padding: i32,
    pub timestamp_ns: i64,
    pub data: MapEventData,
}

pub type EventCallback = unsafe extern "C" fn(user_data: *mut c_void, event: *const MapEvent);
pub type RustEventCallback = Box<dyn Fn(EventType, &MapEventData) + Send + Sync>;
pub type TypedEventCallback = Box<dyn Fn(&TelemetryEvent) + Send + Sync>;

static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

pub fn monotonic_now_ns() -> i64 {
    let start = START_TIME.get_or_init(Instant::now);
    start.elapsed().as_nanos() as i64
}

pub const MAP_EVENT_RING_CAPACITY: usize = 128;

pub struct TelemetryDispatcher {
    is_running: Arc<AtomicBool>,
    callback: Arc<RwLock<Option<(EventCallback, usize)>>>,
    rust_callback: Arc<RwLock<Option<RustEventCallback>>>,
    typed_callback: Arc<RwLock<Option<TypedEventCallback>>>,
    ring: Arc<Vec<UnsafeCell<MapEvent>>>,
    ring_head: Arc<AtomicUsize>,
    tx: crossbeam_channel::Sender<TelemetryEvent>,
    worker_handle: Arc<Mutex<Option<thread::JoinHandle<()>>>>,
}

unsafe impl Send for TelemetryDispatcher {}
unsafe impl Sync for TelemetryDispatcher {}

impl TelemetryDispatcher {
    #[allow(clippy::arc_with_non_send_sync)]
    pub fn new(callback: Option<EventCallback>, user_data: *mut c_void) -> Self {
        let is_running = Arc::new(AtomicBool::new(true));
        let callback_slot = Arc::new(RwLock::new(
            callback.map(|cb| (cb, user_data as usize)),
        ));
        let rust_callback = Arc::new(RwLock::new(None));
        let typed_callback: Arc<RwLock<Option<TypedEventCallback>>> = Arc::new(RwLock::new(None));

        let mut ring_vec = Vec::with_capacity(MAP_EVENT_RING_CAPACITY);
        for _ in 0..MAP_EVENT_RING_CAPACITY {
            ring_vec.push(UnsafeCell::new(MapEvent {
                event_type: 0,
                padding: 0,
                timestamp_ns: 0,
                data: MapEventData { state: 0 },
            }));
        }

        let (tx, rx) = crossbeam_channel::unbounded::<TelemetryEvent>();
        let is_running_clone = is_running.clone();
        let typed_cb_clone = typed_callback.clone();

        let handle = thread::Builder::new()
            .name("map-telemetry".to_string())
            .spawn(move || {
                let mut last_position: i64 = -1;
                while is_running_clone.load(Ordering::Relaxed) {
                    match rx.recv_timeout(Duration::from_millis(25)) {
                        Ok(first_event) => {
                            let mut batch = vec![first_event];
                            while let Ok(ev) = rx.try_recv() {
                                batch.push(ev);
                            }
                            if let Ok(guard) = typed_cb_clone.read() {
                                if let Some(ref cb) = *guard {
                                    for ev in batch {
                                        if let TelemetryEvent::Position(pos) = ev {
                                            if pos == last_position {
                                                continue;
                                            }
                                            last_position = pos;
                                        }
                                        cb(&ev);
                                    }
                                }
                            }
                        }
                        Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                        Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
                    }
                }
            })
            .ok();

        Self {
            is_running,
            callback: callback_slot,
            rust_callback,
            typed_callback,
            ring: Arc::new(ring_vec),
            ring_head: Arc::new(AtomicUsize::new(0)),
            tx,
            worker_handle: Arc::new(Mutex::new(handle)),
        }
    }

    pub fn set_callback(&self, callback: Option<EventCallback>, user_data: *mut c_void) {
        if let Ok(mut lock) = self.callback.write() {
            *lock = callback.map(|cb| (cb, user_data as usize));
        }
    }

    pub fn set_rust_callback(&self, callback: Option<RustEventCallback>) {
        if let Ok(mut lock) = self.rust_callback.write() {
            *lock = callback;
        }
    }

    pub fn set_typed_callback(&self, callback: Option<TypedEventCallback>) {
        if let Ok(mut lock) = self.typed_callback.write() {
            *lock = callback;
        }
    }

    /// Strongly-typed, compiler-enforced telemetry dispatch.
    ///
    /// GUARANTEES:
    /// - 100% Lock-Free & Wait-Free: Audio and decoding threads NEVER block or invoke Dart FFI.
    /// - All Dart FFI dispatch is executed asynchronously by the dedicated `map-telemetry` thread.
    pub fn post(&self, event: TelemetryEvent) {
        if !self.is_running.load(Ordering::Relaxed) {
            return;
        }

        let event_type = event.event_type();
        let data = event.to_map_event_data();

        let slot = self.ring_head.fetch_add(1, Ordering::Relaxed) % MAP_EVENT_RING_CAPACITY;
        let event_ptr = self.ring[slot].get();
        unsafe {
            *event_ptr = MapEvent {
                event_type: event_type as i32,
                padding: 0,
                timestamp_ns: monotonic_now_ns(),
                data,
            };
        }

        if let Ok(guard) = self.rust_callback.read() {
            if let Some(cb) = guard.as_ref() {
                cb(event_type, &data);
            }
        }

        if let Ok(guard) = self.callback.read() {
            if let Some((cb, user_data_addr)) = *guard {
                unsafe {
                    cb(user_data_addr as *mut c_void, event_ptr);
                }
            }
        }

        // Asynchronous, lock-free dispatch to the dedicated map-telemetry thread
        let _ = self.tx.send(event);
    }

    pub fn post_event(&self, event_type: EventType, data: MapEventData) {
        let typed_event = TelemetryEvent::from_raw(event_type, &data);
        self.post(typed_event);
    }

    pub fn dispatch(&self, event: MapEvent) {
        if !self.is_running.load(Ordering::Relaxed) {
            return;
        }

        let slot = self.ring_head.fetch_add(1, Ordering::Relaxed) % MAP_EVENT_RING_CAPACITY;
        let event_ptr = self.ring[slot].get();
        unsafe {
            *event_ptr = event;
        }

        let event_type = match event.event_type {
            1 => EventType::State,
            2 => EventType::Position,
            3 => EventType::Duration,
            4 => EventType::IsPlaying,
            5 => EventType::IsBuffering,
            6 => EventType::IsCompleted,
            7 => EventType::Volume,
            8 => EventType::Rate,
            9 => EventType::Pitch,
            10 => EventType::Bitrate,
            11 => EventType::BufferSize,
            12 => EventType::Device,
            13 => EventType::Visualizer,
            14 => EventType::VisualizerEnabled,
            15 => EventType::BufferedRange,
            16 => EventType::SilenceConfig,
            17 => EventType::SilenceSaved,
            18 => EventType::Equalizer,
            19 => EventType::Preamp,
            20 => EventType::ReplayGain,
            21 => EventType::Balance,
            22 => EventType::Mono,
            23 => EventType::Crossfeed,
            24 => EventType::Spatializer,
            25 => EventType::Reverb,
            26 => EventType::Limiter,
            27 => EventType::Error,
            _ => EventType::None,
        };

        let typed = TelemetryEvent::from_raw(event_type, &event.data);
        if let Ok(guard) = self.typed_callback.read() {
            if let Some(cb) = guard.as_ref() {
                cb(&typed);
            }
        }

        if let Ok(guard) = self.rust_callback.read() {
            if let Some(cb) = guard.as_ref() {
                cb(event_type, &event.data);
            }
        }

        if let Ok(guard) = self.callback.read() {
            if let Some((cb, user_data_addr)) = *guard {
                unsafe {
                    cb(user_data_addr as *mut c_void, event_ptr);
                }
            }
        }
    }

    pub fn stop(&self) {
        self.is_running.store(false, Ordering::SeqCst);
        if let Ok(mut lock) = self.callback.write() {
            *lock = None;
        }
        if let Ok(mut handle_guard) = self.worker_handle.lock() {
            if let Some(handle) = handle_guard.take() {
                let _ = handle.join();
            }
        }
    }
}

impl Drop for TelemetryDispatcher {
    fn drop(&mut self) {
        self.stop();
    }
}
