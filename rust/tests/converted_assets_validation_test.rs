//! Comprehensive validation test suite for newly converted real assets:
//! - WavPack (.wv)
//! - WebM (.webm)
//! - Matroska Audio (.mka)
//! - Direct Stream Digital (.dsf)
//! - HLS M3U8 (.m3u8 and .ts segments)

use std::fs::File;
use std::io::Read;
use std::path::Path;

use miniaudio_player::core::player::PlayerCoordinator;
use miniaudio_player::decoder::sniffer::{BoundaryStatus, ContainerFormat, FormatSniffer};
use miniaudio_player::decoder::SymphoniaEngine;
use miniaudio_player::hls::{M3u8Parser, MpegTsDemuxer, ParsedHlsPlaylist, TsAudioCodec};

const ASSETS_DIR: &str = "../example/assets/music";

fn get_asset_path(filename: &str) -> String {
    let p1 = format!("{}/{}", ASSETS_DIR, filename);
    if Path::new(&p1).exists() {
        return p1;
    }
    let p2 = format!("example/assets/music/{}", filename);
    if Path::new(&p2).exists() {
        return p2;
    }
    panic!("Asset file not found: {}", filename);
}

#[test]
fn test_validate_wavpack_salida_wv() {
    let path = get_asset_path("salida.wv");
    let mut file = File::open(&path).expect("Failed to open salida.wv");
    let mut head = [0u8; 4096];
    let n = file.read(&mut head).expect("Read head failed");

    // 1. Sniffer detection
    let (status, info) = FormatSniffer::detect_head_boundary(&head[..n], file.metadata().unwrap().len() as i64);
    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::WavPack);

    // 2. SymphoniaEngine initialization
    let file = File::open(&path).expect("Failed to re-open salida.wv");
    let mut engine = SymphoniaEngine::new(file, Some("wv")).expect("SymphoniaEngine failed to open salida.wv");

    assert_eq!(engine.channels(), 2, "WavPack output must be stereo");
    assert_eq!(engine.sample_rate(), 48000, "WavPack sample rate must be 48 kHz");
    assert!(engine.duration_ms().is_some(), "Duration must be present");
    let dur = engine.duration_ms().unwrap();
    assert!(dur >= 60000 && dur <= 75000, "Duration must be ~68s, got: {} ms", dur);

    // 3. Frame decoding
    let mut pcm = Vec::new();
    let mut total_samples = 0;
    for _ in 0..20 {
        let ok = engine.decode_next_frame(&mut pcm).expect("Decode frame failed");
        if !ok {
            break;
        }
        assert!(!pcm.is_empty());
        assert_eq!(pcm.len() % 2, 0);
        for &s in &pcm {
            assert!(!s.is_nan());
            assert!(s >= -2.0 && s <= 2.0);
        }
        total_samples += pcm.len();
    }
    assert!(total_samples > 0, "Decoded samples must be > 0");

    // 4. Seek test
    engine.seek_ms(30000).expect("Seek to 30s failed");
    let ok = engine.decode_next_frame(&mut pcm).expect("Decode after seek failed");
    assert!(ok, "Must decode frames after seek");
    assert!(!pcm.is_empty());
}

#[test]
fn test_validate_webm_salida_webm() {
    let path = get_asset_path("salida.webm");
    let mut file = File::open(&path).expect("Failed to open salida.webm");
    let mut head = [0u8; 4096];
    let n = file.read(&mut head).expect("Read head failed");

    // 1. Sniffer detection
    let (status, info) = FormatSniffer::detect_head_boundary(&head[..n], file.metadata().unwrap().len() as i64);
    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Matroska);

    // 2. SymphoniaEngine initialization
    let file = File::open(&path).expect("Failed to re-open salida.webm");
    let mut engine = SymphoniaEngine::new(file, Some("webm")).expect("SymphoniaEngine failed to open salida.webm");

    assert_eq!(engine.channels(), 2, "WebM Opus must be stereo");
    assert_eq!(engine.sample_rate(), 48000, "Opus sample rate must be 48 kHz");

    // 3. Frame decoding
    let mut pcm = Vec::new();
    let mut frames_decoded = 0;
    for _ in 0..20 {
        let ok = engine.decode_next_frame(&mut pcm).expect("Decode frame failed");
        if !ok {
            break;
        }
        assert!(!pcm.is_empty());
        assert_eq!(pcm.len() % 2, 0);
        for &s in &pcm {
            assert!(!s.is_nan());
            assert!(s >= -2.0 && s <= 2.0);
        }
        frames_decoded += 1;
    }
    assert!(frames_decoded > 0, "Decoded frames must be > 0");

    // 4. Seek test
    engine.seek_ms(25000).expect("Seek to 25s failed");
    let ok = engine.decode_next_frame(&mut pcm).expect("Decode after seek failed");
    assert!(ok, "Must decode frames after seek");
}

#[test]
fn test_validate_matroska_salida_mka() {
    let path = get_asset_path("salida.mka");
    let mut file = File::open(&path).expect("Failed to open salida.mka");
    let mut head = [0u8; 4096];
    let n = file.read(&mut head).expect("Read head failed");

    // 1. Sniffer detection
    let (status, info) = FormatSniffer::detect_head_boundary(&head[..n], file.metadata().unwrap().len() as i64);
    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Matroska);

    // 2. SymphoniaEngine initialization
    let file = File::open(&path).expect("Failed to re-open salida.mka");
    let mut engine = SymphoniaEngine::new(file, Some("mka")).expect("SymphoniaEngine failed to open salida.mka");

    assert_eq!(engine.channels(), 2, "MKA FLAC must be stereo");
    assert_eq!(engine.sample_rate(), 48000, "MKA FLAC sample rate must be 48 kHz");

    // 3. Frame decoding
    let mut pcm = Vec::new();
    let mut frames_decoded = 0;
    for _ in 0..20 {
        let ok = engine.decode_next_frame(&mut pcm).expect("Decode frame failed");
        if !ok {
            break;
        }
        assert!(!pcm.is_empty());
        assert_eq!(pcm.len() % 2, 0);
        for &s in &pcm {
            assert!(!s.is_nan());
            assert!(s >= -2.0 && s <= 2.0);
        }
        frames_decoded += 1;
    }
    assert!(frames_decoded > 0, "Decoded frames must be > 0");

    // 4. Seek test
    engine.seek_ms(40000).expect("Seek to 40s failed");
    let ok = engine.decode_next_frame(&mut pcm).expect("Decode after seek failed");
    assert!(ok, "Must decode frames after seek");
}

#[test]
fn test_validate_dsd_salida_dsf() {
    let path = get_asset_path("salida.dsf");
    let mut file = File::open(&path).expect("Failed to open salida.dsf");
    let mut head = [0u8; 4096];
    let n = file.read(&mut head).expect("Read head failed");

    // 1. Sniffer detection
    let (status, info) = FormatSniffer::detect_head_boundary(&head[..n], file.metadata().unwrap().len() as i64);
    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Dsf);

    // 2. SymphoniaEngine initialization
    let file = File::open(&path).expect("Failed to re-open salida.dsf");
    let mut engine = SymphoniaEngine::new(file, Some("dsf")).expect("SymphoniaEngine failed to open salida.dsf");

    assert_eq!(engine.channels(), 2, "DSF must be stereo");
    assert_eq!(engine.sample_rate(), 88200, "DSF decimated sample rate must be 88.2 kHz");
    assert!(engine.duration_ms().is_some(), "Duration must be present");
    let dur = engine.duration_ms().unwrap();
    assert!(dur >= 60000 && dur <= 75000, "Duration must be ~68s, got: {} ms", dur);

    // 3. Decimate PDM blocks to PCM
    let mut pcm = Vec::new();
    let mut total_pcm_samples = 0;
    for _ in 0..10 {
        let ok = engine.decode_next_frame(&mut pcm).expect("DSF decode frame failed");
        if !ok {
            break;
        }
        assert!(!pcm.is_empty());
        assert_eq!(pcm.len() % 2, 0, "Stereo samples must be aligned");
        for &s in &pcm {
            assert!(!s.is_nan(), "Sample cannot be NaN");
            assert!(s >= -2.0 && s <= 2.0, "Sample out of bounds: {}", s);
        }
        total_pcm_samples += pcm.len();
    }
    assert!(total_pcm_samples > 0, "Total decimated samples must be > 0");

    // 4. Seek test
    engine.seek_ms(20000).expect("Seek to 20s failed");
    let ok = engine.decode_next_frame(&mut pcm).expect("Decode after seek failed");
    assert!(ok, "Must decode frames after seek");
    assert!(!pcm.is_empty());
}

#[test]
fn test_validate_hls_salida_m3u8_and_ts() {
    let m3u8_path = get_asset_path("salida.m3u8");
    let mut m3u8_file = File::open(&m3u8_path).expect("Failed to open salida.m3u8");
    let mut m3u8_bytes = Vec::new();
    m3u8_file.read_to_end(&mut m3u8_bytes).expect("Read m3u8 failed");

    // 1. Sniffer detection
    assert!(M3u8Parser::is_m3u8(&m3u8_bytes));

    // 2. M3U8 Playlist Parser
    let parsed = M3u8Parser::parse(&m3u8_bytes).expect("Failed to parse salida.m3u8");
    match parsed {
        ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence,
            segments,
            total_duration_seconds,
        } => {
            assert!(!is_live, "M3U8 VOD must have endlist");
            assert_eq!(media_sequence, 0);
            assert!(target_duration >= 8.0 && target_duration <= 12.0);
            assert_eq!(segments.len(), 7, "Expected 7 segments (salida_0.ts .. salida_6.ts)");
            assert!(total_duration_seconds >= 65.0 && total_duration_seconds <= 75.0);

            assert_eq!(segments[0].uri, "salida_0.ts");
            assert_eq!(segments[6].uri, "salida_6.ts");
        }
        _ => panic!("Expected Media playlist"),
    }

    // 3. TS Segment Demuxing on real segment salida_0.ts
    let ts_path = get_asset_path("salida_0.ts");
    let mut ts_file = File::open(&ts_path).expect("Failed to open salida_0.ts");
    let mut ts_bytes = Vec::new();
    ts_file.read_to_end(&mut ts_bytes).expect("Read ts failed");

    assert!(MpegTsDemuxer::is_mpeg_ts(&ts_bytes), "File must be recognized as MPEG-2 TS");

    let demux = MpegTsDemuxer::demux_segment(&ts_bytes);
    assert_eq!(demux.codec, TsAudioCodec::AacAdts, "Segment codec must be AAC ADTS");
    assert!(demux.audio_pid.is_some(), "Audio PID must be identified");
    assert!(!demux.audio_bytes.is_empty(), "Demuxed audio elementary stream must not be empty");

    // ADTS syncword check: 0xFFF (0xFF followed by 0xF0..0xFF)
    assert_eq!(demux.audio_bytes[0], 0xFF);
    assert_eq!(demux.audio_bytes[1] & 0xF0, 0xF0);

    // 4. Decode the demuxed AAC ADTS stream with SymphoniaEngine
    let cursor = std::io::Cursor::new(demux.audio_bytes);
    let mut aac_engine = SymphoniaEngine::new(cursor, Some("aac")).expect("Failed to open demuxed AAC");
    assert_eq!(aac_engine.channels(), 2);
    assert_eq!(aac_engine.sample_rate(), 48000);

    let mut pcm = Vec::new();
    let ok = aac_engine.decode_next_frame(&mut pcm).expect("Decode demuxed AAC frame failed");
    assert!(ok);
    assert!(!pcm.is_empty());
}

#[test]
fn test_player_coordinator_plays_real_converted_files() {
    use std::sync::atomic::Ordering;

    let files = [
        "salida.wv",
        "salida.webm",
        "salida.mka",
        "salida.dsf",
    ];

    for file_name in files {
        let path = get_asset_path(file_name);
        let coordinator_res = PlayerCoordinator::new(
            48000,
            2,
            1024,
            std::ptr::null(),
            None,
            std::ptr::null_mut(),
        );

        if let Ok(mut player) = coordinator_res {
            let ret = player.open_file(&path);
            assert_eq!(ret, 0, "open_file failed for {}: error {}", file_name, ret);

            assert!(player.channels.load(Ordering::Relaxed) > 0, "{}: channels must be > 0", file_name);
            assert!(player.sample_rate.load(Ordering::Relaxed) > 0, "{}: sample_rate must be > 0", file_name);

            // Start playback
            let play_ret = player.play();
            assert_eq!(play_ret, 0, "play failed for {}", file_name);

            // Seek forward
            let seek_ret = player.seek(15000);
            assert_eq!(seek_ret, 0, "seek failed for {}", file_name);

            // Stop
            player.stop();
        }
    }
}
