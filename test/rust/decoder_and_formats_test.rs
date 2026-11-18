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
                    let name = raw_path.trim_start_matches('/').replace("%20", " ");
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
            let encoded = spec.name.replace(' ', "%20");
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
}

