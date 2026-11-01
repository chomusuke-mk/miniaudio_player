//! Tripartite Buffer, ByteSource Abstraction, and Structural Edge-Case Fixture Tests.

mod common;

use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::mpsc::channel;
use std::thread;
use std::time::Duration;

use common::FixtureResolver;
use miniaudio_player::buffer::{
    BufferError, BufferStreamReader, ByteSource, ByteSourceStream, CustomDartByteSource,
    DartReadRequest, FileByteSource, MemoryByteSource, SourceKind, TripartiteBuffer,
    TripartiteByteSource,
};
use miniaudio_player::decoder::sniffer::{BoundaryStatus, ContainerFormat, FormatSniffer};
use miniaudio_player::decoder::symphonia_engine::SymphoniaEngine;
use symphonia::core::io::MediaSource;

#[test]
fn test_pinned_head_read() {
    let buffer = TripartiteBuffer::new(1024 * 1024, Some(5000), false);
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
    let buffer = TripartiteBuffer::new(capacity, Some(10000), false);
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
    let buffer = TripartiteBuffer::new(1024, Some(1000), false);
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
    let buffer = TripartiteBuffer::new(1024, Some(10000), false);
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
    let buffer = TripartiteBuffer::new(1024, Some(100), false);
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
fn test_buffer_stream_reader_preserves_eof_on_read() {
    let buffer = TripartiteBuffer::new(1024, Some(16), false);
    buffer.set_audio_start(0);
    buffer.feed_chunk(b"0123456789ABCDEF").unwrap();
    buffer.mark_eof();

    let mut reader = BufferStreamReader::new(buffer.clone());
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
    let buffer = TripartiteBuffer::new(capacity, Some(1000), false);
    buffer.set_audio_start(0);

    let chunk = vec![0xAA; 40];
    buffer.feed_chunk(&chunk).unwrap();

    let chunk2 = vec![0xBB; 40];
    let res = buffer.feed_chunk(&chunk2);
    assert_eq!(res, Err(BufferError::Busy));

    buffer.seek(30).unwrap();
    let res2 = buffer.feed_chunk(&chunk2);
    assert!(res2.is_ok());
}

#[test]
fn test_flush_and_cached_seek() {
    let buffer = TripartiteBuffer::new(1024, Some(5000), false);
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
fn test_tripartite_and_custom_dart_byte_sources() {
    let trip = TripartiteBuffer::new(4096, Some(8192), false);
    trip.set_head(b"HEADER_PREFIX");
    trip.set_audio_start(13);
    trip.feed_chunk(b"_AUDIO_PAYLOAD_CHUNK").unwrap();

    let mut source = TripartiteByteSource::new(trip);
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
        b"INITIAL_BYTES".to_vec(),
        request_sender,
    );

    let mut init_out = [0u8; 13];
    assert_eq!(custom_src.read(&mut init_out).unwrap(), 13);
    assert_eq!(&init_out, b"INITIAL_BYTES");

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
fn test_tripartite_edge_case_fixtures_from_manifest() {
    // 1. Giant Cover MP3 (> 350 KB ID3v2 APIC)
    let giant_mp3 = std::fs::read(FixtureResolver::resolve("tripartite/giant_cover.mp3")).unwrap();
    let (status_partial, info_partial) =
        FormatSniffer::detect_head_boundary(&giant_mp3[..64], giant_mp3.len() as i64);
    assert_eq!(status_partial, BoundaryStatus::NeedMore);
    assert!(info_partial.needed_bytes > 350_000);

    let (status_full, info_full) =
        FormatSniffer::detect_head_boundary(&giant_mp3, giant_mp3.len() as i64);
    assert_eq!(status_full, BoundaryStatus::Found);
    assert_eq!(info_full.container, ContainerFormat::Mp3);
    assert!(info_full.audio_start > 350_000);

    // 2. Giant Cover FLAC (> 300 KB PICTURE block)
    let giant_flac = std::fs::read(FixtureResolver::resolve("tripartite/giant_cover.flac")).unwrap();
    let (f_status, f_info) = FormatSniffer::detect_head_boundary(&giant_flac, giant_flac.len() as i64);
    assert_eq!(f_status, BoundaryStatus::Found);
    assert_eq!(f_info.container, ContainerFormat::Flac);
    assert!(f_info.audio_start > 300_000);

    // 3. EOF Chirp MP3 (Trailing APEv2 + ID3v1 with fake syncwords)
    let eof_mp3 = std::fs::read(FixtureResolver::resolve("tripartite/eof_chirp.mp3")).unwrap();
    let total_len = eof_mp3.len() as i64;
    let tail_slice = &eof_mp3[eof_mp3.len() - 4096..];
    let (t_status, audio_end) = FormatSniffer::detect_tail_boundary(
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
    let (w_status, w_info) = FormatSniffer::detect_head_boundary(&wav_trailing[..128], wav_trailing.len() as i64);
    assert_eq!(w_status, BoundaryStatus::Found);
    assert_eq!(w_info.container, ContainerFormat::Wav);
    assert!(w_info.audio_end < wav_trailing.len() as i64);
}
