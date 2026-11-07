//! Lock-free Single-Producer Single-Consumer (SPSC) Audio Ring Buffer powered by `rtrb`.

use rtrb::{Consumer, Producer, RingBuffer};

/// Producer endpoint of a lock-free SPSC audio sample ring buffer.
pub struct AudioProducer {
    producer: Producer<f32>,
}

impl AudioProducer {
    /// Writes as many samples from `samples` as fit into the ring buffer without blocking.
    ///
    /// Returns the number of samples actually written.
    #[inline(always)]
    pub fn write_chunk(&mut self, samples: &[f32]) -> usize {
        let slots = self.producer.slots();
        let to_write = slots.min(samples.len());
        if to_write == 0 {
            return 0;
        }
        if let Ok(mut chunk) = self.producer.write_chunk(to_write) {
            let (first, second) = chunk.as_mut_slices();
            let first_len = first.len();
            first.copy_from_slice(&samples[..first_len]);
            if !second.is_empty() {
                second.copy_from_slice(&samples[first_len..first_len + second.len()]);
            }
            chunk.commit_all();
            to_write
        } else {
            0
        }
    }

    /// Returns the number of vacant sample slots currently available for writing.
    #[inline(always)]
    pub fn slots_available(&self) -> usize {
        self.producer.slots()
    }

    /// Returns whether the ring buffer is completely full.
    #[inline(always)]
    pub fn is_full(&self) -> bool {
        self.producer.is_full()
    }

    /// Returns the total capacity of the ring buffer in samples.
    #[inline(always)]
    pub fn capacity(&self) -> usize {
        self.producer.buffer().capacity()
    }
}

/// Consumer endpoint of a lock-free SPSC audio sample ring buffer.
pub struct AudioConsumer {
    consumer: Consumer<f32>,
}

impl AudioConsumer {
    /// Reads as many available samples as fit into `out_samples` without blocking.
    ///
    /// Returns the number of samples actually read.
    #[inline(always)]
    pub fn read_chunk(&mut self, out_samples: &mut [f32]) -> usize {
        let slots = self.consumer.slots();
        let to_read = slots.min(out_samples.len());
        if to_read == 0 {
            return 0;
        }
        if let Ok(chunk) = self.consumer.read_chunk(to_read) {
            let (first, second) = chunk.as_slices();
            let first_len = first.len();
            out_samples[..first_len].copy_from_slice(first);
            if !second.is_empty() {
                out_samples[first_len..first_len + second.len()].copy_from_slice(second);
            }
            chunk.commit_all();
            to_read
        } else {
            0
        }
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
    /// Allocates an SPSC ring buffer with the given capacity in samples (minimum 1024).
    pub fn create(capacity_samples: usize) -> (AudioProducer, AudioConsumer) {
        let cap = capacity_samples.max(1024);
        let (producer, consumer) = RingBuffer::new(cap);
        (AudioProducer { producer }, AudioConsumer { consumer })
    }
}
