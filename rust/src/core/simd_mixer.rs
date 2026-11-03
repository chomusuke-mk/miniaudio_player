//! Vectorized SIMD Audio Mixer with AVX2 / ARM NEON support and Soft-Knee Headroom Saturation.
//!
//! Provides lock-free, zero-allocation summing, crossfading, gain modulation, and soft-knee
//! peak saturation to prevent digital harshness before the True-Peak limiter.

pub struct SimdMixer;

impl SimdMixer {
    #[inline]
    pub fn new() -> Self {
        Self
    }

    /// Vectorized accumulation: `dst[i] += src[i]`.
    #[inline]
    pub fn accumulate(&self, dst: &mut [f32], src: &[f32]) {
        Self::mix_add(dst, src, 1.0);
    }

    /// Vectorized accumulation with gain: `dst[i] += src[i] * gain`.
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

    /// Vectorized crossfade mix: `dst[i] = src_a[i] * gain_a + src_b[i] * gain_b`.
    #[inline]
    pub fn mix_crossfade(dst: &mut [f32], src_a: &[f32], src_b: &[f32], gain_a: f32, gain_b: f32) {
        let len = dst.len().min(src_a.len()).min(src_b.len());
        let dst_slice = &mut dst[..len];
        let a_slice = &src_a[..len];
        let b_slice = &src_b[..len];

        #[cfg(target_arch = "x86_64")]
        {
            if is_x86_feature_detected!("avx2") && is_x86_feature_detected!("fma") {
                unsafe {
                    Self::mix_crossfade_avx2(dst_slice, a_slice, b_slice, gain_a, gain_b);
                    return;
                }
            }
        }

        #[cfg(target_arch = "aarch64")]
        {
            unsafe {
                Self::mix_crossfade_neon(dst_slice, a_slice, b_slice, gain_a, gain_b);
                return;
            }
        }

        Self::mix_crossfade_scalar(dst_slice, a_slice, b_slice, gain_a, gain_b);
    }

    /// In-place gain multiplication: `buf[i] *= gain`.
    #[inline]
    pub fn apply_gain(buf: &mut [f32], gain: f32) {
        if (gain - 1.0).abs() < f32::EPSILON {
            return;
        }
        if (gain - 0.0).abs() < f32::EPSILON {
            buf.fill(0.0);
            return;
        }

        for sample in buf.iter_mut() {
            *sample *= gain;
        }
    }

    /// In-place linear gain ramp across the slice to eliminate click artifacts.
    #[inline]
    pub fn apply_gain_ramp(buf: &mut [f32], start_gain: f32, end_gain: f32) {
        let n = buf.len();
        if n == 0 {
            return;
        }
        let step = (end_gain - start_gain) / n as f32;
        let mut cur_gain = start_gain;
        for sample in buf.iter_mut() {
            *sample *= cur_gain;
            cur_gain += step;
        }
    }

    /// Soft-knee saturation headroom preventing harsh clipping distortion when summing voices.
    ///
    /// For inputs exceeding `threshold` (e.g. 0.95), applies an asymptotic hyperbolic curve
    /// smoothly bounded to 1.0 dBFS.
    #[inline]
    pub fn soft_knee_saturate(buf: &mut [f32], threshold: f32) {
        let t = threshold.clamp(0.5, 0.999);
        let range = 1.0 - t;
        let inv_range = 1.0 / range;

        for sample in buf.iter_mut() {
            let x = *sample;
            let abs_x = x.abs();
            if abs_x > t {
                let excess = (abs_x - t) * inv_range;
                let sat = t + range * (excess / (1.0 + excess));
                *sample = if x >= 0.0 { sat } else { -sat };
            }
        }
    }

    #[inline(always)]
    fn mix_add_scalar(dst: &mut [f32], src: &[f32], gain: f32) {
        for (d, s) in dst.iter_mut().zip(src.iter()) {
            *d += *s * gain;
        }
    }

    #[inline(always)]
    fn mix_crossfade_scalar(
        dst: &mut [f32],
        src_a: &[f32],
        src_b: &[f32],
        gain_a: f32,
        gain_b: f32,
    ) {
        for ((d, a), b) in dst.iter_mut().zip(src_a.iter()).zip(src_b.iter()) {
            *d = *a * gain_a + *b * gain_b;
        }
    }

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

    #[cfg(target_arch = "x86_64")]
    #[target_feature(enable = "avx2", enable = "fma")]
    unsafe fn mix_crossfade_avx2(
        dst: &mut [f32],
        src_a: &[f32],
        src_b: &[f32],
        gain_a: f32,
        gain_b: f32,
    ) {
        use std::arch::x86_64::*;
        let len = dst.len();
        let chunks = len / 8;
        let remainder = len % 8;

        let va_gain = _mm256_set1_ps(gain_a);
        let vb_gain = _mm256_set1_ps(gain_b);

        let mut d_ptr = dst.as_mut_ptr();
        let mut a_ptr = src_a.as_ptr();
        let mut b_ptr = src_b.as_ptr();

        for _ in 0..chunks {
            let va = _mm256_loadu_ps(a_ptr);
            let vb = _mm256_loadu_ps(b_ptr);
            let vprod_b = _mm256_mul_ps(vb, vb_gain);
            let vres = _mm256_fmadd_ps(va, va_gain, vprod_b);
            _mm256_storeu_ps(d_ptr, vres);

            d_ptr = d_ptr.add(8);
            a_ptr = a_ptr.add(8);
            b_ptr = b_ptr.add(8);
        }

        if remainder > 0 {
            let offset = chunks * 8;
            Self::mix_crossfade_scalar(
                &mut dst[offset..],
                &src_a[offset..],
                &src_b[offset..],
                gain_a,
                gain_b,
            );
        }
    }

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

    #[cfg(target_arch = "aarch64")]
    #[target_feature(enable = "neon")]
    unsafe fn mix_crossfade_neon(
        dst: &mut [f32],
        src_a: &[f32],
        src_b: &[f32],
        gain_a: f32,
        gain_b: f32,
    ) {
        use std::arch::aarch64::*;
        let len = dst.len();
        let chunks = len / 4;
        let remainder = len % 4;

        let va_gain = vdupq_n_f32(gain_a);
        let vb_gain = vdupq_n_f32(gain_b);

        let mut d_ptr = dst.as_mut_ptr();
        let mut a_ptr = src_a.as_ptr();
        let mut b_ptr = src_b.as_ptr();

        for _ in 0..chunks {
            let va = vld1q_f32(a_ptr);
            let vb = vld1q_f32(b_ptr);
            let vprod_b = vmulq_f32(vb, vb_gain);
            let vres = vmlaq_f32(vprod_b, va, va_gain);
            vst1q_f32(d_ptr, vres);

            d_ptr = d_ptr.add(4);
            a_ptr = a_ptr.add(4);
            b_ptr = b_ptr.add(4);
        }

        if remainder > 0 {
            let offset = chunks * 4;
            Self::mix_crossfade_scalar(
                &mut dst[offset..],
                &src_a[offset..],
                &src_b[offset..],
                gain_a,
                gain_b,
            );
        }
    }
}
