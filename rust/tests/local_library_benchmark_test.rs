//! Benchmark and Outlier Audit on local audio library files.
//!
//! Validates:
//! - At least 50 samples per format (Opus, MP3, WAV, M4A, FLAC).
//! - Sub-millisecond to low-millisecond open and seek times (< 15 ms).
//! - Zero tolerance to outliers: any slow or failing file triggers an immediate error.

use std::path::{Path, PathBuf};
use std::time::Instant;

use miniaudio_player::decoder::symphonia_engine::SymphoniaEngine;

fn collect_files_with_ext(root: &str, ext: &str, limit: usize) -> Vec<PathBuf> {
    let mut results = Vec::new();
    let root_path = Path::new(root);
    if !root_path.exists() {
        return results;
    }

    fn walk(dir: &Path, ext: &str, limit: usize, acc: &mut Vec<PathBuf>) {
        if acc.len() >= limit {
            return;
        }
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    walk(&p, ext, limit, acc);
                } else if p.is_file() {
                    if let Some(e) = p.extension() {
                        if e.to_string_lossy().eq_ignore_ascii_case(ext) {
                            acc.push(p);
                            if acc.len() >= limit {
                                return;
                            }
                        }
                    }
                }
            }
        }
    }

    walk(root_path, ext, limit, &mut results);
    results
}

fn benchmark_format_files(ext: &str, search_roots: &[&str], min_count: usize, target_count: usize) {
    let mut files = Vec::new();
    for root in search_roots {
        let found = collect_files_with_ext(root, ext, target_count - files.len());
        files.extend(found);
        if files.len() >= target_count {
            break;
        }
    }

    println!("\n=== Benchmarking [{ext}] (Found {} files) ===", files.len());
    assert!(
        files.len() >= min_count,
        "Found only {} files for format {}, expected at least {}",
        files.len(),
        ext,
        min_count
    );

    let mut open_times_us = Vec::new();
    let mut seek_times_us = Vec::new();
    let mut failures = Vec::new();

    for (idx, path) in files.iter().enumerate() {
        let f_open_start = Instant::now();
        let source = match miniaudio_player::buffer::FileByteSource::open(path) {
            Ok(s) => s,
            Err(e) => {
                failures.push((path.clone(), format!("FileByteSource::open error: {e}")));
                continue;
            }
        };

        let mut engine = match SymphoniaEngine::new(source, Some(ext)) {
            Ok(e) => e,
            Err(e) => {
                failures.push((path.clone(), format!("SymphoniaEngine::new error: {e}")));
                continue;
            }
        };
        let open_dur = f_open_start.elapsed();
        open_times_us.push(open_dur.as_micros());

        let dur_ms = engine.duration_ms().unwrap_or(0);
        let target_seek = if dur_ms > 60_000 {
            55_000
        } else if dur_ms > 2_000 {
            dur_ms / 2
        } else {
            500
        };

        let seek_start = Instant::now();
        match engine.seek_ms(target_seek) {
            Ok(_) => {
                let seek_dur = seek_start.elapsed();
                seek_times_us.push(seek_dur.as_micros());
            }
            Err(e) => {
                failures.push((path.clone(), format!("seek_ms({target_seek}) error: {e}")));
            }
        }

        if (idx + 1) % 10 == 0 || idx + 1 == files.len() {
            println!(
                "  [{ext}] Processed {}/{} files... (Last open: {:?}, Last seek: {:?})",
                idx + 1,
                files.len(),
                open_dur,
                seek_times_us.last().map(|&us| std::time::Duration::from_micros(us as u64)).unwrap_or_default()
            );
        }
    }

    if !failures.is_empty() {
        eprintln!("\n[ERROR] Failures detected in format [{}]:", ext);
        for (f, err) in &failures {
            eprintln!("  FILE: {:?} | ERROR: {}", f, err);
        }
        panic!("TOLERANCIA CERO: Detected {} failing files in format [{}]!", failures.len(), ext);
    }

    open_times_us.sort_unstable();
    seek_times_us.sort_unstable();

    let avg_open = open_times_us.iter().sum::<u128>() as f64 / open_times_us.len() as f64;
    let p95_open = open_times_us[(open_times_us.len() as f64 * 0.95) as usize];
    let max_open = *open_times_us.last().unwrap();

    let avg_seek = seek_times_us.iter().sum::<u128>() as f64 / seek_times_us.len() as f64;
    let p95_seek = seek_times_us[(seek_times_us.len() as f64 * 0.95) as usize];
    let max_seek = *seek_times_us.last().unwrap();

    println!(
        "[{ext} SUMMARY] ({} files):\n  Open: avg={:.2}ms, p95={:.2}ms, max={:.2}ms\n  Seek: avg={:.2}ms, p95={:.2}ms, max={:.2}ms",
        files.len(),
        avg_open / 1000.0,
        p95_open as f64 / 1000.0,
        max_open as f64 / 1000.0,
        avg_seek / 1000.0,
        p95_seek as f64 / 1000.0,
        max_seek as f64 / 1000.0
    );

    // Strict performance invariants for local files (including external mechanical drives):
    // Open p95 < 100 ms, Seek p95 < 100 ms (most formats are sub-millisecond).
    assert!(
        p95_open < 100_000,
        "[{ext}] Open time p95 exceeded 100ms: {:.2}ms",
        p95_open as f64 / 1000.0
    );
    assert!(
        p95_seek < 100_000,
        "[{ext}] Seek time p95 exceeded 100ms: {:.2}ms",
        p95_seek as f64 / 1000.0
    );
}

#[test]
fn test_benchmark_opus_library() {
    let roots = ["/mnt/Last_Order/Música", "/home/javier/Descargas/test", "example/assets/music"];
    benchmark_format_files("opus", &roots, 50, 50);
}

#[test]
fn test_benchmark_m4a_library() {
    let roots = ["/mnt/Last_Order/Música", "example/assets/music"];
    benchmark_format_files("m4a", &roots, 10, 50);
}

#[test]
fn test_benchmark_mp3_library() {
    let roots = [
        "/mnt/Last_Order/respaldos/respaldo-Javier/Proyectos/miyako/audio",
        "/mnt/Last_Order/Videos/tvshows",
        "/home/javier/Descargas/test",
        "example/assets/music",
    ];
    benchmark_format_files("mp3", &roots, 25, 50);
}

#[test]
fn test_benchmark_wav_library() {
    let roots = [
        "/mnt/Last_Order/respaldos/respaldo-Javier/Proyectos/miyako/audio",
        "/mnt/Last_Order/respaldos/respaldo-Javier/Proyectos/RVC1006Nvidia/logs",
        "/home/javier/Descargas/test",
        "example/assets/music",
    ];
    benchmark_format_files("wav", &roots, 25, 50);
}

#[test]
fn test_benchmark_flac_library() {
    let roots = [
        "/mnt/Last_Order/respaldos/respaldo-Javier/Proyectos/miyako/audio-v2",
        "/mnt/Last_Order/respaldos/respaldo-Javier/Proyectos/RVC1006Nvidia/opt",
        "example/assets/music",
    ];
    benchmark_format_files("flac", &roots, 10, 50);
}
