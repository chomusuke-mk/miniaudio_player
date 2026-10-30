use miniaudio_player::buffer::{BufferStreamReader, TripartiteBuffer};
use miniaudio_player::decoder::sniffer::{BoundaryStatus, ContainerFormat, FormatSniffer};
use miniaudio_player::decoder::symphonia_engine::{create_codec_registry, SymphoniaEngine};
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;

fn generate_pcm16_wav(num_frames: usize, sample_rate: u32, channels: u16) -> Vec<u8> {
    let bits_per_sample: u16 = 16;
    let bytes_per_sample = (bits_per_sample / 8) as usize;
    let block_align = channels as usize * bytes_per_sample;
    let byte_rate = sample_rate as usize * block_align;
    let data_size = num_frames * block_align;
    let file_size = 36 + data_size;

    let mut wav = Vec::with_capacity(44 + data_size);
    // RIFF header
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(file_size as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVE");

    // fmt chunk
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // Subchunk1Size (16 for PCM)
    wav.extend_from_slice(&1u16.to_le_bytes()); // AudioFormat (1 for PCM)
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(byte_rate as u32).to_le_bytes());
    wav.extend_from_slice(&(block_align as u16).to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());

    // data chunk
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(data_size as u32).to_le_bytes());

    // Generate a 440Hz sine wave
    for i in 0..num_frames {
        let t = i as f32 / sample_rate as f32;
        let sample = (t * 440.0 * 2.0 * std::f32::consts::PI).sin();
        let val = (sample * 30000.0) as i16;
        for _ in 0..channels {
            wav.extend_from_slice(&val.to_le_bytes());
        }
    }

    wav
}

#[test]
fn test_sniffer_wav_detection() {
    let wav_data = generate_pcm16_wav(500, 48000, 2);
    let (status, info) = FormatSniffer::detect_head_boundary(&wav_data, wav_data.len() as i64);

    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Wav);
    assert_eq!(info.audio_start, 44);
    assert_eq!(info.audio_end, wav_data.len() as i64);
    assert_eq!(info.bytes_per_frame, 4);
    assert_eq!(info.wav_data_size_field_offset, 40);
}

#[test]
fn test_sniffer_tail_boundary_id3v1() {
    let mut data = vec![0u8; 1000];
    // Append ID3v1 tag: "TAG" + 125 bytes
    let mut id3v1 = vec![0u8; 128];
    id3v1[0] = b'T';
    id3v1[1] = b'A';
    id3v1[2] = b'G';
    data.extend_from_slice(&id3v1);

    let total_size = data.len() as i64;
    let tail_len = 256;
    let tail_offset = total_size - tail_len as i64;
    let tail = &data[tail_offset as usize..];

    let (status, audio_end) = FormatSniffer::detect_tail_boundary(
        ContainerFormat::Mp3,
        tail,
        tail_offset,
        total_size,
        0,
    );

    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(audio_end, 1000);
}

#[test]
fn test_symphonia_registry_has_opus() {
    let registry = create_codec_registry();
    assert!(registry.get_audio_decoder(CODEC_ID_OPUS).is_some());
}

#[test]
fn test_symphonia_decode_wav_stream() {
    let sample_rate = 44100;
    let channels = 2;
    let num_frames = 2000;
    let wav_bytes = generate_pcm16_wav(num_frames, sample_rate, channels);

    let buf = TripartiteBuffer::new(wav_bytes.len(), Some(wav_bytes.len() as u64), false);
    buf.set_head(&wav_bytes[0..44]);
    buf.set_audio_start(44);
    buf.set_audio_end(wav_bytes.len() as u64);
    let _ = buf.feed_chunk(&wav_bytes[44..]);
    buf.mark_eof();

    let reader = BufferStreamReader::new(buf);
    let mut engine = SymphoniaEngine::new(reader, Some("wav"))
        .expect("Failed to initialize Symphonia engine with WAV data");

    assert_eq!(engine.sample_rate(), sample_rate);
    assert_eq!(engine.channels(), channels as u32);

    let mut decoded_samples = Vec::new();
    let mut total_decoded_frames = 0;

    while let Ok(true) = engine.decode_next_frame(&mut decoded_samples) {
        assert!(!decoded_samples.is_empty());
        total_decoded_frames += decoded_samples.len() / (channels as usize);
    }

    assert_eq!(total_decoded_frames, num_frames);
}

#[test]
fn test_symphonia_seek_wav_near_end() {
    let wav_bytes = generate_pcm16_wav(44100 * 6, 44100, 1); // 6.0 seconds mono WAV
    let cursor = std::io::Cursor::new(wav_bytes);
    let mut eng = SymphoniaEngine::new(cursor, Some("wav")).expect("Failed to open WAV");
    println!("WAV duration: {:?}, sr: {}, ch: {}", eng.duration_ms(), eng.sample_rate(), eng.channels());
    eng.seek_ms(5900).expect("Seek to 5900ms failed");
    let mut pcm = Vec::new();
    let mut total_frames = 0;
    while let Ok(true) = eng.decode_next_frame(&mut pcm) {
        total_frames += pcm.len() / (eng.channels() as usize);
    }
    println!("Total frames decoded after seek to 5900ms: {}", total_frames);
}

#[test]
fn test_symphonia_seek_wav_stream() {
    let sample_rate = 48000;
    let channels = 2;
    let num_frames = 48000; // 1 second of audio
    let wav_bytes = generate_pcm16_wav(num_frames, sample_rate, channels);

    let buf = TripartiteBuffer::new(wav_bytes.len(), Some(wav_bytes.len() as u64), false);
    buf.set_head(&wav_bytes[0..44]);
    buf.set_audio_start(44);
    buf.set_audio_end(wav_bytes.len() as u64);
    let _ = buf.feed_chunk(&wav_bytes[44..]);
    buf.mark_eof();

    let reader = BufferStreamReader::new(buf);
    let mut engine = SymphoniaEngine::new(reader, Some("wav"))
        .expect("Failed to initialize Symphonia engine");

    // Seek to 500 ms (middle of audio)
    engine.seek_ms(500).expect("Seek to 500ms failed");

    let mut pcm = Vec::new();
    let has_frame = engine.decode_next_frame(&mut pcm).expect("Decode after seek failed");
    assert!(has_frame);
    assert!(!pcm.is_empty());
}

#[test]
fn test_symphonia_decode_mp3_stream_chunk() {
    let mp3_bytes = std::fs::read("../example/assets/music/salida.mp3").expect("Cannot read salida.mp3");
    let chunk_size = 65536.min(mp3_bytes.len());
    let initial_data = &mp3_bytes[..chunk_size];

    let buf = TripartiteBuffer::new(2 * 1024 * 1024, Some(mp3_bytes.len() as u64), false);
    let (_status, boundary) = FormatSniffer::detect_head_boundary(initial_data, mp3_bytes.len() as i64);
    if boundary.audio_start > 0 {
        let head_len = (boundary.audio_start as usize).min(initial_data.len());
        buf.set_head(&initial_data[..head_len]);
        buf.set_audio_start(boundary.audio_start as u64);
        if initial_data.len() > head_len {
            let _ = buf.feed_chunk(&initial_data[head_len..]);
        }
    } else {
        buf.set_audio_start(0);
        let _ = buf.feed_chunk(initial_data);
    }

    let reader = BufferStreamReader::new(buf);
    let res = SymphoniaEngine::new(reader, Some("mp3"));
    match res {
        Ok(engine) => {
            println!("Stream MP3 probe succeeded! SR: {}, CH: {}", engine.sample_rate(), engine.channels());
        }
        Err(e) => {
            panic!("Stream MP3 probe failed: {:?}", e);
        }
    }
}

#[test]
fn test_probe_matrix_files() {
    let files = ["salida.rf64", "salida.w64"];
    for fname in &files {
        let p = format!("../example/assets/music/{}", fname);
        let bytes = std::fs::read(&p).unwrap();
        let ext = fname.split('.').last();
        let cursor = std::io::Cursor::new(bytes);
        let mss = symphonia::core::io::MediaSourceStream::new(Box::new(cursor), Default::default());
        let mut hint = symphonia::core::formats::probe::Hint::new();
        if let Some(e) = ext { hint.with_extension(e); }
        let probed = symphonia::default::get_probe().probe(&hint, mss, Default::default(), Default::default()).unwrap();
        println!("{fname}: matched format={:?}", probed.format_info().short_name);
    }
}
