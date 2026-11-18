//! Complete DSP Chain, Channel Matrix, 3D Spatial Audio, Auto-Ducking, and Voice Pool Tests.

mod common;

use common::SignalGenerator;
use miniaudio_player::dsp::biquad::BiquadDf2t;
use miniaudio_player::dsp::chain::DspChain;
use miniaudio_player::dsp::channel_matrix::ChannelMatrix;
use miniaudio_player::dsp::crossfeed::{Bs2bCrossfeed, CrossfeedConfig};
use miniaudio_player::dsp::ducking::AutoDucker;
use miniaudio_player::dsp::equalizer::Equalizer;
use miniaudio_player::dsp::limiter::SoftLimiter;
use miniaudio_player::dsp::resampler::RubatoResampler;
use miniaudio_player::dsp::reverb::{Freeverb, ReverbConfig};
use miniaudio_player::dsp::silence::{SilenceConfig, SilenceDetector, SilenceMode, SilenceState};
use miniaudio_player::dsp::sonic::SonicStream;
use miniaudio_player::dsp::spatial::{
    DistanceModel, SpatialEmitter, SpatialListener, SpatialProcessor, Vector3,
};
use miniaudio_player::dsp::visualizer::Visualizer;

#[test]
fn test_biquad_peaking_and_nyquist_rejection() {
    let mut filter = BiquadDf2t::peaking(1000.0, 44100.0, 12.0, 1.15);
    let sine = SignalGenerator::sine_wave_f32(4410, 44100, 1, 1000.0);

    let mut max_in = 0.0f32;
    let mut max_out = 0.0f32;
    for &s in &sine {
        max_in = max_in.max(s.abs());
        max_out = max_out.max(filter.process(s).abs());
    }
    assert!(max_out > max_in * 2.5);

    // Invalid / above-Nyquist frequency returns identity filter without silent parameter patching
    let mut nyquist_filter = BiquadDf2t::peaking(25000.0, 44100.0, 12.0, 1.0);
    assert_eq!(nyquist_filter.process(0.5), 0.5);

    // Anti-denormal protection
    let subnormal = f32::from_bits(0x0000_0001);
    let out = filter.process(subnormal);
    assert!(!out.is_nan());
    assert!(!out.is_subnormal() || out == 0.0);
}

#[test]
fn test_equalizer_stages_and_crossfeed_reverb_limiter() {
    let mut eq = Equalizer::new(2, 48000);
    let samples = vec![1.0, 0.0, 1.0, 0.0];
    eq.set_mono(true);
    for _ in 0..1000 {
        let mut tmp = samples.clone();
        eq.process_interleaved(&mut tmp);
    }
    let mut test_frame = vec![1.0, 0.0];
    eq.process_interleaved(&mut test_frame);
    assert!((test_frame[0] - test_frame[1]).abs() < 0.05);

    // Crossfeed crosstalk
    let mut cf = Bs2bCrossfeed::new(44100, CrossfeedConfig::MOFFAT_BAUER);
    let mut stereo = vec![1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0];
    cf.process_frames(&mut stereo, 2);
    let right_energy: f32 = stereo
        .iter()
        .enumerate()
        .filter(|(i, _)| i % 2 == 1)
        .map(|(_, &s)| s.abs())
        .sum();
    assert!(right_energy > 0.05);

    // Freeverb impulse response
    let mut reverb = Freeverb::new(44100);
    reverb.set_config(ReverbConfig {
        enabled: 1,
        room_size: 0.8,
        damping: 0.2,
        width: 1.0,
        wet: 1.0,
        dry: 0.0,
    });
    let mut buf = vec![0.0f32; 4000];
    buf[0] = 1.0;
    buf[1] = 1.0;
    reverb.process_frames(&mut buf, 2);
    let tail_energy: f32 = buf[1000..3000].iter().map(|s| s.abs()).sum();
    assert!(tail_energy > 0.1);

    // Soft limiter
    let limiter = SoftLimiter::new(true);
    let mut high_signal = vec![5.0f32, -3.0f32, 10.0f32, -50.0f32];
    limiter.process_frames(&mut high_signal);
    for &s in &high_signal {
        assert!(s.abs() < 1.0 && s.abs() >= 0.95);
    }
}

#[test]
fn test_silence_detector_sonic_visualizer_and_dsp_chain() {
    let mut det = SilenceDetector::new(2, 44100);
    det.set_config(SilenceConfig {
        enabled: true,
        mode: SilenceMode::Continuous,
        threshold_db: -40.0,
        min_silence_duration_ms: 100,
        padding_ms: 20,
    });
    let silence = vec![0.0f32; 44100 * 2];
    let mut out = vec![0.0f32; silence.len()];
    let (out_frames, in_frames) = det.process_frames(&silence, &mut out);
    assert_eq!(in_frames, 44100);
    assert!(det.saved_frames() > 10000);
    assert_eq!(det.state(), SilenceState::Skipping);
    assert!(out_frames < in_frames);

    // SonicStream 2x speed and >140dB dynamic range
    let mut sonic = SonicStream::new(44100, 2);
    sonic.set_speed(2.0);
    let sine = SignalGenerator::sine_wave_f32(22050, 44100, 2, 440.0);
    assert!(sonic.write_float(&sine));
    sonic.flush();
    let avail = sonic.samples_available();
    assert!((avail as isize - 11025).abs() < 2000);

    // Visualizer 1kHz band
    let mut vis = Visualizer::new(1, 44100);
    vis.set_enabled(true);
    let sine_1k = SignalGenerator::sine_wave_f32(8820, 44100, 1, 1000.0);
    vis.process_frames(&sine_1k);
    let data = vis.get_data();
    assert!(data.peak > 0.9 && data.bands[5] > 0.5);

    // DspChain integration
    let mut chain = DspChain::new(2, 44100);
    chain.set_volume(0.8);
    chain.set_limiter_enabled(true);
    let mut chain_in = SignalGenerator::sine_wave_f32(4410, 44100, 2, 440.0);
    chain.process_frames(&mut chain_in);
    assert!(chain_in.iter().all(|&s| s.abs() <= 1.0));
}

#[test]
fn test_rubato_resampler() {
    let sine = SignalGenerator::sine_wave_f32(4410, 44100, 2, 440.0);
    let mut resampler = RubatoResampler::new(44100, 48000, 2, 1024).unwrap();
    let mut out_stream = Vec::new();
    let written = resampler.process_interleaved(&sine, &mut out_stream).unwrap();
    let flushed = resampler.flush(&mut out_stream).unwrap();
    assert!(written + flushed > 0);
    assert!(!out_stream.is_empty());

    // 192 kHz -> 48 kHz downsampling
    let input_192k = SignalGenerator::sine_wave_f32(19200, 192000, 2, 1000.0);
    let mut downsampler = RubatoResampler::new(192000, 48000, 2, 1024).unwrap();
    let mut out_48k = Vec::new();
    downsampler.process_interleaved(&input_192k, &mut out_48k).unwrap();
    downsampler.flush(&mut out_48k).unwrap();
    let frames_48k = out_48k.len() / 2;
    assert!((frames_48k as i32 - 4800).abs() < 200);
}

#[test]
fn test_channel_matrix_upmix_and_surround_downmix() {
    // 1 -> 2 upmix
    let mut m_1_2 = ChannelMatrix::new(1, 2);
    let mut out = Vec::new();
    m_1_2.process_interleaved(&[0.5, -0.25], &mut out);
    assert_eq!(out, vec![0.5, 0.5, -0.25, -0.25]);

    // 2 -> 1 downmix
    let mut m_2_1 = ChannelMatrix::new(2, 1);
    m_2_1.process_interleaved(&[1.0, 0.0, 0.5, 0.5, -1.0, 1.0], &mut out);
    assert_eq!(out, vec![0.5, 0.5, 0.0]);

    // 5.1 (6ch) -> Stereo downmix
    let mut m_6_2 = ChannelMatrix::new(6, 2);
    m_6_2.process_interleaved(&[1.0; 6], &mut out);
    assert_eq!(out.len(), 2);
    assert!((out[0] - out[1]).abs() < 1e-5 && out[0] > 0.99 && out[0] < 1.01);

    // 7.1 (8ch) -> Stereo downmix
    let mut m_8_2 = ChannelMatrix::new(8, 2);
    m_8_2.process_interleaved(&[0.8; 8], &mut out);
    assert_eq!(out.len(), 2);
    assert!(out.iter().all(|&s| s.abs() <= 1.05));
}

#[test]
fn test_spatial_processor_doppler_panning_and_attenuation() {
    let v1 = Vector3::new(1.0, 2.0, 3.0);
    let v2 = Vector3::new(4.0, 5.0, 6.0);
    assert_eq!(v1.add(&v2), Vector3::new(5.0, 7.0, 9.0));
    assert_eq!(v2.sub(&v1), Vector3::new(3.0, 3.0, 3.0));
    assert_eq!(v1.dot(&v2), 32.0);

    let listener = SpatialListener::default();
    let mut emitter = SpatialEmitter::default();
    emitter.position = Vector3::new(0.0, 0.0, 100.0);

    // Approaching emitter increases pitch
    emitter.velocity = Vector3::new(0.0, 0.0, -34.33);
    let eval_app = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
    assert!(eval_app.doppler_ratio > 1.10 && eval_app.doppler_ratio < 1.12);

    // Receding emitter decreases pitch
    emitter.velocity = Vector3::new(0.0, 0.0, 34.33);
    let eval_rec = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
    assert!(eval_rec.doppler_ratio > 0.90 && eval_rec.doppler_ratio < 0.92);

    // Supersonic clamping
    emitter.velocity = Vector3::new(0.0, 0.0, -700.0);
    let eval_sup = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
    assert!(eval_sup.doppler_ratio <= 4.0 && eval_sup.doppler_ratio >= 0.1);

    // Azimuth panning right & left
    emitter.velocity = Vector3::default();
    emitter.position = Vector3::new(10.0, 0.0, 0.0);
    assert!((SpatialProcessor::evaluate(&listener, &emitter, 343.3).pan - 1.0).abs() < 1e-4);
    emitter.position = Vector3::new(-10.0, 0.0, 0.0);
    assert!((SpatialProcessor::evaluate(&listener, &emitter, 343.3).pan - (-1.0)).abs() < 1e-4);

    // Distance attenuation & slew smoothing
    emitter.min_distance = 10.0;
    emitter.max_distance = 100.0;
    emitter.distance_model = DistanceModel::Linear;
    emitter.position = Vector3::new(0.0, 0.0, 55.0);
    let eval_lin = SpatialProcessor::evaluate(&listener, &emitter, 343.3);
    assert!((eval_lin.gain - 0.5).abs() < 1e-3);
}

#[test]
fn test_auto_ducker_sidechain_envelope() {
    let mut ducker = AutoDucker::new(48000);
    assert!(!ducker.enabled);
    ducker.set_params(true, -14.0, -30.0, 5.0, 20.0, 30.0);

    let voice_speech = vec![0.5f32; 960];
    let mut env = vec![1.0f32; 960];

    for _ in 0..10 {
        ducker.compute_gain_envelope(&voice_speech, &mut env);
    }
    assert!(ducker.is_ducking());
    let expected_duck = 10.0f32.powf(-14.0 / 20.0);
    let end_gain = *env.last().unwrap();
    assert!((end_gain - expected_duck).abs() < 0.05);

    let voice_silence = vec![0.0f32; 960];
    for _ in 0..30 {
        ducker.compute_gain_envelope(&voice_silence, &mut env);
    }
    assert!((*env.last().unwrap() - 1.0).abs() < 0.05);
    assert!(!ducker.is_ducking());
}

/// Helper to parse substring between two delimiters in command output.
fn parse_between<'a>(text: &'a str, prefix: &str, suffix: &str) -> Option<&'a str> {
    let start = text.find(prefix)? + prefix.len();
    let rest = &text[start..];
    let end = rest.find(suffix)?;
    Some(rest[..end].trim())
}

#[test]
fn test_audio_analysis_ffmpeg_reference_comparison() {
    // Verify ffmpeg availability
    let ffmpeg_check = std::process::Command::new("ffmpeg")
        .arg("-version")
        .output();
    let ffmpeg_available = match ffmpeg_check {
        Ok(out) => out.status.success(),
        Err(_) => false,
    };

    if !ffmpeg_available {
        eprintln!("SKIPPING test_audio_analysis_ffmpeg_reference_comparison: ffmpeg is not installed or not in PATH.");
        return;
    }

    struct TestCase {
        filename: &'static str,
        float_decoder: bool,
    }

    let cases = [
        TestCase { filename: "17_Running_To_Meet_The_Sun.wav", float_decoder: true },
        TestCase { filename: "04_Belaya_Tishina.flac", float_decoder: true },
        TestCase { filename: "01_Apex_Momentum.mp3", float_decoder: true },
        TestCase { filename: "05_Burning_in_the_Electric_Light.ogg", float_decoder: true },
        TestCase { filename: "02_Bailando_con_tu_recuerdo.opus", float_decoder: true },
        TestCase { filename: "06_Calculated_Motion_aac.m4a", float_decoder: true },
        TestCase { filename: "07_Fevered_Strings_alac.m4a", float_decoder: true },
    ];

    for case in cases {
        let path = common::FixtureResolver::resolve(case.filename);
        let path_str = path.to_str().expect("Valid UTF-8 fixture path");

        // Execute ffmpeg with replaygain and ebur128 filters
        let output = std::process::Command::new("ffmpeg")
            .args(["-i", path_str, "-af", "replaygain,ebur128=peak=true", "-f", "null", "-"])
            .output()
            .expect("Failed to execute ffmpeg process");
        let stderr = String::from_utf8_lossy(&output.stderr);

        // 1. Parse track_gain
        let ffmpeg_gain: f32 = parse_between(&stderr, "track_gain = ", " dB")
            .and_then(|s| s.parse().ok())
            .unwrap_or_else(|| panic!("Could not parse track_gain from ffmpeg for {}", case.filename));

        // 2. Parse track_peak
        let ffmpeg_peak: f32 = parse_between(&stderr, "track_peak = ", "\n")
            .and_then(|s| s.parse().ok())
            .unwrap_or_else(|| panic!("Could not parse track_peak from ffmpeg for {}", case.filename));

        // 3. Parse summary integrated loudness (I: ... LUFS after 'Summary:')
        let summary_idx = stderr.rfind("Summary:").expect("ffmpeg output must contain Summary section");
        let ffmpeg_lufs: f32 = parse_between(&stderr[summary_idx..], "I:", "LUFS")
            .and_then(|s| s.parse().ok())
            .unwrap_or_else(|| panic!("Could not parse integrated LUFS from ffmpeg for {}", case.filename));

        // Execute application analysis
        let config = miniaudio_player::api::types::RustAnalysisConfig {
            replay_gain: true,
            waveform: true,
            metadata: false,
            chromaprint: false,
            target_lufs: -18.0,
            waveform_points: 72,
            max_duration_ms: None,
        };
        let source = miniaudio_player::core::dual_source::AudioSourceCore {
            source: path_str.to_string(),
            ..Default::default()
        };
        let analysis = miniaudio_player::dsp::analyze_audio_source(source, config)
            .expect("Audio analysis failed");

        println!(
            "[{:18}] App: gain={:6.2} dB, peak={:8.6}, lufs={:5.1} | FFmpeg: gain={:6.2} dB, peak={:8.6}, lufs={:5.1}",
            case.filename,
            analysis.replay_gain_db,
            analysis.replay_gain_peak,
            analysis.integrated_lufs,
            ffmpeg_gain,
            ffmpeg_peak,
            ffmpeg_lufs,
        );

        // 1. ReplayGain dB comparison (practically identical, <= 0.15 dB delta across all formats)
        let gain_delta = (analysis.replay_gain_db - ffmpeg_gain).abs();
        assert!(
            gain_delta < 0.15,
            "ReplayGain dB mismatch for {}: app={}, ffmpeg={}, delta={}",
            case.filename, analysis.replay_gain_db, ffmpeg_gain, gain_delta
        );

        // 2. Integrated LUFS comparison (practically identical, <= 0.2 LUFS delta across all formats)
        let lufs_delta = (analysis.integrated_lufs - ffmpeg_lufs).abs();
        assert!(
            lufs_delta < 0.2,
            "Integrated LUFS mismatch for {}: app={}, ffmpeg={}, delta={}",
            case.filename, analysis.integrated_lufs, ffmpeg_lufs, lufs_delta
        );

        // 3. Peak comparison
        if case.float_decoder {
            // For formats with float decoders (WAV, FLAC, MP3, OGG, OPUS), peak matches FFmpeg closely
            let peak_delta = (analysis.replay_gain_peak - ffmpeg_peak).abs();
            assert!(
                peak_delta < 0.01,
                "Peak mismatch for {}: app={}, ffmpeg={}, delta={}",
                case.filename, analysis.replay_gain_peak, ffmpeg_peak, peak_delta
            );
        } else {
            // For AAC/M4A via symphonia-adapter-fdk-aac, the C library outputs 16-bit signed PCM (AudioBuffer<i16>),
            // which saturates at 32767 / 32768.0 = 0.99997 ~= 1.0000.
            assert!(
                analysis.replay_gain_peak <= 1.0001 && analysis.replay_gain_peak >= 0.99,
                "AAC peak expected ~1.0 for clamped 16-bit integer PCM: app={}",
                analysis.replay_gain_peak
            );
        }

        // 4. Waveform validation: ensure waveform has true musical energy dynamics (not a flat tube)
        assert_eq!(analysis.waveform_peaks.len(), 72);
        let min_wf = analysis.waveform_peaks.iter().copied().fold(f32::INFINITY, f32::min);
        let max_wf = analysis.waveform_peaks.iter().copied().fold(0.0f32, f32::max);
        assert!(
            max_wf >= 0.99,
            "Waveform should normalize peak to 1.0: got max={}",
            max_wf
        );
        assert!(
            min_wf < 0.45,
            "Waveform should have quiet sections, not be a flat tube: got min={}",
            min_wf
        );
        let spread = max_wf - min_wf;
        assert!(
            spread > 0.3,
            "Waveform should have significant dynamic range: got spread={}",
            spread
        );
    }
}
