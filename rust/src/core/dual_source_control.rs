//! Control-plane transition planning, prepared-deck DSP transfer, and RT swap helpers.
//!
//! Separates non-blocking queue/transition planning (`plan_play`, `plan_next`, `plan_previous`),
//! DSP template/overlay capture and silent application, and deterministic deck commit swaps
//! from off-thread I/O decoding.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::buffer::DartResolveRegistry;
use crate::core::dual_source::{
    resolve_replay_gain, AudioSourceCore, CustomSourceFactory, DualSource, StreamingDeck,
};
use crate::core::renderer::DspCommand;
use crate::core::types::{PlaybackState, QueueTransition};
use crate::dsp::crossfeed::CrossfeedConfig;
use crate::dsp::equalizer::EqualizerParams;
use crate::dsp::reverb::ReverbConfig;
use crate::dsp::silence::SilenceConfig;
use crate::sync::{lock_unpoisoned, read_unpoisoned, write_unpoisoned};

/// Full snapshot of deck DSP, hardware format, silence trimming, and visualizer settings.
#[derive(Clone)]
pub struct DeckDspTemplate {
    /// Output device sample rate in Hz (clamped to at least 8000 on capture).
    pub sample_rate: u32,
    /// Output channel count (clamped to `1..=16` on capture).
    pub channels: u32,
    /// Output period size in frames (clamped to at least 64 on capture).
    pub period_size: u32,
    /// Linear deck output gain.
    pub volume: f32,
    /// Playback speed multiplier.
    pub rate: f32,
    /// Pitch-shift multiplier.
    pub pitch: f32,
    /// Whether playback should pause automatically on audio device changes.
    pub pause_on_device_change: bool,
    /// Multi-band parametric equalizer configuration.
    pub eq_params: EqualizerParams,
    /// Pre-amplification gain in decibels.
    pub preamp_db: f32,
    /// Global ReplayGain mode selector.
    pub replay_gain_mode: u32,
    /// Fallback `(gain_db, peak)` tuple used when track-level ReplayGain tags are absent.
    pub default_replay_gain: (f32, f32),
    /// Stereo balance pan in `[-1.0, 1.0]`.
    pub balance: f32,
    /// Whether stereo-to-mono downmix is enabled.
    pub mono_enabled: bool,
    /// Whether stereo width spatialization is enabled.
    pub spatializer_enabled: bool,
    /// Spatializer stereo width factor.
    pub spatializer_width: f32,
    /// Headphone crossfeed configuration.
    pub crossfeed_config: CrossfeedConfig,
    /// Algorithmic reverb configuration.
    pub reverb_config: ReverbConfig,
    /// Whether the soft output limiter is enabled.
    pub limiter_enabled: bool,
    /// Silence trimming and detection configuration.
    pub silence_config: SilenceConfig,
    /// Whether real-time FFT visualizer capture is enabled.
    pub visualizer_enabled: bool,
}

/// Zero-allocation RT-mutable deck settings overlay captured immediately prior to commit swap.
#[derive(Clone, Copy)]
pub struct DeckLiveOverlay {
    /// Live output device sample rate in Hz.
    pub device_sample_rate: u32,
    /// Live output channel count.
    pub device_channels: u32,
    /// Live output period size in frames.
    pub period_size_in_frames: u32,
    /// Live linear deck output gain.
    pub volume: f32,
    /// Live playback speed multiplier.
    pub rate: f32,
    /// Live pitch-shift multiplier.
    pub pitch: f32,
    /// Live pause-on-device-change preference.
    pub pause_on_device_change: bool,
    /// Live pre-amplification gain in decibels.
    pub preamp_db: f32,
    /// Live global ReplayGain mode selector.
    pub replay_gain_mode: u32,
    /// Live fallback `(gain_db, peak)` tuple when track-level ReplayGain tags are absent.
    pub default_replay_gain: (f32, f32),
    /// Live stereo balance pan.
    pub balance: f32,
    /// Live stereo-to-mono downmix toggle.
    pub mono_enabled: bool,
    /// Live spatializer enable toggle.
    pub spatializer_enabled: bool,
    /// Live spatializer stereo width factor.
    pub spatializer_width: f32,
    /// Live soft limiter enable toggle.
    pub limiter_enabled: bool,
    /// Live silence trimming and detection configuration.
    pub silence_config: SilenceConfig,
    /// Live real-time FFT visualizer enable toggle.
    pub visualizer_enabled: bool,
}

/// Specification returned by synchronous planning when an asynchronous I/O open is required.
#[derive(Clone)]
pub struct PlannedOpenSpec {
    /// Queue item to open asynchronously.
    pub item: AudioSourceCore,
    /// Full DSP and hardware format template captured at plan time.
    pub template: DeckDspTemplate,
    /// Optional factory for custom Dart-backed byte sources.
    pub custom_factory: Option<CustomSourceFactory>,
    /// Optional unified Dart source resolution registry.
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    /// Optional initial seek target in milliseconds after opening.
    pub seek_ms: Option<i64>,
    /// Optional manual crossfade duration override in milliseconds.
    pub manual_crossfade_ms: Option<u64>,
    /// Whether playback should start even if the player was stopped or paused.
    pub force_play: bool,
}

/// Immediate or asynchronous result of planning a `play`, `next`, or `previous` command.
pub enum PlanOutcome {
    /// Command completed synchronously without launching a background open.
    Immediate(Result<(), String>),
    /// Standby deck already held the target and was committed immediately; trigger next prewarm.
    CommittedStandby,
    /// Target must be opened asynchronously on `IoWorkerPool`.
    NeedOpen(PlannedOpenSpec),
}

/// Strategy used when committing a prepared `Box<StreamingDeck>` or standby hit on RT clock.
#[derive(Clone, Copy)]
pub enum TransitionCommitMode {
    /// Manual user-initiated track transition.
    Manual {
        /// Optional manual crossfade duration override in milliseconds.
        manual_crossfade_ms: Option<u64>,
        /// Whether playback should start even when the engine was not currently playing.
        force_play: bool,
    },
    /// Automatic end-of-track crossfade transition.
    AutoCrossfade {
        /// Effective crossfade duration in milliseconds.
        eff_ms: u64,
    },
    /// Automatic gapless advance when the active track reaches EOF.
    AutoAdvanceGapless,
}

impl StreamingDeck {
    /// Captures all DSP, format, silence, and visualizer parameters without mutating state.
    ///
    /// Uses `sr`, `ch`, and `period` for hardware format fields (clamped to valid minimums)
    /// along with `replay_gain_mode` and `default_replay_gain` for ReplayGain policy.
    pub fn capture_dsp_template(
        &self,
        sr: u32,
        ch: u32,
        period: u32,
        replay_gain_mode: u32,
        default_replay_gain: (f32, f32),
    ) -> DeckDspTemplate {
        DeckDspTemplate {
            sample_rate: sr.max(8000),
            channels: ch.clamp(1, 16),
            period_size: period.max(64),
            volume: f32::from_bits(self.volume.load(Ordering::Relaxed)),
            rate: f32::from_bits(self.rate.load(Ordering::Relaxed)),
            pitch: f32::from_bits(self.pitch.load(Ordering::Relaxed)),
            pause_on_device_change: self.pause_on_device_change.load(Ordering::Relaxed),
            eq_params: self.eq_params,
            preamp_db: f32::from_bits(self.preamp_db.load(Ordering::Relaxed)),
            replay_gain_mode,
            default_replay_gain,
            balance: f32::from_bits(self.balance.load(Ordering::Relaxed)),
            mono_enabled: self.mono_enabled.load(Ordering::Relaxed),
            spatializer_enabled: self.spatializer_enabled.load(Ordering::Relaxed),
            spatializer_width: f32::from_bits(self.spatializer_width.load(Ordering::Relaxed)),
            crossfeed_config: self.crossfeed_config,
            reverb_config: self.reverb_config,
            limiter_enabled: self.limiter_enabled.load(Ordering::Relaxed),
            silence_config: self.silence_config.read(),
            visualizer_enabled: self.visualizer_enabled.load(Ordering::Relaxed),
        }
    }

    /// Captures lightweight atomic/copy DSP parameters for zero-allocation RT commit sync,
    /// embedding `replay_gain_mode` and `default_replay_gain` in the resulting overlay.
    pub fn capture_live_overlay(
        &self,
        replay_gain_mode: u32,
        default_replay_gain: (f32, f32),
    ) -> DeckLiveOverlay {
        DeckLiveOverlay {
            device_sample_rate: self.device_sample_rate.load(Ordering::Relaxed),
            device_channels: self.device_channels.load(Ordering::Relaxed),
            period_size_in_frames: self.period_size_in_frames.load(Ordering::Relaxed),
            volume: f32::from_bits(self.volume.load(Ordering::Relaxed)),
            rate: f32::from_bits(self.rate.load(Ordering::Relaxed)),
            pitch: f32::from_bits(self.pitch.load(Ordering::Relaxed)),
            pause_on_device_change: self.pause_on_device_change.load(Ordering::Relaxed),
            preamp_db: f32::from_bits(self.preamp_db.load(Ordering::Relaxed)),
            replay_gain_mode,
            default_replay_gain,
            balance: f32::from_bits(self.balance.load(Ordering::Relaxed)),
            mono_enabled: self.mono_enabled.load(Ordering::Relaxed),
            spatializer_enabled: self.spatializer_enabled.load(Ordering::Relaxed),
            spatializer_width: f32::from_bits(self.spatializer_width.load(Ordering::Relaxed)),
            limiter_enabled: self.limiter_enabled.load(Ordering::Relaxed),
            silence_config: self.silence_config.read(),
            visualizer_enabled: self.visualizer_enabled.load(Ordering::Relaxed),
        }
    }

    /// Pushes each [`DspCommand`] in `cmds` into this deck's lock-free DSP command ringbuffer.
    fn push_dsp_commands(&self, cmds: &[DspCommand]) {
        let mut guard = lock_unpoisoned(&self.cmd_producer);
        if let Some(ref mut prod) = *guard {
            for cmd in cmds {
                if prod.push(cmd.clone()).is_err() {
                    crate::map_log!(
                        2,
                        "[DualSourceControl] DSP command ringbuffer full while applying deck configuration"
                    );
                }
            }
        }
    }

    /// Applies `tpl` cleanly to an unattached prepared deck without emitting UI telemetry events,
    /// resolving per-track ReplayGain and queue assignment from `item` when present.
    pub fn apply_dsp_template_silent(&mut self, tpl: &DeckDspTemplate, item: Option<&AudioSourceCore>) {
        self.device_sample_rate.store(tpl.sample_rate, Ordering::Relaxed);
        self.device_channels.store(tpl.channels, Ordering::Relaxed);
        self.period_size_in_frames.store(tpl.period_size, Ordering::Relaxed);
        self.volume.store(tpl.volume.to_bits(), Ordering::Relaxed);
        self.rate.store(tpl.rate.to_bits(), Ordering::Relaxed);
        self.pitch.store(tpl.pitch.to_bits(), Ordering::Relaxed);
        self.pause_on_device_change
            .store(tpl.pause_on_device_change, Ordering::Relaxed);
        self.preamp_db.store(tpl.preamp_db.to_bits(), Ordering::Relaxed);
        self.balance.store(tpl.balance.to_bits(), Ordering::Relaxed);
        self.mono_enabled.store(tpl.mono_enabled, Ordering::Relaxed);
        self.spatializer_enabled
            .store(tpl.spatializer_enabled, Ordering::Relaxed);
        self.spatializer_width
            .store(tpl.spatializer_width.to_bits(), Ordering::Relaxed);
        self.limiter_enabled
            .store(tpl.limiter_enabled, Ordering::Relaxed);
        self.visualizer_enabled
            .store(tpl.visualizer_enabled, Ordering::Relaxed);

        let rg = resolve_replay_gain(tpl.replay_gain_mode, tpl.default_replay_gain, item);
        if let Some(it) = item {
            self.set_queue_item_assignment(it);
        } else {
            self.queue_item_id = None;
            self.track_replay_gain = (None, None);
        }
        self.eq_params = tpl.eq_params.clone();
        self.replay_gain = rg;
        self.crossfeed_config = tpl.crossfeed_config;
        self.reverb_config = tpl.reverb_config;
        self.silence_config.write(|s| *s = tpl.silence_config);

        self.push_dsp_commands(&[
            DspCommand::SetSampleRate(tpl.sample_rate),
            DspCommand::SetVolume(tpl.volume),
            DspCommand::SetEqualizerParams(tpl.eq_params.clone()),
            DspCommand::SetPreamp(tpl.preamp_db),
            DspCommand::SetReplayGain(rg),
            DspCommand::SetBalance(tpl.balance),
            DspCommand::SetMono(tpl.mono_enabled),
            DspCommand::SetSpatializer {
                enabled: tpl.spatializer_enabled,
                width: tpl.spatializer_width,
            },
            DspCommand::SetCrossfeed(tpl.crossfeed_config),
            DspCommand::SetReverb(tpl.reverb_config),
            DspCommand::SetLimiter(tpl.limiter_enabled),
            DspCommand::SetVisualizerEnabled(tpl.visualizer_enabled),
        ]);
    }

    /// Re-applies RT-mutable DSP scalars from `ov` onto a prepared or standby deck on `map-engine-clock`,
    /// updating per-track ReplayGain and queue assignment from `item` when provided.
    pub fn apply_live_overlay_silent(&mut self, ov: &DeckLiveOverlay, item: Option<&AudioSourceCore>) {
        self.device_sample_rate
            .store(ov.device_sample_rate, Ordering::Relaxed);
        self.device_channels
            .store(ov.device_channels, Ordering::Relaxed);
        self.period_size_in_frames
            .store(ov.period_size_in_frames, Ordering::Relaxed);
        self.volume.store(ov.volume.to_bits(), Ordering::Relaxed);
        self.rate.store(ov.rate.to_bits(), Ordering::Relaxed);
        self.pitch.store(ov.pitch.to_bits(), Ordering::Relaxed);
        self.pause_on_device_change
            .store(ov.pause_on_device_change, Ordering::Relaxed);
        self.preamp_db.store(ov.preamp_db.to_bits(), Ordering::Relaxed);
        self.balance.store(ov.balance.to_bits(), Ordering::Relaxed);
        self.mono_enabled.store(ov.mono_enabled, Ordering::Relaxed);
        self.spatializer_enabled
            .store(ov.spatializer_enabled, Ordering::Relaxed);
        self.spatializer_width
            .store(ov.spatializer_width.to_bits(), Ordering::Relaxed);
        self.limiter_enabled
            .store(ov.limiter_enabled, Ordering::Relaxed);
        self.visualizer_enabled
            .store(ov.visualizer_enabled, Ordering::Relaxed);
        self.silence_config.write(|s| *s = ov.silence_config);

        let rg = resolve_replay_gain(ov.replay_gain_mode, ov.default_replay_gain, item);
        if let Some(it) = item {
            self.set_queue_item_assignment(it);
        }
        self.replay_gain = rg;

        self.push_dsp_commands(&[
            DspCommand::SetSampleRate(ov.device_sample_rate),
            DspCommand::SetVolume(ov.volume),
            DspCommand::SetPreamp(ov.preamp_db),
            DspCommand::SetReplayGain(rg),
            DspCommand::SetBalance(ov.balance),
            DspCommand::SetMono(ov.mono_enabled),
            DspCommand::SetSpatializer {
                enabled: ov.spatializer_enabled,
                width: ov.spatializer_width,
            },
            DspCommand::SetLimiter(ov.limiter_enabled),
            DspCommand::SetVisualizerEnabled(ov.visualizer_enabled),
        ]);
    }
}

impl DualSource {
    /// Returns `true` when standby currently holds a decoded track matching `item`.
    pub fn standby_is_ready_for(&self, item: &AudioSourceCore) -> bool {
        if self.standby_ready_id.load(Ordering::Acquire) != item.id {
            return false;
        }
        read_unpoisoned(&self.standby_ready_source).as_deref() == Some(item.source.as_str())
    }

    /// Marks the standby deck cache as invalid.
    pub fn invalidate_standby(&mut self) {
        self.standby_ready_id.store(-1, Ordering::Release);
        *write_unpoisoned(&self.standby_ready_source) = None;
    }

    /// Captures the DSP/hardware template from the current active deck.
    pub fn capture_dsp_template(&self) -> DeckDspTemplate {
        self.active_deck_ref().capture_dsp_template(
            self.sample_rate,
            self.channels,
            self.period_size,
            self.replay_gain_mode,
            self.default_replay_gain,
        )
    }

    /// Captures the lightweight RT DSP overlay and global ReplayGain policy without touching the active deck's item gain.
    pub fn capture_live_overlay(&self) -> DeckLiveOverlay {
        self.active_deck_ref()
            .capture_live_overlay(self.replay_gain_mode, self.default_replay_gain)
    }

    /// Replaces `deck_a` and `deck_b` with `clean_a` and `clean_b` in $O(1)$, installs `items`
    /// as the new queue, resets playback state to stopped, and returns the displaced deck pair.
    pub fn set_queue_swap_decks(
        &mut self,
        items: Vec<AudioSourceCore>,
        mut clean_a: Box<StreamingDeck>,
        mut clean_b: Box<StreamingDeck>,
    ) -> (Box<StreamingDeck>, Box<StreamingDeck>) {
        let item_count = items.len();
        let tpl = self.capture_dsp_template();
        clean_a.apply_dsp_template_silent(&tpl, None);
        clean_b.apply_dsp_template_silent(&tpl, None);

        self.crossfade.abort();
        self.crossfade_target_id.store(-1, Ordering::Release);
        self.crossfade_completed_flag.store(false, Ordering::Release);
        self.invalidate_standby();

        std::mem::swap(&mut self.deck_a, &mut clean_a);
        std::mem::swap(&mut self.deck_b, &mut clean_b);
        self.active_deck.store(0, Ordering::Release);

        *write_unpoisoned(&self.canonical_queue) = items.clone();
        *write_unpoisoned(&self.original_indices) = (0..items.len()).collect();
        *write_unpoisoned(&self.queue) = items;

        self.current_index.store(-1, Ordering::Release);
        self.planned_index.store(-1, Ordering::Release);
        self.pending_open_active.store(false, Ordering::Release);
        self.pending_open_seek_ms.store(0, Ordering::Release);
        self.pending_auto_advance_prev_index
            .store(-1, Ordering::Release);
        self.last_notified_infinite_mix_id.store(-1, Ordering::Release);
        self.playback_state
            .store(PlaybackState::Stopped.as_i32(), Ordering::Release);

        crate::map_log!(
            3,
            "[DualSourceControl] Queue replaced with {} item(s); active deck reset to 0",
            item_count
        );

        (clean_a, clean_b)
    }

    /// Resolves the next pre-warm candidate `(next_idx, item)` from `current_index` and `loop_mode`.
    pub fn expected_prewarm_target(&self) -> Option<(usize, AudioSourceCore)> {
        if self.crossfade.is_active() {
            return None;
        }
        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return None;
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        if cur < 0 || (cur as usize) >= q.len() {
            return None;
        }
        let loop_mode = self.loop_mode.load(Ordering::Relaxed);
        if loop_mode == 1 {
            return Some((cur as usize, q[cur as usize].clone()));
        }
        let next_idx = (cur as usize) + 1;
        if next_idx < q.len() {
            Some((next_idx, q[next_idx].clone()))
        } else if loop_mode == 2 {
            Some((0, q[0].clone()))
        } else {
            None
        }
    }

    /// Synchronizes `planned_index` to `current_index` when queue mutations settle.
    #[inline]
    pub fn sync_planned_index_to_current(&self) {
        let cur = self.current_index.load(Ordering::Relaxed);
        self.planned_index.store(cur, Ordering::Release);
    }

    /// Removes the track at `index` and returns an async [`PlannedOpenSpec`] if the active
    /// track was removed while the queue still has remaining items.
    pub fn remove_item_at_plan(
        &mut self,
        index: usize,
    ) -> (Option<AudioSourceCore>, Option<PlannedOpenSpec>) {
        let (was_cur, had_remaining) = {
            let q = read_unpoisoned(&self.queue);
            let cur = self.current_index.load(Ordering::Relaxed);
            (cur >= 0 && (index as i64) == cur && index < q.len(), q.len() > 1)
        };
        let removed = self.remove_item_at(index);
        if removed.is_none() {
            return (None, None);
        }
        if was_cur && had_remaining {
            let cur = self.current_index.load(Ordering::Relaxed);
            if cur >= 0 {
                let item_opt = read_unpoisoned(&self.queue).get(cur as usize).cloned();
                if let Some(item) = item_opt {
                    self.pending_open_seek_ms.store(0, Ordering::Release);
                    self.pending_auto_advance_prev_index
                        .store(-1, Ordering::Release);
                    self.pending_open_active.store(true, Ordering::Release);
                    crate::map_log!(
                        3,
                        "[DualSourceControl] Removed active index {}; planning replacement open id={}",
                        index,
                        item.id
                    );
                    let spec = PlannedOpenSpec {
                        item,
                        template: self.capture_dsp_template(),
                        custom_factory: self.custom_source_factory.clone(),
                        dart_resolver: self.dart_resolver.clone(),
                        seek_ms: None,
                        manual_crossfade_ms: Some(0),
                        force_play: true,
                    };
                    return (removed, Some(spec));
                }
            }
        }
        (removed, None)
    }

    /// Optimistically marks `target_idx` active in the queue before background I/O completes,
    /// recording `seek_ms` and stopping any active crossfade/deck if `manual_crossfade_ms`
    /// (or the configured manual crossfade duration) resolves to zero.
    fn mark_pending_manual_open(
        &mut self,
        target_idx: usize,
        seek_ms: Option<i64>,
        manual_crossfade_ms: Option<u64>,
    ) {
        self.current_index
            .store(target_idx as i64, Ordering::Release);
        self.planned_index
            .store(target_idx as i64, Ordering::Release);
        self.pending_open_seek_ms
            .store(seek_ms.unwrap_or(0).max(0), Ordering::Release);
        self.pending_auto_advance_prev_index
            .store(-1, Ordering::Release);
        self.pending_open_active.store(true, Ordering::Release);
        let eff_xfade = manual_crossfade_ms
            .unwrap_or_else(|| self.manual_crossfade_duration_ms.load(Ordering::Relaxed));
        if eff_xfade == 0 {
            if self.crossfade.is_active() {
                self.abort_active_crossfade();
            }
            self.active_deck_mut().stop();
        }
    }

    /// Plans `play()` without executing any blocking I/O on the calling thread.
    ///
    /// Selects a target track using `id` (taking precedence) or `position`, applies optional
    /// `shuffled` state, seeks to `seek_ms` when applicable, and avoids relying on standby
    /// when `has_inflight_active_open` is `true`.
    pub fn plan_play(
        &mut self,
        id: Option<i64>,
        position: Option<usize>,
        shuffled: Option<bool>,
        seek_ms: Option<i64>,
        has_inflight_active_open: bool,
    ) -> PlanOutcome {
        let cur = self.current_index.load(Ordering::Relaxed);
        let planned = self.planned_index.load(Ordering::Relaxed);
        let logical_cur = if planned >= 0 { planned } else { cur };

        // Case 1: Initial playback start before any track has become current/planned.
        if logical_cur < 0 {
            let can = read_unpoisoned(&self.canonical_queue).clone();
            if can.is_empty() {
                if id.is_some() || position.is_some() {
                    crate::map_log!(
                        2,
                        "[DualSourceControl] plan_play rejected: queue is empty (id={:?}, position={:?})",
                        id,
                        position
                    );
                    return PlanOutcome::Immediate(Err(
                        "Cannot play specific track: queue is empty".to_string()
                    ));
                }
                return PlanOutcome::Immediate(Ok(()));
            }

            let effective_shuffled = if let Some(shuf) = shuffled {
                self.shuffle_enabled.store(shuf, Ordering::Release);
                shuf
            } else {
                self.shuffle_enabled.load(Ordering::Relaxed)
            };

            let target_canon_idx: Option<usize> = if let Some(target_id) = id {
                let Some(idx) = can.iter().position(|it| it.id == target_id) else {
                    crate::map_log!(
                        2,
                        "[DualSourceControl] plan_play rejected: track id {} not found in queue",
                        target_id
                    );
                    return PlanOutcome::Immediate(Err(format!(
                        "Track id {} not found in queue",
                        target_id
                    )));
                };
                Some(idx)
            } else if let Some(pos) = position {
                if pos >= can.len() {
                    crate::map_log!(
                        2,
                        "[DualSourceControl] plan_play rejected: position {} out of bounds (len={})",
                        pos,
                        can.len()
                    );
                    return PlanOutcome::Immediate(Err(format!(
                        "Position {} out of bounds (queue size {})",
                        pos,
                        can.len()
                    )));
                }
                Some(pos)
            } else {
                None
            };

            let start_idx: usize = if effective_shuffled {
                let mut q = can;
                use rand::seq::SliceRandom;
                let mut rng = rand::rng();
                if let Some(canon_idx) = target_canon_idx {
                    q.swap(0, canon_idx);
                    if q.len() > 2 {
                        q[1..].shuffle(&mut rng);
                    }
                } else {
                    q.shuffle(&mut rng);
                }
                *write_unpoisoned(&self.queue) = q;
                0
            } else {
                *write_unpoisoned(&self.queue) = can;
                target_canon_idx.unwrap_or(0)
            };

            let start_item = read_unpoisoned(&self.queue)[start_idx].clone();
            self.invalidate_standby();
            self.mark_pending_manual_open(start_idx, seek_ms, Some(0));

            crate::map_log!(
                3,
                "[DualSourceControl] plan_play: initial open id={} idx={} shuffled={}",
                start_item.id,
                start_idx,
                effective_shuffled
            );

            return PlanOutcome::NeedOpen(PlannedOpenSpec {
                item: start_item,
                template: self.capture_dsp_template(),
                custom_factory: self.custom_source_factory.clone(),
                dart_resolver: self.dart_resolver.clone(),
                seek_ms,
                manual_crossfade_ms: Some(0),
                force_play: true,
            });
        }

        // Case 2a: Resume / play-in-place when no track selector is passed.
        if id.is_none() && position.is_none() {
            if let Some(shuf) = shuffled {
                self.set_shuffle(shuf);
                self.sync_planned_index_to_current();
            }
            let cur_playback = PlaybackState::from_i32(self.playback_state.load(Ordering::Relaxed));
            let effective_idx = if cur >= 0 { cur } else { logical_cur };
            if effective_idx >= 0 {
                let q_item = read_unpoisoned(&self.queue)
                    .get(effective_idx as usize)
                    .cloned();
                if let Some(item) = q_item {
                    let deck_matches = self.active_deck_ref().queue_item_id == Some(item.id);
                    if cur_playback == PlaybackState::Stopped || !deck_matches {
                        self.mark_pending_manual_open(
                            effective_idx as usize,
                            Some(seek_ms.unwrap_or(0)),
                            Some(0),
                        );
                        crate::map_log!(
                            3,
                            "[DualSourceControl] plan_play: reopening stopped/mismatched track id={} idx={}",
                            item.id,
                            effective_idx
                        );
                        return PlanOutcome::NeedOpen(PlannedOpenSpec {
                            item,
                            template: self.capture_dsp_template(),
                            custom_factory: self.custom_source_factory.clone(),
                            dart_resolver: self.dart_resolver.clone(),
                            seek_ms: Some(seek_ms.unwrap_or(0)),
                            manual_crossfade_ms: Some(0),
                            force_play: true,
                        });
                    }
                }
            }
            if let Some(ms) = seek_ms {
                self.seek(ms);
            }
            let res = self.active_deck_mut().play();
            return if res == 0 {
                if self.crossfade.is_active() || self.crossfade_target_id.load(Ordering::Acquire) >= 0 {
                    let _ = self.standby_deck_mut().play();
                }
                self.playback_state
                    .store(PlaybackState::Playing.as_i32(), Ordering::Release);
                crate::map_log!(4, "[DualSourceControl] plan_play: resumed active deck in place");
                PlanOutcome::Immediate(Ok(()))
            } else {
                crate::map_log!(
                    1,
                    "[DualSourceControl] plan_play: active deck play() failed with code {}",
                    res
                );
                PlanOutcome::Immediate(Err(format!("Play failed: code {}", res)))
            };
        }

        // Case 2b: Explicit track selection by id (takes precedence) or queue position.
        let target_track_id = if let Some(target_id) = id {
            let exists = read_unpoisoned(&self.queue)
                .iter()
                .any(|it| it.id == target_id);
            if !exists {
                crate::map_log!(
                    2,
                    "[DualSourceControl] plan_play rejected: track id {} not found in queue",
                    target_id
                );
                return PlanOutcome::Immediate(Err(format!(
                    "Track id {} not found in queue",
                    target_id
                )));
            }
            target_id
        } else if let Some(pos) = position {
            let q = read_unpoisoned(&self.queue);
            if pos >= q.len() {
                crate::map_log!(
                    2,
                    "[DualSourceControl] plan_play rejected: position {} out of bounds (len={})",
                    pos,
                    q.len()
                );
                return PlanOutcome::Immediate(Err(format!(
                    "Position {} out of bounds (queue size {})",
                    pos,
                    q.len()
                )));
            }
            q[pos].id
        } else {
            crate::map_log!(2, "[DualSourceControl] plan_play rejected: invalid play target");
            return PlanOutcome::Immediate(Err("Invalid play target".to_string()));
        };

        if let Some(shuf) = shuffled {
            self.set_shuffle(shuf);
        }

        let target_opt = {
            let q = read_unpoisoned(&self.queue);
            q.iter()
                .enumerate()
                .find(|(_, it)| it.id == target_track_id)
                .map(|(i, it)| (i, it.clone()))
        };
        let Some((target_idx, target_item)) = target_opt else {
            crate::map_log!(
                1,
                "[DualSourceControl] plan_play error: track id {} disappeared after shuffle",
                target_track_id
            );
            return PlanOutcome::Immediate(Err(format!(
                "Track id {} disappeared after shuffle",
                target_track_id
            )));
        };

        if !has_inflight_active_open
            && !self.crossfade.is_active()
            && self.standby_is_ready_for(&target_item)
        {
            crate::map_log!(
                3,
                "[DualSourceControl] plan_play: standby hit id={} idx={}",
                target_item.id,
                target_idx
            );
            let _displaced = self.commit_transition_internal(
                None,
                &target_item,
                seek_ms,
                TransitionCommitMode::Manual {
                    manual_crossfade_ms: None,
                    force_play: true,
                },
            );
            return PlanOutcome::CommittedStandby;
        }

        self.mark_pending_manual_open(target_idx, seek_ms, None);
        crate::map_log!(
            3,
            "[DualSourceControl] plan_play: async open id={} idx={}",
            target_item.id,
            target_idx
        );
        PlanOutcome::NeedOpen(PlannedOpenSpec {
            item: target_item,
            template: self.capture_dsp_template(),
            custom_factory: self.custom_source_factory.clone(),
            dart_resolver: self.dart_resolver.clone(),
            seek_ms,
            manual_crossfade_ms: None,
            force_play: true,
        })
    }

    /// Plans `next()` without performing blocking I/O. Advances `planned_index` synchronously
    /// so un-awaited concurrent `next()` bursts compose FIFO (`planned_index += 1`).
    ///
    /// Applies `manual_crossfade_ms` when accelerating an active auto-crossfade or launching
    /// the next track, and guards against standby races when `has_inflight_active_open` is `true`.
    pub fn plan_next(
        &mut self,
        manual_crossfade_ms: Option<u64>,
        has_inflight_active_open: bool,
    ) -> PlanOutcome {
        let trans = self.crossfade.transition();
        if trans == QueueTransition::AutoCrossfade && !has_inflight_active_open {
            let target_id = self.crossfade_target_id.load(Ordering::Relaxed);
            if target_id >= 0 {
                if let Some(idx) = read_unpoisoned(&self.queue)
                    .iter()
                    .position(|it| it.id == target_id)
                {
                    self.current_index.store(idx as i64, Ordering::Release);
                    self.planned_index.store(idx as i64, Ordering::Release);
                }
            }
            let manual_ms = manual_crossfade_ms
                .unwrap_or_else(|| self.manual_crossfade_duration_ms.load(Ordering::Relaxed));
            let sr = self.sample_rate.max(1);
            let max_frames = (manual_ms * sr as u64) / 1000;
            let cur_frame = self.crossfade.current_frame.load(Ordering::Relaxed);
            let tot_frame = self.crossfade.total_frames.load(Ordering::Relaxed);
            if tot_frame > cur_frame + max_frames {
                self.crossfade
                    .total_frames
                    .store(cur_frame + max_frames, Ordering::Release);
            }
            self.crossfade
                .transition
                .store(QueueTransition::ManualCrossfade.as_i32(), Ordering::Release);
            crate::map_log!(
                3,
                "[DualSourceControl] plan_next: promoted auto-crossfade to manual ({} ms)",
                manual_ms
            );
            return PlanOutcome::Immediate(Ok(()));
        }

        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return PlanOutcome::Immediate(Ok(()));
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        let planned = self.planned_index.load(Ordering::Relaxed);
        let base = if planned >= 0 { planned } else { cur };
        let next_idx = base + 1;
        let loop_mode = self.loop_mode.load(Ordering::Relaxed);

        let target_idx = if next_idx < q.len() as i64 {
            next_idx as usize
        } else if loop_mode == 2 {
            0
        } else {
            return PlanOutcome::Immediate(Ok(()));
        };
        let item = q[target_idx].clone();
        drop(q);

        self.planned_index.store(target_idx as i64, Ordering::Release);

        // Fast zero-I/O standby hit if standby already decoded this track and no active open is racing.
        if !has_inflight_active_open
            && !self.crossfade.is_active()
            && self.standby_is_ready_for(&item)
        {
            crate::map_log!(
                3,
                "[DualSourceControl] plan_next: standby hit id={} idx={}",
                item.id,
                target_idx
            );
            let _displaced = self.commit_transition_internal(
                None,
                &item,
                None,
                TransitionCommitMode::Manual {
                    manual_crossfade_ms,
                    force_play: false,
                },
            );
            return PlanOutcome::CommittedStandby;
        }

        self.mark_pending_manual_open(target_idx, None, manual_crossfade_ms);
        crate::map_log!(
            3,
            "[DualSourceControl] plan_next: async open id={} idx={}",
            item.id,
            target_idx
        );
        PlanOutcome::NeedOpen(PlannedOpenSpec {
            item,
            template: self.capture_dsp_template(),
            custom_factory: self.custom_source_factory.clone(),
            dart_resolver: self.dart_resolver.clone(),
            seek_ms: None,
            manual_crossfade_ms,
            force_play: false,
        })
    }

    /// Plans `previous()` without performing blocking I/O.
    ///
    /// Restarts the active track at `0 ms` when no active open is in flight
    /// (`!has_inflight_active_open`) and playback position exceeds 3 seconds on a non-live source;
    /// otherwise steps backward in the queue.
    pub fn plan_previous(&mut self, has_inflight_active_open: bool) -> PlanOutcome {
        let cur_deck = self.active_deck_ref();
        let pos_ms = cur_deck.position_ms.load(Ordering::Relaxed);
        let is_live = cur_deck.is_live_stream();

        if !has_inflight_active_open
            && !self.pending_open_active.load(Ordering::Acquire)
            && !is_live
            && pos_ms > 3000
        {
            self.abort_active_crossfade();
            self.active_deck_mut().seek(0);
            self.sync_planned_index_to_current();
            crate::map_log!(
                4,
                "[DualSourceControl] plan_previous: restarted active track at 0 ms (pos={} ms)",
                pos_ms
            );
            return PlanOutcome::Immediate(Ok(()));
        }

        let q = read_unpoisoned(&self.queue);
        if q.is_empty() {
            return PlanOutcome::Immediate(Ok(()));
        }
        let cur = self.current_index.load(Ordering::Relaxed);
        let planned = self.planned_index.load(Ordering::Relaxed);
        let base = if planned >= 0 { planned } else { cur };
        let target_idx = if base > 0 { (base - 1) as usize } else { 0 };
        let item = q[target_idx].clone();
        drop(q);

        self.planned_index.store(target_idx as i64, Ordering::Release);

        if !has_inflight_active_open
            && !self.crossfade.is_active()
            && self.standby_is_ready_for(&item)
        {
            crate::map_log!(
                3,
                "[DualSourceControl] plan_previous: standby hit id={} idx={}",
                item.id,
                target_idx
            );
            let _displaced = self.commit_transition_internal(
                None,
                &item,
                None,
                TransitionCommitMode::Manual {
                    manual_crossfade_ms: None,
                    force_play: false,
                },
            );
            return PlanOutcome::CommittedStandby;
        }

        self.mark_pending_manual_open(target_idx, None, None);
        crate::map_log!(
            3,
            "[DualSourceControl] plan_previous: async open id={} idx={}",
            item.id,
            target_idx
        );
        PlanOutcome::NeedOpen(PlannedOpenSpec {
            item,
            template: self.capture_dsp_template(),
            custom_factory: self.custom_source_factory.clone(),
            dart_resolver: self.dart_resolver.clone(),
            seek_ms: None,
            manual_crossfade_ms: None,
            force_play: false,
        })
    }

    /// Installs a newly `prepared` standby deck if `item` still matches the expected next track.
    ///
    /// Returns the displaced standby deck on success.
    ///
    /// # Errors
    ///
    /// Returns `Err(prepared)` so the caller can reap it off-RT when a crossfade is active,
    /// there is no expected prewarm target, or `item` no longer matches the expected candidate.
    pub fn commit_prepared_standby(
        &mut self,
        mut prepared: Box<StreamingDeck>,
        item: &AudioSourceCore,
    ) -> Result<Box<StreamingDeck>, Box<StreamingDeck>> {
        if self.crossfade.is_active() {
            crate::map_log!(
                4,
                "[DualSourceControl] commit_prepared_standby: rejected id={} (crossfade active)",
                item.id
            );
            return Err(prepared);
        }
        let Some((_idx, expected)) = self.expected_prewarm_target() else {
            crate::map_log!(
                4,
                "[DualSourceControl] commit_prepared_standby: rejected id={} (no expected prewarm target)",
                item.id
            );
            return Err(prepared);
        };
        if expected.id != item.id || expected.source != item.source {
            crate::map_log!(
                4,
                "[DualSourceControl] commit_prepared_standby: rejected stale id={} (expected id={})",
                item.id,
                expected.id
            );
            return Err(prepared);
        }

        let overlay = self.capture_live_overlay();
        prepared.apply_live_overlay_silent(&overlay, Some(&expected));
        prepared.pause();

        let active_idx = self.active_deck.load(Ordering::Relaxed);
        if active_idx == 0 {
            std::mem::swap(&mut self.deck_b, &mut prepared);
        } else {
            std::mem::swap(&mut self.deck_a, &mut prepared);
        }
        self.standby_ready_id.store(expected.id, Ordering::Release);
        *write_unpoisoned(&self.standby_ready_source) = Some(expected.source);
        crate::map_log!(
            3,
            "[DualSourceControl] commit_prepared_standby: installed id={} on standby deck",
            expected.id
        );
        Ok(prepared)
    }

    /// Commits a pre-opened deck from `prepared_opt` (or the standby deck when `None`) for `item`
    /// onto the engine clock using `mode`, optionally applying `seek_ms`.
    ///
    /// Returns any displaced `Box<StreamingDeck>` so the caller drops it off-RT in `ReaperHandle`.
    pub fn commit_transition_internal(
        &mut self,
        prepared_opt: Option<Box<StreamingDeck>>,
        item: &AudioSourceCore,
        seek_ms: Option<i64>,
        mode: TransitionCommitMode,
    ) -> Option<Box<StreamingDeck>> {
        let (index, live_item) = {
            let q = read_unpoisoned(&self.queue);
            if let Some(pos) = q.iter().position(|it| it.id == item.id) {
                (pos, q[pos].clone())
            } else {
                // Target track was removed from the queue while opening off-thread.
                crate::map_log!(
                    2,
                    "[DualSourceControl] commit_transition_internal aborted: target id={} not in queue (len={})",
                    item.id,
                    q.len()
                );
                return prepared_opt;
            }
        };

        match mode {
            TransitionCommitMode::Manual { .. } if self.crossfade.is_active() => {
                self.abort_active_crossfade();
            }
            _ => {}
        }

        self.crossfade_target_id.store(-1, Ordering::Release);
        self.crossfade_completed_flag.store(false, Ordering::Release);
        self.pending_open_active.store(false, Ordering::Release);
        self.pending_open_seek_ms.store(0, Ordering::Release);
        self.pending_auto_advance_prev_index
            .store(-1, Ordering::Release);

        let active_deck = self.active_deck.load(Ordering::Relaxed);
        let to_deck = if active_deck == 0 { 1 } else { 0 };
        let was_playing =
            PlaybackState::from_i32(self.playback_state.load(Ordering::Relaxed)) == PlaybackState::Playing;

        let overlay = self.capture_live_overlay();
        let mut displaced: Option<Box<StreamingDeck>> = None;

        if let Some(mut prepared) = prepared_opt {
            prepared.apply_live_overlay_silent(&overlay, Some(&live_item));
            if to_deck == 0 {
                std::mem::swap(&mut self.deck_a, &mut prepared);
            } else {
                std::mem::swap(&mut self.deck_b, &mut prepared);
            }
            displaced = Some(prepared);
        } else {
            let standby = if to_deck == 0 {
                &mut self.deck_a
            } else {
                &mut self.deck_b
            };
            standby.apply_live_overlay_silent(&overlay, Some(&live_item));
        }

        self.invalidate_standby();

        let to_slot = if to_deck == 0 {
            &mut self.deck_a
        } else {
            &mut self.deck_b
        };
        to_slot.track_exhausted.store(false, Ordering::Release);
        if let Some(ms) = seek_ms {
            if ms > 0 {
                to_slot.seek(ms);
            }
        }

        match mode {
            TransitionCommitMode::Manual {
                manual_crossfade_ms,
                force_play,
            } => {
                if !was_playing {
                    let from_slot = if active_deck == 0 {
                        &mut self.deck_a
                    } else {
                        &mut self.deck_b
                    };
                    from_slot.stop();
                    self.active_deck.store(to_deck, Ordering::Release);
                    self.current_index.store(index as i64, Ordering::Release);
                    self.planned_index.store(index as i64, Ordering::Release);
                    if force_play {
                        let to_slot = if to_deck == 0 {
                            &mut self.deck_a
                        } else {
                            &mut self.deck_b
                        };
                        to_slot.play();
                        self.playback_state
                            .store(PlaybackState::Playing.as_i32(), Ordering::Release);
                    } else {
                        self.playback_state
                            .store(PlaybackState::Paused.as_i32(), Ordering::Release);
                    }
                    crate::map_log!(
                        3,
                        "[DualSourceControl] Committed manual transition id={} idx={} to deck {} (force_play={})",
                        item.id,
                        index,
                        to_deck,
                        force_play
                    );
                    return displaced;
                }

                to_slot.play();
                let xfade_ms = manual_crossfade_ms.unwrap_or_else(|| {
                    self.manual_crossfade_duration_ms.load(Ordering::Relaxed)
                });
                if xfade_ms > 0 {
                    let sr = self.sample_rate;
                    let total_frames = (xfade_ms * sr as u64) / 1000;
                    let curve = self.crossfade_curve.load(Ordering::Relaxed);
                    self.crossfade_target_id.store(item.id, Ordering::Release);
                    self.crossfade.begin(
                        active_deck,
                        to_deck,
                        total_frames,
                        curve,
                        QueueTransition::ManualCrossfade,
                    );
                    self.active_deck.store(to_deck, Ordering::Release);
                    self.current_index.store(index as i64, Ordering::Release);
                    self.planned_index.store(index as i64, Ordering::Release);
                    self.playback_state
                        .store(PlaybackState::Playing.as_i32(), Ordering::Release);
                } else {
                    self.active_deck.store(to_deck, Ordering::Release);
                    let from_slot = if active_deck == 0 {
                        &mut self.deck_a
                    } else {
                        &mut self.deck_b
                    };
                    from_slot.stop();
                    self.current_index.store(index as i64, Ordering::Release);
                    self.planned_index.store(index as i64, Ordering::Release);
                    self.playback_state
                        .store(PlaybackState::Playing.as_i32(), Ordering::Release);
                }
                crate::map_log!(
                    3,
                    "[DualSourceControl] Committed manual transition id={} idx={} to deck {} (xfade_ms={})",
                    item.id,
                    index,
                    to_deck,
                    xfade_ms
                );
            }
            TransitionCommitMode::AutoCrossfade { eff_ms } => {
                if !was_playing {
                    to_slot.stop();
                    crate::map_log!(
                        4,
                        "[DualSourceControl] Auto-crossfade transition id={} aborted because player is not playing",
                        item.id
                    );
                    return displaced;
                }
                to_slot.play();
                let sr = self.sample_rate.max(1);
                let xfade_frames = (eff_ms * sr as u64) / 1000;
                let curve = self.crossfade_curve.load(Ordering::Relaxed);
                self.crossfade.begin(
                    active_deck,
                    to_deck,
                    xfade_frames,
                    curve,
                    QueueTransition::AutoCrossfade,
                );
                self.crossfade_target_id.store(item.id, Ordering::Release);
                self.planned_index.store(index as i64, Ordering::Release);
                crate::map_log!(
                    3,
                    "[DualSourceControl] Committed auto-crossfade id={} idx={} to deck {} (eff_ms={})",
                    item.id,
                    index,
                    to_deck,
                    eff_ms
                );
            }
            TransitionCommitMode::AutoAdvanceGapless => {
                if !was_playing {
                    to_slot.stop();
                    crate::map_log!(
                        4,
                        "[DualSourceControl] Auto-advance gapless id={} aborted because player is not playing",
                        item.id
                    );
                    return displaced;
                }
                to_slot.play();
                let from_slot = if active_deck == 0 {
                    &mut self.deck_a
                } else {
                    &mut self.deck_b
                };
                from_slot.stop();
                self.active_deck.store(to_deck, Ordering::Release);
                self.current_index.store(index as i64, Ordering::Release);
                self.planned_index.store(index as i64, Ordering::Release);
                crate::map_log!(
                    3,
                    "[DualSourceControl] Committed gapless auto-advance id={} idx={} to deck {}",
                    item.id,
                    index,
                    to_deck
                );
            }
        }

        displaced
    }
}
