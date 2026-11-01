//! Real-time decoupled dual-deck engine coordinator with lock-free crossfading,
//! unified telemetry, and composite visualizer processing.

use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::thread::JoinHandle;

use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_set_device,
    map_device_start, map_device_stop, MapDeviceContext, MAP_SUCCESS,
};
use crate::core::player::PlayerCoordinator;
use crate::core::renderer::{AudioRenderer, PcmRendererHeader};
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

        // Compute composite FFT visualizer data directly on the mixed output buffer
        if self.visualizer_enabled.load(Ordering::Relaxed) {
            let out_slice = unsafe { std::slice::from_raw_parts(output_frames, total_samples) };
            self.visualizer.process_frames(out_slice);
            let vis = self.visualizer.data();
            self.visualizer_seqlock.write(|v| *v = vis);
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

    pub auto_crossfade_duration_ms: Arc<AtomicU64>,
    pub manual_crossfade_duration_ms: Arc<AtomicU64>,
    pub crossfade_curve: Arc<AtomicI32>,

    pub visualizer_seqlock: Arc<CachePaddedSeqlock<VisualizerData>>,
    pub visualizer_enabled: Arc<AtomicBool>,

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

        let queue = Arc::new(RwLock::new(Vec::new()));
        let current_index = Arc::new(AtomicI64::new(0));
        let loop_mode = Arc::new(AtomicI32::new(0));
        let shuffle_enabled = Arc::new(AtomicBool::new(false));

        let auto_crossfade_duration_ms = Arc::new(AtomicU64::new(5000));
        let manual_crossfade_duration_ms = Arc::new(AtomicU64::new(100));
        let crossfade_curve = Arc::new(AtomicI32::new(0));

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
            auto_crossfade_duration_ms,
            manual_crossfade_duration_ms,
            crossfade_curve,
            visualizer_seqlock,
            visualizer_enabled,
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
}
