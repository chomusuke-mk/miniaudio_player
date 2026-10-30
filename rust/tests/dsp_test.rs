use miniaudio_player::dsp::biquad::BiquadDf2t;
use miniaudio_player::dsp::chain::DspChain;
use miniaudio_player::dsp::crossfeed::{Bs2bCrossfeed, CrossfeedMode};
use miniaudio_player::dsp::equalizer::Equalizer;
use miniaudio_player::dsp::limiter::SoftLimiter;
use miniaudio_player::dsp::reverb::{Freeverb, ReverbConfig};
use miniaudio_player::dsp::silence::{SilenceConfig, SilenceDetector, SilenceMode, SilenceState};
use miniaudio_player::dsp::sonic::SonicStream;
use miniaudio_player::dsp::visualizer::Visualizer;
use std::f32::consts::PI;

fn generate_sine(freq: f32, sample_rate: u32, duration_secs: f32, channels: usize) -> Vec<f32> {
    let num_frames = (sample_rate as f32 * duration_secs) as usize;
    let mut out = Vec::with_capacity(num_frames * channels);
    for i in 0..num_frames {
        let t = i as f32 / sample_rate as f32;
        let s = (t * freq * 2.0 * PI).sin();
        for _ in 0..channels {
            out.push(s);
        }
    }
    out
}

#[test]
fn test_biquad_peaking_boost() {
    let sample_rate = 44100;
    let f0 = 1000.0;
    let mut filter = BiquadDf2t::peaking(f0, sample_rate as f64, 12.0, 1.15); // +12 dB boost

    let sine = generate_sine(f0 as f32, sample_rate, 0.1, 1);
    let mut max_in = 0.0f32;
    let mut max_out = 0.0f32;

    for &s in &sine {
        max_in = max_in.max(s.abs());
        let out = filter.process(s);
        max_out = max_out.max(out.abs());
    }

    assert!(max_out > max_in * 2.5, "12dB boost should multiply amplitude by ~4x, got {}", max_out / max_in);
}

#[test]
fn test_biquad_anti_denormal() {
    let mut filter = BiquadDf2t::peaking(1000.0, 44100.0, 0.0, 1.0);
    // Feed subnormal float
    let subnormal = f32::from_bits(0x0000_0001); // ~1.4e-45
    let out = filter.process(subnormal);
    assert!(!out.is_nan());
    assert!(!out.is_subnormal() || out == 0.0);
}

#[test]
fn test_equalizer_balance_and_mono() {
    let sample_rate = 48000;
    let mut eq = Equalizer::new(2, sample_rate);

    // Left = 1.0, Right = 0.0
    let samples = vec![1.0, 0.0, 1.0, 0.0];
    eq.set_mono(true);
    // Process multiple frames so smooth gains settle
    for _ in 0..1000 {
        let mut tmp = samples.clone();
        eq.process_interleaved(&mut tmp);
    }

    let mut test_frame = vec![1.0, 0.0];
    eq.process_interleaved(&mut test_frame);
    // In mono, both channels should be approximately equal (0.5)
    assert!((test_frame[0] - test_frame[1]).abs() < 0.05);
}

#[test]
fn test_crossfeed_crosstalk() {
    let sample_rate = 44100;
    let mut cf = Bs2bCrossfeed::new(sample_rate, CrossfeedMode::MoffatBauer);

    // Hard-panned left signal
    let mut stereo = vec![1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0];
    cf.process_frames(&mut stereo, 2);

    // Right channel should now receive non-zero binaural crossfeed signal
    let right_energy: f32 = stereo.iter().enumerate().filter(|(i, _)| i % 2 == 1).map(|(_, &s)| s.abs()).sum();
    assert!(right_energy > 0.05, "Crossfeed should produce audible crosstalk in right channel");
}

#[test]
fn test_freeverb_impulse_response() {
    let sample_rate = 44100;
    let mut reverb = Freeverb::new(sample_rate);
    reverb.set_config(ReverbConfig {
        enabled: 1,
        room_size: 0.8,
        damping: 0.2,
        width: 1.0,
        wet: 1.0,
        dry: 0.0,
    });

    // 1 impulse followed by 2000 zeroes
    let mut buf = vec![0.0f32; 4000];
    buf[0] = 1.0;
    buf[1] = 1.0;

    reverb.process_frames(&mut buf, 2);

    // Later samples should have energy from the reverberant tail
    let tail_energy: f32 = buf[1000..3000].iter().map(|s| s.abs()).sum();
    assert!(tail_energy > 0.1, "Reverb should produce a decaying tail");
}

#[test]
fn test_soft_limiter() {
    let limiter = SoftLimiter::new(true);

    // Feed signal well above 0 dBFS (e.g. 5.0)
    let mut high_signal = vec![5.0f32, -3.0f32, 10.0f32, -50.0f32];
    limiter.process_frames(&mut high_signal);

    for &s in &high_signal {
        assert!(s.abs() < 1.0, "Limiter must strictly protect against clipping <= 1.0, got {}", s);
        assert!(s.abs() >= 0.95, "Limiter should soft-knee compress in [0.95..1.0), got {}", s);
    }
}

#[test]
fn test_silence_detector_skipping() {
    let sample_rate = 44100;
    let channels = 2;
    let mut det = SilenceDetector::new(channels, sample_rate);
    det.set_config(SilenceConfig {
        mode: SilenceMode::Continuous,
        threshold_db: -40.0,
        min_silence_duration_ms: 100, // 100ms
        padding_ms: 20,
    });

    // 1 second of complete silence
    let silence = vec![0.0f32; sample_rate as usize * channels];
    let mut out = vec![0.0f32; silence.len()];

    let (out_frames, in_frames) = det.process_frames(&silence, &mut out);

    assert_eq!(in_frames, sample_rate as usize);
    // Most frames should have been skipped, saving time!
    assert!(det.saved_frames() > 10000);
    assert_eq!(det.state(), SilenceState::Skipping);
    assert!(out_frames < in_frames);
}

#[test]
fn test_sonic_speed_and_pitch() {
    let sample_rate = 44100;
    let channels = 2;
    let mut sonic = SonicStream::new(sample_rate, channels);
    sonic.set_speed(2.0); // 2x speed

    let sine = generate_sine(440.0, sample_rate, 0.5, channels); // 0.5s audio
    let ok = sonic.write_float(&sine);
    assert!(ok);
    sonic.flush();

    let avail = sonic.samples_available();
    // At 2x speed, output frames should be roughly half (within 20% tolerance of PICOLA overlap windows)
    let expected = (sine.len() / channels) / 2;
    let diff = (avail as isize - expected as isize).abs();
    assert!(diff < 2000, "2x speed should output ~{} frames, got {}", expected, avail);

    let mut out_samples = vec![0.0f32; avail * channels];
    let read = sonic.read_float(&mut out_samples);
    assert_eq!(read, avail);
}

#[test]
fn test_visualizer_frequency_response() {
    let sample_rate = 44100;
    let mut vis = Visualizer::new(1, sample_rate);
    vis.set_enabled(true);

    // 1000 Hz sine wave
    let sine = generate_sine(1000.0, sample_rate, 0.2, 1);
    vis.process_frames(&sine);

    let data = vis.get_data();
    assert!(data.peak > 0.9);
    assert!(data.rms > 0.6);
    // Band 5 is 1000 Hz
    assert!(data.bands[5] > 0.5, "1000Hz band should have dominant energy, got {}", data.bands[5]);
}

#[test]
fn test_dsp_chain_integration() {
    let sample_rate = 44100;
    let mut chain = DspChain::new(2, sample_rate);
    chain.set_volume(0.8);
    chain.set_limiter_enabled(true);

    let mut sine = generate_sine(440.0, sample_rate, 0.1, 2);
    chain.process_frames(&mut sine);

    for &s in &sine {
        assert!(s.abs() <= 1.0);
    }
}
