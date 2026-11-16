//! Native reactive event dispatcher and telemetry pipeline for Dart FFI delivery.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use crate::sync::thread;

use crate::dsp::crossfeed::CrossfeedConfig;
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::SilenceConfig;
use crate::dsp::visualizer::VisualizerData;

/// Discrete event type discriminant for telemetry messages delivered across the C/Dart boundary.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventType {
    /// No event.
    None = 0,
    /// Playback state change.
    State = 1,
    /// Playback position update.
    Position = 2,
    /// Track duration notification.
    Duration = 3,
    /// Is-playing boolean change.
    IsPlaying = 4,
    /// Is-buffering boolean change.
    IsBuffering = 5,
    /// Output volume change.
    Volume = 7,
    /// Playback speed/rate change.
    Rate = 8,
    /// Playback pitch shift change.
    Pitch = 9,
    /// Decoded or container bitrate.
    Bitrate = 10,
    /// Audio buffer capacity/occupancy size.
    BufferSize = 11,
    /// Audio output device change.
    Device = 12,
    /// Visualizer frequency band measurement.
    Visualizer = 13,
    /// Visualizer enabled/disabled state.
    VisualizerEnabled = 14,
    /// Network buffered range update.
    BufferedRange = 15,
    /// Silence detection configuration.
    SilenceConfig = 16,
    /// Accumulated silence skipped time.
    SilenceSaved = 17,
    /// Equalizer 10-band gain settings.
    Equalizer = 18,
    /// Preamp amplification level.
    Preamp = 19,
    /// ReplayGain normalization settings.
    ReplayGain = 20,
    /// Stereo balance pan position.
    Balance = 21,
    /// Mono downmix toggle.
    Mono = 22,
    /// Headphone crossfeed filter mode.
    Crossfeed = 23,
    /// Spatializer stereo widening parameters.
    Spatializer = 24,
    /// Algorithmic reverb configuration.
    Reverb = 25,
    /// Lookahead safety limiter toggle.
    Limiter = 26,
    /// Engine error notification.
    Error = 27,
}

impl EventType {
    /// Constructs an `EventType` from an integer code.
    #[inline]
    pub fn from_i32(code: i32) -> Self {
        match code {
            1 => Self::State,
            2 => Self::Position,
            3 => Self::Duration,
            4 => Self::IsPlaying,
            5 => Self::IsBuffering,
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

/// Start and end boundaries of a buffered audio range in milliseconds.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct BufferedRange {
    /// Start position in milliseconds.
    pub start_ms: i64,
    /// End position in milliseconds.
    pub end_ms: i64,
    /// 1 if actively downloading/buffering, 0 otherwise.
    pub is_buffering: i32,
}

/// Audio device metadata reported across FFI.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeviceInfo {
    /// Target device ID string buffer.
    pub id: [u8; 516],
    /// Effective active device ID string buffer.
    pub effective_id: [u8; 516],
    /// Human-readable device display name.
    pub name: [u8; 256],
    /// 1 if this is the system default audio device.
    pub is_default: i32,
    /// 1 if automatic device routing is active.
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

/// Stereo spatializer widening configuration.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct SpatializerData {
    /// 1 if spatializer is enabled, 0 otherwise.
    pub enabled: i32,
    /// Stereo widening factor (1.0 = normal stereo, > 1.0 = widened).
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
    Crossfeed(CrossfeedConfig),
    Spatializer(SpatializerData),
    Reverb(ReverbConfig),
    Limiter(bool),
    Error(i32),
}

impl TelemetryEvent {
    pub fn from_raw(event_type: EventType, data: &MapEventData) -> Self {
        unsafe {
            match event_type {
                EventType::None => Self::None,
                EventType::State => Self::State(data.state),
                EventType::Position => Self::Position(data.position_ms),
                EventType::Duration => Self::Duration(data.duration_ms),
                EventType::IsPlaying => Self::IsPlaying(data.is_playing != 0),
                EventType::IsBuffering => Self::IsBuffering(data.is_buffering != 0),
                EventType::Volume => Self::Volume(data.volume),
                EventType::Rate => Self::Rate(data.rate),
                EventType::Pitch => Self::Pitch(data.pitch),
                EventType::Bitrate => Self::Bitrate(data.bitrate),
                EventType::BufferSize => Self::BufferSize(data.buffer_size),
                EventType::Device => Self::Device(Box::new(data.device)),
                EventType::Visualizer => Self::Visualizer(data.visualizer),
                EventType::VisualizerEnabled => {
                    Self::VisualizerEnabled(data.visualizer_enabled != 0)
                }
                EventType::BufferedRange => Self::BufferedRange(data.buffered_range),
                EventType::SilenceConfig => Self::SilenceConfig(data.silence_config),
                EventType::SilenceSaved => Self::SilenceSaved(data.silence_saved_ms),
                EventType::Equalizer => Self::Equalizer(data.equalizer),
                EventType::Preamp => Self::Preamp(data.preamp_db),
                EventType::ReplayGain => Self::ReplayGain(data.replay_gain),
                EventType::Balance => Self::Balance(data.balance),
                EventType::Mono => Self::Mono(data.mono_enabled != 0),
                EventType::Crossfeed => Self::Crossfeed(data.crossfeed),
                EventType::Spatializer => Self::Spatializer(data.spatializer),
                EventType::Reverb => Self::Reverb(data.reverb),
                EventType::Limiter => Self::Limiter(data.limiter_enabled != 0),
                EventType::Error => Self::Error(data.error_code),
            }
        }
    }
}

/// C-compatible union carrying the payload for a telemetry event.
#[repr(C)]
#[derive(Copy, Clone)]
pub union MapEventData {
    /// Playback state enum value.
    pub state: i32,
    /// Playback position in milliseconds.
    pub position_ms: i64,
    /// Track duration in milliseconds.
    pub duration_ms: i64,
    /// 1 if playing, 0 otherwise.
    pub is_playing: i32,
    /// 1 if buffering, 0 otherwise.
    pub is_buffering: i32,
    /// Volume multiplier.
    pub volume: f32,
    /// Playback speed rate.
    pub rate: f32,
    /// Pitch shift multiplier.
    pub pitch: f32,
    /// Bitrate in kbps.
    pub bitrate: u32,
    /// Buffer size in samples.
    pub buffer_size: u32,
    /// Device metadata struct.
    pub device: DeviceInfo,
    /// Visualizer band data.
    pub visualizer: VisualizerData,
    /// 1 if visualizer is enabled, 0 otherwise.
    pub visualizer_enabled: i32,
    /// Buffered range parameters.
    pub buffered_range: BufferedRange,
    /// Silence detection configuration.
    pub silence_config: SilenceConfig,
    /// Accumulated silence saved in milliseconds.
    pub silence_saved_ms: i64,
    /// Equalizer 10-band parameters.
    pub equalizer: EqualizerParams,
    /// Preamp gain in dB.
    pub preamp_db: f32,
    /// ReplayGain configuration.
    pub replay_gain: ReplayGainConfig,
    /// Balance stereo panning `[-1.0, 1.0]`.
    pub balance: f32,
    /// 1 if mono downmixing is enabled, 0 otherwise.
    pub mono_enabled: i32,
    /// Crossfeed filter configuration.
    pub crossfeed: CrossfeedConfig,
    /// Spatializer configuration.
    pub spatializer: SpatializerData,
    /// Reverb configuration.
    pub reverb: ReverbConfig,
    /// 1 if limiter is enabled, 0 otherwise.
    pub limiter_enabled: i32,
    /// Error code integer.
    pub error_code: i32,
}

/// Strongly-typed event callback closure type.
pub type TypedEventCallback = Box<dyn Fn(&TelemetryEvent) + Send + Sync>;

/// Cross-platform monotonic instant (`std::time::Instant` on native, `web_time::Instant` on `wasm32`).
#[cfg(not(target_arch = "wasm32"))]
pub type MonotonicInstant = std::time::Instant;
/// Cross-platform monotonic instant (`std::time::Instant` on native, `web_time::Instant` on `wasm32`).
#[cfg(target_arch = "wasm32")]
pub type MonotonicInstant = web_time::Instant;

/// Encapsulates registered telemetry callbacks with single-responsibility notification methods.
#[derive(Default)]
struct CallbackRegistry {
    typed_callback: RwLock<Option<TypedEventCallback>>,
}

impl CallbackRegistry {
    fn set_typed(&self, cb: Option<TypedEventCallback>) {
        if let Ok(mut guard) = self.typed_callback.write() {
            *guard = cb;
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

/// Central telemetry dispatcher broadcasting real-time engine events to listeners.
pub struct TelemetryDispatcher {
    is_running: Arc<AtomicBool>,
    callbacks: Arc<CallbackRegistry>,
    queue: Arc<crate::sync::WakeQueue<TelemetryEvent>>,
    worker_handle: Mutex<Option<thread::JoinHandle<()>>>,
}

impl Default for TelemetryDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

impl TelemetryDispatcher {
    /// Creates a new `TelemetryDispatcher` initializing worker threads.
    pub fn new() -> Self {
        let is_running = Arc::new(AtomicBool::new(true));
        let callbacks = Arc::new(CallbackRegistry::default());
        let queue = Arc::new(crate::sync::WakeQueue::new());

        let worker_handle =
            Self::spawn_worker(is_running.clone(), callbacks.clone(), queue.clone());

        Self {
            is_running,
            callbacks,
            queue,
            worker_handle: Mutex::new(worker_handle),
        }
    }

    fn spawn_worker(
        is_running: Arc<AtomicBool>,
        callbacks: Arc<CallbackRegistry>,
        queue: Arc<crate::sync::WakeQueue<TelemetryEvent>>,
    ) -> Option<thread::JoinHandle<()>> {
        thread::Builder::new()
            .name("map-telemetry".to_string())
            .spawn(move || {
                let mut last_position: i64 = -1;
                let mut batch: Vec<TelemetryEvent> = Vec::with_capacity(16);
                while is_running.load(Ordering::Relaxed) {
                    batch.clear();
                    let keep_going = queue.wait_drain_timeout(Duration::from_millis(25), &mut batch);
                    if !batch.is_empty() {
                        callbacks.notify_typed_batch(&batch, &mut last_position);
                    }
                    if !keep_going {
                        break;
                    }
                }
            })
            .ok()
    }

    /// Sets or clears the strongly-typed batch event callback closure.
    pub fn set_typed_callback(&self, callback: Option<TypedEventCallback>) {
        self.callbacks.set_typed(callback);
    }

    /// Primary deterministic telemetry dispatch entry point.
    pub fn post(&self, event: TelemetryEvent) {
        if !self.is_running.load(Ordering::Relaxed) {
            return;
        }
        let _ = self.queue.send(event);
    }

    /// Posts an untyped event by converting `(event_type, data)` into a [`TelemetryEvent`].
    #[inline]
    pub fn post_event(&self, event_type: EventType, data: MapEventData) {
        self.post(TelemetryEvent::from_raw(event_type, &data));
    }

    /// Signals the dispatcher to stop all threads and release callbacks.
    pub fn stop(&self) {
        self.is_running.store(false, Ordering::SeqCst);
        self.queue.close();
        self.callbacks.set_typed(None);
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
