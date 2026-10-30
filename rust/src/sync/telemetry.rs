//! Native reactive event dispatcher and telemetry pipeline for Dart FFI delivery.

use std::cell::UnsafeCell;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};
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
#[derive(Clone, Copy)]
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

static START_TIME: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

pub fn monotonic_now_ns() -> i64 {
    let start = START_TIME.get_or_init(Instant::now);
    start.elapsed().as_nanos() as i64
}

pub const MAP_EVENT_RING_CAPACITY: usize = 128;

pub struct TelemetryDispatcher {
    is_running: Arc<AtomicBool>,
    callback: Arc<RwLock<Option<(EventCallback, usize)>>>,
    ring: Arc<Vec<UnsafeCell<MapEvent>>>,
    ring_head: Arc<AtomicUsize>,
}

unsafe impl Send for TelemetryDispatcher {}
unsafe impl Sync for TelemetryDispatcher {}

impl TelemetryDispatcher {
    pub fn new(callback: Option<EventCallback>, user_data: *mut c_void) -> Self {
        let is_running = Arc::new(AtomicBool::new(true));
        let callback_slot = Arc::new(RwLock::new(
            callback.map(|cb| (cb, user_data as usize)),
        ));

        let mut ring_vec = Vec::with_capacity(MAP_EVENT_RING_CAPACITY);
        for _ in 0..MAP_EVENT_RING_CAPACITY {
            ring_vec.push(UnsafeCell::new(MapEvent {
                event_type: 0,
                padding: 0,
                timestamp_ns: 0,
                data: MapEventData { state: 0 },
            }));
        }

        Self {
            is_running,
            callback: callback_slot,
            ring: Arc::new(ring_vec),
            ring_head: Arc::new(AtomicUsize::new(0)),
        }
    }

    pub fn set_callback(&self, callback: Option<EventCallback>, user_data: *mut c_void) {
        if let Ok(mut lock) = self.callback.write() {
            *lock = callback.map(|cb| (cb, user_data as usize));
        }
    }

    pub fn post_event(&self, event_type: EventType, data: MapEventData) {
        if !self.is_running.load(Ordering::Relaxed) {
            return;
        }

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

        if let Ok(guard) = self.callback.read() {
            if let Some((cb, user_data_addr)) = *guard {
                unsafe {
                    cb(user_data_addr as *mut c_void, event_ptr);
                }
            }
        }
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
    }
}

impl Drop for TelemetryDispatcher {
    fn drop(&mut self) {
        self.stop();
    }
}
