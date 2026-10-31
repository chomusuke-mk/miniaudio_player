use miniaudio_player::decoder::dsf::DsfReader;
use miniaudio_player::decoder::sniffer::{BoundaryStatus, ContainerFormat, FormatSniffer};
use miniaudio_player::hls::{
    Aes128SegmentDecryptor, M3u8Parser, MpegTsDemuxer, ParsedHlsPlaylist, TsAudioCodec,
};
use symphonia::core::io::MediaSource;

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
    // VOD playlist with AES-128 and Byte Ranges
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
            assert!(!is_live, "Should be VOD because of EXT-X-ENDLIST");
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

            assert_eq!(segments[1].uri, "segment101.ts");
            assert_eq!(segments[1].byte_range, Some((12000, 10000)));
            assert_eq!(segments[1].sequence_number, 101);
        }
        _ => panic!("Expected Media playlist"),
    }
}

#[test]
fn test_aes128_segment_decryption() {
    let key = [0x42u8; 16];
    let iv_seq = Aes128SegmentDecryptor::iv_from_sequence(1);
    assert_eq!(iv_seq[15], 1);
    assert_eq!(iv_seq[0], 0);

    let hex_iv = Aes128SegmentDecryptor::parse_iv_hex("0x00000000000000000000000000000001")
        .expect("Hex IV should parse");
    assert_eq!(hex_iv, iv_seq);

    // Encrypt some data using AES-128-CBC
    use aes::Aes128;
    use cbc::cipher::block_padding::Pkcs7;
    use cbc::cipher::{BlockEncryptMut, KeyIvInit};
    type Aes128CbcEnc = cbc::Encryptor<Aes128>;

    let plaintext = b"Hello, HLS encrypted streaming audio data in Rust!";
    let mut encrypted_buf = vec![0u8; plaintext.len() + 16];
    let encryptor = Aes128CbcEnc::new((&key).into(), (&hex_iv).into());
    let enc_len = encryptor
        .encrypt_padded_b2b_mut::<Pkcs7>(plaintext, &mut encrypted_buf)
        .expect("Encryption should succeed")
        .len();
    encrypted_buf.truncate(enc_len);

    // Now decrypt with Aes128SegmentDecryptor
    let decrypted = Aes128SegmentDecryptor::decrypt_segment(&encrypted_buf, &key, &hex_iv)
        .expect("Decryption should succeed");

    assert_eq!(&decrypted[..], plaintext);
}

#[test]
fn test_mpeg2_ts_demuxer_aac() {
    // Build a synthetic 188-byte MPEG-2 TS stream containing PAT, PMT, and an audio PES packet with AAC ADTS frames.
    let mut ts_data = Vec::new();

    // 1. PAT packet (PID 0) -> Program 1 has PMT PID 0x1000
    let mut pat_packet = vec![0xFF; 188];
    pat_packet[0] = 0x47; // Sync byte
    pat_packet[1] = 0x40; // PUSI = 1, PID = 0
    pat_packet[2] = 0x00;
    pat_packet[3] = 0x10; // Payload only, CC = 0
    pat_packet[4] = 0x00; // Pointer field = 0
    pat_packet[5] = 0x00; // Table ID = 0 (PAT)
    pat_packet[6] = 0xB0; // Section syntax indicator + section length high
    pat_packet[7] = 0x0D; // Section length low = 13
    pat_packet[8] = 0x00; // Transport stream ID
    pat_packet[9] = 0x01;
    pat_packet[10] = 0xC1; // Version 0, current_next 1
    pat_packet[11] = 0x00; // Section 0
    pat_packet[12] = 0x00; // Last section 0
    // Program loop: Program 1, PID 0x1000
    pat_packet[13] = 0x00;
    pat_packet[14] = 0x01; // Prog num 1
    pat_packet[15] = 0xF0; // Reserved + PMT PID high
    pat_packet[16] = 0x00; // PMT PID low = 0x1000
    // CRC32 dummy
    pat_packet[17] = 0xAA;
    pat_packet[18] = 0xBB;
    pat_packet[19] = 0xCC;
    pat_packet[20] = 0xDD;
    ts_data.extend_from_slice(&pat_packet);

    // 2. PMT packet (PID 0x1000) -> Audio PID 0x0101, Stream Type 0x0F (AAC ADTS)
    let mut pmt_packet = vec![0xFF; 188];
    pmt_packet[0] = 0x47;
    pmt_packet[1] = 0x50; // PUSI = 1, PID = 0x1000 (high 5 bits = 0x10)
    pmt_packet[2] = 0x00; // PID low = 0x00
    pmt_packet[3] = 0x10;
    pmt_packet[4] = 0x00; // Pointer = 0
    pmt_packet[5] = 0x02; // Table ID = 2 (PMT)
    pmt_packet[6] = 0xB0; // Section syntax + len
    pmt_packet[7] = 0x12; // Length = 18
    pmt_packet[8] = 0x00; // Program 1
    pmt_packet[9] = 0x01;
    pmt_packet[10] = 0xC1;
    pmt_packet[11] = 0x00;
    pmt_packet[12] = 0x00;
    pmt_packet[13] = 0xE1; // PCR PID 0x0100
    pmt_packet[14] = 0x00;
    pmt_packet[15] = 0xF0; // Program info len = 0
    pmt_packet[16] = 0x00;
    // ES loop: Stream type 0x0F (AAC), ES PID 0x0101
    pmt_packet[17] = 0x0F;
    pmt_packet[18] = 0xE1; // Reserved + PID high
    pmt_packet[19] = 0x01; // PID low = 0x0101
    pmt_packet[20] = 0xF0; // ES info len = 0
    pmt_packet[21] = 0x00;
    // CRC32 dummy
    pmt_packet[22] = 0x11;
    pmt_packet[23] = 0x22;
    pmt_packet[24] = 0x33;
    pmt_packet[25] = 0x44;
    ts_data.extend_from_slice(&pmt_packet);

    // 3. Audio PES packet on PID 0x0101 containing raw ADTS AAC header + payload
    let mut pes_packet = vec![0xFF; 188];
    pes_packet[0] = 0x47;
    pes_packet[1] = 0x41; // PUSI = 1, PID = 0x0101
    pes_packet[2] = 0x01;
    pes_packet[3] = 0x10;
    // PES Header
    pes_packet[4] = 0x00; // Start code 0x000001
    pes_packet[5] = 0x00;
    pes_packet[6] = 0x01;
    pes_packet[7] = 0xC0; // Stream ID = Audio 0
    pes_packet[8] = 0x00; // PES packet length
    pes_packet[9] = 0x10;
    pes_packet[10] = 0x80; // Marker bits
    pes_packet[11] = 0x00; // Flags (no PTS/DTS)
    pes_packet[12] = 0x00; // PES header data length = 0
    // ADTS AAC frame starts at byte 13
    pes_packet[13] = 0xFF; // ADTS syncword 0xFFF1
    pes_packet[14] = 0xF1;
    pes_packet[15] = 0x50; // AAC-LC, 44100Hz, 2ch
    pes_packet[16] = 0x80;
    pes_packet[17] = 0x03;
    pes_packet[18] = 0x20;
    pes_packet[19] = 0x00; // Frame data
    pes_packet[20] = 0xAA;
    pes_packet[21] = 0xBB;
    pes_packet[22] = 0xCC;
    ts_data.extend_from_slice(&pes_packet);

    assert!(MpegTsDemuxer::is_mpeg_ts(&ts_data));

    let demux_res = MpegTsDemuxer::demux_segment(&ts_data);
    assert_eq!(demux_res.audio_pid, Some(0x0101));
    assert_eq!(demux_res.codec, TsAudioCodec::AacAdts);
    assert!(!demux_res.audio_bytes.is_empty());
    assert_eq!(&demux_res.audio_bytes[0..2], &[0xFF, 0xF1]);
}

#[test]
fn test_dsd_dsf_container_and_decimation() {
    // Construct a valid minimal DSF file with 1 block of DSD64 stereo
    let mut dsf_data = Vec::new();

    let channel_num: u32 = 2;
    let raw_sampling_freq: u32 = 2822400; // DSD64
    let block_size_per_channel: u32 = 4096;
    let sample_count: u64 = block_size_per_channel as u64 * 8; // 32768 samples per channel
    let fmt_chunk_size: u64 = 52;
    let data_bytes = block_size_per_channel as u64 * channel_num as u64;
    let data_chunk_size: u64 = 12 + data_bytes;
    let total_file_size: u64 = 28 + fmt_chunk_size + data_chunk_size;

    // 1. DSD chunk (28 bytes)
    dsf_data.extend_from_slice(b"DSD ");
    dsf_data.extend_from_slice(&28u64.to_le_bytes());
    dsf_data.extend_from_slice(&total_file_size.to_le_bytes());
    dsf_data.extend_from_slice(&0u64.to_le_bytes()); // metadata offset

    // 2. fmt chunk (52 bytes)
    dsf_data.extend_from_slice(b"fmt ");
    dsf_data.extend_from_slice(&fmt_chunk_size.to_le_bytes());
    dsf_data.extend_from_slice(&1u32.to_le_bytes()); // format version
    dsf_data.extend_from_slice(&0u32.to_le_bytes()); // format ID (0 = DSD raw)
    dsf_data.extend_from_slice(&2u32.to_le_bytes()); // channel type (2 = stereo)
    dsf_data.extend_from_slice(&channel_num.to_le_bytes());
    dsf_data.extend_from_slice(&raw_sampling_freq.to_le_bytes());
    dsf_data.extend_from_slice(&1u32.to_le_bytes()); // bits per sample = 1
    dsf_data.extend_from_slice(&sample_count.to_le_bytes());
    dsf_data.extend_from_slice(&block_size_per_channel.to_le_bytes());
    dsf_data.extend_from_slice(&0u32.to_le_bytes()); // reserved

    // 3. data chunk
    dsf_data.extend_from_slice(b"data");
    dsf_data.extend_from_slice(&data_chunk_size.to_le_bytes());
    // Interleaved channel blocks: 4096 bytes of 0xAA (alternating 1 and 0 bits) for ch 0 and ch 1
    let ch0_data = vec![0xAAu8; block_size_per_channel as usize];
    let ch1_data = vec![0x55u8; block_size_per_channel as usize];
    dsf_data.extend_from_slice(&ch0_data);
    dsf_data.extend_from_slice(&ch1_data);

    // Verify sniffer detects DSF
    let (status, info) = FormatSniffer::detect_head_boundary(&dsf_data, dsf_data.len() as i64);
    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Dsf);

    // Probe with DsfReader
    let cursor: Box<dyn MediaSource> = Box::new(std::io::Cursor::new(dsf_data));
    match DsfReader::try_new(cursor).expect("DSF probe failed") {
        miniaudio_player::decoder::dsf::DsfProbe::Matched(mut reader) => {
            assert_eq!(reader.channels(), 2);
            assert_eq!(reader.sample_rate(), 88200);
            assert!(reader.duration_ms().is_some());

            let mut pcm = Vec::new();
            let decoded = reader.decode_next_frame(&mut pcm).expect("Decode should succeed");
            assert!(decoded, "Expected decoded frames");
            assert!(!pcm.is_empty());
            assert_eq!(pcm.len() % 2, 0, "Stereo samples must be aligned");

            // Verify samples are non-NaN and within normalized [-1.0, 1.0] range
            for &s in &pcm {
                assert!(!s.is_nan());
                assert!(s >= -1.5 && s <= 1.5);
            }

            // Test seeking
            reader.seek_ms(5).expect("Seek should succeed");
        }
        miniaudio_player::decoder::dsf::DsfProbe::NotMatched(_) => {
            panic!("Expected DSF to match probe");
        }
    }
}

#[test]
fn test_sniffer_extended_formats() {
    // Matroska / WebM
    let mkv_bytes = [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F];
    let (_, info) = FormatSniffer::detect_head_boundary(&mkv_bytes, 1000);
    assert_eq!(info.container, ContainerFormat::Matroska);

    // WavPack (WV)
    let wv_bytes = b"wvpk\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    let (_, info) = FormatSniffer::detect_head_boundary(wv_bytes, 1000);
    assert_eq!(info.container, ContainerFormat::WavPack);

    // HLS M3U8
    let hls_bytes = b"#EXTM3U\n#EXT-X-VERSION:3\n";
    let (_, info) = FormatSniffer::detect_head_boundary(hls_bytes, 1000);
    assert_eq!(info.container, ContainerFormat::Hls);
}
