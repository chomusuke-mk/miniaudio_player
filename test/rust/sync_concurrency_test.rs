//! Strict Concurrency & Lock-Free Synchronization Test Suite.
//!
//! Validates:
//! - Wait-free SPSC `AudioRingBuffer` under simultaneous barrier-synchronized contention.
//! - `CachePaddedSeqlock` tear-free concurrent writes and multi-threaded reads.
//! - `TelemetryDispatcher` concurrent multi-producer event dispatch and ring arena polling.
//! - `CaptureReceiver` lock-free real-time PCM frame transfer.
//! - `TripartiteBuffer` concurrent producer feeding and consumer reading.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

use miniaudio_player::bridge::ffi::PcmCaptureHeader;
use miniaudio_player::buffer::{BufferError, TripartiteBuffer};
use miniaudio_player::core::capture::{
    capture_receiver_capture_trampoline, capture_receiver_notif_trampoline, CaptureReceiver,
};
use miniaudio_player::sync::{
    AudioRingBuffer, CachePaddedSeqlock, EventCallback, MapEvent, MapEventData,
    TelemetryDispatcher,
};

#[test]
fn test_ring_buffer_spsc_transfer() {
    let (mut producer, mut consumer) = AudioRingBuffer::create(1024);
    assert_eq!(consumer.samples_available(), 0);
    assert!(consumer.is_empty());

    let input_data: Vec<f32> = (0..500).map(|i| i as f32).collect();
    let written = producer.write_chunk(&input_data);
    assert_eq!(written, 500);
    assert_eq!(consumer.samples_available(), 500);
    assert!(!consumer.is_empty());

    let mut output_data = vec![0.0f32; 500];
    let read = consumer.read_chunk(&mut output_data);
    assert_eq!(read, 500);
    assert_eq!(output_data, input_data);
    assert_eq!(consumer.samples_available(), 0);
}

#[test]
fn test_ring_buffer_barrier_synchronized_concurrent_threads() {
    let (mut producer, mut consumer) = AudioRingBuffer::create(2048);
    let total_samples = 100_000usize;
    let barrier = Arc::new(Barrier::new(2));

    let b_prod = Arc::clone(&barrier);
    let h_producer = thread::spawn(move || {
        b_prod.wait();
        let mut count = 0;
        let mut buffer = [0.0f32; 128];
        while count < total_samples {
            let to_write = (total_samples - count).min(128);
            for (i, item) in buffer.iter_mut().enumerate().take(to_write) {
                *item = (count + i) as f32;
            }
            let written = producer.write_chunk(&buffer[..to_write]);
            count += written;
            if written == 0 {
                thread::yield_now();
            }
        }
    });

    let b_cons = Arc::clone(&barrier);
    let h_consumer = thread::spawn(move || {
        b_cons.wait();
        let mut count = 0;
        let mut buffer = [0.0f32; 128];
        while count < total_samples {
            let read = consumer.read_chunk(&mut buffer);
            for (i, &val) in buffer.iter().enumerate().take(read) {
                assert_eq!(val, (count + i) as f32, "Sample corruption at index {}", count + i);
            }
            count += read;
            if read == 0 {
                thread::yield_now();
            }
        }
    });

    h_producer.join().unwrap();
    h_consumer.join().unwrap();
}

#[derive(Default, Clone, Copy, Debug, PartialEq)]
struct PlayerTelemetrySnapshot {
    pub seq_id: u64,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub checksum: u64,
}

#[test]
fn test_seqlock_tear_free_multi_reader_concurrency() {
    let seqlock = Arc::new(CachePaddedSeqlock::new(PlayerTelemetrySnapshot {
        seq_id: 0,
        position_ms: 0,
        duration_ms: 100_000,
        checksum: 100_000,
    }));

    let stop = Arc::new(AtomicBool::new(false));
    let reader_threads = 4;
    let barrier = Arc::new(Barrier::new(reader_threads + 1));

    let seqlock_w = Arc::clone(&seqlock);
    let stop_w = Arc::clone(&stop);
    let b_writer = Arc::clone(&barrier);
    let writer = thread::spawn(move || {
        b_writer.wait();
        let mut seq = 1u64;
        while !stop_w.load(Ordering::Relaxed) {
            let pos = seq * 10;
            let dur = 100_000;
            let chk = seq ^ pos ^ dur;
            seqlock_w.write(|t| {
                t.seq_id = seq;
                t.position_ms = pos;
                t.duration_ms = dur;
                t.checksum = chk;
            });
            seq += 1;
        }
    });

    let mut readers = Vec::with_capacity(reader_threads);
    for _ in 0..reader_threads {
        let seqlock_r = Arc::clone(&seqlock);
        let b_reader = Arc::clone(&barrier);
        readers.push(thread::spawn(move || {
            b_reader.wait();
            for _ in 0..25_000 {
                let snap = seqlock_r.read();
                assert_eq!(snap.duration_ms, 100_000);
                if snap.seq_id > 0 {
                    assert_eq!(snap.position_ms, snap.seq_id * 10);
                    assert_eq!(
                        snap.checksum,
                        snap.seq_id ^ snap.position_ms ^ snap.duration_ms,
                        "Torn read detected in CachePaddedSeqlock!"
                    );
                }
            }
        }));
    }

    for r in readers {
        r.join().unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    writer.join().unwrap();
}

#[test]
fn test_telemetry_dispatcher_concurrent_multi_producer() {
    static CALL_COUNT: AtomicUsize = AtomicUsize::new(0);
    static LAST_EVENT_TYPE: AtomicI32 = AtomicI32::new(0);
    static RECEIVED_USER_DATA: AtomicUsize = AtomicUsize::new(0);

    unsafe extern "C" fn test_callback(user_data: *mut std::ffi::c_void, event: *const MapEvent) {
        CALL_COUNT.fetch_add(1, Ordering::SeqCst);
        unsafe {
            LAST_EVENT_TYPE.store((*event).event_type, Ordering::SeqCst);
        }
        RECEIVED_USER_DATA.store(user_data as usize, Ordering::SeqCst);
    }

    CALL_COUNT.store(0, Ordering::SeqCst);
    let dispatcher = Arc::new(TelemetryDispatcher::new(
        Some(test_callback as EventCallback),
        0xCAFE as *mut _,
    ));

    let num_producers = 4;
    let events_per_producer = 50;
    let barrier = Arc::new(Barrier::new(num_producers));
    let mut handles = Vec::new();

    for p in 0..num_producers {
        let disp = Arc::clone(&dispatcher);
        let b = Arc::clone(&barrier);
        handles.push(thread::spawn(move || {
            b.wait();
            for i in 0..events_per_producer {
                let event = MapEvent {
                    event_type: (p * 100 + i) as i32,
                    padding: 0,
                    timestamp_ns: 0,
                    data: MapEventData {
                        position_ms: (i * 10) as i64,
                    },
                };
                disp.dispatch(event);
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    thread::sleep(Duration::from_millis(50));
    assert_eq!(
        CALL_COUNT.load(Ordering::SeqCst),
        num_producers * events_per_producer
    );
    assert_eq!(RECEIVED_USER_DATA.load(Ordering::SeqCst), 0xCAFE);
}

#[test]
fn test_capture_receiver_transfers_frames_lock_free() {
    let (producer, mut consumer) = rtrb::RingBuffer::new(1024);
    let is_active = Arc::new(AtomicBool::new(true));

    let mut receiver = CaptureReceiver {
        header: PcmCaptureHeader {
            capture_fn: capture_receiver_capture_trampoline,
            notif_fn: capture_receiver_notif_trampoline,
        },
        producer,
        is_active,
        channels: 1,
    };

    let input_samples = [0.1f32, 0.2f32, 0.3f32, 0.4f32];
    receiver.on_captured_pcm(input_samples.as_ptr(), input_samples.len());

    assert_eq!(consumer.slots(), 4);
    let mut read_buf = [0.0f32; 4];
    if let Ok(chunk) = consumer.read_chunk(4) {
        let (s1, s2) = chunk.as_slices();
        read_buf[..s1.len()].copy_from_slice(s1);
        if !s2.is_empty() {
            read_buf[s1.len()..].copy_from_slice(s2);
        }
        chunk.commit_all();
    }

    assert_eq!(read_buf, input_samples);
}

#[test]
fn test_tripartite_buffer_concurrent_feed_and_read() {
    let total_bytes = 64 * 1024usize;
    let buffer = TripartiteBuffer::new(4096, Some(total_bytes as u64), false);
    buffer.set_audio_start(0);
    let barrier = Arc::new(Barrier::new(2));

    let buf_writer = buffer.clone();
    let b_writer = Arc::clone(&barrier);
    let writer = thread::spawn(move || {
        b_writer.wait();
        let mut written = 0usize;
        let mut chunk = [0u8; 256];
        while written < total_bytes {
            let n = (total_bytes - written).min(chunk.len());
            for (i, b) in chunk.iter_mut().enumerate().take(n) {
                *b = ((written + i) & 0xFF) as u8;
            }
            match buf_writer.feed_chunk(&chunk[..n]) {
                Ok(fed) => written += fed,
                Err(BufferError::Busy) => thread::yield_now(),
                Err(e) => panic!("Unexpected feed error: {:?}", e),
            }
        }
        buf_writer.mark_eof();
    });

    let buf_reader = buffer.clone();
    let b_reader = Arc::clone(&barrier);
    let reader = thread::spawn(move || {
        b_reader.wait();
        let mut cursor = 0usize;
        let mut out = [0u8; 192];
        while cursor < total_bytes {
            match buf_reader.read_at(cursor as u64, &mut out) {
                Ok(0) => break,
                Ok(n) => {
                    for (i, &b) in out.iter().enumerate().take(n) {
                        assert_eq!(
                            b,
                            ((cursor + i) & 0xFF) as u8,
                            "Byte mismatch at offset {}",
                            cursor + i
                        );
                    }
                    cursor += n;
                    buf_reader.advance_read_cursor(cursor as u64);
                }
                Err(BufferError::WouldBlock) => thread::yield_now(),
                Err(e) => panic!("Unexpected read error: {:?}", e),
            }
        }
        assert_eq!(cursor, total_bytes);
    });

    writer.join().unwrap();
    reader.join().unwrap();
}
