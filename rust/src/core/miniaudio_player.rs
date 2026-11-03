//! Master Miniaudio Player Core Orchestrator (`MiniaudioPlayer`).
//!
//! Coordinates the modular domain blocks:
//! 1. `MusicManager`: Streaming dual decks & crossfading.
//! 2. `DspProcessor`: Reusable vectorized DSP effect chain.
//! 3. `EffectsManager`: 64-voice RAM effects with In-Place Buffer Reuse.
//! 4. `InputManager`: Microphone capture & Auto-Ducking dynamics sidechain.
//! 5. `SimdMixer`: AVX2/NEON FMA vector summing.
//! 6. `OutputManager`: Multi-destination output matrix (Master, CUE, WAV, FFT).

use std::ffi::c_void;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex};

use crate::bridge::ffi::{
    map_device_create, map_device_destroy, map_device_start, map_device_stop, MapDeviceContext,
};
use crate::core::dsp_processor::DspProcessor;
use crate::core::effects_manager::EffectsManager;
use crate::core::input_manager::InputManager;
use crate::core::music_manager::MusicManager;
use crate::core::output_manager::OutputManager;
use crate::core::renderer::PcmRendererHeader;
use crate::core::simd_mixer::SimdMixer;
use crate::dsp::limiter::SoftLimiter;

#[repr(C)]
pub struct MiniaudioPlayerRenderer {
    pub header: PcmRendererHeader,
    pub player_ptr: *mut MiniaudioPlayer,

    // Real-Time Preallocated Scratch Buffers (O(1) L1 Cache)
    pub scratch_music: Vec<f32>,
    pub scratch_voice: Vec<f32>,
    pub super_flow: Vec<f32>,
    pub sample_rate: u32,
    pub channels: usize,
    pub device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
}

unsafe impl Send for MiniaudioPlayerRenderer {}

pub unsafe extern "C" fn miniaudio_player_render_trampoline(
    ptr: *mut c_void,
    output: *mut f32,
    count: usize,
) {
    let r = &mut *(ptr as *mut MiniaudioPlayerRenderer);
    r.render_pcm(output, count);
}

pub unsafe extern "C" fn miniaudio_player_notif_trampoline(ptr: *mut c_void, notif: i32) {
    if ptr.is_null() {
        return;
    }
    let r = &mut *(ptr as *mut MiniaudioPlayerRenderer);
    // Notification 1: stopped, Notification 2: rerouted
    if notif == 1 || notif == 2 {
        if !r.player_ptr.is_null() {
            let ply = &mut *r.player_ptr;
            if ply.output_manager.matrix.pause_on_device_change.load(Ordering::Relaxed) {
                let deck = ply.music_manager.active_deck_ref();
                if deck.state.load(Ordering::Relaxed) == crate::core::dual_source::STATE_PLAYING {
                    let _ = ply.music_manager.pause();
                    ply.music_manager.inner.phase.store(crate::core::dual_source::ENGINE_PHASE_PAUSED, Ordering::Release);
                }
            }
        }
        if let Some(ref trig) = r.device_trigger {
            let (lock, cvar) = &**trig;
            if let Ok(mut flag) = lock.lock() {
                *flag = true;
                cvar.notify_one();
            }
        }
    }
}

impl MiniaudioPlayerRenderer {
    pub fn render_pcm(&mut self, output: *mut f32, frame_count: usize) {
        if self.player_ptr.is_null() {
            return;
        }
        let ply = unsafe { &mut *self.player_ptr };
        let sample_count = frame_count * self.channels;

        if self.scratch_music.len() < sample_count {
            self.scratch_music.resize(sample_count, 0.0);
            self.scratch_voice.resize(sample_count, 0.0);
            self.super_flow.resize(sample_count, 0.0);
        }

        self.super_flow[..sample_count].fill(0.0);

        // 1. Render fused music from decks into scratch_music
        ply.music_manager.render(frame_count, &mut self.scratch_music);

        // 2. Render RAM effects with In-Place Buffer Reuse:
        //    - DspRouting::Inherit voices mix directly into scratch_music.
        //    - DspRouting::Bypass voices mix directly into super_flow.
        //    - DspRouting::Isolate voices mix into effects_manager work_buffer.
        ply.effects_manager.render_with_reuse(
            &mut self.scratch_music,
            &mut self.super_flow,
            frame_count,
        );

        // 3. Process isolated SFX voices through their own DSP chain (if any)
        let work_buf = ply.effects_manager.work_buffer(sample_count);
        ply.isolate_dsp.process(work_buf);
        ply.simd_mixer.accumulate(&mut self.super_flow, work_buf);

        // 4. Process music DSP (ReplayGain, SkipSilence, Sonic, EQ, Reverb)
        //    All DspRouting::Inherit voices are processed here together in ONE single pass O(1)!
        ply.music_dsp.process(&mut self.scratch_music[..sample_count]);

        // 5. Microphone capture, RMS level measurement, and Auto-Ducking
        ply.input_manager.process(
            &mut self.scratch_music[..sample_count],
            &mut self.scratch_voice[..sample_count],
        );

        // 6. Accumulate processed music and voice monitoring into super_flow
        ply.simd_mixer.accumulate(&mut self.super_flow, &self.scratch_music[..sample_count]);
        ply.simd_mixer.accumulate(&mut self.super_flow, &self.scratch_voice[..sample_count]);

        // 7. Master True-Peak Brickwall Limiter & Soft-Knee Saturation Headroom
        ply.master_limiter.process_frames(&mut self.super_flow[..sample_count]);

        // 8. Output Dispatch to all active sinks (Master speakers, CUE DJ, WAV recorder, FFT visualizer)
        ply.output_manager.dispatch(
            &self.super_flow[..sample_count],
            ply.music_manager.standby_buffer(),
            output,
            frame_count,
        );
    }
}

/// Master Miniaudio Player Coordinator.
pub struct MiniaudioPlayer {
    pub music_manager: MusicManager,
    pub music_dsp: DspProcessor,
    pub effects_manager: EffectsManager,
    pub isolate_dsp: DspProcessor,
    pub input_manager: InputManager,
    pub simd_mixer: SimdMixer,
    pub master_limiter: SoftLimiter,
    pub output_manager: OutputManager,

    pub device_ctx: *mut MapDeviceContext,
    pub renderer_ptr: *mut MiniaudioPlayerRenderer,
    pub sample_rate: u32,
    pub channels: usize,
    pub period_size: u32,
}

unsafe impl Send for MiniaudioPlayer {}
unsafe impl Sync for MiniaudioPlayer {}

impl Drop for MiniaudioPlayer {
    fn drop(&mut self) {
        self.dispose();
    }
}

impl MiniaudioPlayer {
    pub fn dispose(&mut self) {
        if !self.device_ctx.is_null() {
            unsafe {
                map_device_stop(self.device_ctx);
                map_device_destroy(self.device_ctx);
            }
            self.device_ctx = std::ptr::null_mut();
        }

        if !self.renderer_ptr.is_null() {
            unsafe {
                (*self.renderer_ptr).player_ptr = std::ptr::null_mut();
                drop(Box::from_raw(self.renderer_ptr));
            }
            self.renderer_ptr = std::ptr::null_mut();
        }

        self.music_manager.dispose();
        self.output_manager.dispose();
    }

    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        playback_device_id: Option<String>,
        max_voices: usize,
        max_ram_bytes: usize,
        device_trigger: Option<Arc<(Mutex<bool>, Condvar)>>,
    ) -> Result<Box<Self>, String> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels as usize } else { 2 };
        let period = if period_size > 0 { period_size } else { 1024 };

        let music_manager = MusicManager::new(sr, ch as u32, period)?;
        let music_dsp = DspProcessor::new(sr, ch);
        let effects_manager = EffectsManager::new(max_voices, max_ram_bytes, sr, ch);
        let isolate_dsp = DspProcessor::new(sr, ch);
        let input_manager = InputManager::new(sr, ch);
        let simd_mixer = SimdMixer::new();
        let master_limiter = SoftLimiter::new(true);
        let output_manager = OutputManager::new(sr, ch);

        let max_samples = period as usize * ch * 2;

        let mut player = Box::new(Self {
            music_manager,
            music_dsp,
            effects_manager,
            isolate_dsp,
            input_manager,
            simd_mixer,
            master_limiter,
            output_manager,
            device_ctx: std::ptr::null_mut(),
            renderer_ptr: std::ptr::null_mut(),
            sample_rate: sr,
            channels: ch,
            period_size: period,
        });

        let player_raw = &mut *player as *mut MiniaudioPlayer;

        let renderer = Box::new(MiniaudioPlayerRenderer {
            header: PcmRendererHeader {
                render_fn: miniaudio_player_render_trampoline,
                notif_fn: miniaudio_player_notif_trampoline,
            },
            player_ptr: player_raw,
            scratch_music: vec![0.0; max_samples],
            scratch_voice: vec![0.0; max_samples],
            super_flow: vec![0.0; max_samples],
            sample_rate: sr,
            channels: ch,
            device_trigger,
        });

        let renderer_ptr = Box::into_raw(renderer);
        player.renderer_ptr = renderer_ptr;

        let c_dev = match playback_device_id {
            Some(s) if !s.is_empty() => Some(std::ffi::CString::new(s).map_err(|e| e.to_string())?),
            _ => None,
        };
        let dev_ptr = c_dev.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null());

        let mut dev_res = 0;
        let device_ctx = unsafe {
            map_device_create(
                sr,
                ch as u32,
                period,
                dev_ptr,
                renderer_ptr as *mut c_void,
                &mut dev_res,
            )
        };

        if device_ctx.is_null() || dev_res != 0 {
            unsafe {
                drop(Box::from_raw(renderer_ptr));
            }
            return Err(format!("Hardware device initialization failed: error {}", dev_res));
        }

        player.device_ctx = device_ctx;

        unsafe {
            map_device_start(device_ctx);
        }

        Ok(player)
    }

    // =========================================================================
    // Cross-Cutting Commands
    // =========================================================================

    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.music_dsp.set_volume(volume);
    }

    #[inline]
    pub fn stop_all(&mut self, fade_out_samples: usize) {
        self.music_manager.stop();
        self.effects_manager.stop_all_effects(fade_out_samples);
    }
}
