//! Shared deterministic test utilities for Rust integration tests (`test/rust/`).
//!
//! Provides:
//! - [`FixtureResolver`]: Relative path resolver anchored at `CARGO_MANIFEST_DIR/../test/fixtures`
//!   (strictly zero host-specific absolute paths).
//! - [`SignalGenerator`]: Deterministic PCM, RIFF WAVE, and DSF binary generators.

#![allow(dead_code)]

use std::f32::consts::PI;
use std::path::{Path, PathBuf};

/// Black-box path resolver for test fixtures located in `test/fixtures/`.
pub struct FixtureResolver;

impl FixtureResolver {
    /// Returns the resolved path to the `test/fixtures` directory relative to `rust/Cargo.toml`.
    pub fn fixtures_dir() -> PathBuf {
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        manifest_dir
            .join("..")
            .join("test")
            .join("fixtures")
            .canonicalize()
            .unwrap_or_else(|_| manifest_dir.join("..").join("test").join("fixtures"))
    }

    /// Resolves a fixture file inside `test/fixtures/` and verifies its existence.
    pub fn resolve(relative_path: &str) -> PathBuf {
        let path = Self::fixtures_dir().join(relative_path);
        assert!(
            path.exists(),
            "Required test fixture '{}' was not found at {:?}. \
             Generate test fixtures locally following 'test/fixtures/MANIFEST.md'.",
            relative_path,
            path
        );
        path
    }

    /// Resolves a fixture file inside `test/fixtures/` as a UTF-8 string path.
    pub fn resolve_str(relative_path: &str) -> String {
        Self::resolve(relative_path).to_string_lossy().into_owned()
    }

    /// Collects up to `limit` files matching extension `ext` inside `test/fixtures/<subdir>`.
    pub fn collect_by_extension(subdir: &str, ext: &str, limit: usize) -> Vec<PathBuf> {
        let root = if subdir.is_empty() {
            Self::fixtures_dir()
        } else {
            Self::fixtures_dir().join(subdir)
        };
        let mut results = Vec::new();
        Self::walk_dir(&root, ext, limit, &mut results);
        results.sort();
        results
    }

    /// Returns a deterministic scratch file path inside Cargo's target directory.
    pub fn scratch_file_path(filename: &str) -> PathBuf {
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let scratch_dir = manifest_dir.join("target").join("test_scratch");
        let _ = std::fs::create_dir_all(&scratch_dir);
        scratch_dir.join(format!("{}_{}", std::process::id(), filename))
    }

    fn walk_dir(dir: &Path, ext: &str, limit: usize, acc: &mut Vec<PathBuf>) {
        if acc.len() >= limit || !dir.exists() {
            return;
        }
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    Self::walk_dir(&p, ext, limit, acc);
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
}

/// Deterministic black-box generator for synthetic audio signals and containers.
pub struct SignalGenerator;

impl SignalGenerator {
    /// Generates interleaved `f32` sine wave samples.
    pub fn sine_wave_f32(
        num_frames: usize,
        sample_rate: u32,
        channels: usize,
        freq_hz: f32,
    ) -> Vec<f32> {
        let mut out = Vec::with_capacity(num_frames * channels);
        for i in 0..num_frames {
            let t = i as f32 / sample_rate as f32;
            let s = (t * freq_hz * 2.0 * PI).sin();
            for _ in 0..channels {
                out.push(s);
            }
        }
        out
    }

    /// Generates a complete valid 16-bit Little-Endian RIFF WAVE byte vector.
    pub fn pcm16_wav_bytes(num_frames: usize, sample_rate: u32, channels: u16) -> Vec<u8> {
        let bits_per_sample: u16 = 16;
        let bytes_per_sample = (bits_per_sample / 8) as usize;
        let block_align = channels as usize * bytes_per_sample;
        let byte_rate = sample_rate as usize * block_align;
        let data_size = num_frames * block_align;
        let file_size = 36 + data_size;

        let mut wav = Vec::with_capacity(44 + data_size);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(file_size as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVE");

        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&channels.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&(byte_rate as u32).to_le_bytes());
        wav.extend_from_slice(&(block_align as u16).to_le_bytes());
        wav.extend_from_slice(&bits_per_sample.to_le_bytes());

        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data_size as u32).to_le_bytes());

        for i in 0..num_frames {
            let t = i as f32 / sample_rate as f32;
            let sample = (t * 440.0 * 2.0 * PI).sin();
            let val = (sample * 30000.0) as i16;
            for _ in 0..channels {
                wav.extend_from_slice(&val.to_le_bytes());
            }
        }
        wav
    }
}
