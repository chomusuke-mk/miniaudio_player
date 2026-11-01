//! Complete DSP Chain, Channel Matrix, 3D Spatial Audio, Auto-Ducking, and Voice Pool Tests.

mod common;

use common::SignalGenerator;
use miniaudio_player::dsp::biquad::BiquadDf2t;
use miniaudio_player::dsp::chain::DspChain;
use miniaudio_player::dsp::channel_matrix::ChannelMatrix;
use miniaudio_player::dsp::crossfeed::{Bs2bCrossfeed, CrossfeedMode};
use miniaudio_player::dsp::ducking::AutoDucker;
use miniaudio_player::dsp::equalizer::Equalizer;
use miniaudio_player::dsp::limiter::SoftLimiter;
use miniaudio_player::dsp::resampler::{resample_slice, RubatoResampler};
use miniaudio_player::dsp::reverb::{Freeverb, ReverbConfig};
use miniaudio_player::dsp::silence::{SilenceConfig, SilenceDetector, SilenceMode, SilenceState};
use miniaudio_player::dsp::sonic::SonicStream;
use miniaudio_player::dsp::spatial::{
    DistanceModel, SpatialEmitter, SpatialEvaluation, SpatialListener, SpatialProcessor, Vector3,
};
use miniaudio_player::dsp::timestretch::{timestretch_audio, TimeStretchProcessor};
use miniaudio_player::dsp::visualizer::Visualizer;
use miniaudio_player::dsp::voice_pool::{SoundBuffer, VoicePool, VoiceStealingPolicy};

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
    let mut cf = Bs2bCrossfeed::new(44100, CrossfeedMode::MoffatBauer);
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
fn test_rubato_resampler_and_timestretch() {
    let sine = SignalGenerator::sine_wave_f32(4410, 44100, 2, 440.0);
    let mut resampler = RubatoResampler::new(44100, 48000, 2, 1024).unwrap();
    let mut out_stream = Vec::new();
    let written = resampler.process_interleaved(&sine, &mut out_stream).unwrap();
    let flushed = resampler.flush(&mut out_stream).unwrap();
    assert!(written + flushed > 0);

    let out_slice = resample_slice(&sine, 44100, 48000, 2).unwrap();
    assert!(!out_slice.is_empty());

    // 192 kHz -> 48 kHz downsampling
    let input_192k = SignalGenerator::sine_wave_f32(19200, 192000, 2, 1000.0);
    let out_48k = resample_slice(&input_192k, 192000, 48000, 2).unwrap();
    let frames_48k = out_48k.len() / 2;
    assert!((frames_48k as i32 - 4800).abs() < 50);

    // TimeStretchProcessor
    let mut proc = TimeStretchProcessor::new(44100, 2);
    proc.set_speed(1.25);
    proc.set_pitch(1.0);
    let rendered = proc.process_slice(&sine).unwrap();
    let ratio = rendered.len() as f32 / sine.len() as f32;
    assert!(ratio > 0.7 && ratio < 0.95);

    let slowed = timestretch_audio(&sine, 44100, 2, 0.8, 1.0).unwrap();
    assert!(slowed.len() > sine.len());
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

    let mut proc = SpatialProcessor::new(343.3);
    let target = SpatialEvaluation {
        doppler_ratio: 1.5,
        gain: 0.2,
        pan: 0.8,
        distance: 50.0,
    };
    for _ in 0..50 {
        proc.update_smoothed(&target, 0.010);
    }
    assert!((proc.current_doppler_ratio() - 1.5).abs() < 1e-2);
}

#[test]
fn test_auto_ducker_sidechain_envelope() {
    let mut ducker = AutoDucker::new(48000);
    assert!(!ducker.enabled);
    ducker.set_params(true, -14.0, -30.0, 5.0, 20.0, 30.0);

    let voice_speech = vec![0.5f32; 960];
    let mut music = vec![1.0f32; 960];

    for _ in 0..10 {
        ducker.process_sidechain(&voice_speech, &mut music, 2);
    }
    assert!(ducker.is_ducking());
    let expected_duck = 10.0f32.powf(-14.0 / 20.0);
    assert!((ducker.current_gain() - expected_duck).abs() < 0.05);

    let voice_silence = vec![0.0f32; 960];
    for _ in 0..30 {
        ducker.process_sidechain(&voice_silence, &mut music, 2);
    }
    assert!((ducker.current_gain() - 1.0).abs() < 0.05);
    assert!(!ducker.is_ducking());
}

#[test]
fn test_voice_pool_polyphony_and_listener_relative_farthest_stealing() {
    let mut pool = VoicePool::new(2, VoiceStealingPolicy::LowestPriority);
    let buf = SoundBuffer::new(vec![0.5; 100], 48000, 1);

    let id_low = pool.play_sound(buf.clone(), 1.0, 1.0, 10, false, None).unwrap();
    let id_high = pool.play_sound(buf.clone(), 1.0, 1.0, 200, false, None).unwrap();
    assert_eq!(pool.active_voice_count(), 2);

    // Steal lowest priority voice
    let id_new = pool.play_sound(buf.clone(), 1.0, 1.0, 150, false, None);
    assert!(id_new.is_some());
    assert!(!pool.is_voice_playing(id_low));
    assert!(pool.is_voice_playing(id_high));

    // Verify Farthest stealing measures distance from listener_position (NOT origin)
    let mut pool_far = VoicePool::new(2, VoiceStealingPolicy::Farthest);
    let mut listener = SpatialListener::default();
    listener.position = Vector3::new(100.0, 0.0, 0.0);
    let mut dummy_out = [0.0f32; 4];
    pool_far.render_pcm(&mut dummy_out, 2, 48000, &listener);

    let mut em_near_listener = SpatialEmitter::default();
    em_near_listener.position = Vector3::new(95.0, 0.0, 0.0); // distance 5 from listener, 95 from origin
    let mut em_far_listener = SpatialEmitter::default();
    em_far_listener.position = Vector3::new(10.0, 0.0, 0.0); // distance 90 from listener, 10 from origin

    let id_near = pool_far
        .play_sound(buf.clone(), 1.0, 1.0, 100, false, Some(em_near_listener))
        .unwrap();
    let id_far = pool_far
        .play_sound(buf.clone(), 1.0, 1.0, 100, false, Some(em_far_listener))
        .unwrap();

    // Allocating a 3rd voice must steal id_far (distance 90 from listener), keeping id_near!
    let id_third = pool_far
        .play_sound(buf.clone(), 1.0, 1.0, 100, false, None)
        .unwrap();
    assert!(pool_far.is_voice_playing(id_near));
    assert!(!pool_far.is_voice_playing(id_far));
    assert!(pool_far.is_voice_playing(id_third));

    // Runtime voice controls
    pool_far.set_voice_volume(id_near, 0.4);
    pool_far.set_voice_pitch(id_near, 1.8);
    let v = pool_far.get_voice(id_near).unwrap();
    assert!((v.volume - 0.4).abs() < 0.01);
    assert!((v.pitch - 1.8).abs() < 0.01);
}
