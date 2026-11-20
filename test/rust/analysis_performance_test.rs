//! Performance & Stage-Breakdown Profiler for `analyze_audio_source`.
//!
//! Uses relative fixture paths via [`common::FixtureResolver`] across all 27 full-length
//! tracks in `example/assets/music/` and the 50 files in `example/assets/music/library/`
//! with ALL 4 analysis features enabled (`replay_gain`, `waveform`, `metadata`, `chromaprint`).

mod common;

use std::time::Instant;

use common::FixtureResolver;
use miniaudio_player::api::types::RustAnalysisConfig;
use miniaudio_player::buffer::FileByteSource;
use miniaudio_player::core::dual_source::AudioSourceCore;
use miniaudio_player::decoder::symphonia_engine::SymphoniaEngine;
use miniaudio_player::dsp::analysis::analyze_audio_source;

const ALL_27_TRACKS: &[(&str, bool)] = &[
    // (relative filename, in_standard_library_mix)
    ("01_Apex_Momentum.mp3", true),
    ("02_Bailando_con_tu_recuerdo.opus", true),
    ("03_Before_The_Dawn_cbr_noxing.mp3", true),
    ("04_Belaya_Tishina.flac", true),
    ("05_Burning_in_the_Electric_Light.ogg", true),
    ("06_Calculated_Motion_aac.m4a", true),
    ("07_Fevered_Strings_alac.m4a", true),
    ("08_Firelight_Promise_24bit_mono.wav", true),
    ("09_Flesh_and_Chrome.wv", false),
    ("10_La_cicatriz_del_andén.aac", true),
    ("11_Mar_de_cristal.mka", true),
    ("12_Mi_más_bonita_coincidencia_24bit_stereo.wav", true),
    ("13_Overture_for_the_Floor.webm", true),
    ("14_Painting_the_Sky.mkv", true),
    ("15_Resting_At_Your_Feet.mp2", false),
    ("16_Ribbons_on_Anchors.oga", true),
    ("17_Running_To_Meet_The_Sun.wav", true),
    ("18_Running_With_Daylight.aif", false),
    ("19_Spin_Me_In_The_Dark.rf64", false),
    ("20_Swallowing_This_Glitter_Pill.w64", false),
    ("21_The_Great_Equalizer.bwf", false),
    ("22_The_Midnight_Pursuit.rifx", false),
    ("23_Tracing_Lines.aifc", false),
    ("24_Tracks_Into_The_Dawn.aiff", false),
    ("25_Velocity_of_One.ape", false),
    ("27_\u{00a1}Yo_me_opongo_.caf", false),
    ("29_駆け抜けて、この空を.dsf", false),
];

const STAGE_PROFILE_TRACKS: &[&str] = &[
    "01_Apex_Momentum.mp3",
    "02_Bailando_con_tu_recuerdo.opus",
    "04_Belaya_Tishina.flac",
    "05_Burning_in_the_Electric_Light.ogg",
    "06_Calculated_Motion_aac.m4a",
    "07_Fevered_Strings_alac.m4a",
    "09_Flesh_and_Chrome.wv",
    "10_La_cicatriz_del_andén.aac",
    "12_Mi_más_bonita_coincidencia_24bit_stereo.wav",
    "18_Running_With_Daylight.aif",
    "19_Spin_Me_In_The_Dark.rf64",
    "25_Velocity_of_One.ape",
    "27_\u{00a1}Yo_me_opongo_.caf",
    "29_駆け抜けて、この空を.dsf",
];

fn make_source(id: i64, path: String) -> AudioSourceCore {
    AudioSourceCore {
        id,
        source: path,
        headers: None,
        data_bytes: None,
        replay_gain_db: None,
        replay_peak: None,
        resolve_in_dart: false,
    }
}

fn cfg(replay_gain: bool, waveform: bool, metadata: bool, chromaprint: bool) -> RustAnalysisConfig {
    RustAnalysisConfig {
        replay_gain,
        waveform,
        metadata,
        chromaprint,
        waveform_points: 100,
        target_lufs: -18.0,
        max_duration_ms: None,
    }
}

fn stats_summary(times_ms: &[f64]) -> (f64, f64, f64, f64, f64) {
    let mut sorted = times_ms.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let n = sorted.len().max(1);
    let total: f64 = sorted.iter().sum();
    let mean = total / (n as f64);
    let median = if n % 2 == 1 {
        sorted[n / 2]
    } else {
        0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    };
    let p95_idx = ((n as f64 * 0.95).ceil() as usize)
        .saturating_sub(1)
        .min(n - 1);
    let p95 = sorted[p95_idx];
    let max_v = sorted[n - 1];
    (mean, median, p95, max_v, total)
}

#[test]
fn test_analysis_performance_all_27_full_tracks() {
    println!("\n=== FULL-FEATURE ANALYZE PERFORMANCE: ALL 27 FULL TRACKS ===");
    println!(
        "{:<48} | {:>9} | {:>8} | {:>8} | {:>6}",
        "Track", "Time (ms)", "Dur (s)", "Speedup", "SR"
    );
    println!("{}", "-".repeat(90));

    let mut all_ms = Vec::with_capacity(ALL_27_TRACKS.len());
    let mut std_ms = Vec::new();

    for (idx, &(rel, in_std)) in ALL_27_TRACKS.iter().enumerate() {
        let path = FixtureResolver::resolve_str(rel);
        let t0 = Instant::now();
        let res = analyze_audio_source(
            make_source(idx as i64 + 1, path),
            cfg(true, true, true, true),
        )
        .unwrap_or_else(|e| panic!("analyze_audio_source failed for {}: {}", rel, e));
        let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;

        assert!(res.has_replay_gain, "{}: has_replay_gain", rel);
        assert!(res.has_waveform, "{}: has_waveform", rel);
        assert_eq!(res.waveform_peaks.len(), 100, "{}: waveform_peaks", rel);
        assert!(res.has_metadata, "{}: has_metadata", rel);
        assert!(res.has_chromaprint, "{}: has_chromaprint", rel);

        let dur_s = res.audio_info.duration_ms.unwrap_or(0) as f64 / 1000.0;
        let speedup = if elapsed_ms > 0.0 {
            (dur_s * 1000.0) / elapsed_ms
        } else {
            0.0
        };
        println!(
            "{:<48} | {:>9.2} | {:>8.1} | {:>7.1}x | {:>6}",
            rel, elapsed_ms, dur_s, speedup, res.audio_info.sample_rate
        );

        all_ms.push(elapsed_ms);
        if in_std {
            std_ms.push(elapsed_ms);
        }
    }

    let (mean, median, p95, max_v, total) = stats_summary(&all_ms);
    let proj_1500_all_s = (mean * 1500.0) / 1000.0;
    let (s_mean, s_median, s_p95, s_max, _) = stats_summary(&std_ms);
    let proj_1500_std_s = (s_mean * 1500.0) / 1000.0;

    println!("{}", "-".repeat(90));
    println!(
        "ALL-27 MIX     : total={:.2}ms | mean={:.2}ms | median={:.2}ms | p95={:.2}ms | max={:.2}ms | 1500-file proj={:.1}s ({:.2} min)",
        total,
        mean,
        median,
        p95,
        max_v,
        proj_1500_all_s,
        proj_1500_all_s / 60.0
    );
    println!(
        "STD LIBRARY MIX: n={} | mean={:.2}ms | median={:.2}ms | p95={:.2}ms | max={:.2}ms | 1500-file proj={:.1}s ({:.2} min)",
        std_ms.len(),
        s_mean,
        s_median,
        s_p95,
        s_max,
        proj_1500_std_s,
        proj_1500_std_s / 60.0
    );
}

#[test]
fn test_analysis_stage_breakdown_profiler() {
    println!("\n=== ISOLATED STAGE BREAKDOWN (ms) ===");
    println!(
        "{:<48} | {:>7} | {:>7} | {:>7} | {:>7} | {:>7} | {:>7} | {:>7}",
        "Track", "RawDec", "Open", "Meta", "Wf", "RG", "Chroma", "All4"
    );
    println!("{}", "-".repeat(118));

    let mut sum_raw = 0.0;
    let mut sum_open = 0.0;
    let mut sum_meta = 0.0;
    let mut sum_wf = 0.0;
    let mut sum_rg = 0.0;
    let mut sum_cp = 0.0;
    let mut sum_all = 0.0;

    for (idx, &rel) in STAGE_PROFILE_TRACKS.iter().enumerate() {
        let path_buf = FixtureResolver::resolve(rel);
        let path_str = path_buf.to_string_lossy().into_owned();
        let ext = path_buf.extension().and_then(|e| e.to_str());

        // Warm OS page cache first once so cold disk I/O doesn't skew individual stages
        let _ = analyze_audio_source(make_source(1, path_str.clone()), cfg(false, false, false, false));

        // 1. Raw decode only
        let t_raw = Instant::now();
        {
            let src = FileByteSource::open(&path_buf).unwrap();
            let mut eng = SymphoniaEngine::new(src, ext).unwrap();
            let mut buf = Vec::with_capacity(16384);
            while eng.decode_next_frame(&mut buf).unwrap_or(false) {}
        }
        let raw_ms = t_raw.elapsed().as_secs_f64() * 1000.0;

        // 2. Open + AudioInfo only
        let t_open = Instant::now();
        let _ = analyze_audio_source(make_source(idx as i64 + 10, path_str.clone()), cfg(false, false, false, false)).unwrap();
        let open_ms = t_open.elapsed().as_secs_f64() * 1000.0;

        // 3. Metadata only
        let t_meta = Instant::now();
        let _ = analyze_audio_source(make_source(idx as i64 + 30, path_str.clone()), cfg(false, false, true, false)).unwrap();
        let meta_ms = t_meta.elapsed().as_secs_f64() * 1000.0;

        // 4. Waveform only
        let t_wf = Instant::now();
        let _ = analyze_audio_source(make_source(idx as i64 + 50, path_str.clone()), cfg(false, true, false, false)).unwrap();
        let wf_ms = t_wf.elapsed().as_secs_f64() * 1000.0;

        // 5. ReplayGain only
        let t_rg = Instant::now();
        let _ = analyze_audio_source(make_source(idx as i64 + 70, path_str.clone()), cfg(true, false, false, false)).unwrap();
        let rg_ms = t_rg.elapsed().as_secs_f64() * 1000.0;

        // 6. Chromaprint only
        let t_cp = Instant::now();
        let _ = analyze_audio_source(make_source(idx as i64 + 90, path_str.clone()), cfg(false, false, false, true)).unwrap();
        let cp_ms = t_cp.elapsed().as_secs_f64() * 1000.0;

        // 7. All 4 enabled
        let t_all = Instant::now();
        let _ = analyze_audio_source(make_source(idx as i64 + 110, path_str), cfg(true, true, true, true)).unwrap();
        let all_ms = t_all.elapsed().as_secs_f64() * 1000.0;

        println!(
            "{:<48} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2}",
            rel, raw_ms, open_ms, meta_ms, wf_ms, rg_ms, cp_ms, all_ms
        );

        sum_raw += raw_ms;
        sum_open += open_ms;
        sum_meta += meta_ms;
        sum_wf += wf_ms;
        sum_rg += rg_ms;
        sum_cp += cp_ms;
        sum_all += all_ms;
    }

    let n = STAGE_PROFILE_TRACKS.len() as f64;
    println!("{}", "-".repeat(118));
    println!(
        "{:<48} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2} | {:>7.2}",
        "AVERAGE (14 REPRESENTATIVE TRACKS)",
        sum_raw / n,
        sum_open / n,
        sum_meta / n,
        sum_wf / n,
        sum_rg / n,
        sum_cp / n,
        sum_all / n,
    );
}

#[test]
fn test_analysis_sequential_library_50_files() {
    println!("\n=== SEQUENTIAL 50-FILE LIBRARY TEST (ALL 4 FEATURES) ===");
    let subdirs = ["mp3", "opus", "flac", "m4a", "wav"];
    let mut all_times = Vec::with_capacity(50);

    for ext in &subdirs {
        let subdir = format!("library/{}", ext);
        let files = FixtureResolver::collect_by_extension(&subdir, ext, 10);
        assert!(
            files.len() >= 10,
            "Expected 10 files in {}, found {}",
            subdir,
            files.len()
        );
        let mut fmt_times = Vec::with_capacity(files.len());
        for (i, path) in files.iter().enumerate() {
            let t0 = Instant::now();
            let res = analyze_audio_source(
                make_source(i as i64 + 1, path.to_string_lossy().into_owned()),
                cfg(true, true, true, true),
            )
            .unwrap_or_else(|e| panic!("Library file {:?} failed: {}", path, e));
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            assert!(res.has_replay_gain && res.has_waveform && res.has_chromaprint);
            fmt_times.push(ms);
            all_times.push(ms);
        }
        let (mean, _med, p95, max_v, total) = stats_summary(&fmt_times);
        println!(
            "library/{:<5}: n={} | total={:.2}ms | mean={:.2}ms | p95={:.2}ms | max={:.2}ms",
            ext,
            files.len(),
            total,
            mean,
            p95,
            max_v
        );
    }

    let (mean, median, p95, max_v, total) = stats_summary(&all_times);
    let proj_1500_s = (mean * 1500.0) / 1000.0;
    println!(
        "50-FILE TOTAL: total={:.2}ms | mean={:.2}ms | median={:.2}ms | p95={:.2}ms | max={:.2}ms | 1500-file proj={:.1}s ({:.2} min)",
        total,
        mean,
        median,
        p95,
        max_v,
        proj_1500_s,
        proj_1500_s / 60.0
    );
}
