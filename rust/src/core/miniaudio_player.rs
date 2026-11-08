//! Master Miniaudio Player Core Orchestrator (`MiniaudioPlayer`).
//!
//! Coordinates the modular domain blocks:
//! 1. `MusicManager`: Streaming dual decks & crossfading.
//! 2. `DspProcessor`: Reusable vectorized DSP effect chain.
//! 3. `EffectsManager`: 64-voice RAM effects with In-Place Buffer Reuse.
//! 4. `InputManager`: Microphone capture & Auto-Ducking dynamics sidechain.
//! 5. `SimdMixer`: AVX2/NEON FMA vector summing.
//! 6. `OutputManager`: Multi-destination output matrix (Master, CUE, WAV, FFT).

use std::sync::{Arc, Condvar, Mutex};

use crate::core::dsp_processor::DspProcessor;
use crate::core::effects_manager::EffectsManager;
use crate::core::input_manager::InputManager;
use crate::core::music_manager::MusicManager;
use crate::core::output_manager::OutputManager;
use crate::core::simd_mixer::SimdMixer;
use crate::dsp::limiter::SoftLimiter;

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

    // Real-Time Preallocated Scratch Buffers (O(1) L1 Cache)
    pub scratch_music: Vec<f32>,
    pub scratch_voice: Vec<f32>,
    pub super_flow: Vec<f32>,

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
        self.music_manager.dispose();
        self.output_manager.dispose();
    }

    pub fn new(
        sample_rate: u32,
        channels: u32,
        period_size: u32,
        max_voices: usize,
        max_ram_bytes: Option<usize>,
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
        let output_manager = OutputManager::new(sr, ch, device_trigger);

        let max_samples = period as usize * ch * 2;

        Ok(Box::new(Self {
            music_manager,
            music_dsp,
            effects_manager,
            isolate_dsp,
            input_manager,
            simd_mixer,
            master_limiter,
            output_manager,
            scratch_music: vec![0.0; max_samples],
            scratch_voice: vec![0.0; max_samples],
            super_flow: vec![0.0; max_samples],
            sample_rate: sr,
            channels: ch,
            period_size: period,
        }))
    }

    /// Renders one period of PCM frames across all active decks, effects, and microphone DSP,
    /// then dispatches symmetrically to all active outputs, disk recording, and visualizer.
    pub fn render_pcm(&mut self, frame_count: usize) {
        let sample_count = frame_count * self.channels;

        if self.scratch_music.len() < sample_count {
            self.scratch_music.resize(sample_count, 0.0);
            self.scratch_voice.resize(sample_count, 0.0);
            self.super_flow.resize(sample_count, 0.0);
        }

        self.super_flow[..sample_count].fill(0.0);

        // 1. Render fused music from decks into scratch_music
        self.music_manager.render(frame_count, &mut self.scratch_music);

        // 2. Render RAM effects with In-Place Buffer Reuse
        self.effects_manager.render_with_reuse(
            &mut self.scratch_music,
            &mut self.super_flow,
            frame_count,
        );

        // 3. Process isolated SFX voices through their own DSP chain (if any)
        let work_buf = self.effects_manager.work_buffer(sample_count);
        self.isolate_dsp.process(work_buf);
        self.simd_mixer.accumulate(&mut self.super_flow, work_buf);

        // 4. Process music DSP (ReplayGain, SkipSilence, Sonic, EQ, Reverb)
        self.music_dsp.process(&mut self.scratch_music[..sample_count]);

        // 5. Microphone capture, RMS level measurement, and Auto-Ducking
        self.input_manager.process(
            &mut self.scratch_music[..sample_count],
            &mut self.scratch_voice[..sample_count],
        );

        // 6. Accumulate processed music and voice monitoring into super_flow
        self.simd_mixer.accumulate(&mut self.super_flow, &self.scratch_music[..sample_count]);
        self.simd_mixer.accumulate(&mut self.super_flow, &self.scratch_voice[..sample_count]);

        // 7. Master True-Peak Brickwall Limiter & Soft-Knee Saturation Headroom
        self.master_limiter.process_frames(&mut self.super_flow[..sample_count]);

        // 8. Symmetrical Output Dispatch to all active sinks
        self.output_manager.dispatch(
            &self.super_flow[..sample_count],
            &self.scratch_music[..sample_count],
            self.music_manager.active_deck_buffer(),
            self.music_manager.standby_buffer(),
            frame_count,
        );
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
