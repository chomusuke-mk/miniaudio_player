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

/// Minimum allowed chunk frame duration in milliseconds for Push batching.
pub const MIN_TAP_FRAME_DURATION_MS: u32 = 5;
/// Maximum allowed chunk frame duration in milliseconds for Push batching.
pub const MAX_TAP_FRAME_DURATION_MS: u32 = 200;

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
    /// Converts raw integer wire `value` (`0`: Float32, `1`: Pcm16) into [`TapSampleFormat`].
    ///
    /// # Errors
    ///
    /// Returns an error string if `value` is not `0` or `1`.
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
    /// Zero-based bus index (`0..TAP_BUS_COUNT`) that produced this chunk.
    pub source: i32,
    /// Sample encoding format of `bytes`.
    pub format: TapSampleFormat,
    /// Sample rate in Hertz.
    pub sample_rate: u32,
    /// Number of interleaved audio channels.
    pub channels: usize,
    /// Number of audio frames encoded in `bytes`.
    pub frame_count: u32,
    /// Cumulative dropped frames observed by the tap since opening.
    pub dropped_frames: u64,
    /// Little-endian encoded PCM payload bytes.
    pub bytes: Vec<u8>,
}

/// Sink abstraction allowing `core::tap` to be unit-tested in pure Rust without FRB runtime.
pub trait TapChunkSink: Send + Sync {
    /// Delivers `chunk`; returns `false` if the downstream receiver is closed/canceled.
    fn send_chunk(&self, chunk: TapChunk) -> bool;
}

/// Encodes interleaved `f32` samples from `src` directly into `dst` according to `format`, returning bytes written.
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

/// Reads up to `max_samples` (frame-aligned to `channels`) from `cons`, encoding
/// directly from its ring slices in `format` into `dst_bytes`, and returns `(samples_read, bytes_written)`.
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

/// Drains all currently available frame-aligned samples (aligned to `channels`) from `cons` into `out` without reallocating when capacity suffices.
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

/// Pushes interleaved `src` samples (aligned to `channels`) into `prod`, incrementing `dropped_frames` on ring overflow.
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
    /// SPSC producer written on the RT audio thread.
    producer: rtrb::Producer<f32>,
    /// Cumulative frames dropped due to full SPSC ring capacity.
    dropped_frames: Arc<AtomicU64>,
}

/// Lock-free multi-bus tap matrix owned exclusively by `OutputManager` on the RT audio thread.
pub struct TapRtMatrix {
    /// Bitmask of buses currently having at least one active subscriber.
    active_bus_mask: Arc<AtomicU8>,
    /// Fixed-size array of per-bus RT ring slots.
    slots: [TapRtBusSlot; TAP_BUS_COUNT],
    /// Interleaved channel count of the output mixer.
    channels: usize,
}

impl TapRtMatrix {
    /// Copies active output bus `slices` (up to `sample_count` samples) into their respective RT SPSC rings (`~0.27 ns` when idle).
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

/// Registered Push tap subscriber accumulating samples until reaching its batch target.
struct PushSubscriber {
    /// Unique client identifier for unregistration.
    client_key: u64,
    /// Wire encoding format requested by this subscriber.
    format: TapSampleFormat,
    /// Target number of interleaved `f32` samples per emitted [`TapChunk`].
    target_samples: usize,
    /// Accumulation buffer holding partial frames across dispatcher ticks.
    accum_f32: Vec<f32>,
    /// Initial RT dropped-frame count captured when the subscriber registered.
    dropped_baseline: u64,
    /// Downstream chunk sink delivering encoded batches.
    sink: Arc<dyn TapChunkSink>,
    /// Tombstone flag set when the sink rejects further chunks.
    closed: bool,
}

/// Per-bus collection of active Push and Pull subscribers.
#[derive(Default)]
struct BusSubscribers {
    /// Active Push broadcast subscribers on this bus.
    push_subs: Vec<PushSubscriber>,
    /// Active Pull tap handles attached to this bus.
    pull_subs: Vec<Arc<PullTapHandle>>,
}

/// Shared coordination state between [`TapBusRegistry`] and the off-RT dispatcher worker.
struct TapControlState {
    /// Bitmask of active buses mirrored to [`TapRtMatrix`].
    active_bus_mask: Arc<AtomicU8>,
    /// Whether any bus currently requires off-RT dispatcher fan-out.
    has_fanout_work: AtomicBool,
    /// Mutex paired with `wake_cvar` to guard wakeup predicates.
    wake_lock: Mutex<bool>,
    /// Condition variable waking the dispatcher thread on topology changes.
    wake_cvar: Condvar,
    /// Shutdown signal stopping the dispatcher thread.
    shutdown: AtomicBool,
}

impl TapControlState {
    /// Acquires `wake_lock` and notifies the dispatcher thread to re-evaluate work.
    #[inline]
    fn notify_wake(&self) {
        let mut wake = lock_unpoisoned(&self.wake_lock);
        *wake = true;
        drop(wake);
        self.wake_cvar.notify_all();
    }

    /// Best-effort non-blocking wakeup safe for contexts that must avoid blocking locks.
    #[inline]
    fn try_notify_wake(&self) {
        if let Ok(mut wake) = self.wake_lock.try_lock() {
            *wake = true;
        }
        self.wake_cvar.notify_all();
    }
}

/// Shared hub synchronizing the RT bus ring with Push/Pull subscribers for one output bus.
struct BusHub {
    /// Zero-based bus index (`0..TAP_BUS_COUNT`).
    bus_idx: usize,
    /// Consumer end of the RT SPSC ring buffer for this bus.
    rt_consumer: Mutex<rtrb::Consumer<f32>>,
    /// Cumulative dropped frames reported by the RT producer slot.
    rt_dropped_frames: Arc<AtomicU64>,
    /// Whether the off-RT dispatcher thread owns draining `rt_consumer` for fan-out.
    fanout_active: AtomicBool,
    /// Shared control and wakeup state across all buses.
    control: Arc<TapControlState>,
    /// Protected subscriber list for this bus.
    state: Mutex<BusSubscribers>,
}

/// Handle for zero-allocation Pull reading on an audio output bus.
pub struct PullTapHandle {
    /// Globally unique tap identifier used by FFI lookups.
    pub tap_id: u32,
    /// Zero-based bus index (`0..TAP_BUS_COUNT`) tapped by this handle.
    pub bus_idx: usize,
    /// Target wire sample encoding emitted by [`PullTapHandle::poll_into_bytes`].
    pub format: TapSampleFormat,
    /// Sample rate in Hertz.
    pub sample_rate: u32,
    /// Number of interleaved channels.
    pub channels: usize,
    /// Shared hub for the tapped bus.
    hub: Arc<BusHub>,
    /// Secondary SPSC producer written by the dispatcher during fan-out mode.
    fanout_producer: Mutex<Option<rtrb::Producer<f32>>>,
    /// Secondary SPSC consumer read by callers during fan-out mode.
    fanout_consumer: Mutex<Option<rtrb::Consumer<f32>>>,
    /// RT dropped-frame baseline captured when this handle opened.
    rt_dropped_baseline: AtomicU64,
    /// Frames dropped while pushing into this handle's fan-out ring.
    fanout_dropped_frames: AtomicU64,
    /// Cached last reported dropped-frame count returned after closing.
    last_reported_dropped: AtomicU64,
    /// Flag indicating this handle has been closed.
    closed: AtomicBool,
    /// Reusable per-handle scratch buffer used by [`PullTapHandle::with_scratch_poll`].
    web_scratch_u8: Mutex<Vec<u8>>,
}

impl PullTapHandle {
    /// Lazily allocates the secondary SPSC ring used when this bus enters fan-out mode.
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

    /// Pushes fanned-out `src` samples from the dispatcher thread into this handle's secondary ring.
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

    /// Polls up to `max_frames` (capped at `max_bytes`) into a per-handle reusable scratch buffer under `try_lock`, invoking `f` with `(frames_read, encoded_slice)`.
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

/// Global registry mapping active `tap_id` values to their [`PullTapHandle`] instances.
static PULL_TAP_REGISTRY: OnceLock<RwLock<HashMap<u32, Arc<PullTapHandle>>>> = OnceLock::new();
/// Monotonic counter generating unique non-zero Pull tap identifiers.
static NEXT_PULL_TAP_ID: AtomicU32 = AtomicU32::new(1);

/// Returns the lazily initialized global Pull tap handle registry.
fn global_pull_taps() -> &'static RwLock<HashMap<u32, Arc<PullTapHandle>>> {
    PULL_TAP_REGISTRY.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Looks up an active global Pull tap handle by `tap_id` without blocking if the registry is contended (`try_read`).
pub fn lookup_pull_tap_nonblocking(tap_id: u32) -> Option<Arc<PullTapHandle>> {
    if tap_id == 0 {
        return None;
    }
    let guard = global_pull_taps().try_read().ok()?;
    guard.get(&tap_id).cloned()
}

/// Closes a global Pull tap handle cleanly by `tap_id` (safe and idempotent from Dart `Finalizer` or explicit close).
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
        crate::map_log!(
            3,
            "[TAP] Closed Pull tap tap_id={} bus={}",
            tap_id,
            handle.bus_idx
        );
        handle.mark_closed();
        handle.hub.reconcile_bus_after_pull_close(tap_id);
    }
}

/// Global reference-counted tap hub managing all 5 audio output buses for a player instance.
pub struct TapBusRegistry {
    /// Shared control and wakeup state for the dispatcher worker.
    control: Arc<TapControlState>,
    /// Per-bus subscriber hubs indexed by `0..TAP_BUS_COUNT`.
    hubs: [Arc<BusHub>; TAP_BUS_COUNT],
    /// Output sample rate in Hertz.
    sample_rate: u32,
    /// Interleaved output channel count.
    channels: usize,
    /// List of global Pull tap IDs created by this registry for cleanup on shutdown.
    owned_pull_ids: Mutex<Vec<u32>>,
    /// Join handle for the lazily spawned off-RT fan-out dispatcher thread.
    dispatcher_thread: Mutex<Option<JoinHandle<()>>>,
}

impl Drop for TapBusRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Creates a paired `(TapRtMatrix, Arc<TapBusRegistry>)` sharing lock-free RT SPSC rings per bus
/// for `sample_rate` and `channels`.
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

/// Queued outbound Push delivery `(bus_idx, client_key, sink, chunk)` flushed outside hub locks.
type PendingPushSend = (usize, u64, Arc<dyn TapChunkSink>, TapChunk);

impl BusHub {
    /// Reconciles active RT bitmask and fan-out mode for `subs`, returning `(has_any, need_fanout)`.
    fn reconcile_unlocked(&self, subs: &mut BusSubscribers) -> (bool, bool) {
        subs.push_subs.retain(|s| !s.closed);
        subs.pull_subs.retain(|p| !p.is_closed());

        let has_any = !subs.push_subs.is_empty() || !subs.pull_subs.is_empty();
        let need_fanout = !subs.push_subs.is_empty() || subs.pull_subs.len() > 1;
        let bit = 1u8 << self.bus_idx;

        if !has_any {
            let prev_mask = self.control.active_bus_mask.fetch_and(!bit, Ordering::AcqRel);
            self.fanout_active.store(false, Ordering::Release);
            if let Ok(mut rt_cons) = self.rt_consumer.try_lock() {
                discard_consumer(&mut rt_cons);
            }
            if (prev_mask & bit) != 0 {
                crate::map_log!(4, "[TAP] Deactivated bus={}", self.bus_idx);
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
            crate::map_log!(4, "[TAP] Activated bus={}", self.bus_idx);
        }

        let was_fanout = self.fanout_active.load(Ordering::Acquire);
        if need_fanout && !was_fanout {
            for pull in &subs.pull_subs {
                pull.ensure_fanout_ring();
            }
            self.fanout_active.store(true, Ordering::Release);
            crate::map_log!(4, "[TAP] Enabled fan-out on bus={}", self.bus_idx);
        } else if !need_fanout && was_fanout {
            self.fanout_active.store(false, Ordering::Release);
            crate::map_log!(4, "[TAP] Disabled fan-out on bus={}", self.bus_idx);
        }

        (true, need_fanout)
    }

    /// Removes closed Pull handle `tap_id` from this bus hub and wakes the dispatcher if needed.
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

    /// Marks the Push subscriber matching `client_key` as closed and reconciles bus state.
    fn mark_push_closed(&self, client_key: u64) {
        let mut subs = lock_unpoisoned(&self.state);
        for sub in &mut subs.push_subs {
            if sub.client_key == client_key {
                sub.closed = true;
            }
        }
        let _ = self.reconcile_unlocked(&mut subs);
    }

    /// Allocates and returns encoded wire bytes for `src` samples in `format`.
    fn encode_tap_chunk(src: &[f32], format: TapSampleFormat) -> Vec<u8> {
        let mut buf = vec![0u8; src.len() * format.bytes_per_sample()];
        let written = encode_f32_into_bytes(src, format, &mut buf);
        buf.truncate(written);
        buf
    }

    /// Drains RT samples into `scratch_f32`, fans out to Pull subscribers, and batches encoded Push chunks into `pending_sends` using `sample_rate`, `channels`, and `encoded_cache`.
    fn pump_fanout(
        &self,
        sample_rate: u32,
        channels: usize,
        scratch_f32: &mut Vec<f32>,
        encoded_cache: &mut HashMap<(TapSampleFormat, usize, usize), Vec<u8>>,
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

        // Accumulate into Push subscribers and coalesce identical
        // `(format, target_samples, scratch_offset)` encodings across aligned peers.
        encoded_cache.clear();
        let rt_dropped = self.rt_dropped_frames.load(Ordering::Relaxed);
        let ch = channels.max(1);

        for sub in &mut subs.push_subs {
            let prior_len = sub.accum_f32.len();
            sub.accum_f32.extend_from_slice(scratch_f32);
            let req_samples = sub.target_samples;
            if req_samples == 0 {
                continue;
            }
            let frame_count = (req_samples / ch) as u32;
            let mut drained = 0usize;
            while sub.accum_f32.len() >= req_samples {
                let bytes = if drained >= prior_len {
                    let src_offset = drained - prior_len;
                    encoded_cache
                        .entry((sub.format, req_samples, src_offset))
                        .or_insert_with(|| {
                            Self::encode_tap_chunk(&sub.accum_f32[..req_samples], sub.format)
                        })
                        .clone()
                } else {
                    Self::encode_tap_chunk(&sub.accum_f32[..req_samples], sub.format)
                };

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
                        bytes,
                    },
                ));

                sub.accum_f32.drain(..req_samples);
                drained += req_samples;
            }
        }

        let has_any = !subs.push_subs.is_empty() || !subs.pull_subs.is_empty();
        let need_fanout = !subs.push_subs.is_empty() || subs.pull_subs.len() > 1;
        (has_any, need_fanout)
    }
}

impl TapBusRegistry {
    /// Returns the configured output sample rate in Hertz.
    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Returns the configured interleaved channel count.
    #[inline]
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Returns the bitmask of currently active buses (`bit b = (1 << b)`).
    #[inline]
    pub fn active_bus_mask(&self) -> u8 {
        self.control.active_bus_mask.load(Ordering::Acquire)
    }

    /// Validates that `source` lies within `0..TAP_BUS_COUNT` and returns the bus index.
    ///
    /// # Errors
    ///
    /// Returns an error string if `source` is out of range.
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

    /// Registers a Push broadcast subscriber identified by `client_key` on bus `source`
    /// with `format`, `frame_duration_ms`, and `sink`, activating off-RT fan-out dispatching.
    ///
    /// # Errors
    ///
    /// Returns an error string if the registry is shut down, `frame_duration_ms` is outside
    /// `[MIN_TAP_FRAME_DURATION_MS, MAX_TAP_FRAME_DURATION_MS]`, or `source` is invalid.
    pub fn add_push_tap(
        &self,
        client_key: u64,
        source: i32,
        format: TapSampleFormat,
        frame_duration_ms: u32,
        sink: Arc<dyn TapChunkSink>,
    ) -> Result<(), String> {
        if self.control.shutdown.load(Ordering::Acquire) {
            crate::map_log!(2, "[TAP] add_push_tap rejected: registry shut down");
            return Err("TapBusRegistry is shut down".to_string());
        }
        if !(MIN_TAP_FRAME_DURATION_MS..=MAX_TAP_FRAME_DURATION_MS).contains(&frame_duration_ms) {
            crate::map_log!(
                2,
                "[TAP] add_push_tap invalid frame_duration_ms={}",
                frame_duration_ms
            );
            return Err(format!(
                "frameDurationMs {} out of supported range {}..{}",
                frame_duration_ms, MIN_TAP_FRAME_DURATION_MS, MAX_TAP_FRAME_DURATION_MS
            ));
        }

        let bus_idx = Self::validate_bus(source).map_err(|e| {
            crate::map_log!(2, "[TAP] add_push_tap invalid bus: {}", e);
            e
        })?;
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

        crate::map_log!(
            3,
            "[TAP] Added Push tap client_key={} bus={} format={:?} duration_ms={}",
            client_key,
            bus_idx,
            format,
            frame_duration_ms
        );
        self.recompute_fanout_and_wake();
        Ok(())
    }

    /// Unregisters a Push subscriber by `client_key` and reconciles `active_bus_mask`.
    pub fn remove_push_tap(&self, client_key: u64) {
        let mut removed = false;
        for hub in &self.hubs {
            let mut subs = lock_unpoisoned(&hub.state);
            let before = subs.push_subs.len();
            subs.push_subs
                .retain(|s| s.client_key != client_key && !s.closed);
            if subs.push_subs.len() != before {
                removed = true;
            }
        }
        if removed {
            crate::map_log!(3, "[TAP] Removed Push tap client_key={}", client_key);
        }
        self.recompute_fanout_and_wake();
    }

    /// Opens a zero-allocation Pull tap handle for bus `source` with encoding `format`.
    ///
    /// # Errors
    ///
    /// Returns an error string if the registry is shut down or `source` is out of range.
    pub fn create_pull_tap(
        &self,
        source: i32,
        format: TapSampleFormat,
    ) -> Result<Arc<PullTapHandle>, String> {
        if self.control.shutdown.load(Ordering::Acquire) {
            crate::map_log!(2, "[TAP] create_pull_tap rejected: registry shut down");
            return Err("TapBusRegistry is shut down".to_string());
        }
        let bus_idx = Self::validate_bus(source).map_err(|e| {
            crate::map_log!(2, "[TAP] create_pull_tap invalid bus: {}", e);
            e
        })?;
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

        crate::map_log!(
            3,
            "[TAP] Created Pull tap tap_id={} bus={} format={:?}",
            tap_id,
            bus_idx,
            format
        );
        self.recompute_fanout_and_wake();
        Ok(handle)
    }

    /// Explicitly closes a Pull tap `tap_id` owned by this registry and updates `active_bus_mask`.
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
        crate::map_log!(3, "[TAP] Shutting down TapBusRegistry");

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

    /// Recomputes per-bus active/fan-out state across all hubs and wakes or starts the dispatcher thread.
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

    /// Lazily spawns the off-RT tap fan-out dispatcher thread if not yet started.
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

        match spawn_res {
            Ok(handle) => {
                crate::map_log!(4, "[TAP] Spawned map-tap-dispatcher thread");
                *guard = Some(handle);
            }
            Err(e) => {
                crate::map_log!(1, "[TAP] Failed to spawn map-tap-dispatcher thread: {}", e);
            }
        }
    }
}

/// Execution context moved into the off-RT tap fan-out dispatcher thread.
struct DispatcherCtx {
    /// Shared control and wakeup state.
    control: Arc<TapControlState>,
    /// Array of per-bus subscriber hubs.
    hubs: [Arc<BusHub>; TAP_BUS_COUNT],
    /// Output sample rate in Hertz.
    sample_rate: u32,
    /// Interleaved output channel count.
    channels: usize,
}

/// Background dispatcher loop servicing fan-out Pull rings and Push subscribers from `ctx`.
fn run_tap_dispatcher(ctx: DispatcherCtx) {
    crate::map_log!(4, "[TAP] Dispatcher loop started");
    let mut scratch_f32: Vec<f32> = Vec::with_capacity(TAP_RING_CAPACITY_SAMPLES);
    let mut encoded_cache: HashMap<(TapSampleFormat, usize, usize), Vec<u8>> = HashMap::new();
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
                crate::map_log!(
                    4,
                    "[TAP] Push sink closed; removing client_key={} bus={}",
                    client_key,
                    bus_idx
                );
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
    crate::map_log!(4, "[TAP] Dispatcher loop exited");
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

    #[test]
    fn push_fanout_burst_emits_distinct_sequential_chunks_without_duplication() {
        let (mut rt, reg) = create_tap_pair(44_100, 2);
        let sink = RecordingSink::new();
        // 20ms @ 44.1kHz stereo = 882 frames = 1764 samples per chunk.
        reg.add_push_tap(99, 0, TapSampleFormat::Pcm16, 20, sink.clone())
            .expect("add push tap");

        // Push 4 chunks (7056 samples = 3528 frames) with strictly monotonic ramp values
        // in a single burst so pump_fanout drains >= 2 chunks in one iteration.
        let total_samples = 1764 * 4;
        let ramp: Vec<f32> = (0..total_samples)
            .map(|i| (i as f32 / total_samples as f32) * 0.9)
            .collect();
        let zeros = vec![0.0f32; total_samples];
        rt.write_buses([&ramp, &zeros, &zeros, &zeros, &zeros], total_samples);

        for _ in 0..100 {
            if lock_unpoisoned(&sink.chunks).len() >= 4 {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }

        let chunks = lock_unpoisoned(&sink.chunks);
        assert_eq!(chunks.len(), 4);
        for (idx, chunk) in chunks.iter().enumerate() {
            assert_eq!(chunk.frame_count, 882);
            let first_sample = i16::from_le_bytes(chunk.bytes[0..2].try_into().unwrap());
            let expected = (ramp[idx * 1764].clamp(-1.0, 1.0) * 32767.0).round() as i16;
            assert_eq!(
                first_sample, expected,
                "chunk {idx} first sample mismatch (cache collision / duplication)"
            );
            if idx > 0 {
                assert_ne!(chunk.bytes, chunks[idx - 1].bytes);
            }
        }
        drop(chunks);

        reg.remove_push_tap(99);
        reg.shutdown();
    }
}
