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
    /// Domain manager for dual-deck streaming, queues, and crossfading.
    pub music_manager: MusicManager,
    /// Vectorized DSP processing chain for music playback.
    pub music_dsp: DspProcessor,
    /// Inherited DSP processing chain for sound effects (shares music Reverb, EQ, etc.).
    pub inherit_dsp: DspProcessor,
    /// Domain manager for 64-voice polyphonic RAM sound effects.
    pub effects_manager: EffectsManager,
    /// Isolated DSP chain for dedicated sound effects.
    pub isolate_dsp: DspProcessor,
    /// Domain manager for microphone capture and auto-ducking dynamics.
    pub input_manager: InputManager,
    /// SIMD vector mixer for fast summing and headroom saturation.
    pub simd_mixer: SimdMixer,
    /// Master True-Peak soft brickwall limiter.
    pub master_limiter: SoftLimiter,
    /// Multi-destination physical output matrix, recording, and visualizer.
    pub output_manager: OutputManager,

    // Real-Time Preallocated Scratch Buffers (O(1) L1 Cache)
    /// Scratch buffer for decoded music frames.
    pub scratch_music: Vec<f32>,
    /// Scratch buffer for captured microphone audio.
    pub scratch_voice: Vec<f32>,
    /// Scratch buffer for polyphonic sound effect voices.
    pub scratch_effects: Vec<f32>,
    /// Master summing bus combining all sound sources.
    pub super_flow: Vec<f32>,

    /// Audio sample rate in Hz.
    pub sample_rate: u32,
    /// Audio channel count.
    pub channels: usize,
    /// Hardware callback period size in frames.
    pub period_size: u32,

    /// Effective ReplayGain telemetry cached for the active foreground track `(gain_db, peak)`.
    pub active_replay_gain: (f32, f32),
}

unsafe impl Send for MiniaudioPlayer {}
unsafe impl Sync for MiniaudioPlayer {}

impl Drop for MiniaudioPlayer {
    fn drop(&mut self) {
        self.dispose();
    }
}

impl MiniaudioPlayer {
    /// Disposes underlying music and output managers, releasing hardware resources.
    pub fn dispose(&mut self) {
        self.music_manager.dispose();
        self.output_manager.dispose();
    }

    /// Creates and initializes the master `MiniaudioPlayer` engine with all modular domains.
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
        let inherit_dsp = DspProcessor::new(sr, ch);
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
            inherit_dsp,
            effects_manager,
            isolate_dsp,
            input_manager,
            simd_mixer,
            master_limiter,
            output_manager,
            scratch_music: vec![0.0; max_samples],
            scratch_voice: vec![0.0; max_samples],
            scratch_effects: vec![0.0; max_samples],
            super_flow: vec![0.0; max_samples],
            sample_rate: sr,
            channels: ch,
            period_size: period,
            active_replay_gain: (0.0, 1.0),
        }))
    }

    /// Sets the global ReplayGain operating mode (`0 = Disabled`, `1 = Track`, `2 = Forced`)
    /// and recalculates per-deck ReplayGain normalization cleanly.
    pub fn set_replay_gain_mode(&mut self, mode: u32) -> (f32, f32) {
        self.music_manager.inner.replay_gain_mode = mode;
        self.recalculate_and_apply_replay_gain()
    }

    /// Sets the fallback or forced ReplayGain adjustment `(gain_db, peak)`
    /// and recalculates per-deck ReplayGain normalization cleanly.
    pub fn set_default_replay_gain(&mut self, gain_db: f32, peak: f32) -> (f32, f32) {
        self.music_manager.inner.default_replay_gain = (gain_db, peak);
        self.recalculate_and_apply_replay_gain()
    }

    /// Recalculates per-deck ReplayGain independently on Deck A and Deck B based on each deck's
    /// assigned track, global mode, and fallback default, while keeping post-mix `music_dsp`
    /// ReplayGain disabled so crossfading tracks never adopt each other's gain or double-scale.
    pub fn recalculate_and_apply_replay_gain(&mut self) -> (f32, f32) {
        self.music_dsp
            .set_replay_gain(crate::dsp::equalizer::ReplayGainConfig::default());
        self.music_manager.inner.refresh_deck_replay_gains();
        let fg = self.music_manager.inner.resolve_foreground_replay_gain();
        let eff = (fg.gain_db, fg.peak);
        self.active_replay_gain = eff;
        eff
    }

    /// Renders one period of PCM frames across all active decks, effects, and microphone DSP,
    /// then dispatches symmetrically to all active outputs, disk recording, and visualizer.
    pub fn render_pcm(&mut self, frame_count: usize) {
        let sample_count = frame_count * self.channels;

        if self.scratch_music.len() < sample_count {
            self.scratch_music.resize(sample_count, 0.0);
            self.scratch_voice.resize(sample_count, 0.0);
            self.scratch_effects.resize(sample_count, 0.0);
            self.super_flow.resize(sample_count, 0.0);
        }

        self.super_flow[..sample_count].fill(0.0);
        self.scratch_effects[..sample_count].fill(0.0);

        // 1. Render fused music from decks into scratch_music (pure music bus)
        self.music_manager.render(frame_count, &mut self.scratch_music);

        // 2. Process pure music DSP (ReplayGain, SkipSilence, Sonic, EQ, Reverb)
        self.music_dsp.process(&mut self.scratch_music[..sample_count]);
        // NOTE: scratch_music is strictly the Pure Music bus:
        // - ZERO sound effect leakage (SFX only in super_flow)
        // - ZERO microphone auto-ducking attenuation (ducking only in super_flow)
        // This clean stream is dispatched to AudioOutputSource::MusicMix ("Music Only").

        // 3. Copy pure music into super_flow (All Mix) where auto-ducking is applied
        self.super_flow[..sample_count].copy_from_slice(&self.scratch_music[..sample_count]);

        // 4. Microphone capture, Auto-Ducking on music, and selective direct monitoring injected into super_flow
        self.input_manager.process(
            &mut self.super_flow[..sample_count],
            &mut self.scratch_voice[..sample_count],
        );

        // 5. Render RAM effects with In-Place Buffer Reuse:
        // Voices with DspRouting::Inherit render into scratch_effects,
        // DspRouting::Bypass render into super_flow,
        // DspRouting::Isolate render into effects_work_buffer.
        self.effects_manager.render_with_reuse(
            &mut self.scratch_effects,
            &mut self.super_flow,
            frame_count,
        );

        // 6. Process isolated SFX voices through their own DSP chain (if any) and accumulate into super_flow
        let work_buf = self.effects_manager.work_buffer(sample_count);
        self.isolate_dsp.process(work_buf);
        if work_buf.iter().any(|&s| s.abs() > 1e-6) {
            self.simd_mixer.accumulate(&mut self.super_flow, work_buf);
        }

        // 7. Process inherited SFX voices through inherit_dsp (sharing music's Reverb, EQ, etc.) and accumulate into super_flow
        self.inherit_dsp.process(&mut self.scratch_effects[..sample_count]);
        if self.scratch_effects[..sample_count].iter().any(|&s| s.abs() > 1e-6) {
            self.simd_mixer.accumulate(&mut self.super_flow, &self.scratch_effects[..sample_count]);
        }

        // 8. Direct microphone monitoring is selectively injected into super_flow by input_manager.process
        // (only for inputs with monitor_direct == true, unattenuated by ducking).
        // scratch_voice remains the pure Voice Only bus (dispatched cleanly to VoiceOnly sinks).

        // 9. Master True-Peak Brickwall Limiter & Soft-Knee Saturation Headroom on super_flow
        self.master_limiter.process_frames(&mut self.super_flow[..sample_count]);

        // 10. Symmetrical Output Dispatch to all active sinks:
        // - all_buffer (All Mix): super_flow (ducked music + all SFX + mic + limiter)
        // - music_mix_buffer (Music Only): scratch_music (pure music, ZERO SFX, ZERO DUCKING)
        // - active_buffer: active deck PCM
        // - standby_buffer: standby deck PCM
        // - voice_buffer (Voice Only): scratch_voice (pure microphone capture, ZERO MUSIC, ZERO SFX)
        self.output_manager.dispatch(
            &self.super_flow[..sample_count],
            &self.scratch_music[..sample_count],
            self.music_manager.active_deck_buffer(),
            self.music_manager.standby_buffer(),
            &self.scratch_voice[..sample_count],
            frame_count,
        );
    }

    // =========================================================================
    // Cross-Cutting Commands
    // =========================================================================

    /// Sets the master music volume level.
    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.music_dsp.set_volume(volume);
    }

    /// Stops music playback and all polyphonic sound effects with optional fadeout.
    #[inline]
    pub fn stop_all(&mut self, fade_out_samples: usize) {
        self.music_manager.stop();
        self.effects_manager.stop_all_effects(fade_out_samples);
    }
}
