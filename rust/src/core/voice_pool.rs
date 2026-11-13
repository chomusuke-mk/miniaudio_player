//! High-performance Polyphonic Voice Pool with SIMD mixing, LRU RAM eviction,
//! pinned buffer protection, 3D Spatial Audio & Doppler, and dynamic DSP routing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::time::Instant;

use crate::core::dual_source::{resolve_local_source_path, strip_file_prefix, AudioSourceCore};
use crate::dsp::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor};
pub use crate::dsp::voice_pool::{pseudo_random_jitter, SoundBuffer, VoiceStealingPolicy};

/// Classifies an [`AudioSourceCore`] into its cache retention [`EffectSourceType`].
#[inline]
pub(crate) fn classify_source_type(source: &AudioSourceCore) -> EffectSourceType {
    let is_memory = source.data_bytes.as_ref().is_some_and(|b| !b.is_empty());
    if is_memory {
        return EffectSourceType::Memory;
    }
    let trimmed = source.source.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        EffectSourceType::Network
    } else {
        EffectSourceType::LocalFile
    }
}

/// Computes left/right spatial attenuation gains and Doppler pitch multiplier for a voice.
#[inline]
pub(crate) fn compute_spatial_and_doppler(
    emitter: Option<&SpatialEmitter>,
    listener: &SpatialListener,
    speed_of_sound: f32,
    balance: f32,
) -> (f32, f32, f64) {
    if let Some(em) = emitter {
        let eval = SpatialProcessor::evaluate(listener, em, speed_of_sound);
        let gl = if eval.pan > 0.0 {
            (1.0 - eval.pan) * eval.gain
        } else {
            eval.gain
        };
        let gr = if eval.pan < 0.0 {
            (1.0 + eval.pan) * eval.gain
        } else {
            eval.gain
        };
        (gl, gr, eval.doppler_ratio as f64)
    } else {
        let gl = if balance > 0.0 { 1.0 - balance } else { 1.0 };
        let gr = if balance < 0.0 { 1.0 + balance } else { 1.0 };
        (gl, gr, 1.0)
    }
}

pub(crate) struct VoiceRenderState<'a> {
    pub active: &'a mut bool,
    pub cursor_frame: &'a mut f64,
    pub stopping: &'a mut bool,
    pub fade_samples_remaining: &'a mut usize,
    pub total_fade_samples: usize,
    pub age_frames: &'a mut u64,
}

#[inline]
#[allow(clippy::too_many_arguments)]
pub(crate) fn render_voice_buffer(
    state: VoiceRenderState<'_>,
    buf: &SoundBuffer,
    volume: f32,
    pitch: f32,
    balance: f32,
    looping: bool,
    emitter: Option<&SpatialEmitter>,
    listener: &SpatialListener,
    speed_of_sound: f32,
    target_out: &mut [f32],
    frame_count: usize,
    channels: usize,
    sample_rate: f64,
) -> bool {
    let total_frames = buf.frame_count();
    if total_frames == 0 {
        *state.active = false;
        return false;
    }

    let (spatial_gain_l, spatial_gain_r, doppler_ratio) =
        compute_spatial_and_doppler(emitter, listener, speed_of_sound, balance);
    let step = (pitch as f64 * (buf.sample_rate as f64 / sample_rate)) * doppler_ratio;

    for k in 0..frame_count {
        let Some((f0, f1_clamped, frac)) =
            SoundBuffer::resolve_lerp_indices(state.cursor_frame, total_frames, looping)
        else {
            *state.active = false;
            return true;
        };

        let (sl, sr) = buf.sample_stereo_lerp(f0, f1_clamped, frac);

        let fade_gain = if *state.stopping {
            if *state.fade_samples_remaining == 0 {
                *state.active = false;
                return true;
            }
            let denom = state.total_fade_samples.max(1) as f32;
            let g = *state.fade_samples_remaining as f32 / denom;
            *state.fade_samples_remaining -= 1;
            g
        } else {
            1.0
        };

        let effective_vol = volume * fade_gain;
        let out_l = sl * effective_vol * spatial_gain_l;
        let out_r = sr * effective_vol * spatial_gain_r;

        if channels == 1 {
            target_out[k] += (out_l + out_r) * 0.5;
        } else {
            target_out[k * channels] += out_l;
            target_out[k * channels + 1] += out_r;
        }

        *state.cursor_frame += step;
        *state.age_frames += 1;
    }

    false
}

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
    /// DSP routing mode (Inherit, Isolate, or Bypass).
    pub dsp_routing: DspRouting,
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
            dsp_routing: DspRouting::Inherit,
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
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(5))
            .timeout_read(std::time::Duration::from_secs(10))
            .max_idle_connections(0)
            .build();
        let mut req = agent.get(trimmed);
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
            let source_type = classify_source_type(&item.source);

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

    /// Triggers an already loaded sound effect at `effect_idx` using the specified playback parameters.
    pub fn play_loaded_effect(
        &mut self,
        effect_idx: usize,
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
            dsp_routing: config.dsp_routing,
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

        let voice_id = self.play_loaded_effect(effect_idx, config)?;
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
            let target_out = match v.dsp_routing {
                DspRouting::Inherit => &mut *inherit_buf,
                DspRouting::Isolate => &mut *isolate_buf,
                DspRouting::Bypass => &mut *bypass_buf,
            };

            let completed_in_render = render_voice_buffer(
                VoiceRenderState {
                    active: &mut v.active,
                    cursor_frame: &mut v.cursor_frame,
                    stopping: &mut v.stopping,
                    fade_samples_remaining: &mut v.fade_samples_remaining,
                    total_fade_samples: v.total_fade_samples,
                    age_frames: &mut v.age_frames,
                },
                buf,
                v.volume,
                v.pitch,
                v.balance,
                v.looping,
                v.emitter.as_ref(),
                &self.listener,
                self.speed_of_sound,
                target_out,
                frame_count,
                channels,
                sample_rate,
            );

            if completed_in_render {
                let _ = self.completed_voices_producer.push(v.voice_id);
                let effect_idx = v.effect_idx;
                self.registered_effects[effect_idx].active_voices =
                    self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                self.registered_effects[effect_idx].last_used = Instant::now();
            }
        }
    }
}

// ============================================================================
// Decoupled Real-Time (`VoicePoolRt`) & Cold (`EffectCatalog`) SFX Architecture
// ============================================================================

/// Wait-free atomic telemetry counters shared between [`EffectCatalog`] and [`VoicePoolRt`].
pub struct SharedVoiceMetrics {
    cmd_seq: AtomicU64,
    /// Packed `(seq: u48 << 16) | (active_count: u16)` allowing wait-free reads consistent with
    /// synchronous command issuance before the RT thread drains the command ring.
    packed_active: AtomicU64,
    pending_done: AtomicBool,
    allocated_ram_bytes: AtomicUsize,
}

impl Default for SharedVoiceMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl SharedVoiceMetrics {
    /// Creates zero-initialized voice metrics.
    pub fn new() -> Self {
        Self {
            cmd_seq: AtomicU64::new(0),
            packed_active: AtomicU64::new(0),
            pending_done: AtomicBool::new(false),
            allocated_ram_bytes: AtomicUsize::new(0),
        }
    }

    #[inline]
    pub fn next_seq(&self) -> u64 {
        self.cmd_seq.fetch_add(1, Ordering::AcqRel) + 1
    }

    #[inline]
    pub fn publish_cold_count(&self, seq: u64, count: u16) {
        let packed = (seq << 16) | (count as u64);
        self.packed_active.store(packed, Ordering::Release);
    }

    #[inline]
    pub fn reconcile_rt_count(&self, last_rt_seq: u64, live_count: u16) {
        let cur = self.packed_active.load(Ordering::Acquire);
        if (cur >> 16) == last_rt_seq {
            let desired = (last_rt_seq << 16) | (live_count as u64);
            let _ = self.packed_active.compare_exchange(
                cur,
                desired,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }

    #[inline]
    pub fn active_voices_count(&self) -> u32 {
        (self.packed_active.load(Ordering::Acquire) & 0xFFFF) as u32
    }

    #[inline]
    pub fn allocated_ram_bytes(&self) -> usize {
        self.allocated_ram_bytes.load(Ordering::Acquire)
    }

    #[inline]
    pub fn set_allocated_ram_bytes(&self, bytes: usize) {
        self.allocated_ram_bytes.store(bytes, Ordering::Release);
    }

    #[inline]
    pub fn mark_pending_done(&self) {
        self.pending_done.store(true, Ordering::Release);
    }

    #[inline]
    pub fn has_pending_done(&self) -> bool {
        self.pending_done.load(Ordering::Acquire)
    }

    #[inline]
    pub fn clear_pending_done(&self) {
        self.pending_done.store(false, Ordering::Release);
    }
}

/// Real-time SFX completion notification pushed from [`VoicePoolRt`] to [`EffectCatalog`].
#[derive(Debug, Clone, Copy)]
pub struct RtVoiceDone {
    /// Voice identifier that finished, faded out, or was stopped/stolen.
    pub voice_id: u32,
    /// Stable catalog entry key owning this voice when triggered.
    pub effect_key: u64,
}

/// Lock-free commands dispatched from control/API threads to [`VoicePoolRt`].
pub enum RtVoiceCmd {
    /// Starts rendering a voice using an owned `Arc<[f32]>` [`SoundBuffer`] handle.
    Start {
        seq: u64,
        voice_id: u32,
        effect_key: u64,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        balance: f32,
        priority: u8,
        looping: bool,
        dsp_routing: DspRouting,
        emitter: Option<SpatialEmitter>,
    },
    /// Stops an active voice immediately (`fade_out_samples == 0`) or with a linear ramp.
    StopVoice {
        seq: u64,
        voice_id: u32,
        fade_out_samples: usize,
    },
    /// Stops all active voices immediately (`fade_out_samples == 0`) or with a linear ramp.
    StopAll {
        seq: u64,
        fade_out_samples: usize,
    },
    /// Updates playback volume on a live voice.
    SetVolume { voice_id: u32, volume: f32 },
    /// Updates pitch multiplier on a live voice.
    SetPitch { voice_id: u32, pitch: f32 },
    /// Updates stereo pan balance on a live voice.
    SetBalance { voice_id: u32, balance: f32 },
    /// Updates 3D emitter parameters on a live voice.
    SetEmitter {
        voice_id: u32,
        emitter: Option<SpatialEmitter>,
    },
    /// Updates 3D spatial listener pose.
    SetListener { listener: SpatialListener },
    /// Updates Doppler parameters.
    SetDoppler { factor: f32, speed_of_sound: f32 },
}

/// Fixed real-time voice slot owning its `SoundBuffer` handle independently of cold catalog reloads.
#[derive(Clone, Default)]
pub struct RtVoiceSlot {
    pub voice_id: u32,
    pub effect_key: u64,
    pub active: bool,
    pub buffer: Option<SoundBuffer>,
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

impl Default for DspRouting {
    fn default() -> Self {
        DspRouting::Inherit
    }
}

/// Callback type for deferring off-thread deallocation of retired [`SoundBuffer`] instances.
pub type SoundBufferReaperFn = Box<dyn FnMut(SoundBuffer) + Send>;

/// Lock-free real-time polyphonic voice renderer driven strictly by [`RtVoiceCmd`] messages.
pub struct VoicePoolRt {
    max_voices: usize,
    voices: [RtVoiceSlot; MAX_VOICES],
    listener: SpatialListener,
    speed_of_sound: f32,
    doppler_factor: f32,
    stealing_policy: VoiceStealingPolicy,
    sample_rate: u32,
    channels: usize,
    last_seq: u64,
    cmd_rx: crossbeam_channel::Receiver<RtVoiceCmd>,
    done_tx: rtrb::Producer<RtVoiceDone>,
    metrics: std::sync::Arc<SharedVoiceMetrics>,
    reaper_fn: Option<SoundBufferReaperFn>,
}

unsafe impl Send for VoicePoolRt {}

impl VoicePoolRt {
    /// Creates a new [`VoicePoolRt`] paired with its lock-free channels and shared atomic metrics.
    pub fn new(
        max_voices: usize,
        sample_rate: u32,
        channels: usize,
        cmd_rx: crossbeam_channel::Receiver<RtVoiceCmd>,
        done_tx: rtrb::Producer<RtVoiceDone>,
        metrics: std::sync::Arc<SharedVoiceMetrics>,
    ) -> Self {
        Self {
            max_voices: max_voices.clamp(1, MAX_VOICES),
            voices: std::array::from_fn(|_| RtVoiceSlot::default()),
            listener: SpatialListener::default(),
            speed_of_sound: 343.3,
            doppler_factor: 1.0,
            stealing_policy: VoiceStealingPolicy::LowestPriority,
            sample_rate: sample_rate.max(8000),
            channels: channels.max(1),
            last_seq: 0,
            cmd_rx,
            done_tx,
            metrics,
            reaper_fn: None,
        }
    }

    /// Attaches an off-RT reaper sink receiving retired `SoundBuffer`s when slots deactivate.
    pub fn set_reaper(&mut self, reaper: SoundBufferReaperFn) {
        self.reaper_fn = Some(reaper);
    }

    #[inline]
    fn retire_buffer(&mut self, slot_idx: usize) {
        if let Some(buf) = self.voices[slot_idx].buffer.take() {
            if let Some(ref mut reaper) = self.reaper_fn {
                reaper(buf);
            }
        }
    }

    #[inline]
    fn push_done(&mut self, voice_id: u32, effect_key: u64) {
        if self
            .done_tx
            .push(RtVoiceDone {
                voice_id,
                effect_key,
            })
            .is_ok()
        {
            self.metrics.mark_pending_done();
        }
    }

    fn find_or_steal_slot(&mut self) -> usize {
        for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
            if !v.active {
                return i;
            }
        }

        let mut target = 0usize;
        match self.stealing_policy {
            VoiceStealingPolicy::LowestPriority => {
                let mut lowest = u8::MAX;
                let mut oldest = 0u64;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.priority < lowest || (v.priority == lowest && v.age_frames > oldest) {
                        lowest = v.priority;
                        oldest = v.age_frames;
                        target = i;
                    }
                }
            }
            VoiceStealingPolicy::Oldest => {
                let mut oldest = 0u64;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.age_frames > oldest {
                        oldest = v.age_frames;
                        target = i;
                    }
                }
            }
            VoiceStealingPolicy::Quietest => {
                let mut quietest = f32::MAX;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    if v.volume < quietest {
                        quietest = v.volume;
                        target = i;
                    }
                }
            }
            VoiceStealingPolicy::Farthest => {
                let mut farthest = -1.0f32;
                let lp = self.listener.position;
                for (i, v) in self.voices[..self.max_voices].iter().enumerate() {
                    let dist = if let Some(em) = v.emitter {
                        let dx = em.position.x - lp.x;
                        let dy = em.position.y - lp.y;
                        let dz = em.position.z - lp.z;
                        (dx * dx + dy * dy + dz * dz).sqrt()
                    } else {
                        0.0
                    };
                    if dist > farthest {
                        farthest = dist;
                        target = i;
                    }
                }
            }
        }

        if self.voices[target].active {
            let vid = self.voices[target].voice_id;
            let key = self.voices[target].effect_key;
            self.voices[target].active = false;
            self.retire_buffer(target);
            self.push_done(vid, key);
        }
        target
    }

    fn drain_commands(&mut self) {
        while let Ok(cmd) = self.cmd_rx.try_recv() {
            match cmd {
                RtVoiceCmd::Start {
                    seq,
                    voice_id,
                    effect_key,
                    buffer,
                    volume,
                    pitch,
                    balance,
                    priority,
                    looping,
                    dsp_routing,
                    emitter,
                } => {
                    self.last_seq = self.last_seq.max(seq);
                    let slot = self.find_or_steal_slot();
                    self.retire_buffer(slot);
                    self.voices[slot] = RtVoiceSlot {
                        voice_id,
                        effect_key,
                        active: true,
                        buffer: Some(buffer),
                        cursor_frame: 0.0,
                        volume,
                        pitch,
                        balance,
                        priority,
                        looping,
                        dsp_routing,
                        emitter,
                        stopping: false,
                        fade_samples_remaining: 0,
                        total_fade_samples: 0,
                        age_frames: 0,
                    };
                }
                RtVoiceCmd::StopVoice {
                    seq,
                    voice_id,
                    fade_out_samples,
                } => {
                    self.last_seq = self.last_seq.max(seq);
                    let mut completed_pair = None;
                    for i in 0..self.max_voices {
                        let v = &mut self.voices[i];
                        if v.active && v.voice_id == voice_id {
                            if fade_out_samples == 0 {
                                let key = v.effect_key;
                                v.active = false;
                                completed_pair = Some((i, voice_id, key));
                            } else {
                                v.stopping = true;
                                v.fade_samples_remaining = fade_out_samples;
                                v.total_fade_samples = fade_out_samples;
                            }
                            break;
                        }
                    }
                    if let Some((slot_idx, vid, key)) = completed_pair {
                        self.retire_buffer(slot_idx);
                        self.push_done(vid, key);
                    }
                }
                RtVoiceCmd::StopAll {
                    seq,
                    fade_out_samples,
                } => {
                    self.last_seq = self.last_seq.max(seq);
                    for i in 0..self.max_voices {
                        if self.voices[i].active {
                            if fade_out_samples == 0 {
                                let vid = self.voices[i].voice_id;
                                let key = self.voices[i].effect_key;
                                self.voices[i].active = false;
                                self.retire_buffer(i);
                                self.push_done(vid, key);
                            } else {
                                self.voices[i].stopping = true;
                                self.voices[i].fade_samples_remaining = fade_out_samples;
                                self.voices[i].total_fade_samples = fade_out_samples;
                            }
                        }
                    }
                }
                RtVoiceCmd::SetVolume { voice_id, volume } => {
                    if volume.is_finite() {
                        for v in self.voices[..self.max_voices].iter_mut() {
                            if v.active && v.voice_id == voice_id {
                                v.volume = volume.max(0.0);
                                break;
                            }
                        }
                    }
                }
                RtVoiceCmd::SetPitch { voice_id, pitch } => {
                    if pitch.is_finite() && pitch > 0.0 {
                        for v in self.voices[..self.max_voices].iter_mut() {
                            if v.active && v.voice_id == voice_id {
                                v.pitch = pitch;
                                break;
                            }
                        }
                    }
                }
                RtVoiceCmd::SetBalance { voice_id, balance } => {
                    for v in self.voices[..self.max_voices].iter_mut() {
                        if v.active && v.voice_id == voice_id {
                            v.balance = balance.clamp(-1.0, 1.0);
                            break;
                        }
                    }
                }
                RtVoiceCmd::SetEmitter { voice_id, emitter } => {
                    for v in self.voices[..self.max_voices].iter_mut() {
                        if v.active && v.voice_id == voice_id {
                            v.emitter = emitter;
                            break;
                        }
                    }
                }
                RtVoiceCmd::SetListener { listener } => {
                    self.listener = listener;
                }
                RtVoiceCmd::SetDoppler {
                    factor,
                    speed_of_sound,
                } => {
                    self.doppler_factor = factor;
                    self.speed_of_sound = speed_of_sound;
                }
            }
        }
    }

    /// Wait-free real-time render pass: drains pending commands, mixes all active slots
    /// without touching cold catalog locks, and reconciles active voice telemetry.
    pub fn render(
        &mut self,
        inherit_buf: &mut [f32],
        isolate_buf: &mut [f32],
        bypass_buf: &mut [f32],
        frame_count: usize,
    ) {
        self.drain_commands();

        let channels = self.channels;
        let sample_rate = self.sample_rate as f64;
        let mut live_count: u16 = 0;

        for i in 0..self.max_voices {
            if !self.voices[i].active {
                continue;
            }
            let Some(buf) = self.voices[i].buffer.clone() else {
                self.voices[i].active = false;
                continue;
            };

            let target_out = match self.voices[i].dsp_routing {
                DspRouting::Inherit => &mut *inherit_buf,
                DspRouting::Isolate => &mut *isolate_buf,
                DspRouting::Bypass => &mut *bypass_buf,
            };

            let completed = {
                let v = &mut self.voices[i];
                render_voice_buffer(
                    VoiceRenderState {
                        active: &mut v.active,
                        cursor_frame: &mut v.cursor_frame,
                        stopping: &mut v.stopping,
                        fade_samples_remaining: &mut v.fade_samples_remaining,
                        total_fade_samples: v.total_fade_samples,
                        age_frames: &mut v.age_frames,
                    },
                    &buf,
                    v.volume,
                    v.pitch,
                    v.balance,
                    v.looping,
                    v.emitter.as_ref(),
                    &self.listener,
                    self.speed_of_sound,
                    target_out,
                    frame_count,
                    channels,
                    sample_rate,
                )
            };

            drop(buf);

            if completed {
                let vid = self.voices[i].voice_id;
                let key = self.voices[i].effect_key;
                self.retire_buffer(i);
                self.push_done(vid, key);
            } else if !self.voices[i].active {
                self.retire_buffer(i);
            } else if !self.voices[i].stopping {
                live_count += 1;
            }
        }

        self.metrics.reconcile_rt_count(self.last_seq, live_count);
    }
}

/// Cold-side catalog entry adding a stable [`effect_key`] for lock-free RT decoupling.
pub struct CatalogEntry {
    pub effect_key: u64,
    pub inner: RegisteredEffect,
}

#[derive(Clone, Copy)]
struct ShadowVoice {
    voice_id: u32,
    effect_key: u64,
    priority: u8,
    spawn_order: u64,
    volume: f32,
    emitter: Option<SpatialEmitter>,
    stopping: bool,
}

/// Pre-decoded memory batch produced outside [`EffectCatalog`] locks.
pub struct PreparedCatalogItem {
    pub id: String,
    pub source: AudioSourceCore,
    pub source_type: EffectSourceType,
    pub predecoded: Option<SoundBuffer>,
    pub max_polyphony: usize,
    pub pinned: bool,
}

/// Decodes memory-backed catalog entries outside any mutex.
pub fn prepare_catalog_items(
    effects: Vec<EffectCatalogItem>,
) -> Result<Vec<PreparedCatalogItem>, String> {
    let mut prepared = Vec::with_capacity(effects.len());
    for mut item in effects {
        let source_type = classify_source_type(&item.source);
        let predecoded = if source_type == EffectSourceType::Memory {
            let buf = decode_effect_source(&item.id, &item.source)?;
            item.source.data_bytes = None;
            Some(buf)
        } else {
            None
        };
        prepared.push(PreparedCatalogItem {
            id: item.id,
            source: item.source,
            source_type,
            predecoded,
            max_polyphony: item.max_polyphony.max(1),
            pinned: item.pinned,
        });
    }
    Ok(prepared)
}

/// Cold-path sound effect catalog, LRU cache, and command producer for [`VoicePoolRt`].
pub struct EffectCatalog {
    pub max_voices: usize,
    pub max_ram_bytes: Option<usize>,
    pub allocated_ram_bytes: usize,
    pub entries: Vec<CatalogEntry>,
    pub id_to_index: HashMap<String, usize>,
    next_effect_key: u64,
    next_voice_id: u32,
    next_spawn_order: u64,
    shadow_voices: HashMap<u32, ShadowVoice>,
    pub listener: SpatialListener,
    pub speed_of_sound: f32,
    pub stealing_policy: VoiceStealingPolicy,
    cmd_tx: crossbeam_channel::Sender<RtVoiceCmd>,
    done_rx: rtrb::Consumer<RtVoiceDone>,
    metrics: std::sync::Arc<SharedVoiceMetrics>,
}

unsafe impl Send for EffectCatalog {}

impl EffectCatalog {
    /// Creates a cold catalog connected to its paired [`VoicePoolRt`].
    pub fn new(
        max_voices: usize,
        max_ram_bytes: Option<usize>,
        cmd_tx: crossbeam_channel::Sender<RtVoiceCmd>,
        done_rx: rtrb::Consumer<RtVoiceDone>,
        metrics: std::sync::Arc<SharedVoiceMetrics>,
    ) -> Self {
        Self {
            max_voices: max_voices.clamp(1, MAX_VOICES),
            max_ram_bytes,
            allocated_ram_bytes: 0,
            entries: Vec::new(),
            id_to_index: HashMap::new(),
            next_effect_key: 1,
            next_voice_id: 1,
            next_spawn_order: 1,
            shadow_voices: HashMap::new(),
            listener: SpatialListener::default(),
            speed_of_sound: 343.3,
            stealing_policy: VoiceStealingPolicy::LowestPriority,
            cmd_tx,
            done_rx,
            metrics,
        }
    }

    /// Returns currently resident PCM effect IDs.
    pub fn loaded_effect_ids(&self) -> Vec<String> {
        self.entries
            .iter()
            .filter(|e| e.inner.buffer.is_some())
            .map(|e| e.inner.id.clone())
            .collect()
    }

    fn sync_metrics_ram(&self) {
        self.metrics.set_allocated_ram_bytes(self.allocated_ram_bytes);
    }

    #[inline]
    fn find_index_by_key(&self, effect_key: u64) -> Option<usize> {
        self.entries.iter().position(|e| e.effect_key == effect_key)
    }

    /// Drains RT voice completions into cold accounting without touching RT state.
    pub fn drain_completed(&mut self) -> (Vec<u32>, bool) {
        let mut completed_ids = Vec::new();
        let mut evicted = false;
        let now = Instant::now();
        self.metrics.clear_pending_done();

        while let Ok(done) = self.done_rx.pop() {
            completed_ids.push(done.voice_id);
            if let Some(sv) = self.shadow_voices.remove(&done.voice_id) {
                if let Some(idx) = self.find_index_by_key(sv.effect_key) {
                    let eff = &mut self.entries[idx].inner;
                    eff.active_voices = eff.active_voices.saturating_sub(1);
                    eff.last_used = now;
                }
            }
        }

        if !completed_ids.is_empty() && self.evict_if_over_budget(None).0 {
            evicted = true;
        }
        (completed_ids, evicted)
    }

    /// Applies pre-decoded catalog items without blocking on memory decode or interrupting RT audio.
    /// Returns displaced buffers so the caller can drop them after releasing the catalog lock.
    pub fn apply_prepared_effects(
        &mut self,
        prepared: Vec<PreparedCatalogItem>,
    ) -> Vec<SoundBuffer> {
        let _ = self.drain_completed();
        let mut displaced_buffers = Vec::new();

        let mut old_map: HashMap<String, CatalogEntry> = self
            .entries
            .drain(..)
            .map(|mut e| {
                e.inner.active_voices = 0;
                (e.inner.id.clone(), e)
            })
            .collect();
        self.id_to_index.clear();
        self.allocated_ram_bytes = 0;

        for item in prepared {
            let entry = if let Some(buf) = item.predecoded {
                if let Some(mut prev) = old_map.remove(&item.id) {
                    if let Some(b) = prev.inner.buffer.take() {
                        displaced_buffers.push(b);
                    }
                }
                let byte_size = buf.samples.len() * 4;
                self.allocated_ram_bytes += byte_size;
                let key = self.next_effect_key;
                self.next_effect_key += 1;
                CatalogEntry {
                    effect_key: key,
                    inner: RegisteredEffect {
                        id: item.id,
                        source: item.source,
                        source_type: item.source_type,
                        buffer: Some(buf),
                        max_polyphony: item.max_polyphony,
                        pinned: item.pinned,
                        byte_size,
                        trigger_count: 0,
                        last_used: Instant::now(),
                        active_voices: 0,
                    },
                }
            } else if let Some(mut existing) = old_map.remove(&item.id) {
                if existing.inner.source.source == item.source.source
                    && existing.inner.buffer.is_some()
                {
                    self.allocated_ram_bytes += existing.inner.byte_size;
                    existing.inner.max_polyphony = item.max_polyphony;
                    existing.inner.pinned = item.pinned;
                    existing.inner.source = item.source;
                    existing
                } else {
                    if let Some(b) = existing.inner.buffer.take() {
                        displaced_buffers.push(b);
                    }
                    let key = self.next_effect_key;
                    self.next_effect_key += 1;
                    CatalogEntry {
                        effect_key: key,
                        inner: RegisteredEffect {
                            id: item.id,
                            source: item.source,
                            source_type: item.source_type,
                            buffer: None,
                            max_polyphony: item.max_polyphony,
                            pinned: item.pinned,
                            byte_size: 0,
                            trigger_count: 0,
                            last_used: Instant::now(),
                            active_voices: 0,
                        },
                    }
                }
            } else {
                let key = self.next_effect_key;
                self.next_effect_key += 1;
                CatalogEntry {
                    effect_key: key,
                    inner: RegisteredEffect {
                        id: item.id,
                        source: item.source,
                        source_type: item.source_type,
                        buffer: None,
                        max_polyphony: item.max_polyphony,
                        pinned: item.pinned,
                        byte_size: 0,
                        trigger_count: 0,
                        last_used: Instant::now(),
                        active_voices: 0,
                    },
                }
            };

            let idx = self.entries.len();
            self.id_to_index.insert(entry.inner.id.clone(), idx);
            self.entries.push(entry);
        }

        for (_, mut unused) in old_map {
            if let Some(b) = unused.inner.buffer.take() {
                displaced_buffers.push(b);
            }
        }

        // Preserve accurate active_voices counts for any surviving catalog keys.
        for sv in self.shadow_voices.values() {
            if !sv.stopping {
                if let Some(idx) = self.find_index_by_key(sv.effect_key) {
                    self.entries[idx].inner.active_voices += 1;
                }
            }
        }

        let (_, mut evicted_bufs) = self.evict_if_over_budget(None);
        displaced_buffers.append(&mut evicted_bufs);
        self.sync_metrics_ram();
        displaced_buffers
    }

    pub fn evict_lowest_scoring_until(
        &mut self,
        target_bytes: usize,
        exclude_idx: Option<usize>,
    ) -> (bool, Vec<SoundBuffer>) {
        let mut evicted_any = false;
        let mut evicted_buffers = Vec::new();
        let now = Instant::now();

        while self.allocated_ram_bytes > target_bytes {
            let mut candidate_idx: Option<usize> = None;
            let mut lowest_score = f64::INFINITY;

            for (idx, entry) in self.entries.iter().enumerate() {
                if Some(idx) == exclude_idx {
                    continue;
                }
                if entry.inner.is_evictable() {
                    let score = entry.inner.retention_score(now);
                    if candidate_idx.is_none() || score < lowest_score {
                        lowest_score = score;
                        candidate_idx = Some(idx);
                    }
                }
            }

            if let Some(evict_idx) = candidate_idx {
                let eff = &mut self.entries[evict_idx].inner;
                self.allocated_ram_bytes = self.allocated_ram_bytes.saturating_sub(eff.byte_size);
                if let Some(old_buf) = eff.buffer.take() {
                    evicted_buffers.push(old_buf);
                }
                eff.byte_size = 0;
                evicted_any = true;
            } else {
                break;
            }
        }

        if evicted_any {
            self.sync_metrics_ram();
        }
        (evicted_any, evicted_buffers)
    }

    #[inline]
    pub fn evict_if_over_budget(&mut self, exclude_idx: Option<usize>) -> (bool, Vec<SoundBuffer>) {
        if let Some(limit) = self.max_ram_bytes {
            if self.allocated_ram_bytes > limit {
                return self.evict_lowest_scoring_until(limit, exclude_idx);
            }
        }
        (false, Vec::new())
    }

    /// Returns cached lookup info or `(effect_key, source)` if decoding is required outside the lock.
    pub fn lookup_decode_target(&self, id: &str) -> Result<Option<(u64, AudioSourceCore)>, String> {
        let idx = match self.id_to_index.get(id) {
            Some(&i) => i,
            None => {
                return Err(format!(
                    "AudioEffectNotFound: Effect '{}' not registered in catalog",
                    id
                ));
            }
        };
        let entry = &self.entries[idx];
        if entry.inner.buffer.is_some() {
            Ok(None)
        } else {
            Ok(Some((entry.effect_key, entry.inner.source.clone())))
        }
    }

    /// Inserts a decoded PCM buffer into the matching catalog entry, enforcing RAM budget LRU.
    pub fn install_decoded_buffer(
        &mut self,
        id: &str,
        expected_key: u64,
        decoded: SoundBuffer,
    ) -> (bool, Vec<SoundBuffer>) {
        let Some(&idx) = self.id_to_index.get(id) else {
            return (false, vec![decoded]);
        };
        if self.entries[idx].effect_key != expected_key {
            return (false, vec![decoded]);
        }
        if self.entries[idx].inner.buffer.is_some() {
            return (false, vec![decoded]);
        }

        let byte_size = decoded.samples.len() * 4;
        let mut displaced = Vec::new();
        if let Some(limit) = self.max_ram_bytes {
            if self.allocated_ram_bytes + byte_size > limit {
                let (_, mut bufs) =
                    self.evict_lowest_scoring_until(limit.saturating_sub(byte_size), Some(idx));
                displaced.append(&mut bufs);
            }
        }

        let eff = &mut self.entries[idx].inner;
        if let Some(old_buf) = eff.buffer.replace(decoded) {
            self.allocated_ram_bytes = self
                .allocated_ram_bytes
                .saturating_sub(old_buf.samples.len() * 4);
            displaced.push(old_buf);
        }
        eff.byte_size = byte_size;
        self.allocated_ram_bytes += byte_size;
        self.sync_metrics_ram();
        (true, displaced)
    }

    fn steal_shadow_victim_for_effect(&mut self, effect_key: u64) -> Option<u32> {
        let victim = self
            .shadow_voices
            .values()
            .filter(|v| v.effect_key == effect_key && !v.stopping)
            .min_by_key(|v| (v.priority, v.spawn_order))
            .map(|v| v.voice_id)?;
        self.remove_shadow_voice(victim);
        Some(victim)
    }

    fn steal_global_shadow_victim(&mut self) -> Option<u32> {
        let victim = match self.stealing_policy {
            VoiceStealingPolicy::LowestPriority => self
                .shadow_voices
                .values()
                .min_by_key(|v| (v.priority, v.spawn_order))
                .map(|v| v.voice_id),
            VoiceStealingPolicy::Oldest => self
                .shadow_voices
                .values()
                .min_by_key(|v| v.spawn_order)
                .map(|v| v.voice_id),
            VoiceStealingPolicy::Quietest => self
                .shadow_voices
                .values()
                .min_by(|a, b| {
                    a.volume
                        .partial_cmp(&b.volume)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .map(|v| v.voice_id),
            VoiceStealingPolicy::Farthest => {
                let lp = self.listener.position;
                self.shadow_voices
                    .values()
                    .max_by(|a, b| {
                        let dist = |em: Option<SpatialEmitter>| -> f32 {
                            if let Some(e) = em {
                                let dx = e.position.x - lp.x;
                                let dy = e.position.y - lp.y;
                                let dz = e.position.z - lp.z;
                                (dx * dx + dy * dy + dz * dz).sqrt()
                            } else {
                                0.0
                            }
                        };
                        dist(a.emitter)
                            .partial_cmp(&dist(b.emitter))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|v| v.voice_id)
            }
        }?;
        self.remove_shadow_voice(victim);
        Some(victim)
    }

    fn remove_shadow_voice(&mut self, voice_id: u32) {
        if let Some(sv) = self.shadow_voices.remove(&voice_id) {
            if let Some(idx) = self.find_index_by_key(sv.effect_key) {
                let eff = &mut self.entries[idx].inner;
                eff.active_voices = eff.active_voices.saturating_sub(1);
                eff.last_used = Instant::now();
            }
        }
    }

    #[inline]
    fn live_shadow_count(&self) -> u16 {
        self.shadow_voices.values().filter(|v| !v.stopping).count() as u16
    }

    /// Triggers an already cached sound effect by ID via lock-free command dispatch to [`VoicePoolRt`].
    pub fn play_cached_effect(&mut self, id: &str, config: EffectConfig) -> Result<u32, String> {
        let _ = self.drain_completed();
        let idx = *self
            .id_to_index
            .get(id)
            .ok_or_else(|| format!("AudioEffectNotFound: Effect '{}' not registered", id))?;

        let (effect_key, buffer, max_polyphony, active_for_effect) = {
            let entry = &self.entries[idx];
            let Some(ref buf) = entry.inner.buffer else {
                return Err("Effect buffer is not loaded".to_string());
            };
            (
                entry.effect_key,
                buf.clone(),
                entry.inner.max_polyphony,
                entry.inner.active_voices,
            )
        };

        let mut stolen_victims = Vec::new();
        if active_for_effect >= max_polyphony {
            if let Some(v) = self.steal_shadow_victim_for_effect(effect_key) {
                stolen_victims.push(v);
            }
        }
        if self.shadow_voices.len() >= self.max_voices {
            if let Some(v) = self.steal_global_shadow_victim() {
                stolen_victims.push(v);
            }
        }

        let voice_id = self.next_voice_id;
        self.next_voice_id = self.next_voice_id.wrapping_add(1).max(1);
        let spawn_order = self.next_spawn_order;
        self.next_spawn_order += 1;

        let final_pitch = apply_jitter(
            config.pitch * config.rate,
            config.pitch_jitter,
            voice_id,
            0x1234,
        )
        .max(0.001);
        let final_volume =
            apply_jitter(config.volume, config.volume_jitter, voice_id, 0x5678).max(0.0);
        let final_balance = config.balance.clamp(-1.0, 1.0);

        {
            let eff = &mut self.entries[idx].inner;
            eff.trigger_count += 1;
            eff.last_used = Instant::now();
            eff.active_voices += 1;
        }

        self.shadow_voices.insert(
            voice_id,
            ShadowVoice {
                voice_id,
                effect_key,
                priority: config.priority,
                spawn_order,
                volume: final_volume,
                emitter: config.spatial,
                stopping: false,
            },
        );

        for victim_id in stolen_victims {
            let s = self.metrics.next_seq();
            let _ = self.cmd_tx.try_send(RtVoiceCmd::StopVoice {
                seq: s,
                voice_id: victim_id,
                fade_out_samples: 0,
            });
        }

        let seq = self.metrics.next_seq();
        let count = self.live_shadow_count();
        self.metrics.publish_cold_count(seq, count);

        self.cmd_tx
            .try_send(RtVoiceCmd::Start {
                seq,
                voice_id,
                effect_key,
                buffer,
                volume: final_volume,
                pitch: final_pitch,
                balance: final_balance,
                priority: config.priority,
                looping: config.looping,
                dsp_routing: config.dsp_routing,
                emitter: config.spatial,
            })
            .map_err(|_| "VoicePoolRt command channel full".to_string())?;

        Ok(voice_id)
    }

    /// Stops a single voice, updating shadow count synchronously and sending the command to RT.
    pub fn stop_voice(&mut self, voice_id: u32, fade_out_samples: usize) -> bool {
        let (_, mut evicted) = self.drain_completed();
        if fade_out_samples == 0 {
            self.remove_shadow_voice(voice_id);
            if self.evict_if_over_budget(None).0 {
                evicted = true;
            }
        } else {
            let stopping_key = self.shadow_voices.get_mut(&voice_id).and_then(|sv| {
                if !sv.stopping {
                    sv.stopping = true;
                    Some(sv.effect_key)
                } else {
                    None
                }
            });
            if let Some(effect_key) = stopping_key {
                if let Some(idx) = self.find_index_by_key(effect_key) {
                    let eff = &mut self.entries[idx].inner;
                    eff.active_voices = eff.active_voices.saturating_sub(1);
                }
            }
        }
        let seq = self.metrics.next_seq();
        let count = self.live_shadow_count();
        self.metrics.publish_cold_count(seq, count);
        let _ = self.cmd_tx.try_send(RtVoiceCmd::StopVoice {
            seq,
            voice_id,
            fade_out_samples,
        });
        evicted
    }

    /// Stops all active voices, updating shadow counts synchronously and sending the command to RT.
    pub fn stop_all(&mut self, fade_out_samples: usize) -> bool {
        let (_, mut evicted) = self.drain_completed();
        if fade_out_samples == 0 {
            self.shadow_voices.clear();
            for entry in &mut self.entries {
                entry.inner.active_voices = 0;
            }
            if self.evict_if_over_budget(None).0 {
                evicted = true;
            }
        } else {
            for sv in self.shadow_voices.values_mut() {
                sv.stopping = true;
            }
            for entry in &mut self.entries {
                entry.inner.active_voices = 0;
            }
        }
        let seq = self.metrics.next_seq();
        let count = self.live_shadow_count();
        self.metrics.publish_cold_count(seq, count);
        let _ = self.cmd_tx.try_send(RtVoiceCmd::StopAll {
            seq,
            fade_out_samples,
        });
        evicted
    }
}
