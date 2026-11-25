//! Lock-free Single-Producer Single-Consumer (SPSC) Audio Ring Buffer powered by `rtrb`.

use rtrb::{Consumer, Producer, RingBuffer};

/// Producer endpoint of a lock-free SPSC audio sample ring buffer.
pub struct AudioProducer {
    /// Underlying `rtrb` SPSC sample producer.
    producer: Producer<f32>,
}

impl AudioProducer {
    /// Writes as many samples from `samples` as fit into the ring buffer without blocking.
    ///
    /// Returns the number of samples actually written.
    #[inline(always)]
    pub fn write_chunk(&mut self, samples: &[f32]) -> usize {
        if samples.is_empty() {
            return 0;
        }
        self.producer.push_partial_slice(samples).0.len()
    }

    /// Returns the number of vacant sample slots currently available for writing.
    #[inline(always)]
    pub fn slots_available(&self) -> usize {
        self.producer.slots()
    }

    /// Returns the total capacity of the ring buffer in samples.
    #[inline(always)]
    pub fn capacity(&self) -> usize {
        self.producer.buffer().capacity()
    }
}

/// Consumer endpoint of a lock-free SPSC audio sample ring buffer.
pub struct AudioConsumer {
    /// Underlying `rtrb` SPSC sample consumer.
    consumer: Consumer<f32>,
}

impl AudioConsumer {
    /// Reads as many available samples as fit into `out_samples` without blocking.
    ///
    /// Returns the number of samples actually read.
    #[inline(always)]
    pub fn read_chunk(&mut self, out_samples: &mut [f32]) -> usize {
        if out_samples.is_empty() {
            return 0;
        }
        self.consumer.pop_partial_slice(out_samples).0.len()
    }

    /// Returns the number of readable samples currently stored in the ring buffer.
    #[inline(always)]
    pub fn samples_available(&self) -> usize {
        self.consumer.slots()
    }

    /// Returns whether the ring buffer is empty.
    #[inline(always)]
    pub fn is_empty(&self) -> bool {
        self.consumer.is_empty()
    }

    /// Discards all currently queued samples from the ring buffer.
    #[inline(always)]
    pub fn clear(&mut self) {
        let slots = self.consumer.slots();
        if slots > 0 {
            if let Ok(chunk) = self.consumer.read_chunk(slots) {
                chunk.commit_all();
            }
        }
    }
}

/// Factory utility for constructing matching [`AudioProducer`] and [`AudioConsumer`] pairs.
pub struct AudioRingBuffer;

impl AudioRingBuffer {
    /// Allocates an SPSC ring buffer with at least `capacity_samples` samples (minimum `1024`).
    pub fn create(capacity_samples: usize) -> (AudioProducer, AudioConsumer) {
        let cap = capacity_samples.max(1024);
        let (producer, consumer) = RingBuffer::new(cap);
        (AudioProducer { producer }, AudioConsumer { consumer })
    }
}
