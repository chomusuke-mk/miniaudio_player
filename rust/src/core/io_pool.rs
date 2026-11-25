//! Bounded interruptible I/O worker pool with local fast-lane isolation and epoch coalescing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use crate::sync::thread::{self, JoinHandle};
use crate::sync::MonotonicInstant as Instant;

use crate::bridge::ffi::MAP_SUCCESS;
use crate::buffer::DartResolveRegistry;
use crate::core::dual_source::{
    AudioSourceCore, CustomSourceFactory, DualSource, StreamingDeck, MAP_ERROR_ABORTED,
};
use crate::core::dual_source_control::DeckDspTemplate;
use crate::core::engine_actor::TrackTransitionSnapshot;
use crate::sync::{lock_unpoisoned, CancelToken, ReaperHandle};

/// Generic thread-safe completion waiter shared between async I/O workers and FFI callers.
#[derive(Clone)]
pub struct AsyncWaiter<T: Clone> {
    /// Mutex-protected completion slot paired with a condvar for blocking waiters.
    inner: Arc<(Mutex<Option<T>>, Condvar)>,
}

impl<T: Clone> Default for AsyncWaiter<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Clone> AsyncWaiter<T> {
    /// Creates an unresolved [`AsyncWaiter`].
    pub fn new() -> Self {
        Self {
            inner: Arc::new((Mutex::new(None), Condvar::new())),
        }
    }

    /// Resolves the waiter once with `result` if not already completed and wakes all waiting callers.
    pub fn resolve(&self, result: T) {
        let (lock, cv) = &*self.inner;
        let mut guard = lock_unpoisoned(lock);
        if guard.is_none() {
            *guard = Some(result);
            cv.notify_all();
        }
    }

    /// Blocks until the operation completes or is superseded/cancelled.
    pub fn wait(&self) -> Option<T> {
        let (lock, cv) = &*self.inner;
        if crate::sync::can_block_current_thread() {
            let mut guard = lock_unpoisoned(lock);
            while guard.is_none() {
                guard = cv.wait(guard).unwrap_or_else(|e| e.into_inner());
            }
            guard.clone()
        } else {
            loop {
                {
                    let guard = lock_unpoisoned(lock);
                    if guard.is_some() {
                        return guard.clone();
                    }
                }
                std::hint::spin_loop();
            }
        }
    }
}

/// Completion waiter for `ControlCoordinator` active opens.
pub type OpenWaiter = AsyncWaiter<Result<Option<TrackTransitionSnapshot>, String>>;

/// Kind of active track open operation dispatched through [`IoWorkerPool`].
#[derive(Clone)]
pub enum ActiveOpenKind {
    /// User-initiated playback or track-skip open.
    Manual {
        /// Optional explicit crossfade duration in milliseconds (`None` uses default behavior).
        manual_crossfade_ms: Option<u64>,
        /// Whether playback must start immediately once the track opens.
        force_play: bool,
    },
    /// Automatic track-end or auto-crossfade transition scheduled by the engine clock.
    AutoAdvance {
        /// Whether an overlapping auto-crossfade should be started if still eligible.
        should_auto_xfade: bool,
        /// Configured auto-crossfade duration in milliseconds.
        auto_ms: u64,
        /// Expected active deck slot ID at the time the hint was emitted.
        expected_deck_id: usize,
        /// Expected active deck `open_generation` when the hint was emitted.
        expected_open_gen: u64,
        /// Expected active deck `seek_epoch` when the hint was emitted.
        expected_seek_epoch: u64,
        /// Coordinator auto-advance epoch guarding against stale completions after seek/loop edits.
        auto_epoch: u64,
    },
}

impl ActiveOpenKind {
    /// Returns `true` when this active open was scheduled by automatic end-of-track advancement.
    #[inline]
    pub fn is_auto_advance(&self) -> bool {
        matches!(self, Self::AutoAdvance { .. })
    }
}

/// Asynchronous job opening and pre-decoding the target foreground track on a fresh deck.
#[derive(Clone)]
pub struct ActiveOpenJob {
    /// Monotonic transport epoch used to discard superseded completions.
    pub epoch: u64,
    /// Queue item descriptor to open.
    pub item: AudioSourceCore,
    /// Optional custom PCM/demuxed source factory for `custom://` items.
    pub custom_factory: Option<CustomSourceFactory>,
    /// Optional Dart URL resolution registry for dynamic sources.
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    /// DSP and playback configuration template captured from the active player state.
    pub template: DeckDspTemplate,
    /// Optional initial seek target in milliseconds after opening.
    pub seek_ms: Option<i64>,
    /// Whether this open is manual or an automatic track transition.
    pub kind: ActiveOpenKind,
    /// Whether the queue membership changed as part of the originating command.
    pub queue_changed: bool,
    /// Whether parsed metadata should be included in the emitted snapshot.
    pub include_meta: bool,
    /// Whether ReplayGain telemetry should be recalculated/included on completion.
    pub include_replay_gain: bool,
    /// Cooperative cancellation token for aborting in-flight I/O.
    pub cancel: CancelToken,
    /// Optional synchronous waiter resolved when the open commits, fails, or is superseded.
    pub waiter: Option<OpenWaiter>,
}

/// Asynchronous job opening the upcoming track on a background standby deck.
#[derive(Clone)]
pub struct PrewarmJob {
    /// Monotonic prewarm epoch used to discard stale standby decks.
    pub epoch: u64,
    /// Upcoming queue item descriptor to prewarm.
    pub item: AudioSourceCore,
    /// Optional custom source factory for `custom://` items.
    pub custom_factory: Option<CustomSourceFactory>,
    /// Optional Dart URL resolution registry for dynamic sources.
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    /// DSP and playback configuration template captured for the standby deck.
    pub template: DeckDspTemplate,
    /// Cooperative cancellation token for aborting the prewarm open.
    pub cancel: CancelToken,
}

/// Open result produced by an [`IoWorkerPool`] worker thread.
pub enum IoOpenOutcome {
    /// Track opened successfully onto a newly allocated [`StreamingDeck`].
    Opened(Box<StreamingDeck>),
    /// Open was cancelled or superseded before completion.
    Aborted,
    /// Open failed with an engine error code and optional diagnostic message.
    Failed(i32, Option<String>),
}

/// Completed job delivered to [`ControlCoordinator`] handlers.
pub enum IoCompletion {
    /// Completion of a foreground [`ActiveOpenJob`].
    Active {
        /// Original active open job metadata.
        job: ActiveOpenJob,
        /// Outcome of opening the target track.
        outcome: IoOpenOutcome,
    },
    /// Completion of a background [`PrewarmJob`].
    Prewarm {
        /// Original prewarm job metadata.
        job: PrewarmJob,
        /// Outcome of prewarming the upcoming track.
        outcome: IoOpenOutcome,
    },
}

/// Callback invoked by worker threads upon completing an active or prewarm open job.
pub type CompletionCallback = Arc<dyn Fn(IoCompletion) + Send + Sync>;

/// Queued standby prewarm entry paired with its unique pool-assigned identifier.
struct QueuedPrewarm {
    /// Unique monotonically assigned prewarm identifier for promotion lookup.
    uid: u64,
    /// Standby prewarm job payload.
    job: PrewarmJob,
}

/// Tracked in-flight active open tuple: `(epoch, is_auto_advance, cancel_token, waiter)`.
type InflightActiveEntry = (u64, bool, CancelToken, Option<OpenWaiter>);
/// Tracked in-flight prewarm tuple: `(uid, item_id, item_source, cancel_token)`.
type InflightPrewarmEntry = (u64, i64, String, CancelToken);

/// Synchronized mailbox holding queued, in-flight, and promoted I/O jobs across lanes.
struct PoolMailbox {
    /// Whether pool shutdown has been initiated.
    shutdown: bool,
    /// Next unique identifier assigned to queued prewarm jobs.
    next_prewarm_uid: u64,
    /// Latest queued active job for the local fast lane.
    local_active: Option<ActiveOpenJob>,
    /// Latest queued active job for the network lane.
    net_active: Option<ActiveOpenJob>,
    /// Latest queued prewarm job for the local fast lane.
    local_prewarm: Option<QueuedPrewarm>,
    /// Latest queued prewarm job for the network lane.
    net_prewarm: Option<QueuedPrewarm>,
    /// Currently executing active jobs on the local lane.
    inflight_local_active: Vec<InflightActiveEntry>,
    /// Currently executing active jobs on the network lane.
    inflight_net_active: Vec<InflightActiveEntry>,
    /// Currently executing prewarm jobs on the local lane.
    inflight_local_prewarm: Vec<InflightPrewarmEntry>,
    /// Currently executing prewarm jobs on the network lane.
    inflight_net_prewarm: Vec<InflightPrewarmEntry>,
    /// In-flight prewarm UIDs promoted to foreground active jobs while still opening.
    promoted_prewarms: HashMap<u64, (ActiveOpenJob, CancelToken)>,
    /// Coalescing quiet-window deadline for rapid network track skips.
    net_coalesce_until: Option<Instant>,
    /// Maximum burst deadline capping consecutive network coalescing extensions.
    net_burst_cap: Option<Instant>,
}

/// Collects cancellation tokens and waiters from `entries`, optionally filtering to `auto_only`.
#[inline]
fn collect_inflight_active(
    entries: &[InflightActiveEntry],
    auto_only: bool,
    tokens: &mut Vec<CancelToken>,
    waiters: &mut Vec<OpenWaiter>,
) {
    for (_, is_auto, tok, waiter_opt) in entries {
        if auto_only && !*is_auto {
            continue;
        }
        tokens.push(tok.clone());
        if let Some(ref w) = waiter_opt {
            waiters.push(w.clone());
        }
    }
}

/// Removes a queued active job from `slot` when `!auto_only` or when it is an auto-advance job,
/// appending its cancellation token to `tokens` and waiter to `waiters`.
#[inline]
fn take_active_matching(
    slot: &mut Option<ActiveOpenJob>,
    auto_only: bool,
    tokens: &mut Vec<CancelToken>,
    waiters: &mut Vec<OpenWaiter>,
) {
    let should_take = slot
        .as_ref()
        .is_some_and(|job| !auto_only || job.kind.is_auto_advance());
    if should_take {
        if let Some(old) = slot.take() {
            tokens.push(old.cancel);
            if let Some(w) = old.waiter {
                waiters.push(w);
            }
        }
    }
}

/// Work unit dequeued by a pool worker thread.
enum NextPoolWork {
    /// Foreground active open job.
    Active(ActiveOpenJob),
    /// Background standby prewarm job with its pool-assigned `uid`.
    Prewarm {
        /// Unique prewarm identifier used to detect promotion on completion.
        uid: u64,
        /// Standby prewarm job payload.
        job: PrewarmJob,
    },
}

/// Execution lane isolating low-latency local opens from slow network opens.
#[derive(Clone, Copy, PartialEq, Eq)]
enum WorkerLane {
    /// Dedicated worker lane for file, memory, and `custom://` sources.
    Local,
    /// Multi-worker lane for `http://`, `https://`, and `icy://` network streams.
    Network,
}

/// Bounded interruptible thread pool separating fast local opens from slow network opens.
///
/// Runs `1` dedicated `map-io-local` worker for file/memory/`custom://` tracks (0 ms wait)
/// and `4` `map-io-net-*` workers for `http://`, `https://`, and `icy://` tracks with
/// rapid-skip epoch coalescing.
pub struct IoWorkerPool {
    /// Synchronized job mailbox and condition variable shared across all worker lanes.
    state: Arc<(Mutex<PoolMailbox>, Condvar)>,
    /// Pool-wide cancellation token triggered on shutdown.
    shutdown_token: CancelToken,
    /// Off-RT reaper handle used to drop cancelled/superseded decks safely.
    reaper: ReaperHandle,
    /// Count of currently running worker threads paired with a shutdown condvar.
    active_workers: Arc<(Mutex<usize>, Condvar)>,
    /// Worker completion flags and join handles tracked for bounded shutdown.
    workers_done_flags: Mutex<Vec<(Arc<AtomicBool>, JoinHandle<()>)>>,
    /// Callback invoked whenever an active or prewarm job finishes.
    on_complete: CompletionCallback,
    /// Highest transport epoch observed by the pool for discarding stale submissions.
    latest_epoch: Arc<AtomicU64>,
    /// Total number of active track opens executed by workers.
    pub active_opens_executed: Arc<AtomicU64>,
    /// Total number of active track open requests coalesced or superseded before completion.
    pub active_opens_coalesced: Arc<AtomicU64>,
}

impl IoWorkerPool {
    /// Number of worker threads dedicated to network (`http://`, `https://`, `icy://`) opens.
    const NET_WORKERS: usize = 4;
    /// Quiet-window delay in milliseconds used to coalesce rapid network skips.
    const COALESCE_QUIET_MS: u64 = 18;
    /// Maximum cumulative coalescing delay in milliseconds during a rapid skip burst.
    const COALESCE_BURST_CAP_MS: u64 = 140;

    /// Returns `true` when `item` should run on the low-latency `map-io-local` lane.
    #[inline]
    pub fn is_local_item(item: &AudioSourceCore) -> bool {
        if item.data_bytes.is_some() {
            return true;
        }
        let s = item.source.trim();
        !(s.starts_with("http://") || s.starts_with("https://") || s.starts_with("icy://"))
    }

    /// Spawns the `IoWorkerPool` (`1` local worker and `4` network workers) backed by `reaper`
    /// and delivering completed opens to `on_complete`.
    pub fn spawn(reaper: ReaperHandle, on_complete: CompletionCallback) -> Arc<Self> {
        crate::map_log!(
            3,
            "[IO_POOL] Spawning IoWorkerPool (local=1, net={})",
            Self::NET_WORKERS
        );
        let state = Arc::new((
            Mutex::new(PoolMailbox {
                shutdown: false,
                next_prewarm_uid: 1,
                local_active: None,
                net_active: None,
                local_prewarm: None,
                net_prewarm: None,
                inflight_local_active: Vec::new(),
                inflight_net_active: Vec::new(),
                inflight_local_prewarm: Vec::new(),
                inflight_net_prewarm: Vec::new(),
                promoted_prewarms: HashMap::new(),
                net_coalesce_until: None,
                net_burst_cap: None,
            }),
            Condvar::new(),
        ));

        let active_workers = Arc::new((Mutex::new(0usize), Condvar::new()));

        let pool = Arc::new(Self {
            state,
            shutdown_token: CancelToken::new(),
            reaper,
            active_workers,
            workers_done_flags: Mutex::new(Vec::new()),
            on_complete,
            latest_epoch: Arc::new(AtomicU64::new(0)),
            active_opens_executed: Arc::new(AtomicU64::new(0)),
            active_opens_coalesced: Arc::new(AtomicU64::new(0)),
        });

        {
            let mut handles = lock_unpoisoned(&pool.workers_done_flags);
            Self::spawn_worker_thread(&pool, "map-io-local", WorkerLane::Local, &mut handles);
            for i in 0..Self::NET_WORKERS {
                let name = format!("map-io-net-{}", i);
                Self::spawn_worker_thread(&pool, &name, WorkerLane::Network, &mut handles);
            }
        }

        pool
    }

    /// Spawns a single worker thread named `name` servicing `lane` on `pool`, recording its
    /// completion flag and join handle in `handles`.
    fn spawn_worker_thread(
        pool: &Arc<Self>,
        name: &str,
        lane: WorkerLane,
        handles: &mut Vec<(Arc<AtomicBool>, JoinHandle<()>)>,
    ) {
        {
            let (wlock, _) = &*pool.active_workers;
            let mut cnt = lock_unpoisoned(wlock);
            *cnt += 1;
        }
        let done = Arc::new(AtomicBool::new(false));
        let done_clone = done.clone();
        let pool_weak = Arc::downgrade(pool);

        let jh = thread::Builder::new()
            .name(name.to_string())
            .spawn(move || {
                while let Some(pool) = pool_weak.upgrade() {
                    let Some(work) = pool.take_next_work(lane) else {
                        break;
                    };
                    pool.execute_work(lane, work);
                }
                done_clone.store(true, Ordering::Release);
                if let Some(pool) = pool_weak.upgrade() {
                    let (wlock, wcv) = &*pool.active_workers;
                    let mut cnt = lock_unpoisoned(wlock);
                    *cnt = cnt.saturating_sub(1);
                    wcv.notify_all();
                }
            });

        match jh {
            Ok(handle) => {
                handles.push((done, handle));
            }
            Err(e) => {
                crate::map_log!(1, "[IO_POOL] Failed to spawn worker thread {}: {}", name, e);
                let (wlock, wcv) = &*pool.active_workers;
                let mut cnt = lock_unpoisoned(wlock);
                *cnt = cnt.saturating_sub(1);
                wcv.notify_all();
            }
        }
    }

    /// Returns `true` when an active non-cancelled track open is either queued or currently executing.
    pub fn has_active_work(&self) -> bool {
        let (lock, _) = &*self.state;
        let guard = lock_unpoisoned(lock);
        guard
            .local_active
            .as_ref()
            .is_some_and(|j| !j.cancel.is_cancelled())
            || guard
                .net_active
                .as_ref()
                .is_some_and(|j| !j.cancel.is_cancelled())
            || guard
                .inflight_local_active
                .iter()
                .any(|(_, _, tok, _)| !tok.is_cancelled())
            || guard
                .inflight_net_active
                .iter()
                .any(|(_, _, tok, _)| !tok.is_cancelled())
            || guard
                .promoted_prewarms
                .values()
                .any(|(j, _)| !j.cancel.is_cancelled())
    }

    /// Cancels all active and standby opens and records `epoch` as a stale-open floor.
    pub fn cancel_all_at_epoch(&self, epoch: u64) {
        self.latest_epoch.fetch_max(epoch, Ordering::AcqRel);
        self.cancel_all();
    }

    /// Cancels all active and standby opens (used on `set_queue`, `clear`, `stop`, `dispose`).
    pub fn cancel_all(&self) {
        self.cancel_matching(false);
    }

    /// Cancels only queued and in-flight automatic advancement opens (used on `seek`),
    /// leaving manual user track selections intact.
    pub fn cancel_auto_advance(&self) {
        self.cancel_matching(true);
    }

    /// Cancels queued and in-flight active opens (and all prewarms when `!auto_only`),
    /// resolving any associated waiters with `Ok(None)`.
    fn cancel_matching(&self, auto_only: bool) {
        let mut tokens_to_cancel: Vec<CancelToken> = Vec::new();
        let mut waiters_to_resolve: Vec<OpenWaiter> = Vec::new();
        {
            let (lock, cv) = &*self.state;
            let mut guard = lock_unpoisoned(lock);
            take_active_matching(
                &mut guard.local_active,
                auto_only,
                &mut tokens_to_cancel,
                &mut waiters_to_resolve,
            );
            take_active_matching(
                &mut guard.net_active,
                auto_only,
                &mut tokens_to_cancel,
                &mut waiters_to_resolve,
            );
            collect_inflight_active(
                &guard.inflight_local_active,
                auto_only,
                &mut tokens_to_cancel,
                &mut waiters_to_resolve,
            );
            collect_inflight_active(
                &guard.inflight_net_active,
                auto_only,
                &mut tokens_to_cancel,
                &mut waiters_to_resolve,
            );
            let promoted_keys: Vec<u64> = guard
                .promoted_prewarms
                .iter()
                .filter(|(_, (job, _))| !auto_only || job.kind.is_auto_advance())
                .map(|(k, _)| *k)
                .collect();
            for key in promoted_keys {
                if let Some((old_job, prewarm_tok)) = guard.promoted_prewarms.remove(&key) {
                    tokens_to_cancel.push(prewarm_tok);
                    tokens_to_cancel.push(old_job.cancel);
                    if let Some(w) = old_job.waiter {
                        waiters_to_resolve.push(w);
                    }
                }
            }
            if !auto_only {
                if let Some(old) = guard.local_prewarm.take() {
                    tokens_to_cancel.push(old.job.cancel);
                }
                if let Some(old) = guard.net_prewarm.take() {
                    tokens_to_cancel.push(old.job.cancel);
                }
                for (_, _, _, tok) in &guard.inflight_local_prewarm {
                    tokens_to_cancel.push(tok.clone());
                }
                for (_, _, _, tok) in &guard.inflight_net_prewarm {
                    tokens_to_cancel.push(tok.clone());
                }
                guard.net_coalesce_until = None;
                guard.net_burst_cap = None;
            }
            cv.notify_all();
        }
        for tok in tokens_to_cancel {
            tok.cancel();
        }
        for w in waiters_to_resolve {
            w.resolve(Ok(None));
        }
    }

    /// Cancels pending and in-flight prewarm jobs (e.g. when queue mutations invalidate next track).
    pub fn cancel_prewarms(&self) {
        let mut tokens: Vec<CancelToken> = Vec::new();
        {
            let (lock, cv) = &*self.state;
            let mut guard = lock_unpoisoned(lock);
            if let Some(p) = guard.local_prewarm.take() {
                tokens.push(p.job.cancel);
            }
            if let Some(p) = guard.net_prewarm.take() {
                tokens.push(p.job.cancel);
            }
            for (uid, _, _, t) in &guard.inflight_local_prewarm {
                if !guard.promoted_prewarms.contains_key(uid) {
                    tokens.push(t.clone());
                }
            }
            for (uid, _, _, t) in &guard.inflight_net_prewarm {
                if !guard.promoted_prewarms.contains_key(uid) {
                    tokens.push(t.clone());
                }
            }
            cv.notify_all();
        }
        for t in tokens {
            t.cancel();
        }
    }

    /// Submits a foreground open `job`, superseding/cancelling any prior active or prewarm job.
    pub fn submit_active(&self, job: ActiveOpenJob) {
        let prev = self.latest_epoch.fetch_max(job.epoch, Ordering::AcqRel);
        if job.epoch < prev {
            crate::map_log!(
                4,
                "[IO_POOL] Coalesced stale active open (epoch={} < prev={}, track_id={})",
                job.epoch,
                prev,
                job.item.id
            );
            job.cancel.cancel();
            if let Some(ref w) = job.waiter {
                w.resolve(Ok(None));
            }
            self.active_opens_coalesced.fetch_add(1, Ordering::Relaxed);
            return;
        }

        let mut tokens_to_cancel: Vec<CancelToken> = Vec::new();
        let mut waiters_to_resolve: Vec<OpenWaiter> = Vec::new();
        let is_local = Self::is_local_item(&job.item);
        let job_epoch = job.epoch;
        let job_track_id = job.item.id;
        let now = Instant::now();

        {
            let (lock, cv) = &*self.state;
            let mut guard = lock_unpoisoned(lock);
            if guard.shutdown {
                job.cancel.cancel();
                if let Some(ref w) = job.waiter {
                    w.resolve(Ok(None));
                }
                return;
            }

            // Supersede both active queues cleanly so local skips never race stale HTTP opens.
            if let Some(old) = guard.local_active.take() {
                tokens_to_cancel.push(old.cancel);
                if let Some(w) = old.waiter {
                    waiters_to_resolve.push(w);
                }
                self.active_opens_coalesced.fetch_add(1, Ordering::Relaxed);
            }
            if let Some(old) = guard.net_active.take() {
                tokens_to_cancel.push(old.cancel);
                if let Some(w) = old.waiter {
                    waiters_to_resolve.push(w);
                }
                self.active_opens_coalesced.fetch_add(1, Ordering::Relaxed);
            }
            // Drop queued/in-flight prewarms so they never race a user track change.
            if let Some(old_p) = guard.local_prewarm.take() {
                tokens_to_cancel.push(old_p.job.cancel);
            }
            if let Some(old_p) = guard.net_prewarm.take() {
                tokens_to_cancel.push(old_p.job.cancel);
            }

            collect_inflight_active(
                &guard.inflight_local_active,
                false,
                &mut tokens_to_cancel,
                &mut waiters_to_resolve,
            );
            collect_inflight_active(
                &guard.inflight_net_active,
                false,
                &mut tokens_to_cancel,
                &mut waiters_to_resolve,
            );

            for (_, (old_job, prewarm_tok)) in guard.promoted_prewarms.drain() {
                tokens_to_cancel.push(prewarm_tok);
                tokens_to_cancel.push(old_job.cancel);
                if let Some(w) = old_job.waiter {
                    waiters_to_resolve.push(w);
                }
                self.active_opens_coalesced.fetch_add(1, Ordering::Relaxed);
            }

            let matching_prewarm = guard
                .inflight_local_prewarm
                .iter()
                .chain(guard.inflight_net_prewarm.iter())
                .find(|(_, id, src, tok)| {
                    *id == job.item.id && src == &job.item.source && !tok.is_cancelled()
                })
                .map(|(uid, _, _, tok)| (*uid, tok.clone()));

            if let Some((matched_uid, matched_tok)) = matching_prewarm {
                for (uid, _, _, tok) in &guard.inflight_local_prewarm {
                    if *uid != matched_uid {
                        tokens_to_cancel.push(tok.clone());
                    }
                }
                for (uid, _, _, tok) in &guard.inflight_net_prewarm {
                    if *uid != matched_uid {
                        tokens_to_cancel.push(tok.clone());
                    }
                }
                guard.net_coalesce_until = None;
                guard.net_burst_cap = None;
                guard.promoted_prewarms.insert(matched_uid, (job, matched_tok));
                crate::map_log!(
                    4,
                    "[IO_POOL] Promoted inflight prewarm uid={} to active open (epoch={}, track_id={})",
                    matched_uid,
                    job_epoch,
                    job_track_id
                );
            } else {
                for (_, _, _, tok) in &guard.inflight_local_prewarm {
                    tokens_to_cancel.push(tok.clone());
                }
                for (_, _, _, tok) in &guard.inflight_net_prewarm {
                    tokens_to_cancel.push(tok.clone());
                }

                if is_local {
                    guard.net_coalesce_until = None;
                    guard.net_burst_cap = None;
                    guard.local_active = Some(job);
                } else {
                    if guard.inflight_net_active.is_empty() {
                        guard.net_coalesce_until = None;
                        guard.net_burst_cap = None;
                    } else {
                        let cap = *guard
                            .net_burst_cap
                            .get_or_insert_with(|| now + Duration::from_millis(Self::COALESCE_BURST_CAP_MS));
                        let target = now + Duration::from_millis(Self::COALESCE_QUIET_MS);
                        guard.net_coalesce_until = Some(target.min(cap));
                    }
                    guard.net_active = Some(job);
                }
                crate::map_log!(
                    4,
                    "[IO_POOL] Queued active open (lane={}, epoch={}, track_id={})",
                    if is_local { "local" } else { "net" },
                    job_epoch,
                    job_track_id
                );
            }

            cv.notify_all();
        }

        for tok in tokens_to_cancel {
            tok.cancel();
        }
        for w in waiters_to_resolve {
            w.resolve(Ok(None));
        }
    }

    /// Submits a background prewarm `job` unless an active track transition is already underway.
    pub fn submit_prewarm(&self, job: PrewarmJob) {
        let mut tokens_to_cancel: Vec<CancelToken> = Vec::new();
        let is_local = Self::is_local_item(&job.item);
        let track_id = job.item.id;
        {
            let (lock, cv) = &*self.state;
            let mut guard = lock_unpoisoned(lock);
            if guard.shutdown {
                return;
            }
            if guard.local_active.is_some()
                || guard.net_active.is_some()
                || !guard.inflight_local_active.is_empty()
                || !guard.inflight_net_active.is_empty()
                || !guard.promoted_prewarms.is_empty()
            {
                return;
            }

            let same_inflight = guard
                .inflight_local_prewarm
                .iter()
                .chain(guard.inflight_net_prewarm.iter())
                .any(|(_, id, src, tok)| {
                    *id == job.item.id && src == &job.item.source && !tok.is_cancelled()
                });
            let same_queued = guard
                .local_prewarm
                .as_ref()
                .into_iter()
                .chain(guard.net_prewarm.as_ref().into_iter())
                .any(|q| {
                    q.job.item.id == job.item.id
                        && q.job.item.source == job.item.source
                        && !q.job.cancel.is_cancelled()
                });
            if same_inflight || same_queued {
                return;
            }

            if let Some(old) = guard.local_prewarm.take() {
                tokens_to_cancel.push(old.job.cancel);
            }
            if let Some(old) = guard.net_prewarm.take() {
                tokens_to_cancel.push(old.job.cancel);
            }
            for (_, _, _, tok) in &guard.inflight_local_prewarm {
                tokens_to_cancel.push(tok.clone());
            }
            for (_, _, _, tok) in &guard.inflight_net_prewarm {
                tokens_to_cancel.push(tok.clone());
            }

            let uid = guard.next_prewarm_uid;
            guard.next_prewarm_uid = uid.wrapping_add(1).max(1);
            let queued = QueuedPrewarm { uid, job };
            if is_local {
                guard.local_prewarm = Some(queued);
            } else {
                guard.net_prewarm = Some(queued);
            }
            crate::map_log!(
                4,
                "[IO_POOL] Queued prewarm uid={} (lane={}, track_id={})",
                uid,
                if is_local { "local" } else { "net" },
                track_id
            );
            cv.notify_all();
        }
        for tok in tokens_to_cancel {
            tok.cancel();
        }
    }

    /// Blocks until the next eligible work unit for `lane` is ready or the pool shuts down.
    fn take_next_work(&self, lane: WorkerLane) -> Option<NextPoolWork> {
        let (lock, cv) = &*self.state;
        let mut guard = lock_unpoisoned(lock);

        loop {
            if guard.shutdown {
                return None;
            }

            match lane {
                WorkerLane::Local => {
                    if let Some(job) = guard.local_active.take() {
                        if !job.cancel.is_cancelled() {
                            guard.inflight_local_active.push((
                                job.epoch,
                                job.kind.is_auto_advance(),
                                job.cancel.clone(),
                                job.waiter.clone(),
                            ));
                            return Some(NextPoolWork::Active(job));
                        }
                        if let Some(w) = job.waiter {
                            drop(guard);
                            w.resolve(Ok(None));
                            guard = lock_unpoisoned(lock);
                            continue;
                        }
                    }
                    if let Some(queued) = guard.local_prewarm.take() {
                        if !queued.job.cancel.is_cancelled()
                            && guard.local_active.is_none()
                            && guard.net_active.is_none()
                            && guard.inflight_local_active.is_empty()
                            && guard.inflight_net_active.is_empty()
                            && guard.promoted_prewarms.is_empty()
                        {
                            guard.inflight_local_prewarm.push((
                                queued.uid,
                                queued.job.item.id,
                                queued.job.item.source.clone(),
                                queued.job.cancel.clone(),
                            ));
                            return Some(NextPoolWork::Prewarm {
                                uid: queued.uid,
                                job: queued.job,
                            });
                        }
                    }
                    guard = cv.wait(guard).unwrap_or_else(|e| e.into_inner());
                }
                WorkerLane::Network => {
                    if let Some(ref job) = guard.net_active {
                        if job.cancel.is_cancelled() {
                            if let Some(cancelled) = guard.net_active.take() {
                                if let Some(w) = cancelled.waiter {
                                    drop(guard);
                                    w.resolve(Ok(None));
                                    guard = lock_unpoisoned(lock);
                                    continue;
                                }
                            }
                            continue;
                        }
                        if let Some(deadline) = guard.net_coalesce_until {
                            let now = Instant::now();
                            if now < deadline {
                                let (g, _) = cv
                                    .wait_timeout(guard, deadline - now)
                                    .unwrap_or_else(|e| e.into_inner());
                                guard = g;
                                continue;
                            }
                        }
                        guard.net_coalesce_until = None;
                        guard.net_burst_cap = None;
                        if let Some(job) = guard.net_active.take() {
                            guard.inflight_net_active.push((
                                job.epoch,
                                job.kind.is_auto_advance(),
                                job.cancel.clone(),
                                job.waiter.clone(),
                            ));
                            return Some(NextPoolWork::Active(job));
                        }
                        continue;
                    }

                    // Leave at least one network worker free whenever active network opens run.
                    let busy_net = guard.inflight_net_active.len() + guard.inflight_net_prewarm.len();
                    if let Some(ref queued) = guard.net_prewarm {
                        if !queued.job.cancel.is_cancelled()
                            && guard.local_active.is_none()
                            && guard.inflight_local_active.is_empty()
                            && guard.inflight_net_active.is_empty()
                            && guard.promoted_prewarms.is_empty()
                            && busy_net + 1 < Self::NET_WORKERS
                        {
                            if let Some(queued) = guard.net_prewarm.take() {
                                guard.inflight_net_prewarm.push((
                                    queued.uid,
                                    queued.job.item.id,
                                    queued.job.item.source.clone(),
                                    queued.job.cancel.clone(),
                                ));
                                return Some(NextPoolWork::Prewarm {
                                    uid: queued.uid,
                                    job: queued.job,
                                });
                            }
                        } else if queued.job.cancel.is_cancelled() {
                            guard.net_prewarm = None;
                            continue;
                        }
                    }

                    guard = cv.wait(guard).unwrap_or_else(|e| e.into_inner());
                }
            }
        }
    }

    /// Removes the completed active job matching `epoch` from `lane`'s in-flight tracking list.
    fn finish_inflight_active(&self, lane: WorkerLane, epoch: u64) {
        let (lock, cv) = &*self.state;
        let mut guard = lock_unpoisoned(lock);
        let list = match lane {
            WorkerLane::Local => &mut guard.inflight_local_active,
            WorkerLane::Network => &mut guard.inflight_net_active,
        };
        if let Some(pos) = list.iter().position(|(ep, _, _, _)| *ep == epoch) {
            list.swap_remove(pos);
        }
        cv.notify_all();
    }

    /// Removes the completed prewarm job matching `uid` from `lane` and returns any promoted
    /// foreground [`ActiveOpenJob`] that was attached while it was in flight.
    fn finish_inflight_prewarm_and_take_promoted(
        &self,
        lane: WorkerLane,
        uid: u64,
    ) -> Option<ActiveOpenJob> {
        let (lock, cv) = &*self.state;
        let mut guard = lock_unpoisoned(lock);
        let list = match lane {
            WorkerLane::Local => &mut guard.inflight_local_prewarm,
            WorkerLane::Network => &mut guard.inflight_net_prewarm,
        };
        if let Some(pos) = list.iter().position(|(u, _, _, _)| *u == uid) {
            list.swap_remove(pos);
        }
        let promoted = guard.promoted_prewarms.remove(&uid).map(|(job, _)| job);
        cv.notify_all();
        promoted
    }

    /// Executes a dequeued `work` unit on `lane`, handling cancellation, prewarm promotion,
    /// initial PCM pre-buffering, and completion callback dispatch.
    fn execute_work(&self, lane: WorkerLane, work: NextPoolWork) {
        match work {
            NextPoolWork::Active(job) => {
                self.active_opens_executed.fetch_add(1, Ordering::Relaxed);
                let epoch = job.epoch;
                let outcome = Self::run_open(
                    &job.item,
                    job.custom_factory.as_ref(),
                    job.dart_resolver.as_ref(),
                    &job.template,
                    &job.cancel,
                    &self.shutdown_token,
                    true,
                );
                self.finish_inflight_active(lane, epoch);

                match outcome {
                    IoOpenOutcome::Opened(deck) if job.cancel.is_cancelled() || self.shutdown_token.is_cancelled() => {
                        self.reaper.reap_value(deck);
                        if let Some(ref w) = job.waiter {
                            w.resolve(Ok(None));
                        }
                    }
                    other => {
                        (self.on_complete)(IoCompletion::Active {
                            job,
                            outcome: other,
                        });
                    }
                }
            }
            NextPoolWork::Prewarm { uid, job } => {
                let outcome = Self::run_open(
                    &job.item,
                    job.custom_factory.as_ref(),
                    job.dart_resolver.as_ref(),
                    &job.template,
                    &job.cancel,
                    &self.shutdown_token,
                    false,
                );
                if let Some(active_job) =
                    self.finish_inflight_prewarm_and_take_promoted(lane, uid)
                {
                    self.active_opens_executed.fetch_add(1, Ordering::Relaxed);
                    match outcome {
                        IoOpenOutcome::Opened(deck)
                            if active_job.cancel.is_cancelled()
                                || self.shutdown_token.is_cancelled() =>
                        {
                            self.reaper.reap_value(deck);
                            if let Some(ref w) = active_job.waiter {
                                w.resolve(Ok(None));
                            }
                        }
                        IoOpenOutcome::Opened(deck) => {
                            deck.wait_for_initial_pcm(
                                4096,
                                Duration::from_millis(180),
                                Some(&active_job.cancel),
                            );
                            if active_job.cancel.is_cancelled()
                                || self.shutdown_token.is_cancelled()
                            {
                                self.reaper.reap_value(deck);
                                if let Some(ref w) = active_job.waiter {
                                    w.resolve(Ok(None));
                                }
                            } else {
                                (self.on_complete)(IoCompletion::Active {
                                    job: active_job,
                                    outcome: IoOpenOutcome::Opened(deck),
                                });
                            }
                        }
                        other => {
                            (self.on_complete)(IoCompletion::Active {
                                job: active_job,
                                outcome: other,
                            });
                        }
                    }
                    return;
                }

                match outcome {
                    IoOpenOutcome::Opened(deck) if job.cancel.is_cancelled() || self.shutdown_token.is_cancelled() => {
                        self.reaper.reap_value(deck);
                    }
                    other => {
                        (self.on_complete)(IoCompletion::Prewarm {
                            job,
                            outcome: other,
                        });
                    }
                }
            }
        }
    }

    /// Opens `item` onto a fresh [`StreamingDeck`] configured from `template`, using optional
    /// `custom_factory` and `dart_resolver`, cooperatively observing `cancel` and `shutdown_token`,
    /// and optionally waiting for an initial PCM cushion when `prebuffer_pcm` is `true`.
    fn run_open(
        item: &AudioSourceCore,
        custom_factory: Option<&CustomSourceFactory>,
        dart_resolver: Option<&Arc<DartResolveRegistry>>,
        template: &DeckDspTemplate,
        cancel: &CancelToken,
        shutdown_token: &CancelToken,
        prebuffer_pcm: bool,
    ) -> IoOpenOutcome {
        if cancel.is_cancelled() || shutdown_token.is_cancelled() {
            return IoOpenOutcome::Aborted;
        }
        let _shutdown_guard = shutdown_token.link_child(cancel);

        let Ok(mut deck) = StreamingDeck::new_deck(
            template.sample_rate,
            template.channels,
            template.period_size,
        ) else {
            crate::map_log!(
                1,
                "[IO_POOL] Failed to allocate StreamingDeck for track id={}",
                item.id
            );
            return IoOpenOutcome::Failed(-1, None);
        };
        deck.apply_dsp_template_silent(template, Some(item));

        let res = DualSource::open_deck_with_pre_resolved(
            &mut deck,
            item,
            None,
            custom_factory,
            dart_resolver,
            Some(cancel),
        );
        if res == MAP_ERROR_ABORTED || cancel.is_cancelled() || shutdown_token.is_cancelled() {
            crate::map_log!(4, "[IO_POOL] Open aborted for track id={}", item.id);
            drop(deck);
            return IoOpenOutcome::Aborted;
        }
        if res != MAP_SUCCESS {
            let err_msg = deck.take_last_open_error_message();
            crate::map_log!(
                1,
                "[IO_POOL] Open failed for track id={} (code={}, err={:?})",
                item.id,
                res,
                err_msg
            );
            drop(deck);
            return IoOpenOutcome::Failed(res, err_msg);
        }
        if prebuffer_pcm {
            // Ensure an initial PCM cushion (~93 ms at 44.1 kHz) is decoded before playback starts.
            deck.wait_for_initial_pcm(4096, Duration::from_millis(180), Some(cancel));
            if cancel.is_cancelled() || shutdown_token.is_cancelled() {
                crate::map_log!(
                    4,
                    "[IO_POOL] Open aborted during prebuffer for track id={}",
                    item.id
                );
                drop(deck);
                return IoOpenOutcome::Aborted;
            }
        }
        crate::map_log!(
            4,
            "[IO_POOL] Open succeeded for track id={} (prebuffer_pcm={})",
            item.id,
            prebuffer_pcm
        );
        IoOpenOutcome::Opened(deck)
    }

    /// Signals cancellation to all workers and joins finished workers within a bounded 300ms window.
    pub fn shutdown(&self) {
        crate::map_log!(3, "[IO_POOL] Shutting down IoWorkerPool");
        self.shutdown_token.cancel();
        {
            let (lock, cv) = &*self.state;
            let mut guard = lock_unpoisoned(lock);
            guard.shutdown = true;
            cv.notify_all();
        }
        self.cancel_all();

        if crate::sync::can_block_current_thread() {
            let deadline = Instant::now() + Duration::from_millis(280);
            let (wlock, wcv) = &*self.active_workers;
            let mut guard = lock_unpoisoned(wlock);
            while *guard > 0 {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                let (g, _) = wcv
                    .wait_timeout(guard, deadline - now)
                    .unwrap_or_else(|e| e.into_inner());
                guard = g;
            }
        }

        let mut handles = lock_unpoisoned(&self.workers_done_flags);
        let mut remaining = Vec::new();
        for (done, jh) in handles.drain(..) {
            if done.load(Ordering::Acquire) {
                let _ = jh.join();
            } else {
                remaining.push((done, jh));
            }
        }
        if !remaining.is_empty() {
            crate::map_log!(
                2,
                "[IO_POOL] {} worker(s) still active after shutdown timeout",
                remaining.len()
            );
        }
        *handles = remaining;
    }
}
