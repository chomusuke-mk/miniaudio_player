//! Deterministic Open & Seek Latency Benchmark Suite on `test/fixtures/library/`.
//!
//! Strictly resolves all benchmark files relative to `test/fixtures/` via `FixtureResolver`.
//! Zero host-specific absolute paths are permitted.

mod common;

use std::time::Instant;

use common::FixtureResolver;
use miniaudio_player::buffer::FileByteSource;
use miniaudio_player::decoder::symphonia_engine::SymphoniaEngine;

fn run_format_benchmark(subdir: &str, ext: &str, min_expected_files: usize) {
    let files = FixtureResolver::collect_by_extension(subdir, ext, 50);
    assert!(
        files.len() >= min_expected_files,
        "Expected at least {} '{}' fixture files in test/fixtures/{}, found {}. \
         See test/fixtures/MANIFEST.md.",
        min_expected_files,
        ext,
        subdir,
        files.len()
    );

    let mut open_times_us = Vec::with_capacity(files.len());
    let mut seek_times_us = Vec::with_capacity(files.len());

    for path in &files {
        let open_start = Instant::now();
        let source = FileByteSource::open(path)
            .unwrap_or_else(|e| panic!("FileByteSource::open failed for {:?}: {}", path, e));
        let mut engine = SymphoniaEngine::new(source, Some(ext))
            .unwrap_or_else(|e| panic!("SymphoniaEngine::new failed for {:?}: {}", path, e));
        open_times_us.push(open_start.elapsed().as_micros());

        let dur_ms = engine.duration_ms().unwrap_or(0);
        let target_seek = if dur_ms > 60_000 {
            30_000
        } else if dur_ms > 2_000 {
            dur_ms / 2
        } else {
            500
        };

        let seek_start = Instant::now();
        engine
            .seek_ms(target_seek)
            .unwrap_or_else(|e| panic!("seek_ms({}) failed for {:?}: {}", target_seek, path, e));
        seek_times_us.push(seek_start.elapsed().as_micros());
    }

    open_times_us.sort_unstable();
    seek_times_us.sort_unstable();

    let p95_idx = ((files.len() as f64 * 0.95) as usize).min(files.len() - 1);
    let p95_open_us = open_times_us[p95_idx];
    let p95_seek_us = seek_times_us[p95_idx];

    let max_allowed_us = if cfg!(debug_assertions) { 250_000 } else { 100_000 };
    assert!(
        p95_open_us < max_allowed_us,
        "[{}] Open p95 latency exceeded limit: {:.2} ms",
        ext,
        p95_open_us as f64 / 1000.0
    );
    assert!(
        p95_seek_us < max_allowed_us,
        "[{}] Seek p95 latency exceeded limit: {:.2} ms",
        ext,
        p95_seek_us as f64 / 1000.0
    );
}

#[test]
fn test_benchmark_opus_fixtures() {
    run_format_benchmark("library/opus", "opus", 10);
}

#[test]
fn test_benchmark_m4a_fixtures() {
    run_format_benchmark("library/m4a", "m4a", 10);
}

#[test]
fn test_benchmark_mp3_fixtures() {
    run_format_benchmark("library/mp3", "mp3", 10);
}

#[test]
fn test_benchmark_wav_fixtures() {
    run_format_benchmark("library/wav", "wav", 10);
}

#[test]
fn test_benchmark_flac_fixtures() {
    run_format_benchmark("library/flac", "flac", 10);
}

#[test]
fn test_benchmark_extended_pcm_rf64_rifx_w64() {
    for ext in &["rf64", "rifx", "w64"] {
        let path = FixtureResolver::resolve(&format!("salida.{}", ext));

        let core_src = miniaudio_player::core::dual_source::AudioSourceCore {
            id: 1,
            source: path.to_str().unwrap().to_string(),
            headers: None,
            data_bytes: None,
            replay_gain_db: None,
            replay_peak: None,
        };
        let cfg = miniaudio_player::api::types::RustAnalysisConfig {
            waveform: true,
            waveform_points: 72,
            replay_gain: true,
            metadata: true,
            chromaprint: true,
            max_duration_ms: None,
            target_lufs: -14.0,
        };
        let t = Instant::now();
        let an_res = miniaudio_player::dsp::analysis::analyze_audio_source(core_src, cfg);
        let elapsed = t.elapsed();
        assert!(an_res.is_ok(), "[{}] analyze_audio_source failed", ext);
        assert!(
            elapsed < std::time::Duration::from_millis(800),
            "[{}] analyze_audio_source took too long: {:?}",
            ext,
            elapsed
        );
    }
}

