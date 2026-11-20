//! Control-plane transition planning, prepared-deck DSP transfer, and RT swap helpers.

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
    pub sample_rate: u32,
    pub channels: u32,
    pub period_size: u32,
    pub volume: f32,
    pub rate: f32,
    pub pitch: f32,
    pub pause_on_device_change: bool,
    pub eq_params: EqualizerParams,
    pub preamp_db: f32,
    pub replay_gain_mode: u32,
    pub default_replay_gain: (f32, f32),
    pub balance: f32,
    pub mono_enabled: bool,
    pub spatializer_enabled: bool,
    pub spatializer_width: f32,
    pub crossfeed_config: CrossfeedConfig,
    pub reverb_config: ReverbConfig,
    pub limiter_enabled: bool,
    pub silence_config: SilenceConfig,
    pub visualizer_enabled: bool,
}

/// Zero-allocation RT-mutable deck settings overlay captured immediately prior to commit swap.
#[derive(Clone, Copy)]
pub struct DeckLiveOverlay {
    pub device_sample_rate: u32,
    pub device_channels: u32,
    pub period_size_in_frames: u32,
    pub volume: f32,
    pub rate: f32,
    pub pitch: f32,
    pub pause_on_device_change: bool,
    pub preamp_db: f32,
    pub replay_gain_mode: u32,
    pub default_replay_gain: (f32, f32),
    pub balance: f32,
    pub mono_enabled: bool,
    pub spatializer_enabled: bool,
    pub spatializer_width: f32,
    pub limiter_enabled: bool,
    pub silence_config: SilenceConfig,
    pub visualizer_enabled: bool,
}

/// Specification returned by synchronous planning when an asynchronous I/O open is required.
#[derive(Clone)]
pub struct PlannedOpenSpec {
    pub item: AudioSourceCore,
    pub template: DeckDspTemplate,
    pub custom_factory: Option<CustomSourceFactory>,
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    pub seek_ms: Option<i64>,
    pub manual_crossfade_ms: Option<u64>,
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
    Manual {
        manual_crossfade_ms: Option<u64>,
        force_play: bool,
    },
    AutoCrossfade {
        eff_ms: u64,
    },
    AutoAdvanceGapless,
}

impl StreamingDeck {
    /// Captures all DSP, format, silence, and visualizer parameters without mutating state.
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

    /// Captures lightweight atomic/copy DSP parameters for zero-allocation RT commit sync.
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

    fn push_dsp_commands(&self, cmds: &[DspCommand]) {
        let mut guard = lock_unpoisoned(&self.cmd_producer);
        if let Some(ref mut prod) = *guard {
            for cmd in cmds {
                let _ = prod.push(cmd.clone());
            }
        }
    }

    /// Applies `tpl` cleanly to an unattached prepared deck without emitting UI telemetry events.
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

    /// Re-applies RT-mutable DSP scalars onto a prepared or standby deck on `map-engine-clock`.
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

    /// Replaces `deck_a` and `deck_b` with clean stopped decks in $O(1)$ and returns the displaced pair.
    pub fn set_queue_swap_decks(
        &mut self,
        items: Vec<AudioSourceCore>,
        mut clean_a: Box<StreamingDeck>,
        mut clean_b: Box<StreamingDeck>,
    ) -> (Box<StreamingDeck>, Box<StreamingDeck>) {
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
        let next_idx = (cur as usize) + 1;
        let loop_mode = self.loop_mode.load(Ordering::Relaxed);
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

    /// Optimistically marks `target_idx` active in the queue before background I/O completes.
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
                    return PlanOutcome::Immediate(Err(format!(
                        "Track id {} not found in queue",
                        target_id
                    )));
                };
                Some(idx)
            } else if let Some(pos) = position {
                if pos >= can.len() {
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
                PlanOutcome::Immediate(Ok(()))
            } else {
                PlanOutcome::Immediate(Err(format!("Play failed: code {}", res)))
            };
        }

        // Case 2b: Explicit track selection by id (takes precedence) or queue position.
        let target_track_id = if let Some(target_id) = id {
            let exists = read_unpoisoned(&self.queue)
                .iter()
                .any(|it| it.id == target_id);
            if !exists {
                return PlanOutcome::Immediate(Err(format!(
                    "Track id {} not found in queue",
                    target_id
                )));
            }
            target_id
        } else if let Some(pos) = position {
            let q = read_unpoisoned(&self.queue);
            if pos >= q.len() {
                return PlanOutcome::Immediate(Err(format!(
                    "Position {} out of bounds (queue size {})",
                    pos,
                    q.len()
                )));
            }
            q[pos].id
        } else {
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
            return PlanOutcome::Immediate(Err(format!(
                "Track id {} disappeared after shuffle",
                target_track_id
            )));
        };

        if !has_inflight_active_open
            && !self.crossfade.is_active()
            && self.standby_is_ready_for(&target_item)
        {
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

    /// Installs a newly prepared standby deck if still matching expected next track.
    /// Returns displaced standby deck on success, or returns `Err(prepared)` to be reaped.
    pub fn commit_prepared_standby(
        &mut self,
        mut prepared: Box<StreamingDeck>,
        item: &AudioSourceCore,
    ) -> Result<Box<StreamingDeck>, Box<StreamingDeck>> {
        if self.crossfade.is_active() {
            return Err(prepared);
        }
        let Some((_idx, expected)) = self.expected_prewarm_target() else {
            return Err(prepared);
        };
        if expected.id != item.id || expected.source != item.source {
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
        Ok(prepared)
    }

    /// Commits a pre-opened `prepared` deck (or standby deck when `None`) onto the engine clock.
    /// Returns any displaced `Box<StreamingDeck>` so the caller drops it off-RT in `ReaperHandle`.
    pub fn commit_transition_internal(
        &mut self,
        prepared_opt: Option<Box<StreamingDeck>>,
        item: &AudioSourceCore,
        seek_ms: Option<i64>,
        mode: TransitionCommitMode,
    ) -> Option<Box<StreamingDeck>> {
        let (resolved_idx, live_item) = {
            let q = read_unpoisoned(&self.queue);
            if q.is_empty() {
                if let Some(unused) = prepared_opt {
                    return Some(unused);
                }
                return None;
            }
            if let Some(pos) = q.iter().position(|it| it.id == item.id) {
                (pos, q[pos].clone())
            } else {
                // Target track was removed from the queue while opening off-thread.
                if let Some(unused) = prepared_opt {
                    return Some(unused);
                }
                return None;
            }
        };

        let index = resolved_idx;

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
            }
            TransitionCommitMode::AutoCrossfade { eff_ms } => {
                if !was_playing {
                    to_slot.stop();
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
            }
            TransitionCommitMode::AutoAdvanceGapless => {
                if !was_playing {
                    to_slot.stop();
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
            }
        }

        displaced
    }
}
