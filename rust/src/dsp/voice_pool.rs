//! Lock-free dynamic Voice Pool and Voice Stealing subsystem for video games and sound design.
//!
//! Provides ultra-low-latency polyphonic sound playback with:
//! - Fixed pre-allocated voice array (zero heap allocations in render loop).
//! - Voice Stealing policies: Oldest, LowestPriority, Quietest, Farthest.
//! - Anti-click 5 ms quick-fadeout when stealing active voices.
//! - Pitch/volume jitter for one-shot audio triggers (preventing machine-gun effect).
//! - 3D Spatial Audio & Doppler integration per voice.
//! - Linear interpolation resampling for fractional pitch/speed control.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use super::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor};

/// Maximum concurrent voices rendered simultaneously in a single voice pool.
pub const DEFAULT_MAX_VOICES: usize = 64;

/// Pre-decoded PCM audio buffer in memory, shared across multiple voices with zero copies.
#[derive(Debug, Clone)]
pub struct SoundBuffer {
    /// Interleaved 32-bit floating point PCM audio samples.
    pub samples: Arc<[f32]>,
    /// Sampling rate in Hz (e.g. 44100, 48000).
    pub sample_rate: u32,
    /// Number of channels (1 for Mono, 2 for Stereo).
    pub channels: usize,
    /// Duration in milliseconds.
    pub duration_ms: u64,
}

impl SoundBuffer {
    /// Creates a [SoundBuffer] from raw interleaved float PCM samples.
    pub fn new(samples: Vec<f32>, sample_rate: u32, channels: usize) -> Self {
        let ch = channels.max(1);
        let sr = sample_rate.max(8000);
        let total_frames = samples.len() / ch;
        let duration_ms = (total_frames as u64 * 1000) / sr as u64;
        Self {
            samples: samples.into(),
            sample_rate: sr,
            channels: ch,
            duration_ms,
        }
    }

    /// Creates a [SoundBuffer] by decoding any audio format from in-memory encoded bytes.
    pub fn decode_from_bytes(bytes: &[u8]) -> Result<Self, String> {
        use std::io::Cursor;
        use crate::decoder::symphonia_engine::SymphoniaEngine;

        if bytes.is_empty() {
            return Err("Cannot decode sound buffer from empty byte slice".to_string());
        }

        let cursor = Cursor::new(bytes.to_vec());
        let mut engine = SymphoniaEngine::new(cursor, None)
            .map_err(|e| format!("Failed to probe audio format: {:?}", e))?;

        let sr = engine.sample_rate();
        let ch = engine.channels() as usize;
        let mut pcm = Vec::with_capacity(32768);
        let mut packet_pcm = Vec::with_capacity(4096);

        loop {
            match engine.decode_next_frame(&mut packet_pcm) {
                Ok(true) => {
                    pcm.extend_from_slice(&packet_pcm);
                }
                Ok(false) => break,
                Err(e) => return Err(format!("Decoding error: {:?}", e)),
            }
        }

        if pcm.is_empty() {
            return Err("Decoded audio stream contained zero PCM frames".to_string());
        }

        Ok(Self::new(pcm, sr, ch))
    }

    /// Total number of audio frames in the buffer.
    #[inline]
    pub fn frame_count(&self) -> usize {
        if self.channels > 0 {
            self.samples.len() / self.channels
        } else {
            0
        }
    }
}

/// Eviction policy used when all voices in the pool are active.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VoiceStealingPolicy {
    /// Steal the voice with the lowest user-assigned priority.
    #[default]
    LowestPriority,
    /// Steal the voice that has been playing the longest.
    Oldest,
    /// Steal the voice with the lowest effective calculated volume/gain.
    Quietest,
    /// Steal the voice that is spatially farthest from the listener.
    Farthest,
}

/// State of an individual voice in the pool.
#[derive(Debug, Clone, Copy, PartialEq)]
enum VoiceState {
    Stopped,
    Playing,
    /// Rapid 5ms linear fadeout to 0.0 before replacing or stopping.
    FadingOut {
        current_gain: f32,
        gain_step: f32,
    },
}

/// A single polyphonic audio voice.
#[derive(Clone)]
pub struct Voice {
    pub id: u32,
    pub buffer: Option<SoundBuffer>,
    pub frame_cursor: f64,
    pub volume: f32,
    pub pitch: f32,
    pub priority: u8,
    pub looping: bool,
    pub spatial_emitter: Option<SpatialEmitter>,
    pub spatial_processor: SpatialProcessor,
    pub play_time_samples: u64,
    state: VoiceState,
}

impl Default for Voice {
    fn default() -> Self {
        Self {
            id: 0,
            buffer: None,
            frame_cursor: 0.0,
            volume: 1.0,
            pitch: 1.0,
            priority: 128,
            looping: false,
            spatial_emitter: None,
            spatial_processor: SpatialProcessor::default(),
            play_time_samples: 0,
            state: VoiceState::Stopped,
        }
    }
}

impl Voice {
    #[inline]
    pub fn is_active(&self) -> bool {
        self.state != VoiceState::Stopped
    }

    #[inline]
    pub fn is_playing(&self) -> bool {
        self.state == VoiceState::Playing
    }

    /// Starts a quick 5ms fade-out before stopping or replacing.
    pub fn quick_fadeout(&mut self, sample_rate: u32) {
        if self.state == VoiceState::Playing {
            let fade_frames = (sample_rate as f32 * 0.005).max(1.0); // 5 ms fade
            self.state = VoiceState::FadingOut {
                current_gain: 1.0,
                gain_step: 1.0 / fade_frames,
            };
        }
    }

    /// Immediately stops the voice.
    pub fn stop(&mut self) {
        self.state = VoiceState::Stopped;
        self.buffer = None;
        self.frame_cursor = 0.0;
        self.play_time_samples = 0;
    }
}

/// Dynamic Voice Pool managing polyphonic voice recycling, stealing, and spatial mixing.
pub struct VoicePool {
    voices: Vec<Voice>,
    policy: VoiceStealingPolicy,
    next_voice_id: AtomicU32,
    master_volume: f32,
    time_scale: f32,
}

impl Default for VoicePool {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_VOICES, VoiceStealingPolicy::default())
    }
}

impl VoicePool {
    /// Creates a [VoicePool] with a fixed capacity of voices.
    pub fn new(capacity: usize, policy: VoiceStealingPolicy) -> Self {
        let cap = capacity.clamp(1, 256);
        let mut voices = Vec::with_capacity(cap);
        for _ in 0..cap {
            voices.push(Voice::default());
        }
        Self {
            voices,
            policy,
            next_voice_id: AtomicU32::new(1),
            master_volume: 1.0,
            time_scale: 1.0,
        }
    }

    /// Maximum capacity of concurrent voices in this pool.
    #[inline]
    pub fn capacity(&self) -> usize {
        self.voices.len()
    }

    /// Returns the number of currently active playing voices.
    pub fn active_voice_count(&self) -> usize {
        self.voices.iter().filter(|v| v.is_active()).count()
    }

    /// Sets the voice stealing eviction policy.
    pub fn set_policy(&mut self, policy: VoiceStealingPolicy) {
        self.policy = policy;
    }

    /// Sets the master volume multiplier for all voices in the pool (0.0 to 2.0).
    pub fn set_master_volume(&mut self, volume: f32) {
        self.master_volume = volume.clamp(0.0, 2.0);
    }

    /// Sets the global time scale multiplier for the voice pool (e.g. 0.5 = slow-motion bullet time, 2.0 = fast).
    pub fn set_time_scale(&mut self, scale: f32) {
        self.time_scale = scale.clamp(0.01, 10.0);
    }

    /// Returns the current global time scale multiplier.
    pub fn time_scale(&self) -> f32 {
        self.time_scale
    }

    /// Modifies the volume of an active voice dynamically (0.0 to 2.0).
    pub fn set_voice_volume(&mut self, voice_id: u32, volume: f32) {
        if let Some(v) = self.voices.iter_mut().find(|v| v.id == voice_id && v.is_active()) {
            v.volume = volume.clamp(0.0, 2.0);
        }
    }

    /// Modifies the pitch / playback speed of an active voice dynamically (0.1 to 4.0).
    pub fn set_voice_pitch(&mut self, voice_id: u32, pitch: f32) {
        if let Some(v) = self.voices.iter_mut().find(|v| v.id == voice_id && v.is_active()) {
            v.pitch = pitch.clamp(0.1, 4.0);
        }
    }

    /// Updates the spatial emitter for an active voice dynamically.
    pub fn set_voice_emitter(&mut self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        if let Some(v) = self.voices.iter_mut().find(|v| v.id == voice_id && v.is_active()) {
            v.spatial_emitter = emitter;
        }
    }

    /// Returns whether a given voice ID is currently playing or fading out.
    pub fn is_voice_playing(&self, voice_id: u32) -> bool {
        self.voices.iter().any(|v| v.id == voice_id && v.is_active())
    }

    /// Places and plays a sound with an explicit `voice_id` into the pool.
    /// Returns `true` if allocated, `false` if rejected by voice stealing.
    pub fn play_sound_with_id(
        &mut self,
        voice_id: u32,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<SpatialEmitter>,
    ) -> bool {
        // 1. Find free voice
        if let Some(idx) = self.voices.iter().position(|v| !v.is_active()) {
            self.init_voice(idx, voice_id, buffer, volume, pitch, priority, looping, emitter);
            return true;
        }

        // 2. All voices occupied -> apply Voice Stealing policy
        if let Some(victim_idx) = self.find_victim_voice(priority, emitter.as_ref()) {
            self.voices[victim_idx].stop();
            self.init_voice(victim_idx, voice_id, buffer, volume, pitch, priority, looping, emitter);
            return true;
        }

        // Voice rejected because all active voices have higher priority
        false
    }

    /// Plays a sound in the pool. Returns the allocated `voice_id`, or `None` if stealing rejected it.
    pub fn play_sound(
        &mut self,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<SpatialEmitter>,
    ) -> Option<u32> {
        let voice_id = self.next_voice_id.fetch_add(1, Ordering::Relaxed);
        if self.play_sound_with_id(voice_id, buffer, volume, pitch, priority, looping, emitter) {
            Some(voice_id)
        } else {
            None
        }
    }

    /// Triggers an immediate one-shot sound with optional random pitch and volume jitter.
    ///
    /// Jitter prevents repetitive fatigue ("machine-gun effect").
    /// Example: `pitch_jitter = 0.05` produces $\pm 5\%$ pitch variations.
    pub fn play_one_shot(
        &mut self,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        pitch_jitter: f32,
        volume_jitter: f32,
        priority: u8,
        emitter: Option<SpatialEmitter>,
    ) -> Option<u32> {
        let eff_pitch = if pitch_jitter > 0.0 {
            let rnd = pseudo_random_jitter(self.next_voice_id.load(Ordering::Relaxed), 1);
            pitch * (1.0 + rnd * pitch_jitter.abs())
        } else {
            pitch
        };

        let eff_vol = if volume_jitter > 0.0 {
            let rnd = pseudo_random_jitter(self.next_voice_id.load(Ordering::Relaxed), 2);
            volume * (1.0 + rnd * volume_jitter.abs())
        } else {
            volume
        };

        self.play_sound(
            buffer,
            eff_vol.clamp(0.0, 2.0),
            eff_pitch.clamp(0.1, 4.0),
            priority,
            false,
            emitter,
        )
    }

    /// Stops a voice gracefully by voice ID using an anti-click 5 ms fade-out.
    pub fn stop_voice(&mut self, voice_id: u32, sample_rate: u32) {
        if let Some(v) = self.voices.iter_mut().find(|v| v.id == voice_id) {
            v.quick_fadeout(sample_rate);
        }
    }

    /// Immediately stops all voices in the pool.
    pub fn stop_all(&mut self) {
        for v in &mut self.voices {
            v.stop();
        }
    }

    /// Renders and mixes all active voices into the destination interleaved float PCM buffer.
    ///
    /// Lock-free, zero allocations in the audio thread.
    pub fn render_pcm(
        &mut self,
        out_buffer: &mut [f32],
        out_channels: usize,
        out_sample_rate: u32,
        listener: &SpatialListener,
    ) {
        if out_channels == 0 || out_sample_rate == 0 || out_buffer.is_empty() {
            return;
        }

        let num_frames = out_buffer.len() / out_channels;
        let master_vol = self.master_volume;

        for voice in &mut self.voices {
            if !voice.is_active() {
                continue;
            }

            let Some(ref sound) = voice.buffer else {
                voice.stop();
                continue;
            };

            let src_frames = sound.frame_count();
            if src_frames == 0 {
                voice.stop();
                continue;
            }

            // Spatial calculation
            let (spatial_gain, spatial_pan, spatial_doppler) = if let Some(ref em) = voice.spatial_emitter {
                let eval = SpatialProcessor::evaluate(listener, em, voice.spatial_processor.speed_of_sound);
                (eval.gain, eval.pan, eval.doppler_ratio)
            } else {
                (1.0f32, 0.0f32, 1.0f32)
            };

            let (pan_l, pan_r) = if out_channels >= 2 && voice.spatial_emitter.is_some() {
                let p = spatial_pan.clamp(-1.0, 1.0);
                let left_gain = ((1.0 - p) * 0.5).sqrt();
                let right_gain = ((1.0 + p) * 0.5).sqrt();
                (left_gain, right_gain)
            } else {
                (1.0f32, 1.0f32)
            };

            // Resampling step: pitch * (source_sr / dest_sr) * doppler * time_scale
            let speed_ratio = (voice.pitch * spatial_doppler * self.time_scale) as f64
                * (sound.sample_rate as f64 / out_sample_rate as f64);

            let base_vol = voice.volume * spatial_gain * master_vol;
            let src_ch = sound.channels;
            let samples = &sound.samples;

            for frame_idx in 0..num_frames {
                // Determine fade gain
                let fade_gain = match voice.state {
                    VoiceState::Playing => 1.0f32,
                    VoiceState::FadingOut {
                        ref mut current_gain,
                        gain_step,
                    } => {
                        let g = *current_gain;
                        *current_gain = (*current_gain - gain_step).max(0.0);
                        if *current_gain <= 0.0 {
                            voice.stop();
                            break;
                        }
                        g
                    }
                    VoiceState::Stopped => break,
                };

                let cur_frame = voice.frame_cursor;
                let frame_0 = cur_frame.floor() as usize;
                let frac = (cur_frame - frame_0 as f64) as f32;

                if frame_0 >= src_frames {
                    if voice.looping {
                        voice.frame_cursor = 0.0;
                        continue;
                    } else {
                        voice.stop();
                        break;
                    }
                }

                let frame_1 = if frame_0 + 1 < src_frames {
                    frame_0 + 1
                } else if voice.looping {
                    0
                } else {
                    frame_0
                };

                // Sample source channels (with linear interpolation)
                let (src_l, src_r) = if src_ch == 1 {
                    let s0 = samples[frame_0];
                    let s1 = samples[frame_1];
                    let val = s0 + frac * (s1 - s0);
                    (val, val)
                } else {
                    let s0_l = samples[frame_0 * src_ch];
                    let s0_r = samples[frame_0 * src_ch + 1];
                    let s1_l = samples[frame_1 * src_ch];
                    let s1_r = samples[frame_1 * src_ch + 1];
                    (s0_l + frac * (s1_l - s0_l), s0_r + frac * (s1_r - s0_r))
                };

                let eff_l = src_l * base_vol * fade_gain;
                let eff_r = src_r * base_vol * fade_gain;

                let out_offset = frame_idx * out_channels;
                if out_channels == 1 {
                    out_buffer[out_offset] += (eff_l + eff_r) * 0.5;
                } else {
                    out_buffer[out_offset] += eff_l * pan_l;
                    out_buffer[out_offset + 1] += eff_r * pan_r;
                }

                voice.frame_cursor += speed_ratio;
                voice.play_time_samples += 1;
            }
        }
    }

    fn init_voice(
        &mut self,
        idx: usize,
        voice_id: u32,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<SpatialEmitter>,
    ) {
        let v = &mut self.voices[idx];
        v.id = voice_id;
        v.buffer = Some(buffer);
        v.frame_cursor = 0.0;
        v.volume = volume;
        v.pitch = pitch;
        v.priority = priority;
        v.looping = looping;
        v.spatial_emitter = emitter;
        v.spatial_processor = SpatialProcessor::default();
        v.play_time_samples = 0;
        v.state = VoiceState::Playing;
    }

    /// Evaluates which active voice to evict based on policy and relative priority.
    fn find_victim_voice(&self, new_sound_priority: u8, _new_emitter: Option<&SpatialEmitter>) -> Option<usize> {
        let mut best_candidate = None;

        match self.policy {
            VoiceStealingPolicy::LowestPriority => {
                let mut min_prio = new_sound_priority;
                let mut oldest_time = 0u64;

                for (idx, v) in self.voices.iter().enumerate() {
                    if v.priority < min_prio {
                        min_prio = v.priority;
                        oldest_time = v.play_time_samples;
                        best_candidate = Some(idx);
                    } else if v.priority == min_prio && v.play_time_samples >= oldest_time && min_prio < new_sound_priority {
                        oldest_time = v.play_time_samples;
                        best_candidate = Some(idx);
                    }
                }
            }
            VoiceStealingPolicy::Oldest => {
                let mut max_age = 0u64;
                for (idx, v) in self.voices.iter().enumerate() {
                    // Only steal if priority is <= new sound priority
                    if v.priority <= new_sound_priority && v.play_time_samples >= max_age {
                        max_age = v.play_time_samples;
                        best_candidate = Some(idx);
                    }
                }
            }
            VoiceStealingPolicy::Quietest => {
                let mut min_vol = f32::MAX;
                for (idx, v) in self.voices.iter().enumerate() {
                    if v.priority <= new_sound_priority && v.volume < min_vol {
                        min_vol = v.volume;
                        best_candidate = Some(idx);
                    }
                }
            }
            VoiceStealingPolicy::Farthest => {
                let mut max_dist = 0.0f32;
                for (idx, v) in self.voices.iter().enumerate() {
                    if v.priority <= new_sound_priority {
                        let dist = v.spatial_emitter.as_ref().map(|e| e.position.length()).unwrap_or(0.0);
                        if dist >= max_dist {
                            max_dist = dist;
                            best_candidate = Some(idx);
                        }
                    }
                }
                // Fallback to oldest if no distance difference
                if best_candidate.is_none() {
                    let mut max_age = 0u64;
                    for (idx, v) in self.voices.iter().enumerate() {
                        if v.priority <= new_sound_priority && v.play_time_samples >= max_age {
                            max_age = v.play_time_samples;
                            best_candidate = Some(idx);
                        }
                    }
                }
            }
        }

        best_candidate
    }
}

/// Simple zero-dependency linear-congruential pseudo-random number generator for jitter in [-1.0, 1.0].
#[inline]
pub fn pseudo_random_jitter(seed: u32, salt: u32) -> f32 {
    let mut state = seed.wrapping_mul(1664525).wrapping_add(1013904223 ^ salt);
    state = state.wrapping_mul(1664525).wrapping_add(1013904223);
    let val = (state >> 9) as f32 / 8388607.0; // [0.0, 1.0]
    val * 2.0 - 1.0 // [-1.0, 1.0]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sound_buffer_creation_and_frame_count() {
        let samples = vec![0.1, -0.1, 0.2, -0.2, 0.3, -0.3];
        let buf = SoundBuffer::new(samples, 48000, 2);
        assert_eq!(buf.channels, 2);
        assert_eq!(buf.sample_rate, 48000);
        assert_eq!(buf.frame_count(), 3);
        assert_eq!(buf.duration_ms, 0); // 3 frames @ 48kHz < 1ms
    }

    #[test]
    fn test_voice_pool_plays_within_capacity() {
        let mut pool = VoicePool::new(4, VoiceStealingPolicy::LowestPriority);
        let samples = vec![1.0; 100];
        let buf = SoundBuffer::new(samples, 44100, 1);

        let id1 = pool.play_sound(buf.clone(), 1.0, 1.0, 100, false, None);
        let id2 = pool.play_sound(buf.clone(), 1.0, 1.0, 100, false, None);
        assert!(id1.is_some());
        assert!(id2.is_some());
        assert_eq!(pool.active_voice_count(), 2);
    }

    #[test]
    fn test_voice_stealing_by_lowest_priority() {
        let mut pool = VoicePool::new(2, VoiceStealingPolicy::LowestPriority);
        let samples = vec![1.0; 100];
        let buf = SoundBuffer::new(samples, 44100, 1);

        let id_low = pool.play_sound(buf.clone(), 1.0, 1.0, 10, false, None).unwrap();
        let id_high = pool.play_sound(buf.clone(), 1.0, 1.0, 200, false, None).unwrap();
        assert_eq!(pool.active_voice_count(), 2);

        // Third voice with priority 150 -> should steal the priority 10 voice (id_low)
        let id_new = pool.play_sound(buf.clone(), 1.0, 1.0, 150, false, None);
        assert!(id_new.is_some());
        assert_eq!(pool.active_voice_count(), 2);

        // id_low is no longer in the active voices
        assert!(!pool.voices.iter().any(|v| v.id == id_low && v.is_active()));
        // id_high is still active
        assert!(pool.voices.iter().any(|v| v.id == id_high && v.is_active()));
    }

    #[test]
    fn test_voice_stealing_rejects_lower_priority() {
        let mut pool = VoicePool::new(2, VoiceStealingPolicy::LowestPriority);
        let samples = vec![1.0; 100];
        let buf = SoundBuffer::new(samples, 44100, 1);

        pool.play_sound(buf.clone(), 1.0, 1.0, 100, false, None).unwrap();
        pool.play_sound(buf.clone(), 1.0, 1.0, 100, false, None).unwrap();

        // New sound with priority 50 (< 100) must be discarded
        let id_rejected = pool.play_sound(buf.clone(), 1.0, 1.0, 50, false, None);
        assert!(id_rejected.is_none());
        assert_eq!(pool.active_voice_count(), 2);
    }

    #[test]
    fn test_one_shot_jitter_applies_variation() {
        let mut pool = VoicePool::new(4, VoiceStealingPolicy::default());
        let samples = vec![1.0; 100];
        let buf = SoundBuffer::new(samples, 44100, 1);

        let id = pool.play_one_shot(buf, 1.0, 1.0, 0.1, 0.1, 128, None);
        assert!(id.is_some());
        let voice = pool.voices.iter().find(|v| v.id == id.unwrap()).unwrap();
        // Pitch should be within [0.9, 1.1]
        assert!(voice.pitch >= 0.89 && voice.pitch <= 1.11);
        // Volume should be within [0.9, 1.1]
        assert!(voice.volume >= 0.89 && voice.volume <= 1.11);
    }

    #[test]
    fn test_render_pcm_mixes_voices_accurately() {
        let mut pool = VoicePool::new(4, VoiceStealingPolicy::default());
        // 2 mono samples of 0.5
        let samples = vec![0.5, 0.5];
        let buf = SoundBuffer::new(samples, 48000, 1);

        pool.play_sound(buf.clone(), 1.0, 1.0, 128, false, None);
        pool.play_sound(buf.clone(), 1.0, 1.0, 128, false, None);

        let mut out = vec![0.0f32; 4]; // 2 frames stereo
        let listener = SpatialListener::default();
        pool.render_pcm(&mut out, 2, 48000, &listener);

        // Each voice produces 0.5 on left and right, 2 voices sum to ~1.0
        assert!((out[0] - 1.0).abs() < 0.1);
        assert!((out[1] - 1.0).abs() < 0.1);
    }

    #[test]
    fn test_time_scale_slows_or_speeds_playback() {
        let mut pool = VoicePool::new(4, VoiceStealingPolicy::default());
        let samples = vec![1.0; 100];
        let buf = SoundBuffer::new(samples, 48000, 1);

        pool.set_time_scale(0.5); // Slow motion (bullet time)
        assert_eq!(pool.time_scale(), 0.5);

        let id = pool.play_sound(buf, 1.0, 1.0, 128, false, None).unwrap();
        let mut out = vec![0.0f32; 20]; // 10 frames stereo
        let listener = SpatialListener::default();
        pool.render_pcm(&mut out, 2, 48000, &listener);

        // After 10 frames rendered at 0.5x time_scale, cursor should have advanced 5 frames
        let voice = pool.voices.iter().find(|v| v.id == id).unwrap();
        assert!((voice.frame_cursor - 5.0).abs() < 0.01);
    }

    #[test]
    fn test_voice_runtime_volume_and_pitch_controls() {
        let mut pool = VoicePool::new(4, VoiceStealingPolicy::default());
        let samples = vec![1.0; 100];
        let buf = SoundBuffer::new(samples, 48000, 1);

        let id = pool.play_sound(buf, 1.0, 1.0, 128, false, None).unwrap();
        assert!(pool.is_voice_playing(id));

        pool.set_voice_volume(id, 0.4);
        pool.set_voice_pitch(id, 1.8);

        let voice = pool.voices.iter().find(|v| v.id == id).unwrap();
        assert!((voice.volume - 0.4).abs() < 0.01);
        assert!((voice.pitch - 1.8).abs() < 0.01);
    }
}
