//! StreamSession, StreamBuffer, ByteSource Abstraction, and Structural Edge-Case Fixture Tests.

mod common;

use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::channel;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use common::FixtureResolver;
use miniaudio_player::buffer::{
    BlockFetchPhase, BufferError, ByteSource, ByteSourceStream, CustomDartByteSource,
    DartReadRequest, DemuxedStreamReader, FileByteSource, MemoryByteSource, MetadataStreamReader,
    SlidingWindowConfig, SourceKind, StreamBuffer, StreamByteSource, StreamSession,
};
use miniaudio_player::decoder::classifier::{BoundaryStatus, ContainerFormat, StreamClassifier};
use miniaudio_player::decoder::symphonia_engine::SymphoniaEngine;
use symphonia::core::io::MediaSource;

#[test]
fn test_pinned_head_read() {
    let buffer = StreamSession::new(1024 * 1024, Some(5000), false);
    let head = b"ID3\x03\x00\x00\x00\x00\x00\x0aHEADERDATA";
    buffer.set_head(head);
    buffer.set_audio_start(head.len() as u64);

    let mut out = [0u8; 10];
    let bytes_read = buffer.read_at(0, &mut out).expect("read should succeed");
    assert_eq!(bytes_read, 10);
    assert_eq!(&out, b"ID3\x03\x00\x00\x00\x00\x00\x0a");

    let mut out2 = [0u8; 10];
    let bytes_read2 = buffer.read_at(10, &mut out2).expect("read should succeed");
    assert_eq!(bytes_read2, 10);
    assert_eq!(&out2, b"HEADERDATA");
}

#[test]
fn test_pure_audio_ring_feed_and_read() {
    let capacity = 1024;
    let buffer = StreamSession::new(capacity, Some(10000), false);
    buffer.set_audio_start(0);

    let chunk = b"AUDIO_CHUNK_0123456789";
    let fed = buffer.feed_chunk(chunk).expect("feed should succeed");
    assert_eq!(fed, chunk.len());

    let mut out = [0u8; 22];
    let read = buffer.read_at(0, &mut out).expect("read should succeed");
    assert_eq!(read, chunk.len());
    assert_eq!(&out, chunk);
}

#[test]
fn test_deterministic_write_at_offset_zero_and_arbitrary() {
    let buffer = StreamSession::new(1024, Some(1000), false);
    buffer.set_audio_start(0);

    // Deterministic write_at at offset 0
    let written = buffer.write_at(0, b"HELLO_WORLD").expect("write_at(0) failed");
    assert_eq!(written, 11);

    let mut out = [0u8; 11];
    assert_eq!(buffer.read_at(0, &mut out).unwrap(), 11);
    assert_eq!(&out, b"HELLO_WORLD");

    // Overwrite slice in-place at offset 6
    let written2 = buffer.write_at(6, b"RUST!").expect("write_at(6) failed");
    assert_eq!(written2, 5);
    assert_eq!(buffer.read_at(0, &mut out).unwrap(), 11);
    assert_eq!(&out, b"HELLO_RUST!");
}

#[test]
fn test_contiguous_spanning_read_head_into_ring() {
    let buffer = StreamSession::new(1024, Some(10000), false);
    let head = b"HEAD";
    buffer.set_head(head);
    buffer.set_audio_start(4);

    let audio = b"AUDIO_DATA";
    buffer.feed_chunk(audio).expect("feed should succeed");

    let mut out = [0u8; 14];
    let read = buffer.read_at(0, &mut out).expect("spanning read should succeed");
    assert_eq!(read, 14);
    assert_eq!(&out, b"HEADAUDIO_DATA");
}

#[test]
fn test_tail_buffer_and_audio_eof_protection() {
    let buffer = StreamSession::new(1024, Some(100), false);
    buffer.set_audio_start(0);
    buffer.set_audio_end(50);

    let tail = b"TRAILING_TAGS";
    buffer.set_tail(tail, Some(50));

    let mut out = [0u8; 13];
    let read_tail = buffer.read_at(50, &mut out).expect("read tail should succeed");
    assert_eq!(read_tail, 13);
    assert_eq!(&out, b"TRAILING_TAGS");

    buffer.set_decoding_audio(true);
    let read_eof = buffer.read_at(50, &mut out).expect("read should return EOF");
    assert_eq!(read_eof, 0);
}

#[test]
fn test_demuxed_stream_reader_preserves_eof_on_read() {
    let buffer = StreamSession::new(1024, Some(16), false);
    buffer.set_audio_start(0);
    buffer.feed_chunk(b"0123456789ABCDEF").unwrap();
    buffer.mark_eof();

    let mut reader = DemuxedStreamReader::new(buffer.clone());
    assert!(reader.is_seekable());
    assert_eq!(reader.byte_len(), Some(16));

    let mut out = [0u8; 10];
    let n = reader.read(&mut out).unwrap();
    assert_eq!(n, 10);
    assert_eq!(&out, b"0123456789");
    assert_eq!(reader.cursor(), 10);

    // Remaining 6 bytes should read and then return clean 0-byte EOF without blocking
    let mut rest = [0u8; 10];
    let n2 = reader.read(&mut rest).unwrap();
    assert_eq!(n2, 6);
    assert_eq!(&rest[..6], b"ABCDEF");

    let n_eof = reader.read(&mut rest).unwrap();
    assert_eq!(n_eof, 0, "Reader must preserve EOF state across reads");

    reader.seek(SeekFrom::Start(4)).unwrap();
    assert_eq!(reader.cursor(), 4);

    let mut out2 = [0u8; 4];
    reader.read_exact(&mut out2).unwrap();
    assert_eq!(&out2, b"4567");

    reader.seek(SeekFrom::Current(2)).unwrap();
    assert_eq!(reader.cursor(), 10);
}

#[test]
fn test_backpressure_busy() {
    let capacity = 64;
    let buffer = StreamSession::new(capacity, Some(1000), false);
    buffer.set_audio_start(0);

    let chunk = vec![0xAA; 40];
    buffer.feed_chunk(&chunk).unwrap();

    let chunk2 = vec![0xBB; 40];
    let res = buffer.feed_chunk(&chunk2);
    assert_eq!(res, Err(BufferError::Busy));

    // Reactive wait_for_free_space wakes immediately when consumer advances read cursor
    let consumer_buf = buffer.clone();
    let handle = thread::spawn(move || {
        // Intentional minimal delay so waiter parks on Condvar before cursor advances.
        thread::sleep(Duration::from_millis(5));
        consumer_buf.advance_read_cursor(30);
    });
    assert!(buffer.wait_for_free_space(40, Duration::from_millis(500)));
    handle.join().unwrap();

    let res2 = buffer.feed_chunk(&chunk2);
    assert!(res2.is_ok());
}

#[test]
fn test_flush_and_cached_seek() {
    let buffer = StreamSession::new(1024, Some(5000), false);
    buffer.set_audio_start(0);
    buffer.feed_chunk(b"INITIAL_DATA_FOR_BUFFER").unwrap();

    let (is_hit, contiguous) = buffer.try_seek_cached(5);
    assert!(is_hit);
    assert!(contiguous);

    let (is_miss, _) = buffer.try_seek_cached(2000);
    assert!(!is_miss);

    buffer.flush(2000);
    let range = buffer.get_range();
    assert_eq!(range.start_byte, 2000);
    assert_eq!(range.end_byte, 2000);
    assert_eq!(range.read_cursor_byte, 2000);
    assert_eq!(range.is_buffering, 1);
}

#[test]
fn test_stream_buffer_linear_sparse_and_circular_real_bytes() {
    // 1. Linear StreamBuffer (head) with initial_capacity and min_growth
    let head_buf = StreamBuffer::new_linear(16, 32);
    head_buf.commit_chunk(0, b"0123456789ABCDEF").unwrap();
    head_buf.commit_chunk(16, b"GHIJKL").unwrap();
    assert_eq!(head_buf.linear_len(), 22);
    let mut l_out = [0u8; 6];
    assert_eq!(head_buf.read_at(16, &mut l_out).unwrap(), 6);
    assert_eq!(&l_out, b"GHIJKL");

    // 2. Sparse StreamBuffer (metadata) with chunk coalescing and null/WouldBlock on unbuffered seek
    let meta_buf = StreamBuffer::new_sparse(64, 64, Some(1000));
    meta_buf.commit_chunk(0, b"HEAD_META_").unwrap();
    meta_buf.commit_chunk(10, b"CONTIGUOUS").unwrap();
    meta_buf.commit_chunk(900, b"TAIL_TAG").unwrap();

    let mut m_reader = MetadataStreamReader::new(meta_buf.clone());
    let mut m_out = [0u8; 20];
    assert_eq!(m_reader.read(&mut m_out).unwrap(), 20);
    assert_eq!(&m_out, b"HEAD_META_CONTIGUOUS");

    // Seek to unbuffered middle offset 500 -> returns UnexpectedEof immediately (no network stall)
    m_reader.seek(SeekFrom::Start(500)).unwrap();
    let mut m_miss = [0u8; 8];
    assert_eq!(
        m_reader.read(&mut m_miss).unwrap_err().kind(),
        std::io::ErrorKind::UnexpectedEof
    );

    // Seek to buffered tail offset 900 -> succeeds
    m_reader.seek(SeekFrom::Start(900)).unwrap();
    assert_eq!(m_reader.read(&mut m_miss).unwrap(), 8);
    assert_eq!(&m_miss, b"TAIL_TAG");

    // 3. Circular StreamBuffer (body) with getRealBytes (ByteFetchTask) and watermark prefetch
    let fetch_calls = Arc::new(AtomicUsize::new(0));
    let fetch_calls_clone = fetch_calls.clone();
    let backing_store: Arc<Vec<u8>> = Arc::new((0..1024usize).map(|i| (i & 0xFF) as u8).collect());
    let store_clone = backing_store.clone();

    let fetcher = Arc::new(move |pos: u64, size: usize| -> std::io::Result<Vec<u8>> {
        fetch_calls_clone.fetch_add(1, Ordering::SeqCst);
        let start = (pos as usize).min(store_clone.len());
        let end = (start + size).min(store_clone.len());
        Ok(store_clone[start..end].to_vec())
    });

    let body_buf = StreamBuffer::new_circular(128, SlidingWindowConfig::default(), Some(fetcher));
    // Cache miss at offset 200 triggers Phase 1 UrgentBootstrap getRealBytes
    let mut c_out = [0u8; 32];
    let n = body_buf.read_at(200, &mut c_out).unwrap();
    assert_eq!(n, 32);
    assert_eq!(c_out[0], (200 & 0xFF) as u8);
    assert_eq!(fetch_calls.load(Ordering::SeqCst), 1);

    // Subsequent read triggers proactive Phase 2 Stabilization block fetch
    let mut c_out2 = [0u8; 40];
    let n2 = body_buf.read_at(205, &mut c_out2).unwrap();
    assert_eq!(n2, 32);
    assert!(fetch_calls.load(Ordering::SeqCst) >= 2);
}

#[test]
fn test_sliding_window_progressive_block_coalescing_and_eof() {
    // 10s back (10_000 B), 30s ahead (30_000 B), 5s base window (5_000 B), 3 windows coalesce (15_000 B)
    // Total stream size = 57_000 B (57s), ring capacity = 64_000 B
    let cfg = SlidingWindowConfig {
        back_duration_ms: 10_000,
        ahead_duration_ms: 30_000,
        window_duration_ms: 5_000,
        coalesce_windows: 3,
    };
    let session = StreamSession::with_config(64_000, Some(57_000), false, cfg, None);
    session.set_audio_start(0);
    session.configure_sliding_window(cfg, 1000, 1.0);

    // Phase 1 (UrgentBootstrap): ahead = 0 -> requests 1 window (5_000 B = 5s)
    let order1 = session.next_block_request().expect("Phase 1 order expected");
    assert_eq!(order1.phase, BlockFetchPhase::UrgentBootstrap);
    assert_eq!(order1.offset, 0);
    assert_eq!(order1.length, 5_000);
    assert!(!order1.reaches_eof);
    session.feed_chunk(&vec![0x11; order1.length]).unwrap();

    // Phase 2 (Stabilization): ahead = 5_000 B (1 window) -> requests 1 window (5_000 B = 5s)
    let order2 = session.next_block_request().expect("Phase 2 first order expected");
    assert_eq!(order2.phase, BlockFetchPhase::Stabilization);
    assert_eq!(order2.offset, 5_000);
    assert_eq!(order2.length, 5_000);
    session.feed_chunk(&vec![0x22; order2.length]).unwrap();

    // Phase 2 (Stabilization): ahead = 10_000 B (2 windows) -> requests 1 window (5_000 B = 5s)
    let order3 = session.next_block_request().expect("Phase 2 second order expected");
    assert_eq!(order3.phase, BlockFetchPhase::Stabilization);
    assert_eq!(order3.offset, 10_000);
    assert_eq!(order3.length, 5_000);
    session.feed_chunk(&vec![0x33; order3.length]).unwrap();

    // Phase 3 (CoalescedCruise): ahead = 15_000 B (3 windows reached!) -> requests coalesced 15_000 B (15s)
    let order4 = session.next_block_request().expect("Phase 3 coalesced order expected");
    assert_eq!(order4.phase, BlockFetchPhase::CoalescedCruise);
    assert_eq!(order4.offset, 15_000);
    assert_eq!(order4.length, 15_000);
    session.feed_chunk(&vec![0x44; order4.length]).unwrap();

    // Forward window is now full (ahead = 30_000 B = 30s). If paused or at 0s, zero requests are made.
    assert_eq!(session.ahead_bytes(), 30_000);
    assert!(session.next_block_request().is_none());

    // Advance playback from 1s to 14s: ahead drops from 29_000 to 16_000 -> hysteresis holds (no tiny requests)
    for sec in 1..=14 {
        session.advance_read_cursor(sec * 1000);
        assert!(
            session.next_block_request().is_none(),
            "Must not request miniature blocks at {}s (ahead={} B)",
            sec,
            session.ahead_bytes()
        );
    }

    // At 15s (cursor = 15_000 B), ahead is 15_000 B (deficit = 15_000 B == 3 windows) -> triggers 15s super-block
    session.advance_read_cursor(15_000);
    assert_eq!(session.back_buffered_bytes(), 15_000);
    let order5 = session
        .next_block_request()
        .expect("Phase 3 refill expected at 15s");
    assert_eq!(order5.phase, BlockFetchPhase::CoalescedCruise);
    assert_eq!(order5.offset, 30_000);
    assert_eq!(order5.length, 15_000);
    assert!(!order5.reaches_eof);
    session.feed_chunk(&vec![0x55; order5.length]).unwrap();
    assert_eq!(session.ahead_bytes(), 30_000);

    // Advance cursor to 25_000 B: back retention protects [15_000 .. 25_000] (10s behind cursor)
    session.advance_read_cursor(25_000);
    let (hit, _) = session.try_seek_cached(16_000);
    assert!(hit, "Backward 10s window [15_000..25_000] must be cached in RAM");
    session.advance_read_cursor(25_000);

    // Advance cursor to 30_000 B: ahead is 15_000 B (range_end = 45_000 B), remaining to EOF (57_000 B) is 12_000 B (< 15_000 B)
    session.advance_read_cursor(30_000);
    let order_eof = session
        .next_block_request()
        .expect("Final EOF-clamped block expected");
    assert_eq!(order_eof.phase, BlockFetchPhase::CoalescedCruise);
    assert_eq!(order_eof.offset, 45_000);
    assert_eq!(order_eof.length, 12_000);
    assert!(order_eof.reaches_eof);

    session.feed_chunk(&vec![0x66; order_eof.length]).unwrap();
    assert!(session.is_eof(), "Buffer must automatically mark EOF at audio_end");
    assert!(session.next_block_request().is_none());
}

#[test]
fn test_sliding_window_rate_scaling_and_live_edge() {
    let cfg = SlidingWindowConfig::default();
    let live_session = StreamSession::with_config(512_000, None, true, cfg, None);
    live_session.set_audio_start(0);
    live_session.configure_sliding_window(cfg, 1000, 1.0);

    let state_1x = live_session.body.sliding_window_state().unwrap();
    assert_eq!(state_1x.back_retention_bytes, 10_000);
    assert_eq!(state_1x.ahead_target_bytes, 30_000);
    assert_eq!(state_1x.base_window_bytes, 5_000);

    // At 3.0x playback speed, forward target and base window scale by 3x
    live_session.set_playback_rate(3.0);
    let state_3x = live_session.body.sliding_window_state().unwrap();
    assert_eq!(state_3x.back_retention_bytes, 10_000);
    assert_eq!(state_3x.ahead_target_bytes, 90_000);
    assert_eq!(state_3x.base_window_bytes, 15_000);

    // At 0.25x playback speed, block sizes do not shrink below 1.0x
    live_session.set_playback_rate(0.25);
    let state_025x = live_session.body.sliding_window_state().unwrap();
    assert_eq!(state_025x.ahead_target_bytes, 30_000);
    assert_eq!(state_025x.base_window_bytes, 5_000);

    // Live-edge detection: true when ahead <= 1 base window (5_000 B), false when time-shift accumulated
    live_session.feed_chunk(&vec![0xAA; 3_000]).unwrap();
    assert!(live_session.is_at_live_edge());

    live_session.feed_chunk(&vec![0xBB; 15_000]).unwrap();
    assert!(!live_session.is_at_live_edge());
}

#[test]
fn test_memory_and_file_byte_sources() {
    let data = b"Hello, World! Symphonia ByteSource Test.".to_vec();
    let mut source = MemoryByteSource::new(data.clone());

    assert_eq!(source.total_bytes(), Some(data.len() as u64));
    assert!(ByteSource::is_seekable(&source));
    assert_eq!(source.source_kind(), SourceKind::Memory);

    let mut buf = [0u8; 5];
    assert_eq!(source.read(&mut buf).unwrap(), 5);
    assert_eq!(&buf, b"Hello");

    source.seek(SeekFrom::Start(7)).unwrap();
    let mut buf2 = [0u8; 5];
    assert_eq!(source.read(&mut buf2).unwrap(), 5);
    assert_eq!(&buf2, b"World");

    let tail = source.probe_tail((data.len() - 5) as u64, 5).unwrap();
    assert_eq!(&tail, b"Test.");

    let mut buf3 = [0u8; 1];
    assert_eq!(source.read(&mut buf3).unwrap(), 1);
    assert_eq!(&buf3, b"!");

    // FileByteSource using project-relative scratch directory
    let file_path = FixtureResolver::scratch_file_path("test_file_source.bin");
    let content = vec![0x42u8; 4096];
    {
        let mut file = std::fs::File::create(&file_path).unwrap();
        file.write_all(&content).unwrap();
    }

    let mut f_source = FileByteSource::open(&file_path).unwrap();
    assert_eq!(f_source.total_bytes(), Some(4096));
    assert!(ByteSource::is_seekable(&f_source));
    assert_eq!(f_source.source_kind(), SourceKind::File);

    let mut f_buf = [0u8; 100];
    assert_eq!(f_source.read(&mut f_buf).unwrap(), 100);
    assert_eq!(f_buf[0], 0x42);

    f_source.seek(SeekFrom::Start(2000)).unwrap();
    assert_eq!(f_source.read(&mut f_buf).unwrap(), 100);

    let _ = std::fs::remove_file(file_path);
}

#[test]
fn test_stream_and_custom_dart_byte_sources() {
    let session = StreamSession::new(4096, Some(8192), false);
    session.set_head(b"HEADER_PREFIX");
    session.set_audio_start(13);
    session.feed_chunk(b"_AUDIO_PAYLOAD_CHUNK").unwrap();

    let mut source = StreamByteSource::new(session);
    assert_eq!(source.total_bytes(), Some(8192));
    assert!(ByteSource::is_seekable(&source));
    assert_eq!(source.source_kind(), SourceKind::HttpVod);

    let mut buf = [0u8; 13];
    assert_eq!(source.read(&mut buf).unwrap(), 13);
    assert_eq!(&buf, b"HEADER_PREFIX");

    let mut buf2 = [0u8; 20];
    assert_eq!(source.read(&mut buf2).unwrap(), 20);
    assert_eq!(&buf2, b"_AUDIO_PAYLOAD_CHUNK");

    // CustomDartByteSource pull, seek, and error propagation
    let (tx, rx) = channel::<DartReadRequest>();
    let request_sender = std::sync::Arc::new(move |req: DartReadRequest| {
        tx.send(req).unwrap();
    });

    let (mut custom_src, handle) = CustomDartByteSource::new(
        42,
        Some(1000),
        true,
        request_sender,
    );

    let handle_clone = handle.clone();
    let rx_clone = rx;
    let dart_thread_1 = thread::spawn(move || {
        let req = rx_clone.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(req.stream_id, 42);
        assert_eq!(req.offset, 0);
        handle_clone.supply_bytes(req.request_id, b"INITIAL_BYTES".to_vec(), false);
        rx_clone
    });

    let mut init_out = [0u8; 13];
    assert_eq!(custom_src.read(&mut init_out).unwrap(), 13);
    assert_eq!(&init_out, b"INITIAL_BYTES");
    let rx = dart_thread_1.join().unwrap();

    custom_src.seek(SeekFrom::Start(500)).unwrap();
    let handle_clone = handle.clone();
    let dart_thread = thread::spawn(move || {
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(req.stream_id, 42);
        assert_eq!(req.offset, 500);
        handle_clone.supply_bytes(req.request_id, b"SEEK_DATA".to_vec(), false);
    });

    let mut seek_out = [0u8; 9];
    assert_eq!(custom_src.read(&mut seek_out).unwrap(), 9);
    assert_eq!(&seek_out, b"SEEK_DATA");
    dart_thread.join().unwrap();

    let memory = MemoryByteSource::new(b"STREAM_ADAPTER_TEST".to_vec());
    let mut adapter = ByteSourceStream(memory);
    assert!(adapter.is_seekable());
    assert_eq!(adapter.byte_len(), Some(19));
    let mut abuf = [0u8; 6];
    assert_eq!(adapter.read(&mut abuf).unwrap(), 6);
    assert_eq!(&abuf, b"STREAM");
}

#[test]
fn test_stream_session_edge_case_fixtures_from_manifest() {
    // 1. Giant Cover MP3 (> 350 KB ID3v2 APIC)
    let giant_mp3 = std::fs::read(FixtureResolver::resolve("tripartite/giant_cover.mp3")).unwrap();
    let (status_partial, info_partial) =
        StreamClassifier::detect_head_boundary(&giant_mp3[..64], giant_mp3.len() as i64);
    assert_eq!(status_partial, BoundaryStatus::NeedMore);
    assert!(info_partial.needed_bytes > 350_000);

    let (status_full, info_full) =
        StreamClassifier::detect_head_boundary(&giant_mp3, giant_mp3.len() as i64);
    assert_eq!(status_full, BoundaryStatus::Found);
    assert_eq!(info_full.container, ContainerFormat::Mp3);
    assert!(info_full.audio_start > 350_000);

    // 2. Giant Cover FLAC (> 300 KB PICTURE block)
    let giant_flac = std::fs::read(FixtureResolver::resolve("tripartite/giant_cover.flac")).unwrap();
    let (f_status, f_info) = StreamClassifier::detect_head_boundary(&giant_flac, giant_flac.len() as i64);
    assert_eq!(f_status, BoundaryStatus::Found);
    assert_eq!(f_info.container, ContainerFormat::Flac);
    assert!(f_info.audio_start > 300_000);

    // 3. EOF Chirp MP3 (Trailing APEv2 + ID3v1 with fake syncwords)
    let eof_mp3 = std::fs::read(FixtureResolver::resolve("tripartite/eof_chirp.mp3")).unwrap();
    let total_len = eof_mp3.len() as i64;
    let tail_slice = &eof_mp3[eof_mp3.len() - 4096..];
    let (t_status, audio_end) = StreamClassifier::detect_tail_boundary(
        ContainerFormat::Mp3,
        tail_slice,
        total_len - 4096,
        total_len,
        0,
    );
    assert_eq!(t_status, BoundaryStatus::Found);
    assert!(audio_end < total_len - 128);

    // 4. Non-Fast-Start M4A (moov at EOF)
    let nfs_path = FixtureResolver::resolve("tripartite/non_faststart.m4a");
    let nfs_file = std::fs::File::open(&nfs_path).unwrap();
    let mut nfs_engine = SymphoniaEngine::new(nfs_file, Some("m4a")).expect("Failed to open non_faststart.m4a");
    let mut pcm = Vec::new();
    assert!(nfs_engine.decode_next_frame(&mut pcm).unwrap());
    assert!(!pcm.is_empty());

    // 5. Trailing Chunks WAV (LIST/INFO after data)
    let wav_trailing = std::fs::read(FixtureResolver::resolve("tripartite/trailing_chunks.wav")).unwrap();
    let (w_status, w_info) = StreamClassifier::detect_head_boundary(&wav_trailing[..128], wav_trailing.len() as i64);
    assert_eq!(w_status, BoundaryStatus::Found);
    assert_eq!(w_info.container, ContainerFormat::Wav);
    assert!(w_info.audio_end < wav_trailing.len() as i64);
}

