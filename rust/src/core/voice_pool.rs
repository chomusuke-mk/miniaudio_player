//! High-performance Polyphonic Voice Pool with SIMD mixing, LRU RAM eviction,
//! pinned buffer protection, 3D Spatial Audio & Doppler, and dynamic DSP routing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

use crate::core::dual_source::{resolve_local_source_path, strip_file_prefix, AudioSourceCore};
use crate::dsp::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor};
pub use crate::dsp::voice_pool::{pseudo_random_jitter, SoundBuffer, VoiceStealingPolicy};

/// Source backing classification used by the multi-factor RAM eviction algorithm.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EffectSourceType {
    /// In-memory bytes (`MemoryAudioSource`): immune to eviction (`SourceWeight = inf`).
    Memory,
    /// Network HTTP/HTTPS URI: high cost to re-fetch (`SourceWeight = 5.0`).
    Network,
    /// Local file path: fast to re-read from disk (`SourceWeight = 1.0`).
    LocalFile,
}

impl EffectSourceType {
    /// Returns the source weight multiplier for the multi-factor retention score formula.
    #[inline]
    pub fn source_weight(self) -> f64 {
        match self {
            EffectSourceType::Memory => f64::INFINITY,
            EffectSourceType::Network => 5.0,
            EffectSourceType::LocalFile => 1.0,
        }
    }
}

/// Declarative sound effect descriptor passed to [`VoicePool::set_effects`].
#[derive(Debug, Clone)]
pub struct EffectCatalogItem {
    /// Unique identifier for the sound effect.
    pub id: String,
    /// Underlying audio source descriptor (memory bytes, local file path, or network URL).
    pub source: AudioSourceCore,
    /// Maximum concurrent voices allowed for this specific effect.
    pub max_polyphony: usize,
    /// Whether this effect is pinned in RAM and exempt from automatic eviction.
    pub pinned: bool,
}

/// Maximum concurrent polyphonic voices rendered by the pool.
pub const MAX_VOICES: usize = 64;

/// DSP routing policies for polyphonic sound effect voices.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspRouting {
    /// Voice is mixed with the music bus and shares the master music DSP chain (default).
    Inherit = 0,
    /// Voice undergoes isolated dedicated DSP processing without affecting music.
    Isolate = 1,
    /// Voice bypasses all DSP processing and sums directly into the master output.
    Bypass = 2,
}

impl From<i32> for DspRouting {
    fn from(val: i32) -> Self {
        match val {
            1 => DspRouting::Isolate,
            2 => DspRouting::Bypass,
            _ => DspRouting::Inherit,
        }
    }
}

/// Dynamic playback parameters applied when triggering a sound effect voice.
#[derive(Debug, Clone)]
pub struct EffectConfig {
    /// Playback volume factor (0.0 to 2.0).
    pub volume: f32,
    /// Stereo panning balance (-1.0 to 1.0).
    pub balance: f32,
    /// Pitch shift multiplier (0.5 to 2.0).
    pub pitch: f32,
    /// Speed rate multiplier (0.5 to 2.0).
    pub rate: f32,
    /// Whether this voice should loop continuously.
    pub looping: bool,
    /// Voice stealing priority (0..255).
    pub priority: u8,
    /// Randomized pitch jitter range to reduce fatigue.
    pub pitch_jitter: f32,
    /// Randomized volume jitter range to reduce fatigue.
    pub volume_jitter: f32,
    /// Optional 3D spatial emitter parameters.
    pub spatial: Option<SpatialEmitter>,
}

impl Default for EffectConfig {
    fn default() -> Self {
        Self {
            volume: 1.0,
            balance: 0.0,
            pitch: 1.0,
            rate: 1.0,
            looping: false,
            priority: 128,
            pitch_jitter: 0.0,
            volume_jitter: 0.0,
            spatial: None,
        }
    }
}

pub struct RegisteredEffect {
    pub id: String,
    pub source: AudioSourceCore,
    pub source_type: EffectSourceType,
    pub buffer: Option<SoundBuffer>,
    pub max_polyphony: usize,
    pub pinned: bool,
    pub byte_size: usize,
    pub trigger_count: u64,
    pub last_used: Instant,
    pub active_voices: usize,
}

impl RegisteredEffect {
    /// Returns whether this effect's decoded PCM buffer can be evicted from RAM.
    ///
    /// Memory-backed effects (`EffectSourceType::Memory`), pinned effects, and effects
    /// with active playing voices are strictly immune to eviction.
    #[inline]
    pub fn is_evictable(&self) -> bool {
        self.buffer.is_some()
            && !self.pinned
            && self.source_type != EffectSourceType::Memory
            && self.active_voices == 0
    }

    /// Computes the multi-factor retention score:
    /// `Score = SourceWeight * (1 + TriggerFrequency) * (1 / (1 + dt_seconds))`
    #[inline]
    pub fn retention_score(&self, now: Instant) -> f64 {
        if self.source_type == EffectSourceType::Memory || self.pinned {
            return f64::INFINITY;
        }
        let weight = self.source_type.source_weight();
        let freq = self.trigger_count as f64;
        let dt_seconds = now.saturating_duration_since(self.last_used).as_secs_f64();
        weight * (1.0 + freq) * (1.0 / (1.0 + dt_seconds))
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Voice {
    pub voice_id: u32,
    pub active: bool,
    pub effect_idx: usize,
    pub cursor_frame: f64,
    pub volume: f32,
    pub pitch: f32,
    pub balance: f32,
    pub priority: u8,
    pub looping: bool,
    pub dsp_routing: DspRouting,
    pub emitter: Option<SpatialEmitter>,
    pub stopping: bool,
    pub fade_samples_remaining: usize,
    pub total_fade_samples: usize,
    pub age_frames: u64,
}

impl Default for Voice {
    fn default() -> Self {
        Self {
            voice_id: 0,
            active: false,
            effect_idx: 0,
            cursor_frame: 0.0,
            volume: 1.0,
            pitch: 1.0,
            balance: 0.0,
            priority: 128,
            looping: false,
            dsp_routing: DspRouting::Inherit,
            emitter: None,
            stopping: false,
            fade_samples_remaining: 0,
            total_fade_samples: 0,
            age_frames: 0,
        }
    }
}

#[inline]
pub fn apply_jitter(base: f32, jitter_amount: f32, seed: u32, salt: u32) -> f32 {
    if jitter_amount <= 0.0 {
        base
    } else {
        let rand_val = pseudo_random_jitter(seed, salt);
        base * (1.0 + rand_val * jitter_amount)
    }
}

/// Decodes an [`AudioSourceCore`] into a PCM [`SoundBuffer`].
pub fn decode_effect_source(id: &str, source: &AudioSourceCore) -> Result<SoundBuffer, String> {
    if let Some(ref bytes) = source.data_bytes {
        if !bytes.is_empty() {
            return SoundBuffer::decode_from_bytes(bytes)
                .map_err(|e| format!("Decoding memory effect '{}' failed: {}", id, e));
        }
    }

    let trimmed = source.source.trim();
    #[cfg(not(target_arch = "wasm32"))]
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        let mut req = ureq::get(trimmed);
        if let Some(ref hdrs) = source.headers {
            for h in hdrs {
                req = req.set(&h.key, &h.value);
            }
        }
        let resp = req
            .call()
            .map_err(|e| format!("Failed to fetch network effect '{}' ({}): {}", id, trimmed, e))?;
        let mut bytes = Vec::new();
        use std::io::Read;
        resp.into_reader()
            .read_to_end(&mut bytes)
            .map_err(|e| format!("Failed to read network effect '{}' bytes: {}", id, e))?;
        return SoundBuffer::decode_from_bytes(&bytes)
            .map_err(|e| format!("Decoding network effect '{}' failed: {}", id, e));
    }

    let stripped = strip_file_prefix(trimmed);
    let path = resolve_local_source_path(&stripped);
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("Failed to read effect file '{}' for '{}': {}", path, id, e))?;
    SoundBuffer::decode_from_bytes(&bytes)
        .map_err(|e| format!("Decoding effect '{}' failed: {}", id, e))
}

pub struct VoicePool {
    pub max_voices: usize,
    pub max_ram_bytes: Option<usize>,
    pub allocated_ram_bytes: usize,
    pub registered_effects: Vec<RegisteredEffect>,
    pub id_to_index: HashMap<String, usize>,
    pub voices: [Voice; MAX_VOICES],
    pub next_voice_id: AtomicU32,
    pub listener: SpatialListener,
    pub speed_of_sound: f32,
    pub doppler_factor: f32,
    pub stealing_policy: VoiceStealingPolicy,
    pub sample_rate: u32,
    pub channels: usize,
    pub completed_voices_producer: rtrb::Producer<u32>,
    pub completed_voices_consumer: rtrb::Consumer<u32>,
}

unsafe impl Send for VoicePool {}
unsafe impl Sync for VoicePool {}

impl VoicePool {
    pub fn new(
        max_voices: usize,
        max_ram_bytes: Option<usize>,
        sample_rate: u32,
        channels: usize,
    ) -> Self {
        let (prod, cons) = rtrb::RingBuffer::new(256);
        Self {
            max_voices: max_voices.clamp(1, MAX_VOICES),
            max_ram_bytes,
            allocated_ram_bytes: 0,
            registered_effects: Vec::new(),
            id_to_index: HashMap::new(),
            voices: [Voice::default(); MAX_VOICES],
            next_voice_id: AtomicU32::new(1),
            listener: SpatialListener::default(),
            speed_of_sound: 343.3,
            doppler_factor: 1.0,
            stealing_policy: VoiceStealingPolicy::LowestPriority,
            sample_rate: sample_rate.max(8000),
            channels: channels.max(1),
            completed_voices_producer: prod,
            completed_voices_consumer: cons,
        }
    }

    /// Returns the IDs of all effects whose decoded PCM buffers are currently resident in RAM.
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        self.registered_effects
            .iter()
            .filter(|e| e.buffer.is_some())
            .map(|e| e.id.clone())
            .collect()
    }

    /// Returns the number of currently active, non-stopping voices.
    pub fn active_voices_count(&self) -> usize {
        self.voices[..self.max_voices]
            .iter()
            .filter(|v| v.active && !v.stopping)
            .count()
    }

    /// Updates 3D spatial audio listener parameters.
    pub fn set_listener(&mut self, listener: SpatialListener) {
        self.listener = listener;
    }

    /// Sets Doppler physics parameters (intensity factor and speed of sound in m/s).
    pub fn set_doppler_parameters(&mut self, factor: f32, speed_of_sound: f32) {
        self.doppler_factor = factor;
        self.speed_of_sound = speed_of_sound;
    }

    /// Declaratively synchronizes the catalog of sound effects.
    ///
    /// Memory-backed effects are decoded immediately into PCM (freeing compressed bytes)
    /// and are immune to eviction. File and network effects are registered in the catalog
    /// and decoded on demand when triggered via [`VoicePool::play_effect`].
    pub fn set_effects(&mut self, effects: Vec<EffectCatalogItem>) -> Result<(), String> {
        // Stop all active voices before restructuring catalog indices
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active {
                v.active = false;
                let _ = self.completed_voices_producer.push(v.voice_id);
            }
        }

        let mut old_map: HashMap<String, RegisteredEffect> = self
            .registered_effects
            .drain(..)
            .map(|mut e| {
                e.active_voices = 0;
                (e.id.clone(), e)
            })
            .collect();
        self.id_to_index.clear();
        self.allocated_ram_bytes = 0;

        for mut item in effects {
            let is_memory = item
                .source
                .data_bytes
                .as_ref()
                .is_some_and(|b| !b.is_empty());
            let trimmed = item.source.source.trim();
            let source_type = if is_memory {
                EffectSourceType::Memory
            } else if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
                EffectSourceType::Network
            } else {
                EffectSourceType::LocalFile
            };

            let reg = if source_type == EffectSourceType::Memory {
                let buf = decode_effect_source(&item.id, &item.source)?;
                let byte_size = buf.samples.len() * 4;
                // Free compressed raw bytes once decoded into PCM
                item.source.data_bytes = None;
                self.allocated_ram_bytes += byte_size;
                RegisteredEffect {
                    id: item.id,
                    source: item.source,
                    source_type,
                    buffer: Some(buf),
                    max_polyphony: item.max_polyphony.max(1),
                    pinned: item.pinned,
                    byte_size,
                    trigger_count: 0,
                    last_used: Instant::now(),
                    active_voices: 0,
                }
            } else if let Some(mut existing) = old_map.remove(&item.id) {
                if existing.source.source == item.source.source && existing.buffer.is_some() {
                    self.allocated_ram_bytes += existing.byte_size;
                    existing.max_polyphony = item.max_polyphony.max(1);
                    existing.pinned = item.pinned;
                    existing.source = item.source;
                    existing
                } else {
                    RegisteredEffect {
                        id: item.id,
                        source: item.source,
                        source_type,
                        buffer: None,
                        max_polyphony: item.max_polyphony.max(1),
                        pinned: item.pinned,
                        byte_size: 0,
                        trigger_count: 0,
                        last_used: Instant::now(),
                        active_voices: 0,
                    }
                }
            } else {
                RegisteredEffect {
                    id: item.id,
                    source: item.source,
                    source_type,
                    buffer: None,
                    max_polyphony: item.max_polyphony.max(1),
                    pinned: item.pinned,
                    byte_size: 0,
                    trigger_count: 0,
                    last_used: Instant::now(),
                    active_voices: 0,
                }
            };

            let idx = self.registered_effects.len();
            self.id_to_index.insert(reg.id.clone(), idx);
            self.registered_effects.push(reg);
        }

        let _ = self.evict_if_over_budget(None);
        Ok(())
    }

    /// Evicts inactive, unpinned, non-memory effects with the lowest multi-factor retention
    /// score until `allocated_ram_bytes <= target_bytes` or no evictable candidates remain.
    ///
    /// Returns `true` if at least one effect buffer was evicted.
    pub fn evict_lowest_scoring_until(
        &mut self,
        target_bytes: usize,
        exclude_idx: Option<usize>,
    ) -> bool {
        let mut evicted_any = false;
        let now = Instant::now();

        while self.allocated_ram_bytes > target_bytes {
            let mut candidate_idx: Option<usize> = None;
            let mut lowest_score = f64::INFINITY;

            for (idx, effect) in self.registered_effects.iter().enumerate() {
                if Some(idx) == exclude_idx {
                    continue;
                }
                if effect.is_evictable() {
                    let score = effect.retention_score(now);
                    if candidate_idx.is_none() || score < lowest_score {
                        lowest_score = score;
                        candidate_idx = Some(idx);
                    }
                }
            }

            if let Some(evict_idx) = candidate_idx {
                let eff = &mut self.registered_effects[evict_idx];
                self.allocated_ram_bytes = self.allocated_ram_bytes.saturating_sub(eff.byte_size);
                eff.buffer = None;
                eff.byte_size = 0;
                evicted_any = true;
            } else {
                // All remaining loaded effects are either active, pinned, or memory-backed.
                // Temporarily permit the allocation without dropping audio; eviction will
                // run again on VoiceCompleted.
                break;
            }
        }

        evicted_any
    }

    /// Checks if `allocated_ram_bytes` exceeds `max_ram_bytes` and purges lowest-scoring
    /// inactive effects if needed. Returns `true` if any effect was evicted.
    pub fn evict_if_over_budget(&mut self, exclude_idx: Option<usize>) -> bool {
        if let Some(limit) = self.max_ram_bytes {
            if self.allocated_ram_bytes > limit {
                return self.evict_lowest_scoring_until(limit, exclude_idx);
            }
        }
        false
    }

    /// Reactive Trigger 2: Invoked when an active voice finishes playing and frees its slot.
    /// Immediately purges lowest-scoring inactive effects if `allocated_ram_bytes > max_ram_bytes`.
    pub fn on_voice_completed(&mut self) -> bool {
        self.evict_if_over_budget(None)
    }

    /// Ensures the effect at `effect_idx` has its decoded PCM buffer loaded in RAM,
    /// performing reactive eviction before loading if necessary.
    pub fn ensure_effect_loaded(
        &mut self,
        effect_idx: usize,
        decoded_buffer: SoundBuffer,
    ) -> bool {
        let byte_size = decoded_buffer.samples.len() * 4;
        if let Some(limit) = self.max_ram_bytes {
            if self.allocated_ram_bytes + byte_size > limit {
                self.evict_lowest_scoring_until(limit.saturating_sub(byte_size), Some(effect_idx));
            }
        }
        let eff = &mut self.registered_effects[effect_idx];
        if let Some(old_buf) = eff.buffer.replace(decoded_buffer) {
            self.allocated_ram_bytes = self
                .allocated_ram_bytes
                .saturating_sub(old_buf.samples.len() * 4);
        }
        eff.byte_size = byte_size;
        self.allocated_ram_bytes += byte_size;
        true
    }

    /// Triggers an already loaded sound effect at `effect_idx` using the specified DSP routing and playback parameters.
    pub fn play_loaded_effect(
        &mut self,
        effect_idx: usize,
        dsp_routing: DspRouting,
        config: EffectConfig,
    ) -> Result<u32, String> {
        if effect_idx >= self.registered_effects.len()
            || self.registered_effects[effect_idx].buffer.is_none()
        {
            return Err("Effect buffer is not loaded".to_string());
        }

        // Check per-effect polyphony limit
        if self.registered_effects[effect_idx].active_voices
            >= self.registered_effects[effect_idx].max_polyphony
        {
            self.steal_voice_for_effect(effect_idx);
        }

        let voice_slot = self.find_free_voice_slot();
        let voice_id = self.next_voice_id.fetch_add(1, Ordering::Relaxed);

        let final_pitch = apply_jitter(
            config.pitch * config.rate,
            config.pitch_jitter,
            voice_id,
            0x1234,
        );
        let final_volume = apply_jitter(config.volume, config.volume_jitter, voice_id, 0x5678);

        let effect = &mut self.registered_effects[effect_idx];
        effect.trigger_count += 1;
        effect.last_used = Instant::now();
        effect.active_voices += 1;

        self.voices[voice_slot] = Voice {
            voice_id,
            active: true,
            effect_idx,
            cursor_frame: 0.0,
            volume: final_volume.max(0.0),
            pitch: final_pitch.max(0.001),
            balance: config.balance.clamp(-1.0, 1.0),
            priority: config.priority,
            looping: config.looping,
            dsp_routing,
            emitter: config.spatial,
            stopping: false,
            fade_samples_remaining: 0,
            total_fade_samples: 0,
            age_frames: 0,
        };

        Ok(voice_id)
    }

    /// Triggers a registered sound effect by its identifier, loading it into RAM on demand if needed.
    pub fn play_effect(
        &mut self,
        id: &str,
        dsp_routing: DspRouting,
        config: EffectConfig,
    ) -> Result<(u32, bool), String> {
        let effect_idx = match self.id_to_index.get(id) {
            Some(&idx) => idx,
            None => {
                return Err(format!(
                    "AudioEffectNotFound: Effect '{}' not registered in catalog",
                    id
                ));
            }
        };

        let mut ram_changed = false;
        if self.registered_effects[effect_idx].buffer.is_none() {
            let src = self.registered_effects[effect_idx].source.clone();
            let buf = decode_effect_source(id, &src)?;
            self.ensure_effect_loaded(effect_idx, buf);
            ram_changed = true;
        }

        let voice_id = self.play_loaded_effect(effect_idx, dsp_routing, config)?;
        Ok((voice_id, ram_changed))
    }

    fn find_free_voice_slot(&mut self) -> usize {
        for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
            if !v.active {
                return i;
            }
        }
        self.steal_global_voice()
    }

    fn steal_voice_for_effect(&mut self, effect_idx: usize) {
        let mut target_slot: Option<usize> = None;
        let mut lowest_priority = u8::MAX;
        let mut oldest_age = 0u64;

        for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
            if v.active && v.effect_idx == effect_idx {
                if v.priority < lowest_priority || (v.priority == lowest_priority && v.age_frames > oldest_age) {
                    lowest_priority = v.priority;
                    oldest_age = v.age_frames;
                    target_slot = Some(i);
                }
            }
        }

        if let Some(slot) = target_slot {
            self.stop_voice_immediate(slot);
        }
    }

    fn steal_global_voice(&mut self) -> usize {
        let mut target_slot = 0;

        match self.stealing_policy {
            VoiceStealingPolicy::LowestPriority => {
                let mut lowest = u8::MAX;
                let mut oldest = 0;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.priority < lowest || (v.priority == lowest && v.age_frames > oldest) {
                        lowest = v.priority;
                        oldest = v.age_frames;
                        target_slot = i;
                    }
                }
            }
            VoiceStealingPolicy::Oldest => {
                let mut oldest = 0;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.age_frames > oldest {
                        oldest = v.age_frames;
                        target_slot = i;
                    }
                }
            }
            VoiceStealingPolicy::Quietest => {
                let mut quietest = f32::MAX;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.volume < quietest {
                        quietest = v.volume;
                        target_slot = i;
                    }
                }
            }
            VoiceStealingPolicy::Farthest => {
                let mut farthest_dist = -1.0f32;
                let listener_pos = self.listener.position;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    let dist = if let Some(em) = v.emitter {
                        let dx = em.position.x - listener_pos.x;
                        let dy = em.position.y - listener_pos.y;
                        let dz = em.position.z - listener_pos.z;
                        (dx * dx + dy * dy + dz * dz).sqrt()
                    } else {
                        0.0
                    };
                    if dist > farthest_dist {
                        farthest_dist = dist;
                        target_slot = i;
                    }
                }
            }
        }

        self.stop_voice_immediate(target_slot);
        target_slot
    }

    fn stop_voice_immediate(&mut self, slot: usize) {
        let v = &mut self.voices[slot];
        if v.active {
            let effect_idx = v.effect_idx;
            if effect_idx < self.registered_effects.len() {
                self.registered_effects[effect_idx].active_voices =
                    self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                self.registered_effects[effect_idx].last_used = Instant::now();
            }
            let _ = self.completed_voices_producer.push(v.voice_id);
            v.active = false;
        }
    }

    /// Stops playback of the specified voice, applying quick fadeout if `fade_out_samples > 0`.
    pub fn stop_voice(&mut self, voice_id: u32, fade_out_samples: usize) {
        let mut stopped_immediate = false;
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                if fade_out_samples == 0 {
                    let effect_idx = v.effect_idx;
                    if effect_idx < self.registered_effects.len() {
                        self.registered_effects[effect_idx].active_voices =
                            self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                        self.registered_effects[effect_idx].last_used = Instant::now();
                    }
                    v.active = false;
                    let _ = self.completed_voices_producer.push(voice_id);
                    stopped_immediate = true;
                } else {
                    v.stopping = true;
                    v.fade_samples_remaining = fade_out_samples;
                    v.total_fade_samples = fade_out_samples;
                }
                break;
            }
        }
        if stopped_immediate {
            let _ = self.on_voice_completed();
        }
    }

    /// Stops all currently active voices, applying fadeout ramps if requested.
    pub fn stop_all(&mut self, fade_out_samples: usize) {
        let mut stopped_immediate = false;
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active {
                if fade_out_samples == 0 {
                    let effect_idx = v.effect_idx;
                    if effect_idx < self.registered_effects.len() {
                        self.registered_effects[effect_idx].active_voices =
                            self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                        self.registered_effects[effect_idx].last_used = Instant::now();
                    }
                    v.active = false;
                    let _ = self.completed_voices_producer.push(v.voice_id);
                    stopped_immediate = true;
                } else {
                    v.stopping = true;
                    v.fade_samples_remaining = fade_out_samples;
                    v.total_fade_samples = fade_out_samples;
                }
            }
        }
        if stopped_immediate {
            let _ = self.on_voice_completed();
        }
    }

    /// Dynamically modifies playback volume of an active voice.
    pub fn set_voice_volume(&mut self, voice_id: u32, volume: f32) {
        if !volume.is_finite() {
            return;
        }
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.volume = volume.max(0.0);
                break;
            }
        }
    }

    /// Dynamically modifies playback pitch multiplier of an active voice.
    pub fn set_voice_pitch(&mut self, voice_id: u32, pitch: f32) {
        if !pitch.is_finite() || pitch <= 0.0 {
            return;
        }
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.pitch = pitch;
                break;
            }
        }
    }

    /// Dynamically modifies stereo pan balance of an active voice.
    pub fn set_voice_balance(&mut self, voice_id: u32, balance: f32) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.balance = balance.clamp(-1.0, 1.0);
                break;
            }
        }
    }

    /// Updates 3D spatial emitter parameters for an active voice.
    pub fn set_voice_emitter(&mut self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.emitter = emitter;
                break;
            }
        }
    }

    /// Real-time audio render callback summing active voices into 3 routing buses:
    /// - `inherit_buf`: Voices inheriting music bus EQ and Reverb.
    /// - `isolate_buf`: Voices running isolated/clean.
    /// - `bypass_buf`: Voices bypassing all DSP directly to master mix.
    pub fn render(
        &mut self,
        inherit_buf: &mut [f32],
        isolate_buf: &mut [f32],
        bypass_buf: &mut [f32],
        frame_count: usize,
    ) {
        let channels = self.channels;
        let sample_rate = self.sample_rate as f64;

        for v in self.voices[..self.max_voices].iter_mut() {
            if !v.active {
                continue;
            }

            if v.effect_idx >= self.registered_effects.len() {
                v.active = false;
                continue;
            }

            let Some(ref buf) = self.registered_effects[v.effect_idx].buffer else {
                v.active = false;
                continue;
            };
            let total_frames = buf.frame_count();
            if total_frames == 0 {
                v.active = false;
                continue;
            }

            // Spatial positioning calculations
            let (spatial_gain_l, spatial_gain_r, doppler_ratio) = if let Some(ref em) = v.emitter {
                let eval = SpatialProcessor::evaluate(&self.listener, em, self.speed_of_sound);
                let gl = if eval.pan > 0.0 { (1.0 - eval.pan) * eval.gain } else { eval.gain };
                let gr = if eval.pan < 0.0 { (1.0 + eval.pan) * eval.gain } else { eval.gain };
                (gl, gr, eval.doppler_ratio as f64)
            } else {
                let bal = v.balance;
                let gl = if bal > 0.0 { 1.0 - bal } else { 1.0 };
                let gr = if bal < 0.0 { 1.0 + bal } else { 1.0 };
                (gl, gr, 1.0)
            };

            let step = (v.pitch as f64 * (buf.sample_rate as f64 / sample_rate)) * doppler_ratio;
            let target_out = match v.dsp_routing {
                DspRouting::Inherit => &mut *inherit_buf,
                DspRouting::Isolate => &mut *isolate_buf,
                DspRouting::Bypass => &mut *bypass_buf,
            };

            let mut completed_in_render = false;
            for k in 0..frame_count {
                let f0 = v.cursor_frame.floor() as usize;
                let f1 = f0 + 1;
                let frac = (v.cursor_frame - f0 as f64) as f32;

                if f0 >= total_frames {
                    if v.looping {
                        v.cursor_frame %= total_frames as f64;
                    } else {
                        v.active = false;
                        completed_in_render = true;
                        let _ = self.completed_voices_producer.push(v.voice_id);
                        break;
                    }
                }

                let f1_clamped = if f1 >= total_frames {
                    if v.looping {
                        0
                    } else {
                        total_frames - 1
                    }
                } else {
                    f1
                };

                let (sl, sr) = buf.sample_stereo_lerp(f0, f1_clamped, frac);

                // Quick fadeout attenuation if stopping
                let fade_gain = if v.stopping {
                    if v.fade_samples_remaining == 0 {
                        v.active = false;
                        completed_in_render = true;
                        let _ = self.completed_voices_producer.push(v.voice_id);
                        break;
                    }
                    let g = v.fade_samples_remaining as f32 / v.total_fade_samples as f32;
                    v.fade_samples_remaining -= 1;
                    g
                } else {
                    1.0
                };

                let effective_vol = v.volume * fade_gain;
                let out_l = sl * effective_vol * spatial_gain_l;
                let out_r = sr * effective_vol * spatial_gain_r;

                if channels == 1 {
                    target_out[k] += (out_l + out_r) * 0.5;
                } else {
                    target_out[k * channels] += out_l;
                    target_out[k * channels + 1] += out_r;
                }

                v.cursor_frame += step;
                v.age_frames += 1;
            }

            if completed_in_render {
                let effect_idx = v.effect_idx;
                self.registered_effects[effect_idx].active_voices =
                    self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                self.registered_effects[effect_idx].last_used = Instant::now();
            }
        }
    }
}
