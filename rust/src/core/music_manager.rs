//! Music Stream & Queue Domain Manager (`MusicManager`).
//!
//! Encapsulates Deck A and Deck B streaming, Symphonia demuxing, StreamSession,
//! playlist/queue management, and atomic crossfading.

use std::sync::atomic::Ordering;

use crate::core::dual_source::{AudioSourceCore, DualSource, StreamingDeck};

/// Domain manager governing dual streaming decks (Deck A & Deck B), crossfading, and playback queue.
pub struct MusicManager {
    /// Underlying dual-deck engine instance.
    pub inner: DualSource,
    /// Preallocated scratch buffer for Deck A rendering.
    pub scratch_deck_a: Vec<f32>,
    /// Preallocated scratch buffer for Deck B rendering.
    pub scratch_deck_b: Vec<f32>,
    /// Preallocated scratch buffer for standby deck CUE monitoring.
    pub scratch_standby: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: usize,
}

impl MusicManager {
    /// Creates a new `MusicManager` initialized with the given sample rate and channels.
    pub fn new(sample_rate: u32, channels: u32, period_size: u32) -> Result<Self, String> {
        let sr = if sample_rate > 0 { sample_rate } else { 44100 };
        let ch = if channels > 0 { channels as usize } else { 2 };
        let period = if period_size > 0 { period_size } else { 1024 };

        let inner = DualSource::new(sr, ch as u32, period)
            .map_err(|e| format!("Failed to create DualSource: error {}", e))?;

        let max_samples = period as usize * ch * 2;

        Ok(Self {
            inner,
            scratch_deck_a: vec![0.0; max_samples],
            scratch_deck_b: vec![0.0; max_samples],
            scratch_standby: vec![0.0; max_samples],
            sample_rate: sr,
            channels: ch,
        })
    }

    // =========================================================================
    // Direct Music Commands
    // =========================================================================

    /// Sets the custom byte source factory for Dart stream callbacks.
    #[inline]
    pub fn set_custom_source_factory(&mut self, factory: crate::core::dual_source::CustomSourceFactory) {
        self.inner.custom_source_factory = Some(factory);
    }

    /// Sets the unified asynchronous Dart source resolver bridge.
    #[inline]
    pub fn set_dart_resolver(&mut self, resolver: std::sync::Arc<crate::buffer::DartResolveRegistry>) {
        self.inner.dart_resolver = Some(resolver);
    }

    /// Appends audio sources to the end of the playlist queue.
    #[inline]
    pub fn append(&mut self, sources: Vec<AudioSourceCore>) {
        self.inner.append_items(sources);
    }

    /// Inserts an audio source directly after the currently playing item.
    #[inline]
    pub fn insert_next(&mut self, source: AudioSourceCore) {
        self.inner.insert_next_item(source);
    }

    /// Reorders a playlist item from `old_index` to `new_index`.
    #[inline]
    pub fn reorder(&mut self, old_index: usize, new_index: usize) -> bool {
        self.inner.reorder_item(old_index, new_index)
    }

    /// Reorders playlist queue according to the given array of source identifiers.
    #[inline]
    pub fn reorder_by_ids(&mut self, ids: &[i64]) -> bool {
        self.inner.reorder_by_ids(ids)
    }

    /// Clears the playlist queue, optionally retaining the currently playing item.
    #[inline]
    pub fn clear_queue(&mut self, keep_current: bool) {
        self.inner.clear_items(keep_current);
    }

    /// Pauses music playback across active decks.
    #[inline]
    pub fn pause(&mut self) {
        self.inner.pause();
    }

    /// Stops music playback and resets playback positions.
    #[inline]
    pub fn stop(&mut self) {
        self.inner.stop();
    }

    /// Seeks the active music deck to `position_ms`.
    #[inline]
    pub fn seek(&mut self, position_ms: i64) -> Result<(), String> {
        let res = self.inner.seek(position_ms);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("Seek failed: code {}", res))
        }
    }

    /// Updates playlist looping mode (`0 = Off`, `1 = One`, `2 = All`).
    #[inline]
    pub fn set_loop_mode(&mut self, mode: i32) {
        self.inner.set_loop_mode(mode);
    }

    /// Enables or disables playlist shuffle order.
    #[inline]
    pub fn set_shuffle(&mut self, enabled: bool) {
        self.inner.set_shuffle(enabled);
    }

    /// Configures automatic and manual crossfade durations and curve profile.
    #[inline]
    pub fn set_crossfade(&mut self, duration_ms: u64, manual_ms: u64, curve: i32) {
        self.inner.set_crossfade(duration_ms, manual_ms, curve);
    }

    /// Returns the current playback speed rate.
    #[inline]
    pub fn rate(&self) -> f32 {
        f32::from_bits(self.inner.deck_a.rate.load(std::sync::atomic::Ordering::Relaxed))
    }

    /// Returns the current playback pitch shift multiplier.
    #[inline]
    pub fn pitch(&self) -> f32 {
        f32::from_bits(self.inner.deck_a.pitch.load(std::sync::atomic::Ordering::Relaxed))
    }

    /// Returns whether playlist shuffle is enabled.
    #[inline]
    pub fn is_shuffled(&self) -> bool {
        self.inner.shuffle_enabled.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Sets playback speed rate across active decks.
    #[inline]
    pub fn set_rate(&mut self, rate: f32) {
        self.inner.deck_a.set_rate(rate);
        self.inner.deck_b.set_rate(rate);
    }

    /// Sets pitch shift multiplier across active decks.
    #[inline]
    pub fn set_pitch(&mut self, pitch: f32) {
        self.inner.deck_a.set_pitch(pitch);
        self.inner.deck_b.set_pitch(pitch);
    }

    /// Sets music volume multiplier across active decks.
    #[inline]
    pub fn set_volume(&mut self, volume: f32) {
        self.inner.deck_a.set_volume(volume);
        self.inner.deck_b.set_volume(volume);
    }

    // =========================================================================
    // Real-Time Audio Rendering
    // =========================================================================

    /// Renders the fused/crossfaded music stream into `output`.
    pub fn render(&mut self, frame_count: usize, output: &mut [f32]) {
        let sample_count = frame_count * self.channels;
        output.fill(0.0);

        let active_slot = self.inner.active_deck.load(Ordering::Relaxed);
        let is_xfading = self.inner.crossfade.is_active();

        if self.scratch_deck_a.len() < sample_count {
            self.scratch_deck_a.resize(sample_count, 0.0);
            self.scratch_deck_b.resize(sample_count, 0.0);
            self.scratch_standby.resize(sample_count, 0.0);
        }

        self.scratch_deck_a[..sample_count].fill(0.0);
        self.scratch_deck_b[..sample_count].fill(0.0);

        self.inner.deck_a.render_pcm(self.scratch_deck_a.as_mut_ptr(), frame_count);
        self.inner.deck_b.render_pcm(self.scratch_deck_b.as_mut_ptr(), frame_count);

        if is_xfading {
            let is_playing = crate::core::PlaybackState::from_i32(
                self.inner.playback_state.load(Ordering::Relaxed),
            ) == crate::core::PlaybackState::Playing;
            let (gain_a, gain_b) = if is_playing {
                let gains = self.inner.crossfade.advance_and_get_gains(frame_count as u64);
                if !self.inner.crossfade.is_active() {
                    self.inner.crossfade_completed_flag.store(true, Ordering::Release);
                }
                gains
            } else {
                self.inner.crossfade.current_gains()
            };

            for i in 0..sample_count {
                output[i] = self.scratch_deck_a[i] * gain_a + self.scratch_deck_b[i] * gain_b;
            }

            // Expose the outgoing deck to standby scratch for CUE
            if active_slot == 0 {
                self.scratch_standby[..sample_count].copy_from_slice(&self.scratch_deck_b[..sample_count]);
            } else {
                self.scratch_standby[..sample_count].copy_from_slice(&self.scratch_deck_a[..sample_count]);
            }
        } else {
            if active_slot == 0 {
                output[..sample_count].copy_from_slice(&self.scratch_deck_a[..sample_count]);
                self.scratch_standby[..sample_count].copy_from_slice(&self.scratch_deck_b[..sample_count]);
            } else {
                output[..sample_count].copy_from_slice(&self.scratch_deck_b[..sample_count]);
                self.scratch_standby[..sample_count].copy_from_slice(&self.scratch_deck_a[..sample_count]);
            }
        }
    }

    /// Returns an immutable slice to the standby CUE monitoring buffer.
    #[inline]
    pub fn standby_buffer(&self) -> &[f32] {
        &self.scratch_standby
    }

    /// Returns an immutable slice to the active deck rendered audio buffer.
    #[inline]
    pub fn active_deck_buffer(&self) -> &[f32] {
        if self.inner.active_deck.load(Ordering::Relaxed) == 0 {
            &self.scratch_deck_a
        } else {
            &self.scratch_deck_b
        }
    }

    // =========================================================================
    // State Accessors
    // =========================================================================

    /// Returns a reference to the active foreground streaming deck.
    #[inline]
    pub fn active_deck_ref(&self) -> &StreamingDeck {
        self.inner.active_deck_ref()
    }

    /// Returns a mutable reference to the active foreground streaming deck.
    #[inline]
    pub fn active_deck_mut(&mut self) -> &mut StreamingDeck {
        self.inner.active_deck_mut()
    }

    /// Returns the currently active playlist queue index.
    #[inline]
    pub fn current_index(&self) -> i64 {
        self.inner.current_index.load(Ordering::Relaxed)
    }

    /// Returns whether an atomic crossfade is currently in progress.
    #[inline]
    pub fn is_crossfading(&self) -> bool {
        self.inner.crossfade.is_active()
    }

    /// Destroys and cleans up both streaming decks.
    pub fn dispose(&mut self) {
        self.inner.deck_a.destroy();
        self.inner.deck_b.destroy();
    }
}
