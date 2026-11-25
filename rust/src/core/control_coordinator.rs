//! Off-RT control coordinator orchestrating epoch serialization, I/O opens, and standby pre-warming.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use crate::sync::thread::{self, JoinHandle};

use crossbeam_channel::{Receiver, Sender};

use crate::buffer::{CustomSourceRegistry, DartResolveRegistry};
use crate::core::dual_source::{AudioSourceCore, CustomSourceFactory, StreamingDeck, STATE_PLAYING};
use crate::core::dual_source_control::{
    PlanOutcome, PlannedOpenSpec, TransitionCommitMode,
};
use crate::core::engine_actor::{
    capture_provisional_track_snapshot, capture_track_snapshot, snapshot_queue_ids,
    EngineActorHandle, RtControlHint, TrackTransitionSnapshot,
};
use crate::core::io_pool::{
    ActiveOpenJob, ActiveOpenKind, IoCompletion, IoOpenOutcome, IoWorkerPool, OpenWaiter,
    PrewarmJob,
};
use crate::core::types::PlaybackState;
use crate::dsp::visualizer::VisualizerData;
use crate::sync::{lock_unpoisoned, read_unpoisoned, CancelToken};

/// Callback invoked on asynchronous background commits (e.g., RT-triggered auto-advance
/// or active track replacement after `removeAt`) so UI telemetry stays synchronized.
pub type AsyncCommitCallback = Arc<dyn Fn(TrackTransitionSnapshot) + Send + Sync>;

/// Internal wake messages sent to the `map-ctrl-coord` coordinator thread.
enum CoordWake {
    /// Triggers an asynchronous standby prewarm evaluation.
    PrewarmCheck {
        /// When `true`, retries prewarming even if the same `(epoch, deck, item)` was already attempted.
        retry_if_failed: bool,
    },
    /// Requests the coordinator thread to exit cleanly.
    Shutdown,
}

/// Planning outcome produced on `map-engine-clock` for a user-initiated playback transition.
enum PlannedDispatch {
    /// Transition completed immediately without opening a new stream (e.g. standby promoted or seek).
    Immediate {
        /// Authoritative post-transition track snapshot.
        snap: TrackTransitionSnapshot,
        /// Whether a standby prewarm check should be scheduled immediately.
        needs_prewarm: bool,
    },
    /// Transition requires opening a track asynchronously on [`IoWorkerPool`].
    NeedOpen {
        /// Specification of the track and deck configuration to open off-clock.
        spec: PlannedOpenSpec,
        /// Provisional UI snapshot emitted immediately while I/O opens in the background.
        provisional_snap: TrackTransitionSnapshot,
        /// Whether ReplayGain telemetry should be recalculated upon commit.
        include_replay_gain: bool,
    },
}

/// Shared inner state owned by [`ControlCoordinator`] and its background coordinator thread.
struct CoordInner {
    /// Handle to the single-owner real-time engine actor.
    engine: EngineActorHandle,
    /// Interruptible I/O worker pool executing active opens and standby prewarms.
    io_pool: Mutex<Option<Arc<IoWorkerPool>>>,
    /// Registry of active custom PCM/demuxed stream factories aborted on queue reset/stop.
    custom_registry: CustomSourceRegistry,
    /// Monotonic epoch incremented on user transport/queue commands to discard stale opens.
    transport_epoch: AtomicU64,
    /// Monotonic epoch incremented when queue mutations invalidate standby prewarms.
    prewarm_epoch: AtomicU64,
    /// Monotonic epoch incremented on seeks, loop-mode changes, and transport resets.
    auto_advance_epoch: AtomicU64,
    /// Serializes foreground transition planning, open submission, and commit operations.
    dispatch_lock: Mutex<()>,
    /// Serializes standby prewarm candidate evaluation.
    prewarm_lock: Mutex<()>,
    /// Deduplication key for the last scheduled prewarm: `(prewarm_epoch, deck_id, open_gen, item_id, source, retried)`.
    last_prewarm: Mutex<Option<(u64, usize, u64, i64, String, bool)>>,
    /// Deduplication key for an in-flight auto-advance open: `(deck_id, open_gen, seek_epoch)`.
    auto_advance_inflight: Mutex<Option<(usize, u64, u64)>>,
    /// Indicates whether [`ControlCoordinator::shutdown`] has been invoked.
    disposed: AtomicBool,
    /// Callback invoked on asynchronous background commits and provisional dispatches.
    on_async_commit: AsyncCommitCallback,
    /// Bounded wake channel driving `map-ctrl-coord`.
    wake_tx: Sender<CoordWake>,
}

/// Returns `true` when `active` has reached the auto-crossfade window (`should_auto_xfade` with
/// `auto_ms > 0`) or hit EOF/track exhaustion.
#[inline]
fn is_auto_advance_due(active: &StreamingDeck, should_auto_xfade: bool, auto_ms: u64) -> bool {
    let pos = active.position_ms.load(Ordering::Relaxed);
    let dur = active.duration_ms.load(Ordering::Relaxed);
    if should_auto_xfade {
        auto_ms > 0 && dur > (auto_ms as i64) && pos + (auto_ms as i64) >= dur
    } else {
        active.decoder_eof.load(Ordering::Acquire)
            || active.track_exhausted.load(Ordering::Acquire)
            || (dur > 0 && pos >= dur && pos > 0)
    }
}

/// Non-blocking orchestrator separating fast RT engine commands from interruptible track I/O.
#[derive(Clone)]
pub struct ControlCoordinator {
    /// Shared coordinator state accessed by FFI callers, `map-ctrl-coord`, and I/O callbacks.
    inner: Arc<CoordInner>,
    /// Join handle for the `map-ctrl-coord` background thread.
    coord_thread: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl ControlCoordinator {
    /// Spawns the `map-ctrl-coord` thread and its backing [`IoWorkerPool`], wiring `engine`,
    /// `custom_registry`, the RT `hint_rx` channel, and the `on_async_commit` callback.
    pub fn spawn(
        engine: EngineActorHandle,
        custom_registry: CustomSourceRegistry,
        hint_rx: Receiver<RtControlHint>,
        on_async_commit: AsyncCommitCallback,
    ) -> Self {
        crate::map_log!(3, "[COORD] Spawning ControlCoordinator");
        let (wake_tx, wake_rx) = crossbeam_channel::bounded::<CoordWake>(64);
        let reaper = engine.reaper().clone();

        let inner = Arc::new(CoordInner {
            engine,
            io_pool: Mutex::new(None),
            custom_registry,
            transport_epoch: AtomicU64::new(0),
            prewarm_epoch: AtomicU64::new(0),
            auto_advance_epoch: AtomicU64::new(0),
            dispatch_lock: Mutex::new(()),
            prewarm_lock: Mutex::new(()),
            last_prewarm: Mutex::new(None),
            auto_advance_inflight: Mutex::new(None),
            disposed: AtomicBool::new(false),
            on_async_commit,
            wake_tx,
        });

        let weak_for_pool = Arc::downgrade(&inner);
        let reaper_for_pool = reaper.clone();
        let pool = IoWorkerPool::spawn(
            reaper,
            Arc::new(move |completion| {
                if let Some(coord) = weak_for_pool.upgrade() {
                    coord.handle_io_completion(completion);
                } else {
                    match completion {
                        IoCompletion::Active { job, outcome } => {
                            if let IoOpenOutcome::Opened(deck) = outcome {
                                reaper_for_pool.reap_value(deck);
                            }
                            if let Some(w) = job.waiter {
                                w.resolve(Ok(None));
                            }
                        }
                        IoCompletion::Prewarm { outcome, .. } => {
                            if let IoOpenOutcome::Opened(deck) = outcome {
                                reaper_for_pool.reap_value(deck);
                            }
                        }
                    }
                }
            }),
        );
        *lock_unpoisoned(&inner.io_pool) = Some(pool);

        let coord_jh = {
            let weak = Arc::downgrade(&inner);
            match thread::Builder::new()
                .name("map-ctrl-coord".to_string())
                .spawn(move || Self::coord_loop(weak, hint_rx, wake_rx))
            {
                Ok(jh) => Some(jh),
                Err(e) => {
                    crate::map_log!(1, "[COORD] Failed to spawn map-ctrl-coord thread: {}", e);
                    None
                }
            }
        };

        Self {
            inner,
            coord_thread: Arc::new(Mutex::new(coord_jh)),
        }
    }

    /// Event loop running on `map-ctrl-coord`, multiplexing `wake_rx` control messages and
    /// `hint_rx` engine lifecycle hints until shutdown or `weak` upgrade failure.
    fn coord_loop(
        weak: Weak<CoordInner>,
        hint_rx: Receiver<RtControlHint>,
        wake_rx: Receiver<CoordWake>,
    ) {
        loop {
            crossbeam_channel::select! {
                recv(wake_rx) -> msg => {
                    let Some(coord) = weak.upgrade() else { return; };
                    match msg {
                        Ok(CoordWake::Shutdown) | Err(_) => return,
                        Ok(CoordWake::PrewarmCheck { retry_if_failed }) => {
                            coord.run_prewarm_check(retry_if_failed);
                        }
                    }
                }
                recv(hint_rx) -> msg => {
                    let Some(coord) = weak.upgrade() else { return; };
                    match msg {
                        Ok(RtControlHint::PrewarmNeeded) => {
                            coord.run_prewarm_check(true);
                        }
                        Ok(RtControlHint::AutoAdvanceNeeded {
                            expected_deck_id,
                            expected_open_gen,
                            expected_seek_epoch,
                            next_idx,
                            item,
                            should_auto_xfade,
                            auto_ms,
                        }) => {
                            coord.handle_auto_advance_hint(
                                expected_deck_id,
                                expected_open_gen,
                                expected_seek_epoch,
                                next_idx,
                                item,
                                should_auto_xfade,
                                auto_ms,
                            );
                        }
                        Err(_) => return,
                    }
                }
            }
        }
    }

    /// Triggers an asynchronous pre-warm evaluation on `map-ctrl-coord`.
    pub fn schedule_prewarm(&self) {
        self.inner.schedule_prewarm(false);
    }

    /// Returns telemetry counters for coalescing/stress assertions in tests.
    pub fn io_pool_stats(&self) -> (u64, u64) {
        if let Some(ref pool) = *lock_unpoisoned(&self.inner.io_pool) {
            (
                pool.active_opens_executed.load(Ordering::Relaxed),
                pool.active_opens_coalesced.load(Ordering::Relaxed),
            )
        } else {
            (0, 0)
        }
    }

    /// Attaches the shared `dart_resolver` bridge for subsequent track opens.
    pub fn set_dart_resolver(&self, dart_resolver: Arc<DartResolveRegistry>) {
        let _ = self.inner.engine.exec(move |ply| {
            ply.music_manager.set_dart_resolver(dart_resolver);
        });
    }

    /// Replaces the playback queue with `items` and `custom_factory` using fresh pre-built decks
    /// so `map-engine-clock` never joins threads.
    pub fn set_queue(
        &self,
        items: Vec<AudioSourceCore>,
        custom_factory: CustomSourceFactory,
    ) -> Result<(f32, f32), String> {
        let queue_len = items.len();
        crate::map_log!(3, "[COORD] set_queue(len={})", queue_len);
        let sr = self.inner.engine.snapshots().sample_rate;
        let clean_a = StreamingDeck::new_deck(sr, 2, 1024).map_err(|e| {
            let msg = format!("Failed to allocate clean deck A: {}", e);
            crate::map_log!(1, "[COORD] {}", msg);
            msg
        })?;
        let clean_b = StreamingDeck::new_deck(sr, 2, 1024).map_err(|e| {
            let msg = format!("Failed to allocate clean deck B: {}", e);
            crate::map_log!(1, "[COORD] {}", msg);
            msg
        })?;

        let pre_epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(pre_epoch);
        self.inner.custom_registry.abort_all();

        let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
        let epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(epoch);
        self.inner.custom_registry.abort_all();

        let (old_a, old_b, rg) = self.inner.engine.exec(move |ply| {
            ply.music_manager.set_custom_source_factory(custom_factory);
            let (oa, ob) = ply
                .music_manager
                .inner
                .set_queue_swap_decks(items, clean_a, clean_b);
            let rg = ply.recalculate_and_apply_replay_gain();
            (oa, ob, rg)
        })?;

        let reaper = self.inner.engine.reaper();
        reaper.reap_value(old_a);
        reaper.reap_value(old_b);
        Ok(rg)
    }

    /// Appends `items` to the end of the playback queue and invalidates any stale prewarm.
    pub fn append(&self, items: Vec<AudioSourceCore>) -> Result<(), String> {
        crate::map_log!(4, "[COORD] append(count={})", items.len());
        self.inner.bump_prewarm_epoch();
        self.inner.cancel_prewarms();
        self.inner.engine.exec(move |ply| {
            ply.music_manager.append(items);
        })?;
        self.schedule_prewarm();
        Ok(())
    }

    /// Inserts `item` immediately after the current track and invalidates any stale prewarm.
    pub fn insert_next(&self, item: AudioSourceCore) -> Result<(), String> {
        crate::map_log!(4, "[COORD] insert_next(track_id={})", item.id);
        self.inner.bump_prewarm_epoch();
        self.inner.cancel_prewarms();
        self.inner.engine.exec(move |ply| {
            ply.music_manager.insert_next(item);
        })?;
        self.schedule_prewarm();
        Ok(())
    }

    /// Removes the queue entry at `index`, opening the replacement active track with optional
    /// `include_meta` metadata if the removed entry was playing, returning `(removed, current_index, reopened)`.
    pub fn remove_at(
        &self,
        index: usize,
        include_meta: bool,
    ) -> Result<(bool, i64, bool), String> {
        self.inner.bump_prewarm_epoch();
        self.inner.cancel_prewarms();

        let waiter_opt = {
            let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
            let (removed, cur_idx, spec_opt, provisional_opt) =
                self.inner.engine.exec(move |ply| {
                    let (rem, spec) = ply.music_manager.inner.remove_item_at_plan(index);
                    let prov = if spec.is_some() {
                        Some(capture_provisional_track_snapshot(ply, true, false))
                    } else {
                        None
                    };
                    (
                        rem.is_some(),
                        ply.music_manager.current_index() as i64,
                        spec,
                        prov,
                    )
                })?;

            if !removed {
                return Ok((false, cur_idx, false));
            }
            let Some(spec) = spec_opt else {
                crate::map_log!(4, "[COORD] remove_at(index={}) removed non-active item", index);
                self.schedule_prewarm();
                return Ok((true, cur_idx, false));
            };

            crate::map_log!(
                3,
                "[COORD] remove_at(index={}) opening replacement track_id={}",
                index,
                spec.item.id
            );
            let epoch = self.inner.bump_epochs();
            let waiter = OpenWaiter::new();
            self.inner.submit_open_spec(
                epoch,
                spec,
                false,
                include_meta,
                true,
                Some(waiter.clone()),
            );
            if let Some(provisional_snap) = provisional_opt {
                (self.inner.on_async_commit)(provisional_snap);
            }
            Some(waiter)
        };

        if let Some(w) = waiter_opt {
            let _ = w.wait();
            self.schedule_prewarm();
            return Ok((true, self.inner.engine.snapshots().current_index(), true));
        }
        Ok((true, self.inner.engine.snapshots().current_index(), false))
    }

    /// Moves a queue item from `old_index` to `new_index` and refreshes prewarming if changed.
    pub fn reorder(&self, old_index: usize, new_index: usize) -> Result<bool, String> {
        self.inner.bump_prewarm_epoch();
        self.inner.cancel_prewarms();
        let moved = self
            .inner
            .engine
            .exec(move |ply| ply.music_manager.reorder(old_index, new_index))?;
        if moved {
            crate::map_log!(4, "[COORD] reorder({} -> {})", old_index, new_index);
            self.schedule_prewarm();
        }
        Ok(moved)
    }

    /// Reorders the queue to match `ordered_ids` and refreshes prewarming if the order changed.
    pub fn reorder_by_ids(&self, ordered_ids: Vec<i64>) -> Result<bool, String> {
        self.inner.bump_prewarm_epoch();
        self.inner.cancel_prewarms();
        let count = ordered_ids.len();
        let changed = self
            .inner
            .engine
            .exec(move |ply| ply.music_manager.reorder_by_ids(&ordered_ids))?;
        if changed {
            crate::map_log!(4, "[COORD] reorder_by_ids(count={}) applied", count);
            self.schedule_prewarm();
        }
        Ok(changed)
    }

    /// Clears the queue (preserving the active track when `keep_current` is `true`) and cancels
    /// affected I/O opens.
    pub fn clear_queue(&self, keep_current: bool) -> Result<i64, String> {
        crate::map_log!(3, "[COORD] clear_queue(keep_current={})", keep_current);
        if keep_current {
            self.inner.bump_prewarm_epoch();
            self.inner.cancel_prewarms();
        } else {
            let pre_epoch = self.inner.bump_epochs();
            self.inner.cancel_all_io(pre_epoch);
            self.inner.custom_registry.abort_all();
        }
        let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
        if !keep_current {
            let epoch = self.inner.bump_epochs();
            self.inner.cancel_all_io(epoch);
            self.inner.custom_registry.abort_all();
        }
        let idx = self.inner.engine.exec(move |ply| {
            ply.music_manager.clear_queue(keep_current);
            ply.music_manager.inner.sync_planned_index_to_current();
            ply.music_manager.current_index() as i64
        })?;
        if keep_current {
            self.schedule_prewarm();
        }
        Ok(idx)
    }

    /// Updates the queue loop `mode` (clamped to `0..=2`), cancelling stale auto-advances and
    /// prewarms when the mode changes.
    pub fn set_loop_mode(&self, mode: i32) -> Result<bool, String> {
        let clamped = mode.clamp(0, 2);
        let changed = self.inner.engine.exec(move |ply| {
            let prev = ply.music_manager.inner.loop_mode.load(Ordering::Relaxed);
            if prev != clamped {
                ply.music_manager.set_loop_mode(clamped);
                true
            } else {
                false
            }
        })?;
        if changed {
            crate::map_log!(3, "[COORD] Loop mode changed to {}", clamped);
            self.inner.auto_advance_epoch.fetch_add(1, Ordering::AcqRel);
            *lock_unpoisoned(&self.inner.auto_advance_inflight) = None;
            if let Some(ref pool) = *lock_unpoisoned(&self.inner.io_pool) {
                pool.cancel_auto_advance();
            }
            self.inner.bump_prewarm_epoch();
            self.inner.cancel_prewarms();
            self.schedule_prewarm();
        }
        Ok(changed)
    }

    /// Updates queue shuffle state to `enabled`, returning the updated `current_index` if changed.
    pub fn set_shuffle(&self, enabled: bool) -> Result<Option<i64>, String> {
        self.inner.bump_prewarm_epoch();
        self.inner.cancel_prewarms();
        let res = self.inner.engine.exec(move |ply| {
            let prev = ply.music_manager.is_shuffled();
            if prev != enabled {
                ply.music_manager.set_shuffle(enabled);
                ply.music_manager.inner.sync_planned_index_to_current();
                Some(ply.music_manager.current_index() as i64)
            } else {
                None
            }
        })?;
        if res.is_some() {
            crate::map_log!(3, "[COORD] Shuffle changed to {}", enabled);
            self.schedule_prewarm();
        }
        Ok(res)
    }

    /// Executes a serialized transition planned by `plan_fn` on `map-engine-clock`, either
    /// committing immediately or submitting an interruptible open with `include_meta` and waiting.
    fn execute_planned_transition<F>(
        &self,
        include_meta: bool,
        plan_fn: F,
    ) -> Result<Option<TrackTransitionSnapshot>, String>
    where
        F: FnOnce(&mut crate::core::miniaudio_player::MiniaudioPlayer, bool) -> Result<PlannedDispatch, String>
            + Send
            + 'static,
    {
        let waiter = {
            let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
            let has_inflight = self.inner.has_active_io();
            let dispatch = self
                .inner
                .engine
                .exec(move |ply| plan_fn(ply, has_inflight))??;

            match dispatch {
                PlannedDispatch::Immediate { snap, needs_prewarm } => {
                    if needs_prewarm {
                        self.inner.bump_prewarm_epoch();
                        self.schedule_prewarm();
                    }
                    (self.inner.on_async_commit)(snap.clone());
                    return Ok(Some(snap));
                }
                PlannedDispatch::NeedOpen {
                    spec,
                    provisional_snap,
                    include_replay_gain,
                } => {
                    let epoch = self.inner.bump_epochs();
                    let w = OpenWaiter::new();
                    self.inner.submit_open_spec(
                        epoch,
                        spec,
                        false,
                        include_meta,
                        include_replay_gain,
                        Some(w.clone()),
                    );
                    (self.inner.on_async_commit)(provisional_snap);
                    w
                }
            }
        };

        let result = waiter.wait().unwrap_or(Ok(None));
        if matches!(result, Ok(Some(_))) {
            self.schedule_prewarm();
        }
        result
    }

    /// Starts or resumes playback, optionally targeting queue item `id` or `position`, applying
    /// `shuffled`, seeking to `seek_ms`, and returning metadata when `include_meta` is `true`.
    pub fn play(
        &self,
        id: Option<i64>,
        position: Option<usize>,
        shuffled: Option<bool>,
        seek_ms: Option<i64>,
        include_meta: bool,
    ) -> Result<Option<TrackTransitionSnapshot>, String> {
        crate::map_log!(
            3,
            "[COORD] play(id={:?}, pos={:?}, shuffled={:?}, seek_ms={:?})",
            id,
            position,
            shuffled,
            seek_ms
        );
        self.execute_planned_transition(include_meta, move |ply, has_inflight| {
            let prev_ids = snapshot_queue_ids(ply).0;
            let plan = ply
                .music_manager
                .inner
                .plan_play(id, position, shuffled, seek_ms, has_inflight);
            let new_ids = snapshot_queue_ids(ply).0;
            let q_changed = prev_ids != new_ids;
            match plan {
                PlanOutcome::Immediate(Ok(())) => {
                    let mut snap = capture_track_snapshot(ply, q_changed, include_meta, true);
                    snap.emit_shuffle = true;
                    Ok(PlannedDispatch::Immediate {
                        snap,
                        needs_prewarm: false,
                    })
                }
                PlanOutcome::Immediate(Err(e)) => Err(e),
                PlanOutcome::CommittedStandby => {
                    let _ = ply.recalculate_and_apply_replay_gain();
                    let mut snap = capture_track_snapshot(ply, q_changed, include_meta, true);
                    snap.emit_shuffle = true;
                    Ok(PlannedDispatch::Immediate {
                        snap,
                        needs_prewarm: true,
                    })
                }
                PlanOutcome::NeedOpen(spec) => {
                    let provisional_snap = capture_provisional_track_snapshot(ply, q_changed, true);
                    Ok(PlannedDispatch::NeedOpen {
                        spec,
                        provisional_snap,
                        include_replay_gain: true,
                    })
                }
            }
        })
    }

    /// Advances to the next queue track using optional `manual_crossfade_ms` and returning
    /// metadata when `include_meta` is `true`.
    pub fn next(
        &self,
        manual_crossfade_ms: Option<u64>,
        include_meta: bool,
    ) -> Result<Option<TrackTransitionSnapshot>, String> {
        crate::map_log!(3, "[COORD] next(crossfade_ms={:?})", manual_crossfade_ms);
        self.execute_planned_transition(include_meta, move |ply, has_inflight| {
            let plan = ply
                .music_manager
                .inner
                .plan_next(manual_crossfade_ms, has_inflight);
            match plan {
                PlanOutcome::Immediate(Ok(())) => {
                    let snap = capture_track_snapshot(ply, false, include_meta, false);
                    Ok(PlannedDispatch::Immediate {
                        snap,
                        needs_prewarm: false,
                    })
                }
                PlanOutcome::Immediate(Err(e)) => Err(e),
                PlanOutcome::CommittedStandby => {
                    let _ = ply.recalculate_and_apply_replay_gain();
                    let snap = capture_track_snapshot(ply, false, include_meta, false);
                    Ok(PlannedDispatch::Immediate {
                        snap,
                        needs_prewarm: true,
                    })
                }
                PlanOutcome::NeedOpen(spec) => {
                    let provisional_snap = capture_provisional_track_snapshot(ply, false, false);
                    Ok(PlannedDispatch::NeedOpen {
                        spec,
                        provisional_snap,
                        include_replay_gain: false,
                    })
                }
            }
        })
    }

    /// Steps back to the previous queue track, returning metadata when `include_meta` is `true`.
    pub fn previous(&self, include_meta: bool) -> Result<Option<TrackTransitionSnapshot>, String> {
        crate::map_log!(3, "[COORD] previous()");
        self.execute_planned_transition(include_meta, move |ply, has_inflight| {
            let plan = ply.music_manager.inner.plan_previous(has_inflight);
            match plan {
                PlanOutcome::Immediate(Ok(())) => {
                    let snap = capture_track_snapshot(ply, false, include_meta, false);
                    Ok(PlannedDispatch::Immediate {
                        snap,
                        needs_prewarm: false,
                    })
                }
                PlanOutcome::Immediate(Err(e)) => Err(e),
                PlanOutcome::CommittedStandby => {
                    let _ = ply.recalculate_and_apply_replay_gain();
                    let snap = capture_track_snapshot(ply, false, include_meta, false);
                    Ok(PlannedDispatch::Immediate {
                        snap,
                        needs_prewarm: true,
                    })
                }
                PlanOutcome::NeedOpen(spec) => {
                    let provisional_snap = capture_provisional_track_snapshot(ply, false, false);
                    Ok(PlannedDispatch::NeedOpen {
                        spec,
                        provisional_snap,
                        include_replay_gain: false,
                    })
                }
            }
        })
    }

    /// Cancels any pending automatic track advances and seeks to `position_ms` within the active deck.
    pub fn seek(&self, position_ms: i64) -> Result<(i64, i32, bool, bool), String> {
        crate::map_log!(4, "[COORD] seek(position_ms={})", position_ms);
        self.inner.auto_advance_epoch.fetch_add(1, Ordering::AcqRel);
        if let Some(ref pool) = *lock_unpoisoned(&self.inner.io_pool) {
            pool.cancel_auto_advance();
        }
        let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
        self.inner.auto_advance_epoch.fetch_add(1, Ordering::AcqRel);
        *lock_unpoisoned(&self.inner.auto_advance_inflight) = None;
        if let Some(ref pool) = *lock_unpoisoned(&self.inner.io_pool) {
            pool.cancel_auto_advance();
        }
        let res = self.inner.engine.exec(move |ply| {
            ply.music_manager.seek(position_ms)?;
            let cur_idx = ply.music_manager.current_index();
            let state = ply
                .music_manager
                .inner
                .playback_state
                .load(Ordering::Relaxed);
            let is_playing = state == PlaybackState::Playing.as_i32();
            let is_xfading = ply.music_manager.inner.crossfade.is_active();
            Ok::<_, String>((cur_idx, state, is_playing, is_xfading))
        })??;
        if res.2 {
            self.schedule_prewarm();
        }
        Ok(res)
    }

    /// Cancels any pending opens immediately without waiting and pauses the active deck.
    pub fn pause(&self) -> Result<(i32, bool), String> {
        crate::map_log!(3, "[COORD] pause()");
        let pre_epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(pre_epoch);

        let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
        let epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(epoch);
        self.inner.engine.exec(|ply| {
            ply.music_manager.pause();
            ply.music_manager.inner.sync_planned_index_to_current();
            (
                ply.music_manager
                    .inner
                    .playback_state
                    .load(Ordering::Relaxed),
                ply.music_manager.inner.crossfade.is_active(),
            )
        })
    }

    /// Cancels any pending opens immediately without waiting and stops playback.
    pub fn stop(&self) -> Result<(i32, bool), String> {
        crate::map_log!(3, "[COORD] stop()");
        let pre_epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(pre_epoch);
        self.inner.custom_registry.abort_all();

        let _guard = lock_unpoisoned(&self.inner.dispatch_lock);
        let epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(epoch);
        self.inner.custom_registry.abort_all();
        self.inner.engine.exec(|ply| {
            ply.music_manager.stop();
            ply.music_manager.inner.sync_planned_index_to_current();
            ply.output_manager
                .visualizer_seqlock
                .write(|d| *d = VisualizerData::default());
            (
                ply.music_manager
                    .inner
                    .playback_state
                    .load(Ordering::Relaxed),
                ply.music_manager.inner.crossfade.is_active(),
            )
        })
    }

    /// Shuts down `map-ctrl-coord`, cancels all pending/active I/O opens, and joins pool threads.
    pub fn shutdown(&self) {
        if self.inner.disposed.swap(true, Ordering::AcqRel) {
            return;
        }
        crate::map_log!(3, "[COORD] Shutting down ControlCoordinator");
        let epoch = self.inner.bump_epochs();
        self.inner.cancel_all_io(epoch);
        self.inner.custom_registry.abort_all();
        let _ = self.inner.wake_tx.try_send(CoordWake::Shutdown);
        if let Some(jh) = lock_unpoisoned(&self.coord_thread).take() {
            let _ = jh.join();
        }
        if let Some(pool) = lock_unpoisoned(&self.inner.io_pool).take() {
            pool.shutdown();
        }
    }
}

impl CoordInner {
    /// Advances prewarm, auto-advance, and transport epochs, clearing in-flight auto-advance
    /// tracking and returning the new `transport_epoch`.
    fn bump_epochs(&self) -> u64 {
        self.prewarm_epoch.fetch_add(1, Ordering::AcqRel);
        self.auto_advance_epoch.fetch_add(1, Ordering::AcqRel);
        *lock_unpoisoned(&self.auto_advance_inflight) = None;
        self.transport_epoch.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// Increments and returns the updated `prewarm_epoch`.
    fn bump_prewarm_epoch(&self) -> u64 {
        self.prewarm_epoch.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// Returns `true` when [`IoWorkerPool`] has any queued or in-flight active open.
    fn has_active_io(&self) -> bool {
        lock_unpoisoned(&self.io_pool)
            .as_ref()
            .is_some_and(|p| p.has_active_work())
    }

    /// Cancels all active and standby I/O jobs and records `epoch` as the stale-open floor.
    fn cancel_all_io(&self, epoch: u64) {
        if let Some(ref pool) = *lock_unpoisoned(&self.io_pool) {
            pool.cancel_all_at_epoch(epoch);
        }
    }

    /// Cancels all queued and in-flight standby prewarm jobs without disturbing active opens.
    fn cancel_prewarms(&self) {
        if let Some(ref pool) = *lock_unpoisoned(&self.io_pool) {
            pool.cancel_prewarms();
        }
    }

    /// Posts a [`CoordWake::PrewarmCheck`] wake request carrying `retry_if_failed` to `map-ctrl-coord`.
    fn schedule_prewarm(&self, retry_if_failed: bool) {
        if self.disposed.load(Ordering::Acquire) {
            return;
        }
        let _ = self.wake_tx.try_send(CoordWake::PrewarmCheck { retry_if_failed });
    }

    /// Submits an [`ActiveOpenJob`] constructed from `spec` at `epoch` with flags
    /// `queue_changed`, `include_meta`, `include_replay_gain`, and optional `waiter`.
    fn submit_open_spec(
        &self,
        epoch: u64,
        spec: PlannedOpenSpec,
        queue_changed: bool,
        include_meta: bool,
        include_replay_gain: bool,
        waiter: Option<OpenWaiter>,
    ) {
        let Some(pool) = lock_unpoisoned(&self.io_pool).clone() else {
            if let Some(w) = waiter {
                w.resolve(Ok(None));
            }
            return;
        };
        let job = ActiveOpenJob {
            epoch,
            item: spec.item,
            custom_factory: spec.custom_factory,
            dart_resolver: spec.dart_resolver,
            template: spec.template,
            seek_ms: spec.seek_ms,
            kind: ActiveOpenKind::Manual {
                manual_crossfade_ms: spec.manual_crossfade_ms,
                force_play: spec.force_play,
            },
            queue_changed,
            include_meta,
            include_replay_gain,
            cancel: CancelToken::new(),
            waiter,
        };
        pool.submit_active(job);
    }

    /// Evaluates whether the upcoming queue item needs standby prewarming and submits a
    /// [`PrewarmJob`] when eligible (retrying previously attempted keys only if `retry_if_failed`).
    fn run_prewarm_check(&self, retry_if_failed: bool) {
        if self.disposed.load(Ordering::Acquire) || self.has_active_io() {
            return;
        }
        let _guard = lock_unpoisoned(&self.prewarm_lock);
        let p_epoch = self.prewarm_epoch.load(Ordering::Acquire);
        let Ok(candidate) = self.engine.exec(|ply| {
            let Some((_idx, item)) = ply.music_manager.inner.expected_prewarm_target() else {
                return None;
            };
            if ply.music_manager.inner.standby_is_ready_for(&item) {
                return None;
            }
            let active = ply.music_manager.active_deck_ref();
            let active_deck_id = active.deck_id;
            let active_open_gen = active.open_generation.load(Ordering::Acquire);
            let tpl = ply.music_manager.inner.capture_dsp_template();
            let factory = ply.music_manager.inner.custom_source_factory.clone();
            let resolver = ply.music_manager.inner.dart_resolver.clone();
            Some((active_deck_id, active_open_gen, item, tpl, factory, resolver))
        }) else {
            return;
        };
        let Some((active_deck_id, active_open_gen, item, template, custom_factory, dart_resolver)) =
            candidate
        else {
            return;
        };
        if p_epoch != self.prewarm_epoch.load(Ordering::Acquire) {
            return;
        }

        {
            let mut last = lock_unpoisoned(&self.last_prewarm);
            if let Some((e, dk, og, id, ref src, retried)) = *last {
                if e == p_epoch
                    && dk == active_deck_id
                    && og == active_open_gen
                    && id == item.id
                    && src == &item.source
                {
                    if !retry_if_failed || retried {
                        return;
                    }
                }
            }
            *last = Some((
                p_epoch,
                active_deck_id,
                active_open_gen,
                item.id,
                item.source.clone(),
                retry_if_failed,
            ));
        }

        if let Some(pool) = lock_unpoisoned(&self.io_pool).clone() {
            crate::map_log!(
                4,
                "[COORD] Scheduling standby prewarm for track_id={} (prewarm_epoch={})",
                item.id,
                p_epoch
            );
            pool.submit_prewarm(PrewarmJob {
                epoch: p_epoch,
                item,
                custom_factory,
                dart_resolver,
                template,
                cancel: CancelToken::new(),
            });
        }
    }

    /// Validates an engine auto-advance hint against `expected_deck_id`, `expected_open_gen`,
    /// `expected_seek_epoch`, `next_idx`, `hint_item`, `should_auto_xfade`, and `auto_ms`, and
    /// dispatches an [`ActiveOpenKind::AutoAdvance`] open if still due.
    #[allow(clippy::too_many_arguments)]
    fn handle_auto_advance_hint(
        &self,
        expected_deck_id: usize,
        expected_open_gen: u64,
        expected_seek_epoch: u64,
        next_idx: usize,
        hint_item: AudioSourceCore,
        should_auto_xfade: bool,
        auto_ms: u64,
    ) {
        if self.disposed.load(Ordering::Acquire) {
            return;
        }
        let key = (expected_deck_id, expected_open_gen, expected_seek_epoch);
        {
            let inflight = lock_unpoisoned(&self.auto_advance_inflight);
            if *inflight == Some(key) {
                return;
            }
        }

        let _guard = lock_unpoisoned(&self.dispatch_lock);
        if self.has_active_io() {
            return;
        }
        let Ok(Some((tpl, factory, resolver, live_item))) = self.engine.exec(move |ply| {
            let cur_playback = PlaybackState::from_i32(
                ply.music_manager
                    .inner
                    .playback_state
                    .load(Ordering::Relaxed),
            );
            let active = ply.music_manager.active_deck_ref();
            if cur_playback != PlaybackState::Playing
                || ply.music_manager.inner.crossfade.is_active()
                || active.deck_id != expected_deck_id
                || active.open_generation.load(Ordering::Acquire) != expected_open_gen
                || active.seek_epoch.load(Ordering::Acquire) != expected_seek_epoch
                || !is_auto_advance_due(active, should_auto_xfade, auto_ms)
            {
                return None;
            }
            let item = read_unpoisoned(&ply.music_manager.inner.queue)
                .get(next_idx)
                .cloned()?;
            if item.id != hint_item.id {
                return None;
            }
            Some((
                ply.music_manager.inner.capture_dsp_template(),
                ply.music_manager.inner.custom_source_factory.clone(),
                ply.music_manager.inner.dart_resolver.clone(),
                item,
            ))
        }) else {
            return;
        };

        let Some(pool) = lock_unpoisoned(&self.io_pool).clone() else {
            return;
        };
        let epoch = self.bump_epochs();
        let auto_epoch = self.auto_advance_epoch.load(Ordering::Acquire);
        *lock_unpoisoned(&self.auto_advance_inflight) = Some(key);
        crate::map_log!(
            4,
            "[COORD] Submitting auto-advance open (epoch={}, next_idx={}, track_id={}, xfade={}, auto_ms={})",
            epoch,
            next_idx,
            live_item.id,
            should_auto_xfade,
            auto_ms
        );
        pool.submit_active(ActiveOpenJob {
            epoch,
            item: live_item,
            custom_factory: factory,
            dart_resolver: resolver,
            template: tpl,
            seek_ms: None,
            kind: ActiveOpenKind::AutoAdvance {
                should_auto_xfade,
                auto_ms,
                expected_deck_id,
                expected_open_gen,
                expected_seek_epoch,
                auto_epoch,
            },
            queue_changed: false,
            include_meta: true,
            include_replay_gain: !should_auto_xfade,
            cancel: CancelToken::new(),
            waiter: None,
        });
    }

    /// Processes an [`IoCompletion`] callback from [`IoWorkerPool`], committing non-stale decks,
    /// reconciling failed/aborted transitions, reaping unused decks, and resolving waiters.
    fn handle_io_completion(self: &Arc<Self>, completion: IoCompletion) {
        let reaper = self.engine.reaper().clone();
        match completion {
            IoCompletion::Prewarm { job, outcome } => {
                let deck = match outcome {
                    IoOpenOutcome::Opened(deck) => deck,
                    IoOpenOutcome::Failed(code, ref msg) => {
                        crate::map_log!(
                            2,
                            "[COORD] Prewarm open failed (track_id={}, code={}, err={:?})",
                            job.item.id,
                            code,
                            msg
                        );
                        return;
                    }
                    IoOpenOutcome::Aborted => {
                        crate::map_log!(4, "[COORD] Prewarm open aborted (track_id={})", job.item.id);
                        return;
                    }
                };
                if job.epoch != self.prewarm_epoch.load(Ordering::Acquire)
                    || self.disposed.load(Ordering::Acquire)
                {
                    reaper.reap_value(deck);
                    return;
                }
                let expected_epoch = job.epoch;
                let item = job.item;
                let coord = self.clone();
                let reaper_cb = reaper.clone();
                self.engine.exec_async(move |ply| {
                    if expected_epoch != coord.prewarm_epoch.load(Ordering::Acquire) {
                        reaper_cb.reap_value(deck);
                        return;
                    }
                    match ply.music_manager.inner.commit_prepared_standby(deck, &item) {
                        Ok(displaced) => {
                            crate::map_log!(
                                4,
                                "[COORD] Committed standby prewarm (track_id={}, epoch={})",
                                item.id,
                                expected_epoch
                            );
                            reaper_cb.reap_value(displaced);
                        }
                        Err(unused) => {
                            crate::map_log!(
                                4,
                                "[COORD] Discarded standby prewarm (track_id={}, epoch={})",
                                item.id,
                                expected_epoch
                            );
                            reaper_cb.reap_value(unused);
                        }
                    }
                });
            }
            IoCompletion::Active { job, outcome } => {
                let waiter = job.waiter.clone();
                let resolve_ok_none = || {
                    if let Some(ref w) = waiter {
                        w.resolve(Ok(None));
                    }
                };

                if job.epoch != self.transport_epoch.load(Ordering::Acquire)
                    || self.disposed.load(Ordering::Acquire)
                {
                    crate::map_log!(
                        4,
                        "[COORD] Discarding stale active I/O completion (job_epoch={}, track_id={})",
                        job.epoch,
                        job.item.id
                    );
                    if let IoOpenOutcome::Opened(deck) = outcome {
                        reaper.reap_value(deck);
                    }
                    resolve_ok_none();
                    return;
                }

                match outcome {
                    IoOpenOutcome::Aborted => {
                        crate::map_log!(
                            4,
                            "[COORD] Active I/O open aborted (epoch={}, track_id={})",
                            job.epoch,
                            job.item.id
                        );
                        let coord = self.clone();
                        let expected_epoch = job.epoch;
                        let auto_epoch_opt = match job.kind {
                            ActiveOpenKind::AutoAdvance { auto_epoch, .. } => Some(auto_epoch),
                            ActiveOpenKind::Manual { .. } => None,
                        };
                        {
                            let _guard = lock_unpoisoned(&self.dispatch_lock);
                            if expected_epoch == self.transport_epoch.load(Ordering::Acquire)
                                && !self.disposed.load(Ordering::Acquire)
                            {
                                let _ = self.engine.exec(move |ply| {
                                    if expected_epoch
                                        != coord.transport_epoch.load(Ordering::Acquire)
                                    {
                                        return;
                                    }
                                    if let Some(exp_auto) = auto_epoch_opt {
                                        if exp_auto
                                            != coord.auto_advance_epoch.load(Ordering::Acquire)
                                        {
                                            // Seek/user preempt already cleaned up pending state synchronously.
                                            return;
                                        }
                                        let prev_auto = ply
                                            .music_manager
                                            .inner
                                            .pending_auto_advance_prev_index
                                            .swap(-1, Ordering::AcqRel);
                                        if prev_auto >= 0 {
                                            ply.music_manager
                                                .inner
                                                .current_index
                                                .store(prev_auto, Ordering::Release);
                                            ply.music_manager.inner.sync_planned_index_to_current();
                                        }
                                    } else {
                                        ply.music_manager
                                            .inner
                                            .pending_auto_advance_prev_index
                                            .store(-1, Ordering::Release);
                                    }
                                    ply.music_manager
                                        .inner
                                        .pending_open_active
                                        .store(false, Ordering::Release);
                                    ply.music_manager
                                        .inner
                                        .pending_open_seek_ms
                                        .store(0, Ordering::Release);
                                });
                            }
                        }
                        resolve_ok_none();
                    }
                    IoOpenOutcome::Failed(code, detail_msg) => {
                        crate::map_log!(
                            1,
                            "[COORD] Active I/O open failed (epoch={}, track_id={}, code={}, err={:?})",
                            job.epoch,
                            job.item.id,
                            code,
                            detail_msg
                        );
                        let auto_params = match job.kind {
                            ActiveOpenKind::AutoAdvance {
                                expected_deck_id,
                                expected_open_gen,
                                expected_seek_epoch,
                                auto_epoch,
                                ..
                            } => Some((
                                expected_deck_id,
                                expected_open_gen,
                                expected_seek_epoch,
                                auto_epoch,
                            )),
                            ActiveOpenKind::Manual { .. } => None,
                        };
                        let coord = self.clone();
                        let expected_epoch = job.epoch;
                        let include_meta = job.include_meta;
                        {
                            let _guard = lock_unpoisoned(&self.dispatch_lock);
                            if expected_epoch == self.transport_epoch.load(Ordering::Acquire)
                                && !self.disposed.load(Ordering::Acquire)
                            {
                                let reconcile_snap = self
                                    .engine
                                    .exec(move |ply| {
                                        if expected_epoch
                                            != coord.transport_epoch.load(Ordering::Acquire)
                                        {
                                            return None;
                                        }
                                        ply.music_manager
                                            .inner
                                            .pending_open_active
                                            .store(false, Ordering::Release);
                                        ply.music_manager
                                            .inner
                                            .pending_open_seek_ms
                                            .store(0, Ordering::Release);
                                        let prev_auto = ply
                                            .music_manager
                                            .inner
                                            .pending_auto_advance_prev_index
                                            .swap(-1, Ordering::AcqRel);
                                        if let Some((exp_deck, exp_gen, exp_seek, exp_auto)) =
                                            auto_params
                                        {
                                            let active = ply.music_manager.active_deck_ref();
                                            let cur_playback = PlaybackState::from_i32(
                                                ply.music_manager
                                                    .inner
                                                    .playback_state
                                                    .load(Ordering::Relaxed),
                                            );
                                            if exp_auto
                                                == coord.auto_advance_epoch.load(Ordering::Acquire)
                                                && cur_playback == PlaybackState::Playing
                                                && active.deck_id == exp_deck
                                                && active.open_generation.load(Ordering::Acquire)
                                                    == exp_gen
                                                && active.seek_epoch.load(Ordering::Acquire)
                                                    == exp_seek
                                            {
                                                if prev_auto >= 0 {
                                                    ply.music_manager
                                                        .inner
                                                        .current_index
                                                        .store(prev_auto, Ordering::Release);
                                                }
                                                ply.music_manager
                                                    .inner
                                                    .sync_planned_index_to_current();
                                                ply.music_manager.inner.playback_state.store(
                                                    PlaybackState::Stopped.as_i32(),
                                                    Ordering::Release,
                                                );
                                                ply.music_manager
                                                    .active_deck_mut()
                                                    .finish_at_end();
                                                return Some(capture_track_snapshot(
                                                    ply,
                                                    false,
                                                    include_meta,
                                                    false,
                                                ));
                                            }
                                            None
                                        } else {
                                            let item_id_opt = {
                                                let active = ply.music_manager.active_deck_ref();
                                                if active.state.load(Ordering::Acquire)
                                                    == STATE_PLAYING
                                                {
                                                    active.queue_item_id
                                                } else {
                                                    None
                                                }
                                            };
                                            if let Some(item_id) = item_id_opt {
                                                let pos_opt =
                                                    read_unpoisoned(&ply.music_manager.inner.queue)
                                                        .iter()
                                                        .position(|it| it.id == item_id);
                                                if let Some(pos) = pos_opt {
                                                    ply.music_manager
                                                        .inner
                                                        .current_index
                                                        .store(pos as i64, Ordering::Release);
                                                    ply.music_manager
                                                        .inner
                                                        .sync_planned_index_to_current();
                                                    return Some(capture_track_snapshot(
                                                        ply,
                                                        false,
                                                        include_meta,
                                                        true,
                                                    ));
                                                }
                                            }
                                            None
                                        }
                                    })
                                    .ok()
                                    .flatten();
                                if let Some(snap) = reconcile_snap {
                                    (self.on_async_commit)(snap);
                                }
                                if let Some((exp_deck, exp_gen, exp_seek, exp_auto)) = auto_params {
                                    if exp_auto == self.auto_advance_epoch.load(Ordering::Acquire) {
                                        let mut inflight =
                                            lock_unpoisoned(&self.auto_advance_inflight);
                                        if *inflight == Some((exp_deck, exp_gen, exp_seek)) {
                                            *inflight = None;
                                        }
                                    }
                                }
                            }
                        }
                        if let Some(ref w) = waiter {
                            w.resolve(Err(detail_msg
                                .unwrap_or_else(|| format!("Failed to open track: error {}", code))));
                        }
                    }
                    IoOpenOutcome::Opened(deck) => {
                        let coord = self.clone();
                        let expected_epoch = job.epoch;
                        let item = job.item.clone();
                        let item_id = item.id;
                        let seek_ms = job.seek_ms;
                        let kind = job.kind.clone();
                        let queue_changed = job.queue_changed;
                        let include_meta = job.include_meta;
                        let include_rg = job.include_replay_gain;

                        enum CommitResult {
                            Committed(Option<Box<StreamingDeck>>, TrackTransitionSnapshot),
                            Unused(Box<StreamingDeck>),
                            EngineErr,
                        }

                        let outcome_res = {
                            let _guard = lock_unpoisoned(&self.dispatch_lock);
                            if expected_epoch != self.transport_epoch.load(Ordering::Acquire)
                                || self.disposed.load(Ordering::Acquire)
                            {
                                CommitResult::Unused(deck)
                            } else {
                                let exec_res = self.engine.exec(move |ply| {
                                    if expected_epoch
                                        != coord.transport_epoch.load(Ordering::Acquire)
                                    {
                                        return Err(deck);
                                    }
                                    let exists = read_unpoisoned(&ply.music_manager.inner.queue)
                                        .iter()
                                        .any(|it| it.id == item.id);
                                    if !exists {
                                        return Err(deck);
                                    }

                                    let mode = match kind {
                                        ActiveOpenKind::Manual {
                                            manual_crossfade_ms,
                                            force_play,
                                        } => TransitionCommitMode::Manual {
                                            manual_crossfade_ms,
                                            force_play,
                                        },
                                        ActiveOpenKind::AutoAdvance {
                                            should_auto_xfade,
                                            auto_ms,
                                            expected_deck_id,
                                            expected_open_gen,
                                            expected_seek_epoch,
                                            auto_epoch,
                                        } => {
                                            let cur_playback = PlaybackState::from_i32(
                                                ply.music_manager
                                                    .inner
                                                    .playback_state
                                                    .load(Ordering::Relaxed),
                                            );
                                            let active = ply.music_manager.active_deck_ref();
                                            if auto_epoch
                                                != coord.auto_advance_epoch.load(Ordering::Acquire)
                                                || cur_playback != PlaybackState::Playing
                                                || ply.music_manager.inner.crossfade.is_active()
                                                || active.deck_id != expected_deck_id
                                                || active.open_generation.load(Ordering::Acquire)
                                                    != expected_open_gen
                                                || active.seek_epoch.load(Ordering::Acquire)
                                                    != expected_seek_epoch
                                                || !is_auto_advance_due(
                                                    active,
                                                    should_auto_xfade,
                                                    auto_ms,
                                                )
                                            {
                                                return Err(deck);
                                            }
                                            let dur = active.duration_ms.load(Ordering::Relaxed);
                                            let pos = active.position_ms.load(Ordering::Relaxed);
                                            let exhausted =
                                                active.track_exhausted.load(Ordering::Acquire);
                                            if should_auto_xfade
                                                && !exhausted
                                                && dur > pos + 50
                                            {
                                                let eff_ms = ((dur - pos) as u64).clamp(50, auto_ms);
                                                TransitionCommitMode::AutoCrossfade { eff_ms }
                                            } else {
                                                TransitionCommitMode::AutoAdvanceGapless
                                            }
                                        }
                                    };

                                    let displaced = ply.music_manager.inner.commit_transition_internal(
                                        Some(deck),
                                        &item,
                                        seek_ms,
                                        mode,
                                    );
                                    let _ = ply.recalculate_and_apply_replay_gain();
                                    let snap = capture_track_snapshot(
                                        ply,
                                        queue_changed,
                                        include_meta,
                                        include_rg,
                                    );
                                    Ok((displaced, snap))
                                });

                                match exec_res {
                                    Ok(Ok((displaced_opt, snap))) => {
                                        (self.on_async_commit)(snap.clone());
                                        CommitResult::Committed(displaced_opt, snap)
                                    }
                                    Ok(Err(unused_deck)) => CommitResult::Unused(unused_deck),
                                    Err(_) => CommitResult::EngineErr,
                                }
                            }
                        };

                        match outcome_res {
                            CommitResult::Committed(displaced_opt, snap) => {
                                crate::map_log!(
                                    3,
                                    "[COORD] Active I/O open committed (epoch={}, track_id={})",
                                    expected_epoch,
                                    item_id
                                );
                                if let Some(displaced) = displaced_opt {
                                    reaper.reap_value(displaced);
                                }
                                if let Some(ref w) = waiter {
                                    w.resolve(Ok(Some(snap)));
                                } else {
                                    self.schedule_prewarm(false);
                                }
                            }
                            CommitResult::Unused(unused_deck) => {
                                crate::map_log!(
                                    4,
                                    "[COORD] Discarding unused opened deck (epoch={}, track_id={})",
                                    expected_epoch,
                                    item_id
                                );
                                reaper.reap_value(unused_deck);
                                resolve_ok_none();
                            }
                            CommitResult::EngineErr => {
                                crate::map_log!(
                                    2,
                                    "[COORD] Engine error committing opened deck (epoch={}, track_id={})",
                                    expected_epoch,
                                    item_id
                                );
                                resolve_ok_none();
                            }
                        }
                    }
                }
            }
        }
    }
}
