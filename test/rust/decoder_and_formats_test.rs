//! Comprehensive Format Sniffer, Decoder Engine, and All-Format Fixture Validation Suite.
//!
//! Validates all 26 audio container/codec fixtures listed in `test/fixtures/MANIFEST.md`
//! using strictly relative path resolution via `FixtureResolver`.

mod common;

use std::fs::File;
use std::io::Read;

use common::{FixtureResolver, SignalGenerator};
use miniaudio_player::buffer::{BufferStreamReader, TripartiteBuffer};
use miniaudio_player::decoder::dsf::{DsfProbe, DsfReader};
use miniaudio_player::decoder::sniffer::{BoundaryStatus, ContainerFormat, FormatSniffer};
use miniaudio_player::decoder::symphonia_engine::{create_codec_registry, SymphoniaEngine};
use miniaudio_player::dsp::channel_matrix::ChannelMatrix;
use miniaudio_player::dsp::resampler::RubatoResampler;
use miniaudio_player::sync::ring_buffer::AudioRingBuffer;
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::io::MediaSource;

#[test]
fn test_sniffer_wav_and_id3v1_tail_detection() {
    let wav_data = SignalGenerator::pcm16_wav_bytes(500, 48000, 2);
    let (status, info) = FormatSniffer::detect_head_boundary(&wav_data, wav_data.len() as i64);

    assert_eq!(status, BoundaryStatus::Found);
    assert_eq!(info.container, ContainerFormat::Wav);
    assert_eq!(info.audio_start, 44);
    assert_eq!(info.audio_end, wav_data.len() as i64);
    assert_eq!(info.bytes_per_frame, 4);
    assert_eq!(info.wav_data_size_field_offset, 40);

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

    let (t_status, audio_end) = FormatSniffer::detect_tail_boundary(
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

    let buf = TripartiteBuffer::new(wav_bytes.len(), Some(wav_bytes.len() as u64), false);
    buf.set_head(&wav_bytes[0..44]);
    buf.set_audio_start(44);
    buf.set_audio_end(wav_bytes.len() as u64);
    buf.feed_chunk(&wav_bytes[44..]).unwrap();
    buf.mark_eof();

    let reader = BufferStreamReader::new(buf);
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
        "salida.wav",
        "test_24bit.wav",
        "test_24bit_stereo.wav",
        "salida.rf64",
        "salida.rifx",
        "salida.w64",
        "salida.bwf",
        "salida.aif",
        "salida.aiff",
        "salida.aifc",
        "salida.caf",
        "salida.flac",
        "salida_alac.m4a",
        "salida_aac.m4a",
        "salida.aac",
        "salida.mp3",
        "cbr_noxing.mp3",
        "salida.mp2",
        "salida.ogg",
        "salida.oga",
        "salida.opus",
        "salida.webm",
        "salida.mka",
        "salida.wv",
        "salida.dsf",
        "salida.ape",
    ];

    for filename in &all_fixtures {
        let path = FixtureResolver::resolve(filename);
        let file = File::open(&path).unwrap_or_else(|e| panic!("Failed to open {}: {}", filename, e));
        let ext = FormatSniffer::extract_extension_hint(filename);

        let mut engine = SymphoniaEngine::new(file, ext)
            .unwrap_or_else(|e| panic!("SymphoniaEngine failed to open {}: {}", filename, e));

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
        if *filename != "salida.aac" {
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
    for (filename, ext) in &[("salida.flac", "flac"), ("salida_alac.m4a", "m4a")] {
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

    // Mono upmix check on cbr_noxing.mp3
    let mp3_file = File::open(FixtureResolver::resolve("cbr_noxing.mp3")).unwrap();
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
    for (filename, hint) in &[("salida.mp3", Some("mp3")), ("salida.aif", None)] {
        let mut file = File::open(FixtureResolver::resolve(filename)).unwrap();
        let total_len = file.metadata().unwrap().len();
        let mut initial_data = vec![0u8; 65536];
        let n = file.read(&mut initial_data).unwrap();
        initial_data.truncate(n);

        let buf = TripartiteBuffer::new(2 * 1024 * 1024, Some(total_len), false);
        let (_, boundary) = FormatSniffer::detect_head_boundary(&initial_data, total_len as i64);
        if boundary.audio_start > 0 {
            let head_len = (boundary.audio_start as usize).min(initial_data.len());
            buf.set_head(&initial_data[..head_len]);
            buf.set_audio_start(boundary.audio_start as u64);
            if initial_data.len() > head_len {
                buf.feed_chunk(&initial_data[head_len..]).unwrap();
            }
        } else {
            buf.set_audio_start(0);
            buf.feed_chunk(&initial_data).unwrap();
        }

        let reader = BufferStreamReader::new(buf);
        let engine = SymphoniaEngine::new(reader, *hint)
            .unwrap_or_else(|e| panic!("Stream probe failed for {}: {}", filename, e));
        assert!(engine.sample_rate() > 0);
        assert!(engine.channels() > 0);
    }
}
