//! Strict Concurrency & Lock-Free Synchronization Test Suite.
//!
//! Validates:
//! - Wait-free SPSC `AudioRingBuffer` under simultaneous barrier-synchronized contention.
//! - `CachePaddedSeqlock` tear-free concurrent writes and multi-threaded reads.
//! - `TelemetryDispatcher` concurrent multi-producer event dispatch and ring arena polling.
//! - `CaptureReceiver` lock-free real-time PCM frame transfer.
//! - `StreamSession` concurrent producer feeding and consumer reading.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::Duration;

use miniaudio_player::bridge::ffi::PcmCaptureHeader;
use miniaudio_player::buffer::{BufferError, StreamSession};
use miniaudio_player::core::capture::{
    capture_receiver_capture_trampoline, capture_receiver_notif_trampoline, CaptureReceiver,
};
use miniaudio_player::sync::{
    AudioRingBuffer, CachePaddedSeqlock, TelemetryDispatcher, TelemetryEvent,
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

    CALL_COUNT.store(0, Ordering::SeqCst);
    let dispatcher = Arc::new(TelemetryDispatcher::new());
    dispatcher.set_typed_callback(Some(Box::new(|_ev| {
        CALL_COUNT.fetch_add(1, Ordering::SeqCst);
    })));

    let num_producers = 4;
    let events_per_producer = 50;
    let expected_total = num_producers * events_per_producer;
    let barrier = Arc::new(Barrier::new(num_producers));
    let mut handles = Vec::new();

    for p in 0..num_producers {
        let disp = Arc::clone(&dispatcher);
        let b = Arc::clone(&barrier);
        handles.push(thread::spawn(move || {
            b.wait();
            for i in 0..events_per_producer {
                disp.post(TelemetryEvent::Duration(((p * 100 + i) * 10) as i64));
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    for _ in 0..40 {
        if CALL_COUNT.load(Ordering::SeqCst) >= expected_total {
            break;
        }
        thread::sleep(Duration::from_millis(25));
    }

    assert_eq!(CALL_COUNT.load(Ordering::SeqCst), expected_total);
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
    receiver.on_captured_pcm(&input_samples);

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
fn test_stream_session_concurrent_feed_and_read() {
    let total_bytes = 64 * 1024usize;
    let buffer = StreamSession::new(4096, Some(total_bytes as u64), false);
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

#[test]
fn test_wasm_net_protocol_ring_math_control_block_and_header_wire() {
    use miniaudio_player::net::wasm_ureq_protocol::*;

    assert_eq!(ring_available(0, 0), 0);
    assert_eq!(ring_available(1024, 0), 1024);

    let near_end = RING_MOD - 512;
    let wrapped_w = advance_ring_pos(near_end, 1536);
    assert_eq!(wrapped_w, 1024);
    assert_eq!(ring_available(wrapped_w, near_end), 1536);

    let full_w = advance_ring_pos(1234, RING_CAP);
    assert_eq!(ring_available(full_w, 1234), RING_CAP);

    let shared = WasmStreamShared::new(7);
    assert_eq!(shared.id, 7);
    assert_ne!(shared.ctrl_ptr(), 0);
    assert_ne!(shared.ring_ptr(), 0);
    assert_ne!(shared.hdr_ptr(), 0);
    assert_eq!(shared.ctrl[CTRL_STATE].load(Ordering::Relaxed), STATE_CONNECTING);
    assert_eq!(shared.ctrl[CTRL_STATUS].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_WRITE_POS].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_READ_POS].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_WAKE_RUST].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_WAKE_JS].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_ABORTED].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_HDR_LEN].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_JS_EXITED].load(Ordering::Relaxed), 0);
    assert_eq!(shared.ctrl[CTRL_JS_WAIT_FALLBACK].load(Ordering::Relaxed), 0);
    assert_ne!(STATE_HEADERS_READY, STATE_EOF);
    assert_ne!(STATE_EOF, STATE_ERROR);

    let wire = b"Content-Type\0audio/mpeg\nICY-MetaInt\0 16000 \n\nbadline\n\0emptykey\n";
    let headers = decode_header_wire_bytes(wire);
    assert_eq!(
        headers,
        vec![
            ("content-type".to_string(), "audio/mpeg".to_string()),
            ("icy-metaint".to_string(), "16000".to_string()),
        ]
    );
}

#[test]
fn test_dart_resolve_registry_success_cancellation_and_bounded_fd_slice() {
    use miniaudio_player::api::types::RustResolvedSource;
    use miniaudio_player::buffer::{
        DartResolveRegistry, FileByteSource, ResolvedCoreSource,
    };
    use miniaudio_player::core::dual_source::MAP_ERROR_ABORTED;
    use miniaudio_player::sync::CancelToken;
    use std::io::{Read, Seek, SeekFrom};
    use std::sync::{Arc, Mutex};
    use std::thread;

    let issued_reqs = Arc::new(Mutex::new(Vec::new()));
    let issued_clone = issued_reqs.clone();
    let registry = Arc::new(DartResolveRegistry::new(Arc::new(move |req| {
        issued_clone.lock().unwrap().push(req);
    })));

    // 1. Happy-path async response wakes waiter cleanly.
    let reg_worker = registry.clone();
    let jh = thread::spawn(move || {
        reg_worker.resolve("asset://assets/music/#song.opus", None, None)
    });
    let req_id = loop {
        if let Some(req) = issued_reqs.lock().unwrap().pop() {
            assert_eq!(req.source, "asset://assets/music/#song.opus");
            break req.request_id;
        }
        thread::yield_now();
    };
    assert!(registry.resolve_request(
        req_id,
        RustResolvedSource::Bytes {
            data: vec![1, 2, 3, 4],
            hint_ext: Some("opus".to_string()),
        },
    ));
    match jh.join().unwrap().unwrap() {
        ResolvedCoreSource::Bytes { data, hint_ext } => {
            assert_eq!(data, vec![1, 2, 3, 4]);
            assert_eq!(hint_ext.as_deref(), Some("opus"));
        }
        other => panic!("Unexpected resolved variant: {:?}", other),
    }

    // 2. Bounded FileByteSource slicing prevents out-of-range reads (APK resource offsets).
    let tmp = std::env::temp_dir().join(format!("map_fd_slice_test_{}.bin", std::process::id()));
    let mut blob = Vec::new();
    blob.extend_from_slice(b"PREFIX_GARBAGE_0000");
    let slice_offset = blob.len() as u64;
    let payload = b"SLICE_PAYLOAD_DATA";
    blob.extend_from_slice(payload);
    blob.extend_from_slice(b"SUFFIX_NEXT_ZIP_ENTRY");
    std::fs::write(&tmp, &blob).unwrap();

    let file = std::fs::File::open(&tmp).unwrap();
    let mut sliced = FileByteSource::from_file_slice_with_len(
        file,
        slice_offset,
        payload.len() as u64,
    )
    .unwrap();
    let mut read_back = Vec::new();
    sliced.read_to_end(&mut read_back).unwrap();
    assert_eq!(read_back.as_slice(), payload);
    assert_eq!(sliced.seek(SeekFrom::End(-4)).unwrap(), (payload.len() - 4) as u64);
    let mut tail = [0u8; 16];
    let n = sliced.read(&mut tail).unwrap();
    assert_eq!(&tail[..n], b"DATA");

    // 3. Unix: cancelling a pending resolve before Dart replies with `Fd` must close the late FD.
    #[cfg(unix)]
    {
        use std::os::unix::io::IntoRawFd;
        let cancel = CancelToken::new();
        let reg_cancel = registry.clone();
        let cancel_clone = cancel.clone();
        let wait_handle = thread::spawn(move || {
            reg_cancel.resolve("content://media/external/audio/media/999", None, Some(&cancel_clone))
        });

        let late_req_id = loop {
            if let Some(req) = issued_reqs.lock().unwrap().pop() {
                break req.request_id;
            }
            thread::yield_now();
        };
        cancel.cancel();
        let err = wait_handle.join().unwrap().unwrap_err();
        assert_eq!(err.code, MAP_ERROR_ABORTED);

        let fd = std::fs::File::open(&tmp).unwrap().into_raw_fd();
        // Delivering a late FD after request cancellation returns false and closes `fd` via RAII.
        let delivered = registry.resolve_request(
            late_req_id,
            RustResolvedSource::Fd {
                fd,
                offset: 0,
                length: None,
                hint_ext: None,
            },
        );
        assert!(!delivered);

        #[cfg(target_os = "linux")]
        assert!(
            !std::path::Path::new(&format!("/proc/self/fd/{}", fd)).exists(),
            "Detached late FD {} leaked after cancelled resolve_request!",
            fd
        );
    }

    let _ = std::fs::remove_file(&tmp);
}

#[test]
fn test_open_memory_owned_with_hint_decodes_seeks_and_releases_cleanly() {
    use miniaudio_player::core::dual_source::StreamingDeck;
    use std::path::PathBuf;

    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("example/assets/music/cbr_noxing.mp3");
    let owned_bytes = std::fs::read(&path).expect("cbr_noxing.mp3 fixture must exist");
    assert!(!owned_bytes.is_empty());

    let mut deck = StreamingDeck::new_analysis_deck(44100, 2).expect("analysis deck");
    let res = deck.open_memory_owned_with_hint(owned_bytes, Some("mp3"));
    assert_eq!(res, 0, "open_memory_owned_with_hint should open owned bytes");

    let mut pcm = Vec::new();
    let has_audio = deck
        .decode_next_analysis_frame(&mut pcm)
        .expect("decode_next_analysis_frame should succeed");
    assert!(has_audio && !pcm.is_empty());

    let _ = deck.stop();
    drop(deck);
}
