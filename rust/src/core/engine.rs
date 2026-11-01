//! Real-time decoupled dual-deck engine coordinator with lock-free crossfading,
//! unified telemetry, and composite visualizer processing.

use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread::JoinHandle;

use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_set_device,
    map_device_start, map_device_stop, MapDeviceContext, MAP_SUCCESS,
};
use crate::core::capture::DeviceCaptureNode;
use crate::core::player::PlayerCoordinator;
use crate::core::recording::{offline_bounce_to_wav, LiveRecorder, WavFormat};
use crate::core::renderer::{AudioRenderer, PcmRendererHeader};
use crate::dsp::ducking::AutoDucker;
use crate::dsp::visualizer::{Visualizer, VisualizerData};
use crate::sync::seqlock::CachePaddedSeqlock;

pub const ENGINE_PHASE_IDLE: i32 = 0;
pub const ENGINE_PHASE_LOADING: i32 = 1;
pub const ENGINE_PHASE_PLAYING: i32 = 2;
pub const ENGINE_PHASE_PAUSED: i32 = 3;
pub const ENGINE_PHASE_AUTO_CROSSFADING: i32 = 4;
pub const ENGINE_PHASE_MANUAL_CROSSFADING: i32 = 5;
pub const ENGINE_PHASE_COMPLETED: i32 = 6;
pub const ENGINE_PHASE_ERROR: i32 = 7;

#[repr(C)]
pub struct CrossfadeAtomic {
    pub is_active: AtomicBool,
    pub from_deck: AtomicI32, // 0: A, 1: B
    pub to_deck: AtomicI32,   // 0: A, 1: B
    pub current_frame: AtomicU64,
    pub total_frames: AtomicU64,
    pub curve: AtomicI32, // 0: EqualPower, 1: Linear
}

impl Default for CrossfadeAtomic {
    fn default() -> Self {
        Self {
            is_active: AtomicBool::new(false),
            from_deck: AtomicI32::new(0),
            to_deck: AtomicI32::new(1),
            current_frame: AtomicU64::new(0),
            total_frames: AtomicU64::new(0),
            curve: AtomicI32::new(0),
        }
    }
}

/// Hardware audio callback renderer that mixes Deck A and Deck B with sample-accurate crossfading
/// and computes the FFT visualizer on the composite audio output.
#[repr(C)]
pub struct EngineRenderer {
    pub header: PcmRendererHeader,
    pub renderer_a: *mut AudioRenderer,
    pub renderer_b: *mut AudioRenderer,
    pub active_deck: Arc<AtomicI32>, // 0: A, 1: B
    pub crossfade: Arc<CrossfadeAtomic>,
    pub crossfade_completed_flag: Arc<AtomicBool>,
    pub visualizer: Visualizer,
    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    pub visualizer_enabled: Arc<AtomicBool>,
    pub channels: usize,
    pub sample_rate: u32,
    pub scratch_a: Vec<f32>,
    pub scratch_b: Vec<f32>,

    // Recording sink
    pub record_producer: Option<rtrb::Producer<f32>>,
    pub is_recording: Arc<AtomicBool>,

    // Auto-ducking & Microphone capture
    pub ducker: AutoDucker,
    pub mic_consumer: Arc<Mutex<Option<rtrb::Consumer<f32>>>>,
    pub mic_enabled: Arc<AtomicBool>,
    pub mic_volume: Arc<AtomicU32>,
    pub scratch_mic: Vec<f32>,

    // Cue output
    pub cue_producer: Option<rtrb::Producer<f32>>,
    pub cue_enabled: Arc<AtomicBool>,
    pub cue_mode: Arc<AtomicI32>, // 0: Deck A, 1: Deck B, 2: Master
}

unsafe impl Send for EngineRenderer {}

pub unsafe extern "C" fn engine_renderer_render_trampoline(
    ptr: *mut c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut EngineRenderer);
    r.render_pcm(output, count);
}

pub unsafe extern "C" fn engine_renderer_notif_trampoline(
    _ptr: *mut c_void,
    _notif: i32,
) {
    // Hardware notification callback
}

#[repr(C)]
pub struct CueRenderer {
    pub header: PcmRendererHeader,
    pub consumer: rtrb::Consumer<f32>,
    pub volume: Arc<AtomicU32>,
    pub channels: usize,
    pub is_enabled: Arc<AtomicBool>,
}

unsafe impl Send for CueRenderer {}

pub unsafe extern "C" fn cue_renderer_render_trampoline(
    ptr: *mut c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut CueRenderer);
    r.render_pcm(output, count);
}

pub unsafe extern "C" fn cue_renderer_notif_trampoline(
    _ptr: *mut c_void,
    _notif: i32,
) {}

impl CueRenderer {
    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        if output_frames.is_null() || frame_count == 0 {
            return;
        }

        let total_samples = frame_count * self.channels;
        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

        if !self.is_enabled.load(Ordering::Relaxed) {
            out_slice.fill(0.0);
            return;
        }

        let slots = self.consumer.slots();
        let to_read = slots.min(total_samples);
        let read = if to_read > 0 {
            if let Ok(chunk) = self.consumer.read_chunk(to_read) {
                let (s1, s2) = chunk.as_slices();
                let n1 = s1.len();
                out_slice[..n1].copy_from_slice(s1);
                if !s2.is_empty() {
                    out_slice[n1..to_read].copy_from_slice(s2);
                }
                chunk.commit_all();
                to_read
            } else {
                0
            }
        } else {
            0
        };

        if read < total_samples {
            out_slice[read..].fill(0.0);
        }

        let vol = f32::from_bits(self.volume.load(Ordering::Relaxed));
        if (vol - 1.0).abs() > 0.001 {
            for sample in out_slice.iter_mut() {
                *sample *= vol;
            }
        }
    }
}

impl EngineRenderer {
    #[inline]
    pub fn render_pcm(&mut self, output_frames: *mut f32, frame_count: usize) {
        if output_frames.is_null() || frame_count == 0 {
            return;
        }

        let total_samples = frame_count * self.channels;
        let is_xfading = self.crossfade.is_active.load(Ordering::Acquire);

        if !is_xfading {
            let active = self.active_deck.load(Ordering::Acquire);
            let target_renderer = if active == 0 { self.renderer_a } else { self.renderer_b };
            if !target_renderer.is_null() {
                unsafe {
                    (*target_renderer).render_pcm(output_frames, frame_count);
                }
            } else {
                unsafe {
                    std::ptr::write_bytes(output_frames, 0, total_samples);
                }
            }
        } else {
            // Allocate / resize scratch buffers if needed
            if self.scratch_a.len() < total_samples {
                self.scratch_a.resize(total_samples, 0.0);
            }
            if self.scratch_b.len() < total_samples {
                self.scratch_b.resize(total_samples, 0.0);
            }

            // Zero scratch buffers
            self.scratch_a[..total_samples].fill(0.0);
            self.scratch_b[..total_samples].fill(0.0);

            if !self.renderer_a.is_null() {
                unsafe {
                    (*self.renderer_a).render_pcm(self.scratch_a.as_mut_ptr(), frame_count);
                }
            }
            if !self.renderer_b.is_null() {
                unsafe {
                    (*self.renderer_b).render_pcm(self.scratch_b.as_mut_ptr(), frame_count);
                }
            }

            let from_deck = self.crossfade.from_deck.load(Ordering::Relaxed);
            let curve = self.crossfade.curve.load(Ordering::Relaxed);
            let cur_frame = self.crossfade.current_frame.load(Ordering::Relaxed);
            let tot_frames = self.crossfade.total_frames.load(Ordering::Relaxed).max(1);

            let (from_buf, to_buf) = if from_deck == 0 {
                (&self.scratch_a, &self.scratch_b)
            } else {
                (&self.scratch_b, &self.scratch_a)
            };

            let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

            for k in 0..frame_count {
                let frame_idx = cur_frame + k as u64;
                let progress = (frame_idx as f32 / tot_frames as f32).clamp(0.0, 1.0);

                let (gain_out, gain_in) = if curve == 1 {
                    // Linear
                    (1.0 - progress, progress)
                } else {
                    // Equal Power
                    let angle = progress * std::f32::consts::FRAC_PI_2;
                    (angle.cos(), angle.sin())
                };

                for c in 0..self.channels {
                    let idx = k * self.channels + c;
                    out_slice[idx] = gain_out * from_buf[idx] + gain_in * to_buf[idx];
                }
            }

            let next_frame = cur_frame + frame_count as u64;
            self.crossfade.current_frame.store(next_frame, Ordering::Relaxed);

            if next_frame >= tot_frames {
                self.crossfade.is_active.store(false, Ordering::Release);
                let to_deck = self.crossfade.to_deck.load(Ordering::Relaxed);
                self.active_deck.store(to_deck, Ordering::Release);
                self.crossfade_completed_flag.store(true, Ordering::Release);
            }
        }

        let out_slice = unsafe { std::slice::from_raw_parts_mut(output_frames, total_samples) };

        // 1. Microphone & Auto-Ducking
        if self.mic_enabled.load(Ordering::Relaxed) {
            if let Ok(mut mic_guard) = self.mic_consumer.try_lock() {
                if let Some(ref mut mic_c) = *mic_guard {
                    let slots = mic_c.slots();
                    let to_read = slots.min(total_samples);
                    if to_read > 0 {
                        if self.scratch_mic.len() < to_read {
                            self.scratch_mic.resize(to_read, 0.0);
                        }
                        if let Ok(chunk) = mic_c.read_chunk(to_read) {
                            let (s1, s2) = chunk.as_slices();
                            let n1 = s1.len();
                            self.scratch_mic[..n1].copy_from_slice(s1);
                            if !s2.is_empty() {
                                self.scratch_mic[n1..to_read].copy_from_slice(s2);
                            }
                            chunk.commit_all();

                            // Process sidechain auto-ducking on music
                            self.ducker.process_sidechain(&self.scratch_mic[..to_read], out_slice, self.channels);

                            // Mix microphone into master output
                            let mic_gain = f32::from_bits(self.mic_volume.load(Ordering::Relaxed));
                            let min_len = to_read.min(total_samples);
                            for i in 0..min_len {
                                out_slice[i] += mic_gain * self.scratch_mic[i];
                            }
                        }
                    }
                }
            }
        }

        // 2. Cue Output Push
        if self.cue_enabled.load(Ordering::Relaxed) {
            if let Some(ref mut cue_p) = self.cue_producer {
                let slots = cue_p.slots();
                let to_write = slots.min(total_samples);
                if to_write > 0 {
                    let mode = self.cue_mode.load(Ordering::Relaxed);
                    let src = match mode {
                        0 => if self.scratch_a.len() >= to_write { &self.scratch_a[..to_write] } else { &out_slice[..to_write] },
                        1 => if self.scratch_b.len() >= to_write { &self.scratch_b[..to_write] } else { &out_slice[..to_write] },
                        _ => &out_slice[..to_write],
                    };
                    if let Ok(mut chunk) = cue_p.write_chunk(to_write) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let n1 = s1.len();
                        s1.copy_from_slice(&src[..n1]);
                        if !s2.is_empty() {
                            s2.copy_from_slice(&src[n1..to_write]);
                        }
                        chunk.commit_all();
                    }
                }
            }
        }

        // 3. Live Recording Sink Push
        if self.is_recording.load(Ordering::Relaxed) {
            if let Some(ref mut rec_p) = self.record_producer {
                let slots = rec_p.slots();
                let to_write = slots.min(total_samples);
                if to_write > 0 {
                    if let Ok(mut chunk) = rec_p.write_chunk(to_write) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let n1 = s1.len();
                        s1.copy_from_slice(&out_slice[..n1]);
                        if !s2.is_empty() {
                            s2.copy_from_slice(&out_slice[n1..to_write]);
                        }
                        chunk.commit_all();
                    }
                }
            }
        }

        // 4. Compute composite FFT visualizer data directly on the mixed output buffer
        if self.visualizer_enabled.load(Ordering::Relaxed) {
            if !self.visualizer.is_enabled() {
                self.visualizer.set_enabled(true);
            }
            self.visualizer.process_frames(out_slice);
            let vis = self.visualizer.data();
            self.visualizer_seqlock.write(|v| *v = vis);
        } else if self.visualizer.is_enabled() {
            self.visualizer.set_enabled(false);
            self.visualizer_seqlock.write(|v| *v = crate::dsp::visualizer::VisualizerData::default());
        }
    }
}

#[derive(Clone, Debug)]
pub struct EngineItemCore {
    pub id: i64,
    pub source: String,
    pub headers: Option<Vec<crate::api::types::RustHttpHeader>>,
    pub data_bytes: Option<Vec<u8>>,
    pub replay_gain_db: Option<f32>,
    pub replay_peak: Option<f32>,
}

pub struct EngineCoordinator {
    pub deck_a: Box<PlayerCoordinator>,
    pub deck_b: Box<PlayerCoordinator>,
    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut EngineRenderer,

    pub active_deck: Arc<AtomicI32>,
    pub crossfade: Arc<CrossfadeAtomic>,
    pub crossfade_completed_flag: Arc<AtomicBool>,
    pub phase: Arc<AtomicI32>,

    pub queue: Arc<RwLock<Vec<EngineItemCore>>>,
    pub current_index: Arc<AtomicI64>,
    pub loop_mode: Arc<AtomicI32>, // 0: off, 1: one, 2: all
    pub shuffle_enabled: Arc<AtomicBool>,
    pub infinite_mix_enabled: Arc<AtomicBool>,

    pub auto_crossfade_duration_ms: Arc<AtomicU64>,
    pub manual_crossfade_duration_ms: Arc<AtomicU64>,
    pub crossfade_curve: Arc<AtomicI32>,
    pub auto_crossfade_target_index: Arc<AtomicI64>,

    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    pub visualizer_enabled: Arc<AtomicBool>,

    // Recording sink
    pub live_recorder: Arc<RwLock<LiveRecorder>>,
    pub is_recording: Arc<AtomicBool>,
    pub record_consumer: Arc<Mutex<rtrb::Consumer<f32>>>,

    // Cue output
    pub cue_device_ctx: *mut MapDeviceContext,
    pub cue_renderer_ptr: *mut CueRenderer,
    pub cue_enabled: Arc<AtomicBool>,
    pub cue_volume: Arc<AtomicU32>,
    pub cue_mode: Arc<AtomicI32>,

    // Microphone & Auto-Ducking
    pub capture_node: Arc<RwLock<Option<Box<DeviceCaptureNode>>>>,
    pub mic_consumer: Arc<Mutex<Option<rtrb::Consumer<f32>>>>,
    pub mic_enabled: Arc<AtomicBool>,
    pub mic_volume: Arc<AtomicU32>,

    pub thread_running: Arc<AtomicBool>,
    pub monitor_thread: Option<JoinHandle<()>>,
}

unsafe impl Send for EngineCoordinator {}
unsafe impl Sync for EngineCoordinator {}

impl Drop for EngineCoordinator {
    fn drop(&mut self) {
        self.thread_running.store(false, Ordering::Relaxed);
        if let Some(handle) = self.monitor_thread.take() {
            let _ = handle.join();
        }

        // Clean up Cue device
        if !self.cue_device_ctx.is_null() {
            unsafe {
                map_device_stop(self.cue_device_ctx);
                map_device_destroy(self.cue_device_ctx);
            }
            self.cue_device_ctx = std::ptr::null_mut();
        }

        if !self.cue_renderer_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(self.cue_renderer_ptr));
            }
            self.cue_renderer_ptr = std::ptr::null_mut();
        }

        // Clean up Microphone node
        if let Ok(mut cap_lock) = self.capture_node.write() {
            if let Some(node) = cap_lock.take() {
                node.stop();
            }
        }

        // Clean up Master playback device
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

impl EngineCoordinator {
    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: *const c_char,
    ) -> Result<Box<Self>, i32> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels } else { 2 };
        let period = if period_size > 0 { period_size } else { 1024 };

        let deck_a = PlayerCoordinator::new_deck(sr, ch, period)?;
        let deck_b = PlayerCoordinator::new_deck(sr, ch, period)?;

        let active_deck = Arc::new(AtomicI32::new(0));
        let crossfade = Arc::new(CrossfadeAtomic::default());
        let crossfade_completed_flag = Arc::new(AtomicBool::new(false));
        let phase = Arc::new(AtomicI32::new(ENGINE_PHASE_IDLE));

        let visualizer_seqlock = Arc::new(CachePaddedSeqlock::new(VisualizerData::default()));
        let visualizer_enabled = Arc::new(AtomicBool::new(false));

        let (record_producer, record_consumer) = rtrb::RingBuffer::new(131072);
        let is_recording = Arc::new(AtomicBool::new(false));

        let (cue_producer, cue_consumer) = rtrb::RingBuffer::new(32768);
        let cue_enabled = Arc::new(AtomicBool::new(false));
        let cue_volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let cue_mode = Arc::new(AtomicI32::new(0)); // 0: Deck A

        let cue_renderer = CueRenderer {
            header: PcmRendererHeader {
                render_fn: cue_renderer_render_trampoline,
                notif_fn: cue_renderer_notif_trampoline,
            },
            consumer: cue_consumer,
            volume: cue_volume.clone(),
            channels: ch as usize,
            is_enabled: cue_enabled.clone(),
        };
        let cue_renderer_ptr = Box::into_raw(Box::new(cue_renderer));

        let mic_consumer = Arc::new(Mutex::new(None));
        let mic_enabled = Arc::new(AtomicBool::new(false));
        let mic_volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));

        let renderer = EngineRenderer {
            header: PcmRendererHeader {
                render_fn: engine_renderer_render_trampoline,
                notif_fn: engine_renderer_notif_trampoline,
            },
            renderer_a: deck_a.renderer_ptr,
            renderer_b: deck_b.renderer_ptr,
            active_deck: active_deck.clone(),
            crossfade: crossfade.clone(),
            crossfade_completed_flag: crossfade_completed_flag.clone(),
            visualizer: Visualizer::new(ch as usize, sr),
            visualizer_seqlock: visualizer_seqlock.clone(),
            visualizer_enabled: visualizer_enabled.clone(),
            channels: ch as usize,
            sample_rate: sr,
            scratch_a: vec![0.0f32; period as usize * ch as usize * 4],
            scratch_b: vec![0.0f32; period as usize * ch as usize * 4],

            record_producer: Some(record_producer),
            is_recording: is_recording.clone(),

            ducker: AutoDucker::new(sr),
            mic_consumer: mic_consumer.clone(),
            mic_enabled: mic_enabled.clone(),
            mic_volume: mic_volume.clone(),
            scratch_mic: vec![0.0f32; period as usize * ch as usize * 4],

            cue_producer: Some(cue_producer),
            cue_enabled: cue_enabled.clone(),
            cue_mode: cue_mode.clone(),
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
            unsafe {
                drop(Box::from_raw(cue_renderer_ptr));
                drop(Box::from_raw(renderer_ptr));
            }
            return Err(dev_res);
        }

        let queue = Arc::new(RwLock::new(Vec::new()));
        let current_index = Arc::new(AtomicI64::new(0));
        let loop_mode = Arc::new(AtomicI32::new(0));
        let shuffle_enabled = Arc::new(AtomicBool::new(false));
        let infinite_mix_enabled = Arc::new(AtomicBool::new(false));

        let auto_crossfade_duration_ms = Arc::new(AtomicU64::new(5000));
        let manual_crossfade_duration_ms = Arc::new(AtomicU64::new(100));
        let crossfade_curve = Arc::new(AtomicI32::new(0));
        let auto_crossfade_target_index = Arc::new(AtomicI64::new(-1));

        let thread_running = Arc::new(AtomicBool::new(true));

        Ok(Box::new(Self {
            deck_a,
            deck_b,
            device_ctx,
            renderer_ptr,
            active_deck,
            crossfade,
            crossfade_completed_flag,
            phase,
            queue,
            current_index,
            loop_mode,
            shuffle_enabled,
            infinite_mix_enabled,
            auto_crossfade_duration_ms,
            manual_crossfade_duration_ms,
            crossfade_curve,
            auto_crossfade_target_index,
            visualizer_seqlock,
            visualizer_enabled,

            live_recorder: Arc::new(RwLock::new(LiveRecorder::new(sr, ch as usize, WavFormat::Pcm16))),
            is_recording,
            record_consumer: Arc::new(Mutex::new(record_consumer)),

            cue_device_ctx: std::ptr::null_mut(),
            cue_renderer_ptr,
            cue_enabled,
            cue_volume,
            cue_mode,

            capture_node: Arc::new(RwLock::new(None)),
            mic_consumer,
            mic_enabled,
            mic_volume,

            thread_running,
            monitor_thread: None,
        }))
    }

    pub fn start_device(&mut self) -> i32 {
        if !self.device_ctx.is_null() {
            unsafe { map_device_start(self.device_ctx) }
        } else {
            MAP_SUCCESS
        }
    }

    pub fn stop_device(&mut self) -> i32 {
        if !self.device_ctx.is_null() {
            unsafe { map_device_stop(self.device_ctx) }
        } else {
            MAP_SUCCESS
        }
    }

    pub fn set_device(&mut self, device_id: *const c_char) -> i32 {
        if !self.device_ctx.is_null() {
            unsafe { map_device_set_device(self.device_ctx, device_id) }
        } else {
            MAP_SUCCESS
        }
    }

    pub fn active_deck_mut(&mut self) -> &mut PlayerCoordinator {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &mut self.deck_a
        } else {
            &mut self.deck_b
        }
    }

    pub fn standby_deck_mut(&mut self) -> &mut PlayerCoordinator {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &mut self.deck_b
        } else {
            &mut self.deck_a
        }
    }

    pub fn active_deck_ref(&self) -> &PlayerCoordinator {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &self.deck_a
        } else {
            &self.deck_b
        }
    }

    pub fn standby_deck_ref(&self) -> &PlayerCoordinator {
        if self.active_deck.load(Ordering::Relaxed) == 0 {
            &self.deck_b
        } else {
            &self.deck_a
        }
    }

    pub fn append_items(&mut self, items: Vec<EngineItemCore>) {
        let mut q = self.queue.write().unwrap();
        q.extend(items);
    }

    pub fn insert_next_item(&mut self, item: EngineItemCore) {
        let mut q = self.queue.write().unwrap();
        let cur = self.current_index.load(Ordering::Relaxed);
        let insert_idx = ((cur + 1).max(0) as usize).min(q.len());
        q.insert(insert_idx, item);
    }

    pub fn remove_item_at(&mut self, index: usize) -> Option<EngineItemCore> {
        let mut q = self.queue.write().unwrap();
        if index >= q.len() {
            return None;
        }
        let removed = q.remove(index);
        let cur = self.current_index.load(Ordering::Relaxed);
        if (index as i64) < cur {
            self.current_index.store(cur - 1, Ordering::Release);
        } else if (index as i64) == cur {
            if q.is_empty() {
                self.current_index.store(-1, Ordering::Release);
                self.phase.store(ENGINE_PHASE_IDLE, Ordering::Release);
                self.deck_a.stop();
                self.deck_b.stop();
            } else if cur >= q.len() as i64 {
                self.current_index.store((q.len() - 1) as i64, Ordering::Release);
            }
        }
        Some(removed)
    }

    pub fn reorder_item(&mut self, from: usize, to: usize) -> bool {
        let mut q = self.queue.write().unwrap();
        if from >= q.len() || to >= q.len() || from == to {
            return false;
        }
        let item = q.remove(from);
        q.insert(to, item);
        let cur = self.current_index.load(Ordering::Relaxed);
        let cur_u = cur as usize;
        if cur >= 0 {
            if cur_u == from {
                self.current_index.store(to as i64, Ordering::Release);
            } else if from < cur_u && to >= cur_u {
                self.current_index.store(cur - 1, Ordering::Release);
            } else if from > cur_u && to <= cur_u {
                self.current_index.store(cur + 1, Ordering::Release);
            }
        }
        true
    }

    pub fn clear_items(&mut self, keep_current: bool) {
        let mut q = self.queue.write().unwrap();
        let cur = self.current_index.load(Ordering::Relaxed);
        if keep_current && cur >= 0 && (cur as usize) < q.len() {
            let current_item = q[cur as usize].clone();
            q.clear();
            q.push(current_item);
            self.current_index.store(0, Ordering::Release);
        } else {
            q.clear();
            self.current_index.store(-1, Ordering::Release);
            self.phase.store(ENGINE_PHASE_IDLE, Ordering::Release);
            self.deck_a.stop();
            self.deck_b.stop();
        }
    }

    pub fn set_spatial_enabled(&mut self, enabled: bool) {
        self.deck_a.set_spatial_enabled(enabled);
        self.deck_b.set_spatial_enabled(enabled);
    }

    pub fn set_spatial_listener(&mut self, listener: crate::dsp::spatial::SpatialListener) {
        self.deck_a.set_spatial_listener(listener);
        self.deck_b.set_spatial_listener(listener);
    }

    pub fn set_spatial_emitter(&mut self, emitter: crate::dsp::spatial::SpatialEmitter) {
        self.deck_a.set_spatial_emitter(emitter);
        self.deck_b.set_spatial_emitter(emitter);
    }

    pub fn set_spatial_doppler_factor(&mut self, factor: f32) {
        self.deck_a.set_spatial_doppler_factor(factor);
        self.deck_b.set_spatial_doppler_factor(factor);
    }

    pub fn set_spatial_speed_of_sound(&mut self, speed: f32) {
        self.deck_a.set_spatial_speed_of_sound(speed);
        self.deck_b.set_spatial_speed_of_sound(speed);
    }

    pub fn start_recording(&self, path: &str, format: WavFormat) -> Result<(), String> {
        let mut rec = self.live_recorder.write().unwrap();
        rec.set_format(format);
        rec.start_shared(path, self.record_consumer.clone())?;
        self.is_recording.store(true, Ordering::Release);
        Ok(())
    }

    pub fn stop_recording(&self) -> Result<u64, String> {
        self.is_recording.store(false, Ordering::Release);
        let mut rec = self.live_recorder.write().unwrap();
        rec.stop()
    }

    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::Acquire)
    }

    pub fn offline_bounce(
        &self,
        path: &str,
        format: WavFormat,
        duration_ms: i64,
    ) -> Result<u64, String> {
        let sr = unsafe { (*self.renderer_ptr).sample_rate };
        let ch = unsafe { (*self.renderer_ptr).channels };
        let total_frames = ((duration_ms as f64 * 0.001) * sr as f64).round() as usize;
        let total_samples = total_frames * ch;
        let mut samples = vec![0.0f32; total_samples];

        unsafe {
            (*self.renderer_ptr).render_pcm(samples.as_mut_ptr(), total_frames);
        }

        offline_bounce_to_wav(path, &samples, sr, ch, format)
    }

    pub fn enable_microphone(
        &self,
        capture_device_id: Option<String>,
        auto_ducking: bool,
        ducking_db: f32,
        threshold_db: f32,
    ) -> Result<(), String> {
        let dev_id_c = capture_device_id.map(|s| std::ffi::CString::new(s).unwrap_or_default());
        let dev_id_ptr = dev_id_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let sr = unsafe { (*self.renderer_ptr).sample_rate };
        let (node, consumer) = DeviceCaptureNode::new(sr, 1, 512, dev_id_ptr)
            .map_err(|e| format!("Failed to create capture device: error {}", e))?;

        let _ = node.start();

        if let Ok(mut guard) = self.mic_consumer.lock() {
            *guard = Some(consumer);
        }

        unsafe {
            (*self.renderer_ptr).ducker.set_params(
                auto_ducking,
                ducking_db,
                threshold_db,
                30.0,
                250.0,
                400.0,
            );
        }

        self.mic_enabled.store(true, Ordering::Release);
        let mut cap_lock = self.capture_node.write().unwrap();
        *cap_lock = Some(node);
        Ok(())
    }

    pub fn disable_microphone(&self) {
        self.mic_enabled.store(false, Ordering::Release);
        if let Ok(mut guard) = self.mic_consumer.lock() {
            *guard = None;
        }
        let mut cap_lock = self.capture_node.write().unwrap();
        if let Some(node) = cap_lock.take() {
            node.stop();
        }
    }

    pub fn set_mic_volume(&self, volume: f32) {
        self.mic_volume.store(volume.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
    }

    pub fn configure_cue_output(
        &mut self,
        cue_device_id: Option<String>,
        volume: f32,
        mode: i32,
    ) -> Result<(), String> {
        let dev_id_c = cue_device_id.map(|s| std::ffi::CString::new(s).unwrap_or_default());
        let dev_id_ptr = dev_id_c.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let sr = unsafe { (*self.renderer_ptr).sample_rate };
        let ch = unsafe { (*self.renderer_ptr).channels } as u32;

        if self.cue_device_ctx.is_null() {
            let mut dev_res = 0;
            let ctx = unsafe {
                map_device_create(
                    sr,
                    ch,
                    1024,
                    dev_id_ptr,
                    self.cue_renderer_ptr as *mut c_void,
                    &mut dev_res,
                )
            };
            if ctx.is_null() || dev_res != 0 {
                return Err(format!("Failed to create cue audio device: error {}", dev_res));
            }
            let start_res = unsafe { map_device_start(ctx) };
            if start_res != 0 {
                unsafe { map_device_destroy(ctx); }
                return Err(format!("Failed to start cue device: error {}", start_res));
            }
            self.cue_device_ctx = ctx;
        } else if let Some(ref id_c) = dev_id_c {
            unsafe {
                map_device_set_device(self.cue_device_ctx, id_c.as_ptr());
            }
        }

        self.cue_volume.store(volume.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
        self.cue_mode.store(mode.clamp(0, 2), Ordering::Relaxed);
        self.cue_enabled.store(true, Ordering::Release);
        Ok(())
    }

    pub fn set_cue_volume(&self, volume: f32) {
        self.cue_volume.store(volume.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
    }

    pub fn set_cue_mode(&self, mode: i32) {
        self.cue_mode.store(mode.clamp(0, 2), Ordering::Relaxed);
    }

    pub fn disable_cue_output(&self) {
        self.cue_enabled.store(false, Ordering::Release);
    }
}
