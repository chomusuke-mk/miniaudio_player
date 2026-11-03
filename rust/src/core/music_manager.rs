//! Music Stream & Queue Domain Manager (`MusicManager`).
//!
//! Encapsulates Deck A and Deck B streaming, Symphonia demuxing, TripartiteBuffer,
//! playlist/queue management, and atomic crossfading.

use std::sync::atomic::Ordering;

use crate::core::dual_source::{AudioSourceCore, DualSource, StreamingDeck};

pub struct MusicManager {
    pub inner: DualSource,
    pub scratch_deck_a: Vec<f32>,
    pub scratch_deck_b: Vec<f32>,
    pub scratch_standby: Vec<f32>,
    pub sample_rate: u32,
    pub channels: usize,
}

impl MusicManager {
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

    #[inline]
    pub fn open(&mut self, queue: Vec<AudioSourceCore>, start_index: usize, auto_play: bool) -> Result<(), String> {
        self.inner.open_queue(queue, start_index, auto_play)
    }

    #[inline]
    pub fn set_custom_source_factory(&mut self, factory: crate::core::dual_source::CustomSourceFactory) {
        self.inner.custom_source_factory = Some(factory);
    }

    #[inline]
    pub fn append(&mut self, sources: Vec<AudioSourceCore>) {
        self.inner.append_items(sources);
    }

    #[inline]
    pub fn insert_next(&mut self, source: AudioSourceCore) {
        self.inner.insert_next_item(source);
    }

    #[inline]
    pub fn remove_at(&mut self, index: usize) -> Option<AudioSourceCore> {
        self.inner.remove_item_at(index)
    }

    #[inline]
    pub fn reorder(&mut self, old_index: usize, new_index: usize) -> bool {
        self.inner.reorder_item(old_index, new_index)
    }

    #[inline]
    pub fn clear_queue(&mut self, keep_current: bool) {
        self.inner.clear_items(keep_current);
    }

    #[inline]
    pub fn next(&mut self, manual_crossfade_ms: Option<u64>) -> Result<(), String> {
        self.inner.next(manual_crossfade_ms)
    }

    #[inline]
    pub fn previous(&mut self) -> Result<(), String> {
        self.inner.previous()
    }

    #[inline]
    pub fn skip_to_index(&mut self, index: usize, crossfade_ms: Option<u64>) -> Result<(), String> {
        self.inner.skip_to_index(index, crossfade_ms)
    }

    #[inline]
    pub fn play(&mut self) -> Result<(), String> {
        let res = self.inner.play();
        if res == 0 {
            Ok(())
        } else {
            Err(format!("Play failed: code {}", res))
        }
    }

    #[inline]
    pub fn pause(&mut self) {
        self.inner.pause();
    }

    #[inline]
    pub fn stop(&mut self) {
        self.inner.stop();
    }

    #[inline]
    pub fn seek(&mut self, position_ms: i64) -> Result<(), String> {
        let res = self.inner.seek(position_ms);
        if res == 0 {
            Ok(())
        } else {
            Err(format!("Seek failed: code {}", res))
        }
    }

    #[inline]
    pub fn set_loop_mode(&mut self, mode: i32) {
        self.inner.set_loop_mode(mode);
    }

    #[inline]
    pub fn set_shuffle(&mut self, enabled: bool) {
        self.inner.set_shuffle(enabled);
    }

    #[inline]
    pub fn set_crossfade(&mut self, duration_ms: u64, manual_ms: u64, curve: i32) {
        self.inner.set_crossfade(duration_ms, manual_ms, curve);
    }

    #[inline]
    pub fn rate(&self) -> f32 {
        f32::from_bits(self.inner.deck_a.rate.load(std::sync::atomic::Ordering::Relaxed))
    }

    #[inline]
    pub fn pitch(&self) -> f32 {
        f32::from_bits(self.inner.deck_a.pitch.load(std::sync::atomic::Ordering::Relaxed))
    }

    #[inline]
    pub fn is_shuffled(&self) -> bool {
        self.inner.shuffle_enabled.load(std::sync::atomic::Ordering::Relaxed)
    }

    #[inline]
    pub fn set_rate(&mut self, rate: f32) {
        self.inner.deck_a.set_rate(rate);
        self.inner.deck_b.set_rate(rate);
    }

    #[inline]
    pub fn set_pitch(&mut self, pitch: f32) {
        self.inner.deck_a.set_pitch(pitch);
        self.inner.deck_b.set_pitch(pitch);
    }

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
        let is_xfading = self.inner.crossfade.is_active.load(Ordering::Relaxed);

        if self.scratch_deck_a.len() < sample_count {
            self.scratch_deck_a.resize(sample_count, 0.0);
            self.scratch_deck_b.resize(sample_count, 0.0);
            self.scratch_standby.resize(sample_count, 0.0);
        }

        self.scratch_deck_a[..sample_count].fill(0.0);
        self.scratch_deck_b[..sample_count].fill(0.0);

        unsafe {
            if !self.inner.deck_a.renderer_ptr.is_null() {
                let rend_a = &mut *self.inner.deck_a.renderer_ptr;
                rend_a.render_pcm(self.scratch_deck_a.as_mut_ptr(), frame_count);
            }
            if !self.inner.deck_b.renderer_ptr.is_null() {
                let rend_b = &mut *self.inner.deck_b.renderer_ptr;
                rend_b.render_pcm(self.scratch_deck_b.as_mut_ptr(), frame_count);
            }
        }

        if is_xfading {
            let (gain_a, gain_b) = self.inner.crossfade.advance_and_get_gains(frame_count as u64);

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

    #[inline]
    pub fn standby_buffer(&self) -> &[f32] {
        &self.scratch_standby
    }

    // =========================================================================
    // State Accessors
    // =========================================================================

    #[inline]
    pub fn active_deck_ref(&self) -> &StreamingDeck {
        self.inner.active_deck_ref()
    }

    #[inline]
    pub fn active_deck_mut(&mut self) -> &mut StreamingDeck {
        self.inner.active_deck_mut()
    }

    #[inline]
    pub fn current_index(&self) -> i64 {
        self.inner.current_index.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn is_crossfading(&self) -> bool {
        self.inner.crossfade.is_active.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn queue_items(&self) -> Vec<AudioSourceCore> {
        self.inner.queue.read().unwrap().clone()
    }

    pub fn dispose(&mut self) {
        self.inner.deck_a.destroy();
        self.inner.deck_b.destroy();
    }
}
