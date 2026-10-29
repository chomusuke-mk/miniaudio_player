use miniaudio_player::buffer::{BufferError, TripartiteBuffer};
use std::io::{Read, Seek, SeekFrom};
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

    // Antes de decodificar audio, la lectura del tail funciona
    let mut out = [0u8; 13];
    let read_tail = buffer.read_at(50, &mut out).expect("read tail should succeed");
    assert_eq!(read_tail, 13);
    assert_eq!(&out, b"TRAILING_TAGS");

    // Al activar is_decoding_audio, leer en o después de audio_end produce EOF (0 bytes)
    buffer.set_decoding_audio(true);
    let read_eof = buffer.read_at(50, &mut out).expect("read should return EOF");
    assert_eq!(read_eof, 0);
}

#[test]
fn test_buffer_stream_reader_traits() {
    let buffer = TripartiteBuffer::new(1024, Some(100), false);
    buffer.set_audio_start(0);
    buffer.feed_chunk(b"0123456789ABCDEF").unwrap();
    buffer.mark_eof();

    let mut reader = buffer.create_reader();

    assert!(reader.is_seekable());
    assert_eq!(reader.byte_len(), Some(100));

    let mut out = [0u8; 10];
    let n = reader.read(&mut out).unwrap();
    assert_eq!(n, 10);
    assert_eq!(&out, b"0123456789");
    assert_eq!(reader.cursor(), 10);

    // Seek test: SeekFrom::Start
    reader.seek(SeekFrom::Start(4)).unwrap();
    assert_eq!(reader.cursor(), 4);

    let mut out2 = [0u8; 4];
    reader.read_exact(&mut out2).unwrap();
    assert_eq!(&out2, b"4567");

    // Seek test: SeekFrom::Current
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

    // Intentar escribir más allá de la capacidad sin que el lector avance
    let chunk2 = vec![0xBB; 40];
    let res = buffer.feed_chunk(&chunk2);
    assert_eq!(res, Err(BufferError::Busy));

    // Cuando el lector avanza, se libera espacio
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
