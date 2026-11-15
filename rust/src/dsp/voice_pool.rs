//! Pre-decoded PCM sound buffer (`SoundBuffer`), voice stealing policy (`VoiceStealingPolicy`),
//! and pseudo-random jitter generation for the polyphonic SFX voice pool.

use std::sync::Arc;

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

    /// Resolves wrapped interpolation frame indices `(frame_0, frame_1, frac)` for `cursor`.
    ///
    /// Returns `None` when `total_frames == 0` or a non-looping cursor reaches end-of-buffer.
    #[inline]
    pub fn resolve_lerp_indices(
        cursor: &mut f64,
        total_frames: usize,
        looping: bool,
    ) -> Option<(usize, usize, f32)> {
        if total_frames == 0 {
            return None;
        }
        if !cursor.is_finite() || *cursor < 0.0 {
            *cursor = 0.0;
        }
        if *cursor >= total_frames as f64 {
            if looping {
                *cursor %= total_frames as f64;
                if !cursor.is_finite() || *cursor >= total_frames as f64 {
                    *cursor = 0.0;
                }
            } else {
                return None;
            }
        }
        let f0 = (cursor.floor() as usize).min(total_frames - 1);
        let f1 = if f0 + 1 < total_frames {
            f0 + 1
        } else if looping {
            0
        } else {
            total_frames - 1
        };
        let frac = (*cursor - f0 as f64).clamp(0.0, 1.0) as f32;
        Some((f0, f1, frac))
    }

    /// Samples left and right channels at `frame_0` and `frame_1` with fractional linear interpolation `frac`.
    #[inline]
    pub fn sample_stereo_lerp(&self, frame_0: usize, frame_1: usize, frac: f32) -> (f32, f32) {
        let max_frame = self.frame_count();
        if max_frame == 0 {
            return (0.0, 0.0);
        }
        let f0 = frame_0.min(max_frame - 1);
        let f1 = frame_1.min(max_frame - 1);
        if self.channels == 1 {
            let s0 = self.samples[f0];
            let s1 = self.samples[f1];
            let val = s0 + frac * (s1 - s0);
            (val, val)
        } else {
            let ch = self.channels;
            let s0_l = self.samples[f0 * ch];
            let s0_r = self.samples[f0 * ch + 1];
            let s1_l = self.samples[f1 * ch];
            let s1_r = self.samples[f1 * ch + 1];
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

/// Linear-congruential pseudo-random number generator for jitter in `[-1.0, 1.0]`.
#[inline]
pub fn pseudo_random_jitter(seed: u32, salt: u32) -> f32 {
    let mut state = seed.wrapping_mul(1664525).wrapping_add(1013904223 ^ salt);
    state = state.wrapping_mul(1664525).wrapping_add(1013904223);
    let val = (state >> 9) as f32 / 8388607.0;
    val * 2.0 - 1.0
}
