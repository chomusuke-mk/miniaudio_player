//! Comprehensive Format Sniffer, Decoder Engine, and All-Format Fixture Validation Suite.
//!
//! Validates all 27 root audio container/codec fixtures listed in `test/MANIFEST.md`
//! using strictly relative path resolution via `FixtureResolver`.

mod common;

use std::fs::File;
use std::io::{Read, Seek};

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::buffer::{DemuxedStreamReader, StreamSession};
use miniaudio_player::decoder::classifier::{BoundaryStatus, ContainerFormat, StreamClassifier};
use miniaudio_player::decoder::dsf::{DsfProbe, DsfReader};
use miniaudio_player::decoder::symphonia_engine::{create_codec_registry, SymphoniaEngine};
use miniaudio_player::dsp::channel_matrix::ChannelMatrix;
use miniaudio_player::dsp::resampler::RubatoResampler;
use miniaudio_player::sync::ring_buffer::AudioRingBuffer;
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::io::MediaSource;

#[test]
fn test_classifier_wav_and_id3v1_tail_detection() {
    let wav_data = SignalGenerator::pcm16_wav_bytes(500, 48000, 2);
    let (status, info) = StreamClassifier::detect_head_boundary(&wav_data, wav_data.len() as i64);

    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Wav);
    assert_eq!(info.audio_start, 44);
    assert_eq!(info.audio_end, wav_data.len() as i64);

    // ID3v1 tail stripping
    let mut data = vec![0u8; 1000];
    let mut id3v1 = vec![0u8; 128];
    id3v1[0] = b'T';
    id3v1[1] = b'A';
    id3v1[2] = b'G';
    data.extend_from_slice(&id3v1);

    let total_size = data.len() as i64;
    let tail_offset = total_size - 256;
    let tail = &data[tail_offset as usize..];

    let (t_status, audio_end) = StreamClassifier::detect_tail_boundary(
        ContainerFormat::Mp3,
        tail,
        tail_offset,
        total_size,
        0,
    );
    assert_eq!(t_status, BoundaryStatus::Found);
    assert_eq!(audio_end, 1000);
}

#[test]
fn test_symphonia_registry_and_synthetic_wav_stream() {
    let registry = create_codec_registry();
    assert!(registry.get_audio_decoder(CODEC_ID_OPUS).is_some());

    let sample_rate = 48000;
    let channels = 2;
    let num_frames = 4800;
    let wav_bytes = SignalGenerator::pcm16_wav_bytes(num_frames, sample_rate, channels);

    let buf = StreamSession::new(wav_bytes.len(), Some(wav_bytes.len() as u64), false);
    buf.head.set_linear_bytes(&wav_bytes[0..44]);
    buf.set_audio_start(44);
    buf.set_audio_end(wav_bytes.len() as u64);
    buf.feed_chunk(&wav_bytes[44..]).unwrap();
    buf.mark_eof();

    let reader = DemuxedStreamReader::new(buf);
    let mut engine = SymphoniaEngine::new(reader, Some("wav")).unwrap();

    assert_eq!(engine.sample_rate(), sample_rate);
    assert_eq!(engine.channels(), channels as u32);

    let mut decoded_samples = Vec::new();
    let mut total_decoded_frames = 0;
    while let Ok(true) = engine.decode_next_frame(&mut decoded_samples) {
        total_decoded_frames += decoded_samples.len() / (channels as usize);
    }
    assert_eq!(total_decoded_frames, num_frames);
}

#[test]
fn test_synthetic_dsd_dsf_decimation() {
    let mut dsf_data = Vec::new();
    let channel_num: u32 = 2;
    let raw_sampling_freq: u32 = 2822400;
    let block_size_per_channel: u32 = 4096;
    let sample_count: u64 = block_size_per_channel as u64 * 8;
    let fmt_chunk_size: u64 = 52;
    let data_bytes = block_size_per_channel as u64 * channel_num as u64;
    let data_chunk_size: u64 = 12 + data_bytes;
    let total_file_size: u64 = 28 + fmt_chunk_size + data_chunk_size;

    dsf_data.extend_from_slice(b"DSD ");
    dsf_data.extend_from_slice(&28u64.to_le_bytes());
    dsf_data.extend_from_slice(&total_file_size.to_le_bytes());
    dsf_data.extend_from_slice(&0u64.to_le_bytes());

    dsf_data.extend_from_slice(b"fmt ");
    dsf_data.extend_from_slice(&fmt_chunk_size.to_le_bytes());
    dsf_data.extend_from_slice(&1u32.to_le_bytes());
    dsf_data.extend_from_slice(&0u32.to_le_bytes());
    dsf_data.extend_from_slice(&2u32.to_le_bytes());
    dsf_data.extend_from_slice(&channel_num.to_le_bytes());
    dsf_data.extend_from_slice(&raw_sampling_freq.to_le_bytes());
    dsf_data.extend_from_slice(&1u32.to_le_bytes());
    dsf_data.extend_from_slice(&sample_count.to_le_bytes());
    dsf_data.extend_from_slice(&block_size_per_channel.to_le_bytes());
    dsf_data.extend_from_slice(&0u32.to_le_bytes());

    dsf_data.extend_from_slice(b"data");
    dsf_data.extend_from_slice(&data_chunk_size.to_le_bytes());
    dsf_data.extend_from_slice(&vec![0xAAu8; block_size_per_channel as usize]);
    dsf_data.extend_from_slice(&vec![0x55u8; block_size_per_channel as usize]);

    let cursor: Box<dyn MediaSource> = Box::new(std::io::Cursor::new(dsf_data));
    match DsfReader::try_new(cursor).expect("DSF probe failed") {
        DsfProbe::Matched(mut reader) => {
            assert_eq!(reader.channels(), 2);
            assert_eq!(reader.sample_rate(), 88200);
            let mut pcm = Vec::new();
            assert!(reader.decode_next_frame(&mut pcm).unwrap());
            assert!(!pcm.is_empty());
            reader.seek_ms(5).expect("Seek should succeed");
        }
        DsfProbe::NotMatched(_) => panic!("Expected DSF to match probe"),
    }
}

#[test]
fn test_all_manifest_audio_formats_decode_and_seek() {
    let all_fixtures = [
        "17_Running_To_Meet_The_Sun.wav",
        "08_Firelight_Promise_24bit_mono.wav",
        "12_Mi_más_bonita_coincidencia_24bit_stereo.wav",
        "19_Spin_Me_In_The_Dark.rf64",
        "22_The_Midnight_Pursuit.rifx",
        "20_Swallowing_This_Glitter_Pill.w64",
        "21_The_Great_Equalizer.bwf",
        "18_Running_With_Daylight.aif",
        "24_Tracks_Into_The_Dawn.aiff",
        "23_Tracing_Lines.aifc",
        "27_¡Yo_me_opongo_.caf",
        "04_Belaya_Tishina.flac",
        "07_Fevered_Strings_alac.m4a",
        "06_Calculated_Motion_aac.m4a",
        "10_La_cicatriz_del_andén.aac",
        "01_Apex_Momentum.mp3",
        "03_Before_The_Dawn_cbr_noxing.mp3",
        "15_Resting_At_Your_Feet.mp2",
        "05_Burning_in_the_Electric_Light.ogg",
        "16_Ribbons_on_Anchors.oga",
        "02_Bailando_con_tu_recuerdo.opus",
        "13_Overture_for_the_Floor.webm",
        "11_Mar_de_cristal.mka",
        "14_Painting_the_Sky.mkv",
        "09_Flesh_and_Chrome.wv",
        "29_駆け抜けて、この空を.dsf",
        "25_Velocity_of_One.ape",
    ];

    for filename in &all_fixtures {
        let path = FixtureResolver::resolve(filename);
        let file = File::open(&path).unwrap_or_else(|e| panic!("Failed to open {}: {}", filename, e));
        let ext = StreamClassifier::extract_extension_hint(filename);

        let mut engine = SymphoniaEngine::new(file, ext)
            .unwrap_or_else(|e| panic!("SymphoniaEngine failed to open {}: {}", filename, e));

        if *filename == "10_La_cicatriz_del_andén.aac" {
            let dur = engine.duration_ms().expect("ADTS .aac must have duration");
            assert!(
                (dur as i64 - 170_670).abs() <= 250,
                "ADTS .aac duration {}ms must be ~170670ms (full original song)",
                dur
            );
        }

        assert!(engine.sample_rate() > 0, "{}: invalid sample rate", filename);
        assert!(engine.channels() > 0, "{}: invalid channel count", filename);

        let mut pcm = Vec::new();
        let mut frames_decoded = 0usize;
        for _ in 0..8 {
            match engine.decode_next_frame(&mut pcm) {
                Ok(true) => {
                    assert!(!pcm.is_empty(), "{}: decoded empty PCM frame", filename);
                    for &s in &pcm {
                        assert!(!s.is_nan(), "{}: decoded NaN sample", filename);
                    }
                    frames_decoded += pcm.len() / (engine.channels() as usize);
                }
                Ok(false) => break,
                Err(e) => panic!("{}: frame decode error: {}", filename, e),
            }
        }
        assert!(frames_decoded > 0, "{}: decoded 0 frames", filename);

        // Seek test on seekable containers (all except raw ADTS .aac)
        if *filename != "10_La_cicatriz_del_andén.aac" {
            engine
                .seek_ms(1000)
                .unwrap_or_else(|e| panic!("{}: seek_ms(1000) failed: {}", filename, e));
            let ok = engine
                .decode_next_frame(&mut pcm)
                .unwrap_or_else(|e| panic!("{}: decode after seek failed: {}", filename, e));
            assert!(ok, "{}: expected frame after seek_ms(1000)", filename);
        }
    }
}

#[test]
fn test_flac_and_alac_speed_consistency_and_mono_upmix() {
    for (filename, ext) in &[
        ("04_Belaya_Tishina.flac", "flac"),
        ("07_Fevered_Strings_alac.m4a", "m4a"),
    ] {
        let path = FixtureResolver::resolve(filename);
        let file = File::open(&path).unwrap();
        let mut engine = SymphoniaEngine::new(file, Some(ext)).unwrap();

        let track_sr = engine.sample_rate();
        let track_ch = engine.channels() as usize;
        assert_eq!(track_sr, 48000);
        assert_eq!(track_ch, 2);

        let (mut producer, mut consumer) = AudioRingBuffer::create(48000 * 2);
        let mut channel_matrix = ChannelMatrix::new(track_ch, 2);
        let mut resampler = RubatoResampler::new(track_sr, 48000, 2, 1024).unwrap();

        let mut frame_buf = Vec::new();
        let mut matrix_buf = Vec::new();
        let mut resampler_out = Vec::new();
        let mut pending_pcm = Vec::new();
        let mut pending_offset = 0;

        let mut total_rendered_frames = 0usize;
        let mut render_buf = vec![0.0f32; 2048];
        let target_frames = 48000 * 3;

        while total_rendered_frames < target_frames {
            if pending_offset < pending_pcm.len() {
                let written = producer.write_chunk(&pending_pcm[pending_offset..]);
                pending_offset += written;
                if pending_offset >= pending_pcm.len() {
                    pending_pcm.clear();
                    pending_offset = 0;
                }
            }

            if pending_pcm.is_empty() && producer.slots_available() >= 2048 {
                if let Ok(true) = engine.decode_next_frame(&mut frame_buf) {
                    channel_matrix.process_interleaved(&frame_buf, &mut matrix_buf);
                    resampler_out.clear();
                    resampler.process_interleaved(&matrix_buf, &mut resampler_out).unwrap();
                    pending_pcm.extend_from_slice(&resampler_out);
                    pending_offset = producer.write_chunk(&pending_pcm);
                    if pending_offset >= pending_pcm.len() {
                        pending_pcm.clear();
                        pending_offset = 0;
                    }
                } else {
                    break;
                }
            }

            let read = consumer.read_chunk(&mut render_buf);
            if read > 0 {
                total_rendered_frames += read / 2;
            } else if pending_pcm.is_empty() {
                break;
            }
        }

        assert!(total_rendered_frames >= target_frames);
    }

    // Mono upmix check on 03_Before_The_Dawn_cbr_noxing.mp3
    let mp3_file = File::open(FixtureResolver::resolve("03_Before_The_Dawn_cbr_noxing.mp3")).unwrap();
    let mut mono_engine = SymphoniaEngine::new(mp3_file, Some("mp3")).unwrap();
    assert_eq!(mono_engine.channels(), 1);

    let mut matrix = ChannelMatrix::new(1, 2);
    let mut frame_buf = Vec::new();
    let mut stereo_buf = Vec::new();
    assert!(mono_engine.decode_next_frame(&mut frame_buf).unwrap());
    matrix.process_interleaved(&frame_buf, &mut stereo_buf);
    assert_eq!(stereo_buf.len(), frame_buf.len() * 2);
    for f in 0..frame_buf.len() {
        assert_eq!(stereo_buf[f * 2], stereo_buf[f * 2 + 1]);
    }
}

#[test]
fn test_stream_chunk_probing_mp3_and_aiff() {
    for (filename, hint) in &[
        ("01_Apex_Momentum.mp3", Some("mp3")),
        ("18_Running_With_Daylight.aif", None),
    ] {
        let mut file = File::open(FixtureResolver::resolve(filename)).unwrap();
        let total_len = file.metadata().unwrap().len();
        let mut initial_data = vec![0u8; 262144];
        let n = file.read(&mut initial_data).unwrap();
        initial_data.truncate(n);

        let buf = StreamSession::new(2 * 1024 * 1024, Some(total_len), false);
        let (_, boundary) = StreamClassifier::detect_head_boundary(&initial_data, total_len as i64);
        if boundary.audio_start > 0 {
            let head_len = (boundary.audio_start as usize).min(initial_data.len());
            buf.head.set_linear_bytes(&initial_data[..head_len]);
            buf.set_audio_start(boundary.audio_start as u64);
            if initial_data.len() > head_len {
                buf.feed_chunk(&initial_data[head_len..]).unwrap();
            }
        } else {
            buf.set_audio_start(0);
            buf.feed_chunk(&initial_data).unwrap();
        }

        let reader = DemuxedStreamReader::new(buf);
        let engine = SymphoniaEngine::new(reader, *hint)
            .unwrap_or_else(|e| panic!("Stream probe failed for {}: {}", filename, e));
        assert!(engine.sample_rate() > 0);
        assert!(engine.channels() > 0);
    }
}

#[test]
fn test_adts_aac_exact_duration_calculation() {
    let path = FixtureResolver::resolve("10_La_cicatriz_del_andén.aac");
    let mut file = File::open(&path).expect("Failed to open 10_La_cicatriz_del_andén.aac");
    let total_len = file.metadata().expect("Failed metadata").len();

    // 1. Test StreamClassifier::scan_adts_stream
    let adts_info = StreamClassifier::scan_adts_stream(&mut file)
        .expect("StreamClassifier::scan_adts_stream must detect ADTS");
    assert_eq!(adts_info.0, 48000, "Sample rate must be 48000");
    assert_eq!(adts_info.1, 2, "Channel count must be 2");
    let exact_ms = adts_info.2;
    assert!(
        (exact_ms as i64 - 170_670).abs() <= 250,
        "Exact duration must be ~170670 ms (full original song), was {}",
        exact_ms
    );

    // 2. Test StreamClassifier::sniff_adts_stream_info
    let mut data = Vec::new();
    file.seek(std::io::SeekFrom::Start(0)).unwrap();
    file.read_to_end(&mut data).unwrap();
    let (bitrate, dur_ms) = StreamClassifier::sniff_adts_stream_info(&data, total_len as i64)
        .expect("sniff_adts_stream_info must succeed");
    assert_eq!(
        dur_ms as u64, exact_ms,
        "sniff_adts_stream_info duration {} must match scan_adts_stream {}",
        dur_ms, exact_ms
    );
    assert!(
        bitrate > 165_000 && bitrate < 235_000,
        "Bitrate ~192kbps, was {}",
        bitrate
    );

    // 3. Test SymphoniaEngine::new
    file.seek(std::io::SeekFrom::Start(0)).unwrap();
    let engine = SymphoniaEngine::new(file, Some("aac")).expect("SymphoniaEngine must open");
    let eng_dur = engine.duration_ms().expect("duration_ms must be present");
    assert_eq!(
        eng_dur, exact_ms,
        "SymphoniaEngine duration {} must match {}",
        eng_dur, exact_ms
    );

    // 4. Test analyze_audio_source
    let config = miniaudio_player::api::types::RustAnalysisConfig {
        replay_gain: false,
        waveform: false,
        metadata: false,
        chromaprint: false,
        target_lufs: -14.0,
        waveform_points: 0,
        max_duration_ms: None,
    };
    let source = miniaudio_player::core::dual_source::AudioSourceCore {
        source: path.to_str().unwrap().to_string(),
        ..Default::default()
    };
    let analysis = miniaudio_player::dsp::analyze_audio_source(source, config)
        .expect("analyze_audio_source must succeed");
    assert_eq!(
        analysis.audio_info.duration_ms.unwrap_or(0),
        exact_ms as i64,
        "Analysis duration {:?} must match {}",
        analysis.audio_info.duration_ms,
        exact_ms
    );
    assert!(!analysis.has_chromaprint);
    assert!(analysis.chromaprint.is_none());
}

#[test]
fn test_chromaprint_analysis_generation() {
    let wav_data = SignalGenerator::pcm16_wav_bytes(44100 * 4, 44100, 2);
    let scratch = FixtureResolver::scratch_file_path("chromaprint_test.wav");
    std::fs::write(&scratch, wav_data).unwrap();

    let config = miniaudio_player::api::types::RustAnalysisConfig {
        replay_gain: true,
        waveform: true,
        metadata: false,
        chromaprint: true,
        target_lufs: -18.0,
        waveform_points: 50,
        max_duration_ms: None,
    };
    let source = miniaudio_player::core::dual_source::AudioSourceCore {
        source: scratch.to_str().unwrap().to_string(),
        ..Default::default()
    };
    let analysis = miniaudio_player::dsp::analyze_audio_source(source, config)
        .expect("analyze_audio_source with chromaprint must succeed");

    let _ = std::fs::remove_file(&scratch);

    assert!(analysis.has_replay_gain);
    assert!(analysis.has_waveform);
    assert!(analysis.has_chromaprint, "Chromaprint flag must be true");

    let cp = analysis.chromaprint.expect("Chromaprint result must be present");
    assert!(!cp.fingerprint.is_empty(), "Fingerprint string must not be empty");
    assert!(!cp.raw.is_empty(), "Raw fingerprint hashes must not be empty");
    assert!(cp.algorithm >= 0, "Algorithm must be valid (>= 0)");
}

#[test]
fn test_pure_rust_symphonia_opus_0_1_2_capabilities_and_accuracy() {
    use symphonia::core::audio::{Channels, Position};
    use symphonia::core::codecs::audio::{
        AudioCodecParameters, AudioDecoder, AudioDecoderOptions,
    };
    use symphonia::core::packet::PacketRef;
    use symphonia::core::units::{Duration, Timestamp};
    use symphonia_opus::OpusDecoder;

    // 1. Registry must expose symphonia-opus 0.1.2 for CODEC_ID_OPUS
    let registry = create_codec_registry();
    assert!(registry.get_audio_decoder(CODEC_ID_OPUS).is_some());

    // 2. Full decode & seek/reset validation on real Opus containers (.opus, .webm)
    for (filename, ext) in &[
        ("02_Bailando_con_tu_recuerdo.opus", "opus"),
        ("13_Overture_for_the_Floor.webm", "webm"),
    ] {
        let file = File::open(FixtureResolver::resolve(filename)).unwrap();
        let mut engine = SymphoniaEngine::new(file, Some(ext))
            .unwrap_or_else(|e| panic!("Opus open failed for {}: {}", filename, e));
        assert_eq!(engine.codec(), "Opus");
        assert_eq!(engine.sample_rate(), 48000);
        assert!(engine.channels() >= 1);

        let mut pcm = Vec::new();
        let mut total_frames = 0usize;
        while let Ok(true) = engine.decode_next_frame(&mut pcm) {
            for &s in &pcm {
                assert!(s.is_finite(), "{}: non-finite Opus sample", filename);
            }
            total_frames += pcm.len() / (engine.channels() as usize);
        }
        assert!(total_frames > 48000, "{}: expected > 1s of decoded Opus audio", filename);

        // Seek before hitting container EOF (isomp4/mkv demuxers invalidate state once EOF is reached).
        let seek_file = File::open(FixtureResolver::resolve(filename)).unwrap();
        let mut seek_engine = SymphoniaEngine::new(seek_file, Some(ext)).unwrap();
        for _ in 0..8 {
            assert!(seek_engine.decode_next_frame(&mut pcm).unwrap());
        }
        seek_engine.seek_ms(1000).expect("Opus seek failed");
        assert!(seek_engine.decode_next_frame(&mut pcm).unwrap());
        for &s in &pcm {
            assert!(s.is_finite(), "{}: non-finite Opus sample after seek", filename);
        }
    }

    // 3. Container 44.1 kHz sample rate fallback to 48 kHz + Q7.8 OutputGain (+6.02 dB = 1536 -> ~2.0x)
    let make_head = |channels: u8, output_gain: i16, family: u8, streams: u8, coupled: u8, map: &[u8]| -> Box<[u8]> {
        let mut h = Vec::with_capacity(21 + map.len());
        h.extend_from_slice(b"OpusHead");
        h.push(1);
        h.push(channels);
        h.extend_from_slice(&0u16.to_le_bytes());
        h.extend_from_slice(&44100u32.to_le_bytes());
        h.extend_from_slice(&output_gain.to_le_bytes());
        h.push(family);
        if family != 0 {
            h.push(streams);
            h.push(coupled);
            h.extend_from_slice(map);
        }
        h.into_boxed_slice()
    };

    let mut p_unity = AudioCodecParameters::new();
    p_unity
        .for_codec(CODEC_ID_OPUS)
        .with_sample_rate(44100)
        .with_extra_data(make_head(2, 0, 0, 1, 1, &[]));
    let mut d_unity = OpusDecoder::try_new(&p_unity, &AudioDecoderOptions::default()).unwrap();
    assert_eq!(d_unity.codec_params().sample_rate, Some(48000));

    let mut p_gain = AudioCodecParameters::new();
    p_gain
        .for_codec(CODEC_ID_OPUS)
        .with_sample_rate(44100)
        .with_extra_data(make_head(2, 1536, 0, 1, 1, &[])); // +6.0 dB
    let mut d_gain = OpusDecoder::try_new(&p_gain, &AudioDecoderOptions::default()).unwrap();
    assert_eq!(d_gain.output_gain(), 1536);

    // Non-silent CELT frame + empty PLC packet
    let pkt_bytes = [0xFCu8, 0x10, 0x20, 0x30, 0x40, 0x50];
    let pkt = PacketRef::new(0, Timestamp::from(0u32), Duration::from(960u64), &pkt_bytes);
    let _ = d_unity.decode_ref(&pkt).unwrap();
    let _ = d_gain.decode_ref(&pkt).unwrap();
    let expected_scale = 10.0_f32.powf(1536.0 / (20.0 * 256.0));
    let mut u_samples: Vec<f32> = Vec::new();
    d_unity.last_decoded().copy_to_vec_interleaved(&mut u_samples);
    let u_peak = u_samples.iter().fold(0.0_f32, |m, &s| m.max(s.abs()));
    let mut g_samples: Vec<f32> = Vec::new();
    d_gain.last_decoded().copy_to_vec_interleaved(&mut g_samples);
    let g_peak = g_samples.iter().fold(0.0_f32, |m, &s| m.max(s.abs()));
    assert!((g_peak - u_peak * expected_scale).abs() < 1e-4);

    // PLC on empty packet must synthesize 960 finite samples without error
    let plc_pkt = PacketRef::new(0, Timestamp::from(960u32), Duration::from(960u64), &[]);
    let plc_out = d_unity.decode_ref(&plc_pkt).unwrap();
    assert_eq!(plc_out.frames(), 960);

    // 4. Surround 5.1 (Mapping Family 1, 6 channels = 4 streams / 2 coupled)
    let mut p_51 = AudioCodecParameters::new();
    p_51.for_codec(CODEC_ID_OPUS)
        .with_sample_rate(48000)
        .with_channels(Channels::Positioned(
            Position::FRONT_LEFT
                | Position::FRONT_CENTER
                | Position::FRONT_RIGHT
                | Position::REAR_LEFT
                | Position::REAR_RIGHT
                | Position::LFE1,
        ))
        .with_extra_data(make_head(6, 0, 1, 4, 2, &[0, 4, 1, 2, 3, 5]));
    let mut d_51 = registry
        .make_audio_decoder(&p_51, &AudioDecoderOptions::default())
        .expect("Opus 5.1 surround decoder must instantiate");
    let pkt_51 = [
        0xFCu8, 0x02, 0xFF, 0xFE, // Stream 0 (coupled, self-delimited)
        0xFC, 0x02, 0xFF, 0xFE,   // Stream 1 (coupled, self-delimited)
        0xF8, 0x02, 0xFF, 0xFE,   // Stream 2 (mono, self-delimited)
        0xF8, 0xFF, 0xFE,         // Stream 3 (mono, final undelimited)
    ];
    let p_ref = PacketRef::new(0, Timestamp::from(0u32), Duration::from(960u64), &pkt_51);
    let dec_51 = d_51.decode_ref(&p_ref).unwrap();
    assert_eq!(dec_51.spec().channels().count(), 6);
    assert_eq!(dec_51.frames(), 960);
}

#[test]
fn test_pure_rust_rusty_aac_2_0_2_lc_sbr_ps_and_multichannel() {
    use miniaudio_player::decoder::RustyAacDecoder;
    use symphonia::core::codecs::audio::well_known::{
        profiles::{CODEC_PROFILE_AAC_HE, CODEC_PROFILE_AAC_HE_V2, CODEC_PROFILE_AAC_LC},
        CODEC_ID_AAC,
    };
    use symphonia::core::codecs::audio::{
        AudioCodecParameters, AudioDecoderOptions,
    };
    use symphonia::core::codecs::registry::RegisterableAudioDecoder;

    // 1. Verify CODEC_ID_AAC registers RustyAacDecoder and advertises LC / HE-AAC v1 / HE-AAC v2
    let registry = create_codec_registry();
    assert!(registry.get_audio_decoder(CODEC_ID_AAC).is_some());
    let supported = RustyAacDecoder::supported_codecs();
    let profiles = supported[0].info.profiles;
    assert!(profiles.iter().any(|p| p.profile == CODEC_PROFILE_AAC_LC));
    assert!(profiles.iter().any(|p| p.profile == CODEC_PROFILE_AAC_HE));
    assert!(profiles.iter().any(|p| p.profile == CODEC_PROFILE_AAC_HE_V2));

    // 2. Full decode + seek validation on real M4A AAC-LC and raw ADTS .aac fixtures
    for (filename, ext) in &[
        ("06_Calculated_Motion_aac.m4a", "m4a"),
        ("10_La_cicatriz_del_andén.aac", "aac"),
    ] {
        let file = File::open(FixtureResolver::resolve(filename)).unwrap();
        let mut engine = SymphoniaEngine::new(file, Some(ext))
            .unwrap_or_else(|e| panic!("AAC open failed for {}: {}", filename, e));
        assert_eq!(engine.codec(), "AAC");
        assert_eq!(engine.sample_rate(), 48000);
        assert_eq!(engine.channels(), 2);

        let mut pcm = Vec::new();
        let mut total_frames = 0usize;
        while let Ok(true) = engine.decode_next_frame(&mut pcm) {
            for &s in &pcm {
                assert!(s.is_finite(), "{}: non-finite AAC sample", filename);
            }
            total_frames += pcm.len() / 2;
        }
        assert!(total_frames > 48000, "{}: expected > 1s of decoded AAC audio", filename);

        if *filename != "10_La_cicatriz_del_andén.aac" {
            let seek_file = File::open(FixtureResolver::resolve(filename)).unwrap();
            let mut seek_engine = SymphoniaEngine::new(seek_file, Some(ext)).unwrap();
            for _ in 0..8 {
                assert!(seek_engine.decode_next_frame(&mut pcm).unwrap());
            }
            seek_engine.seek_ms(1000).expect("M4A AAC seek failed");
            assert!(seek_engine.decode_next_frame(&mut pcm).unwrap());
            for &s in &pcm {
                assert!(s.is_finite(), "{}: non-finite AAC sample after seek", filename);
            }
        }
    }

    // 3. HE-AAC v1 (SBR, AOT 5: 24 kHz base -> 48 kHz output, stereo)
    let mut p_sbr = AudioCodecParameters::new();
    p_sbr
        .for_codec(CODEC_ID_AAC)
        .with_extra_data(Box::new([0x2B, 0x11, 0x88, 0x00]));
    let dec_sbr = registry
        .make_audio_decoder(&p_sbr, &AudioDecoderOptions::default())
        .expect("HE-AAC v1 SBR must initialize");
    assert_eq!(dec_sbr.codec_params().sample_rate, Some(48000));
    assert_eq!(dec_sbr.codec_params().channels.as_ref().unwrap().count(), 2);

    // 4. HE-AAC v2 (SBR + Parametric Stereo, AOT 29: 24 kHz mono base -> 48 kHz stereo output)
    let mut p_ps = AudioCodecParameters::new();
    p_ps.for_codec(CODEC_ID_AAC)
        .with_extra_data(Box::new([0xEB, 0x09, 0x88, 0x00]));
    let dec_ps = registry
        .make_audio_decoder(&p_ps, &AudioDecoderOptions::default())
        .expect("HE-AAC v2 SBR+PS must initialize");
    assert_eq!(dec_ps.codec_params().sample_rate, Some(48000));
    assert_eq!(dec_ps.codec_params().channels.as_ref().unwrap().count(), 2);

    // 5. Surround 5.1 (6 channels) AAC-LC AudioSpecificConfig
    let mut p_51 = AudioCodecParameters::new();
    p_51.for_codec(CODEC_ID_AAC)
        .with_extra_data(Box::new([0x11, 0xB0]));
    let dec_51 = registry
        .make_audio_decoder(&p_51, &AudioDecoderOptions::default())
        .expect("5.1 surround AAC must initialize");
    assert_eq!(dec_51.codec_params().sample_rate, Some(48000));
    assert_eq!(dec_51.codec_params().channels.as_ref().unwrap().count(), 6);
}

#[test]
fn test_http_edge_formats_aiff_mkv_aac() {
    use miniaudio_player::api::types::RustAnalysisConfig;
    use miniaudio_player::core::dual_source::{AudioSourceCore, StreamingDeck};
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::Arc;

    struct ExpectSpec {
        name: &'static str,
        container: &'static str,
        codec: &'static str,
        min_open_dur_ms: i64,
        max_open_dur_ms: i64,
        min_analyze_dur_ms: i64,
        max_analyze_dur_ms: i64,
    }

    let specs = [
        ExpectSpec {
            name: "18_Running_With_Daylight.aif",
            container: "AIFF",
            codec: "PCM",
            min_open_dur_ms: 171_500,
            max_open_dur_ms: 173_500,
            min_analyze_dur_ms: 171_500,
            max_analyze_dur_ms: 173_500,
        },
        ExpectSpec {
            name: "23_Tracing_Lines.aifc",
            container: "AIFF",
            codec: "PCM",
            min_open_dur_ms: 178_500,
            max_open_dur_ms: 181_000,
            min_analyze_dur_ms: 178_500,
            max_analyze_dur_ms: 181_000,
        },
        ExpectSpec {
            name: "24_Tracks_Into_The_Dawn.aiff",
            container: "AIFF",
            codec: "PCM",
            min_open_dur_ms: 182_000,
            max_open_dur_ms: 184_000,
            min_analyze_dur_ms: 182_000,
            max_analyze_dur_ms: 184_000,
        },
        ExpectSpec {
            name: "14_Painting_the_Sky.mkv",
            container: "Matroska",
            codec: "Opus",
            min_open_dur_ms: 178_000,
            max_open_dur_ms: 181_000,
            min_analyze_dur_ms: 178_000,
            max_analyze_dur_ms: 181_000,
        },
        ExpectSpec {
            name: "11_Mar_de_cristal.mka",
            container: "Matroska",
            codec: "FLAC",
            min_open_dur_ms: 180_000,
            max_open_dur_ms: 182_000,
            min_analyze_dur_ms: 180_000,
            max_analyze_dur_ms: 182_000,
        },
        ExpectSpec {
            name: "10_La_cicatriz_del_andén.aac",
            container: "ADTS",
            codec: "AAC",
            min_open_dur_ms: 150_000,
            max_open_dur_ms: 205_000,
            min_analyze_dur_ms: 170_000,
            max_analyze_dur_ms: 171_500,
        },
        ExpectSpec {
            name: "09_Flesh_and_Chrome.wv",
            container: "WavPack",
            codec: "WavPack",
            min_open_dur_ms: 182_000,
            max_open_dur_ms: 183_500,
            min_analyze_dur_ms: 182_000,
            max_analyze_dur_ms: 183_500,
        },
        ExpectSpec {
            name: "27_¡Yo_me_opongo_.caf",
            container: "CAF",
            codec: "PCM",
            min_open_dur_ms: 176_500,
            max_open_dur_ms: 178_000,
            min_analyze_dur_ms: 176_500,
            max_analyze_dur_ms: 178_000,
        },
    ];

    let music_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("example/assets/music");
    let files: Arc<Vec<(String, Vec<u8>)>> = Arc::new(
        specs
            .iter()
            .map(|s| {
                (
                    s.name.to_string(),
                    std::fs::read(music_dir.join(s.name)).unwrap(),
                )
            })
            .collect(),
    );

    for support_range in [true, false] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let files_srv = files.clone();

        std::thread::spawn(move || {
            for stream_res in listener.incoming() {
                let Ok(mut stream) = stream_res else { break };
                let files_req = files_srv.clone();
                std::thread::spawn(move || {
                    let mut br = BufReader::new(stream.try_clone().unwrap());
                    let mut req_line = String::new();
                    if br.read_line(&mut req_line).is_err() {
                        return;
                    }
                    let raw_path = req_line.split_whitespace().nth(1).unwrap_or("/");
                    let name = raw_path
                        .trim_start_matches('/')
                        .replace("%20", " ")
                        .replace("%C2%A1", "¡")
                        .replace("%C3%A9", "é");
                    let mut range_hdr: Option<String> = None;
                    loop {
                        let mut h = String::new();
                        if br.read_line(&mut h).is_err() || h.trim().is_empty() {
                            break;
                        }
                        let low = h.to_ascii_lowercase();
                        if let Some(rest) = low.strip_prefix("range:") {
                            range_hdr = Some(rest.trim().to_string());
                        }
                    }
                    let Some((_, data)) = files_req.iter().find(|(n, _)| *n == name) else {
                        let _ = stream
                            .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                        return;
                    };
                    if support_range {
                        if let Some(r) =
                            range_hdr.and_then(|s| s.strip_prefix("bytes=").map(str::to_string))
                        {
                            let (a, b) = r.split_once('-').unwrap_or(("0", ""));
                            let start: usize = a.parse().unwrap_or(0);
                            let end: usize = if b.is_empty() {
                                data.len() - 1
                            } else {
                                b.parse().unwrap_or(data.len() - 1).min(data.len() - 1)
                            };
                            if start <= end && start < data.len() {
                                let slice = &data[start..=end];
                                let hdr = format!(
                                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                                    slice.len(),
                                    start,
                                    end,
                                    data.len()
                                );
                                let _ = stream.write_all(hdr.as_bytes());
                                let _ = stream.write_all(slice);
                                return;
                            }
                        }
                    }
                    let hdr = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        data.len()
                    );
                    let _ = stream.write_all(hdr.as_bytes());
                    let _ = stream.write_all(data);
                });
            }
        });

        for spec in &specs {
            let encoded = spec
                .name
                .replace(' ', "%20")
                .replace('¡', "%C2%A1")
                .replace('é', "%C3%A9");
            let url = format!("http://127.0.0.1:{}/{}", port, encoded);
            let mut deck = StreamingDeck::new_analysis_deck(48000, 2).unwrap();
            let code = deck.open_network_with_cancel(&url, None, None);
            assert_eq!(
                code, 0,
                "open_network_with_cancel failed for {} (range={})",
                spec.name, support_range
            );
            let info = deck.get_audio_info();
            assert_eq!(
                info.container_format, spec.container,
                "unexpected container for {} (range={})",
                spec.name, support_range
            );
            assert_eq!(
                info.codec, spec.codec,
                "unexpected codec for {} (range={})",
                spec.name, support_range
            );
            let open_dur = info.duration_ms.unwrap_or_else(|| {
                panic!("missing open duration for {} (range={})", spec.name, support_range)
            });
            assert!(
                (spec.min_open_dur_ms..=spec.max_open_dur_ms).contains(&open_dur),
                "unexpected open duration {}ms for {} (range={}, expected {}..={})",
                open_dur,
                spec.name,
                support_range,
                spec.min_open_dur_ms,
                spec.max_open_dur_ms
            );
            drop(deck);

            let cfg = RustAnalysisConfig {
                replay_gain: true,
                waveform: true,
                metadata: true,
                chromaprint: false,
                target_lufs: -14.0,
                waveform_points: 100,
                max_duration_ms: None,
            };
            let src = AudioSourceCore {
                source: url,
                ..Default::default()
            };
            let res = miniaudio_player::dsp::analyze_audio_source(src, cfg).unwrap_or_else(|e| {
                panic!(
                    "analyze_audio_source failed for {} (range={}): {}",
                    spec.name, support_range, e
                )
            });
            let analyze_dur = res.audio_info.duration_ms.unwrap_or(0);
            assert!(
                (spec.min_analyze_dur_ms..=spec.max_analyze_dur_ms).contains(&analyze_dur),
                "unexpected analyzed duration {}ms for {} (range={})",
                analyze_dur,
                spec.name,
                support_range
            );
            assert!(res.has_replay_gain);
            assert!(res.has_waveform);
            assert_eq!(res.waveform_peaks.len(), 100);
            assert!(res.integrated_lufs.is_finite());
        }
    }
}

#[test]
fn test_classifier_aiff_and_mkv_precluster_boundary() {
    let music_dir = FixtureResolver::fixtures_dir();

    // AIFF and AIFC FORM detection
    let aiff_bytes = std::fs::read(music_dir.join("18_Running_With_Daylight.aif")).unwrap();
    let (st_aif, b_aif) = StreamClassifier::detect_head_boundary(&aiff_bytes[..65536], aiff_bytes.len() as i64);
    assert_eq!(st_aif, BoundaryStatus::Found);
    assert_eq!(b_aif.container, ContainerFormat::Aiff);
    assert_eq!(b_aif.audio_start, 0);

    // Matroska with >64KB Attachments before first Cluster must request NeedMore until Cluster
    let mkv_bytes = std::fs::read(music_dir.join("14_Painting_the_Sky.mkv")).unwrap();
    let (st_short, b_short) =
        StreamClassifier::detect_head_boundary(&mkv_bytes[..65536], mkv_bytes.len() as i64);
    assert_eq!(st_short, BoundaryStatus::NeedMore);
    assert!(b_short.needed_bytes > 65536);

    let (st_full, b_full) =
        StreamClassifier::detect_head_boundary(&mkv_bytes[..262144], mkv_bytes.len() as i64);
    assert_eq!(st_full, BoundaryStatus::Found);
    assert_eq!(b_full.container, ContainerFormat::Matroska);
    assert!(
        b_full.audio_start > 65_536 && b_full.audio_start <= 262_144,
        "MKV audio_start {} should lie past 64KB attachment block and within 256KB",
        b_full.audio_start
    );

    // CAF ("caff") detection must identify data payload start (547) without full scan
    let caf_bytes = std::fs::read(music_dir.join("27_¡Yo_me_opongo_.caf")).unwrap();
    let (st_caf, b_caf) =
        StreamClassifier::detect_head_boundary(&caf_bytes[..4096], caf_bytes.len() as i64);
    assert_eq!(st_caf, BoundaryStatus::Found);
    assert_eq!(b_caf.container, ContainerFormat::Caf);
    assert_eq!(b_caf.audio_start, 547);
}

fn decode_url_path(raw: &str) -> String {
    let stripped = raw.trim_start_matches('/');
    let mut out = Vec::with_capacity(stripped.len());
    let bytes = stripped.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn encode_url_path(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for &b in name.as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

fn spawn_http_fixture_server(
    file_names: &[&str],
    throttle_after_bytes: Option<(usize, usize, u64)>,
) -> (
    u16,
    std::sync::Arc<std::sync::atomic::AtomicBool>,
    std::thread::JoinHandle<()>,
) {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    use std::time::Duration;

    let music_dir = FixtureResolver::fixtures_dir();
    let files = Arc::new(
        file_names
            .iter()
            .map(|&n| (n.to_string(), std::fs::read(music_dir.join(n)).unwrap()))
            .collect::<Vec<_>>(),
    );

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_srv = stop.clone();

    let handle = std::thread::spawn(move || {
        while !stop_srv.load(Ordering::Acquire) {
            let Ok((mut stream, _)) = listener.accept() else {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            };
            let _ = stream.set_nonblocking(false);
            let files_req = files.clone();
            let stop_req = stop_srv.clone();
            std::thread::spawn(move || {
                let mut br = BufReader::new(stream.try_clone().unwrap());
                let mut req_line = String::new();
                if br.read_line(&mut req_line).is_err() {
                    return;
                }
                let raw_path = req_line.split_whitespace().nth(1).unwrap_or("/");
                let name = decode_url_path(raw_path);
                let mut range_hdr: Option<String> = None;
                loop {
                    let mut h = String::new();
                    if br.read_line(&mut h).is_err() || h.trim().is_empty() {
                        break;
                    }
                    let low = h.to_ascii_lowercase();
                    if let Some(rest) = low.strip_prefix("range:") {
                        range_hdr = Some(rest.trim().to_string());
                    }
                }
                let Some((_, data)) = files_req.iter().find(|(n, _)| *n == name) else {
                    let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                    return;
                };

                if let Some(r) = range_hdr.and_then(|s| s.strip_prefix("bytes=").map(str::to_string))
                {
                    let (a, b) = r.split_once('-').unwrap_or(("0", ""));
                    let start: usize = a.parse().unwrap_or(0);
                    let end: usize = if b.is_empty() {
                        data.len() - 1
                    } else {
                        b.parse().unwrap_or(data.len() - 1).min(data.len() - 1)
                    };
                    if start <= end && start < data.len() {
                        let slice = &data[start..=end];
                        let hdr = format!(
                            "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                            slice.len(),
                            start,
                            end,
                            data.len()
                        );
                        if stream.write_all(hdr.as_bytes()).is_err() {
                            return;
                        }
                        if b.is_empty() {
                            write_with_optional_throttle(
                                &mut stream,
                                slice,
                                throttle_after_bytes,
                                &stop_req,
                            );
                        } else {
                            let _ = stream.write_all(slice);
                        }
                        return;
                    }
                }

                let hdr = format!(
                    "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    data.len()
                );
                if stream.write_all(hdr.as_bytes()).is_err() {
                    return;
                }
                write_with_optional_throttle(&mut stream, data, throttle_after_bytes, &stop_req);
            });
        }
    });

    (port, stop, handle)
}

fn write_with_optional_throttle(
    stream: &mut std::net::TcpStream,
    data: &[u8],
    throttle: Option<(usize, usize, u64)>,
    stop: &std::sync::atomic::AtomicBool,
) {
    use std::io::Write;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let Some((burst_bytes, chunk_size, sleep_ms)) = throttle else {
        let _ = stream.write_all(data);
        return;
    };
    let head_len = burst_bytes.min(data.len());
    if stream.write_all(&data[..head_len]).is_err() {
        return;
    }
    let mut offset = head_len;
    while offset < data.len() && !stop.load(Ordering::Acquire) {
        std::thread::sleep(Duration::from_millis(sleep_ms));
        let end = (offset + chunk_size).min(data.len());
        if stream.write_all(&data[offset..end]).is_err() {
            break;
        }
        offset = end;
    }
}

fn pump_until_audible(
    deck: &mut miniaudio_player::core::dual_source::StreamingDeck,
    label: &str,
    fname: &str,
) {
    use std::time::Duration;

    let mut render_buf = vec![0.0f32; 1024 * 2];
    let mut max_abs = 0.0f32;
    for _ in 0..100 {
        if let Some(ref mut r) = deck.renderer {
            r.render_pcm(render_buf.as_mut_ptr(), 1024);
        }
        for &s in &render_buf {
            max_abs = max_abs.max(s.abs());
        }
        if max_abs > 1e-4 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        max_abs > 1e-4,
        "expected audible PCM at {} for {}",
        label,
        fname
    );
}

#[test]
fn test_http_206_wv_and_caf_streaming_open_seek_and_metadata() {
    use miniaudio_player::core::dual_source::StreamingDeck;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let (port, stop, srv) = spawn_http_fixture_server(
        &["09_Flesh_and_Chrome.wv", "27_¡Yo_me_opongo_.caf"],
        None,
    );

    for (fname, expected_title, expected_artist) in [
        ("09_Flesh_and_Chrome.wv", "Flesh and Chrome", "Vespera 9"),
        ("27_¡Yo_me_opongo_.caf", "¡Yo me opongo!", "Gabriel Peña"),
    ] {
        let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));
        let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
        let code = deck.open_network_with_cancel(&url, None, None);
        assert_eq!(code, 0, "failed to open {}", fname);
        deck.play();

        pump_until_audible(&mut deck, "initial", fname);
        let meta = deck
            .get_parsed_metadata()
            .unwrap_or_else(|| panic!("missing metadata for {}", fname));
        assert_eq!(meta.title.as_deref(), Some(expected_title), "title mismatch for {}", fname);
        assert_eq!(meta.track_artist.as_deref(), Some(expected_artist), "artist mismatch for {}", fname);

        // Seek far into the track (> 4 MiB ring buffer boundary) and verify audible PCM
        assert_eq!(deck.seek(120_000), 0);
        std::thread::sleep(Duration::from_millis(120));
        pump_until_audible(&mut deck, "seek(120s)", fname);
        let pos_120 = deck.position_ms.load(Ordering::Relaxed);
        assert!(
            (119_500..=125_000).contains(&pos_120),
            "{} pos after seek(120s)={}",
            fname,
            pos_120
        );

        assert_eq!(deck.seek(25_000), 0);
        std::thread::sleep(Duration::from_millis(120));
        pump_until_audible(&mut deck, "seek(25s)", fname);
        let pos_25 = deck.position_ms.load(Ordering::Relaxed);
        assert!(
            (24_500..=30_000).contains(&pos_25),
            "{} pos after seek(25s)={}",
            fname,
            pos_25
        );

        let _ = deck.stop();
    }
    stop.store(true, Ordering::Release);
    let _ = srv.join();
}

#[test]
fn test_http_206_in_buffer_seeks_p0_e1_e2_e3() {
    use miniaudio_player::bridge::ffi::MiniaudioBufferedRange;
    use miniaudio_player::core::dual_source::StreamingDeck;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let files = [
        "02_Bailando_con_tu_recuerdo.opus",
        "04_Belaya_Tishina.flac",
        "05_Burning_in_the_Electric_Light.ogg",
        "06_Calculated_Motion_aac.m4a",
        "07_Fevered_Strings_alac.m4a",
        "16_Ribbons_on_Anchors.oga",
    ];
    // Pace at ~2.5 MB/s after 256 KB initial burst so large tracks (35 MB FLAC) reach >=18s in ~1.6s while staying partial.
    let (port, stop, srv) = spawn_http_fixture_server(&files, Some((256 * 1024, 48 * 1024, 18)));

    for fname in files {
        let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));
        let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
        assert_eq!(deck.open_network_with_cancel(&url, None, None), 0, "open failed for {}", fname);
        let dur_ms = deck.duration_ms.load(Ordering::Relaxed);
        assert!(dur_ms > 120_000, "{} dur_ms={}", fname, dur_ms);
        deck.play();
        pump_until_audible(&mut deck, "initial", fname);

        let mut pre_br = MiniaudioBufferedRange::default();
        for _ in 0..160 {
            assert_eq!(deck.get_buffered_range(&mut pre_br), 0);
            if pre_br.end_ms >= 18_000 {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        assert!(
            pre_br.end_ms >= 15_000,
            "{}: expected partial buffer >= 15s, got {}..{}",
            fname,
            pre_br.start_ms,
            pre_br.end_ms
        );

        let cap_end_before_eof = pre_br.end_ms.min((dur_ms * 70) / 100);
        for frac_pct in [45i64, 82i64] {
            let target =
                pre_br.start_ms + ((cap_end_before_eof - pre_br.start_ms) * frac_pct) / 100;
            let pre_ring_start = deck
                .stream_session
                .read()
                .unwrap()
                .as_ref()
                .map(|s| s.range_start())
                .unwrap();

            assert_eq!(deck.seek(target), 0);
            std::thread::sleep(Duration::from_millis(80));
            pump_until_audible(&mut deck, &format!("in-buf-{}pct", frac_pct), fname);

            let mut post_br = MiniaudioBufferedRange::default();
            assert_eq!(deck.get_buffered_range(&mut post_br), 0);
            let post_ring_start = deck
                .stream_session
                .read()
                .unwrap()
                .as_ref()
                .map(|s| s.range_start())
                .unwrap();

            assert!(
                post_br.end_ms >= target,
                "{}: in-buffer seek({}ms) dropped buf.end to {}ms",
                fname,
                target,
                post_br.end_ms
            );
            assert_eq!(
                post_ring_start, pre_ring_start,
                "{}: in-buffer seek({}ms) unexpectedly flushed Body ring ({} -> {})",
                fname, target, pre_ring_start, post_ring_start
            );
        }

        // Far seek past initial buffer -> verifies P0 (buf.start > 0) and stable subsequent in-buffer seek!
        let far_target = (dur_ms * 75) / 100;
        assert_eq!(deck.seek(far_target), 0);
        let mut far_br = MiniaudioBufferedRange::default();
        for _ in 0..80 {
            std::thread::sleep(Duration::from_millis(30));
            assert_eq!(deck.get_buffered_range(&mut far_br), 0);
            if far_br.start_ms > 0 && far_br.end_ms >= far_target + 10_000 {
                break;
            }
        }
        pump_until_audible(&mut deck, "far-seek", fname);
        assert_eq!(deck.get_buffered_range(&mut far_br), 0);
        assert!(
            far_br.start_ms > 0,
            "{}: expected P0 buffer start_ms > 0 after far seek to {}ms, got {}..{}",
            fname,
            far_target,
            far_br.start_ms,
            far_br.end_ms
        );

        let inner_target = far_br.start_ms + ((far_br.end_ms - far_br.start_ms) * 75) / 100;
        let ring_start_before_inner = deck
            .stream_session
            .read()
            .unwrap()
            .as_ref()
            .map(|s| s.range_start())
            .unwrap();
        assert_eq!(deck.seek(inner_target), 0);
        std::thread::sleep(Duration::from_millis(80));
        pump_until_audible(&mut deck, "post-far-in-buf", fname);
        let ring_start_after_inner = deck
            .stream_session
            .read()
            .unwrap()
            .as_ref()
            .map(|s| s.range_start())
            .unwrap();
        assert_eq!(
            ring_start_after_inner, ring_start_before_inner,
            "{}: seek inside shifted window {}..{} should not flush ring!",
            fname, far_br.start_ms, far_br.end_ms
        );

        let _ = deck.stop();
    }

    stop.store(true, Ordering::Release);
    let _ = srv.join();
}

#[test]
fn test_e6a_http_206_adts_vbr_duration_and_overshoot_seek() {
    use miniaudio_player::core::dual_source::StreamingDeck;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let fname = "10_La_cicatriz_del_andén.aac";
    let (port, stop, srv) =
        spawn_http_fixture_server(&[fname], Some((256 * 1024, 64 * 1024, 15)));
    let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));

    let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
    assert_eq!(deck.open_network_with_cancel(&url, None, None), 0);

    let dur_ms = deck.duration_ms.load(Ordering::Relaxed);
    assert!(
        (168_000..=173_000).contains(&dur_ms),
        "expected ADTS duration ~170_666ms, got {}ms",
        dur_ms
    );

    deck.play();
    pump_until_audible(&mut deck, "initial", fname);

    assert_eq!(deck.seek(155_000), 0);
    std::thread::sleep(Duration::from_millis(120));
    pump_until_audible(&mut deck, "seek(155s)", fname);
    let pos_155 = deck.position_ms.load(Ordering::Relaxed);
    assert!(
        (153_000..=158_500).contains(&pos_155),
        "unexpected pos after seek(155s): {}",
        pos_155
    );

    assert_eq!(deck.seek(50_000), 0);
    std::thread::sleep(Duration::from_millis(120));
    pump_until_audible(&mut deck, "seek(50s)", fname);
    assert!(!deck.decoder_eof.load(Ordering::Relaxed));

    // Seek near true end, then simulate VBR overshoot past true ADTS EOF (~170_666ms) while
    // duration_ms reports an overestimate: must recover cursor cleanly and never latch decoder_eof.
    deck.duration_ms.store(190_000, Ordering::Relaxed);
    assert_eq!(deck.seek(175_000), 0);
    std::thread::sleep(Duration::from_millis(180));
    let mut render_buf = vec![0.0f32; 1024 * 2];
    for _ in 0..16 {
        if let Some(ref mut r) = deck.renderer {
            r.render_pcm(render_buf.as_mut_ptr(), 1024);
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    assert!(
        !deck.decoder_eof.load(Ordering::Relaxed),
        "ADTS overshoot seek(175s) must not latch decoder_eof and trigger premature skip"
    );
    deck.duration_ms.store(dur_ms, Ordering::Relaxed);

    // Seeking back to 50s must continue decoding cleanly.
    assert_eq!(deck.seek(50_000), 0);
    std::thread::sleep(Duration::from_millis(120));
    pump_until_audible(&mut deck, "post-overshoot seek(50s)", fname);
    assert!(!deck.decoder_eof.load(Ordering::Relaxed));
    let pos_back = deck.position_ms.load(Ordering::Relaxed);
    assert!(
        (48_000..=55_000).contains(&pos_back),
        "unexpected pos after post-overshoot seek(50s): {}",
        pos_back
    );

    let _ = deck.stop();
    stop.store(true, Ordering::Release);
    let _ = srv.join();
}

#[test]
fn test_e10_http_206_ape_seek_and_analysis_parity() {
    use miniaudio_player::api::types::RustAnalysisConfig;
    use miniaudio_player::core::dual_source::{AudioSourceCore, StreamingDeck};
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let fname = "25_Velocity_of_One.ape";
    let local_path = FixtureResolver::resolve_str(fname);
    let (port, stop, srv) =
        spawn_http_fixture_server(&[fname], Some((256 * 1024, 64 * 1024, 15)));
    let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));

    let cfg = RustAnalysisConfig {
        replay_gain: true,
        waveform: true,
        metadata: true,
        chromaprint: false,
        target_lufs: -14.0,
        waveform_points: 100,
        max_duration_ms: None,
    };
    let local_res = miniaudio_player::dsp::analyze_audio_source(
        AudioSourceCore {
            source: local_path,
            ..Default::default()
        },
        cfg.clone(),
    )
    .expect("local APE analysis failed");

    let http_res = miniaudio_player::dsp::analyze_audio_source(
        AudioSourceCore {
            source: url.clone(),
            ..Default::default()
        },
        cfg,
    )
    .expect("HTTP APE analysis failed");

    assert!(local_res.has_replay_gain && http_res.has_replay_gain);
    assert!(local_res.has_waveform && http_res.has_waveform);
    assert_eq!(local_res.waveform_peaks.len(), 100);
    assert_eq!(http_res.waveform_peaks.len(), 100);
    assert!(
        (local_res.replay_gain_db - http_res.replay_gain_db).abs() < 0.05,
        "APE replay_gain_db mismatch: local={} vs http={}",
        local_res.replay_gain_db,
        http_res.replay_gain_db
    );
    assert!(
        (local_res.integrated_lufs - http_res.integrated_lufs).abs() < 0.05,
        "APE integrated_lufs mismatch: local={} vs http={}",
        local_res.integrated_lufs,
        http_res.integrated_lufs
    );
    assert!(
        (local_res.replay_gain_peak - http_res.replay_gain_peak).abs() < 0.01,
        "APE replay_gain_peak mismatch: local={} vs http={}",
        local_res.replay_gain_peak,
        http_res.replay_gain_peak
    );
    let mut max_wf_diff = 0.0f32;
    let mut bad_points = Vec::new();
    for (idx, (&lp, &hp)) in local_res
        .waveform_peaks
        .iter()
        .zip(http_res.waveform_peaks.iter())
        .enumerate()
    {
        let d = (lp - hp).abs();
        max_wf_diff = max_wf_diff.max(d);
        if d >= 0.02 {
            bad_points.push((idx, lp, hp));
        }
    }
    if !bad_points.is_empty() {
        let mut adeck = StreamingDeck::new_analysis_deck(44100, 2).unwrap();
        let rc = adeck.open_network_with_cancel(&url, None, None);
        let mut pkts = 0usize;
        let mut frames = 0usize;
        let mut fbuf = Vec::new();
        let mut term = String::from("Ok(false)");
        while rc == 0 {
            match adeck.decode_next_analysis_frame(&mut fbuf) {
                Ok(true) => {
                    pkts += 1;
                    frames += fbuf.len() / 2;
                }
                Ok(false) => break,
                Err(e) => {
                    term = format!("Err({})", e);
                    break;
                }
            }
        }
        let info = adeck.get_audio_info();
        let _ = adeck.stop();
        eprintln!(
            "APE DIAG: local_dur={:?}, http_dur={:?}, max_wf_diff={}, bad_count={}, first_bad={:?} | raw http trace: rc={}, pkts={}, frames={}, term={}, audio_info_dur={:?}, file_size={:?}",
            local_res.audio_info.duration_ms,
            http_res.audio_info.duration_ms,
            max_wf_diff,
            bad_points.len(),
            &bad_points[..bad_points.len().min(12)],
            rc,
            pkts,
            frames,
            term,
            info.duration_ms,
            info.file_size
        );
    }
    assert!(
        bad_points.is_empty(),
        "APE waveform peak[{}] mismatch: local={} vs http={}",
        bad_points[0].0,
        bad_points[0].1,
        bad_points[0].2
    );
    let tail_min = http_res.waveform_peaks[70..]
        .iter()
        .copied()
        .fold(f32::INFINITY, f32::min);
    let tail_max = http_res.waveform_peaks[70..]
        .iter()
        .copied()
        .fold(0.0f32, f32::max);
    assert!(
        (tail_max - tail_min) > 0.01,
        "APE HTTP waveform tail 70..100 must not be a flat constant pole: min={}, max={}",
        tail_min,
        tail_max
    );

    let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
    assert_eq!(deck.open_network_with_cancel(&url, None, None), 0);
    deck.play();
    pump_until_audible(&mut deck, "initial", fname);

    assert_eq!(deck.seek(150_000), 0);
    std::thread::sleep(Duration::from_millis(200));
    pump_until_audible(&mut deck, "seek(150s)", fname);
    assert!(!deck.decoder_eof.load(Ordering::Relaxed));
    let pos_150 = deck.position_ms.load(Ordering::Relaxed);
    assert!(
        (147_500..=156_500).contains(&pos_150),
        "unexpected APE pos after seek(150s): {}",
        pos_150
    );

    assert_eq!(deck.seek(40_000), 0);
    std::thread::sleep(Duration::from_millis(200));
    pump_until_audible(&mut deck, "seek(40s)", fname);
    assert!(!deck.decoder_eof.load(Ordering::Relaxed));
    let pos_40 = deck.position_ms.load(Ordering::Relaxed);
    assert!(
        (37_500..=45_500).contains(&pos_40),
        "unexpected APE pos after seek(40s): {}",
        pos_40
    );

    let _ = deck.stop();
    stop.store(true, Ordering::Release);
    let _ = srv.join();
}

#[test]
fn test_e7_wav_24bit_stereo_rapid_seek_stress_no_white_noise() {
    use miniaudio_player::core::dual_source::StreamingDeck;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    fn block_stats(samples: &[f32]) -> (f64, f64, f64) {
        let mut sum_sq = 0.0f64;
        let mut diff_sq = 0.0f64;
        let frames = samples.len() / 2;
        for f in 0..frames {
            let l = samples[f * 2];
            let r = samples[f * 2 + 1];
            assert!(
                l.is_finite() && r.is_finite() && l.abs() <= 2.5 && r.abs() <= 2.5,
                "invalid PCM sample l={}, r={}",
                l,
                r
            );
            sum_sq += (l as f64) * (l as f64) + (r as f64) * (r as f64);
            if f > 0 {
                let dl = (l - samples[(f - 1) * 2]) as f64;
                let dr = (r - samples[(f - 1) * 2 + 1]) as f64;
                diff_sq += dl * dl + dr * dr;
            }
        }
        let n = (frames * 2).max(1) as f64;
        let rms = (sum_sq / n).sqrt();
        let diff_rms = (diff_sq / ((frames.saturating_sub(1)) * 2).max(1) as f64).sqrt();
        let ratio = if rms > 1e-6 { diff_rms / rms } else { 0.0 };
        (rms, diff_rms, ratio)
    }

    fn assert_block_not_static(samples: &[f32], context: &str) {
        let (rms, diff_rms, ratio) = block_stats(samples);
        if rms > 0.05 && ratio >= 0.75 {
            let nonzero_frames = samples.chunks_exact(2).filter(|c| c[0].abs() > 1e-6 || c[1].abs() > 1e-6).count();
            eprintln!(
                "E7 DIAG [{}]: rms={:.4}, diff_rms={:.4}, ratio={:.4}, nonzero_frames={}/{}, first12={:?}",
                context,
                rms,
                diff_rms,
                ratio,
                nonzero_frames,
                samples.len() / 2,
                &samples[..samples.len().min(24)]
            );
            panic!(
                "{}: static/white-noise signature detected! rms={:.4}, diff_rms={:.4}, ratio={:.4}",
                context,
                rms,
                diff_rms,
                ratio
            );
        }
    }

    let fname = "12_Mi_más_bonita_coincidencia_24bit_stereo.wav";
    let local_path = FixtureResolver::resolve_str(fname);
    let (port, stop, srv) =
        spawn_http_fixture_server(&[fname], Some((256 * 1024, 64 * 1024, 15)));
    let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));

    for (mode, is_http) in [("http_206", true), ("local", false)] {
        let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
        let rc = if is_http {
            deck.open_network_with_cancel(&url, None, None)
        } else {
            deck.open_file(&local_path)
        };
        assert_eq!(rc, 0, "open failed in {} mode", mode);
        let dur_ms = deck.duration_ms.load(Ordering::Relaxed);
        assert!(dur_ms > 150_000, "{} dur_ms={}", mode, dur_ms);
        deck.play();
        pump_until_audible(&mut deck, "initial", mode);

        let mut render_buf = vec![0.0f32; 1024 * 2];
        for i in 0..220i64 {
            let target = ((i * 19_753 + 3_333) % (dur_ms - 8_000)).max(1_000);
            assert_eq!(deck.seek(target), 0);
            std::thread::sleep(Duration::from_millis(((i % 3) + 1) as u64));
            if let Some(ref mut r) = deck.renderer {
                r.render_pcm(render_buf.as_mut_ptr(), 1024);
                assert_block_not_static(&render_buf, &format!("{} burst iter {}", mode, i));
            }
        }

        // Ultra-fast 0ms slider drag burst + settled blocks immediately afterwards.
        for j in 0..100i64 {
            let target = ((j * 27_109 + 7_777) % (dur_ms - 8_000)).max(1_000);
            assert_eq!(deck.seek(target), 0);
            if j % 10 == 0 {
                if let Some(ref mut r) = deck.renderer {
                    r.render_pcm(render_buf.as_mut_ptr(), 1024);
                    assert_block_not_static(&render_buf, &format!("{} rapid-0ms iter {}", mode, j));
                }
            }
        }

        // Wait briefly after burst and verify sustained settled blocks remain clean music, not static.
        assert_eq!(deck.seek(65_000), 0);
        std::thread::sleep(Duration::from_millis(160));
        pump_until_audible(&mut deck, "post-burst settled", mode);
        for blk in 0..24 {
            if let Some(ref mut r) = deck.renderer {
                r.render_pcm(render_buf.as_mut_ptr(), 1024);
                assert_block_not_static(&render_buf, &format!("{} settled blk {}", mode, blk));
            }
            std::thread::sleep(Duration::from_millis(8));
        }
        assert!(!deck.decoder_eof.load(Ordering::Relaxed));

        let _ = deck.stop();
    }

    stop.store(true, Ordering::Release);
    let _ = srv.join();
}


#[test]
fn test_http_206_near_eof_and_unseekable_regression_e6b_e8_e9() {
    use miniaudio_player::bridge::ffi::MiniaudioBufferedRange;
    use miniaudio_player::core::dual_source::StreamingDeck;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let files = [
        "11_Mar_de_cristal.mka",
        "13_Overture_for_the_Floor.webm",
        "14_Painting_the_Sky.mkv",
        "15_Resting_At_Your_Feet.mp2",
    ];
    let (port, stop, srv) = spawn_http_fixture_server(&files, Some((256 * 1024, 64 * 1024, 15)));

    for (mode, is_http) in [("http_206", true), ("local", false)] {
        for fname in [
            "11_Mar_de_cristal.mka",
            "13_Overture_for_the_Floor.webm",
            "14_Painting_the_Sky.mkv",
        ] {
            let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
            if is_http {
                let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));
                assert_eq!(
                    deck.open_network_with_cancel(&url, None, None),
                    0,
                    "open failed for {} ({})",
                    fname,
                    mode
                );
            } else {
                let local = FixtureResolver::resolve_str(fname);
                assert_eq!(
                    deck.open_file(&local),
                    0,
                    "open failed for {} ({})",
                    fname,
                    mode
                );
            }
            let dur_ms = deck.duration_ms.load(Ordering::Relaxed);
            deck.play();
            pump_until_audible(&mut deck, "initial", fname);

            assert_eq!(deck.seek(dur_ms - 1_200), 0);
            let mut render_buf = vec![0.0f32; 1024 * 2];
            for _ in 0..200 {
                if let Some(ref mut r) = deck.renderer {
                    r.render_pcm(render_buf.as_mut_ptr(), 1024);
                    r.render_pcm(render_buf.as_mut_ptr(), 1024);
                }
                if deck.decoder_eof.load(Ordering::Relaxed) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(
                deck.decoder_eof.load(Ordering::Relaxed),
                "{} ({}): expected decoder_eof near end (dur={}, pos={}, buf_frames={}, is_buf={})",
                fname,
                mode,
                dur_ms,
                deck.position_ms.load(Ordering::Relaxed),
                deck.buffered_audio_frames(),
                deck.is_buffering.load(Ordering::Relaxed)
            );

            assert_eq!(deck.seek(30_000), 0);
            std::thread::sleep(Duration::from_millis(150));
            pump_until_audible(&mut deck, "backward-after-eof", fname);
            assert!(
                !deck.decoder_eof.load(Ordering::Relaxed),
                "{} ({}): decoder_eof stayed latched after backward seek(30s)",
                fname,
                mode
            );
            let pos_back = deck.position_ms.load(Ordering::Relaxed);
            assert!(
                (28_500..=36_000).contains(&pos_back),
                "{} ({}): unexpected pos after backward seek={}",
                fname,
                mode,
                pos_back
            );

            let _ = deck.stop();
        }
    }

    {
        let fname = "15_Resting_At_Your_Feet.mp2";
        let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));
        let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
        assert_eq!(deck.open_network_with_cancel(&url, None, None), 0);
        deck.play();
        pump_until_audible(&mut deck, "initial", fname);

        for target_ms in [40_000i64, 80_000, 120_000] {
            assert_eq!(deck.seek(target_ms), 0);
            std::thread::sleep(Duration::from_millis(120));
            pump_until_audible(&mut deck, &format!("seek({})", target_ms), fname);
            let pos = deck.position_ms.load(Ordering::Relaxed);
            assert!(
                (target_ms - 3_000..=target_ms + 5_000).contains(&pos),
                "{}: expected pos near {}, got {}",
                fname,
                target_ms,
                pos
            );
            let mut br = MiniaudioBufferedRange::default();
            assert_eq!(deck.get_buffered_range(&mut br), 0);
            assert!(
                br.end_ms >= target_ms - 2_000,
                "{}: buffered end frozen at {} after seek({})",
                fname,
                br.end_ms,
                target_ms
            );
        }

        let _ = deck.stop();
    }

    stop.store(true, Ordering::Release);
    let _ = srv.join();
}

/// Builds a synthetic mono/stereo DSD64 (2.8224 MHz) `.dsf` container from a 1-bit sigma-delta modulator
/// driven by `sample_fn(channel, sample_index, fs_dsd)`, plus optional trailing bytes past `data_end`.
fn build_synthetic_dsd64_dsf(
    channels: u32,
    sample_count_bits: u64,
    block_size_per_channel: usize,
    trailing_garbage: &[u8],
    mut sample_fn: impl FnMut(u32, u64, f64) -> f64,
) -> Vec<u8> {
    let raw_sr: u32 = 2_822_400;
    let total_blocks = ((sample_count_bits as usize) + block_size_per_channel * 8 - 1)
        / (block_size_per_channel * 8);
    let data_payload_bytes = total_blocks * (channels as usize) * block_size_per_channel;
    let data_chunk_size = 12u64 + data_payload_bytes as u64;
    let total_file_size = 28u64 + 52 + data_chunk_size + trailing_garbage.len() as u64;

    let mut dsf = Vec::with_capacity(total_file_size as usize);
    dsf.extend_from_slice(b"DSD ");
    dsf.extend_from_slice(&28u64.to_le_bytes());
    dsf.extend_from_slice(&total_file_size.to_le_bytes());
    dsf.extend_from_slice(&0u64.to_le_bytes());

    dsf.extend_from_slice(b"fmt ");
    dsf.extend_from_slice(&52u64.to_le_bytes());
    dsf.extend_from_slice(&1u32.to_le_bytes());
    dsf.extend_from_slice(&0u32.to_le_bytes());
    dsf.extend_from_slice(&(if channels == 1 { 1u32 } else { 2u32 }).to_le_bytes());
    dsf.extend_from_slice(&channels.to_le_bytes());
    dsf.extend_from_slice(&raw_sr.to_le_bytes());
    dsf.extend_from_slice(&1u32.to_le_bytes());
    dsf.extend_from_slice(&sample_count_bits.to_le_bytes());
    dsf.extend_from_slice(&(block_size_per_channel as u32).to_le_bytes());
    dsf.extend_from_slice(&0u32.to_le_bytes());

    dsf.extend_from_slice(b"data");
    dsf.extend_from_slice(&data_chunk_size.to_le_bytes());

    // 2nd-order error-feedback sigma-delta modulator per channel (LSB-first DSF bit packing).
    let mut err1 = vec![0.0f64; channels as usize];
    let mut err2 = vec![0.0f64; channels as usize];
    for blk in 0..total_blocks {
        for ch in 0..channels as usize {
            for b in 0..block_size_per_channel {
                let mut byte_val = 0u8;
                for bit in 0..8usize {
                    let bit_idx = (blk * block_size_per_channel + b) as u64 * 8 + bit as u64;
                    if bit_idx < sample_count_bits {
                        let x = sample_fn(ch as u32, bit_idx, raw_sr as f64);
                        let target = x + 1.5 * err1[ch] - 0.65 * err2[ch];
                        let y = if target >= 0.0 { 1.0 } else { -1.0 };
                        let e = target - y;
                        err2[ch] = err1[ch];
                        err1[ch] = e;
                        if y > 0.0 {
                            byte_val |= 1u8 << bit;
                        }
                    } else {
                        // Fill padded tail beyond sample_count with hostile alternating pattern / ones
                        byte_val |= ((bit & 1) as u8) << bit;
                    }
                }
                dsf.push(byte_val);
            }
        }
    }
    dsf.extend_from_slice(trailing_garbage);
    dsf
}

fn dft_tone_mag(samples: &[f32], freq_hz: f64, sr_hz: f64) -> f64 {
    let n = samples.len();
    let mut re = 0.0f64;
    let mut im = 0.0f64;
    let two_pi_f = 2.0 * std::f64::consts::PI * freq_hz / sr_hz;
    let mut w_sum = 0.0f64;
    for (i, &s) in samples.iter().enumerate() {
        let w = 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / n as f64).cos();
        w_sum += w;
        let phase = two_pi_f * i as f64;
        re += (s as f64) * w * phase.cos();
        im += (s as f64) * w * phase.sin();
    }
    2.0 * (re * re + im * im).sqrt() / w_sum.max(1.0)
}

#[test]
fn test_e13_dsd64_decimator_stopband_rejection_and_audible_fidelity() {
    use miniaudio_player::decoder::SymphoniaEngine;
    use std::f64::consts::PI;

    // 1. Audible passband fidelity + strict sample_count truncation:
    //    Decode 1 kHz + 18 kHz in 2nd-order SDM (peak <= 0.36 so SDM stays linear) + partial EOF trim.
    let block_sz = 4096usize;
    let bits_total = (block_sz * 8 * 12) as u64; // 12 blocks = 12,288 PCM samples @ 88.2k (~139 ms)
    let partial_pcm_cut = 11_776u64; // NOT a block boundary (11 blocks + 512 frames < 12 blocks)
    let bits_partial = partial_pcm_cut * 32;
    let dsf = build_synthetic_dsd64_dsf(1, bits_partial, block_sz, b"ID3v2_GARBAGE_TRAILER", |_ch, idx, fs| {
        let t = idx as f64 / fs;
        0.18 * (2.0 * PI * 1_000.0 * t).sin() + 0.16 * (2.0 * PI * 18_000.0 * t).sin()
    });

    let mut eng = SymphoniaEngine::new(std::io::Cursor::new(dsf), Some("dsf"))
        .expect("Failed to open synthetic DSD64 stream");
    assert_eq!(eng.sample_rate(), 88200);
    assert_eq!(eng.raw_sample_rate(), Some(2_822_400));

    let mut pcm = Vec::new();
    let mut pkt = Vec::new();
    while eng.decode_next_frame(&mut pkt).unwrap() {
        pcm.extend_from_slice(&pkt);
    }

    // Must trim strictly at total_pcm_samples_per_channel and never read trailing ID3 bytes.
    assert_eq!(
        pcm.len(),
        partial_pcm_cut as usize,
        "Expected exact trimmed PCM frame count {}, got {} (total_blocks_max={})",
        partial_pcm_cut,
        pcm.len(),
        bits_total / 32
    );

    // Measure settled middle window (after initial transient)
    let slice = &pcm[2048..10240];
    let mag_1k = dft_tone_mag(slice, 1_000.0, 88_200.0);
    let mag_18k = dft_tone_mag(slice, 18_000.0, 88_200.0);
    let passband_droop_db = 20.0 * (mag_18k / 0.16 / (mag_1k / 0.18)).log10();

    assert!(
        (mag_1k - 0.18).abs() < 0.015,
        "1 kHz amplitude inaccurate: got {:.4} expected 0.18",
        mag_1k
    );
    assert!(
        passband_droop_db > -0.5,
        "Excessive passband droop at 18 kHz: {:.2} dB",
        passband_droop_db
    );

    // 2. Ultrasonic alias rejection: with M=32 (88.2 kHz), 95 kHz folds directly to |95 - 88.2| = 6.8 kHz
    //    unless the decimator LPF suppresses >= 80 dB above Nyquist. (Single tone avoids multi-tone SDM IMD.)
    let pure_hi = build_synthetic_dsd64_dsf(1, bits_total, block_sz, b"", |_ch, idx, fs| {
        let t = idx as f64 / fs;
        0.30 * (2.0 * PI * 95_000.0 * t).sin()
    });
    let mut eng2 = SymphoniaEngine::new(std::io::Cursor::new(pure_hi), Some("dsf")).unwrap();
    let mut pcm2 = Vec::new();
    while eng2.decode_next_frame(&mut pkt).unwrap() {
        pcm2.extend_from_slice(&pkt);
    }
    let settled = &pcm2[2048..10240];
    let alias_6k8 = dft_tone_mag(settled, 6_800.0, 88_200.0);
    let fold_rejection_db = 20.0 * ((alias_6k8 / 0.30).max(1e-7)).log10();
    assert!(
        fold_rejection_db < -65.0,
        "95 kHz ultrasonic tone aliased to 6.8 kHz at {:.2} dB (expected < -65 dB, unfixed 64-tap leaked > -15 dB)!",
        fold_rejection_db
    );
}

#[test]
fn test_e13_dsf_real_track_local_and_http_206_no_ultrasonic_aliasing() {
    use miniaudio_player::core::dual_source::StreamingDeck;
    use miniaudio_player::decoder::SymphoniaEngine;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    let fname = "29_駆け抜けて、この空を.dsf";
    let path = FixtureResolver::resolve_str(fname);

    // 1. Local SymphoniaEngine band energy check: [32..44.1 kHz] ultrasonic noise floor must be >= 60 dB below [0..16 kHz].
    let mut eng = SymphoniaEngine::new(std::fs::File::open(&path).unwrap(), Some("dsf"))
        .expect("Failed to open real DSF fixture");
    assert_eq!(eng.sample_rate(), 88200);
    assert_eq!(eng.raw_sample_rate(), Some(2_822_400));
    assert_eq!(eng.channels(), 1);
    eng.seek_ms(30_000).expect("DSF seek_ms(30s) failed");

    let mut pcm = Vec::with_capacity(88200);
    let mut pkt = Vec::new();
    while pcm.len() < 4096 * 4 && eng.decode_next_frame(&mut pkt).unwrap() {
        pcm.extend_from_slice(&pkt);
    }
    let seg = &pcm[2048..2048 + 4096];
    let mut low_e = 0.0f64;
    let mut ultra_e = 0.0f64;
    for bin_hz in (500..=16_000).step_by(250) {
        let m = dft_tone_mag(seg, bin_hz as f64, 88_200.0);
        low_e += m * m;
    }
    for bin_hz in (32_000..=43_500).step_by(250) {
        let m = dft_tone_mag(seg, bin_hz as f64, 88_200.0);
        ultra_e += m * m;
    }
    let ratio_db = 10.0 * (ultra_e / low_e.max(1e-24)).log10();
    assert!(
        ratio_db < -60.0,
        "Excessive ultrasonic DSD64 residual noise in 32..43.5 kHz: {:.2} dB vs audible (expected < -60 dB)",
        ratio_db
    );

    // 2. HTTP 206 playback + near-EOF seek (174s) + seek-back (15s) cleanly recovers without white noise or premature EOF.
    let (port, stop, srv) = spawn_http_fixture_server(&[fname], Some((256 * 1024, 64 * 1024, 15)));
    let url = format!("http://127.0.0.1:{}/{}", port, encode_url_path(fname));
    let mut deck = StreamingDeck::new_deck(48000, 2, 1024).unwrap();
    assert_eq!(deck.open_network_with_cancel(&url, None, None), 0);
    let dur = deck.duration_ms.load(Ordering::Relaxed);
    assert!(
        (174_000..=178_000).contains(&dur),
        "Unexpected DSF HTTP duration_ms={}",
        dur
    );
    deck.play();
    pump_until_audible(&mut deck, "dsf_http_init", "29_.dsf");

    assert_eq!(deck.seek(174_000), 0);
    std::thread::sleep(Duration::from_millis(120));
    pump_until_audible(&mut deck, "dsf_http_near_end", "29_.dsf");

    assert_eq!(deck.seek(15_000), 0);
    std::thread::sleep(Duration::from_millis(120));
    pump_until_audible(&mut deck, "dsf_http_seek_back", "29_.dsf");
    let pos_after = deck.position_ms.load(Ordering::Relaxed);
    assert!(
        (12_000..=20_000).contains(&pos_after),
        "Expected DSF position near 15000ms after seek back, got {}",
        pos_after
    );

    let _ = deck.stop();
    stop.store(true, Ordering::Release);
    let _ = srv.join();
}
