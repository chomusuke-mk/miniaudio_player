//! Real-time lock-free synchronization and telemetry primitives.
//!
//! Provides single-producer single-consumer (SPSC) ring buffers, cache-padded seqlocks
//! for lockless reader-writer synchronization, and a zero-allocation telemetry dispatcher.

pub mod ring_buffer;
pub mod seqlock;
pub mod telemetry;

pub use ring_buffer::{AudioConsumer, AudioProducer, AudioRingBuffer};
pub use seqlock::CachePaddedSeqlock;
pub use telemetry::{
    EventCallback, EventType, MapEvent, MapEventData, MonotonicInstant, TelemetryDispatcher,
    TelemetryEvent, TypedEventCallback,
};
