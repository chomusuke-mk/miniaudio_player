//! Lock-Free Multi-Bus Audio Tap Subsystem (`OutputManager` → Push Broadcast & Zero-Alloc Pull).
//!
//! Provides a 5-bus real-time tap matrix matching `AudioOutputSource`:
//! - `0`: All
//! - `1`: MusicMix
//! - `2`: ActiveTrack
//! - `3`: StandbyTrack
//! - `4`: VoiceOnly
//!
//! Invariants:
//! - Real-time `OutputManager::dispatch` checks a single `active_bus_mask: AtomicU8` (`~0.27 ns` idle)
//!   and performs at most ONE lock-free SPSC copy per active bus regardless of subscriber count.
//! - Zero heap allocations, zero mutex locks, and zero blocking syscalls occur on the RT thread.
//! - A single Pull tap on a bus reads directly from that bus's `rtrb::Consumer` into the caller's
//!   reusable destination buffer (1 copy, 0 intermediate threads).
//! - Any Push subscriber or >= 2 Pull taps on the same bus activates fan-out on an off-RT
//!   dispatcher thread without adding any extra work to the RT audio loop.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};

use std::time::Duration;

use crate::sync::thread::{self, JoinHandle};
use crate::sync::{can_block_current_thread, lock_unpoisoned, wait_timeout_unpoisoned};

/// Number of addressable output buses (`All`, `MusicMix`, `ActiveTrack`, `StandbyTrack`, `VoiceOnly`).
pub const TAP_BUS_COUNT: usize = 5;

/// SPSC ring capacity in interleaved `f32` samples per active bus (~341 ms @ 48 kHz stereo).
pub const TAP_RING_CAPACITY_SAMPLES: usize = 32768;

/// Secondary SPSC ring capacity for individual Pull readers during fan-out mode.
pub const TAP_PULL_FANOUT_CAPACITY_SAMPLES: usize = 32768;

/// Minimum and maximum allowed chunk frame duration (ms) for Push batching.
pub const MIN_TAP_FRAME_DURATION_MS: u32 = 5;
pub const MAX_TAP_FRAME_DURATION_MS: u32 = 200;
pub const DEFAULT_TAP_FRAME_DURATION_MS: u32 = 20;

/// Sample encoding format emitted by an audio bus tap.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TapSampleFormat {
    /// 32-bit IEEE 754 little-endian float PCM (`4` bytes/sample).
    Float32 = 0,
    /// 16-bit signed integer little-endian linear PCM (`2` bytes/sample).
    Pcm16 = 1,
}

impl TapSampleFormat {
    /// Converts raw integer wire code (`0`: Float32, `1`: Pcm16) into [`TapSampleFormat`].
    #[inline]
    pub fn from_i32(value: i32) -> Result<Self, String> {
        match value {
            0 => Ok(Self::Float32),
            1 => Ok(Self::Pcm16),
            _ => Err(format!(
                "Invalid AudioTapFormat code {}: expected 0 (float32) or 1 (pcm16)",
                value
            )),
        }
    }

    /// Returns byte size per single channel sample (`4` for Float32, `2` for Pcm16).
    #[inline]
    pub const fn bytes_per_sample(self) -> usize {
        match self {
            Self::Float32 => 4,
            Self::Pcm16 => 2,
        }
    }
}

/// Owned PCM batch emitted by a Push tap toward Dart/consumers.
#[derive(Debug, Clone)]
pub struct TapChunk {
    pub source: i32,
    pub format: TapSampleFormat,
    pub sample_rate: u32,
    pub channels: usize,
    pub frame_count: u32,
    pub dropped_frames: u64,
    pub bytes: Vec<u8>,
}

/// Sink abstraction allowing `core::tap` to be unit-tested in pure Rust without FRB runtime.
pub trait TapChunkSink: Send + Sync {
    /// Delivers `chunk`; returns `false` if the downstream receiver is closed/canceled.
    fn send_chunk(&self, chunk: TapChunk) -> bool;
}

/// Encodes interleaved `f32` samples directly into `dst` according to `format`, returning bytes written.
///
/// Both `Float32` and `Pcm16` emit little-endian wire layout matching Dart typed views.
#[inline]
pub fn encode_f32_into_bytes(src: &[f32], format: TapSampleFormat, dst: &mut [u8]) -> usize {
    let sample_bytes = format.bytes_per_sample();
    let max_samples = dst.len() / sample_bytes;
    let count = src.len().min(max_samples);
    if count == 0 {
        return 0;
    }

    match format {
        TapSampleFormat::Float32 => {
            #[cfg(target_endian = "little")]
            unsafe {
                std::ptr::copy_nonoverlapping(
                    src.as_ptr() as *const u8,
                    dst.as_mut_ptr(),
                    count * 4,
                );
            }
            #[cfg(not(target_endian = "little"))]
            for (i, &s) in src[..count].iter().enumerate() {
                dst[i * 4..(i + 1) * 4].copy_from_slice(&s.to_le_bytes());
            }
            count * 4
        }
        TapSampleFormat::Pcm16 => {
            for (i, &s) in src[..count].iter().enumerate() {
                let pcm = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
                dst[i * 2..(i + 1) * 2].copy_from_slice(&pcm.to_le_bytes());
            }
            count * 2
        }
    }
}

/// Reads up to `max_samples` (already frame-aligned) from an `rtrb::Consumer<f32>`, encoding
/// straight from its ring slices into `dst_bytes`. Returns `(samples_read, bytes_written)`.
#[inline]
fn pop_consumer_encoded(
    cons: &mut rtrb::Consumer<f32>,
    max_samples: usize,
    channels: usize,
    format: TapSampleFormat,
    dst_bytes: &mut [u8],
) -> (usize, usize) {
    let ch = channels.max(1);
    let avail = cons.slots();
    let wanted = ((avail.min(max_samples)) / ch) * ch;
    if wanted == 0 {
        return (0, 0);
    }

    let Ok(chunk) = cons.read_chunk(wanted) else {
        return (0, 0);
    };
    let (s1, s2) = chunk.as_slices();
    let b1 = encode_f32_into_bytes(s1, format, dst_bytes);
    let b2 = if !s2.is_empty() && b1 < dst_bytes.len() {
        encode_f32_into_bytes(s2, format, &mut dst_bytes[b1..])
    } else {
        0
    };
    chunk.commit_all();
    (wanted, b1 + b2)
}

/// Drains all currently available aligned frames from `cons` into `out` without reallocating.
#[inline]
fn drain_consumer_to_vec(cons: &mut rtrb::Consumer<f32>, channels: usize, out: &mut Vec<f32>) {
    out.clear();
    let ch = channels.max(1);
    let avail = (cons.slots() / ch) * ch;
    if avail == 0 {
        return;
    }
    if let Ok(chunk) = cons.read_chunk(avail) {
        let (s1, s2) = chunk.as_slices();
        out.reserve(avail);
        out.extend_from_slice(s1);
        out.extend_from_slice(s2);
        chunk.commit_all();
    }
}

/// Discards any unread samples currently sitting in `cons` cleanly.
#[inline]
fn discard_consumer(cons: &mut rtrb::Consumer<f32>) {
    let slots = cons.slots();
    if slots > 0 {
        if let Ok(chunk) = cons.read_chunk(slots) {
            chunk.commit_all();
        }
    }
}

/// Pushes interleaved `src` samples into an `rtrb::Producer<f32>`, tracking dropped frames on overflow.
#[inline]
fn push_producer_aligned(
    prod: &mut rtrb::Producer<f32>,
    src: &[f32],
    channels: usize,
    dropped_frames: &AtomicU64,
) {
    let ch = channels.max(1);
    let aligned_total = (src.len() / ch) * ch;
    if aligned_total == 0 {
        return;
    }
    let free = prod.slots();
    let to_write = ((free.min(aligned_total)) / ch) * ch;
    if to_write > 0 {
        if let Ok(mut chunk) = prod.write_chunk(to_write) {
            let (s1, s2) = chunk.as_mut_slices();
            let n1 = s1.len();
            s1.copy_from_slice(&src[..n1]);
            if !s2.is_empty() {
                s2.copy_from_slice(&src[n1..to_write]);
            }
            chunk.commit_all();
        }
    }
    if to_write < aligned_total {
        let missing_frames = ((aligned_total - to_write) / ch) as u64;
        dropped_frames.fetch_add(missing_frames, Ordering::Relaxed);
    }
}

/// Real-time side slot for a single audio output bus.
pub struct TapRtBusSlot {
    producer: rtrb::Producer<f32>,
    dropped_frames: Arc<AtomicU64>,
}

/// Lock-free multi-bus tap matrix owned exclusively by `OutputManager` on the RT audio thread.
pub struct TapRtMatrix {
    active_bus_mask: Arc<AtomicU8>,
    slots: [TapRtBusSlot; TAP_BUS_COUNT],
    channels: usize,
}

impl TapRtMatrix {
    /// Copies active output bus slices into their respective RT SPSC rings (`~0.27 ns` when idle).
    ///
    /// Expects `slices` ordered as `[All, MusicMix, ActiveTrack, StandbyTrack, VoiceOnly]`.
    #[inline]
    pub fn write_buses(&mut self, slices: [&[f32]; TAP_BUS_COUNT], sample_count: usize) {
        let mask = self.active_bus_mask.load(Ordering::Acquire);
        if mask == 0 || sample_count == 0 {
            return;
        }
        for (bus_idx, slot) in self.slots.iter_mut().enumerate() {
            if (mask & (1u8 << bus_idx)) != 0 {
                let valid = slices[bus_idx].len().min(sample_count);
                if valid > 0 {
                    push_producer_aligned(
                        &mut slot.producer,
                        &slices[bus_idx][..valid],
                        self.channels,
                        &slot.dropped_frames,
                    );
                }
            }
        }
    }
}

struct PushSubscriber {
    client_key: u64,
    format: TapSampleFormat,
    target_samples: usize,
    accum_f32: Vec<f32>,
    dropped_baseline: u64,
    sink: Arc<dyn TapChunkSink>,
    closed: bool,
}

#[derive(Default)]
struct BusSubscribers {
    push_subs: Vec<PushSubscriber>,
    pull_subs: Vec<Arc<PullTapHandle>>,
}

struct TapControlState {
    active_bus_mask: Arc<AtomicU8>,
    has_fanout_work: AtomicBool,
    wake_lock: Mutex<bool>,
    wake_cvar: Condvar,
    shutdown: AtomicBool,
}

impl TapControlState {
    #[inline]
    fn notify_wake(&self) {
        let mut wake = lock_unpoisoned(&self.wake_lock);
        *wake = true;
        drop(wake);
        self.wake_cvar.notify_all();
    }

    #[inline]
    fn try_notify_wake(&self) {
        if let Ok(mut wake) = self.wake_lock.try_lock() {
            *wake = true;
        }
        self.wake_cvar.notify_all();
    }
}

struct BusHub {
    bus_idx: usize,
    rt_consumer: Mutex<rtrb::Consumer<f32>>,
    rt_dropped_frames: Arc<AtomicU64>,
    fanout_active: AtomicBool,
    control: Arc<TapControlState>,
    state: Mutex<BusSubscribers>,
}

/// Handle for zero-allocation Pull reading on an audio output bus.
pub struct PullTapHandle {
    pub tap_id: u32,
    pub bus_idx: usize,
    pub format: TapSampleFormat,
    pub sample_rate: u32,
    pub channels: usize,
    hub: Arc<BusHub>,
    fanout_producer: Mutex<Option<rtrb::Producer<f32>>>,
    fanout_consumer: Mutex<Option<rtrb::Consumer<f32>>>,
    rt_dropped_baseline: AtomicU64,
    fanout_dropped_frames: AtomicU64,
    last_reported_dropped: AtomicU64,
    closed: AtomicBool,
    web_scratch_u8: Mutex<Vec<u8>>,
}

impl PullTapHandle {
    fn ensure_fanout_ring(&self) {
        let mut prod_guard = lock_unpoisoned(&self.fanout_producer);
        if prod_guard.is_some() {
            return;
        }
        let mut cons_guard = lock_unpoisoned(&self.fanout_consumer);
        if cons_guard.is_some() {
            return;
        }
        let (prod, cons) = rtrb::RingBuffer::new(TAP_PULL_FANOUT_CAPACITY_SAMPLES);
        *prod_guard = Some(prod);
        *cons_guard = Some(cons);
    }

    fn push_fanout_samples(&self, src: &[f32]) {
        if self.closed.load(Ordering::Acquire) {
            return;
        }
        self.ensure_fanout_ring();
        let mut guard = lock_unpoisoned(&self.fanout_producer);
        if let Some(ref mut prod) = *guard {
            push_producer_aligned(prod, src, self.channels, &self.fanout_dropped_frames);
        }
    }

    /// Computes total dropped frames observed by this Pull handle since it opened.
    #[inline]
    pub fn total_dropped_frames(&self) -> u64 {
        let rt_now = self.hub.rt_dropped_frames.load(Ordering::Relaxed);
        let base = self.rt_dropped_baseline.load(Ordering::Relaxed);
        let rt_delta = rt_now.saturating_sub(base);
        let fan_delta = self.fanout_dropped_frames.load(Ordering::Relaxed);
        let total = rt_delta.saturating_add(fan_delta);
        self.last_reported_dropped.store(total, Ordering::Relaxed);
        total
    }

    /// Returns whether this handle has been closed or its owning player disposed.
    #[inline]
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Marks this Pull handle closed.
    #[inline]
    pub fn mark_closed(&self) {
        self.closed.store(true, Ordering::Release);
    }

    /// Reads up to `max_frames` into caller-owned `dst_bytes` without heap allocations.
    ///
    /// Uses `try_lock()` on consumers so calling synchronously from the Web main UI thread never
    /// hits `Atomics.wait`. Returns `(frames_read, dropped_frames)`.
    pub fn poll_into_bytes(&self, dst_bytes: &mut [u8], max_frames: u32) -> (u32, u64) {
        if self.closed.load(Ordering::Acquire) {
            return (0, self.last_reported_dropped.load(Ordering::Relaxed));
        }

        let ch = self.channels.max(1);
        let bpf = ch * self.format.bytes_per_sample();
        let cap_frames = (dst_bytes.len() / bpf).min(max_frames as usize);
        if cap_frames == 0 {
            return (0, self.total_dropped_frames());
        }

        let mut frames_read = 0usize;
        let mut bytes_written = 0usize;

        // 1. Drain any leftover samples queued in fan-out consumer so mode switches never drop/reorder.
        if let Ok(mut f_guard) = self.fanout_consumer.try_lock() {
            if let Some(ref mut cons) = *f_guard {
                if cons.slots() >= ch {
                    let max_samples = (cap_frames - frames_read) * ch;
                    let (s_read, b_written) = pop_consumer_encoded(
                        cons,
                        max_samples,
                        ch,
                        self.format,
                        &mut dst_bytes[bytes_written..],
                    );
                    frames_read += s_read / ch;
                    bytes_written += b_written;
                }
            }
        }

        // 2. Direct 1-copy fast path from RT SPSC ring when this handle is the sole consumer on the bus.
        if frames_read < cap_frames && !self.hub.fanout_active.load(Ordering::Acquire) {
            if let Ok(mut rt_guard) = self.hub.rt_consumer.try_lock() {
                if !self.hub.fanout_active.load(Ordering::Acquire) {
                    let max_samples = (cap_frames - frames_read) * ch;
                    let (s_read, _b_written) = pop_consumer_encoded(
                        &mut rt_guard,
                        max_samples,
                        ch,
                        self.format,
                        &mut dst_bytes[bytes_written..],
                    );
                    frames_read += s_read / ch;
                }
            }
        }

        (frames_read as u32, self.total_dropped_frames())
    }

    /// Web helper using a per-handle reusable scratch byte buffer under `try_lock` to avoid per-poll allocs.
    pub fn with_scratch_poll<R>(
        &self,
        max_bytes: usize,
        max_frames: u32,
        f: impl FnOnce(u32, &[u8]) -> R,
    ) -> Option<R> {
        let Ok(mut scratch) = self.web_scratch_u8.try_lock() else {
            return None;
        };
        if scratch.len() < max_bytes {
            scratch.resize(max_bytes, 0);
        }
        let (frames, _) = self.poll_into_bytes(&mut scratch[..max_bytes], max_frames);
        let used_bytes = frames as usize * self.channels.max(1) * self.format.bytes_per_sample();
        Some(f(frames, &scratch[..used_bytes]))
    }
}

static PULL_TAP_REGISTRY: OnceLock<RwLock<HashMap<u32, Arc<PullTapHandle>>>> = OnceLock::new();
static NEXT_PULL_TAP_ID: AtomicU32 = AtomicU32::new(1);

fn global_pull_taps() -> &'static RwLock<HashMap<u32, Arc<PullTapHandle>>> {
    PULL_TAP_REGISTRY.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Looks up an active global Pull tap handle without blocking if registry is contended (`try_read`).
pub fn lookup_pull_tap_nonblocking(tap_id: u32) -> Option<Arc<PullTapHandle>> {
    if tap_id == 0 {
        return None;
    }
    let guard = global_pull_taps().try_read().ok()?;
    guard.get(&tap_id).cloned()
}

/// Closes a global Pull tap handle cleanly by ID (safe/idempotent from Dart `Finalizer` or explicit close).
///
/// Uses non-blocking locks when invoked on the Web main UI thread so `Atomics.wait` is never touched.
pub fn close_global_pull_tap(tap_id: u32) {
    if tap_id == 0 {
        return;
    }
    let removed = if !can_block_current_thread() {
        if let Ok(guard) = global_pull_taps().try_read() {
            if let Some(h) = guard.get(&tap_id) {
                h.mark_closed();
            }
        }
        if let Ok(mut guard) = global_pull_taps().try_write() {
            guard.remove(&tap_id)
        } else {
            None
        }
    } else if let Ok(mut guard) = global_pull_taps().write() {
        guard.remove(&tap_id)
    } else {
        None
    };

    if let Some(handle) = removed {
        handle.mark_closed();
        handle.hub.reconcile_bus_after_pull_close(tap_id);
    }
}

/// Global reference-counted tap hub managing all 5 audio output buses for a player instance.
pub struct TapBusRegistry {
    control: Arc<TapControlState>,
    hubs: [Arc<BusHub>; TAP_BUS_COUNT],
    sample_rate: u32,
    channels: usize,
    owned_pull_ids: Mutex<Vec<u32>>,
    dispatcher_thread: Mutex<Option<JoinHandle<()>>>,
}

impl Drop for TapBusRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Creates a paired `(TapRtMatrix, Arc<TapBusRegistry>)` sharing lock-free RT SPSC rings per bus.
pub fn create_tap_pair(sample_rate: u32, channels: usize) -> (TapRtMatrix, Arc<TapBusRegistry>) {
    let sr = sample_rate.max(8000);
    let ch = channels.max(1);
    let active_bus_mask = Arc::new(AtomicU8::new(0));
    let control = Arc::new(TapControlState {
        active_bus_mask: active_bus_mask.clone(),
        has_fanout_work: AtomicBool::new(false),
        wake_lock: Mutex::new(false),
        wake_cvar: Condvar::new(),
        shutdown: AtomicBool::new(false),
    });

    let mut rt_slots: Vec<TapRtBusSlot> = Vec::with_capacity(TAP_BUS_COUNT);
    let mut hubs_vec: Vec<Arc<BusHub>> = Vec::with_capacity(TAP_BUS_COUNT);

    for bus_idx in 0..TAP_BUS_COUNT {
        let (prod, cons) = rtrb::RingBuffer::new(TAP_RING_CAPACITY_SAMPLES);
        let dropped = Arc::new(AtomicU64::new(0));
        rt_slots.push(TapRtBusSlot {
            producer: prod,
            dropped_frames: dropped.clone(),
        });
        hubs_vec.push(Arc::new(BusHub {
            bus_idx,
            rt_consumer: Mutex::new(cons),
            rt_dropped_frames: dropped,
            fanout_active: AtomicBool::new(false),
            control: control.clone(),
            state: Mutex::new(BusSubscribers::default()),
        }));
    }

    let slots: [TapRtBusSlot; TAP_BUS_COUNT] = rt_slots
        .try_into()
        .unwrap_or_else(|_| unreachable!("exactly TAP_BUS_COUNT slots"));
    let hubs: [Arc<BusHub>; TAP_BUS_COUNT] = hubs_vec
        .try_into()
        .unwrap_or_else(|_| unreachable!("exactly TAP_BUS_COUNT hubs"));

    let matrix = TapRtMatrix {
        active_bus_mask,
        slots,
        channels: ch,
    };
    let registry = Arc::new(TapBusRegistry {
        control,
        hubs,
        sample_rate: sr,
        channels: ch,
        owned_pull_ids: Mutex::new(Vec::new()),
        dispatcher_thread: Mutex::new(None),
    });

    (matrix, registry)
}

type PendingPushSend = (usize, u64, Arc<dyn TapChunkSink>, TapChunk);

impl BusHub {
    fn reconcile_unlocked(&self, subs: &mut BusSubscribers) -> (bool, bool) {
        subs.push_subs.retain(|s| !s.closed);
        subs.pull_subs.retain(|p| !p.is_closed());

        let has_any = !subs.push_subs.is_empty() || !subs.pull_subs.is_empty();
        let need_fanout = !subs.push_subs.is_empty() || subs.pull_subs.len() > 1;
        let bit = 1u8 << self.bus_idx;

        if !has_any {
            self.control.active_bus_mask.fetch_and(!bit, Ordering::AcqRel);
            self.fanout_active.store(false, Ordering::Release);
            if let Ok(mut rt_cons) = self.rt_consumer.try_lock() {
                discard_consumer(&mut rt_cons);
            }
            return (false, false);
        }

        let was_active = (self.control.active_bus_mask.load(Ordering::Acquire) & bit) != 0;
        if !was_active {
            // Drain stale samples before arming the active bus bit so newly attached taps start clean.
            if !can_block_current_thread() {
                if let Ok(mut rt_cons) = self.rt_consumer.try_lock() {
                    discard_consumer(&mut rt_cons);
                }
            } else {
                let mut rt_cons = lock_unpoisoned(&self.rt_consumer);
                discard_consumer(&mut rt_cons);
            }
            self.control.active_bus_mask.fetch_or(bit, Ordering::AcqRel);
        }

        let was_fanout = self.fanout_active.load(Ordering::Acquire);
        if need_fanout && !was_fanout {
            for pull in &subs.pull_subs {
                pull.ensure_fanout_ring();
            }
            self.fanout_active.store(true, Ordering::Release);
        } else if !need_fanout && was_fanout {
            self.fanout_active.store(false, Ordering::Release);
        }

        (true, need_fanout)
    }

    fn reconcile_bus_after_pull_close(&self, tap_id: u32) {
        let locked = if !can_block_current_thread() {
            self.state.try_lock().ok()
        } else {
            Some(lock_unpoisoned(&self.state))
        };
        if let Some(mut subs) = locked {
            subs.pull_subs.retain(|p| p.tap_id != tap_id && !p.is_closed());
            let _ = self.reconcile_unlocked(&mut subs);
        }
        self.control.try_notify_wake();
    }

    fn mark_push_closed(&self, client_key: u64) {
        let mut subs = lock_unpoisoned(&self.state);
        for sub in &mut subs.push_subs {
            if sub.client_key == client_key {
                sub.closed = true;
            }
        }
        let _ = self.reconcile_unlocked(&mut subs);
    }

    fn pump_fanout(
        &self,
        sample_rate: u32,
        channels: usize,
        scratch_f32: &mut Vec<f32>,
        encoded_cache: &mut HashMap<(TapSampleFormat, usize), Vec<u8>>,
        pending_sends: &mut Vec<PendingPushSend>,
    ) -> (bool, bool) {
        if !self.fanout_active.load(Ordering::Acquire) {
            return (false, false);
        }

        {
            let mut rt_cons = lock_unpoisoned(&self.rt_consumer);
            drain_consumer_to_vec(&mut rt_cons, channels, scratch_f32);
        }

        let mut subs = lock_unpoisoned(&self.state);
        let before_pulls = subs.pull_subs.len();
        let before_pushes = subs.push_subs.len();
        subs.pull_subs.retain(|p| !p.is_closed());
        subs.push_subs.retain(|s| !s.closed);
        if subs.pull_subs.len() != before_pulls || subs.push_subs.len() != before_pushes {
            let (has_any, need_fanout) = self.reconcile_unlocked(&mut subs);
            if !need_fanout {
                return (has_any, false);
            }
        }

        if scratch_f32.is_empty() {
            let has_any = !subs.push_subs.is_empty() || !subs.pull_subs.is_empty();
            let need_fanout = !subs.push_subs.is_empty() || subs.pull_subs.len() > 1;
            return (has_any, need_fanout);
        }

        // Fan out to any Pull handles sharing this bus.
        for pull in &subs.pull_subs {
            pull.push_fanout_samples(scratch_f32);
        }

        // Accumulate into Push subscribers and coalesce identical `(format, target_samples)` encodings.
        encoded_cache.clear();
        let rt_dropped = self.rt_dropped_frames.load(Ordering::Relaxed);
        let ch = channels.max(1);

        for sub in &mut subs.push_subs {
            sub.accum_f32.extend_from_slice(scratch_f32);
            let req_samples = sub.target_samples;
            if req_samples == 0 {
                continue;
            }
            let frame_count = (req_samples / ch) as u32;
            while sub.accum_f32.len() >= req_samples {
                let encoded = encoded_cache
                    .entry((sub.format, req_samples))
                    .or_insert_with(|| {
                        let mut buf = vec![0u8; req_samples * sub.format.bytes_per_sample()];
                        let written = encode_f32_into_bytes(
                            &sub.accum_f32[..req_samples],
                            sub.format,
                            &mut buf,
                        );
                        buf.truncate(written);
                        buf
                    });

                pending_sends.push((
                    self.bus_idx,
                    sub.client_key,
                    sub.sink.clone(),
                    TapChunk {
                        source: self.bus_idx as i32,
                        format: sub.format,
                        sample_rate,
                        channels: ch,
                        frame_count,
                        dropped_frames: rt_dropped.saturating_sub(sub.dropped_baseline),
                        bytes: encoded.clone(),
                    },
                ));

                sub.accum_f32.drain(..req_samples);
            }
        }

        let has_any = !subs.push_subs.is_empty() || !subs.pull_subs.is_empty();
        let need_fanout = !subs.push_subs.is_empty() || subs.pull_subs.len() > 1;
        (has_any, need_fanout)
    }
}

impl TapBusRegistry {
    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Returns the bitmask of currently active buses (`bit b = (1 << b)`).
    #[inline]
    pub fn active_bus_mask(&self) -> u8 {
        self.control.active_bus_mask.load(Ordering::Acquire)
    }

    fn validate_bus(source: i32) -> Result<usize, String> {
        if !(0..TAP_BUS_COUNT as i32).contains(&source) {
            return Err(format!(
                "Invalid AudioOutputSource {}: expected 0..{}",
                source,
                TAP_BUS_COUNT - 1
            ));
        }
        Ok(source as usize)
    }

    /// Registers a Push broadcast subscriber for a bus and activates off-RT fan-out dispatching.
    pub fn add_push_tap(
        &self,
        client_key: u64,
        source: i32,
        format: TapSampleFormat,
        frame_duration_ms: u32,
        sink: Arc<dyn TapChunkSink>,
    ) -> Result<(), String> {
        if self.control.shutdown.load(Ordering::Acquire) {
            return Err("TapBusRegistry is shut down".to_string());
        }
        if !(MIN_TAP_FRAME_DURATION_MS..=MAX_TAP_FRAME_DURATION_MS).contains(&frame_duration_ms) {
            return Err(format!(
                "frameDurationMs {} out of supported range {}..{}",
                frame_duration_ms, MIN_TAP_FRAME_DURATION_MS, MAX_TAP_FRAME_DURATION_MS
            ));
        }

        let bus_idx = Self::validate_bus(source)?;
        let target_frames = ((self.sample_rate as u64 * frame_duration_ms as u64) / 1000).max(1);
        let target_samples = (target_frames as usize) * self.channels;

        let hub = &self.hubs[bus_idx];
        {
            let mut subs = lock_unpoisoned(&hub.state);
            subs.push_subs
                .retain(|s| s.client_key != client_key && !s.closed);
            subs.push_subs.push(PushSubscriber {
                client_key,
                format,
                target_samples,
                accum_f32: Vec::with_capacity(target_samples * 2),
                dropped_baseline: hub.rt_dropped_frames.load(Ordering::Relaxed),
                sink,
                closed: false,
            });
        }

        self.recompute_fanout_and_wake();
        Ok(())
    }

    /// Unregisters a Push subscriber by `client_key` and reconciles `active_bus_mask`.
    pub fn remove_push_tap(&self, client_key: u64) {
        for hub in &self.hubs {
            let mut subs = lock_unpoisoned(&hub.state);
            subs.push_subs
                .retain(|s| s.client_key != client_key && !s.closed);
        }
        self.recompute_fanout_and_wake();
    }

    /// Opens a zero-allocation Pull tap handle for the given bus.
    pub fn create_pull_tap(
        &self,
        source: i32,
        format: TapSampleFormat,
    ) -> Result<Arc<PullTapHandle>, String> {
        if self.control.shutdown.load(Ordering::Acquire) {
            return Err("TapBusRegistry is shut down".to_string());
        }
        let bus_idx = Self::validate_bus(source)?;
        let hub = self.hubs[bus_idx].clone();

        let mut tap_id = NEXT_PULL_TAP_ID.fetch_add(1, Ordering::Relaxed);
        if tap_id == 0 {
            tap_id = NEXT_PULL_TAP_ID.fetch_add(1, Ordering::Relaxed);
        }

        let handle = Arc::new(PullTapHandle {
            tap_id,
            bus_idx,
            format,
            sample_rate: self.sample_rate,
            channels: self.channels,
            hub: hub.clone(),
            fanout_producer: Mutex::new(None),
            fanout_consumer: Mutex::new(None),
            rt_dropped_baseline: AtomicU64::new(hub.rt_dropped_frames.load(Ordering::Relaxed)),
            fanout_dropped_frames: AtomicU64::new(0),
            last_reported_dropped: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            web_scratch_u8: Mutex::new(Vec::new()),
        });

        {
            let mut global = global_pull_taps()
                .write()
                .unwrap_or_else(|e| e.into_inner());
            global.insert(tap_id, handle.clone());
        }
        {
            let mut owned = lock_unpoisoned(&self.owned_pull_ids);
            owned.push(tap_id);
        }
        {
            let mut subs = lock_unpoisoned(&hub.state);
            subs.pull_subs.push(handle.clone());
        }

        self.recompute_fanout_and_wake();
        Ok(handle)
    }

    /// Explicitly closes a Pull tap owned by this registry and updates `active_bus_mask`.
    pub fn close_pull_tap(&self, tap_id: u32) {
        {
            let mut owned = lock_unpoisoned(&self.owned_pull_ids);
            owned.retain(|&id| id != tap_id);
        }
        close_global_pull_tap(tap_id);
        self.recompute_fanout_and_wake();
    }

    /// Shuts down all Push/Pull taps, disables the RT mask, and joins the dispatcher worker.
    pub fn shutdown(&self) {
        if self.control.shutdown.swap(true, Ordering::AcqRel) {
            return;
        }

        let pull_ids = {
            let mut owned = lock_unpoisoned(&self.owned_pull_ids);
            std::mem::take(&mut *owned)
        };
        for tap_id in pull_ids {
            close_global_pull_tap(tap_id);
        }

        for hub in &self.hubs {
            let mut subs = lock_unpoisoned(&hub.state);
            for pull in &subs.pull_subs {
                pull.mark_closed();
            }
            subs.push_subs.clear();
            subs.pull_subs.clear();
            let _ = hub.reconcile_unlocked(&mut subs);
        }

        self.control.has_fanout_work.store(false, Ordering::Release);
        self.control.notify_wake();

        let join = lock_unpoisoned(&self.dispatcher_thread).take();
        if let Some(handle) = join {
            let _ = handle.join();
        }
    }

    fn recompute_fanout_and_wake(&self) {
        if self.control.shutdown.load(Ordering::Acquire) {
            self.control.has_fanout_work.store(false, Ordering::Release);
            self.control.notify_wake();
            return;
        }

        let mut any_fanout = false;
        for hub in &self.hubs {
            let mut subs = lock_unpoisoned(&hub.state);
            let (_, need_fanout) = hub.reconcile_unlocked(&mut subs);
            if need_fanout {
                any_fanout = true;
            }
        }
        self.control
            .has_fanout_work
            .store(any_fanout, Ordering::Release);
        if any_fanout {
            self.ensure_dispatcher_started();
        }
        self.control.notify_wake();
    }

    fn ensure_dispatcher_started(&self) {
        let mut guard = lock_unpoisoned(&self.dispatcher_thread);
        if guard.is_some() || self.control.shutdown.load(Ordering::Acquire) {
            return;
        }

        let ctx = DispatcherCtx {
            control: self.control.clone(),
            hubs: self.hubs.clone(),
            sample_rate: self.sample_rate,
            channels: self.channels,
        };

        let spawn_res = thread::Builder::new()
            .name("map-tap-dispatcher".to_string())
            .spawn(move || run_tap_dispatcher(ctx));

        if let Ok(handle) = spawn_res {
            *guard = Some(handle);
        }
    }
}

struct DispatcherCtx {
    control: Arc<TapControlState>,
    hubs: [Arc<BusHub>; TAP_BUS_COUNT],
    sample_rate: u32,
    channels: usize,
}

fn run_tap_dispatcher(ctx: DispatcherCtx) {
    let mut scratch_f32: Vec<f32> = Vec::with_capacity(TAP_RING_CAPACITY_SAMPLES);
    let mut encoded_cache: HashMap<(TapSampleFormat, usize), Vec<u8>> = HashMap::new();
    let mut pending_sends: Vec<PendingPushSend> = Vec::with_capacity(16);

    loop {
        if ctx.control.shutdown.load(Ordering::Acquire) {
            break;
        }

        if !ctx.control.has_fanout_work.load(Ordering::Acquire) {
            let mut wake = lock_unpoisoned(&ctx.control.wake_lock);
            while !*wake
                && !ctx.control.has_fanout_work.load(Ordering::Acquire)
                && !ctx.control.shutdown.load(Ordering::Acquire)
            {
                let (next_guard, _) = wait_timeout_unpoisoned(
                    &ctx.control.wake_cvar,
                    wake,
                    Duration::from_millis(200),
                );
                wake = next_guard;
            }
            *wake = false;
            continue;
        }

        pending_sends.clear();
        let mut any_fanout = false;
        for hub in &ctx.hubs {
            let (_, bus_fanout) = hub.pump_fanout(
                ctx.sample_rate,
                ctx.channels,
                &mut scratch_f32,
                &mut encoded_cache,
                &mut pending_sends,
            );
            if bus_fanout {
                any_fanout = true;
            }
        }

        let mut closed_keys: Vec<(usize, u64)> = Vec::new();
        for (bus_idx, client_key, sink, chunk) in pending_sends.drain(..) {
            if !sink.send_chunk(chunk) {
                closed_keys.push((bus_idx, client_key));
            }
        }
        if !closed_keys.is_empty() {
            for (bus_idx, client_key) in closed_keys {
                ctx.hubs[bus_idx].mark_push_closed(client_key);
            }
            any_fanout = ctx
                .hubs
                .iter()
                .any(|h| h.fanout_active.load(Ordering::Acquire));
        }

        ctx.control
            .has_fanout_work
            .store(any_fanout, Ordering::Release);

        if any_fanout && !ctx.control.shutdown.load(Ordering::Acquire) {
            let wake = lock_unpoisoned(&ctx.control.wake_lock);
            let _ = wait_timeout_unpoisoned(
                &ctx.control.wake_cvar,
                wake,
                Duration::from_millis(4),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    struct RecordingSink {
        chunks: Mutex<Vec<TapChunk>>,
        allow_send: AtomicBool,
    }

    impl RecordingSink {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                chunks: Mutex::new(Vec::new()),
                allow_send: AtomicBool::new(true),
            })
        }
    }

    impl TapChunkSink for RecordingSink {
        fn send_chunk(&self, chunk: TapChunk) -> bool {
            if !self.allow_send.load(Ordering::Acquire) {
                return false;
            }
            lock_unpoisoned(&self.chunks).push(chunk);
            true
        }
    }

    #[test]
    fn idle_mask_is_zero_and_writes_nothing() {
        let (mut rt, reg) = create_tap_pair(48_000, 2);
        assert_eq!(reg.active_bus_mask(), 0);
        let dummy = [0.25f32; 512];
        rt.write_buses([&dummy, &dummy, &dummy, &dummy, &dummy], 512);
        assert_eq!(reg.active_bus_mask(), 0);
        reg.shutdown();
    }

    #[test]
    fn single_pull_fast_path_reads_direct_without_fanout_and_clears_mask_on_close() {
        let (mut rt, reg) = create_tap_pair(48_000, 2);
        let pull = reg
            .create_pull_tap(4, TapSampleFormat::Float32)
            .expect("create pull tap");
        // VoiceOnly = bus 4 -> bit 16
        assert_eq!(reg.active_bus_mask(), 1 << 4);
        assert!(!pull.hub.fanout_active.load(Ordering::Acquire));

        let voice: Vec<f32> = (0..512).map(|i| i as f32 * 0.001).collect();
        let zeros = [0.0f32; 512];
        rt.write_buses([&zeros, &zeros, &zeros, &zeros, &voice], 512);

        let mut dst = vec![0u8; 512 * 4];
        let (frames, dropped) = pull.poll_into_bytes(&mut dst, 256);
        assert_eq!(frames, 256);
        assert_eq!(dropped, 0);

        let first = f32::from_le_bytes(dst[0..4].try_into().unwrap());
        let tenth = f32::from_le_bytes(dst[40..44].try_into().unwrap());
        assert!((first - 0.0).abs() < 1e-6);
        assert!((tenth - 0.010).abs() < 1e-6);

        reg.close_pull_tap(pull.tap_id);
        assert_eq!(reg.active_bus_mask(), 0);
        reg.shutdown();
    }

    #[test]
    fn pull_pcm16_conversion_matches_little_endian_range() {
        let (mut rt, reg) = create_tap_pair(48_000, 2);
        let pull = reg
            .create_pull_tap(1, TapSampleFormat::Pcm16)
            .expect("create pull pcm16");

        let music = [1.0f32, -1.0f32, 0.5f32, 0.0f32];
        let zeros = [0.0f32; 4];
        rt.write_buses([&zeros, &music, &zeros, &zeros, &zeros], 4);

        let mut dst = [0u8; 8];
        let (frames, _) = pull.poll_into_bytes(&mut dst, 2);
        assert_eq!(frames, 2);
        assert_eq!(i16::from_le_bytes(dst[0..2].try_into().unwrap()), 32767);
        assert_eq!(i16::from_le_bytes(dst[2..4].try_into().unwrap()), -32767);
        assert_eq!(i16::from_le_bytes(dst[4..6].try_into().unwrap()), 16384);
        assert_eq!(i16::from_le_bytes(dst[6..8].try_into().unwrap()), 0);
        reg.shutdown();
    }

    #[test]
    fn multi_bus_and_coalesced_push_fanout_work_independently() {
        let (mut rt, reg) = create_tap_pair(48_000, 2);
        let voice_sink = RecordingSink::new();
        let music_sink = RecordingSink::new();

        // Listen to VoiceOnly (4) + MusicMix (1) simultaneously via Push (20ms = 960 frames = 1920 samples)
        reg.add_push_tap(10, 4, TapSampleFormat::Float32, 20, voice_sink.clone())
            .expect("add voice push");
        reg.add_push_tap(20, 1, TapSampleFormat::Pcm16, 20, music_sink.clone())
            .expect("add music push");
        assert_eq!(reg.active_bus_mask(), (1 << 4) | (1 << 1));

        let voice = vec![0.5f32; 1920];
        let music = vec![-0.5f32; 1920];
        let zeros = vec![0.0f32; 1920];
        rt.write_buses([&zeros, &music, &zeros, &zeros, &voice], 1920);

        for _ in 0..80 {
            let vc = lock_unpoisoned(&voice_sink.chunks).len();
            let mc = lock_unpoisoned(&music_sink.chunks).len();
            if vc >= 1 && mc >= 1 {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }

        let v_chunks = lock_unpoisoned(&voice_sink.chunks);
        let m_chunks = lock_unpoisoned(&music_sink.chunks);
        assert!(!v_chunks.is_empty(), "expected voice push chunk");
        assert!(!m_chunks.is_empty(), "expected music push chunk");
        assert_eq!(v_chunks[0].source, 4);
        assert_eq!(v_chunks[0].format, TapSampleFormat::Float32);
        assert_eq!(v_chunks[0].frame_count, 960);
        assert_eq!(m_chunks[0].source, 1);
        assert_eq!(m_chunks[0].format, TapSampleFormat::Pcm16);
        assert_eq!(m_chunks[0].frame_count, 960);
        drop(v_chunks);
        drop(m_chunks);

        // Removing voice restores MusicOnly bit cleanly; cancelling music clears mask to 0
        reg.remove_push_tap(10);
        assert_eq!(reg.active_bus_mask(), 1 << 1);
        reg.remove_push_tap(20);
        assert_eq!(reg.active_bus_mask(), 0);
        reg.shutdown();
    }

    #[test]
    fn duplicate_voice_subscribers_share_bus_until_last_removed() {
        let (mut rt, reg) = create_tap_pair(48_000, 2);
        let sink = RecordingSink::new();
        reg.add_push_tap(1, 4, TapSampleFormat::Float32, 20, sink.clone())
            .unwrap();
        reg.add_push_tap(2, 4, TapSampleFormat::Float32, 20, sink.clone())
            .unwrap();
        let pull = reg.create_pull_tap(4, TapSampleFormat::Float32).unwrap();
        assert_eq!(reg.active_bus_mask(), 1 << 4);
        assert!(pull.hub.fanout_active.load(Ordering::Acquire));

        let voice = vec![0.25f32; 1920];
        let zeros = vec![0.0f32; 1920];
        rt.write_buses([&zeros, &zeros, &zeros, &zeros, &voice], 1920);

        let got_pull = Arc::new(AtomicUsize::new(0));
        let mut buf = vec![0u8; 960 * 2 * 4];
        for _ in 0..80 {
            let (frames, _) = pull.poll_into_bytes(&mut buf, 960);
            if frames > 0 {
                got_pull.fetch_add(frames as usize, Ordering::Relaxed);
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(got_pull.load(Ordering::Relaxed) > 0);

        reg.remove_push_tap(1);
        assert_eq!(reg.active_bus_mask(), 1 << 4);
        reg.remove_push_tap(2);
        assert_eq!(reg.active_bus_mask(), 1 << 4);
        // Single remaining Pull tap exits fan-out and stays active directly
        assert!(!pull.hub.fanout_active.load(Ordering::Acquire));
        reg.close_pull_tap(pull.tap_id);
        assert_eq!(reg.active_bus_mask(), 0);
        reg.shutdown();
    }
}
