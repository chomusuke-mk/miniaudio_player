//! Lock-free dynamic Voice Pool and Voice Stealing subsystem for video games and sound design.
//!
//! Provides ultra-low-latency polyphonic sound playback with:
//! - Fixed pre-allocated voice array (zero heap allocations in render loop).
//! - Voice Stealing policies: Oldest, LowestPriority, Quietest, Farthest (listener-relative).
//! - Anti-click 5 ms quick-fadeout when stopping active voices.
//! - Pitch/volume jitter for one-shot audio triggers (preventing machine-gun effect).
//! - 3D Spatial Audio & Doppler integration per voice.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use super::spatial::{SpatialEmitter, SpatialListener, SpatialProcessor, Vector3};

/// Maximum concurrent voices rendered simultaneously in a single voice pool.
pub const DEFAULT_MAX_VOICES: usize = 64;

/// Pre-decoded PCM audio buffer in memory, shared across multiple voices with zero copies.
#[derive(Debug, Clone)]
pub struct SoundBuffer {
    /// Shared reference to interleaved float PCM audio samples.
    pub samples: Arc<[f32]>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: usize,
    /// Total duration in milliseconds.
    pub duration_ms: u64,
}

impl SoundBuffer {
    /// Creates a new sound buffer from raw PCM samples, sample rate, and channel count.
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

    /// Decodes an audio file in memory (MP3, WAV, FLAC, OGG, AAC) into a `SoundBuffer`.
    pub fn decode_from_bytes(bytes: &[u8]) -> Result<Self, String> {
        use crate::decoder::classifier::StreamClassifier;
        use crate::decoder::symphonia_engine::SymphoniaEngine;
        use std::io::Cursor;

        if bytes.is_empty() {
            return Err("Cannot decode sound buffer from empty byte slice".to_string());
        }

        let (_status, boundary) = StreamClassifier::detect_head_boundary(bytes, bytes.len() as i64);
        let hint = boundary.container.hint_extension();

        let cursor = Cursor::new(bytes.to_vec());
        let mut engine = SymphoniaEngine::new(cursor, hint)
            .map_err(|e| format!("Failed to probe audio format: {:?}", e))?;

        let sr = engine.sample_rate();
        let ch = engine.channels() as usize;
        let mut pcm = Vec::with_capacity(32768);
        let mut packet_pcm = Vec::with_capacity(4096);

        while engine
            .decode_next_frame(&mut packet_pcm)
            .map_err(|e| format!("Decoding error: {:?}", e))?
        {
            pcm.extend_from_slice(&packet_pcm);
        }

        if pcm.is_empty() {
            return Err("Decoded audio stream contained zero PCM frames".to_string());
        }

        Ok(Self::new(pcm, sr, ch))
    }

    /// Returns the total number of audio frames in the buffer.
    #[inline]
    pub fn frame_count(&self) -> usize {
        if self.channels > 0 {
            self.samples.len() / self.channels
        } else {
            0
        }
    }

    /// Samples left and right channels at `frame_0` and `frame_1` with fractional linear interpolation `frac`.
    #[inline]
    pub fn sample_stereo_lerp(&self, frame_0: usize, frame_1: usize, frac: f32) -> (f32, f32) {
        if self.channels == 1 {
            let s0 = self.samples[frame_0];
            let s1 = self.samples[frame_1];
            let val = s0 + frac * (s1 - s0);
            (val, val)
        } else {
            let ch = self.channels;
            let s0_l = self.samples[frame_0 * ch];
            let s0_r = self.samples[frame_0 * ch + 1];
            let s1_l = self.samples[frame_1 * ch];
            let s1_r = self.samples[frame_1 * ch + 1];
            (s0_l + frac * (s1_l - s0_l), s0_r + frac * (s1_r - s0_r))
        }
    }
}

/// Eviction policy used when all voices in the pool are active.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VoiceStealingPolicy {
    /// Steals the voice with the lowest priority value.
    #[default]
    LowestPriority,
    /// Steals the voice that has been playing the longest.
    Oldest,
    /// Steals the voice with the quietest effective volume.
    Quietest,
    /// Steals the voice located farthest from the listener.
    Farthest,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum VoiceState {
    Stopped,
    Playing,
    FadingOut { current_gain: f32, gain_step: f32 },
}

/// A single polyphonic audio voice with encapsulated state and rendering logic.
#[derive(Clone)]
pub struct DspVoice {
    /// Unique identifier of the currently playing voice.
    pub id: u32,
    /// Pre-decoded PCM sound buffer.
    pub buffer: Option<SoundBuffer>,
    /// Fractional playback frame position.
    pub frame_cursor: f64,
    /// Playback volume multiplier.
    pub volume: f32,
    /// Playback pitch multiplier.
    pub pitch: f32,
    /// Eviction priority (0 = lowest, 255 = highest).
    pub priority: u8,
    /// Whether the voice loops when reaching the end of the sound buffer.
    pub looping: bool,
    /// Optional 3D spatial emitter parameters.
    pub spatial_emitter: Option<SpatialEmitter>,
    /// Spatial processor instance for smoothing and 3D calculations.
    pub spatial_processor: SpatialProcessor,
    /// Age in rendered output frames since activation.
    pub play_time_samples: u64,
    state: VoiceState,
}

impl Default for DspVoice {
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

impl DspVoice {
    /// Returns whether the voice is active (either playing or fading out).
    #[inline]
    pub fn is_active(&self) -> bool {
        self.state != VoiceState::Stopped
    }

    /// Returns whether the voice is currently in the active playing state (not fading out).
    #[inline]
    pub fn is_playing(&self) -> bool {
        self.state == VoiceState::Playing
    }

    /// Activates this voice slot with the specified sound buffer and playback parameters.
    pub fn activate(
        &mut self,
        voice_id: u32,
        buffer: SoundBuffer,
        volume: f32,
        pitch: f32,
        priority: u8,
        looping: bool,
        emitter: Option<SpatialEmitter>,
    ) {
        self.id = voice_id;
        self.buffer = Some(buffer);
        self.frame_cursor = 0.0;
        self.volume = volume;
        self.pitch = pitch;
        self.priority = priority;
        self.looping = looping;
        self.spatial_emitter = emitter;
        self.spatial_processor = SpatialProcessor::default();
        self.play_time_samples = 0;
        self.state = VoiceState::Playing;
    }

    /// Starts a 5 ms anti-click quick fade-out ramp before stopping.
    pub fn quick_fadeout(&mut self, sample_rate: u32) {
        if self.state == VoiceState::Playing {
            let fade_frames = (sample_rate as f32 * 0.005).max(1.0);
            self.state = VoiceState::FadingOut {
                current_gain: 1.0,
                gain_step: 1.0 / fade_frames,
            };
        }
    }

    /// Immediately stops the voice and releases its sound buffer.
    pub fn stop(&mut self) {
        self.state = VoiceState::Stopped;
        self.buffer = None;
        self.frame_cursor = 0.0;
        self.play_time_samples = 0;
    }

    #[inline]
    fn next_fade_gain(&mut self) -> Option<f32> {
        match self.state {
            VoiceState::Playing => Some(1.0),
            VoiceState::FadingOut {
                ref mut current_gain,
                gain_step,
            } => {
                let g = *current_gain;
                *current_gain = (*current_gain - gain_step).max(0.0);
                if *current_gain <= 0.0 {
                    self.stop();
                    None
                } else {
                    Some(g)
                }
            }
            VoiceState::Stopped => None,
        }
    }

    fn compute_spatial_params(
        &self,
        out_channels: usize,
        listener: &SpatialListener,
    ) -> (f32, f32, f32, f32) {
        if let Some(ref em) = self.spatial_emitter {
            let eval =
                SpatialProcessor::evaluate(listener, em, self.spatial_processor.speed_of_sound);
            let (pan_l, pan_r) = if out_channels >= 2 {
                let p = eval.pan.clamp(-1.0, 1.0);
                (((1.0 - p) * 0.5).sqrt(), ((1.0 + p) * 0.5).sqrt())
            } else {
                (1.0, 1.0)
            };
            (eval.gain, pan_l, pan_r, eval.doppler_ratio)
        } else {
            (1.0, 1.0, 1.0, 1.0)
        }
    }

    /// Renders audio frames from this voice into the output buffer with spatial mixing.
    pub fn render_into(
        &mut self,
        out_buffer: &mut [f32],
        out_channels: usize,
        out_sample_rate: u32,
        master_vol: f32,
        time_scale: f32,
        listener: &SpatialListener,
    ) {
        if !self.is_active() {
            return;
        }
        let Some(sound) = self.buffer.clone() else {
            self.stop();
            return;
        };
        let src_frames = sound.frame_count();
        if src_frames == 0 {
            self.stop();
            return;
        }

        let (spatial_gain, pan_l, pan_r, doppler) =
            self.compute_spatial_params(out_channels, listener);
        let speed_ratio = (self.pitch * doppler * time_scale) as f64
            * (sound.sample_rate as f64 / out_sample_rate as f64);
        let base_vol = self.volume * spatial_gain * master_vol;
        let num_frames = out_buffer.len() / out_channels;

        for frame_idx in 0..num_frames {
            let Some(fade_gain) = self.next_fade_gain() else {
                break;
            };

            let cur_frame = self.frame_cursor;
            let frame_0 = cur_frame.floor() as usize;
            let frac = (cur_frame - frame_0 as f64) as f32;

            if frame_0 >= src_frames {
                if self.looping {
                    self.frame_cursor = 0.0;
                    continue;
                } else {
                    self.stop();
                    break;
                }
            }

            let frame_1 = if frame_0 + 1 < src_frames {
                frame_0 + 1
            } else if self.looping {
                0
            } else {
                frame_0
            };

            let (src_l, src_r) = sound.sample_stereo_lerp(frame_0, frame_1, frac);
            let eff_l = src_l * base_vol * fade_gain;
            let eff_r = src_r * base_vol * fade_gain;

            let out_offset = frame_idx * out_channels;
            if out_channels == 1 {
                out_buffer[out_offset] += (eff_l + eff_r) * 0.5;
            } else {
                out_buffer[out_offset] += eff_l * pan_l;
                out_buffer[out_offset + 1] += eff_r * pan_r;
            }

            self.frame_cursor += speed_ratio;
            self.play_time_samples += 1;
        }
    }
}

/// A single polyphonic audio voice with encapsulated state and rendering logic.
pub type Voice = DspVoice;

/// Dynamic Voice Pool managing polyphonic voice recycling, stealing, and spatial mixing.
pub type VoicePool = DspVoicePool;

/// Dynamic Voice Pool managing polyphonic voice recycling, stealing, and spatial mixing.
pub struct DspVoicePool {
    voices: Vec<DspVoice>,
    policy: VoiceStealingPolicy,
    next_voice_id: AtomicU32,
    master_volume: f32,
    time_scale: f32,
    listener_position: Vector3,
}

impl Default for DspVoicePool {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_VOICES, VoiceStealingPolicy::default())
    }
}

impl DspVoicePool {
    /// Creates a new `DspVoicePool` with the specified capacity and stealing policy.
    pub fn new(capacity: usize, policy: VoiceStealingPolicy) -> Self {
        let cap = capacity.clamp(1, 256);
        Self {
            voices: vec![DspVoice::default(); cap],
            policy,
            next_voice_id: AtomicU32::new(1),
            master_volume: 1.0,
            time_scale: 1.0,
            listener_position: Vector3::new(0.0, 0.0, 0.0),
        }
    }

    /// Returns the maximum number of concurrent voice slots allocated.
    #[inline]
    pub fn capacity(&self) -> usize {
        self.voices.len()
    }

    /// Returns the count of currently active voices.
    pub fn active_voice_count(&self) -> usize {
        self.voices.iter().filter(|v| v.is_active()).count()
    }

    /// Updates the voice stealing eviction policy.
    pub fn set_policy(&mut self, policy: VoiceStealingPolicy) {
        self.policy = policy;
    }

    /// Sets the master volume multiplier applied to all voices `[0.0, 2.0]`.
    pub fn set_master_volume(&mut self, volume: f32) {
        self.master_volume = volume.clamp(0.0, 2.0);
    }

    /// Sets the global time scale multiplier for game sound effects `[0.01, 10.0]`.
    pub fn set_time_scale(&mut self, scale: f32) {
        self.time_scale = scale.clamp(0.01, 10.0);
    }

    /// Returns the current global time scale multiplier.
    #[inline]
    pub fn time_scale(&self) -> f32 {
        self.time_scale
    }

    /// Sets the playback volume for an active voice.
    pub fn set_voice_volume(&mut self, voice_id: u32, volume: f32) {
        if let Some(v) = self
            .voices
            .iter_mut()
            .find(|v| v.id == voice_id && v.is_active())
        {
            if volume.is_finite() {
                v.volume = volume.max(0.0);
            }
        }
    }

    /// Sets the pitch multiplier for an active voice.
    pub fn set_voice_pitch(&mut self, voice_id: u32, pitch: f32) {
        if let Some(v) = self
            .voices
            .iter_mut()
            .find(|v| v.id == voice_id && v.is_active())
        {
            if pitch.is_finite() && pitch > 0.0 {
                v.pitch = pitch;
            }
        }
    }

    /// Sets or updates the 3D spatial emitter for an active voice.
    pub fn set_voice_emitter(&mut self, voice_id: u32, emitter: Option<SpatialEmitter>) {
        if let Some(v) = self
            .voices
            .iter_mut()
            .find(|v| v.id == voice_id && v.is_active())
        {
            v.spatial_emitter = emitter;
        }
    }

    /// Checks whether the specified voice is currently playing or fading out.
    pub fn is_voice_playing(&self, voice_id: u32) -> bool {
        self.voices
            .iter()
            .any(|v| v.id == voice_id && v.is_active())
    }

    /// Attempts to play a sound assigning a specific caller-provided `voice_id`.
    ///
    /// If all voice slots are busy, steals a voice according to [`VoiceStealingPolicy`].
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
        if let Some(idx) = self.voices.iter().position(|v| !v.is_active()) {
            self.voices[idx].activate(voice_id, buffer, volume, pitch, priority, looping, emitter);
            return true;
        }

        if let Some(victim_idx) = self.find_victim_voice(priority) {
            self.voices[victim_idx].stop();
            self.voices[victim_idx]
                .activate(voice_id, buffer, volume, pitch, priority, looping, emitter);
            return true;
        }

        false
    }

    /// Plays a sound in an available voice slot, returning the assigned voice ID.
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

    /// Plays a one-shot sound with randomized pitch and volume jitter.
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
        let seed = self.next_voice_id.load(Ordering::Relaxed);
        let eff_pitch = if pitch_jitter > 0.0 {
            pitch * (1.0 + pseudo_random_jitter(seed, 1) * pitch_jitter.abs())
        } else {
            pitch
        };

        let eff_vol = if volume_jitter > 0.0 {
            volume * (1.0 + pseudo_random_jitter(seed, 2) * volume_jitter.abs())
        } else {
            volume
        };

        self.play_sound(
            buffer,
            eff_vol.max(0.0),
            eff_pitch.max(0.001),
            priority,
            false,
            emitter,
        )
    }

    /// Initiates a quick anti-click fadeout for the specified voice.
    pub fn stop_voice(&mut self, voice_id: u32, sample_rate: u32) {
        if let Some(v) = self.voices.iter_mut().find(|v| v.id == voice_id) {
            v.quick_fadeout(sample_rate);
        }
    }

    /// Immediately stops all playing voices in the pool.
    pub fn stop_all(&mut self) {
        for v in &mut self.voices {
            v.stop();
        }
    }

    /// Returns a reference to the voice with the given ID if found.
    pub fn get_voice(&self, voice_id: u32) -> Option<&DspVoice> {
        self.voices.iter().find(|v| v.id == voice_id)
    }

    /// Renders and mixes all active voices into the destination interleaved float PCM buffer.
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
        self.listener_position = listener.position;
        let master_vol = self.master_volume;
        let time_scale = self.time_scale;

        for voice in &mut self.voices {
            voice.render_into(
                out_buffer,
                out_channels,
                out_sample_rate,
                master_vol,
                time_scale,
                listener,
            );
        }
    }

    fn find_victim_voice(&self, new_sound_priority: u8) -> Option<usize> {
        match self.policy {
            VoiceStealingPolicy::LowestPriority => self.select_lowest_priority(new_sound_priority),
            VoiceStealingPolicy::Oldest => self.select_oldest(new_sound_priority),
            VoiceStealingPolicy::Quietest => self.select_quietest(new_sound_priority),
            VoiceStealingPolicy::Farthest => self
                .select_farthest(new_sound_priority)
                .or_else(|| self.select_oldest(new_sound_priority)),
        }
    }

    fn select_lowest_priority(&self, new_sound_priority: u8) -> Option<usize> {
        let mut best_candidate = None;
        let mut min_prio = new_sound_priority;
        let mut oldest_time = 0u64;

        for (idx, v) in self.voices.iter().enumerate() {
            if v.priority < min_prio {
                min_prio = v.priority;
                oldest_time = v.play_time_samples;
                best_candidate = Some(idx);
            } else if v.priority == min_prio
                && min_prio < new_sound_priority
                && v.play_time_samples >= oldest_time
            {
                oldest_time = v.play_time_samples;
                best_candidate = Some(idx);
            }
        }
        best_candidate
    }

    fn select_oldest(&self, new_sound_priority: u8) -> Option<usize> {
        let mut best_candidate = None;
        let mut max_age = 0u64;
        for (idx, v) in self.voices.iter().enumerate() {
            if v.priority <= new_sound_priority && v.play_time_samples >= max_age {
                max_age = v.play_time_samples;
                best_candidate = Some(idx);
            }
        }
        best_candidate
    }

    fn select_quietest(&self, new_sound_priority: u8) -> Option<usize> {
        let mut best_candidate = None;
        let mut min_vol = f32::MAX;
        for (idx, v) in self.voices.iter().enumerate() {
            if v.priority <= new_sound_priority && v.volume < min_vol {
                min_vol = v.volume;
                best_candidate = Some(idx);
            }
        }
        best_candidate
    }

    fn select_farthest(&self, new_sound_priority: u8) -> Option<usize> {
        let mut best_candidate = None;
        let mut max_dist = 0.0f32;
        for (idx, v) in self.voices.iter().enumerate() {
            if v.priority <= new_sound_priority {
                let dist = v
                    .spatial_emitter
                    .as_ref()
                    .map(|e| e.position.sub(&self.listener_position).length())
                    .unwrap_or(0.0);
                if dist > max_dist {
                    max_dist = dist;
                    best_candidate = Some(idx);
                }
            }
        }
        best_candidate
    }
}

/// Linear-congruential pseudo-random number generator for jitter in `[-1.0, 1.0]`.
#[inline]
pub fn pseudo_random_jitter(seed: u32, salt: u32) -> f32 {
    let mut state = seed.wrapping_mul(1664525).wrapping_add(1013904223 ^ salt);
    state = state.wrapping_mul(1664525).wrapping_add(1013904223);
    let val = (state >> 9) as f32 / 8388607.0;
    val * 2.0 - 1.0
}
