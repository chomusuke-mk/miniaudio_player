//! Central thread-safe player coordinator integrating decoding, DSP, buffering, and device output.

use std::ffi::{c_char, c_void};
use std::fs::File;
use std::io::Cursor;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::bridge::ffi::*;
use crate::buffer::{CustomByteSourceHandle, CustomDartByteSource, TripartiteBuffer};
use crate::core::renderer::{AudioRenderer, DspCommand};
use crate::decoder::{BoundaryInfo, ContainerFormat, FormatSniffer, SymphoniaEngine};
use crate::dsp::channel_matrix::ChannelMatrix;
use crate::dsp::crossfeed::CrossfeedMode;
use crate::dsp::equalizer::{EqualizerParams, ReplayGainConfig};
use crate::dsp::resampler::RubatoResampler;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::{SilenceConfig, SilenceDetector};
use crate::dsp::sonic::SonicStream;
use crate::dsp::visualizer::VisualizerData;
use crate::dsp::DspChain;
use crate::sync::ring_buffer::{AudioProducer, AudioRingBuffer};
use crate::sync::seqlock::CachePaddedSeqlock;
use crate::sync::telemetry::{
    DeviceInfo as TelemetryDeviceInfo, EventCallback, EventType, MapEventData,
    SpatializerData, TelemetryDispatcher,
};

pub const STATE_STOPPED: i32 = 0;
pub const STATE_PLAYING: i32 = 1;
pub const STATE_PAUSED: i32 = 2;
pub const STATE_COMPLETED: i32 = 3;
pub const STATE_BUFFERING: i32 = 4;
pub const STATE_ERROR: i32 = 5;
pub const STATE_OPENING: i32 = 6;

pub const MAP_STREAM_SEEK_CACHE_MISS: i32 = 0;
pub const MAP_STREAM_SEEK_CACHE_HIT: i32 = 1;
pub const MAP_STREAM_SEEK_CACHE_HIT_PREFETCH: i32 = 2;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct MiniaudioStreamStatus {
    pub buffer_capacity: usize,
    pub buffer_fill: usize,
    pub fill_percentage: f32,
    pub is_buffering: i32,
    pub is_eof: i32,
    pub read_cursor_byte: i64,
    pub range_start: i64,
    pub range_end: i64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MiniaudioPlayerStatus {
    pub position_ms: i64,
    pub duration_ms: i64,
    pub state: i32,
    pub is_playing: i32,
    pub is_buffering: i32,
    pub is_completed: i32,
    pub volume: f32,
    pub rate: f32,
    pub pitch: f32,
    pub bitrate: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub equalizer: EqualizerParams,
    pub device: MapDeviceInfo,
    pub silence: SilenceConfig,
    pub silence_saved_ms: i64,
    pub visualizer_enabled: i32,
    pub visualizer: VisualizerData,
    pub preamp_db: f32,
    pub replay_gain: ReplayGainConfig,
    pub balance: f32,
    pub mono_enabled: i32,
    pub crossfeed_mode: i32,
    pub spatializer_enabled: i32,
    pub spatializer_width: f32,
    pub reverb: ReverbConfig,
    pub limiter_enabled: i32,
}

pub type CompletionCallback = unsafe extern "C" fn(user_data: *mut c_void);

pub struct PlayerCoordinator {
    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut AudioRenderer,

    pub state: Arc<AtomicI32>,
    pub pause_on_device_change: Arc<AtomicBool>,
    pub position_ms: Arc<AtomicI64>,
    pub position_frames: Arc<AtomicI64>,
    pub duration_ms: Arc<AtomicI64>,
    pub volume: Arc<AtomicU32>,
    pub rate: Arc<AtomicU32>,
    pub pitch: Arc<AtomicU32>,
    pub bitrate: Arc<AtomicU32>,
    pub sample_rate: Arc<AtomicU32>,
    pub channels: Arc<AtomicU32>,
    pub device_sample_rate: Arc<AtomicU32>,
    pub device_channels: Arc<AtomicU32>,
    pub period_size_in_frames: Arc<AtomicU32>,
    pub silence_saved_ms: Arc<AtomicI64>,
    pub visualizer_enabled: Arc<AtomicBool>,

    pub is_stream: Arc<AtomicBool>,
    pub trip_buffer: Arc<RwLock<Option<TripartiteBuffer>>>,
    pub boundary_info: Arc<RwLock<Option<BoundaryInfo>>>,
    pub custom_source_handle: Arc<RwLock<Option<CustomByteSourceHandle>>>,

    pub telemetry: Arc<TelemetryDispatcher>,
    pub completion_cb: Arc<RwLock<Option<(CompletionCallback, usize)>>>,

    pub silence_config: Arc<RwLock<SilenceConfig>>,

    pub audio_producer: Arc<Mutex<Option<AudioProducer>>>,
    pub cmd_producer: Arc<Mutex<Option<rtrb::Producer<DspCommand>>>>,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,

    pub flush_generation: Arc<AtomicU64>,
    pub flush_acknowledged: Arc<AtomicU64>,
    pub completed_flag: Arc<AtomicBool>,
    pub buffering_flag: Arc<AtomicBool>,
    pub buffering_resumed_flag: Arc<AtomicBool>,

    // Cached DSP settings
    pub eq_params: Arc<RwLock<EqualizerParams>>,
    pub preamp_db: Arc<AtomicU32>,
    pub replay_gain: Arc<RwLock<ReplayGainConfig>>,
    pub balance: Arc<AtomicU32>,
    pub mono_enabled: Arc<AtomicBool>,
    pub spatializer_enabled: Arc<AtomicBool>,
    pub spatializer_width: Arc<AtomicU32>,
    pub crossfeed_mode: Arc<AtomicI32>,
    pub reverb_config: Arc<RwLock<ReverbConfig>>,
    pub limiter_enabled: Arc<AtomicBool>,

    pub engine: Arc<Mutex<Option<SymphoniaEngine>>>,
    pub seek_request_ms: Arc<AtomicI64>,
    pub decoder_eof: Arc<AtomicBool>,
    pub stream_reinit_needed: Arc<AtomicBool>,

    pub decoder_running: Arc<AtomicBool>,
    pub decoder_wake: Arc<(Mutex<bool>, Condvar)>,
    pub decoder_thread: Option<JoinHandle<()>>,
}

// PlayerCoordinator is Send + Sync across threads
unsafe impl Send for PlayerCoordinator {}
unsafe impl Sync for PlayerCoordinator {}

impl PlayerCoordinator {
    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn new(
        target_sample_rate: u32,
        target_channels: u32,
        period_size: u32,
        playback_device_id: *const c_char,
        on_completed: Option<CompletionCallback>,
        user_data: *mut c_void,
    ) -> Result<Box<Self>, i32> {
        let sr = if target_sample_rate > 0 { target_sample_rate } else { 44100 };
        let ch = if target_channels > 0 { target_channels } else { 2 };
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
        let channels = Arc::new(AtomicU32::new(ch));
        let device_sample_rate = Arc::new(AtomicU32::new(sr));
        let device_channels = Arc::new(AtomicU32::new(ch));
        let period_size_in_frames = Arc::new(AtomicU32::new(period));
        let silence_saved_ms = Arc::new(AtomicI64::new(0));
        let visualizer_enabled = Arc::new(AtomicBool::new(false));

        let is_stream = Arc::new(AtomicBool::new(false));
        let trip_buffer = Arc::new(RwLock::new(None));
        let boundary_info = Arc::new(RwLock::new(None));
        let custom_source_handle = Arc::new(RwLock::new(None));

        let telemetry = Arc::new(TelemetryDispatcher::new(None, std::ptr::null_mut()));
        let completion_cb = Arc::new(RwLock::new(
            on_completed.map(|cb| (cb, user_data as usize)),
        ));

        let silence_config = Arc::new(RwLock::new(SilenceConfig::default()));

        let ring_cap = (sr as usize * ch as usize * 3).max(262144);
        let (producer, consumer) = AudioRingBuffer::create(ring_cap);
        let audio_producer = Arc::new(Mutex::new(Some(producer)));

        let (cmd_prod, cmd_cons) = rtrb::RingBuffer::new(256);
        let cmd_producer = Arc::new(Mutex::new(Some(cmd_prod)));

        let visualizer_seqlock = Arc::new(CachePaddedSeqlock::new(VisualizerData::default()));
        let flush_generation = Arc::new(AtomicU64::new(0));
        let flush_acknowledged = Arc::new(AtomicU64::new(0));
        let completed_flag = Arc::new(AtomicBool::new(false));
        let buffering_flag = Arc::new(AtomicBool::new(false));
        let buffering_resumed_flag = Arc::new(AtomicBool::new(false));

        let eq_params = Arc::new(RwLock::new(EqualizerParams::default()));
        let preamp_db = Arc::new(AtomicU32::new(0.0f32.to_bits()));
        let replay_gain = Arc::new(RwLock::new(ReplayGainConfig::default()));
        let balance = Arc::new(AtomicU32::new(0.0f32.to_bits()));
        let mono_enabled = Arc::new(AtomicBool::new(false));
        let spatializer_enabled = Arc::new(AtomicBool::new(false));
        let spatializer_width = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let crossfeed_mode = Arc::new(AtomicI32::new(0));
        let reverb_config = Arc::new(RwLock::new(ReverbConfig::default()));
        let limiter_enabled = Arc::new(AtomicBool::new(true));

        let engine = Arc::new(Mutex::new(None));
        let seek_request_ms = Arc::new(AtomicI64::new(-1));
        let decoder_eof = Arc::new(AtomicBool::new(false));
        let stream_reinit_needed = Arc::new(AtomicBool::new(false));

        let decoder_running = Arc::new(AtomicBool::new(true));
        let decoder_wake = Arc::new((Mutex::new(false), Condvar::new()));

        let pause_on_device = pause_on_device_change.clone();
        let state_for_notif = state.clone();
        let tele_for_notif = telemetry.clone();
        let notif_cb: Arc<dyn Fn(i32) + Send + Sync> = Arc::new(move |_notification_type: i32| {
            if pause_on_device.load(Ordering::Relaxed) {
                if state_for_notif.load(Ordering::Relaxed) == STATE_PLAYING {
                    state_for_notif.store(STATE_PAUSED, Ordering::Relaxed);
                    tele_for_notif.post_event(
                        EventType::IsPlaying,
                        MapEventData { is_playing: 0 },
                    );
                    tele_for_notif.post_event(
                        EventType::State,
                        MapEventData { state: STATE_PAUSED },
                    );
                }
            }
        });

        let renderer = AudioRenderer {
            consumer,
            cmd_consumer: cmd_cons,
            state: state.clone(),
            sample_rate: sample_rate.clone(),
            channels: channels.clone(),
            device_sample_rate: device_sample_rate.clone(),
            device_channels: device_channels.clone(),
            volume: volume.clone(),
            rate: rate.clone(),
            position_frames: position_frames.clone(),
            position_ms: position_ms.clone(),
            duration_ms: duration_ms.clone(),
            decoder_eof: decoder_eof.clone(),
            seek_request_ms: seek_request_ms.clone(),
            is_stream: is_stream.clone(),
            flush_generation: flush_generation.clone(),
            flush_acknowledged: flush_acknowledged.clone(),
            local_flush_gen: 0,
            completed_flag: completed_flag.clone(),
            buffering_flag: buffering_flag.clone(),
            buffering_resumed_flag: buffering_resumed_flag.clone(),
            dsp: DspChain::new(ch as usize, sr),
            visualizer_seqlock: visualizer_seqlock.clone(),
            visualizer_enabled: visualizer_enabled.clone(),
            notification_callback: Some(notif_cb),
        };
        let renderer_ptr = Box::into_raw(Box::new(renderer));

        let mut dev_res = 0;
        let device_ctx = unsafe {
            map_device_create(
                sr,
                ch,
                period,
                playback_device_id,
                renderer_ptr as *mut c_void,
                &mut dev_res,
            )
        };

        if device_ctx.is_null() || dev_res != 0 {
            unsafe { drop(Box::from_raw(renderer_ptr)); }
            return Err(dev_res);
        }

        let actual_sr = unsafe { map_device_get_sample_rate(device_ctx) };
        let actual_ch = unsafe { map_device_get_channels(device_ctx) };
        if actual_sr > 0 {
            device_sample_rate.store(actual_sr, Ordering::SeqCst);
        }
        if actual_ch > 0 {
            device_channels.store(actual_ch, Ordering::SeqCst);
        }

        let mut coordinator = Box::new(Self {
            device_ctx,
            renderer_ptr,
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
            channels,
            device_sample_rate,
            device_channels,
            period_size_in_frames,
            silence_saved_ms,
            visualizer_enabled,
            is_stream,
            trip_buffer,
            boundary_info,
            custom_source_handle,
            telemetry,
            completion_cb,
            silence_config,
            audio_producer,
            cmd_producer,
            visualizer_seqlock,
            flush_generation,
            flush_acknowledged,
            completed_flag,
            buffering_flag,
            buffering_resumed_flag,
            eq_params,
            preamp_db,
            replay_gain,
            balance,
            mono_enabled,
            spatializer_enabled,
            spatializer_width,
            crossfeed_mode,
            reverb_config,
            limiter_enabled,
            engine,
            seek_request_ms,
            decoder_eof,
            stream_reinit_needed,
            decoder_running,
            decoder_wake,
            decoder_thread: None,
        });

        // Spawn background decoder loop
        coordinator.start_decoder_loop();

        Ok(coordinator)
    }

    pub fn send_dsp_command(&self, cmd: DspCommand) {
        if let Ok(mut guard) = self.cmd_producer.lock() {
            if let Some(ref mut prod) = *guard {
                let _ = prod.push(cmd);
            }
        }
    }

    fn start_decoder_loop(&mut self) {
        let running = self.decoder_running.clone();
        let wake = self.decoder_wake.clone();
        let state = self.state.clone();
        let engine_arc = self.engine.clone();
        let producer_arc = self.audio_producer.clone();
        let seek_req = self.seek_request_ms.clone();
        let pos_ms = self.position_ms.clone();
        let pos_frames = self.position_frames.clone();
        let dur_ms = self.duration_ms.clone();
        let rate_arc = self.rate.clone();
        let pitch_arc = self.pitch.clone();
        let sr_arc = self.sample_rate.clone();
        let ch_arc = self.channels.clone();
        let silence_cfg_arc = self.silence_config.clone();
        let silence_saved_arc = self.silence_saved_ms.clone();
        let is_stream_arc = self.is_stream.clone();
        let trip_buf_arc = self.trip_buffer.clone();
        let decoder_eof_arc = self.decoder_eof.clone();
        let tele = self.telemetry.clone();
        let completed_flag = self.completed_flag.clone();
        let buffering_flag = self.buffering_flag.clone();
        let buffering_resumed_flag = self.buffering_resumed_flag.clone();
        let visualizer_seqlock = self.visualizer_seqlock.clone();
        let visualizer_enabled = self.visualizer_enabled.clone();
        let completion_cb = self.completion_cb.clone();
        let flush_generation = self.flush_generation.clone();
        let flush_acknowledged = self.flush_acknowledged.clone();
        let stream_reinit_needed = self.stream_reinit_needed.clone();

        let dev_sr_arc = self.device_sample_rate.clone();
        let dev_ch_arc = self.device_channels.clone();
        let handle = thread::Builder::new()
            .name("map-decoder".to_string())
            .spawn(move || {
                let mut frame_buf = Vec::new();
                let mut active_buf = Vec::new();
                let mut matrix_buf = Vec::new();
                let mut resampler_out = Vec::new();
                let mut pending_pcm: Vec<f32> = Vec::new();
                let mut pending_offset: usize = 0;
                let mut sonic_out_buf = vec![0.0f32; 16384];

                let cur_sr = sr_arc.load(Ordering::Relaxed).max(8000);
                let cur_ch = (ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
                let cur_dev_sr = dev_sr_arc.load(Ordering::Relaxed).max(8000);
                let cur_dev_ch = (dev_ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);

                let mut sonic = SonicStream::new(cur_sr, cur_ch);
                let mut silence_detector = SilenceDetector::new(cur_ch, cur_sr);
                let mut channel_matrix = ChannelMatrix::new(cur_ch, cur_dev_ch);
                let mut resampler = RubatoResampler::new(cur_sr, cur_dev_sr, cur_dev_ch, 1024)
                    .unwrap_or_else(|_| RubatoResampler::new(48000, 48000, cur_dev_ch, 1024).unwrap());

                let mut last_tele_pos: i64 = -1;
                let mut last_vis_instant = std::time::Instant::now();

                while running.load(Ordering::Relaxed) {
                    // 1. Check completed flag from AudioRenderer
                    if completed_flag.swap(false, Ordering::AcqRel) {
                        let dur = dur_ms.load(Ordering::Relaxed);
                        tele.post_event(EventType::Position, MapEventData { position_ms: dur });
                        tele.post_event(EventType::IsPlaying, MapEventData { is_playing: 0 });
                        tele.post_event(EventType::IsCompleted, MapEventData { is_completed: 1 });
                        tele.post_event(EventType::State, MapEventData { state: STATE_COMPLETED });
                        if let Ok(guard) = completion_cb.read() {
                            if let Some((cb, udata)) = *guard {
                                unsafe { cb(udata as *mut c_void); }
                            }
                        }
                    }

                    // 2. Check buffering flags from AudioRenderer
                    if buffering_flag.swap(false, Ordering::AcqRel) {
                        tele.post_event(EventType::IsBuffering, MapEventData { is_buffering: 1 });
                        tele.post_event(EventType::State, MapEventData { state: STATE_BUFFERING });
                    }
                    if buffering_resumed_flag.swap(false, Ordering::AcqRel) {
                        tele.post_event(EventType::IsBuffering, MapEventData { is_buffering: 0 });
                        tele.post_event(EventType::State, MapEventData { state: STATE_PLAYING });
                    }

                    let cur_sr = sr_arc.load(Ordering::Relaxed);
                    let cur_ch = ch_arc.load(Ordering::Relaxed) as usize;
                    if cur_sr > 0 && cur_ch > 0 && (cur_sr != silence_detector.sample_rate() || cur_ch != silence_detector.channels()) {
                        silence_detector.set_sample_rate(cur_sr);
                        silence_detector.set_channels(cur_ch);
                        sonic = SonicStream::new(cur_sr, cur_ch);
                    }

                    // Check for seek request
                    let target_seek = seek_req.swap(-1, Ordering::SeqCst);
                    if target_seek >= 0 {
                        let dur = dur_ms.load(Ordering::Relaxed);
                        if dur > 0 && target_seek >= dur {
                            decoder_eof_arc.store(true, Ordering::Relaxed);
                            state.store(STATE_COMPLETED, Ordering::Relaxed);
                            pos_ms.store(dur, Ordering::Relaxed);
                            let f = if cur_sr > 0 { (dur * cur_sr as i64 * 1024) / 1000 } else { 0 };
                            pos_frames.store(f, Ordering::Relaxed);
                            tele.post_event(
                                EventType::Position,
                                MapEventData { position_ms: dur },
                            );
                            tele.post_event(
                                EventType::IsPlaying,
                                MapEventData { is_playing: 0 },
                            );
                            tele.post_event(
                                EventType::IsCompleted,
                                MapEventData { is_completed: 1 },
                            );
                            tele.post_event(
                                EventType::State,
                                MapEventData { state: STATE_COMPLETED },
                            );
                            continue;
                        }

                        // Wait for flush to be acknowledged by renderer (up to 50ms)
                        let cur_flush = flush_generation.load(Ordering::Acquire);
                        let start_wait = std::time::Instant::now();
                        while flush_acknowledged.load(Ordering::Acquire) < cur_flush && start_wait.elapsed() < Duration::from_millis(50) {
                            std::thread::yield_now();
                        }

                        decoder_eof_arc.store(false, Ordering::Relaxed);
                        if let Ok(mut eng_lock) = engine_arc.lock() {
                            let mut reinit = false;
                            if target_seek == 0 && is_stream_arc.load(Ordering::Relaxed) {
                                if let Ok(guard) = trip_buf_arc.read() {
                                    if let Some(ref trip) = *guard {
                                        let reader = trip.create_reader();
                                        if let Ok(new_eng) = SymphoniaEngine::new(reader, None) {
                                            *eng_lock = Some(new_eng);
                                            reinit = true;
                                        }
                                    }
                                }
                            }
                            if !reinit {
                                if let Some(ref mut eng) = *eng_lock {
                                    let _ = eng.seek_ms(target_seek as u64);
                                }
                            }
                        }
                        sonic.flush();
                        silence_detector.reset(target_seek == 0);
                        silence_saved_arc.store(0, Ordering::Relaxed);
                        pending_pcm.clear();
                        pending_offset = 0;
                        resampler.reset();
                        tele.post_event(
                            EventType::SilenceSaved,
                            MapEventData {
                                silence_saved_ms: 0,
                            },
                        );
                        pos_ms.store(target_seek, Ordering::Relaxed);
                        let f = if cur_sr > 0 { (target_seek * cur_sr as i64 * 1024) / 1000 } else { 0 };
                        pos_frames.store(f, Ordering::Relaxed);
                        tele.post_event(
                            EventType::Position,
                            MapEventData {
                                position_ms: target_seek,
                            },
                        );
                    }

                    let cur_state = state.load(Ordering::Relaxed);
                    if cur_state != STATE_PLAYING && cur_state != STATE_BUFFERING {
                        let (lock, cvar) = &*wake;
                        let guard = lock.lock().unwrap();
                        let _ = cvar.wait_timeout(guard, Duration::from_millis(30));
                        continue;
                    }

                    // Reinitialize engine if live stream was flushed/reopened
                    if stream_reinit_needed.load(Ordering::Acquire) {
                        let can_init = {
                            if let Ok(guard) = trip_buf_arc.read() {
                                if let Some(ref trip) = *guard {
                                    trip.head_size() > 0 || trip.range_end() > trip.range_start() || trip.is_eof()
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        };
                        if can_init {
                            let maybe_reader = {
                                if let Ok(guard) = trip_buf_arc.read() {
                                    guard.as_ref().map(|t| t.create_reader())
                                } else {
                                    None
                                }
                            };
                            if let Some(reader) = maybe_reader {
                                if let Ok(new_eng) = SymphoniaEngine::new(reader, None) {
                                    let new_sr = new_eng.sample_rate();
                                    let new_ch = new_eng.channels();
                                    if new_sr > 0 {
                                        sr_arc.store(new_sr, Ordering::Relaxed);
                                    }
                                    if new_ch > 0 {
                                        ch_arc.store(new_ch as u32, Ordering::Relaxed);
                                    }
                                    if let Ok(mut eng_lock) = engine_arc.lock() {
                                        *eng_lock = Some(new_eng);
                                    }
                                    stream_reinit_needed.store(false, Ordering::Release);
                                    decoder_eof_arc.store(false, Ordering::Relaxed);
                                    pending_pcm.clear();
                                    pending_offset = 0;
                                    resampler.reset();
                                }
                            }
                        } else {
                            let (lock, cvar) = &*wake;
                            let guard = lock.lock().unwrap();
                            let _ = cvar.wait_timeout(guard, Duration::from_millis(10));
                            continue;
                        }
                    }

                    // 3. Periodic Position Telemetry dispatch (active playback only)
                    let cur_pos = pos_ms.load(Ordering::Relaxed);
                    if cur_pos != last_tele_pos && (cur_pos / 33 != last_tele_pos / 33 || cur_pos == 0) {
                        last_tele_pos = cur_pos;
                        tele.post_event(EventType::Position, MapEventData { position_ms: cur_pos });
                    }

                    // 4. Periodic Visualizer Telemetry dispatch (~30fps, active playback only)
                    if visualizer_enabled.load(Ordering::Relaxed) && last_vis_instant.elapsed() >= Duration::from_millis(33) {
                        last_vis_instant = std::time::Instant::now();
                        let vis = visualizer_seqlock.read();
                        tele.post_event(EventType::Visualizer, MapEventData { visualizer: vis });
                    }

                    if state.load(Ordering::Relaxed) == STATE_BUFFERING {
                        let has_enough_audio = {
                            if let Ok(guard) = producer_arc.lock() {
                                if let Some(ref prod) = *guard {
                                    prod.slots_available() < prod.capacity()
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        };
                        if has_enough_audio {
                            state.store(STATE_PLAYING, Ordering::Relaxed);
                            tele.post_event(
                                EventType::IsBuffering,
                                MapEventData { is_buffering: 0 },
                            );
                            tele.post_event(
                                EventType::State,
                                MapEventData { state: STATE_PLAYING },
                            );
                        }
                    }

                    // 1. Drain pending PCM from previous packet first (Zero-loss backpressure guarantee)
                    if pending_offset < pending_pcm.len() {
                        let slice_to_write = &pending_pcm[pending_offset..];
                        let written = {
                            if let Ok(mut guard) = producer_arc.lock() {
                                if let Some(ref mut prod) = *guard {
                                    prod.write_chunk(slice_to_write)
                                } else {
                                    0
                                }
                            } else {
                                0
                            }
                        };
                        pending_offset += written;
                        if pending_offset < pending_pcm.len() {
                            let (lock, cvar) = &*wake;
                            let guard = lock.lock().unwrap();
                            let _ = cvar.wait_timeout(guard, Duration::from_millis(3));
                            continue;
                        } else {
                            pending_pcm.clear();
                            pending_offset = 0;
                        }
                    }

                    // 2. Check producer slots before decoding a new packet
                    let slots = {
                        if let Ok(guard) = producer_arc.lock() {
                            if let Some(ref prod) = *guard {
                                prod.slots_available()
                            } else {
                                0
                            }
                        } else {
                            0
                        }
                    };

                    if slots < 2048 {
                        let (lock, cvar) = &*wake;
                        let guard = lock.lock().unwrap();
                        let _ = cvar.wait_timeout(guard, Duration::from_millis(3));
                        continue;
                    }

                    // 3. Decode next frame
                    let mut decoded_ok = false;
                    let mut eof_reached = false;

                    if let Ok(mut eng_lock) = engine_arc.lock() {
                        if let Some(ref mut eng) = *eng_lock {
                            match eng.decode_next_frame(&mut frame_buf) {
                                Ok(true) => {
                                    decoded_ok = true;
                                    let new_sr = eng.sample_rate();
                                    let new_ch = eng.channels();
                                    if new_sr > 0 && new_sr != sr_arc.load(Ordering::Relaxed) {
                                        sr_arc.store(new_sr, Ordering::Relaxed);
                                    }
                                    if new_ch > 0 && new_ch != ch_arc.load(Ordering::Relaxed) {
                                        ch_arc.store(new_ch, Ordering::Relaxed);
                                    }
                                }
                                Ok(false) => {
                                    eof_reached = true;
                                }
                                Err(err) => {
                                    if is_stream_arc.load(Ordering::Relaxed) {
                                        let is_empty = {
                                            if let Ok(guard) = producer_arc.lock() {
                                                if let Some(ref prod) = *guard {
                                                    prod.slots_available() >= prod.capacity()
                                                } else {
                                                    true
                                                }
                                            } else {
                                                true
                                            }
                                        };
                                        if is_empty && state.load(Ordering::Relaxed) != STATE_BUFFERING {
                                            state.store(STATE_BUFFERING, Ordering::Relaxed);
                                            tele.post_event(
                                                EventType::IsBuffering,
                                                MapEventData { is_buffering: 1 },
                                            );
                                            tele.post_event(
                                                EventType::State,
                                                MapEventData { state: STATE_BUFFERING },
                                            );
                                        }
                                        thread::sleep(Duration::from_millis(10));
                                        continue;
                                    } else {
                                        log::error!("Decoder error: {}", err);
                                        eof_reached = true;
                                    }
                                }
                            }
                        }
                    }

                    if eof_reached {
                        if is_stream_arc.load(Ordering::Relaxed) {
                            let is_buf_eof = {
                                if let Ok(guard) = trip_buf_arc.read() {
                                    guard.as_ref().map(|b| b.is_eof()).unwrap_or(true)
                                } else {
                                    true
                                }
                            };

                            if !is_buf_eof {
                                state.store(STATE_BUFFERING, Ordering::Relaxed);
                                tele.post_event(
                                    EventType::IsBuffering,
                                    MapEventData { is_buffering: 1 },
                                );
                                tele.post_event(
                                    EventType::State,
                                    MapEventData { state: STATE_BUFFERING },
                                );
                                thread::sleep(Duration::from_millis(15));
                                continue;
                            }
                        }

                        // Flush any remaining resampler frames
                        if pending_pcm.is_empty() {
                            let _ = resampler.flush(&mut pending_pcm);
                            pending_offset = 0;
                        }
                        if pending_offset < pending_pcm.len() {
                            let slice = &pending_pcm[pending_offset..];
                            let written = {
                                if let Ok(mut guard) = producer_arc.lock() {
                                    if let Some(ref mut prod) = *guard {
                                        prod.write_chunk(slice)
                                    } else {
                                        0
                                    }
                                } else {
                                    0
                                }
                            };
                            pending_offset += written;
                            if pending_offset < pending_pcm.len() {
                                let (lock, cvar) = &*wake;
                                let guard = lock.lock().unwrap();
                                let _ = cvar.wait_timeout(guard, Duration::from_millis(4));
                                continue;
                            } else {
                                pending_pcm.clear();
                                pending_offset = 0;
                            }
                        }

                        if state.load(Ordering::Relaxed) == STATE_BUFFERING {
                            state.store(STATE_PLAYING, Ordering::Relaxed);
                            tele.post_event(
                                EventType::IsBuffering,
                                MapEventData { is_buffering: 0 },
                            );
                            tele.post_event(
                                EventType::State,
                                MapEventData { state: STATE_PLAYING },
                            );
                        }

                        decoder_eof_arc.store(true, Ordering::Relaxed);
                        thread::sleep(Duration::from_millis(20));
                        continue;
                    }

                    if decoded_ok && !frame_buf.is_empty() {
                        decoder_eof_arc.store(false, Ordering::Relaxed);
                        if state.load(Ordering::Relaxed) == STATE_BUFFERING {
                            state.store(STATE_PLAYING, Ordering::Relaxed);
                            tele.post_event(
                                EventType::IsBuffering,
                                MapEventData { is_buffering: 0 },
                            );
                            tele.post_event(
                                EventType::State,
                                MapEventData { state: STATE_PLAYING },
                            );
                        }

                        let cur_track_sr = sr_arc.load(Ordering::Relaxed).max(8000);
                        let cur_track_ch = (ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);
                        let cur_dev_sr = dev_sr_arc.load(Ordering::Relaxed).max(8000);
                        let cur_dev_ch = (dev_ch_arc.load(Ordering::Relaxed) as usize).clamp(1, 16);

                        if cur_track_sr > 0 && cur_track_ch > 0 && (cur_track_sr != silence_detector.sample_rate() || cur_track_ch != silence_detector.channels()) {
                            silence_detector.set_sample_rate(cur_track_sr);
                            silence_detector.set_channels(cur_track_ch);
                            sonic = SonicStream::new(cur_track_sr, cur_track_ch);
                        }

                        // Silence Detection
                        let cur_silence_cfg = *silence_cfg_arc.read().unwrap();
                        silence_detector.set_config(cur_silence_cfg);

                        if active_buf.len() < frame_buf.len() {
                            active_buf.resize(frame_buf.len(), 0.0);
                        }
                        let (frames_out, _) = silence_detector.process_frames(
                            &frame_buf,
                            &mut active_buf,
                        );
                        let new_saved = silence_detector.saved_ms() as i64;
                        let old_saved = silence_saved_arc.swap(new_saved, Ordering::Relaxed);
                        if new_saved != old_saved {
                            tele.post_event(
                                EventType::SilenceSaved,
                                MapEventData {
                                    silence_saved_ms: new_saved,
                                },
                            );
                        }

                        let samples_out = frames_out * cur_track_ch;
                        if samples_out == 0 {
                            continue;
                        }
                        let active_slice = &active_buf[..samples_out];

                        // Time-stretching / Pitch-shifting
                        let cur_rate = f32::from_bits(rate_arc.load(Ordering::Relaxed));
                        let cur_pitch = f32::from_bits(pitch_arc.load(Ordering::Relaxed));
                        let sonic_slice = if (cur_rate - 1.0).abs() > 0.001 || (cur_pitch - 1.0).abs() > 0.001 {
                            sonic.set_speed(cur_rate);
                            sonic.set_pitch(cur_pitch);
                            sonic.write_float(active_slice);

                            let frames_read = sonic.read_float(&mut sonic_out_buf);
                            let samples_read = frames_read * cur_track_ch;
                            &sonic_out_buf[..samples_read]
                        } else {
                            active_slice
                        };

                        // Channel Matrix Adaptation (e.g. Mono -> Stereo, 5.1 -> Stereo, 5.1 -> 7.1, etc.)
                        channel_matrix.set_channels(cur_track_ch, cur_dev_ch);
                        channel_matrix.process_interleaved(sonic_slice, &mut matrix_buf);

                        // High-Fidelity Resampling (e.g. 44.1k -> 48k, 192k -> 48k, or passthrough)
                        if resampler.sample_rate_in() != cur_track_sr
                            || resampler.sample_rate_out() != cur_dev_sr
                            || resampler.channels() != cur_dev_ch
                        {
                            if let Ok(new_res) = RubatoResampler::new(cur_track_sr, cur_dev_sr, cur_dev_ch, 1024) {
                                resampler = new_res;
                            }
                        }
                        resampler_out.clear();
                        let _ = resampler.process_interleaved(&matrix_buf, &mut resampler_out);

                        // Commit to pending buffer and write first chunk
                        pending_pcm.extend_from_slice(&resampler_out);
                        pending_offset = 0;

                        let written = {
                            if let Ok(mut guard) = producer_arc.lock() {
                                if let Some(ref mut prod) = *guard {
                                    prod.write_chunk(&pending_pcm[pending_offset..])
                                } else {
                                    0
                                }
                            } else {
                                0
                            }
                        };
                        pending_offset += written;
                        if pending_offset >= pending_pcm.len() {
                            pending_pcm.clear();
                            pending_offset = 0;
                        }
                    }
                }
            })
            .ok();

        self.decoder_thread = handle;
    }

    pub fn on_device_notification(&mut self, _notification_type: i32) {
        if self.pause_on_device_change.load(Ordering::Relaxed) {
            if self.state.load(Ordering::Relaxed) == STATE_PLAYING {
                let _ = self.pause();
            }
        }
        let mut dev_info = MapDeviceInfo::default();
        let _ = self.get_current_device(&mut dev_info);
        let mut tele_dev = TelemetryDeviceInfo::default();
        tele_dev.id = dev_info.id;
        tele_dev.effective_id = dev_info.effective_id;
        tele_dev.name = dev_info.name;
        tele_dev.is_default = dev_info.is_default;
        tele_dev.is_auto = dev_info.is_auto;

        self.telemetry.post_event(
            EventType::Device,
            MapEventData { device: tele_dev },
        );
    }

    pub fn set_event_callback(&self, callback: Option<EventCallback>, user_data: *mut c_void) -> i32 {
        self.telemetry.set_callback(callback, user_data);
        MAP_SUCCESS
    }

    pub fn begin_open(&mut self) -> i32 {
        let _ = self.stop();
        *self.custom_source_handle.write().unwrap() = None;
        *self.engine.lock().unwrap() = None;
        self.decoder_eof.store(false, Ordering::Relaxed);
        self.silence_saved_ms.store(0, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::SilenceSaved,
            MapEventData { silence_saved_ms: 0 },
        );
        self.state.store(STATE_OPENING, Ordering::Relaxed);
        self.position_ms.store(0, Ordering::Relaxed);
        self.position_frames.store(0, Ordering::Relaxed);
        self.duration_ms.store(0, Ordering::Relaxed);
        self.bitrate.store(0, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::State,
            MapEventData { state: STATE_OPENING },
        );
        MAP_SUCCESS
    }

    pub fn open_file(&mut self, path: &str) -> i32 {
        let _ = self.begin_open();

        let file = match File::open(path) {
            Ok(f) => f,
            Err(_) => {
                self.state.store(STATE_ERROR, Ordering::Relaxed);
                self.telemetry.post_event(
                    EventType::State,
                    MapEventData { state: STATE_ERROR },
                );
                return MAP_ERROR_FILE_NOT_FOUND;
            }
        };

        let file_size = file.metadata().map(|m| m.len()).unwrap_or(0);
        let ext = std::path::Path::new(path)
            .extension()
            .and_then(|e| e.to_str());

        let eng = match SymphoniaEngine::new(file, ext) {
            Ok(e) => e,
            Err(_) => {
                self.state.store(STATE_ERROR, Ordering::Relaxed);
                self.telemetry.post_event(
                    EventType::State,
                    MapEventData { state: STATE_ERROR },
                );
                return MAP_ERROR_DECODE_FAILED;
            }
        };

        let mut header = [0u8; 8192];
        let mut header_len = 0;
        if let Ok(mut f) = File::open(path) {
            use std::io::Read;
            if let Ok(n) = f.read(&mut header) {
                header_len = n;
            }
        }

        self.init_engine(eng, false, file_size, &header[..header_len]);
        MAP_SUCCESS
    }

    pub fn open_memory(&mut self, data: &[u8], _take_ownership: bool) -> i32 {
        let _ = self.begin_open();

        let cursor = Cursor::new(data.to_vec());
        let eng = match SymphoniaEngine::new(cursor, None) {
            Ok(e) => e,
            Err(_) => {
                self.state.store(STATE_ERROR, Ordering::Relaxed);
                self.telemetry.post_event(
                    EventType::State,
                    MapEventData { state: STATE_ERROR },
                );
                return MAP_ERROR_DECODE_FAILED;
            }
        };

        self.init_engine(eng, false, data.len() as u64, data);
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
        let _ = self.begin_open();

        let cap = if buffer_capacity_bytes > 0 {
            buffer_capacity_bytes
        } else {
            TripartiteBuffer::DEFAULT_RING_CAPACITY
        };

        let tot = if total_size > 0 { Some(total_size as u64) } else { None };
        let trip = TripartiteBuffer::new(cap, tot, is_live);

        let mut container = ContainerFormat::Unknown;
        if !initial_data.is_empty() {
            let (_status, boundary) = FormatSniffer::detect_head_boundary(initial_data, total_size);
            container = boundary.container;
            if boundary.audio_start > 0 {
                let head_len = (boundary.audio_start as usize).min(initial_data.len());
                trip.set_head(&initial_data[..head_len]);
                trip.set_audio_start(boundary.audio_start as u64);
                if initial_data.len() > head_len {
                    let _ = trip.feed_chunk(&initial_data[head_len..]);
                }
            } else if boundary.audio_start == 0 {
                trip.set_audio_start(0);
                let _ = trip.feed_chunk(initial_data);
            } else {
                let _ = trip.feed_chunk(initial_data);
            }
            if boundary.audio_end > 0 {
                trip.set_audio_end(boundary.audio_end as u64);
            }
            let mut lock_b = self.boundary_info.write().unwrap();
            *lock_b = Some(boundary);
        }

        if let Some(tail) = tail_data {
            if !tail.is_empty() {
                trip.set_tail(tail, None);
            }
        }

        let hint = match container {
            ContainerFormat::Mp3 => Some("mp3"),
            ContainerFormat::Adts => Some("aac"),
            ContainerFormat::Flac => Some("flac"),
            ContainerFormat::OggVorbis | ContainerFormat::OggOpus => Some("ogg"),
            ContainerFormat::Wav => Some("wav"),
            ContainerFormat::Mp4 => Some("mp4"),
            ContainerFormat::Unknown => match encoding_format {
                1 => Some("wav"),
                2 => Some("flac"),
                3 => Some("mp3"),
                4 => Some("ogg"),
                _ => None,
            },
        };

        let reader = trip.create_reader();
        let eng = match SymphoniaEngine::new(reader, hint) {
            Ok(e) => e,
            Err(_) => {
                self.state.store(STATE_ERROR, Ordering::Relaxed);
                self.telemetry.post_event(
                    EventType::State,
                    MapEventData { state: STATE_ERROR },
                );
                return MAP_ERROR_DECODE_FAILED;
            }
        };

        let tot = trip.total_size().unwrap_or(0);
        *self.trip_buffer.write().unwrap() = Some(trip);
        self.init_engine(eng, true, tot, initial_data);
        MAP_SUCCESS
    }

    pub fn open_custom_source(
        &mut self,
        source: CustomDartByteSource,
        handle: CustomByteSourceHandle,
        total_size: Option<u64>,
        is_seekable: bool,
        initial_bytes: &[u8],
    ) -> i32 {
        let _ = self.begin_open();

        let mut hint = None;
        if !initial_bytes.is_empty() {
            let (_status, boundary) = FormatSniffer::detect_head_boundary(
                initial_bytes,
                total_size.map(|s| s as i64).unwrap_or(-1),
            );
            hint = match boundary.container {
                ContainerFormat::Mp3 => Some("mp3"),
                ContainerFormat::Adts => Some("aac"),
                ContainerFormat::Flac => Some("flac"),
                ContainerFormat::OggVorbis | ContainerFormat::OggOpus => Some("ogg"),
                ContainerFormat::Wav => Some("wav"),
                ContainerFormat::Mp4 => Some("mp4"),
                ContainerFormat::Unknown => None,
            };
        }

        *self.custom_source_handle.write().unwrap() = Some(handle);

        let eng = match SymphoniaEngine::new(source, hint) {
            Ok(e) => e,
            Err(_) => {
                *self.custom_source_handle.write().unwrap() = None;
                self.state.store(STATE_ERROR, Ordering::Relaxed);
                self.telemetry.post_event(
                    EventType::State,
                    MapEventData { state: STATE_ERROR },
                );
                return MAP_ERROR_DECODE_FAILED;
            }
        };

        self.init_engine(eng, !is_seekable, total_size.unwrap_or(0), initial_bytes);
        MAP_SUCCESS
    }

    pub fn supply_custom_bytes(&self, _stream_id: u32, request_id: u64, data: Vec<u8>, is_eof: bool) -> i32 {
        if let Some(ref handle) = *self.custom_source_handle.read().unwrap() {
            handle.supply_bytes(request_id, data, is_eof);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn notify_custom_error(&self, _stream_id: u32, request_id: u64, error_message: String) -> i32 {
        if let Some(ref handle) = *self.custom_source_handle.read().unwrap() {
            handle.notify_error(request_id, error_message);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    fn init_engine(&mut self, eng: SymphoniaEngine, is_stream: bool, total_bytes: u64, initial_data: &[u8]) {
        let is_live = self.trip_buffer.read().map(|g| g.as_ref().map(|t| t.is_live()).unwrap_or(false)).unwrap_or(false);
        let sr = eng.sample_rate();
        let ch = eng.channels();
        let mut dur = if is_live { 0 } else { eng.duration_ms().unwrap_or(0) as i64 };

        if !is_live && dur <= 0 {
            if let Ok(guard) = self.trip_buffer.read() {
                if let Some(ref trip) = *guard {
                    let tail = trip.tail_data();
                    if !tail.is_empty() {
                        if let Ok(b_guard) = self.boundary_info.read() {
                            if let Some(boundary) = *b_guard {
                                if let Some(d) = FormatSniffer::extract_tail_duration_ms(boundary.container, sr, &tail) {
                                    dur = d;
                                }
                            }
                        }
                    }
                }
            }
        }

        if !is_live && dur <= 0 && total_bytes > 0 && !initial_data.is_empty() {
            if let Some((_br, d)) = FormatSniffer::sniff_stream_info(initial_data, total_bytes as i64) {
                if d > 0 {
                    dur = d;
                }
            }
        }

        let bitrate = if dur > 0 && total_bytes > 0 {
            ((total_bytes * 8000) / dur as u64) as u32
        } else if sr > 0 && ch > 0 {
            sr * ch * 16
        } else {
            0
        };

        {
            let mut eng_lock = self.engine.lock().unwrap();
            *eng_lock = Some(eng);
            self.sample_rate.store(sr, Ordering::SeqCst);
            self.channels.store(ch, Ordering::SeqCst);
            self.duration_ms.store(dur, Ordering::SeqCst);
            self.bitrate.store(bitrate, Ordering::SeqCst);
            self.is_stream.store(is_stream, Ordering::SeqCst);
            self.decoder_eof.store(false, Ordering::SeqCst);
            self.position_ms.store(0, Ordering::SeqCst);
            self.position_frames.store(0, Ordering::SeqCst);
            self.flush_generation.fetch_add(1, Ordering::SeqCst);
        }

        self.send_dsp_command(DspCommand::SetSampleRate(self.device_sample_rate.load(Ordering::Relaxed)));

        self.state.store(STATE_STOPPED, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::Duration,
            MapEventData { duration_ms: dur },
        );
        self.telemetry.post_event(
            EventType::Bitrate,
            MapEventData { bitrate },
        );
        self.telemetry.post_event(
            EventType::State,
            MapEventData { state: STATE_STOPPED },
        );

        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();
    }

    pub fn stream_feed(&mut self, data: &[u8]) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            match trip.feed_chunk(data) {
                Ok(_) => {
                    let (_, cvar) = &*self.decoder_wake;
                    cvar.notify_all();
                    MAP_SUCCESS
                }
                Err(crate::buffer::BufferError::Busy) => MAP_ERROR_BUSY,
                Err(_) => MAP_ERROR_GENERIC,
            }
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_flush(&mut self, new_stream_offset: i64) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.flush(new_stream_offset as u64);
            self.decoder_eof.store(false, Ordering::Relaxed);
            self.flush_generation.fetch_add(1, Ordering::Release);
            if trip.is_live() {
                self.stream_reinit_needed.store(true, Ordering::Release);
            }
            let (_, cvar) = &*self.decoder_wake;
            cvar.notify_all();
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_seek(&mut self, position_ms: i64, new_stream_offset: i64) -> i32 {
        let (is_hit, is_contiguous) = {
            if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
                trip.try_seek_cached(new_stream_offset as u64)
            } else {
                return MAP_ERROR_INVALID_STATE;
            }
        };

        let code = if is_hit {
            if is_contiguous {
                MAP_STREAM_SEEK_CACHE_HIT
            } else {
                MAP_STREAM_SEEK_CACHE_HIT_PREFETCH
            }
        } else {
            let _ = self.stream_flush(new_stream_offset);
            MAP_STREAM_SEEK_CACHE_MISS
        };

        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur > 0 && position_ms >= dur {
            self.decoder_eof.store(true, Ordering::Relaxed);
            self.state.store(STATE_COMPLETED, Ordering::Relaxed);
            self.position_ms.store(dur, Ordering::Relaxed);
            let sr = self.sample_rate.load(Ordering::Relaxed) as i64;
            self.position_frames.store(if sr > 0 { (dur * sr * 1024) / 1000 } else { 0 }, Ordering::Relaxed);
            self.seek_request_ms.store(-1, Ordering::SeqCst);
            self.flush_generation.fetch_add(1, Ordering::Release);

            self.telemetry.post_event(
                EventType::Position,
                MapEventData { position_ms: dur },
            );
            self.telemetry.post_event(
                EventType::IsPlaying,
                MapEventData { is_playing: 0 },
            );
            self.telemetry.post_event(
                EventType::IsCompleted,
                MapEventData { is_completed: 1 },
            );
            self.telemetry.post_event(
                EventType::State,
                MapEventData { state: STATE_COMPLETED },
            );
            if let Ok(guard) = self.completion_cb.read() {
                if let Some((cb, udata)) = *guard {
                    unsafe { cb(udata as *mut c_void); }
                }
            }
            return code;
        }

        self.decoder_eof.store(false, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::IsCompleted,
            MapEventData { is_completed: 0 },
        );
        if self.state.load(Ordering::Relaxed) == STATE_COMPLETED {
            self.state.store(STATE_PAUSED, Ordering::Relaxed);
            self.telemetry.post_event(
                EventType::State,
                MapEventData { state: STATE_PAUSED },
            );
        }
        self.flush_generation.fetch_add(1, Ordering::Release);

        self.position_ms.store(position_ms, Ordering::Relaxed);
        let sr = self.sample_rate.load(Ordering::Relaxed) as i64;
        self.position_frames.store(if sr > 0 { (position_ms * sr * 1024) / 1000 } else { 0 }, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::Position,
            MapEventData { position_ms },
        );

        self.seek_request_ms.store(position_ms, Ordering::SeqCst);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();
        code
    }

    pub fn stream_end(&mut self) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.mark_eof();
            let (_, cvar) = &*self.decoder_wake;
            cvar.notify_all();
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_get_status(&self, out_status: &mut MiniaudioStreamStatus) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            let r = trip.get_range();
            let cap = trip.ring_capacity();
            out_status.buffer_capacity = cap;
            out_status.buffer_fill = (r.end_byte.saturating_sub(r.start_byte)).max(0) as usize;
            out_status.fill_percentage = r.fill_percentage * 100.0;
            out_status.is_buffering = (self.state.load(Ordering::Relaxed) == STATE_BUFFERING) as i32;
            out_status.is_eof = r.is_eof;
            out_status.read_cursor_byte = r.read_cursor_byte;
            out_status.range_start = r.start_byte;
            out_status.range_end = r.end_byte;
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn get_buffered_range(&self, out_range: &mut MiniaudioBufferedRange) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            let r = trip.get_range();
            let duration = self.duration_ms.load(Ordering::Relaxed);
            out_range.start_ms = 0;
            out_range.duration_ms = duration;
            out_range.fill_percentage = r.fill_percentage * 100.0;
            out_range.stream_percentage = r.stream_percentage * 100.0;
            if r.total_bytes > 0 && duration > 0 {
                out_range.end_ms = ((r.end_byte as f64 / r.total_bytes as f64) * duration as f64) as i64;
            } else {
                out_range.end_ms = 0;
            }
            out_range.is_buffering = (self.state.load(Ordering::Relaxed) == STATE_BUFFERING) as i32;
            out_range.is_eof = r.is_eof;
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn stream_get_seek_byte(&self, position_ms: i64) -> i64 {
        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur <= 0 {
            return -1;
        }
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            if let Some(tot) = trip.total_size() {
                let start = trip.audio_start() as i64;
                let audio_len = (tot as i64) - start;
                let raw_byte = start + ((position_ms * audio_len) / dur);

                let headroom = 8192;
                let seek_byte = if position_ms > 0 {
                    (raw_byte - headroom).max(start)
                } else {
                    start
                };
                return (seek_byte / 4) * 4;
            }
        }
        -1
    }

    pub fn get_audio_data_offset(&self) -> i64 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.audio_start() as i64
        } else {
            0
        }
    }

    pub fn stream_get_pinned_head_size(&self) -> i64 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.head_size() as i64
        } else {
            0
        }
    }

    pub fn get_meta_bytes_version(&self) -> u32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.meta_version()
        } else {
            0
        }
    }

    pub fn get_meta_bytes_size(&self) -> usize {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.get_meta_bytes().len()
        } else {
            0
        }
    }

    pub fn copy_meta_bytes(&self, out: &mut [u8]) -> usize {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.copy_meta_bytes(out)
        } else {
            0
        }
    }

    pub fn set_icy_meta(&mut self, data: &[u8]) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.set_icy_meta(data);
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    pub fn probe_tail(&mut self, tail_data: &[u8], tail_offset: i64) -> i32 {
        if let Some(ref trip) = *self.trip_buffer.read().unwrap() {
            trip.probe_tail(tail_data, tail_offset as u64);
            if self.duration_ms.load(Ordering::Relaxed) <= 0 {
                let sr = self.sample_rate.load(Ordering::Relaxed);
                if let Ok(b_guard) = self.boundary_info.read() {
                    if let Some(boundary) = *b_guard {
                        if let Some(dur) = FormatSniffer::extract_tail_duration_ms(boundary.container, sr, tail_data) {
                            self.duration_ms.store(dur, Ordering::Relaxed);
                            self.telemetry.post_event(
                                EventType::Duration,
                                MapEventData { duration_ms: dur },
                            );
                        }
                    }
                }
            }
            MAP_SUCCESS
        } else {
            MAP_ERROR_INVALID_STATE
        }
    }

    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn read_pcm_frames(
        &mut self,
        frames_out: *mut f32,
        frame_count: u32,
        out_frames_read: *mut u32,
    ) -> i32 {
        if frames_out.is_null() || out_frames_read.is_null() {
            return MAP_ERROR_INVALID_ARGS;
        }
        if !self.renderer_ptr.is_null() {
            unsafe {
                (*self.renderer_ptr).render_pcm(frames_out, frame_count as usize);
            }
        }
        unsafe {
            *out_frames_read = frame_count;
        }
        MAP_SUCCESS
    }

    pub fn play(&mut self) -> i32 {
        let cur = self.state.load(Ordering::Relaxed);
        if cur == STATE_OPENING || cur == STATE_ERROR {
            return MAP_ERROR_INVALID_STATE;
        }

        self.decoder_eof.store(false, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::IsCompleted,
            MapEventData { is_completed: 0 },
        );

        if !self.device_ctx.is_null() {
            unsafe {
                map_device_start(self.device_ctx);
            }
        }

        self.state.store(STATE_PLAYING, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::IsPlaying,
            MapEventData { is_playing: 1 },
        );
        self.telemetry.post_event(
            EventType::State,
            MapEventData { state: STATE_PLAYING },
        );

        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        MAP_SUCCESS
    }

    pub fn pause(&mut self) -> i32 {
        let cur = self.state.load(Ordering::Relaxed);
        if cur == STATE_OPENING || cur == STATE_ERROR {
            return MAP_ERROR_INVALID_STATE;
        }

        self.state.store(STATE_PAUSED, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::IsPlaying,
            MapEventData { is_playing: 0 },
        );
        self.telemetry.post_event(
            EventType::State,
            MapEventData { state: STATE_PAUSED },
        );

        MAP_SUCCESS
    }

    pub fn stop(&mut self) -> i32 {
        if !self.device_ctx.is_null() {
            unsafe {
                map_device_stop(self.device_ctx);
            }
        }

        self.decoder_eof.store(false, Ordering::Relaxed);
        if let Ok(guard) = self.trip_buffer.read() {
            if let Some(ref trip) = *guard {
                if trip.is_live() {
                    self.stream_reinit_needed.store(true, Ordering::Release);
                }
            }
        }
        self.telemetry.post_event(
            EventType::IsCompleted,
            MapEventData { is_completed: 0 },
        );
        if self.state.load(Ordering::Relaxed) == STATE_COMPLETED {
            self.state.store(STATE_PAUSED, Ordering::Relaxed);
            self.telemetry.post_event(
                EventType::State,
                MapEventData { state: STATE_PAUSED },
            );
        }
        self.flush_generation.fetch_add(1, Ordering::Release);

        self.state.store(STATE_STOPPED, Ordering::Relaxed);
        self.position_ms.store(0, Ordering::Relaxed);
        self.position_frames.store(0, Ordering::Relaxed);
        self.silence_saved_ms.store(0, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::SilenceSaved,
            MapEventData { silence_saved_ms: 0 },
        );
        self.telemetry.post_event(
            EventType::IsPlaying,
            MapEventData { is_playing: 0 },
        );
        self.telemetry.post_event(
            EventType::Position,
            MapEventData { position_ms: 0 },
        );
        self.telemetry.post_event(
            EventType::State,
            MapEventData { state: STATE_STOPPED },
        );

        MAP_SUCCESS
    }

    pub fn seek(&mut self, position_ms: i64) -> i32 {
        let cur = self.state.load(Ordering::Relaxed);
        if cur == STATE_OPENING || cur == STATE_ERROR {
            return MAP_ERROR_INVALID_STATE;
        }

        let dur = self.duration_ms.load(Ordering::Relaxed);
        if dur > 0 && position_ms >= dur {
            self.decoder_eof.store(true, Ordering::Relaxed);
            self.state.store(STATE_COMPLETED, Ordering::Relaxed);
            self.position_ms.store(dur, Ordering::Relaxed);
            let sr = self.sample_rate.load(Ordering::Relaxed) as i64;
            self.position_frames.store(if sr > 0 { (dur * sr * 1024) / 1000 } else { 0 }, Ordering::Relaxed);
            self.seek_request_ms.store(-1, Ordering::SeqCst);
            self.flush_generation.fetch_add(1, Ordering::Release);

            self.telemetry.post_event(
                EventType::Position,
                MapEventData { position_ms: dur },
            );
            self.telemetry.post_event(
                EventType::IsPlaying,
                MapEventData { is_playing: 0 },
            );
            self.telemetry.post_event(
                EventType::IsCompleted,
                MapEventData { is_completed: 1 },
            );
            self.telemetry.post_event(
                EventType::State,
                MapEventData { state: STATE_COMPLETED },
            );
            if let Ok(guard) = self.completion_cb.read() {
                if let Some((cb, udata)) = *guard {
                    unsafe { cb(udata as *mut c_void); }
                }
            }
            return MAP_SUCCESS;
        }

        self.decoder_eof.store(false, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::IsCompleted,
            MapEventData { is_completed: 0 },
        );
        if self.state.load(Ordering::Relaxed) == STATE_COMPLETED {
            self.state.store(STATE_PAUSED, Ordering::Relaxed);
            self.telemetry.post_event(
                EventType::State,
                MapEventData { state: STATE_PAUSED },
            );
        }
        self.flush_generation.fetch_add(1, Ordering::Release);

        self.position_ms.store(position_ms, Ordering::Relaxed);
        let sr = self.sample_rate.load(Ordering::Relaxed) as i64;
        self.position_frames.store(if sr > 0 { (position_ms * sr * 1024) / 1000 } else { 0 }, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::Position,
            MapEventData { position_ms },
        );

        self.seek_request_ms.store(position_ms, Ordering::SeqCst);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        MAP_SUCCESS
    }

    pub fn set_volume(&mut self, volume: f32) -> i32 {
        let vol = volume.max(0.0);
        self.volume.store(vol.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetVolume(vol));
        self.telemetry.post_event(
            EventType::Volume,
            MapEventData { volume: vol },
        );
        MAP_SUCCESS
    }

    pub fn set_rate(&mut self, rate: f32) -> i32 {
        let r = rate.clamp(0.25, 4.0);
        self.rate.store(r.to_bits(), Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::Rate,
            MapEventData { rate: r },
        );
        MAP_SUCCESS
    }

    pub fn set_pitch(&mut self, pitch: f32) -> i32 {
        let p = pitch.clamp(0.5, 2.0);
        self.pitch.store(p.to_bits(), Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::Pitch,
            MapEventData { pitch: p },
        );
        MAP_SUCCESS
    }

    pub fn set_buffer_size(&mut self, frames: u32) -> i32 {
        self.period_size_in_frames.store(frames, Ordering::Relaxed);
        self.telemetry.post_event(
            EventType::BufferSize,
            MapEventData { buffer_size: frames },
        );
        MAP_SUCCESS
    }

    pub fn get_buffer_size(&self) -> u32 {
        self.period_size_in_frames.load(Ordering::Relaxed)
    }

    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    pub fn set_device(&mut self, device_id: *const c_char) -> i32 {
        if self.device_ctx.is_null() {
            return MAP_ERROR_INVALID_STATE;
        }
        let ret = unsafe {
            map_device_set_device(self.device_ctx, device_id)
        };
        let mut dev_info = MapDeviceInfo::default();
        let _ = self.get_current_device(&mut dev_info);
        let mut tele_dev = TelemetryDeviceInfo::default();
        tele_dev.id = dev_info.id;
        tele_dev.effective_id = dev_info.effective_id;
        tele_dev.name = dev_info.name;
        tele_dev.is_default = dev_info.is_default;
        tele_dev.is_auto = dev_info.is_auto;

        self.telemetry.post_event(
            EventType::Device,
            MapEventData { device: tele_dev },
        );
        ret
    }

    pub fn get_current_device(&self, out_device: &mut MapDeviceInfo) -> i32 {
        if self.device_ctx.is_null() {
            return MAP_ERROR_INVALID_STATE;
        }
        unsafe {
            map_device_get_current_device_info(self.device_ctx, out_device as *mut MapDeviceInfo)
        }
    }

    pub fn set_pause_on_device_change(&mut self, enabled: i32) -> i32 {
        self.pause_on_device_change.store(enabled != 0, Ordering::Relaxed);
        MAP_SUCCESS
    }

    pub fn get_pause_on_device_change(&self) -> i32 {
        self.pause_on_device_change.load(Ordering::Relaxed) as i32
    }

    pub fn set_equalizer(&mut self, params: &EqualizerParams) -> i32 {
        *self.eq_params.write().unwrap() = *params;
        self.send_dsp_command(DspCommand::SetEqualizerParams(*params));
        self.telemetry.post_event(
            EventType::Equalizer,
            MapEventData { equalizer: *params },
        );
        MAP_SUCCESS
    }

    pub fn set_equalizer_band(&mut self, band: u32, gain_db: f32) -> i32 {
        self.eq_params.write().unwrap().set_band(band as usize, gain_db);
        self.send_dsp_command(DspCommand::SetEqualizerBand { band: band as usize, gain_db });
        MAP_SUCCESS
    }

    pub fn get_equalizer(&self, out: &mut EqualizerParams) -> i32 {
        *out = *self.eq_params.read().unwrap();
        MAP_SUCCESS
    }

    pub fn set_replay_gain(&mut self, gain_db: f32, peak: f32, prevent_clipping: i32) -> i32 {
        let rg = ReplayGainConfig {
            gain_db,
            peak,
            prevent_clipping,
            enabled: 1,
        };
        *self.replay_gain.write().unwrap() = rg;
        self.send_dsp_command(DspCommand::SetReplayGain(rg));
        self.telemetry.post_event(
            EventType::ReplayGain,
            MapEventData { replay_gain: rg },
        );
        MAP_SUCCESS
    }

    pub fn clear_replay_gain(&mut self) -> i32 {
        let rg = ReplayGainConfig::default();
        *self.replay_gain.write().unwrap() = rg;
        self.send_dsp_command(DspCommand::SetReplayGain(rg));
        self.telemetry.post_event(
            EventType::ReplayGain,
            MapEventData { replay_gain: rg },
        );
        MAP_SUCCESS
    }

    pub fn set_preamp(&mut self, preamp_db: f32) -> i32 {
        self.preamp_db.store(preamp_db.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetPreamp(preamp_db));
        self.telemetry.post_event(
            EventType::Preamp,
            MapEventData { preamp_db },
        );
        MAP_SUCCESS
    }

    pub fn set_balance(&mut self, pan: f32) -> i32 {
        self.balance.store(pan.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetBalance(pan));
        self.telemetry.post_event(
            EventType::Balance,
            MapEventData { balance: pan },
        );
        MAP_SUCCESS
    }

    pub fn set_mono(&mut self, enabled: i32) -> i32 {
        let mono = enabled != 0;
        self.mono_enabled.store(mono, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetMono(mono));
        self.telemetry.post_event(
            EventType::Mono,
            MapEventData { mono_enabled: enabled },
        );
        MAP_SUCCESS
    }

    pub fn set_crossfeed(&mut self, mode: i32) -> i32 {
        let cf_mode = match mode {
            1 => CrossfeedMode::MoffatBauer,
            2 => CrossfeedMode::ChuMoy,
            _ => CrossfeedMode::Off,
        };
        self.crossfeed_mode.store(mode, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetCrossfeed(cf_mode));
        self.telemetry.post_event(
            EventType::Crossfeed,
            MapEventData { crossfeed_mode: mode },
        );
        MAP_SUCCESS
    }

    pub fn set_spatializer(&mut self, enabled: i32, width: f32) -> i32 {
        let en = enabled != 0;
        self.spatializer_enabled.store(en, Ordering::Relaxed);
        self.spatializer_width.store(width.to_bits(), Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetSpatializer { enabled: en, width });
        self.telemetry.post_event(
            EventType::Spatializer,
            MapEventData {
                spatializer: SpatializerData {
                    enabled,
                    width,
                },
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
        let rev = ReverbConfig {
            enabled,
            room_size,
            damping,
            width,
            wet,
            dry,
        };
        *self.reverb_config.write().unwrap() = rev;
        self.send_dsp_command(DspCommand::SetReverb(rev));
        self.telemetry.post_event(
            EventType::Reverb,
            MapEventData { reverb: rev },
        );
        MAP_SUCCESS
    }

    pub fn set_limiter(&mut self, enabled: i32) -> i32 {
        let en = enabled != 0;
        self.limiter_enabled.store(en, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetLimiter(en));
        self.telemetry.post_event(
            EventType::Limiter,
            MapEventData { limiter_enabled: enabled },
        );
        MAP_SUCCESS
    }

    pub fn set_silence_config(&mut self, config: &SilenceConfig) -> i32 {
        *self.silence_config.write().unwrap() = *config;
        self.telemetry.post_event(
            EventType::SilenceConfig,
            MapEventData { silence_config: *config },
        );
        MAP_SUCCESS
    }

    pub fn get_silence_config(&self, out: &mut SilenceConfig) -> i32 {
        *out = *self.silence_config.read().unwrap();
        MAP_SUCCESS
    }

    pub fn get_silence_saved_ms(&self) -> i64 {
        self.silence_saved_ms.load(Ordering::Relaxed)
    }

    pub fn set_visualizer_enabled(&mut self, enabled: i32) -> i32 {
        let en = enabled != 0;
        self.visualizer_enabled.store(en, Ordering::Relaxed);
        self.send_dsp_command(DspCommand::SetVisualizerEnabled(en));
        if !en {
            let zero_vis = VisualizerData::default();
            self.visualizer_seqlock.write(|v| *v = zero_vis);
            self.telemetry.post_event(
                EventType::Visualizer,
                MapEventData { visualizer: zero_vis },
            );
        }
        self.telemetry.post_event(
            EventType::VisualizerEnabled,
            MapEventData { visualizer_enabled: enabled },
        );
        MAP_SUCCESS
    }

    pub fn is_visualizer_enabled(&self) -> i32 {
        self.visualizer_enabled.load(Ordering::Relaxed) as i32
    }

    pub fn get_visualizer_data(&self, out: &mut VisualizerData) -> i32 {
        *out = self.visualizer_seqlock.read();
        MAP_SUCCESS
    }

    pub fn get_status(&self, out: &mut MiniaudioPlayerStatus) -> i32 {
        out.position_ms = self.position_ms.load(Ordering::Relaxed);
        out.duration_ms = self.duration_ms.load(Ordering::Relaxed);
        let st = self.state.load(Ordering::Relaxed);
        out.state = st;
        out.is_playing = (st == STATE_PLAYING) as i32;
        out.is_buffering = (st == STATE_BUFFERING) as i32;
        out.is_completed = (st == STATE_COMPLETED) as i32;
        out.volume = f32::from_bits(self.volume.load(Ordering::Relaxed));
        out.rate = f32::from_bits(self.rate.load(Ordering::Relaxed));
        out.pitch = f32::from_bits(self.pitch.load(Ordering::Relaxed));
        out.bitrate = self.bitrate.load(Ordering::Relaxed);
        out.sample_rate = self.sample_rate.load(Ordering::Relaxed);
        out.channels = self.channels.load(Ordering::Relaxed);

        out.equalizer = *self.eq_params.read().unwrap();
        out.preamp_db = f32::from_bits(self.preamp_db.load(Ordering::Relaxed));
        out.replay_gain = *self.replay_gain.read().unwrap();
        out.balance = f32::from_bits(self.balance.load(Ordering::Relaxed));
        out.mono_enabled = self.mono_enabled.load(Ordering::Relaxed) as i32;
        out.crossfeed_mode = self.crossfeed_mode.load(Ordering::Relaxed);
        out.spatializer_enabled = self.spatializer_enabled.load(Ordering::Relaxed) as i32;
        out.spatializer_width = f32::from_bits(self.spatializer_width.load(Ordering::Relaxed));
        out.reverb = *self.reverb_config.read().unwrap();
        out.limiter_enabled = self.limiter_enabled.load(Ordering::Relaxed) as i32;
        out.visualizer = self.visualizer_seqlock.read();

        out.visualizer_enabled = self.visualizer_enabled.load(Ordering::Relaxed) as i32;
        out.silence = *self.silence_config.read().unwrap();
        out.silence_saved_ms = self.silence_saved_ms.load(Ordering::Relaxed);

        let _ = self.get_current_device(&mut out.device);

        MAP_SUCCESS
    }

    pub fn destroy(&mut self) {
        let _ = self.stop();
        self.telemetry.stop();
        if let Ok(mut cb) = self.completion_cb.write() {
            *cb = None;
        }
        self.decoder_running.store(false, Ordering::Relaxed);
        let (_, cvar) = &*self.decoder_wake;
        cvar.notify_all();

        if let Some(handle) = self.decoder_thread.take() {
            let _ = handle.join();
        }

        if !self.device_ctx.is_null() {
            unsafe {
                map_device_destroy(self.device_ctx);
            }
            self.device_ctx = std::ptr::null_mut();
        }

        if !self.renderer_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.renderer_ptr));
            }
            self.renderer_ptr = std::ptr::null_mut();
        }
    }
}

impl Drop for PlayerCoordinator {
    fn drop(&mut self) {
        self.destroy();
    }
}
