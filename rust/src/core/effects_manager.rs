//! RAM Sound Effects Domain Manager (`EffectsManager`).
//!
//! Encapsulates 64 polyphonic RAM voices (Arc<[f32]>), 3D spatial evaluation,
//! Doppler cinemática, pitch/volume jitter, LRU eviction with pinned protection,
//! and In-Place Buffer Reuse routing.

use std::sync::{Arc, Mutex};

use crate::core::voice_pool::{DspRouting, EffectConfig, SoundBuffer, VoicePool};
use crate::dsp::spatial::{SpatialEmitter, SpatialListener};

pub struct EffectsManager {
    pub pool: Arc<Mutex<VoicePool>>,
    pub effects_work_buffer: Vec<f32>,
    pub sample_rate: u32,
    pub channels: usize,
}

impl EffectsManager {
    pub fn new(max_voices: usize, max_ram_bytes: usize, sample_rate: u32, channels: usize) -> Self {
        let pool = Arc::new(Mutex::new(VoicePool::new(
            max_voices,
            max_ram_bytes,
            sample_rate,
            channels,
        )));

        Self {
            pool,
            effects_work_buffer: vec![0.0; 2048 * channels],
            sample_rate,
            channels,
        }
    }

    // =========================================================================
    // Direct Effects Commands
    // =========================================================================

    #[inline]
    pub fn load_effect(&self, id: String, buffer: SoundBuffer, max_polyphony: usize, pinned: bool) -> Result<(), String> {
        self.pool.lock().unwrap().load_effect(id, buffer, max_polyphony, pinned)
    }

    #[inline]
    pub fn unload_effect(&self, id: &str) -> bool {
        self.pool.lock().unwrap().unload_effect(id)
    }

    #[inline]
    pub fn play_effect(&self, id: &str, routing: DspRouting, config: EffectConfig) -> Result<u32, String> {
        self.pool.lock().unwrap().play_effect(id, routing, config)
    }

    #[inline]
    pub fn stop_effect(&self, voice_id: u32, fade_out_samples: usize) {
        self.pool.lock().unwrap().stop_voice(voice_id, fade_out_samples);
    }

    #[inline]
    pub fn stop_all_effects(&self, fade_out_samples: usize) {
        self.pool.lock().unwrap().stop_all(fade_out_samples);
    }

    #[inline]
    pub fn set_voice_volume(&self, voice_id: u32, volume: f32) {
        self.pool.lock().unwrap().set_voice_volume(voice_id, volume);
    }

    #[inline]
    pub fn set_voice_pitch(&self, voice_id: u32, pitch: f32) {
        self.pool.lock().unwrap().set_voice_pitch(voice_id, pitch);
    }

    #[inline]
    pub fn set_voice_balance(&self, voice_id: u32, balance: f32) {
        self.pool.lock().unwrap().set_voice_balance(voice_id, balance);
    }

    #[inline]
    pub fn set_voice_emitter(&self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        self.pool.lock().unwrap().set_voice_emitter(voice_id, emitter);
    }

    #[inline]
    pub fn set_listener(&self, listener: SpatialListener) {
        self.pool.lock().unwrap().set_listener(listener);
    }

    #[inline]
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        self.pool.lock().unwrap().set_doppler_parameters(factor, speed_of_sound);
    }

    // =========================================================================
    // In-Place Buffer Reuse Audio Rendering
    // =========================================================================

    /// Renders active polyphonic voices using In-Place Buffer Reuse:
    /// - `music_buffer`: Receives voices with `DspRouting::Inherit` mixed directly in-place.
    /// - `super_flow`: Receives voices with `DspRouting::Bypass` mixed directly without DSP.
    /// - `effects_work_buffer`: Receives voices with `DspRouting::Isolate` for isolated DSP processing.
    pub fn render_with_reuse(
        &mut self,
        music_buffer: &mut [f32],
        super_flow: &mut [f32],
        frame_count: usize,
    ) {
        let sample_count = frame_count * self.channels;
        if self.effects_work_buffer.len() < sample_count {
            self.effects_work_buffer.resize(sample_count, 0.0);
        }
        self.effects_work_buffer[..sample_count].fill(0.0);

        if let Ok(mut pool) = self.pool.try_lock() {
            // pool.render takes: inherit_buf, isolate_buf, bypass_buf, frame_count
            pool.render(
                &mut music_buffer[..sample_count],
                &mut self.effects_work_buffer[..sample_count],
                &mut super_flow[..sample_count],
                frame_count,
            );
        }
    }

    #[inline]
    pub fn work_buffer(&mut self, sample_count: usize) -> &mut [f32] {
        &mut self.effects_work_buffer[..sample_count]
    }

    // =========================================================================
    // State Accessors
    // =========================================================================

    #[inline]
    pub fn active_voices_count(&self) -> u32 {
        if let Ok(pool) = self.pool.try_lock() {
            pool.active_voices_count() as u32
        } else {
            0
        }
    }

    #[inline]
    pub fn allocated_ram_bytes(&self) -> usize {
        if let Ok(pool) = self.pool.try_lock() {
            pool.allocated_ram_bytes
        } else {
            0
        }
    }

    #[inline]
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        if let Ok(pool) = self.pool.try_lock() {
            pool.registered_effects.iter().map(|e| e.id.clone()).collect()
        } else {
            Vec::new()
        }
    }
}
