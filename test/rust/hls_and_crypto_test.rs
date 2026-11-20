//! HLS Playlist Parsing and MPEG-2 TS Demuxing Tests.

mod common;

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::FixtureResolver;
use miniaudio_player::api::types::RustAnalysisConfig;
use miniaudio_player::core::dual_source::{AudioSourceCore, StreamingDeck};
use miniaudio_player::decoder::SymphoniaEngine;
use miniaudio_player::dsp::analysis::analyze_audio_source;
use miniaudio_player::hls::{
    derive_companion_hls_metadata_urls, parse_hls_extinf_metadata, resolve_hls_uri,
    HlsExtinfMetadata, HlsPlaylistTracker, HlsSegmentTarget, M3u8Parser, MpegTsDemuxer,
    ParsedHlsPlaylist, TsAudioCodec,
};

#[test]
fn test_m3u8_master_playlist_parsing() {
    let master_content = b"#EXTM3U\n\
#EXT-X-VERSION:4\n\
#EXT-X-STREAM-INF:BANDWIDTH=1280000,CODECS=\"mp4a.40.2\",RESOLUTION=640x360\n\
low/playlist.m3u8\n\
#EXT-X-STREAM-INF:BANDWIDTH=2560000,CODECS=\"mp4a.40.2\",RESOLUTION=1280x720\n\
mid/playlist.m3u8\n\
#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS=\"mp4a.40.2\",RESOLUTION=1920x1080\n\
high/playlist.m3u8\n";

    assert!(M3u8Parser::is_m3u8(master_content));

    let parsed = M3u8Parser::parse(master_content).expect("Master playlist should parse");
    match parsed {
        ParsedHlsPlaylist::Master { variants } => {
            assert_eq!(variants.len(), 3);
            assert_eq!(variants[0].uri, "low/playlist.m3u8");
            assert_eq!(variants[0].bandwidth, 1280000);
            assert_eq!(variants[0].resolution, Some((640, 360)));

            assert_eq!(variants[2].uri, "high/playlist.m3u8");
            assert_eq!(variants[2].bandwidth, 5000000);
            assert_eq!(variants[2].resolution, Some((1920, 1080)));
        }
        _ => panic!("Expected Master playlist"),
    }
}

#[test]
fn test_m3u8_media_playlist_parsing_vod_and_live() {
    let vod_content = b"#EXTM3U\n\
#EXT-X-VERSION:4\n\
#EXT-X-TARGETDURATION:10\n\
#EXT-X-MEDIA-SEQUENCE:100\n\
#EXT-X-PLAYLIST-TYPE:VOD\n\
#EXT-X-KEY:METHOD=AES-128,URI=\"https://example.com/key.bin\",IV=0x00000000000000000000000000000064\n\
#EXTINF:9.500,\n\
#EXT-X-BYTERANGE:10000@0\n\
segment100.ts\n\
#EXTINF:10.000,\n\
#EXT-X-BYTERANGE:12000@10000\n\
segment101.ts\n\
#EXT-X-ENDLIST\n";

    let parsed = M3u8Parser::parse(vod_content).expect("Media playlist should parse");
    match parsed {
        ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence,
            segments,
            total_duration_seconds,
        } => {
            assert!(!is_live);
            assert_eq!(target_duration, 10.0);
            assert_eq!(media_sequence, 100);
            assert_eq!(segments.len(), 2);
            assert_eq!(total_duration_seconds, 19.5);

            assert_eq!(segments[0].uri, "segment100.ts");
            assert_eq!(segments[0].duration_seconds, 9.5);
            assert_eq!(segments[0].byte_range, Some((10000, 0)));
            assert_eq!(segments[0].sequence_number, 100);

            let key0 = segments[0].key.as_ref().expect("Key must be present");
            assert_eq!(key0.method, "AES-128");
            assert_eq!(key0.uri.as_deref(), Some("https://example.com/key.bin"));
            assert_eq!(
                key0.iv.as_deref(),
                Some("0x00000000000000000000000000000064")
            );
        }
        _ => panic!("Expected Media playlist"),
    }
}

#[test]
fn test_synthetic_mpeg2_ts_demuxer_aac() {
    let mut ts_data = Vec::new();

    // 1. PAT packet (PID 0) -> Program 1 has PMT PID 0x1000
    let mut pat_packet = vec![0xFF; 188];
    pat_packet[0] = 0x47;
    pat_packet[1] = 0x40;
    pat_packet[2] = 0x00;
    pat_packet[3] = 0x10;
    pat_packet[4] = 0x00;
    pat_packet[5] = 0x00;
    pat_packet[6] = 0xB0;
    pat_packet[7] = 0x0D;
    pat_packet[8] = 0x00;
    pat_packet[9] = 0x01;
    pat_packet[10] = 0xC1;
    pat_packet[11] = 0x00;
    pat_packet[12] = 0x00;
    pat_packet[13] = 0x00;
    pat_packet[14] = 0x01;
    pat_packet[15] = 0xF0;
    pat_packet[16] = 0x00;
    ts_data.extend_from_slice(&pat_packet);

    // 2. PMT packet (PID 0x1000) -> Audio PID 0x0101, Stream Type 0x0F (AAC ADTS)
    let mut pmt_packet = vec![0xFF; 188];
    pmt_packet[0] = 0x47;
    pmt_packet[1] = 0x50;
    pmt_packet[2] = 0x00;
    pmt_packet[3] = 0x10;
    pmt_packet[4] = 0x00;
    pmt_packet[5] = 0x02;
    pmt_packet[6] = 0xB0;
    pmt_packet[7] = 0x12;
    pmt_packet[8] = 0x00;
    pmt_packet[9] = 0x01;
    pmt_packet[10] = 0xC1;
    pmt_packet[11] = 0x00;
    pmt_packet[12] = 0x00;
    pmt_packet[13] = 0xE1;
    pmt_packet[14] = 0x00;
    pmt_packet[15] = 0xF0;
    pmt_packet[16] = 0x00;
    pmt_packet[17] = 0x0F;
    pmt_packet[18] = 0xE1;
    pmt_packet[19] = 0x01;
    pmt_packet[20] = 0xF0;
    pmt_packet[21] = 0x00;
    ts_data.extend_from_slice(&pmt_packet);

    // 3. Audio PES packet on PID 0x0101
    let mut pes_packet = vec![0xFF; 188];
    pes_packet[0] = 0x47;
    pes_packet[1] = 0x41;
    pes_packet[2] = 0x01;
    pes_packet[3] = 0x10;
    pes_packet[4] = 0x00;
    pes_packet[5] = 0x00;
    pes_packet[6] = 0x01;
    pes_packet[7] = 0xC0;
    pes_packet[8] = 0x00;
    pes_packet[9] = 0x10;
    pes_packet[10] = 0x80;
    pes_packet[11] = 0x00;
    pes_packet[12] = 0x00;
    pes_packet[13] = 0xFF;
    pes_packet[14] = 0xF1;
    pes_packet[15] = 0x50;
    pes_packet[16] = 0x80;
    ts_data.extend_from_slice(&pes_packet);

    assert!(MpegTsDemuxer::is_mpeg_ts(&ts_data));

    let demux_res = MpegTsDemuxer::demux_segment(&ts_data);
    assert_eq!(demux_res.audio_pid, Some(0x0101));
    assert_eq!(demux_res.codec, TsAudioCodec::AacAdts);
    assert_eq!(&demux_res.audio_bytes[0..2], &[0xFF, 0xF1]);
}

#[test]
fn test_real_hls_fixture_playlist_and_ts_segments() {
    let m3u8_path = FixtureResolver::resolve("hls/28_Разводят_мосты.m3u8");
    let mut m3u8_file = File::open(&m3u8_path).expect("Failed to open hls/28_Разводят_мосты.m3u8");
    let mut m3u8_bytes = Vec::new();
    m3u8_file.read_to_end(&mut m3u8_bytes).unwrap();

    assert!(M3u8Parser::is_m3u8(&m3u8_bytes));

    let parsed = M3u8Parser::parse(&m3u8_bytes).expect("Failed to parse hls/28_Разводят_мосты.m3u8");
    match parsed {
        ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence,
            segments,
            total_duration_seconds,
        } => {
            assert!(!is_live);
            assert_eq!(media_sequence, 0);
            assert!(target_duration >= 8.0 && target_duration <= 12.0);
            assert_eq!(segments.len(), 19);
            assert!(total_duration_seconds >= 178.0 && total_duration_seconds <= 183.0);

            for seg in &segments {
                let ts_path = FixtureResolver::resolve(&format!("hls/{}", seg.uri));
                let ts_bytes = std::fs::read(&ts_path).unwrap();
                assert!(MpegTsDemuxer::is_mpeg_ts(&ts_bytes));

                let demux = MpegTsDemuxer::demux_segment(&ts_bytes);
                assert_eq!(demux.codec, TsAudioCodec::AacAdts);
                assert!(demux.audio_pid.is_some());
                assert!(!demux.audio_bytes.is_empty());
                assert_eq!(demux.audio_bytes[0], 0xFF);
                assert_eq!(demux.audio_bytes[1] & 0xF0, 0xF0);
            }
        }
        _ => panic!("Expected Media playlist"),
    }

    // Verify AES-128-CBC encrypted HLS playlist & key file
    let aes_m3u8_bytes = std::fs::read(FixtureResolver::resolve("hls/26_Where_Miracles_Start_aes.m3u8")).unwrap();
    match M3u8Parser::parse(&aes_m3u8_bytes).expect("Failed to parse AES m3u8") {
        ParsedHlsPlaylist::Media { segments, .. } => {
            assert_eq!(segments.len(), 19);
            let key = segments[0].key.as_ref().expect("AES-128 playlist must declare key");
            assert_eq!(key.method, "AES-128");
            let key_path = FixtureResolver::resolve(&format!("hls/{}", key.uri.as_deref().unwrap()));
            assert_eq!(std::fs::read(&key_path).unwrap().len(), 16);
        }
        _ => panic!("Expected Media playlist for AES-128 fixture"),
    }

    // Decode demuxed segment 0 with SymphoniaEngine
    let ts0_bytes = std::fs::read(FixtureResolver::resolve("hls/28_seg_0.ts")).unwrap();
    let demux0 = MpegTsDemuxer::demux_segment(&ts0_bytes);
    let cursor = std::io::Cursor::new(demux0.audio_bytes);
    let mut aac_engine = SymphoniaEngine::new(cursor, Some("aac")).expect("Failed to open demuxed AAC");
    assert_eq!(aac_engine.channels(), 2);
    assert_eq!(aac_engine.sample_rate(), 48000);

    let mut pcm = Vec::new();
    assert!(aac_engine.decode_next_frame(&mut pcm).unwrap());
    assert!(!pcm.is_empty());
}

#[test]
fn test_m3u8_byterange_implicit_offsets_and_uri_resolution() {
    let manifest = b"#EXTM3U\n\
#EXT-X-VERSION:4\n\
#EXT-X-TARGETDURATION:6\n\
#EXTINF:5.0,\n\
#EXT-X-BYTERANGE:1000@500\n\
pack_a.ts\n\
#EXTINF:5.0,\n\
#EXT-X-BYTERANGE:2000\n\
pack_a.ts\n\
#EXTINF:5.0,\n\
#EXT-X-BYTERANGE:1500\n\
pack_a.ts\n\
#EXTINF:4.0,\n\
#EXT-X-BYTERANGE:800\n\
pack_b.ts\n\
#EXTINF:4.0,\n\
#EXT-X-BYTERANGE:400@100\n\
pack_b.ts\n\
#EXT-X-ENDLIST\n";

    let parsed = M3u8Parser::parse(manifest).expect("Byte-range playlist should parse");
    match parsed {
        ParsedHlsPlaylist::Media { segments, .. } => {
            assert_eq!(segments.len(), 5);
            assert_eq!(segments[0].byte_range, Some((1000, 500)));
            assert_eq!(segments[1].byte_range, Some((2000, 1500)));
            assert_eq!(segments[2].byte_range, Some((1500, 3500)));
            assert_eq!(segments[3].byte_range, Some((800, 0)));
            assert_eq!(segments[4].byte_range, Some((400, 100)));
        }
        _ => panic!("Expected Media playlist"),
    }

    assert_eq!(
        resolve_hls_uri(
            "https://cdn.example.com/live/master.m3u8?token=abc",
            "low/stream.m3u8?x=1"
        ),
        "https://cdn.example.com/live/low/stream.m3u8?x=1"
    );
    assert_eq!(
        resolve_hls_uri("https://cdn.example.com/live/master.m3u8", "/vod/seg0.ts"),
        "https://cdn.example.com/vod/seg0.ts"
    );
    assert_eq!(
        resolve_hls_uri("https://cdn.example.com/live/master.m3u8", "//edge.example.com/a.ts"),
        "https://edge.example.com/a.ts"
    );
    assert_eq!(
        resolve_hls_uri("http://127.0.0.1:8080/live.m3u8", "https://other.host/seg.ts"),
        "https://other.host/seg.ts"
    );
}

#[test]
fn test_hls_playlist_tracker_live_reloads_and_endlist() {
    let parse_media = |body: &[u8]| match M3u8Parser::parse(body).unwrap() {
        ParsedHlsPlaylist::Media {
            is_live,
            target_duration,
            media_sequence,
            segments,
            ..
        } => (is_live, target_duration, media_sequence, segments),
        _ => panic!("Expected media playlist"),
    };

    let (is_live0, td0, seq0, segs0) = parse_media(
        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:10\n\
#EXTINF:4.0,\nseg10.ts\n#EXTINF:4.0,\nseg11.ts\n",
    );
    let mut tracker = HlsPlaylistTracker::new(
        "http://127.0.0.1/live/stream.m3u8".to_string(),
        is_live0,
        td0,
        seq0,
        &segs0,
    );
    assert!(tracker.is_live());

    // Poll 1: unchanged playlist yields zero new segments.
    let new1 = tracker.ingest_media_playlist(seq0, is_live0, td0, &segs0);
    assert!(new1.is_empty());

    // Poll 2: compliant sliding window advance (#EXT-X-MEDIA-SEQUENCE: 10 -> 11).
    let (is_live2, td2, seq2, segs2) = parse_media(
        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:11\n\
#EXTINF:4.0,\nseg11.ts\n#EXTINF:4.0,\nseg12.ts\n#EXTINF:4.0,\nseg13.ts\n",
    );
    let new2 = tracker.ingest_media_playlist(seq2, is_live2, td2, &segs2);
    assert_eq!(
        new2,
        vec![
            HlsSegmentTarget {
                url: "http://127.0.0.1/live/seg12.ts".to_string(),
                byte_range: None,
                sequence_number: 12,
                duration_ms: 4000,
                title: None,
            },
            HlsSegmentTarget {
                url: "http://127.0.0.1/live/seg13.ts".to_string(),
                byte_range: None,
                sequence_number: 13,
                duration_ms: 4000,
                title: None,
            },
        ]
    );

    // Poll 3: non-compliant server forgets to increment EXT-X-MEDIA-SEQUENCE while rolling URI window.
    let (is_live3, td3, seq3, segs3) = parse_media(
        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:11\n\
#EXTINF:4.0,\nseg12.ts\n#EXTINF:4.0,\nseg13.ts\n#EXTINF:4.0,\nseg14.ts\n",
    );
    let new3 = tracker.ingest_media_playlist(seq3, is_live3, td3, &segs3);
    assert_eq!(
        new3,
        vec![HlsSegmentTarget {
            url: "http://127.0.0.1/live/seg14.ts".to_string(),
            byte_range: None,
            sequence_number: 13,
            duration_ms: 4000,
            title: None,
        }]
    );

    // Poll 4: final segment appended with #EXT-X-ENDLIST stops live polling.
    let (is_live4, td4, seq4, segs4) = parse_media(
        b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:11\n\
#EXTINF:4.0,\nseg13.ts\n#EXTINF:4.0,\nseg14.ts\n#EXTINF:4.0,\nseg15.ts\n#EXT-X-ENDLIST\n",
    );
    let new4 = tracker.ingest_media_playlist(seq4, is_live4, td4, &segs4);
    assert_eq!(
        new4,
        vec![HlsSegmentTarget {
            url: "http://127.0.0.1/live/seg15.ts".to_string(),
            byte_range: None,
            sequence_number: 13,
            duration_ms: 4000,
            title: None,
        }]
    );
    assert!(!tracker.is_live());
}

fn spawn_hls_test_server<F>(handler: F) -> (String, Arc<AtomicBool>, std::thread::JoinHandle<()>)
where
    F: Fn(&str, Option<&str>) -> (u16, &'static str, Vec<u8>, Option<String>) + Send + Sync + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").expect("Failed to bind ephemeral HTTP port");
    listener
        .set_nonblocking(true)
        .expect("Failed to set listener non-blocking");
    let addr = listener.local_addr().unwrap();
    let base_url = format!("http://127.0.0.1:{}", addr.port());
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = stop.clone();

    let handle = std::thread::spawn(move || {
        while !stop_clone.load(Ordering::Acquire) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let _ = stream.set_nonblocking(false);
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request_line = String::new();
                    if reader.read_line(&mut request_line).is_err() {
                        continue;
                    }
                    let path = request_line
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or("/")
                        .to_string();
                    let mut range_header: Option<String> = None;
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            break;
                        }
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            break;
                        }
                        if let Some((k, v)) = trimmed.split_once(':') {
                            if k.trim().eq_ignore_ascii_case("Range") {
                                range_header = Some(v.trim().to_string());
                            }
                        }
                    }

                    let (status, content_type, body, content_range) =
                        handler(&path, range_header.as_deref());
                    let reason = match status {
                        200 => "OK",
                        206 => "Partial Content",
                        404 => "Not Found",
                        _ => "Error",
                    };
                    let mut head = format!(
                        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
                        status,
                        reason,
                        content_type,
                        body.len()
                    );
                    if let Some(cr) = content_range {
                        head.push_str(&format!("Content-Range: {}\r\n", cr));
                    }
                    head.push_str("\r\n");
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&body);
                    let _ = stream.flush();
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => break,
            }
        }
    });

    (base_url, stop, handle)
}

#[test]
fn test_hls_live_manifest_periodic_polling_http() {
    let seg_bytes: Vec<Vec<u8>> = (0..4)
        .map(|i| std::fs::read(FixtureResolver::resolve(&format!("hls/28_seg_{}.ts", i))).unwrap())
        .collect();
    let expected_total_demuxed: usize = seg_bytes
        .iter()
        .map(|b| MpegTsDemuxer::demux_segment(b).audio_bytes.len())
        .sum();

    let playlist_polls = Arc::new(AtomicUsize::new(0));
    let requested_segments = Arc::new(Mutex::new(Vec::<String>::new()));

    let seg_clone = seg_bytes.clone();
    let polls_clone = playlist_polls.clone();
    let reqs_clone = requested_segments.clone();

    let (base_url, stop_srv, srv_handle) = spawn_hls_test_server(move |path, _range| match path {
        "/master.m3u8" => (
            200,
            "application/vnd.apple.mpegurl",
            b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000\n/live/audio.m3u8\n".to_vec(),
            None,
        ),
        "/live/audio.m3u8" => {
            let poll = polls_clone.fetch_add(1, Ordering::SeqCst) + 1;
            let body = match poll {
                1 => "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\nseg0.ts\n",
                2 => "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nseg2.ts\n",
                _ => "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:2\n#EXTINF:10.0,\nseg2.ts\n#EXTINF:10.0,\nseg3.ts\n#EXT-X-ENDLIST\n",
            };
            (
                200,
                "application/vnd.apple.mpegurl",
                body.as_bytes().to_vec(),
                None,
            )
        }
        p if p.starts_with("/live/seg") && p.ends_with(".ts") => {
            reqs_clone.lock().unwrap().push(p.to_string());
            let idx = p["/live/seg".len()..p.len() - 3]
                .parse::<usize>()
                .unwrap_or(0);
            (200, "video/mp2t", seg_clone[idx].clone(), None)
        }
        _ => (404, "text/plain", b"not found".to_vec(), None),
    });

    let mut deck = StreamingDeck::new_deck(48000, 2, 1024).expect("Failed to create deck");
    let master_url = format!("{}/master.m3u8", base_url);
    let open_res = deck.open_network_with_cancel(&master_url, None, None);
    assert_eq!(open_res, 0, "Live master HLS stream must open cleanly");

    let session = deck
        .stream_session
        .read()
        .unwrap()
        .clone()
        .expect("StreamSession must exist for HLS stream");

    let deadline = Instant::now() + Duration::from_secs(6);
    while !session.body.is_eof() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
    }

    assert!(
        session.body.is_eof(),
        "Live HLS stream must reach EOF after #EXT-X-ENDLIST arrives via polling"
    );
    assert!(
        playlist_polls.load(Ordering::SeqCst) >= 3,
        "Expected at least 3 media playlist polls, got {}",
        playlist_polls.load(Ordering::SeqCst)
    );
    assert_eq!(
        *requested_segments.lock().unwrap(),
        vec![
            "/live/seg0.ts".to_string(),
            "/live/seg1.ts".to_string(),
            "/live/seg2.ts".to_string(),
            "/live/seg3.ts".to_string(),
        ]
    );
    assert_eq!(session.range_end(), expected_total_demuxed as u64);

    let _ = deck.stop();
    drop(deck);
    stop_srv.store(true, Ordering::Release);
    let _ = srv_handle.join();
}

#[test]
fn test_hls_byterange_http_206_and_200_fallback() {
    let seg_bytes: Vec<Vec<u8>> = (0..3)
        .map(|i| std::fs::read(FixtureResolver::resolve(&format!("hls/28_seg_{}.ts", i))).unwrap())
        .collect();
    let expected_total_demuxed: usize = seg_bytes
        .iter()
        .map(|b| MpegTsDemuxer::demux_segment(b).audio_bytes.len())
        .sum();

    let mut pack = Vec::new();
    let len0 = seg_bytes[0].len();
    let len1 = seg_bytes[1].len();
    let len2 = seg_bytes[2].len();
    pack.extend_from_slice(&seg_bytes[0]);
    pack.extend_from_slice(&seg_bytes[1]);
    pack.extend_from_slice(&seg_bytes[2]);

    let playlist_text = format!(
        "#EXTM3U\n\
#EXT-X-VERSION:4\n\
#EXT-X-TARGETDURATION:10\n\
#EXTINF:10.0,\n\
#EXT-X-BYTERANGE:{}@0\n\
pack.ts\n\
#EXTINF:10.0,\n\
#EXT-X-BYTERANGE:{}\n\
pack.ts\n\
#EXTINF:10.0,\n\
#EXT-X-BYTERANGE:{}@{}\n\
pack.ts\n\
#EXT-X-ENDLIST\n",
        len0,
        len1,
        len2,
        len0 + len1
    );

    for honor_range in [true, false] {
        let pack_clone = pack.clone();
        let pl_clone = playlist_text.as_bytes().to_vec();
        let seen_ranges = Arc::new(Mutex::new(Vec::<String>::new()));
        let seen_clone = seen_ranges.clone();

        let (base_url, stop_srv, srv_handle) = spawn_hls_test_server(move |path, range_hdr| {
            match path {
                "/byterange.m3u8" => (
                    200,
                    "application/vnd.apple.mpegurl",
                    pl_clone.clone(),
                    None,
                ),
                "/pack.ts" => {
                    if let Some(rh) = range_hdr {
                        seen_clone.lock().unwrap().push(rh.to_string());
                        if honor_range {
                            if let Some(spec) = rh.strip_prefix("bytes=") {
                                if let Some((s, e)) = spec.split_once('-') {
                                    let start: usize = s.parse().unwrap();
                                    let end_incl: usize = e.parse().unwrap();
                                    let slice = pack_clone[start..=end_incl].to_vec();
                                    let cr = format!(
                                        "bytes {}-{}/{}",
                                        start,
                                        end_incl,
                                        pack_clone.len()
                                    );
                                    return (206, "video/mp2t", slice, Some(cr));
                                }
                            }
                        }
                    }
                    (200, "video/mp2t", pack_clone.clone(), None)
                }
                _ => (404, "text/plain", b"not found".to_vec(), None),
            }
        });

        let mut deck = StreamingDeck::new_deck(48000, 2, 1024).expect("Failed to create deck");
        let url = format!("{}/byterange.m3u8", base_url);
        let res = deck.open_network_with_cancel(&url, None, None);
        assert_eq!(
            res, 0,
            "Byte-range HLS failed (honor_range={}): {}",
            honor_range, res
        );

        let session = deck
            .stream_session
            .read()
            .unwrap()
            .clone()
            .expect("StreamSession must exist");
        let deadline = Instant::now() + Duration::from_secs(4);
        while !session.body.is_eof() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(15));
        }

        assert!(session.body.is_eof());
        assert_eq!(
            session.range_end(),
            expected_total_demuxed as u64,
            "Demuxed payload size mismatch when honor_range={}",
            honor_range
        );
        assert_eq!(
            *seen_ranges.lock().unwrap(),
            vec![
                format!("bytes=0-{}", len0 - 1),
                format!("bytes={}-{}", len0, len0 + len1 - 1),
                format!("bytes={}-{}", len0 + len1, len0 + len1 + len2 - 1),
            ]
        );

        let _ = deck.stop();
        drop(deck);
        stop_srv.store(true, Ordering::Release);
        let _ = srv_handle.join();
    }
}

#[test]
fn test_hls_byterange_local_file_open_file() {
    let ts0 = std::fs::read(FixtureResolver::resolve("hls/28_seg_0.ts")).unwrap();
    let ts1 = std::fs::read(FixtureResolver::resolve("hls/28_seg_1.ts")).unwrap();

    let pack_path = FixtureResolver::scratch_file_path("hls_pack.ts");
    let m3u8_path = FixtureResolver::scratch_file_path("hls_byterange_local.m3u8");

    let mut pack = Vec::with_capacity(ts0.len() + ts1.len());
    pack.extend_from_slice(&ts0);
    pack.extend_from_slice(&ts1);
    std::fs::write(&pack_path, &pack).expect("Failed to write temp TS pack");

    let pack_name = pack_path.file_name().unwrap().to_string_lossy();
    let m3u8_content = format!(
        "#EXTM3U\n\
#EXT-X-VERSION:4\n\
#EXT-X-TARGETDURATION:10\n\
#EXTINF:10.0,\n\
#EXT-X-BYTERANGE:{}@0\n\
{}\n\
#EXTINF:10.0,\n\
#EXT-X-BYTERANGE:{}\n\
{}\n\
#EXT-X-ENDLIST\n",
        ts0.len(),
        pack_name,
        ts1.len(),
        pack_name
    );
    std::fs::write(&m3u8_path, m3u8_content).expect("Failed to write temp local m3u8");

    let mut deck = StreamingDeck::new_analysis_deck(48000, 2).expect("Failed to create deck");
    let res = deck.open_file(&m3u8_path.to_string_lossy());
    assert_eq!(res, 0, "Local byte-range m3u8 should open cleanly");

    let mut pcm = Vec::new();
    let has_audio = deck
        .decode_next_analysis_frame(&mut pcm)
        .expect("Decoding local byte-range HLS must succeed");
    assert!(has_audio && !pcm.is_empty());

    let _ = deck.stop();
    drop(deck);
    let _ = std::fs::remove_file(&m3u8_path);
    let _ = std::fs::remove_file(&pack_path);
}

#[test]
fn test_hls_dart_resolved_m3u8_asset_segments() {
    use miniaudio_player::api::types::RustResolvedSource;
    use miniaudio_player::buffer::DartResolveRegistry;
    use miniaudio_player::core::dual_source::{AudioSourceCore, DualSource};

    let requested_uris = Arc::new(Mutex::new(Vec::<String>::new()));
    let (tx, rx) = std::sync::mpsc::channel::<miniaudio_player::buffer::DartResolveRequest>();
    let requested_clone = requested_uris.clone();

    let registry = Arc::new(DartResolveRegistry::new(Arc::new(move |req| {
        requested_clone.lock().unwrap().push(req.source.clone());
        let _ = tx.send(req);
    })));

    let responder_reg = registry.clone();
    let responder_thread = std::thread::spawn(move || {
        while let Ok(req) = rx.recv() {
            let file_name = req.source.rsplit('/').next().unwrap_or("");
            let path = FixtureResolver::resolve(&format!("hls/{}", file_name));
            let bytes = std::fs::read(&path).unwrap_or_default();
            let ext = file_name.rsplit('.').next().map(|s| s.to_string());
            let _ = responder_reg.resolve_request(
                req.request_id,
                RustResolvedSource::Bytes {
                    data: bytes,
                    hint_ext: ext,
                },
            );
        }
    });

    let item = AudioSourceCore {
        id: 77,
        source: "asset://assets/music/hls/28_Разводят_мосты.m3u8".to_string(),
        headers: None,
        data_bytes: None,
        replay_gain_db: None,
        replay_peak: None,
        resolve_in_dart: true,
    };

    let mut deck = StreamingDeck::new_analysis_deck(48000, 2).expect("Failed to create deck");
    let res = DualSource::open_deck_with_pre_resolved(
        &mut deck,
        &item,
        None,
        None,
        Some(&registry),
        None,
    );
    assert_eq!(res, 0, "DartResolved HLS m3u8 + TS segments should open cleanly");

    let mut pcm = Vec::new();
    let has_audio = deck
        .decode_next_analysis_frame(&mut pcm)
        .expect("Decoding DartResolved HLS playlist must succeed");
    assert!(has_audio && !pcm.is_empty());

    let seen = requested_uris.lock().unwrap().clone();
    assert!(
        seen.iter().any(|u| u == "asset://assets/music/hls/28_Разводят_мосты.m3u8"),
        "Resolver should request m3u8 manifest, got: {:?}",
        seen
    );
    assert!(
        seen.iter().any(|u| u == "asset://assets/music/hls/28_seg_0.ts"),
        "Resolver should request 28_seg_0.ts segment, got: {:?}",
        seen
    );

    let _ = deck.stop();
    drop(deck);
    drop(registry);
    // Drop item/closure channel cleanly by clearing registry
    drop(responder_thread);
}

#[test]
fn test_e12_hls_vod_progressive_buffered_range() {
    use miniaudio_player::bridge::ffi::MiniaudioBufferedRange;

    let hls_dir = FixtureResolver::resolve("hls");
    let m3u8_bytes = std::fs::read(hls_dir.join("28_Разводят_мосты.m3u8")).unwrap();
    let mut seg_map = std::collections::HashMap::<String, Vec<u8>>::new();
    for entry in std::fs::read_dir(&hls_dir).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("28_seg_") && name.ends_with(".ts") {
            seg_map.insert(format!("/{}", name), std::fs::read(entry.path()).unwrap());
        }
    }
    assert!(
        seg_map.len() >= 10,
        "expected >=10 HLS TS segments for fixture, found {}",
        seg_map.len()
    );

    let m3u8_arc = Arc::new(m3u8_bytes);
    let seg_arc = Arc::new(seg_map);
    let (base_url, stop, srv_handle) = spawn_hls_test_server(move |path, _range| {
        if path == "/playlist.m3u8" {
            return (
                200,
                "application/vnd.apple.mpegurl",
                (*m3u8_arc).clone(),
                None,
            );
        }
        if let Some(bytes) = seg_arc.get(path) {
            std::thread::sleep(Duration::from_millis(20));
            return (200, "video/mp2t", bytes.clone(), None);
        }
        (404, "text/plain", b"not found".to_vec(), None)
    });

    let playlist_url = format!("{}/playlist.m3u8", base_url);
    let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
    assert_eq!(deck.open_network_with_cancel(&playlist_url, None, None), 0);

    let dur_ms = deck.duration_ms.load(Ordering::Relaxed);
    assert!(dur_ms > 100_000, "expected full VOD playlist duration, got {}", dur_ms);

    let mut initial_br = MiniaudioBufferedRange::default();
    assert_eq!(deck.get_buffered_range(&mut initial_br), 0);
    assert!(
        initial_br.end_ms > 0,
        "HLS VOD buffer must not remain at 0 - 0 after initial segment load (got {}..{})",
        initial_br.start_ms,
        initial_br.end_ms
    );

    deck.play();
    let mut max_end = initial_br.end_ms;
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(40));
        let mut br = MiniaudioBufferedRange::default();
        assert_eq!(deck.get_buffered_range(&mut br), 0);
        assert!(br.start_ms >= 0 && br.start_ms <= br.end_ms);
        assert!(br.end_ms <= dur_ms + 2_000);
        max_end = max_end.max(br.end_ms);
        if max_end > initial_br.end_ms + 15_000 {
            break;
        }
    }
    assert!(
        max_end > initial_br.end_ms + 10_000,
        "expected HLS VOD buffered end_ms to grow progressively from {} -> got max {}",
        initial_br.end_ms,
        max_end
    );

    let _ = deck.stop();
    drop(deck);
    stop.store(true, Ordering::Release);
    let _ = srv_handle.join();
}

#[test]
fn test_problems2_e9_hls_vod_block_lookahead_and_segment_seek() {
    use miniaudio_player::bridge::ffi::MiniaudioBufferedRange;
    use std::sync::Mutex;

    let hls_dir = FixtureResolver::resolve("hls");
    let m3u8_bytes = std::fs::read(hls_dir.join("28_Разводят_мосты.m3u8")).unwrap();
    let mut seg_map = std::collections::HashMap::<String, Vec<u8>>::new();
    for entry in std::fs::read_dir(&hls_dir).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("28_seg_") && name.ends_with(".ts") {
            seg_map.insert(format!("/{}", name), std::fs::read(entry.path()).unwrap());
        }
    }
    let total_segs = seg_map.len();
    assert!(total_segs >= 15, "expected >=15 TS segments, found {}", total_segs);

    let m3u8_arc = Arc::new(m3u8_bytes);
    let seg_arc = Arc::new(seg_map);
    let req_log = Arc::new(Mutex::new(Vec::<String>::new()));
    let req_log_srv = req_log.clone();

    let (base_url, stop, srv_handle) = spawn_hls_test_server(move |path, _range| {
        if path == "/playlist.m3u8" {
            return (
                200,
                "application/vnd.apple.mpegurl",
                (*m3u8_arc).clone(),
                None,
            );
        }
        if let Some(bytes) = seg_arc.get(path) {
            req_log_srv.lock().unwrap().push(path.to_string());
            std::thread::sleep(Duration::from_millis(15));
            return (200, "video/mp2t", bytes.clone(), None);
        }
        (404, "text/plain", b"not found".to_vec(), None)
    });

    let playlist_url = format!("{}/playlist.m3u8", base_url);
    let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
    assert_eq!(deck.open_network_with_cancel(&playlist_url, None, None), 0);

    // Wait 1.0s while idle: bounded lookahead (~30s) must NOT eagerly download all 19 segments.
    std::thread::sleep(Duration::from_millis(1000));
    let initial_reqs = req_log.lock().unwrap().clone();
    assert!(
        initial_reqs.len() <= 5,
        "E9: HLS VOD eagerly downloaded {} / {} segments at open: {:?}",
        initial_reqs.len(),
        total_segs,
        initial_reqs
    );
    let mut initial_br = MiniaudioBufferedRange::default();
    assert_eq!(deck.get_buffered_range(&mut initial_br), 0);
    assert!(
        initial_br.end_ms >= 25_000 && initial_br.end_ms <= 45_000,
        "expected ~30-40s initial VOD lookahead, got {}..{}",
        initial_br.start_ms,
        initial_br.end_ms
    );

    // Jump straight to 120s (far past lookahead) and verify playback produces clean PCM near 120s.
    deck.play();
    assert_eq!(deck.seek(120_000), 0);
    let mut out = vec![0.0f32; 2048];
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut heard = false;
    while Instant::now() < deadline {
        deck.render_pcm(out.as_mut_ptr(), 1024);
        let pos = deck.position_ms.load(Ordering::Relaxed);
        let peak = out.iter().fold(0.0f32, |m, &x| m.max(x.abs()));
        if peak > 0.001 && pos >= 118_000 && pos <= 123_000 {
            heard = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        heard,
        "E9: HLS VOD seek(120000) did not produce audible audio at 120s (pos={})",
        deck.position_ms.load(Ordering::Relaxed)
    );

    let mut br_after_jump = MiniaudioBufferedRange::default();
    assert_eq!(deck.get_buffered_range(&mut br_after_jump), 0);
    assert!(
        br_after_jump.start_ms >= 110_000 && br_after_jump.start_ms <= 120_000,
        "E9: post-jump buffered range start_ms expected near 116s, got {}..{}",
        br_after_jump.start_ms,
        br_after_jump.end_ms
    );

    // Skipped middle segments must NEVER have been downloaded.
    let all_reqs_after_jump = req_log.lock().unwrap().clone();
    for skipped in ["/28_seg_6.ts", "/28_seg_7.ts", "/28_seg_8.ts", "/28_seg_9.ts"] {
        assert!(
            !all_reqs_after_jump.iter().any(|r| r == skipped),
            "E9: middle skipped segment {} was downloaded during seek to 120s: {:?}",
            skipped,
            all_reqs_after_jump
        );
    }

    // Wait briefly so cached_segments settles, then seek back to 10s (seg 1 cached in RAM = 0 extra HTTP).
    std::thread::sleep(Duration::from_millis(200));
    let reqs_before_back = req_log.lock().unwrap().len();
    assert_eq!(deck.seek(10_000), 0);
    let back_deadline = Instant::now() + Duration::from_secs(3);
    let mut back_ok = false;
    while Instant::now() < back_deadline {
        deck.render_pcm(out.as_mut_ptr(), 1024);
        let pos = deck.position_ms.load(Ordering::Relaxed);
        let peak = out.iter().fold(0.0f32, |m, &x| m.max(x.abs()));
        if peak > 0.001 && (9_000..=14_000).contains(&pos) {
            back_ok = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        back_ok,
        "E9: backward seek(10000) failed after jump to 120s (pos={})",
        deck.position_ms.load(Ordering::Relaxed)
    );
    let reqs_after_back = req_log.lock().unwrap().clone();
    let new_reqs = &reqs_after_back[reqs_before_back..];
    assert!(
        !new_reqs.iter().any(|r| r == "/28_seg_1.ts"),
        "E9: expected cached seg 1 NOT to be re-fetched over HTTP after backward seek(10s): {:?}",
        new_reqs
    );
    assert!(
        new_reqs.len() <= 2,
        "E9: expected at most lookahead seg 4 / in-flight seg 15 on backward seek(10s), got {:?}",
        new_reqs
    );

    let _ = deck.stop();
    drop(deck);
    stop.store(true, Ordering::Release);
    let _ = srv_handle.join();
}

fn load_valid_adts_frames_chunk(min_bytes: usize) -> Vec<u8> {
    let raw = std::fs::read(FixtureResolver::resolve("10_La_cicatriz_del_andén.aac"))
        .expect("read AAC fixture");
    let mut off = 0usize;
    if raw.len() >= 10 && &raw[..3] == b"ID3" {
        let size = (((raw[6] as usize) & 0x7F) << 21)
            | (((raw[7] as usize) & 0x7F) << 14)
            | (((raw[8] as usize) & 0x7F) << 7)
            | ((raw[9] as usize) & 0x7F);
        let footer = if (raw[5] & 0x10) != 0 { 10 } else { 0 };
        off = (10 + size + footer).min(raw.len());
    }
    while off + 7 <= raw.len() {
        if raw[off] == 0xFF && (raw[off + 1] & 0xF6) == 0xF0 {
            break;
        }
        off += 1;
    }
    let mut single_pass = Vec::new();
    let mut cursor = off;
    while cursor + 7 <= raw.len() && single_pass.len() < 8192 {
        if raw[cursor] != 0xFF || (raw[cursor + 1] & 0xF6) != 0xF0 {
            break;
        }
        let frame_len = ((((raw[cursor + 3] as usize) & 0x03) << 11)
            | ((raw[cursor + 4] as usize) << 3)
            | (((raw[cursor + 5] as usize) >> 5) & 0x07))
            .max(7);
        if cursor + frame_len > raw.len() {
            break;
        }
        single_pass.extend_from_slice(&raw[cursor..cursor + frame_len]);
        cursor += frame_len;
    }
    assert!(
        !single_pass.is_empty(),
        "expected valid ADTS frames in 10_La_cicatriz_del_andén.aac"
    );
    let mut out = Vec::with_capacity(min_bytes.max(single_pass.len()));
    while out.len() < min_bytes {
        out.extend_from_slice(&single_pass);
    }
    out
}

fn build_id3v24_aac_segment(title: &str, artist: &str, adts_audio: &[u8]) -> Vec<u8> {
    fn enc_ss(v: u32) -> [u8; 4] {
        [
            ((v >> 21) & 0x7F) as u8,
            ((v >> 14) & 0x7F) as u8,
            ((v >> 7) & 0x7F) as u8,
            (v & 0x7F) as u8,
        ]
    }
    let mut frames = Vec::new();
    for (id, text) in [(b"TIT2", title), (b"TPE1", artist)] {
        let len = (1 + text.len()) as u32;
        frames.extend_from_slice(id);
        frames.extend_from_slice(&enc_ss(len));
        frames.extend_from_slice(&[0x00, 0x00, 0x03]);
        frames.extend_from_slice(text.as_bytes());
    }
    let mut seg = Vec::with_capacity(10 + frames.len() + adts_audio.len());
    seg.extend_from_slice(b"ID3\x04\x00\x00");
    seg.extend_from_slice(&enc_ss(frames.len() as u32));
    seg.extend_from_slice(&frames);
    seg.extend_from_slice(adts_audio);
    seg
}

#[test]
fn test_mediastream_resolve_hls_triple_slash_uri() {
    let base = "https://us-b4-p-e-zs14-audio.cdn.mdstrm.com/live-audio-aw/6839e1c82cc4c480fcd318dd/playlist.m3u8";
    let seg = ":///live-audio-aw/6839e1c82cc4c480fcd318dd/seg.aac";
    assert_eq!(
        resolve_hls_uri(base, seg),
        "https://us-b4-p-e-zs14-audio.cdn.mdstrm.com/live-audio-aw/6839e1c82cc4c480fcd318dd/seg.aac"
    );
}

#[test]
fn test_parse_hls_extinf_metadata_variants() {
    assert_eq!(
        parse_hls_extinf_metadata("title=\"Moda\""),
        Some(HlsExtinfMetadata {
            title: Some("Moda".to_string()),
            artist: None,
        })
    );
    assert_eq!(
        parse_hls_extinf_metadata("title=\"Soy igual que tu\",artist=\"Alexis y Fido\""),
        Some(HlsExtinfMetadata {
            title: Some("Soy igual que tu".to_string()),
            artist: Some("Alexis y Fido".to_string()),
        })
    );
    assert_eq!(parse_hls_extinf_metadata("ADWSRTAG_START"), None);
    assert_eq!(
        parse_hls_extinf_metadata("title=\"ADWSRTAG_END\""),
        None
    );
    assert_eq!(
        parse_hls_extinf_metadata("Just A Song Title"),
        Some(HlsExtinfMetadata {
            title: Some("Just A Song Title".to_string()),
            artist: None,
        })
    );
    assert_eq!(
        parse_hls_extinf_metadata("title=\"Hello, \\\"World\\\"\",artist=\"A & B\""),
        Some(HlsExtinfMetadata {
            title: Some("Hello, \"World\"".to_string()),
            artist: Some("A & B".to_string()),
        })
    );

    let playlist = b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:42\n\
#EXTINF:4.992,title=\"Soy igual que tu\",artist=\"Alexis y Fido\"\n\
:///live-audio-aw/6598b65ab398c90871aff8cc/seg.aac\n";
    match M3u8Parser::parse(playlist).expect("M3U8 with EXTINF commas should parse") {
        ParsedHlsPlaylist::Media { segments, .. } => {
            assert_eq!(segments.len(), 1);
            assert_eq!(
                segments[0].uri,
                ":///live-audio-aw/6598b65ab398c90871aff8cc/seg.aac"
            );
            assert_eq!(
                segments[0].title.as_deref(),
                Some("title=\"Soy igual que tu\",artist=\"Alexis y Fido\"")
            );
        }
        _ => panic!("Expected Media playlist"),
    }
}

#[test]
fn test_derive_companion_hls_metadata_urls() {
    let moda = "https://us-b4-p-e-zs14-audio.cdn.mdstrm.com/live-audio-aw/6839e1c82cc4c480fcd318dd";
    let moda_urls = derive_companion_hls_metadata_urls(moda, None);
    assert!(
        moda_urls.contains(&"https://us-b4-p-e-zs14-audio.cdn.mdstrm.com/live-audio-aw/6839e1c82cc4c480fcd318dd/playlist.m3u8".to_string()),
        "expected edge playlist.m3u8 in {:?}",
        moda_urls
    );
    assert!(
        moda_urls.contains(&"https://mdstrm.com/live-stream-playlist/6839e1c82cc4c480fcd318dd.m3u8".to_string()),
        "expected live-stream-playlist in {:?}",
        moda_urls
    );

    let onda = "https://mdstrm.com/audio/6598b65ab398c90871aff8cc/icecast.audio";
    let onda_only = derive_companion_hls_metadata_urls(onda, None);
    assert_eq!(
        onda_only,
        vec!["https://mdstrm.com/live-stream-playlist/6598b65ab398c90871aff8cc.m3u8".to_string()]
    );

    let onda_final = "https://us-b4-p-e-zs14-audio.cdn.mdstrm.com/live-audio-aw/6598b65ab398c90871aff8cc";
    let onda_both = derive_companion_hls_metadata_urls(onda, Some(onda_final));
    assert!(
        onda_both.contains(&"https://us-b4-p-e-zs14-audio.cdn.mdstrm.com/live-audio-aw/6598b65ab398c90871aff8cc/playlist.m3u8".to_string()),
        "expected edge URL derived from final_url in {:?}",
        onda_both
    );
    assert!(
        onda_both.contains(&"https://mdstrm.com/live-stream-playlist/6598b65ab398c90871aff8cc.m3u8".to_string()),
        "expected origin URL in {:?}",
        onda_both
    );

    assert!(derive_companion_hls_metadata_urls("https://example.com/live/radio.mp3", None).is_empty());
}

#[test]
fn test_live_hls_aac_extinf_and_id3_static_and_dynamic_metadata() {
    let adts = load_valid_adts_frames_chunk(20_000);
    let seg1 = build_id3v24_aac_segment("Song One", "Artist One", &adts);
    let seg2 = build_id3v24_aac_segment("Song Two", "Artist Two", &adts);
    let seg3 = build_id3v24_aac_segment("Song Two", "Artist Two", &adts);

    let dyn_polls = Arc::new(AtomicUsize::new(0));
    let dyn_polls_srv = dyn_polls.clone();

    let (base_url, stop, srv_handle) = spawn_hls_test_server(move |path, _range| match path {
        "/static/playlist.m3u8" => (
            200,
            "application/vnd.apple.mpegurl",
            b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:10\n\
#EXTINF:1.0,title=\"Song One\",artist=\"Artist One\"\n/seg1.aac\n"
                .to_vec(),
            None,
        ),
        "/dynamic/playlist.m3u8" => {
            let poll = dyn_polls_srv.fetch_add(1, Ordering::AcqRel);
            if poll == 0 {
                (
                    200,
                    "application/vnd.apple.mpegurl",
                    b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:10\n\
#EXTINF:1.0,title=\"Song One\",artist=\"Artist One\"\n/seg1.aac\n"
                        .to_vec(),
                    None,
                )
            } else {
                (
                    200,
                    "application/vnd.apple.mpegurl",
                    b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:11\n\
#EXTINF:1.0,title=\"Song Two\",artist=\"Artist Two\"\n/seg2.aac\n\
#EXTINF:1.0,title=\"Song Two\",artist=\"Artist Two\"\n/seg3.aac\n"
                        .to_vec(),
                    None,
                )
            }
        }
        "/seg1.aac" => (200, "audio/aac", seg1.clone(), None),
        "/seg2.aac" => (200, "audio/aac", seg2.clone(), None),
        "/seg3.aac" => (200, "audio/aac", seg3.clone(), None),
        _ => (404, "text/plain", b"Not Found".to_vec(), None),
    });

    // 1. Static analysis returns Song One / Artist One quickly on live HLS.
    let static_url = format!("{}/static/playlist.m3u8", base_url);
    let analysis_start = Instant::now();
    let res = analyze_audio_source(
        AudioSourceCore {
            id: 101,
            source: static_url,
            ..Default::default()
        },
        RustAnalysisConfig {
            metadata: true,
            replay_gain: true,
            waveform: true,
            ..Default::default()
        },
    )
    .expect("live HLS static analysis should succeed");
    assert!(
        analysis_start.elapsed() < Duration::from_secs(3),
        "live HLS static analysis took too long: {:?}",
        analysis_start.elapsed()
    );
    assert!(res.audio_info.duration_ms.is_none());
    let static_meta = res.metadata.expect("expected static metadata");
    assert_eq!(static_meta.title.as_deref(), Some("Song One"));
    assert_eq!(static_meta.track_artist.as_deref(), Some("Artist One"));

    // 2. Live playback loads initial Song One then updates dynamically to Song Two.
    let dyn_url = format!("{}/dynamic/playlist.m3u8", base_url);
    let mut deck = StreamingDeck::new_deck(44100, 2, 1024).unwrap();
    assert_eq!(deck.open_network_with_cancel(&dyn_url, None, None), 0);
    let init_meta = deck
        .get_parsed_metadata()
        .expect("expected initial live HLS metadata");
    assert_eq!(init_meta.title.as_deref(), Some("Song One"));
    assert_eq!(init_meta.track_artist.as_deref(), Some("Artist One"));

    deck.play();
    let mut out = vec![0.0f32; 2048];
    let deadline = Instant::now() + Duration::from_secs(6);
    let mut updated = false;
    while Instant::now() < deadline {
        deck.render_pcm(out.as_mut_ptr(), 1024);
        if let Some(m) = deck.get_parsed_metadata() {
            if m.title.as_deref() == Some("Song Two")
                && m.track_artist.as_deref() == Some("Artist Two")
            {
                updated = true;
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(updated, "live HLS deck did not update dynamic metadata to Song Two");

    let _ = deck.stop();
    drop(deck);
    stop.store(true, Ordering::Release);
    let _ = srv_handle.join();
}
