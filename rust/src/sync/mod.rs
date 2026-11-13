//! Real-time lock-free synchronization and telemetry primitives.
//!
//! Provides single-producer single-consumer (SPSC) ring buffers, cache-padded seqlocks
//! for lockless reader-writer synchronization, and a zero-allocation telemetry dispatcher.

pub mod cancel;
pub mod reaper;
pub mod ring_buffer;
pub mod seqlock;
pub mod telemetry;

pub use cancel::{CancelHookGuard, CancelToken};
pub use reaper::{ReaperHandle, ReaperTrash};
pub use ring_buffer::{AudioConsumer, AudioProducer, AudioRingBuffer};
pub use seqlock::CachePaddedSeqlock;
pub use telemetry::{
    EventType, MapEvent, MapEventData, MonotonicInstant, TelemetryDispatcher,
    TelemetryEvent, TypedEventCallback,
};

use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Acquires a `Mutex` guard even if a previous holder panicked (poison recovery).
#[inline]
pub fn lock_unpoisoned<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Waits on a condition variable with a timeout, recovering the guard if poisoned.
#[inline]
pub fn wait_timeout_unpoisoned<'a, T>(
    cvar: &std::sync::Condvar,
    guard: MutexGuard<'a, T>,
    dur: std::time::Duration,
) -> (MutexGuard<'a, T>, std::sync::WaitTimeoutResult) {
    cvar.wait_timeout(guard, dur).unwrap_or_else(|e| e.into_inner())
}

/// Acquires a read lock on an `RwLock`, recovering gracefully from poisoning.
#[inline]
pub fn read_unpoisoned<T>(rw: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    rw.read().unwrap_or_else(|e| e.into_inner())
}

/// Acquires a write lock on an `RwLock`, recovering gracefully from poisoning.
#[inline]
pub fn write_unpoisoned<T>(rw: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    rw.write().unwrap_or_else(|e| e.into_inner())
}
