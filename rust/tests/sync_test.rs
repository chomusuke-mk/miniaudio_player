use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

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
fn test_ring_buffer_concurrent_threads() {
    let (mut producer, mut consumer) = AudioRingBuffer::create(4096);
    let total_samples = 50_000;

    let h_producer = thread::spawn(move || {
        let mut count = 0;
        let mut buffer = [0.0f32; 128];
        while count < total_samples {
            let to_write = (total_samples - count).min(128);
            for i in 0..to_write {
                buffer[i] = (count + i) as f32;
            }
            let written = producer.write_chunk(&buffer[..to_write]);
            count += written;
            if written == 0 {
                thread::yield_now();
            }
        }
    });

    let h_consumer = thread::spawn(move || {
        let mut count = 0;
        let mut buffer = [0.0f32; 128];
        while count < total_samples {
            let read = consumer.read_chunk(&mut buffer);
            for i in 0..read {
                assert_eq!(buffer[i], (count + i) as f32);
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
struct PlayerTelemetry {
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
}

#[test]
fn test_seqlock_concurrent_read_write() {
    let seqlock = Arc::new(CachePaddedSeqlock::new(PlayerTelemetry {
        position_ms: 0,
        duration_ms: 100_000,
        volume: 1.0,
    }));

    let stop = Arc::new(AtomicBool::new(false));

    let seqlock_w = Arc::clone(&seqlock);
    let stop_w = Arc::clone(&stop);
    let writer = thread::spawn(move || {
        let mut pos = 0;
        while !stop_w.load(Ordering::Relaxed) {
            seqlock_w.write(|t| {
                t.position_ms = pos;
                t.duration_ms = 100_000;
                t.volume = (pos % 100) as f32 / 100.0;
            });
            pos += 1;
        }
    });

    let seqlock_r = Arc::clone(&seqlock);
    let reader = thread::spawn(move || {
        for _ in 0..10_000 {
            let val = seqlock_r.read();
            assert_eq!(val.duration_ms, 100_000);
            assert!(val.volume >= 0.0 && val.volume <= 1.0);
        }
    });

    reader.join().unwrap();
    stop.store(true, Ordering::Relaxed);
    writer.join().unwrap();
}

#[test]
fn test_telemetry_dispatcher_callback() {
    static CALLED: AtomicBool = AtomicBool::new(false);
    static RECEIVED_EVENT_TYPE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
    static RECEIVED_USER_DATA: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    unsafe extern "C" fn test_callback(user_data: *mut std::ffi::c_void, event: *const MapEvent) {
        CALLED.store(true, Ordering::Relaxed);
        unsafe {
            RECEIVED_EVENT_TYPE.store((*event).event_type, Ordering::Relaxed);
        }
        RECEIVED_USER_DATA.store(user_data as usize, Ordering::Relaxed);
    }

    let dispatcher = TelemetryDispatcher::new(Some(test_callback as EventCallback), 0x1234 as *mut _);

    let event = MapEvent {
        event_type: 42,
        padding: 0,
        timestamp_ns: 0,
        data: MapEventData {
            position_ms: 12345,
        },
    };

    dispatcher.dispatch(event);

    // Give the telemetry worker thread a moment to deliver the event
    std::thread::sleep(Duration::from_millis(50));

    assert!(CALLED.load(Ordering::Relaxed));
    assert_eq!(RECEIVED_EVENT_TYPE.load(Ordering::Relaxed), 42);
    assert_eq!(RECEIVED_USER_DATA.load(Ordering::Relaxed), 0x1234);
}
