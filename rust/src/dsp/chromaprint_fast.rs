//! High-speed Chromaprint wrapper with cached polyphase sinc banks,
//! pooled `Fingerprinter` workspaces, SSE2 i16 dot products, and AcoustID 120 s capping.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use crate::api::types::RustChromaprintResult;

/// Internal target sample rate required by Chromaprint.
pub const TARGET_SAMPLE_RATE: u32 = 11025;
/// Standard AcoustID / `fpcalc` analysis window in seconds.
pub const CHROMAPRINT_MAX_DURATION_SECS: u64 = 120;

const MIN_SAMPLE_RATE: u32 = 1000;
const MAX_BUFFER_SIZE: usize = 32768;
const RESAMPLE_FILTER_LENGTH: i32 = 16;
const RESAMPLE_PHASE_SHIFT: i32 = 8;
const RESAMPLE_CUTOFF: f64 = 0.8;
const FILTER_SHIFT: i32 = 15;
const WINDOW_TYPE: i32 = 9;
const MAX_POOLED_FINGERPRINTERS: usize = 8;

/// Precomputed immutable polyphase FIR filter bank shared across tracks of matching `in_rate`.
struct PolyphaseBank {
    filter_bank: Vec<i16>,
    filter_length: usize,
    ideal_dst_incr: i32,
    src_incr: i32,
    initial_index: i32,
    phase_shift: i32,
    phase_mask: i32,
}

impl PolyphaseBank {
    fn build(in_rate: u32) -> Self {
        let out_rate = TARGET_SAMPLE_RATE as i32;
        let in_rate_i32 = in_rate as i32;
        let factor = (out_rate as f64 * RESAMPLE_CUTOFF / in_rate as f64).min(1.0);
        let phase_count = 1i32 << RESAMPLE_PHASE_SHIFT;
        let pc = phase_count as usize;

        let filter_length = ((RESAMPLE_FILTER_LENGTH as f64 / factor).ceil() as usize).max(1);
        let mut filter_bank = vec![0i16; filter_length * (pc + 1)];

        build_filter(
            &mut filter_bank,
            factor,
            filter_length,
            pc,
            1 << FILTER_SHIFT,
            WINDOW_TYPE,
        );

        // Wraparound phase row matching chromaprint-next `AvResampleContext::new`.
        filter_bank[filter_length * pc] = filter_bank[filter_length - 1];
        for i in 1..filter_length {
            filter_bank[filter_length * pc + i] = filter_bank[i - 1];
        }

        Self {
            filter_bank,
            filter_length,
            ideal_dst_incr: in_rate_i32 * phase_count,
            src_incr: out_rate,
            initial_index: -phase_count * ((filter_length as i32 - 1) / 2),
            phase_shift: RESAMPLE_PHASE_SHIFT,
            phase_mask: phase_count - 1,
        }
    }
}

fn bessel(x: f64) -> f64 {
    let mut v: f64 = 1.0;
    let mut last_v: f64 = 0.0;
    let mut t: f64 = 1.0;
    let x = x * x / 4.0;
    let mut i = 1;
    while v != last_v {
        last_v = v;
        t *= x / (i * i) as f64;
        v += t;
        i += 1;
    }
    v
}

fn build_filter(
    filter: &mut [i16],
    factor: f64,
    tap_count: usize,
    phase_count: usize,
    scale: i32,
    window_type: i32,
) {
    let center = (tap_count - 1) / 2;
    let mut tab = vec![0.0f64; tap_count];

    for ph in 0..phase_count {
        let mut norm: f64 = 0.0;
        for (i, slot) in tab.iter_mut().enumerate() {
            let x = std::f64::consts::PI
                * ((i as f64 - center as f64) - ph as f64 / phase_count as f64)
                * factor;
            let mut y = if x == 0.0 { 1.0 } else { x.sin() / x };
            let w = 2.0 * x / (factor * tap_count as f64 * std::f64::consts::PI);
            y *= bessel(window_type as f64 * (1.0 - w * w).max(0.0).sqrt());
            *slot = y;
            norm += y;
        }

        for (i, &t) in tab.iter().enumerate() {
            let val = (t * scale as f64 / norm).round() as i32;
            filter[ph * tap_count + i] = val.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
        }
    }
}

fn shared_polyphase_bank(in_rate: u32) -> Arc<PolyphaseBank> {
    static CACHE: OnceLock<Mutex<HashMap<u32, Arc<PolyphaseBank>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some(found) = guard.get(&in_rate) {
            return Arc::clone(found);
        }
    }
    let bank = Arc::new(PolyphaseBank::build(in_rate));
    if let Ok(mut guard) = cache.lock() {
        let entry = guard.entry(in_rate).or_insert_with(|| Arc::clone(&bank));
        Arc::clone(entry)
    } else {
        bank
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse2")]
#[inline]
unsafe fn dot_product_i16_sse2(a: &[i16], b: &[i16]) -> i32 {
    use std::arch::x86_64::*;

    let len = a.len().min(b.len());
    let a_ptr = a.as_ptr();
    let b_ptr = b.as_ptr();
    let mut acc0 = _mm_setzero_si128();
    let mut acc1 = _mm_setzero_si128();

    let chunks16 = len / 16;
    for i in 0..chunks16 {
        let off = i * 16;
        let a0 = _mm_loadu_si128(a_ptr.add(off) as *const __m128i);
        let b0 = _mm_loadu_si128(b_ptr.add(off) as *const __m128i);
        let a1 = _mm_loadu_si128(a_ptr.add(off + 8) as *const __m128i);
        let b1 = _mm_loadu_si128(b_ptr.add(off + 8) as *const __m128i);
        acc0 = _mm_add_epi32(acc0, _mm_madd_epi16(a0, b0));
        acc1 = _mm_add_epi32(acc1, _mm_madd_epi16(a1, b1));
    }

    acc0 = _mm_add_epi32(acc0, acc1);
    let mut off = chunks16 * 16;
    if len - off >= 8 {
        let av = _mm_loadu_si128(a_ptr.add(off) as *const __m128i);
        let bv = _mm_loadu_si128(b_ptr.add(off) as *const __m128i);
        acc0 = _mm_add_epi32(acc0, _mm_madd_epi16(av, bv));
        off += 8;
    }

    let hi64 = _mm_unpackhi_epi64(acc0, acc0);
    acc0 = _mm_add_epi32(acc0, hi64);
    let hi32 = _mm_shuffle_epi32(acc0, 1);
    let mut result = _mm_cvtsi128_si32(_mm_add_epi32(acc0, hi32));

    while off < len {
        result += *a_ptr.add(off) as i32 * *b_ptr.add(off) as i32;
        off += 1;
    }
    result
}

#[inline]
fn dot_product_i16(a: &[i16], b: &[i16]) -> i32 {
    #[cfg(target_arch = "x86_64")]
    {
        // SAFETY: x86_64 guarantees SSE2.
        unsafe { dot_product_i16_sse2(a, b) }
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        chromaprint::simd::dot_product_i16(a, b)
    }
}

struct CachedResampler {
    bank: Arc<PolyphaseBank>,
    dst_incr: i32,
    index: i32,
    frac: i32,
}

impl CachedResampler {
    fn new(in_rate: u32) -> Self {
        let bank = shared_polyphase_bank(in_rate);
        Self {
            dst_incr: bank.ideal_dst_incr,
            index: bank.initial_index,
            frac: 0,
            bank,
        }
    }

    fn resample(
        &mut self,
        dst: &mut [i16],
        src: &[i16],
        consumed: &mut usize,
        dst_size: usize,
    ) -> usize {
        if src.is_empty() {
            *consumed = 0;
            return 0;
        }
        let src_size = src.len() as i32;
        let filter_length = self.bank.filter_length;
        let filter_bank = &self.bank.filter_bank;
        let phase_mask = self.bank.phase_mask;
        let phase_shift = self.bank.phase_shift;
        let src_incr = self.bank.src_incr;
        let mut index = self.index;
        let mut frac = self.frac;
        let dst_incr_frac = self.dst_incr % src_incr;
        let dst_incr = self.dst_incr / src_incr;
        let mut dst_index = 0usize;
        let limit = dst_size.min(dst.len());

        while dst_index < limit {
            let filter_offset = filter_length * ((index & phase_mask) as usize);
            let sample_index = index >> phase_shift;

            if sample_index < 0 {
                let mut val: i32 = 0;
                for i in 0..filter_length as i32 {
                    let si = ((sample_index + i).abs() % src_size) as usize;
                    val += src[si] as i32 * filter_bank[filter_offset + i as usize] as i32;
                }
                val = (val + (1 << (FILTER_SHIFT - 1))) >> FILTER_SHIFT;
                dst[dst_index] = if (val as u32).wrapping_add(32768) > 65535 {
                    ((val >> 31) ^ 32767) as i16
                } else {
                    val as i16
                };
            } else if sample_index + filter_length as i32 > src_size {
                break;
            } else {
                let si = sample_index as usize;
                let mut val = dot_product_i16(
                    &src[si..si + filter_length],
                    &filter_bank[filter_offset..filter_offset + filter_length],
                );
                val = (val + (1 << (FILTER_SHIFT - 1))) >> FILTER_SHIFT;
                dst[dst_index] = if (val as u32).wrapping_add(32768) > 65535 {
                    ((val >> 31) ^ 32767) as i16
                } else {
                    val as i16
                };
            }

            frac += dst_incr_frac;
            index += dst_incr;
            if frac >= src_incr {
                frac -= src_incr;
                index += 1;
            }
            dst_index += 1;
        }

        *consumed = (index.max(0) >> phase_shift) as usize;
        if index >= 0 {
            index &= phase_mask;
        }

        self.frac = frac;
        self.index = index;
        self.dst_incr = dst_incr_frac + src_incr * dst_incr;
        dst_index
    }
}

struct PooledFpWorkspace {
    fp: chromaprint::Fingerprinter,
    mono_buf: Vec<i16>,
    resample_buf: Vec<i16>,
}

impl PooledFpWorkspace {
    fn new() -> Self {
        Self {
            fp: chromaprint::Fingerprinter::new(chromaprint::types::Algorithm::default()),
            mono_buf: vec![0i16; MAX_BUFFER_SIZE],
            resample_buf: vec![0i16; MAX_BUFFER_SIZE],
        }
    }
}

fn fp_workspace_pool() -> &'static Mutex<Vec<PooledFpWorkspace>> {
    static POOL: OnceLock<Mutex<Vec<PooledFpWorkspace>>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(Vec::with_capacity(MAX_POOLED_FINGERPRINTERS)))
}

fn acquire_fp_workspace() -> PooledFpWorkspace {
    if let Ok(mut guard) = fp_workspace_pool().lock() {
        if let Some(ws) = guard.pop() {
            return ws;
        }
    }
    PooledFpWorkspace::new()
}

fn release_fp_workspace(ws: PooledFpWorkspace) {
    if let Ok(mut guard) = fp_workspace_pool().lock() {
        if guard.len() < MAX_POOLED_FINGERPRINTERS {
            guard.push(ws);
        }
    }
}

/// High-speed Chromaprint session reusing cached `11025 Hz` polyphase filter banks
/// and pooled `Fingerprinter` instances with optional duration capping (default 120 s).
pub struct CachedChromaprintSession {
    workspace: Option<PooledFpWorkspace>,
    resampler: Option<CachedResampler>,
    mono_offset: usize,
    frames_fed: u64,
    max_frames: Option<u64>,
}

impl CachedChromaprintSession {
    /// Starts a new Chromaprint session with the AcoustID standard 120 s duration cap.
    pub fn new(sample_rate: u32, channels: usize) -> Option<Self> {
        Self::new_with_max_secs(sample_rate, channels, Some(CHROMAPRINT_MAX_DURATION_SECS))
    }

    /// Starts a new Chromaprint session with an optional duration cap in seconds (`None` = full track).
    pub fn new_with_max_secs(
        sample_rate: u32,
        channels: usize,
        max_secs: Option<u64>,
    ) -> Option<Self> {
        if sample_rate <= MIN_SAMPLE_RATE || channels == 0 {
            return None;
        }
        let mut ws = acquire_fp_workspace();
        if ws.fp.start(TARGET_SAMPLE_RATE, 1).is_err() {
            release_fp_workspace(ws);
            return None;
        }
        let resampler = if sample_rate != TARGET_SAMPLE_RATE {
            Some(CachedResampler::new(sample_rate))
        } else {
            None
        };
        let max_frames = max_secs.map(|s| (sample_rate as u64).saturating_mul(s));
        Some(Self {
            workspace: Some(ws),
            resampler,
            mono_offset: 0,
            frames_fed: 0,
            max_frames,
        })
    }

    /// Returns `true` once the configured duration cap (`120 s`) has been ingested.
    #[inline]
    pub fn is_capped(&self) -> bool {
        self.max_frames
            .is_some_and(|limit| self.frames_fed >= limit)
    }

    #[inline]
    fn f32_to_i16(sample: f32) -> i16 {
        (sample.clamp(-1.0, 1.0) * 32767.0) as i16
    }

    #[inline]
    fn resample_and_feed_block(&mut self) {
        let Some(ref mut ws) = self.workspace else {
            return;
        };
        if let Some(ref mut resampler) = self.resampler {
            let mut consumed = 0usize;
            let len = resampler.resample(
                &mut ws.resample_buf,
                &ws.mono_buf[..self.mono_offset],
                &mut consumed,
                MAX_BUFFER_SIZE,
            );
            if len > 0 {
                let emit = len.min(MAX_BUFFER_SIZE);
                let _ = ws.fp.feed(&ws.resample_buf[..emit]);
            }
            let remaining = self.mono_offset.saturating_sub(consumed);
            if remaining > 0 {
                ws.mono_buf.copy_within(consumed..self.mono_offset, 0);
            }
            self.mono_offset = remaining;
        } else {
            let _ = ws.fp.feed(&ws.mono_buf[..self.mono_offset]);
            self.mono_offset = 0;
        }
    }

    /// Feeds interleaved float PCM frames (`channels` per frame) until capped.
    pub fn push_slice(&mut self, pcm: &[f32], channels: usize) {
        if channels == 0 || pcm.is_empty() || self.is_capped() {
            return;
        }
        let chunk_frames = pcm.len() / channels;
        let allowed_frames = match self.max_frames {
            Some(limit) => chunk_frames.min((limit - self.frames_fed) as usize),
            None => chunk_frames,
        };
        if allowed_frames == 0 {
            return;
        }
        self.frames_fed += allowed_frames as u64;

        let mut frame_pos = 0usize;
        let mut remaining = allowed_frames;

        while remaining > 0 {
            let space = MAX_BUFFER_SIZE - self.mono_offset;
            let to_load = remaining.min(space);
            let Some(ref mut ws) = self.workspace else {
                return;
            };
            let dst = &mut ws.mono_buf[self.mono_offset..self.mono_offset + to_load];

            if channels == 1 {
                let src = &pcm[frame_pos..frame_pos + to_load];
                for (out, &s) in dst.iter_mut().zip(src.iter()) {
                    *out = Self::f32_to_i16(s);
                }
            } else if channels == 2 {
                let src = &pcm[frame_pos * 2..(frame_pos + to_load) * 2];
                for (out, pair) in dst.iter_mut().zip(src.chunks_exact(2)) {
                    let l = Self::f32_to_i16(pair[0]) as i32;
                    let r = Self::f32_to_i16(pair[1]) as i32;
                    *out = ((l + r) / 2) as i16;
                }
            } else {
                let src = &pcm[frame_pos * channels..(frame_pos + to_load) * channels];
                for (out, frame) in dst.iter_mut().zip(src.chunks_exact(channels)) {
                    let mut sum = 0i32;
                    for &s in frame {
                        sum += Self::f32_to_i16(s) as i32;
                    }
                    *out = (sum / channels as i32) as i16;
                }
            }

            self.mono_offset += to_load;
            frame_pos += to_load;
            remaining -= to_load;

            if self.mono_offset == MAX_BUFFER_SIZE {
                self.resample_and_feed_block();
                if self.mono_offset == MAX_BUFFER_SIZE {
                    return;
                }
            }
        }
    }

    /// Flushes remaining buffered audio, finalizes Chromaprint, and returns the fingerprint result.
    pub fn finish(mut self) -> Option<RustChromaprintResult> {
        if self.mono_offset > 0 {
            self.resample_and_feed_block();
        }
        let ws = self.workspace.take()?;
        let mut ws = ws;
        let result = if ws.fp.finish().is_ok() {
            let fingerprint = ws.fp.encode();
            let raw = ws.fp.fingerprint().to_vec();
            let algorithm = match ws.fp.algorithm() {
                chromaprint::types::Algorithm::Test1 => 0,
                chromaprint::types::Algorithm::Test2 => 1,
                chromaprint::types::Algorithm::Test3 => 2,
                chromaprint::types::Algorithm::Test4 => 3,
                chromaprint::types::Algorithm::Test5 => 4,
            };
            Some(RustChromaprintResult {
                fingerprint,
                raw,
                algorithm,
            })
        } else {
            None
        };
        release_fp_workspace(ws);
        result
    }
}

impl Drop for CachedChromaprintSession {
    fn drop(&mut self) {
        if let Some(ws) = self.workspace.take() {
            release_fp_workspace(ws);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    fn generate_multitone_pcm(sample_rate: u32, channels: usize, secs: f32) -> Vec<f32> {
        let frames = (sample_rate as f32 * secs) as usize;
        let mut pcm = Vec::with_capacity(frames * channels);
        for i in 0..frames {
            let t = i as f32 / sample_rate as f32;
            let chord = 0.25 * (TAU * 220.0 * t).sin()
                + 0.20 * (TAU * 329.63 * t).sin()
                + 0.18 * (TAU * 440.0 * t).sin()
                + 0.15 * (TAU * (554.37 + 30.0 * (TAU * 0.5 * t).sin()) * t).sin();
            for ch in 0..channels {
                let phase_mod = if ch % 2 == 0 { 1.0 } else { 0.85 };
                pcm.push((chord * phase_mod).clamp(-0.98, 0.98));
            }
        }
        pcm
    }

    fn run_vanilla_chromaprint(pcm: &[f32], sample_rate: u32, channels: u16) -> (Vec<u32>, String) {
        let mut fp = chromaprint::Fingerprinter::new(chromaprint::types::Algorithm::default());
        fp.start(sample_rate, channels).unwrap();
        let i16_pcm: Vec<i16> = pcm
            .iter()
            .map(|&s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
            .collect();
        for chunk in i16_pcm.chunks(4096 * channels as usize) {
            fp.feed(chunk).unwrap();
        }
        fp.finish().unwrap();
        (fp.fingerprint().to_vec(), fp.encode())
    }

    #[test]
    fn matches_vanilla_chromaprint_exact_across_rates_and_channels() {
        for &(sr, ch) in &[(44100u32, 2usize), (48000, 2), (48000, 1), (88200, 2)] {
            let pcm = generate_multitone_pcm(sr, ch, 10.0);
            let (expected_raw, expected_enc) = run_vanilla_chromaprint(&pcm, sr, ch as u16);

            let mut fast = CachedChromaprintSession::new_with_max_secs(sr, ch, None).unwrap();
            for chunk in pcm.chunks(2047 * ch) {
                fast.push_slice(chunk, ch);
            }
            let got = fast.finish().expect("fast chromaprint must produce result");

            assert!(!got.raw.is_empty(), "raw fingerprint empty at {}Hz ch={}", sr, ch);
            assert_eq!(
                got.raw, expected_raw,
                "raw fingerprint mismatch at {}Hz ch={}",
                sr, ch
            );
            assert_eq!(
                got.fingerprint, expected_enc,
                "encoded fingerprint mismatch at {}Hz ch={}",
                sr, ch
            );
        }
    }

    #[test]
    fn respects_120s_acoustid_cap_and_reuses_pooled_fingerprinters() {
        let sr = 44100u32;
        let ch = 2usize;
        let pcm_135s = generate_multitone_pcm(sr, ch, 135.0);
        let pcm_120s = &pcm_135s[..(sr as usize * 120 * ch)];

        let mut capped = CachedChromaprintSession::new(sr, ch).unwrap();
        for chunk in pcm_135s.chunks(16384 * ch) {
            capped.push_slice(chunk, ch);
        }
        assert!(capped.is_capped());
        let capped_res = capped.finish().unwrap();

        let (expected_raw, expected_enc) = run_vanilla_chromaprint(pcm_120s, sr, ch as u16);
        assert_eq!(capped_res.raw, expected_raw);
        assert_eq!(capped_res.fingerprint, expected_enc);
    }
}
