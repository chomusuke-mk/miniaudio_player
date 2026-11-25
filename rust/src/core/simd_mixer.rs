//! Vectorized SIMD audio mixer with AVX2/FMA and ARM NEON support.
//!
//! Provides lock-free, zero-allocation slice accumulation and gain-scaled mixing
//! with scalar fallbacks for targets without SIMD intrinsics.

/// SIMD-accelerated audio sample mixer with AVX2/FMA, ARM NEON, and scalar fallback routines.
#[derive(Debug, Clone, Copy, Default)]
pub struct SimdMixer {}

impl SimdMixer {
    /// Creates a new [`SimdMixer`] instance.
    #[inline]
    pub fn new() -> Self {
        Self {}
    }

    /// Accumulates `src` samples into `dst` with unity gain (`dst[i] += src[i]`).
    #[inline]
    pub fn accumulate(&self, dst: &mut [f32], src: &[f32]) {
        Self::mix_add(dst, src, 1.0);
    }

    /// Accumulates `src` samples scaled by `gain` into `dst` (`dst[i] += src[i] * gain`).
    #[inline]
    pub fn mix_add(dst: &mut [f32], src: &[f32], gain: f32) {
        if (gain - 0.0).abs() < f32::EPSILON {
            return;
        }

        let len = dst.len().min(src.len());
        let dst_slice = &mut dst[..len];
        let src_slice = &src[..len];

        #[cfg(target_arch = "x86_64")]
        {
            if is_x86_feature_detected!("avx2") && is_x86_feature_detected!("fma") {
                unsafe {
                    Self::mix_add_avx2(dst_slice, src_slice, gain);
                    return;
                }
            }
        }

        #[cfg(target_arch = "aarch64")]
        {
            unsafe {
                Self::mix_add_neon(dst_slice, src_slice, gain);
                return;
            }
        }

        Self::mix_add_scalar(dst_slice, src_slice, gain);
    }

    /// Scalar fallback loop accumulating `src` scaled by `gain` into `dst`.
    #[inline(always)]
    fn mix_add_scalar(dst: &mut [f32], src: &[f32], gain: f32) {
        for (d, s) in dst.iter_mut().zip(src.iter()) {
            *d += *s * gain;
        }
    }

    /// AVX2 + FMA vectorized loop accumulating `src` scaled by `gain` into `dst`.
    ///
    /// # Safety
    ///
    /// Caller must ensure the current CPU supports both `avx2` and `fma` target features,
    /// and `dst` and `src` must have equal lengths (`dst.len() == src.len()`).
    #[cfg(target_arch = "x86_64")]
    #[target_feature(enable = "avx2", enable = "fma")]
    unsafe fn mix_add_avx2(dst: &mut [f32], src: &[f32], gain: f32) {
        use std::arch::x86_64::*;
        let len = dst.len();
        let chunks = len / 8;
        let remainder = len % 8;

        let v_gain = _mm256_set1_ps(gain);

        let mut d_ptr = dst.as_mut_ptr();
        let mut s_ptr = src.as_ptr();

        for _ in 0..chunks {
            let vd = _mm256_loadu_ps(d_ptr);
            let vs = _mm256_loadu_ps(s_ptr);
            let vres = _mm256_fmadd_ps(vs, v_gain, vd);
            _mm256_storeu_ps(d_ptr, vres);

            d_ptr = d_ptr.add(8);
            s_ptr = s_ptr.add(8);
        }

        if remainder > 0 {
            let offset = chunks * 8;
            Self::mix_add_scalar(&mut dst[offset..], &src[offset..], gain);
        }
    }

    /// ARM NEON vectorized loop accumulating `src` scaled by `gain` into `dst`.
    ///
    /// # Safety
    ///
    /// Caller must ensure the current CPU supports the `neon` target feature,
    /// and `dst` and `src` must have equal lengths (`dst.len() == src.len()`).
    #[cfg(target_arch = "aarch64")]
    #[target_feature(enable = "neon")]
    unsafe fn mix_add_neon(dst: &mut [f32], src: &[f32], gain: f32) {
        use std::arch::aarch64::*;
        let len = dst.len();
        let chunks = len / 4;
        let remainder = len % 4;

        let v_gain = vdupq_n_f32(gain);

        let mut d_ptr = dst.as_mut_ptr();
        let mut s_ptr = src.as_ptr();

        for _ in 0..chunks {
            let vd = vld1q_f32(d_ptr);
            let vs = vld1q_f32(s_ptr);
            let vres = vmlaq_f32(vd, vs, v_gain);
            vst1q_f32(d_ptr, vres);

            d_ptr = d_ptr.add(4);
            s_ptr = s_ptr.add(4);
        }

        if remainder > 0 {
            let offset = chunks * 4;
            Self::mix_add_scalar(&mut dst[offset..], &src[offset..], gain);
        }
    }
}
