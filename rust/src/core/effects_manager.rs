//! RAM Sound Effects Domain Manager (`EffectsManager`).
//!
//! Encapsulates 64 polyphonic RAM voices (Arc<[f32]>), 3D spatial evaluation,
//! Doppler kinematics, pitch/volume jitter, LRU eviction with pinned protection,
//! and In-Place Buffer Reuse routing.

use std::sync::{Arc, Mutex};

use crate::core::voice_pool::{
    decode_effect_source, DspRouting, EffectCatalogItem, EffectConfig, VoicePool,
};
use crate::dsp::spatial::{SpatialEmitter, SpatialListener};

/// Domain manager for polyphonic RAM sound effects, 3D spatial audio, and voice pooling.
pub struct EffectsManager {
    /// Mutex-wrapped voice pool holding preloaded audio buffers and active voices.
    pub pool: Arc<Mutex<VoicePool>>,
    /// Preallocated scratch buffer for rendering isolated DSP effect voices.
    pub effects_work_buffer: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: usize,
}

impl EffectsManager {
    /// Creates a new `EffectsManager` with voice capacity and optional memory budget limits.
    pub fn new(
        max_voices: usize,
        max_ram_bytes: Option<usize>,
        sample_rate: u32,
        channels: usize,
    ) -> Self {
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

    /// Declaratively registers the sound effect catalog into the voice pool.
    #[inline]
    pub fn set_effects(&self, effects: Vec<EffectCatalogItem>) -> Result<(), String> {
        self.pool.lock().unwrap().set_effects(effects)
    }

    /// Triggers playback of a registered sound effect by ID with specified routing and parameters.
    #[inline]
    pub fn play_effect(
        &self,
        id: &str,
        routing: DspRouting,
        config: EffectConfig,
    ) -> Result<(u32, bool), String> {
        let need_decode = {
            let pool = self.pool.lock().unwrap();
            let effect_idx = match pool.id_to_index.get(id) {
                Some(&idx) => idx,
                None => {
                    return Err(format!(
                        "AudioEffectNotFound: Effect '{}' not registered in catalog",
                        id
                    ));
                }
            };
            if pool.registered_effects[effect_idx].buffer.is_none() {
                Some((effect_idx, pool.registered_effects[effect_idx].source.clone()))
            } else {
                None
            }
        };

        let mut ram_changed = false;
        if let Some((effect_idx, src)) = need_decode {
            let decoded = decode_effect_source(id, &src)?;
            let mut pool = self.pool.lock().unwrap();
            if effect_idx < pool.registered_effects.len()
                && pool.registered_effects[effect_idx].id == id
            {
                pool.ensure_effect_loaded(effect_idx, decoded);
                ram_changed = true;
            }
        }

        let mut pool = self.pool.lock().unwrap();
        let effect_idx = *pool
            .id_to_index
            .get(id)
            .ok_or_else(|| format!("AudioEffectNotFound: Effect '{}' not registered", id))?;
        let voice_id = pool.play_loaded_effect(effect_idx, routing, config)?;
        Ok((voice_id, ram_changed))
    }

    /// Re-evaluates LRU cache eviction when an active voice completes.
    #[inline]
    pub fn on_voice_completed(&self) -> bool {
        self.pool.lock().unwrap().on_voice_completed()
    }

    /// Stops playback of an active voice slot.
    #[inline]
    pub fn stop_effect(&self, voice_id: u32, fade_out_samples: usize) {
        self.pool.lock().unwrap().stop_voice(voice_id, fade_out_samples);
    }

    /// Stops all currently active sound effect voices.
    #[inline]
    pub fn stop_all_effects(&self, fade_out_samples: usize) {
        self.pool.lock().unwrap().stop_all(fade_out_samples);
    }

    /// Sets playback volume of an active voice.
    #[inline]
    pub fn set_voice_volume(&self, voice_id: u32, volume: f32) {
        self.pool.lock().unwrap().set_voice_volume(voice_id, volume);
    }

    /// Sets playback pitch multiplier of an active voice.
    #[inline]
    pub fn set_voice_pitch(&self, voice_id: u32, pitch: f32) {
        self.pool.lock().unwrap().set_voice_pitch(voice_id, pitch);
    }

    /// Sets stereo pan balance of an active voice.
    #[inline]
    pub fn set_voice_balance(&self, voice_id: u32, balance: f32) {
        self.pool.lock().unwrap().set_voice_balance(voice_id, balance);
    }

    /// Sets 3D spatial emitter parameters of an active voice.
    #[inline]
    pub fn set_voice_emitter(&self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        self.pool.lock().unwrap().set_voice_emitter(voice_id, emitter);
    }

    /// Sets 3D spatial listener position and orientation for all sound effects.
    #[inline]
    pub fn set_listener(&self, listener: SpatialListener) {
        self.pool.lock().unwrap().set_listener(listener);
    }

    /// Updates Doppler effect physics parameters.
    #[inline]
    pub fn set_doppler_parameters(&self, factor: f32, speed_of_sound: f32) {
        self.pool.lock().unwrap().set_doppler_parameters(factor, speed_of_sound);
    }

    // =========================================================================
    // In-Place Buffer Reuse Audio Rendering
    // =========================================================================

    /// Renders active polyphonic voices using In-Place Buffer Reuse:
    /// - `inherit_buffer`: Receives voices with `DspRouting::Inherit`.
    /// - `super_flow`: Receives voices with `DspRouting::Bypass` mixed directly without DSP.
    /// - `effects_work_buffer`: Receives voices with `DspRouting::Isolate` for isolated DSP processing.
    pub fn render_with_reuse(
        &mut self,
        inherit_buffer: &mut [f32],
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
                &mut inherit_buffer[..sample_count],
                &mut self.effects_work_buffer[..sample_count],
                &mut super_flow[..sample_count],
                frame_count,
            );
        }
    }

    /// Returns a mutable slice to the isolated scratch work buffer.
    #[inline]
    pub fn work_buffer(&mut self, sample_count: usize) -> &mut [f32] {
        &mut self.effects_work_buffer[..sample_count]
    }

    // =========================================================================
    // State Accessors
    // =========================================================================

    /// Returns the number of currently active sound effect voices.
    #[inline]
    pub fn active_voices_count(&self) -> u32 {
        if let Ok(pool) = self.pool.try_lock() {
            pool.active_voices_count() as u32
        } else {
            0
        }
    }

    /// Returns the total bytes of decoded sound effect PCM currently allocated in RAM.
    #[inline]
    pub fn allocated_ram_bytes(&self) -> usize {
        if let Ok(pool) = self.pool.try_lock() {
            pool.allocated_ram_bytes
        } else {
            0
        }
    }

    /// Returns the identifiers of all sound effects currently resident in RAM.
    #[inline]
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        if let Ok(pool) = self.pool.try_lock() {
            pool.loaded_effect_ids()
        } else {
            Vec::new()
        }
    }
}
