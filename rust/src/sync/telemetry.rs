//! Native reactive event dispatcher and telemetry pipeline for Dart FFI delivery.

use std::cell::UnsafeCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::{Duration, Instant};

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

impl EventType {
    #[inline]
    pub fn from_i32(code: i32) -> Self {
        match code {
            1 => Self::State,
            2 => Self::Position,
            3 => Self::Duration,
            4 => Self::IsPlaying,
            5 => Self::IsBuffering,
            6 => Self::IsCompleted,
            7 => Self::Volume,
            8 => Self::Rate,
            9 => Self::Pitch,
            10 => Self::Bitrate,
            11 => Self::BufferSize,
            12 => Self::Device,
            13 => Self::Visualizer,
            14 => Self::VisualizerEnabled,
            15 => Self::BufferedRange,
            16 => Self::SilenceConfig,
            17 => Self::SilenceSaved,
            18 => Self::Equalizer,
            19 => Self::Preamp,
            20 => Self::ReplayGain,
            21 => Self::Balance,
            22 => Self::Mono,
            23 => Self::Crossfeed,
            24 => Self::Spatializer,
            25 => Self::Reverb,
            26 => Self::Limiter,
            27 => Self::Error,
            _ => Self::None,
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct BufferedRange {
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    pub fill_percentage: f32,
    pub stream_percentage: f32,
    pub is_buffering: i32,
    pub is_eof: i32,
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
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct SpatializerData {
    pub enabled: i32,
    pub width: f32,
}

/// Strongly-typed, deterministic telemetry events.
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
    #[inline]
    pub fn event_type(&self) -> EventType {
        match self {
            Self::None => EventType::None,
            Self::State(_) => EventType::State,
            Self::Position(_) => EventType::Position,
            Self::Duration(_) => EventType::Duration,
            Self::IsPlaying(_) => EventType::IsPlaying,
            Self::IsBuffering(_) => EventType::IsBuffering,
            Self::IsCompleted(_) => EventType::IsCompleted,
            Self::Volume(_) => EventType::Volume,
            Self::Rate(_) => EventType::Rate,
            Self::Pitch(_) => EventType::Pitch,
            Self::Bitrate(_) => EventType::Bitrate,
            Self::BufferSize(_) => EventType::BufferSize,
            Self::Device(_) => EventType::Device,
            Self::Visualizer(_) => EventType::Visualizer,
            Self::VisualizerEnabled(_) => EventType::VisualizerEnabled,
            Self::BufferedRange(_) => EventType::BufferedRange,
            Self::SilenceConfig(_) => EventType::SilenceConfig,
            Self::SilenceSaved(_) => EventType::SilenceSaved,
            Self::Equalizer(_) => EventType::Equalizer,
            Self::Preamp(_) => EventType::Preamp,
            Self::ReplayGain(_) => EventType::ReplayGain,
            Self::Balance(_) => EventType::Balance,
            Self::Mono(_) => EventType::Mono,
            Self::Crossfeed(_) => EventType::Crossfeed,
            Self::Spatializer(_) => EventType::Spatializer,
            Self::Reverb(_) => EventType::Reverb,
            Self::Limiter(_) => EventType::Limiter,
            Self::Error(_) => EventType::Error,
        }
    }

    #[inline]
    pub fn to_map_event_data(&self) -> MapEventData {
        match self {
            Self::None => MapEventData { state: 0 },
            Self::State(s) => MapEventData { state: *s },
            Self::Position(p) => MapEventData { position_ms: *p },
            Self::Duration(d) => MapEventData { duration_ms: *d },
            Self::IsPlaying(p) => MapEventData { is_playing: i32::from(*p) },
            Self::IsBuffering(b) => MapEventData { is_buffering: i32::from(*b) },
            Self::IsCompleted(c) => MapEventData { is_completed: i32::from(*c) },
            Self::Volume(v) => MapEventData { volume: *v },
            Self::Rate(r) => MapEventData { rate: *r },
            Self::Pitch(p) => MapEventData { pitch: *p },
            Self::Bitrate(b) => MapEventData { bitrate: *b },
            Self::BufferSize(b) => MapEventData { buffer_size: *b },
            Self::Device(d) => MapEventData { device: **d },
            Self::Visualizer(v) => MapEventData { visualizer: *v },
            Self::VisualizerEnabled(e) => MapEventData { visualizer_enabled: i32::from(*e) },
            Self::BufferedRange(br) => MapEventData { buffered_range: *br },
            Self::SilenceConfig(sc) => MapEventData { silence_config: *sc },
            Self::SilenceSaved(s) => MapEventData { silence_saved_ms: *s },
            Self::Equalizer(eq) => MapEventData { equalizer: *eq },
            Self::Preamp(p) => MapEventData { preamp_db: *p },
            Self::ReplayGain(rg) => MapEventData { replay_gain: *rg },
            Self::Balance(b) => MapEventData { balance: *b },
            Self::Mono(m) => MapEventData { mono_enabled: i32::from(*m) },
            Self::Crossfeed(c) => MapEventData { crossfeed_mode: *c },
            Self::Spatializer(sp) => MapEventData { spatializer: *sp },
            Self::Reverb(rv) => MapEventData { reverb: *rv },
            Self::Limiter(l) => MapEventData { limiter_enabled: i32::from(*l) },
            Self::Error(e) => MapEventData { error_code: *e },
        }
    }

    #[inline]
    pub fn to_map_event(&self) -> MapEvent {
        MapEvent {
            event_type: self.event_type() as i32,
            padding: 0,
            timestamp_ns: monotonic_now_ns(),
            data: self.to_map_event_data(),
        }
    }

    pub fn from_raw(event_type: EventType, data: &MapEventData) -> Self {
        unsafe {
            match event_type {
                EventType::None => Self::None,
                EventType::State => Self::State(data.state),
                EventType::Position => Self::Position(data.position_ms),
                EventType::Duration => Self::Duration(data.duration_ms),
                EventType::IsPlaying => Self::IsPlaying(data.is_playing != 0),
                EventType::IsBuffering => Self::IsBuffering(data.is_buffering != 0),
                EventType::IsCompleted => Self::IsCompleted(data.is_completed != 0),
                EventType::Volume => Self::Volume(data.volume),
                EventType::Rate => Self::Rate(data.rate),
                EventType::Pitch => Self::Pitch(data.pitch),
                EventType::Bitrate => Self::Bitrate(data.bitrate),
                EventType::BufferSize => Self::BufferSize(data.buffer_size),
                EventType::Device => Self::Device(Box::new(data.device)),
                EventType::Visualizer => Self::Visualizer(data.visualizer),
                EventType::VisualizerEnabled => Self::VisualizerEnabled(data.visualizer_enabled != 0),
                EventType::BufferedRange => Self::BufferedRange(data.buffered_range),
                EventType::SilenceConfig => Self::SilenceConfig(data.silence_config),
                EventType::SilenceSaved => Self::SilenceSaved(data.silence_saved_ms),
                EventType::Equalizer => Self::Equalizer(data.equalizer),
                EventType::Preamp => Self::Preamp(data.preamp_db),
                EventType::ReplayGain => Self::ReplayGain(data.replay_gain),
                EventType::Balance => Self::Balance(data.balance),
                EventType::Mono => Self::Mono(data.mono_enabled != 0),
                EventType::Crossfeed => Self::Crossfeed(data.crossfeed_mode),
                EventType::Spatializer => Self::Spatializer(data.spatializer),
                EventType::Reverb => Self::Reverb(data.reverb),
                EventType::Limiter => Self::Limiter(data.limiter_enabled != 0),
                EventType::Error => Self::Error(data.error_code),
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

#[inline]
pub fn monotonic_now_ns() -> i64 {
    let start = START_TIME.get_or_init(Instant::now);
    start.elapsed().as_nanos() as i64
}

pub const MAP_EVENT_RING_CAPACITY: usize = 128;

/// Fixed-capacity circular arena for C-ABI `MapEvent` pointers.
struct EventRingArena {
    slots: Vec<UnsafeCell<MapEvent>>,
    head: AtomicUsize,
}

unsafe impl Send for EventRingArena {}
unsafe impl Sync for EventRingArena {}

impl EventRingArena {
    fn new(capacity: usize) -> Self {
        let mut slots = Vec::with_capacity(capacity);
        for _ in 0..capacity {
            slots.push(UnsafeCell::new(MapEvent {
                event_type: 0,
                padding: 0,
                timestamp_ns: 0,
                data: MapEventData { state: 0 },
            }));
        }
        Self {
            slots,
            head: AtomicUsize::new(0),
        }
    }

    #[inline]
    fn write_slot(&self, event: MapEvent) -> *const MapEvent {
        let idx = self.head.fetch_add(1, Ordering::Relaxed) % self.slots.len();
        let ptr = self.slots[idx].get();
        unsafe {
            *ptr = event;
        }
        ptr
    }
}

/// Encapsulates all registered telemetry callbacks with single-responsibility notification methods.
#[derive(Default)]
struct CallbackRegistry {
    c_callback: RwLock<Option<(EventCallback, usize)>>,
    rust_callback: RwLock<Option<RustEventCallback>>,
    typed_callback: RwLock<Option<TypedEventCallback>>,
}

impl CallbackRegistry {
    fn set_c(&self, cb: Option<EventCallback>, user_data: *mut c_void) {
        if let Ok(mut guard) = self.c_callback.write() {
            *guard = cb.map(|f| (f, user_data as usize));
        }
    }

    fn set_rust(&self, cb: Option<RustEventCallback>) {
        if let Ok(mut guard) = self.rust_callback.write() {
            *guard = cb;
        }
    }

    fn set_typed(&self, cb: Option<TypedEventCallback>) {
        if let Ok(mut guard) = self.typed_callback.write() {
            *guard = cb;
        }
    }

    fn notify_immediate(&self, event_type: EventType, data: &MapEventData, event_ptr: *const MapEvent) {
        if let Ok(guard) = self.rust_callback.read() {
            if let Some(cb) = guard.as_ref() {
                cb(event_type, data);
            }
        }
        if let Ok(guard) = self.c_callback.read() {
            if let Some((cb, user_data_addr)) = *guard {
                unsafe {
                    cb(user_data_addr as *mut c_void, event_ptr);
                }
            }
        }
    }

    fn notify_typed_batch(&self, batch: &[TelemetryEvent], last_position: &mut i64) {
        if let Ok(guard) = self.typed_callback.read() {
            if let Some(cb) = guard.as_ref() {
                for ev in batch {
                    if let TelemetryEvent::Position(pos) = *ev {
                        if pos == *last_position {
                            continue;
                        }
                        *last_position = pos;
                    }
                    cb(ev);
                }
            }
        }
    }
}

pub struct TelemetryDispatcher {
    is_running: Arc<AtomicBool>,
    callbacks: Arc<CallbackRegistry>,
    arena: Arc<EventRingArena>,
    tx: crossbeam_channel::Sender<TelemetryEvent>,
    worker_handle: Mutex<Option<thread::JoinHandle<()>>>,
}

impl TelemetryDispatcher {
    pub fn new(callback: Option<EventCallback>, user_data: *mut c_void) -> Self {
        let is_running = Arc::new(AtomicBool::new(true));
        let callbacks = Arc::new(CallbackRegistry::default());
        callbacks.set_c(callback, user_data);

        let arena = Arc::new(EventRingArena::new(MAP_EVENT_RING_CAPACITY));
        let (tx, rx) = crossbeam_channel::unbounded::<TelemetryEvent>();

        let worker_handle = Self::spawn_worker(is_running.clone(), callbacks.clone(), rx);

        Self {
            is_running,
            callbacks,
            arena,
            tx,
            worker_handle: Mutex::new(worker_handle),
        }
    }

    fn spawn_worker(
        is_running: Arc<AtomicBool>,
        callbacks: Arc<CallbackRegistry>,
        rx: crossbeam_channel::Receiver<TelemetryEvent>,
    ) -> Option<thread::JoinHandle<()>> {
        thread::Builder::new()
            .name("map-telemetry".to_string())
            .spawn(move || {
                let mut last_position: i64 = -1;
                while is_running.load(Ordering::Relaxed) {
                    match rx.recv_timeout(Duration::from_millis(25)) {
                        Ok(first_event) => {
                            let mut batch = vec![first_event];
                            while let Ok(ev) = rx.try_recv() {
                                batch.push(ev);
                            }
                            callbacks.notify_typed_batch(&batch, &mut last_position);
                        }
                        Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                        Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
                    }
                }
            })
            .ok()
    }

    pub fn set_callback(&self, callback: Option<EventCallback>, user_data: *mut c_void) {
        self.callbacks.set_c(callback, user_data);
    }

    pub fn set_rust_callback(&self, callback: Option<RustEventCallback>) {
        self.callbacks.set_rust(callback);
    }

    pub fn set_typed_callback(&self, callback: Option<TypedEventCallback>) {
        self.callbacks.set_typed(callback);
    }

    /// Primary deterministic telemetry dispatch entry point.
    pub fn post(&self, event: TelemetryEvent) {
        if !self.is_running.load(Ordering::Relaxed) {
            return;
        }
        let map_event = event.to_map_event();
        let event_type = event.event_type();
        let event_ptr = self.arena.write_slot(map_event);

        self.callbacks.notify_immediate(event_type, &map_event.data, event_ptr);
        let _ = self.tx.send(event);
    }

    #[inline]
    pub fn post_event(&self, event_type: EventType, data: MapEventData) {
        self.post(TelemetryEvent::from_raw(event_type, &data));
    }

    pub fn dispatch(&self, event: MapEvent) {
        if !self.is_running.load(Ordering::Relaxed) {
            return;
        }
        let event_type = EventType::from_i32(event.event_type);
        let typed = TelemetryEvent::from_raw(event_type, &event.data);
        let event_ptr = self.arena.write_slot(event);

        let mut last_pos = -1;
        self.callbacks.notify_typed_batch(std::slice::from_ref(&typed), &mut last_pos);
        self.callbacks.notify_immediate(event_type, &event.data, event_ptr);
    }

    pub fn stop(&self) {
        self.is_running.store(false, Ordering::SeqCst);
        self.callbacks.set_c(None, std::ptr::null_mut());
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
