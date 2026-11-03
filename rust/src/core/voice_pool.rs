//! High-performance Polyphonic Voice Pool with SIMD mixing, LRU RAM eviction,
//! pinned buffer protection, 3D Spatial Audio & Doppler, and dynamic DSP routing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

use crate::dsp::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor};
pub use crate::dsp::voice_pool::{pseudo_random_jitter, SoundBuffer, VoiceStealingPolicy};

pub const MAX_VOICES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspRouting {
    Inherit = 0,
    Isolate = 1,
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

#[derive(Debug, Clone)]
pub struct EffectConfig {
    pub volume: f32,
    pub balance: f32,
    pub pitch: f32,
    pub rate: f32,
    pub looping: bool,
    pub priority: u8,
    pub pitch_jitter: f32,
    pub volume_jitter: f32,
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
    pub buffer: SoundBuffer,
    pub max_polyphony: usize,
    pub pinned: bool,
    pub byte_size: usize,
    pub last_used: Instant,
    pub active_voices: usize,
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

pub struct VoicePool {
    pub max_voices: usize,
    pub max_ram_bytes: usize,
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
        max_ram_bytes: usize,
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

    pub fn loaded_effect_ids(&self) -> Vec<String> {
        self.registered_effects.iter().map(|e| e.id.clone()).collect()
    }

    pub fn active_voices_count(&self) -> usize {
        self.voices[..self.max_voices]
            .iter()
            .filter(|v| v.active && !v.stopping)
            .count()
    }

    pub fn set_listener(&mut self, listener: SpatialListener) {
        self.listener = listener;
    }

    pub fn set_doppler_parameters(&mut self, factor: f32, speed_of_sound: f32) {
        self.doppler_factor = factor;
        self.speed_of_sound = speed_of_sound;
    }

    pub fn load_effect(
        &mut self,
        id: String,
        buffer: SoundBuffer,
        max_polyphony: usize,
        pinned: bool,
    ) -> Result<(), String> {
        let byte_size = buffer.samples.len() * 4;

        // If effect already exists, update buffer
        if let Some(&idx) = self.id_to_index.get(&id) {
            let old_size = self.registered_effects[idx].byte_size;
            if self.allocated_ram_bytes - old_size + byte_size > self.max_ram_bytes {
                self.evict_lru_until(self.max_ram_bytes.saturating_sub(byte_size))?;
            }
            self.allocated_ram_bytes = self.allocated_ram_bytes - old_size + byte_size;
            self.registered_effects[idx].buffer = buffer;
            self.registered_effects[idx].max_polyphony = max_polyphony;
            self.registered_effects[idx].pinned = pinned;
            self.registered_effects[idx].byte_size = byte_size;
            self.registered_effects[idx].last_used = Instant::now();
            return Ok(());
        }

        if self.allocated_ram_bytes + byte_size > self.max_ram_bytes {
            self.evict_lru_until(self.max_ram_bytes.saturating_sub(byte_size))?;
        }

        let idx = self.registered_effects.len();
        self.id_to_index.insert(id.clone(), idx);
        self.registered_effects.push(RegisteredEffect {
            id,
            buffer,
            max_polyphony,
            pinned,
            byte_size,
            last_used: Instant::now(),
            active_voices: 0,
        });
        self.allocated_ram_bytes += byte_size;
        Ok(())
    }

    fn evict_lru_until(&mut self, target_bytes: usize) -> Result<(), String> {
        while self.allocated_ram_bytes > target_bytes {
            // Find unpinned candidate with 0 active voices and oldest last_used
            let mut candidate_idx: Option<usize> = None;
            let mut oldest_time = Instant::now();

            for (idx, effect) in self.registered_effects.iter().enumerate() {
                if !effect.pinned && effect.active_voices == 0 {
                    if candidate_idx.is_none() || effect.last_used < oldest_time {
                        oldest_time = effect.last_used;
                        candidate_idx = Some(idx);
                    }
                }
            }

            if let Some(evict_idx) = candidate_idx {
                let evicted = self.registered_effects.remove(evict_idx);
                self.allocated_ram_bytes = self.allocated_ram_bytes.saturating_sub(evicted.byte_size);
                self.rebuild_id_index();
            } else {
                return Err(format!(
                    "RAM budget of {} bytes exceeded. Cannot evict active or pinned effects.",
                    self.max_ram_bytes
                ));
            }
        }
        Ok(())
    }

    fn rebuild_id_index(&mut self) {
        self.id_to_index.clear();
        for (idx, effect) in self.registered_effects.iter().enumerate() {
            self.id_to_index.insert(effect.id.clone(), idx);
        }
        // Update voice effect_idx references
        for v in self.voices.iter_mut() {
            if v.active && v.effect_idx >= self.registered_effects.len() {
                v.active = false;
            }
        }
    }

    pub fn unload_effect(&mut self, id: &str) -> bool {
        if let Some(&idx) = self.id_to_index.get(id) {
            // Stop active voices using this effect with quick fadeout
            for v in self.voices.iter_mut() {
                if v.active && v.effect_idx == idx {
                    v.stopping = true;
                    v.fade_samples_remaining = (self.sample_rate as usize * 5) / 1000;
                    v.total_fade_samples = v.fade_samples_remaining.max(1);
                }
            }
            let evicted = self.registered_effects.remove(idx);
            self.allocated_ram_bytes = self.allocated_ram_bytes.saturating_sub(evicted.byte_size);
            self.rebuild_id_index();
            true
        } else {
            false
        }
    }

    pub fn play_effect(
        &mut self,
        id: &str,
        dsp_routing: DspRouting,
        config: EffectConfig,
    ) -> Result<u32, String> {
        let effect_idx = match self.id_to_index.get(id) {
            Some(&idx) => idx,
            None => {
                return Err(format!("AudioEffectNotFound: Effect '{}' not registered in RAM", id));
            }
        };

        // Check per-effect polyphony limit
        let effect = &mut self.registered_effects[effect_idx];
        if effect.active_voices >= effect.max_polyphony {
            // Steal within this effect's voices
            self.steal_voice_for_effect(effect_idx);
        }

        let voice_slot = self.find_free_voice_slot();
        let voice_id = self.next_voice_id.fetch_add(1, Ordering::Relaxed);

        let final_pitch = apply_jitter(config.pitch * config.rate, config.pitch_jitter, voice_id, 0x1234);
        let final_volume = apply_jitter(config.volume, config.volume_jitter, voice_id, 0x5678);

        let effect = &mut self.registered_effects[effect_idx];
        effect.last_used = Instant::now();
        effect.active_voices += 1;

        self.voices[voice_slot] = Voice {
            voice_id,
            active: true,
            effect_idx,
            cursor_frame: 0.0,
            volume: final_volume.clamp(0.0, 4.0),
            pitch: final_pitch.clamp(0.05, 16.0),
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
            }
            let _ = self.completed_voices_producer.push(v.voice_id);
            v.active = false;
        }
    }

    pub fn stop_voice(&mut self, voice_id: u32, fade_out_samples: usize) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                if fade_out_samples == 0 {
                    let effect_idx = v.effect_idx;
                    if effect_idx < self.registered_effects.len() {
                        self.registered_effects[effect_idx].active_voices =
                            self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                    }
                    v.active = false;
                    let _ = self.completed_voices_producer.push(voice_id);
                } else {
                    v.stopping = true;
                    v.fade_samples_remaining = fade_out_samples;
                    v.total_fade_samples = fade_out_samples;
                }
                break;
            }
        }
    }

    pub fn stop_all(&mut self, fade_out_samples: usize) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active {
                if fade_out_samples == 0 {
                    let effect_idx = v.effect_idx;
                    if effect_idx < self.registered_effects.len() {
                        self.registered_effects[effect_idx].active_voices =
                            self.registered_effects[effect_idx].active_voices.saturating_sub(1);
                    }
                    v.active = false;
                    let _ = self.completed_voices_producer.push(v.voice_id);
                } else {
                    v.stopping = true;
                    v.fade_samples_remaining = fade_out_samples;
                    v.total_fade_samples = fade_out_samples;
                }
            }
        }
    }

    pub fn set_voice_volume(&mut self, voice_id: u32, volume: f32) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.volume = volume.clamp(0.0, 4.0);
                break;
            }
        }
    }

    pub fn set_voice_pitch(&mut self, voice_id: u32, pitch: f32) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.pitch = pitch.clamp(0.05, 16.0);
                break;
            }
        }
    }

    pub fn set_voice_balance(&mut self, voice_id: u32, balance: f32) {
        for v in self.voices[..self.max_voices].iter_mut() {
            if v.active && v.voice_id == voice_id {
                v.balance = balance.clamp(-1.0, 1.0);
                break;
            }
        }
    }

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

            let buf = &self.registered_effects[v.effect_idx].buffer;
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

            for k in 0..frame_count {
                let f0 = v.cursor_frame.floor() as usize;
                let f1 = f0 + 1;
                let frac = (v.cursor_frame - f0 as f64) as f32;

                if f0 >= total_frames {
                    if v.looping {
                        v.cursor_frame %= total_frames as f64;
                    } else {
                        v.active = false;
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
        }
    }
}
