//! Bounded interruptible I/O worker pool with local fast-lane isolation and epoch coalescing.

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
    inner: Arc<(Mutex<Option<T>>, Condvar)>,
}

impl<T: Clone> Default for AsyncWaiter<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Clone> AsyncWaiter<T> {
    pub fn new() -> Self {
        Self {
            inner: Arc::new((Mutex::new(None), Condvar::new())),
        }
    }

    /// Resolves the waiter once if not already completed and wakes all waiting callers.
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
    Manual {
        manual_crossfade_ms: Option<u64>,
        force_play: bool,
    },
    AutoAdvance {
        should_auto_xfade: bool,
        auto_ms: u64,
        expected_deck_id: usize,
        expected_open_gen: u64,
        expected_seek_epoch: u64,
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
    pub epoch: u64,
    pub item: AudioSourceCore,
    pub custom_factory: Option<CustomSourceFactory>,
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    pub template: DeckDspTemplate,
    pub seek_ms: Option<i64>,
    pub kind: ActiveOpenKind,
    pub queue_changed: bool,
    pub include_meta: bool,
    pub include_replay_gain: bool,
    pub cancel: CancelToken,
    pub waiter: Option<OpenWaiter>,
}

/// Asynchronous job opening the upcoming track on a background standby deck.
#[derive(Clone)]
pub struct PrewarmJob {
    pub epoch: u64,
    pub item: AudioSourceCore,
    pub custom_factory: Option<CustomSourceFactory>,
    pub dart_resolver: Option<Arc<DartResolveRegistry>>,
    pub template: DeckDspTemplate,
    pub cancel: CancelToken,
}

/// Open result produced by an [`IoWorkerPool`] worker thread.
pub enum IoOpenOutcome {
    Opened(Box<StreamingDeck>),
    Aborted,
    Failed(i32, Option<String>),
}

/// Completed job delivered to [`ControlCoordinator`] handlers.
pub enum IoCompletion {
    Active {
        job: ActiveOpenJob,
        outcome: IoOpenOutcome,
    },
    Prewarm {
        job: PrewarmJob,
        outcome: IoOpenOutcome,
    },
}

pub type CompletionCallback = Arc<dyn Fn(IoCompletion) + Send + Sync>;

type InflightActiveEntry = (u64, bool, CancelToken, Option<OpenWaiter>);

struct PoolMailbox {
    shutdown: bool,
    local_active: Option<ActiveOpenJob>,
    net_active: Option<ActiveOpenJob>,
    local_prewarm: Option<PrewarmJob>,
    net_prewarm: Option<PrewarmJob>,
    inflight_local_active: Vec<InflightActiveEntry>,
    inflight_net_active: Vec<InflightActiveEntry>,
    inflight_local_prewarm: Vec<(u64, CancelToken)>,
    inflight_net_prewarm: Vec<(u64, CancelToken)>,
    net_coalesce_until: Option<Instant>,
    net_burst_cap: Option<Instant>,
}

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

enum NextPoolWork {
    Active(ActiveOpenJob),
    Prewarm(PrewarmJob),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum WorkerLane {
    Local,
    Network,
}

/// Bounded interruptible thread pool separating fast local opens from slow network opens.
///
/// Runs `1` dedicated `map-io-local` worker for file/memory/`custom://` tracks (0 ms wait)
/// and `4` `map-io-net-*` workers for `http://`, `https://`, and `icy://` tracks with
/// rapid-skip epoch coalescing.
pub struct IoWorkerPool {
    state: Arc<(Mutex<PoolMailbox>, Condvar)>,
    shutdown_token: CancelToken,
    reaper: ReaperHandle,
    active_workers: Arc<(Mutex<usize>, Condvar)>,
    workers_done_flags: Mutex<Vec<(Arc<AtomicBool>, JoinHandle<()>)>>,
    on_complete: CompletionCallback,
    latest_epoch: Arc<AtomicU64>,
    pub active_opens_executed: Arc<AtomicU64>,
    pub active_opens_coalesced: Arc<AtomicU64>,
}

impl IoWorkerPool {
    const NET_WORKERS: usize = 4;
    const COALESCE_QUIET_MS: u64 = 18;
    const COALESCE_BURST_CAP_MS: u64 = 140;

    /// Returns `true` for tracks handled on the low-latency `map-io-local` lane.
    #[inline]
    pub fn is_local_item(item: &AudioSourceCore) -> bool {
        if item.data_bytes.is_some() {
            return true;
        }
        let s = item.source.trim();
        !(s.starts_with("http://") || s.starts_with("https://") || s.starts_with("icy://"))
    }

    pub fn spawn(reaper: ReaperHandle, on_complete: CompletionCallback) -> Arc<Self> {
        let state = Arc::new((
            Mutex::new(PoolMailbox {
                shutdown: false,
                local_active: None,
                net_active: None,
                local_prewarm: None,
                net_prewarm: None,
                inflight_local_active: Vec::new(),
                inflight_net_active: Vec::new(),
                inflight_local_prewarm: Vec::new(),
                inflight_net_prewarm: Vec::new(),
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

        if let Ok(handle) = jh {
            handles.push((done, handle));
        } else {
            let (wlock, wcv) = &*pool.active_workers;
            let mut cnt = lock_unpoisoned(wlock);
            *cnt = cnt.saturating_sub(1);
            wcv.notify_all();
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
            if !auto_only {
                if let Some(old) = guard.local_prewarm.take() {
                    tokens_to_cancel.push(old.cancel);
                }
                if let Some(old) = guard.net_prewarm.take() {
                    tokens_to_cancel.push(old.cancel);
                }
                for (_, tok) in &guard.inflight_local_prewarm {
                    tokens_to_cancel.push(tok.clone());
                }
                for (_, tok) in &guard.inflight_net_prewarm {
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
                tokens.push(p.cancel);
            }
            if let Some(p) = guard.net_prewarm.take() {
                tokens.push(p.cancel);
            }
            for (_, t) in &guard.inflight_local_prewarm {
                tokens.push(t.clone());
            }
            for (_, t) in &guard.inflight_net_prewarm {
                tokens.push(t.clone());
            }
            cv.notify_all();
        }
        for t in tokens {
            t.cancel();
        }
    }

    /// Submits a foreground open job, superseding/cancelling any prior active or prewarm job.
    pub fn submit_active(&self, job: ActiveOpenJob) {
        let prev = self.latest_epoch.fetch_max(job.epoch, Ordering::AcqRel);
        if job.epoch < prev {
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
                tokens_to_cancel.push(old_p.cancel);
            }
            if let Some(old_p) = guard.net_prewarm.take() {
                tokens_to_cancel.push(old_p.cancel);
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
            for (_, tok) in &guard.inflight_local_prewarm {
                tokens_to_cancel.push(tok.clone());
            }
            for (_, tok) in &guard.inflight_net_prewarm {
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

            cv.notify_all();
        }

        for tok in tokens_to_cancel {
            tok.cancel();
        }
        for w in waiters_to_resolve {
            w.resolve(Ok(None));
        }
    }

    /// Submits a background prewarm job unless an active track transition is already underway.
    pub fn submit_prewarm(&self, job: PrewarmJob) {
        let mut tokens_to_cancel: Vec<CancelToken> = Vec::new();
        let is_local = Self::is_local_item(&job.item);
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
            {
                return;
            }

            if let Some(old) = guard.local_prewarm.take() {
                tokens_to_cancel.push(old.cancel);
            }
            if let Some(old) = guard.net_prewarm.take() {
                tokens_to_cancel.push(old.cancel);
            }
            for (_, tok) in &guard.inflight_local_prewarm {
                tokens_to_cancel.push(tok.clone());
            }
            for (_, tok) in &guard.inflight_net_prewarm {
                tokens_to_cancel.push(tok.clone());
            }

            if is_local {
                guard.local_prewarm = Some(job);
            } else {
                guard.net_prewarm = Some(job);
            }
            cv.notify_all();
        }
        for tok in tokens_to_cancel {
            tok.cancel();
        }
    }

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
                    if let Some(job) = guard.local_prewarm.take() {
                        if !job.cancel.is_cancelled()
                            && guard.local_active.is_none()
                            && guard.net_active.is_none()
                            && guard.inflight_local_active.is_empty()
                            && guard.inflight_net_active.is_empty()
                        {
                            guard
                                .inflight_local_prewarm
                                .push((job.epoch, job.cancel.clone()));
                            return Some(NextPoolWork::Prewarm(job));
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
                    if let Some(ref job) = guard.net_prewarm {
                        if !job.cancel.is_cancelled()
                            && guard.local_active.is_none()
                            && guard.inflight_local_active.is_empty()
                            && guard.inflight_net_active.is_empty()
                            && busy_net + 1 < Self::NET_WORKERS
                        {
                            if let Some(job) = guard.net_prewarm.take() {
                                guard
                                    .inflight_net_prewarm
                                    .push((job.epoch, job.cancel.clone()));
                                return Some(NextPoolWork::Prewarm(job));
                            }
                        } else if job.cancel.is_cancelled() {
                            guard.net_prewarm = None;
                            continue;
                        }
                    }

                    guard = cv.wait(guard).unwrap_or_else(|e| e.into_inner());
                }
            }
        }
    }

    fn finish_inflight(&self, lane: WorkerLane, is_active: bool, epoch: u64) {
        let (lock, cv) = &*self.state;
        let mut guard = lock_unpoisoned(lock);
        if is_active {
            let list = match lane {
                WorkerLane::Local => &mut guard.inflight_local_active,
                WorkerLane::Network => &mut guard.inflight_net_active,
            };
            if let Some(pos) = list.iter().position(|(ep, _, _, _)| *ep == epoch) {
                list.swap_remove(pos);
            }
        } else {
            let list = match lane {
                WorkerLane::Local => &mut guard.inflight_local_prewarm,
                WorkerLane::Network => &mut guard.inflight_net_prewarm,
            };
            if let Some(pos) = list.iter().position(|(ep, _)| *ep == epoch) {
                list.swap_remove(pos);
            }
        }
        cv.notify_all();
    }

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
                self.finish_inflight(lane, true, epoch);

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
            NextPoolWork::Prewarm(job) => {
                let epoch = job.epoch;
                let outcome = Self::run_open(
                    &job.item,
                    job.custom_factory.as_ref(),
                    job.dart_resolver.as_ref(),
                    &job.template,
                    &job.cancel,
                    &self.shutdown_token,
                    false,
                );
                self.finish_inflight(lane, false, epoch);

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
            drop(deck);
            return IoOpenOutcome::Aborted;
        }
        if res != MAP_SUCCESS {
            let err_msg = deck.take_last_open_error_message();
            drop(deck);
            return IoOpenOutcome::Failed(res, err_msg);
        }
        if prebuffer_pcm {
            // Ensure an initial PCM cushion (~93 ms at 44.1 kHz) is decoded before playback starts.
            deck.wait_for_initial_pcm(4096, Duration::from_millis(180), Some(cancel));
            if cancel.is_cancelled() || shutdown_token.is_cancelled() {
                drop(deck);
                return IoOpenOutcome::Aborted;
            }
        }
        IoOpenOutcome::Opened(deck)
    }

    /// Signals cancellation to all workers and joins finished workers within a bounded 300ms window.
    pub fn shutdown(&self) {
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
        *handles = remaining;
    }
}
