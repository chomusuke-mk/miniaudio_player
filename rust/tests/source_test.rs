use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::mpsc::channel;
use std::thread;
use std::time::Duration;

use miniaudio_player::buffer::{
    ByteSource, ByteSourceStream, CustomDartByteSource, DartReadRequest, FileByteSource,
    MemoryByteSource, SourceKind, TripartiteBuffer, TripartiteByteSource,
};
use symphonia::core::io::MediaSource;

#[test]
fn test_memory_byte_source() {
    let data = b"Hello, World! Symphonia ByteSource Test.".to_vec();
    let mut source = MemoryByteSource::new(data.clone());

    assert_eq!(source.total_bytes(), Some(data.len() as u64));
    assert!(ByteSource::is_seekable(&source));
    assert_eq!(source.source_kind(), SourceKind::Memory);

    let mut buf = [0u8; 5];
    assert_eq!(source.read(&mut buf).unwrap(), 5);
    assert_eq!(&buf, b"Hello");

    // Seek
    source.seek(SeekFrom::Start(7)).unwrap();
    let mut buf2 = [0u8; 5];
    assert_eq!(source.read(&mut buf2).unwrap(), 5);
    assert_eq!(&buf2, b"World");

    // Probe tail
    let tail = source.probe_tail((data.len() - 5) as u64, 5).unwrap();
    assert_eq!(&tail, b"Test.");

    // Current position should be restored after probe_tail
    let mut buf3 = [0u8; 1];
    assert_eq!(source.read(&mut buf3).unwrap(), 1);
    assert_eq!(&buf3, b"!");

    // Test MediaSource implementation
    let media: Box<dyn MediaSource> = Box::new(source);
    assert!(media.is_seekable());
    assert_eq!(media.byte_len(), Some(data.len() as u64));
}

#[test]
fn test_file_byte_source() {
    let temp_dir = std::env::temp_dir();
    let file_path = temp_dir.join(format!("test_file_source_{}.bin", std::process::id()));

    let content = vec![0x42u8; 4096];
    {
        let mut file = std::fs::File::create(&file_path).unwrap();
        file.write_all(&content).unwrap();
    }

    let mut source = FileByteSource::open(&file_path).unwrap();
    assert_eq!(source.total_bytes(), Some(4096));
    assert!(ByteSource::is_seekable(&source));
    assert_eq!(source.source_kind(), SourceKind::File);

    let mut buf = [0u8; 100];
    assert_eq!(source.read(&mut buf).unwrap(), 100);
    assert_eq!(buf[0], 0x42);

    source.seek(SeekFrom::Start(2000)).unwrap();
    assert_eq!(source.read(&mut buf).unwrap(), 100);

    let _ = std::fs::remove_file(file_path);
}

#[test]
fn test_tripartite_byte_source() {
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
}

#[test]
fn test_custom_dart_byte_source_pull_prefetch() {
    let (tx, rx) = channel::<DartReadRequest>();
    let request_sender = std::sync::Arc::new(move |req: DartReadRequest| {
        tx.send(req).unwrap();
    });

    let initial_data = b"INITIAL_STREAM_BYTES".to_vec();
    let (mut source, handle) = CustomDartByteSource::new(
        42,
        Some(100),
        true,
        initial_data,
        request_sender,
    );

    assert_eq!(source.total_bytes(), Some(100));
    assert!(ByteSource::is_seekable(&source));
    assert_eq!(source.source_kind(), SourceKind::CustomDart);

    // Initial read should consume the initial bytes immediately without asking Dart
    let mut buf = [0u8; 7];
    assert_eq!(source.read(&mut buf).unwrap(), 7);
    assert_eq!(&buf, b"INITIAL");

    let mut buf2 = [0u8; 13];
    assert_eq!(source.read(&mut buf2).unwrap(), 13);
    assert_eq!(&buf2, b"_STREAM_BYTES");

    // Next read needs to pull from Dart
    let handle_clone = handle.clone();
    let dart_thread = thread::spawn(move || {
        let req = rx.recv_timeout(Duration::from_secs(2)).expect("Dart should receive read request");
        assert_eq!(req.stream_id, 42);
        assert_eq!(req.offset, 20);
        assert!(req.length > 0);

        // Supply data back to Rust
        handle_clone.supply_bytes(req.request_id, b"DART_CHUNK_1".to_vec(), false);
    });

    let mut buf3 = [0u8; 12];
    assert_eq!(source.read(&mut buf3).unwrap(), 12);
    assert_eq!(&buf3, b"DART_CHUNK_1");
    dart_thread.join().unwrap();
}

#[test]
fn test_custom_dart_byte_source_error() {
    let (tx, rx) = channel::<DartReadRequest>();
    let request_sender = std::sync::Arc::new(move |req: DartReadRequest| {
        tx.send(req).unwrap();
    });

    let (mut source, handle) = CustomDartByteSource::new(
        10,
        Some(500),
        false,
        Vec::new(),
        request_sender,
    );

    let handle_clone = handle.clone();
    let dart_thread = thread::spawn(move || {
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        handle_clone.notify_error(req.request_id, "Decryption key invalid".to_string());
    });

    let mut buf = [0u8; 64];
    let err = source.read(&mut buf).unwrap_err();
    assert!(err.to_string().contains("Decryption key invalid"));
    dart_thread.join().unwrap();
}

#[test]
fn test_custom_dart_byte_source_seek() {
    let (tx, rx) = channel::<DartReadRequest>();
    let request_sender = std::sync::Arc::new(move |req: DartReadRequest| {
        tx.send(req).unwrap();
    });

    let (mut source, handle) = CustomDartByteSource::new(
        99,
        Some(1000),
        true,
        b"AAA".to_vec(),
        request_sender,
    );

    // Seek to offset 500
    source.seek(SeekFrom::Start(500)).unwrap();

    let handle_clone = handle.clone();
    let dart_thread = thread::spawn(move || {
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(req.offset, 500);
        handle_clone.supply_bytes(req.request_id, b"SEEK_DATA".to_vec(), false);
    });

    let mut buf = [0u8; 9];
    assert_eq!(source.read(&mut buf).unwrap(), 9);
    assert_eq!(&buf, b"SEEK_DATA");
    dart_thread.join().unwrap();
}

#[test]
fn test_byte_source_stream_adapter() {
    let memory = MemoryByteSource::new(b"STREAM_ADAPTER_TEST".to_vec());
    let mut adapter = ByteSourceStream(memory);

    assert!(adapter.is_seekable());
    assert_eq!(adapter.byte_len(), Some(19));

    let mut buf = [0u8; 6];
    assert_eq!(adapter.read(&mut buf).unwrap(), 6);
    assert_eq!(&buf, b"STREAM");
}
