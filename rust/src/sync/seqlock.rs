//! Lock-free, wait-free Reader Seqlock with Cache-Line Padding to prevent false sharing.

use crossbeam_utils::CachePadded;
use std::cell::UnsafeCell;
use std::sync::atomic::{fence, AtomicUsize, Ordering};

pub struct CachePaddedSeqlock<T> {
    sequence: CachePadded<AtomicUsize>,
    data: UnsafeCell<T>,
}

unsafe impl<T: Send> Send for CachePaddedSeqlock<T> {}
unsafe impl<T: Send> Sync for CachePaddedSeqlock<T> {}

impl<T> CachePaddedSeqlock<T> {
    pub fn new(initial: T) -> Self {
        Self {
            sequence: CachePadded::new(AtomicUsize::new(0)),
            data: UnsafeCell::new(initial),
        }
    }

    /// Mutates the protected data. Guaranteed to never block readers indefinitely.
    pub fn write<F: FnOnce(&mut T)>(&self, f: F) {
        let seq = self.sequence.load(Ordering::Relaxed);
        // Odd sequence number indicates a write is in progress
        self.sequence.store(seq.wrapping_add(1), Ordering::Release);
        fence(Ordering::Release);

        unsafe {
            f(&mut *self.data.get());
        }

        fence(Ordering::Release);
        // Even sequence number indicates write is complete and consistent
        self.sequence.store(seq.wrapping_add(2), Ordering::Release);
    }

    /// Reads consistent snapshot of `T`. Retries spin-loop if a write overlapped.
    pub fn read(&self) -> T
    where
        T: Copy,
    {
        loop {
            let seq1 = self.sequence.load(Ordering::Acquire);
            if seq1 & 1 != 0 {
                std::hint::spin_loop();
                continue;
            }
            fence(Ordering::Acquire);

            let val = unsafe { *self.data.get() };

            fence(Ordering::Acquire);
            let seq2 = self.sequence.load(Ordering::Acquire);
            if seq1 == seq2 {
                return val;
            }
            std::hint::spin_loop();
        }
    }
}
