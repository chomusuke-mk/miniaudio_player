//! HLS Playlist Parsing, AES-128-CBC Segment Decryption, and MPEG-2 TS Demuxing Tests.

mod common;

use std::fs::File;
use std::io::Read;

use common::FixtureResolver;
use miniaudio_player::decoder::SymphoniaEngine;
use miniaudio_player::hls::{
    Aes128SegmentDecryptor, M3u8Parser, MpegTsDemuxer, ParsedHlsPlaylist, TsAudioCodec,
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
fn test_aes128_cbc_pkcs7_and_no_padding_decryption() {
    use aes::Aes128;
    use cbc::cipher::block_padding::{NoPadding, Pkcs7};
    use cbc::cipher::{BlockEncryptMut, KeyIvInit};
    type Aes128CbcEnc = cbc::Encryptor<Aes128>;

    let key = [0x42u8; 16];
    let iv = Aes128SegmentDecryptor::iv_from_sequence(1);
    assert_eq!(iv[15], 1);
    assert_eq!(iv[0], 0);

    let hex_iv = Aes128SegmentDecryptor::parse_iv_hex("0x00000000000000000000000000000001")
        .expect("Hex IV should parse");
    assert_eq!(hex_iv, iv);

    // 1. PKCS#7 padded encryption & decryption
    let plaintext = b"Hello, HLS encrypted streaming audio data in Rust!";
    let mut encrypted_buf = vec![0u8; plaintext.len() + 16];
    let encryptor = Aes128CbcEnc::new((&key).into(), (&hex_iv).into());
    let enc_len = encryptor
        .encrypt_padded_b2b_mut::<Pkcs7>(plaintext, &mut encrypted_buf)
        .expect("Encryption should succeed")
        .len();
    encrypted_buf.truncate(enc_len);

    let decrypted = Aes128SegmentDecryptor::decrypt_segment(&encrypted_buf, &key, &hex_iv)
        .expect("PKCS#7 decryption should succeed");
    assert_eq!(&decrypted[..], plaintext);

    // 2. Multi-block unpadded CBC encryption & decryption (verifying true CBC chaining across blocks)
    let raw_blocks = [0xAAu8; 64]; // 4 blocks of 16 bytes
    let mut enc_blocks = [0u8; 64];
    let enc_no_pad = Aes128CbcEnc::new((&key).into(), (&hex_iv).into());
    enc_no_pad
        .encrypt_padded_b2b_mut::<NoPadding>(&raw_blocks, &mut enc_blocks)
        .unwrap();

    let dec_no_pad =
        Aes128SegmentDecryptor::decrypt_segment_no_padding(&enc_blocks, &key, &hex_iv)
            .expect("NoPadding CBC decryption should succeed");
    assert_eq!(&dec_no_pad[..], &raw_blocks[..]);
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
    let m3u8_path = FixtureResolver::resolve("salida.m3u8");
    let mut m3u8_file = File::open(&m3u8_path).expect("Failed to open salida.m3u8");
    let mut m3u8_bytes = Vec::new();
    m3u8_file.read_to_end(&mut m3u8_bytes).unwrap();

    assert!(M3u8Parser::is_m3u8(&m3u8_bytes));

    let parsed = M3u8Parser::parse(&m3u8_bytes).expect("Failed to parse salida.m3u8");
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
            assert_eq!(segments.len(), 7);
            assert!(total_duration_seconds >= 65.0 && total_duration_seconds <= 75.0);

            for seg in &segments {
                let ts_path = FixtureResolver::resolve(&seg.uri);
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

    // Decode demuxed segment 0 with SymphoniaEngine
    let ts0_bytes = std::fs::read(FixtureResolver::resolve("salida_0.ts")).unwrap();
    let demux0 = MpegTsDemuxer::demux_segment(&ts0_bytes);
    let cursor = std::io::Cursor::new(demux0.audio_bytes);
    let mut aac_engine = SymphoniaEngine::new(cursor, Some("aac")).expect("Failed to open demuxed AAC");
    assert_eq!(aac_engine.channels(), 2);
    assert_eq!(aac_engine.sample_rate(), 48000);

    let mut pcm = Vec::new();
    assert!(aac_engine.decode_next_frame(&mut pcm).unwrap());
    assert!(!pcm.is_empty());
}
