/**
 * @file map_dsp.c
 * @brief Equalizer composite node, biquad filters, crossfeed, and limiter implementation.
 */

#include "map_dsp.h"

#if defined(MAP_HAS_SSE2)
static MA_INLINE __m128 map_mm_abs_ps(__m128 v)
{
    __m128 mask = _mm_castsi128_ps(_mm_set1_epi32(0x7fffffff));
    return _mm_and_ps(v, mask);
}
#elif defined(MAP_HAS_SSE)
static MA_INLINE __m128 map_mm_abs_ps(__m128 v)
{
    MAP_ALIGN_CACHE_LINE static const unsigned int s_mask[4] = {
        0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
    };
    return _mm_and_ps(v, _mm_load_ps((const float *)(const void *)s_mask));
}
#endif

const double g_map_eq_frequencies[MAP_EQ_BAND_COUNT] = {
    31.0,
    63.0,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0
};

void map_biquad_bpf_init(map_biquad_df2t_t *filter, double f0, double fs, double q)
{
    double w0, alpha, cos_w, b0, b1, b2, a0, a1, a2;
    if (fs <= 0.0) fs = 44100.0;
    if (f0 >= fs * 0.49) f0 = fs * 0.49;
    if (f0 < 10.0) f0 = 10.0;
    if (q <= 0.0) q = 1.0;

    w0 = 2.0 * MA_PI_D * f0 / fs;
    alpha = sin(w0) / (2.0 * q);
    cos_w = cos(w0);

    b0 = alpha;
    b1 = 0.0;
    b2 = -alpha;
    a0 = 1.0 + alpha;
    a1 = -2.0 * cos_w;
    a2 = 1.0 - alpha;

    filter->b0 = (float)(b0 / a0);
    filter->b1 = (float)(b1 / a0);
    filter->b2 = (float)(b2 / a0);
    filter->a1 = (float)(a1 / a0);
    filter->a2 = (float)(a2 / a0);
    filter->s1 = 0.0f;
    filter->s2 = 0.0f;
}

void map_bs2b_init(map_bs2b_t *bs2b, uint32_t srate, uint32_t level)
{
    double Fc_lo, Fc_hi, G_lo, G_hi, GB_lo, GB_hi, lev_db, x;

    if (bs2b == NULL) return;
    memset(bs2b, 0, sizeof(*bs2b));

    if (srate < 2000 || srate > 384000) srate = 44100;
    bs2b->srate = srate;
    bs2b->level = level;

    Fc_lo = (double)(level & 0xffff);
    lev_db = (double)((level & 0xffff0000) >> 16);

    if (Fc_lo < 300.0 || Fc_lo > 2000.0 || lev_db < 10.0 || lev_db > 150.0)
    {
        Fc_lo = 700.0;
        lev_db = 45.0;
    }

    lev_db /= 10.0; /* dB */

    GB_lo = lev_db * (-5.0 / 6.0) - 3.0;
    GB_hi = lev_db / 6.0 - 3.0;

    G_lo = pow(10.0, GB_lo / 20.0);
    G_hi = 1.0 - pow(10.0, GB_hi / 20.0);
    Fc_hi = Fc_lo * pow(2.0, (GB_lo - 20.0 * log10(G_hi)) / 12.0);

    x = exp(-2.0 * M_PI * Fc_lo / (double)srate);
    bs2b->b1_lo = x;
    bs2b->a0_lo = G_lo * (1.0 - x);

    x = exp(-2.0 * M_PI * Fc_hi / (double)srate);
    bs2b->b1_hi = x;
    bs2b->a0_hi = 1.0 - G_hi * (1.0 - x);
    bs2b->a1_hi = -x;

    bs2b->gain = 1.0 / (1.0 - G_hi + G_lo);

    bs2b->a0_lo_f = (float)bs2b->a0_lo;
    bs2b->b1_lo_f = (float)bs2b->b1_lo;
    bs2b->a0_hi_f = (float)bs2b->a0_hi;
    bs2b->a1_hi_f = (float)bs2b->a1_hi;
    bs2b->b1_hi_f = (float)bs2b->b1_hi;
    bs2b->gain_f  = (float)bs2b->gain;
}

void map_bs2b_process_frames(map_bs2b_t *bs2b, float *pSamples, ma_uint32 frameCount, ma_uint32 channels)
{
    ma_uint32 f;
    if (bs2b == NULL || pSamples == NULL || channels < 2 || frameCount == 0) return;

#if defined(MAP_HAS_SSE)
    __m128 va0_lo = _mm_set1_ps(bs2b->a0_lo_f);
    __m128 vb1_lo = _mm_set1_ps(bs2b->b1_lo_f);
    __m128 va0_hi = _mm_set1_ps(bs2b->a0_hi_f);
    __m128 va1_hi = _mm_set1_ps(bs2b->a1_hi_f);
    __m128 vb1_hi = _mm_set1_ps(bs2b->b1_hi_f);
    __m128 vgain  = _mm_set1_ps(bs2b->gain_f);
    const __m128 v_thresh = _mm_set1_ps(1e-20f);

    /* Hoist filter delay states into local 128-bit SIMD registers before loop */
    __m128 vlo   = _mm_setr_ps((float)bs2b->lfs.lo[0],   (float)bs2b->lfs.lo[1],   0.0f, 0.0f);
    __m128 vhi   = _mm_setr_ps((float)bs2b->lfs.hi[0],   (float)bs2b->lfs.hi[1],   0.0f, 0.0f);
    __m128 vasis = _mm_setr_ps((float)bs2b->lfs.asis[0], (float)bs2b->lfs.asis[1], 0.0f, 0.0f);

    for (f = 0; f < frameCount; f++)
    {
        float l = pSamples[f * channels];
        float r = pSamples[f * channels + 1];
        __m128 vin = _mm_setr_ps(l, r, 0.0f, 0.0f);

        /* Lowpass filter: vlo = va0_lo * vin + vb1_lo * vlo */
        vlo = _mm_add_ps(_mm_mul_ps(va0_lo, vin), _mm_mul_ps(vb1_lo, vlo));

        /* Highboost filter: vhi = va0_hi * vin + va1_hi * vasis + vb1_hi * vhi */
        vhi = _mm_add_ps(_mm_add_ps(_mm_mul_ps(va0_hi, vin), _mm_mul_ps(va1_hi, vasis)),
                         _mm_mul_ps(vb1_hi, vhi));
        vasis = vin;

        /* Crossfeed: out_l = (hi0 + lo1) * gain; out_r = (hi1 + lo0) * gain */
        __m128 vlo_swap = _mm_shuffle_ps(vlo, vlo, _MM_SHUFFLE(3, 2, 0, 1));
        __m128 vout = _mm_mul_ps(_mm_add_ps(vhi, vlo_swap), vgain);

        /* Anti-denormal protection */
        __m128 mask_lo = _mm_cmpge_ps(map_mm_abs_ps(vlo), v_thresh);
        vlo = _mm_and_ps(vlo, mask_lo);

        __m128 mask_hi = _mm_cmpge_ps(map_mm_abs_ps(vhi), v_thresh);
        vhi = _mm_and_ps(vhi, mask_hi);

        pSamples[f * channels]     = _mm_cvtss_f32(vout);
        pSamples[f * channels + 1] = _mm_cvtss_f32(_mm_shuffle_ps(vout, vout, _MM_SHUFFLE(1, 1, 1, 1)));
    }

    /* Write back filter delay states once at buffer completion */
    bs2b->lfs.lo[0]   = (double)_mm_cvtss_f32(vlo);
    bs2b->lfs.lo[1]   = (double)_mm_cvtss_f32(_mm_shuffle_ps(vlo, vlo, _MM_SHUFFLE(1, 1, 1, 1)));
    bs2b->lfs.hi[0]   = (double)_mm_cvtss_f32(vhi);
    bs2b->lfs.hi[1]   = (double)_mm_cvtss_f32(_mm_shuffle_ps(vhi, vhi, _MM_SHUFFLE(1, 1, 1, 1)));
    bs2b->lfs.asis[0] = (double)_mm_cvtss_f32(vasis);
    bs2b->lfs.asis[1] = (double)_mm_cvtss_f32(_mm_shuffle_ps(vasis, vasis, _MM_SHUFFLE(1, 1, 1, 1)));

#elif defined(MAP_HAS_NEON)
    float32x2_t va0_lo = vdup_n_f32(bs2b->a0_lo_f);
    float32x2_t vb1_lo = vdup_n_f32(bs2b->b1_lo_f);
    float32x2_t va0_hi = vdup_n_f32(bs2b->a0_hi_f);
    float32x2_t va1_hi = vdup_n_f32(bs2b->a1_hi_f);
    float32x2_t vb1_hi = vdup_n_f32(bs2b->b1_hi_f);
    float32x2_t vgain  = vdup_n_f32(bs2b->gain_f);
    float32x2_t v_thresh = vdup_n_f32(1e-20f);

    float init_lo[2]   = {(float)bs2b->lfs.lo[0],   (float)bs2b->lfs.lo[1]};
    float init_hi[2]   = {(float)bs2b->lfs.hi[0],   (float)bs2b->lfs.hi[1]};
    float init_asis[2] = {(float)bs2b->lfs.asis[0], (float)bs2b->lfs.asis[1]};

    float32x2_t vlo   = vld1_f32(init_lo);
    float32x2_t vhi   = vld1_f32(init_hi);
    float32x2_t vasis = vld1_f32(init_asis);

    if (channels == 2)
    {
        for (f = 0; f < frameCount; f++)
        {
            float32x2_t vin = vld1_f32(&pSamples[f * 2]);

            /* Lowpass filter */
            vlo = vmla_f32(vmul_f32(va0_lo, vin), vb1_lo, vlo);

            /* Highboost filter */
            vhi = vadd_f32(vmla_f32(vmul_f32(va0_hi, vin), va1_hi, vasis), vmul_f32(vb1_hi, vhi));
            vasis = vin;

            /* Crossfeed swap */
            float32x2_t vlo_swap = vrev64_f32(vlo);
            float32x2_t vout = vmul_f32(vadd_f32(vhi, vlo_swap), vgain);

            /* Anti-denormal */
            uint32x2_t mask_lo = vcge_f32(vabs_f32(vlo), v_thresh);
            vlo = vreinterpret_f32_u32(vand_u32(vreinterpret_u32_f32(vlo), mask_lo));

            uint32x2_t mask_hi = vcge_f32(vabs_f32(vhi), v_thresh);
            vhi = vreinterpret_f32_u32(vand_u32(vreinterpret_u32_f32(vhi), mask_hi));

            vst1_f32(&pSamples[f * 2], vout);
        }
    }
    else
    {
        for (f = 0; f < frameCount; f++)
        {
            float *ptr = &pSamples[f * channels];
            float32x2_t vin = vld1_f32(ptr);

            /* Lowpass filter */
            vlo = vmla_f32(vmul_f32(va0_lo, vin), vb1_lo, vlo);

            /* Highboost filter */
            vhi = vadd_f32(vmla_f32(vmul_f32(va0_hi, vin), va1_hi, vasis), vmul_f32(vb1_hi, vhi));
            vasis = vin;

            /* Crossfeed swap */
            float32x2_t vlo_swap = vrev64_f32(vlo);
            float32x2_t vout = vmul_f32(vadd_f32(vhi, vlo_swap), vgain);

            /* Anti-denormal */
            uint32x2_t mask_lo = vcge_f32(vabs_f32(vlo), v_thresh);
            vlo = vreinterpret_f32_u32(vand_u32(vreinterpret_u32_f32(vlo), mask_lo));

            uint32x2_t mask_hi = vcge_f32(vabs_f32(vhi), v_thresh);
            vhi = vreinterpret_f32_u32(vand_u32(vreinterpret_u32_f32(vhi), mask_hi));

            ptr[0] = vget_lane_f32(vout, 0);
            ptr[1] = vget_lane_f32(vout, 1);
        }
    }

    float end_lo[2], end_hi[2], end_asis[2];
    vst1_f32(end_lo, vlo);
    vst1_f32(end_hi, vhi);
    vst1_f32(end_asis, vasis);
    bs2b->lfs.lo[0]   = (double)end_lo[0];
    bs2b->lfs.lo[1]   = (double)end_lo[1];
    bs2b->lfs.hi[0]   = (double)end_hi[0];
    bs2b->lfs.hi[1]   = (double)end_hi[1];
    bs2b->lfs.asis[0] = (double)end_asis[0];
    bs2b->lfs.asis[1] = (double)end_asis[1];

#else
    float a0_lo = bs2b->a0_lo_f;
    float b1_lo = bs2b->b1_lo_f;
    float a0_hi = bs2b->a0_hi_f;
    float a1_hi = bs2b->a1_hi_f;
    float b1_hi = bs2b->b1_hi_f;
    float gain  = bs2b->gain_f;

    float lo0   = (float)bs2b->lfs.lo[0];
    float lo1   = (float)bs2b->lfs.lo[1];
    float hi0   = (float)bs2b->lfs.hi[0];
    float hi1   = (float)bs2b->lfs.hi[1];
    float asis0 = (float)bs2b->lfs.asis[0];
    float asis1 = (float)bs2b->lfs.asis[1];

    for (f = 0; f < frameCount; f++)
    {
        float l = pSamples[f * channels];
        float r = pSamples[f * channels + 1];

        lo0 = a0_lo * l + b1_lo * lo0;
        lo1 = a0_lo * r + b1_lo * lo1;

        hi0 = a0_hi * l + a1_hi * asis0 + b1_hi * hi0;
        hi1 = a0_hi * r + a1_hi * asis1 + b1_hi * hi1;
        asis0 = l;
        asis1 = r;

        float out_l = (hi0 + lo1) * gain;
        float out_r = (hi1 + lo0) * gain;

        if (fabsf(lo0) < 1e-20f) lo0 = 0.0f;
        if (fabsf(lo1) < 1e-20f) lo1 = 0.0f;
        if (fabsf(hi0) < 1e-20f) hi0 = 0.0f;
        if (fabsf(hi1) < 1e-20f) hi1 = 0.0f;

        pSamples[f * channels]     = out_l;
        pSamples[f * channels + 1] = out_r;
    }

    bs2b->lfs.lo[0]   = (double)lo0;
    bs2b->lfs.lo[1]   = (double)lo1;
    bs2b->lfs.hi[0]   = (double)hi0;
    bs2b->lfs.hi[1]   = (double)hi1;
    bs2b->lfs.asis[0] = (double)asis0;
    bs2b->lfs.asis[1] = (double)asis1;
#endif
}

float map_calculate_effective_preamp(const miniaudio_player_replay_gain_config_t *rg, float standalone_preamp_db)
{
    float total_db = standalone_preamp_db;
    if (rg != NULL && rg->enabled)
    {
        total_db += rg->gain_db + rg->preamp_db;
    }
    float linear = powf(10.0f, total_db / 20.0f);
    if (rg != NULL && rg->enabled && rg->prevent_clipping && rg->peak > 0.0001f)
    {
        if (linear * rg->peak > 1.0f)
        {
            linear = 1.0f / rg->peak;
        }
    }
    if (linear < 0.0f) linear = 0.0f;
    return linear;
}

void ma_equalizer_node_process_pcm_frames(
    ma_node *pNode,
    const float **ppFramesIn,
    ma_uint32 *pFrameCountIn,
    float **ppFramesOut,
    ma_uint32 *pFrameCountOut)
{
    ma_equalizer_node *pEq = (ma_equalizer_node *)pNode;
    ma_uint32 frameCount;
    int i;
    (void)pFrameCountIn;

    if (pEq == NULL || ppFramesIn == NULL || ppFramesOut == NULL ||
        ppFramesIn[0] == NULL || ppFramesOut[0] == NULL || pFrameCountOut == NULL)
    {
        return;
    }

    frameCount = *pFrameCountOut;
    if (frameCount == 0)
    {
        return;
    }

    ma_spinlock_lock(&pEq->lock);

    /* 1. Preamp & ReplayGain: Transfer from ppFramesIn to ppFramesOut with gain smoothing */
    {
        float target_linear = map_calculate_effective_preamp(&pEq->rg_config, pEq->preamp_db);
        float current_linear = pEq->current_preamp_linear;
        const float *pIn = ppFramesIn[0];
        float *pOut = ppFramesOut[0];
        ma_uint32 ch = pEq->channels;
        ma_uint32 f, c;
        float sf = pEq->smooth_factor;

        for (f = 0; f < frameCount; f++)
        {
            current_linear += (target_linear - current_linear) * sf;
            for (c = 0; c < ch; c++)
            {
                pOut[f * ch + c] = pIn[f * ch + c] * current_linear;
            }
        }
        if (fabsf(current_linear) < 1e-15f) current_linear = 0.0f;
        pEq->current_preamp_linear = current_linear;
        pEq->target_preamp_linear = target_linear;
    }

    /* 2. Equalizer (10 Bands): Fused SIMD Biquad Cascade (NP3-05) */
    {
        typedef struct {
            float b0, b1, b2, a1, a2;
            ma_biquad_coefficient *pR1;
            ma_biquad_coefficient *pR2;
        } map_active_biquad_t;

        map_active_biquad_t active_bqs[10];
        int num_active = 0;
        ma_biquad *bqs[10];
        bqs[0] = &pEq->loshelf.bq;
        for (i = 0; i < 8; i++)
            bqs[1 + i] = &pEq->peaks[i].bq;
        bqs[9] = &pEq->hishelf.bq;

        for (i = 0; i < 10; i++)
        {
            ma_biquad *bq = bqs[i];
            /* A band is active if non-zero gain OR delay registers haven't completely settled */
            ma_bool32 is_active = (fabsf(pEq->band_gains[i]) > 0.0001f);
            if (!is_active)
            {
                ma_uint32 c;
                for (c = 0; c < pEq->channels; c++)
                {
                    if (fabsf(bq->pR1[c].f32) > 1e-15f || fabsf(bq->pR2[c].f32) > 1e-15f)
                    {
                        is_active = MA_TRUE;
                        break;
                    }
                }
                if (!is_active && (fabsf(bq->b0.f32 - 1.0f) > 0.0001f ||
                                   fabsf(bq->b1.f32) > 0.0001f ||
                                   fabsf(bq->b2.f32) > 0.0001f ||
                                   fabsf(bq->a1.f32) > 0.0001f ||
                                   fabsf(bq->a2.f32) > 0.0001f))
                {
                    is_active = MA_TRUE;
                }
            }

            if (is_active)
            {
                active_bqs[num_active].b0 = bq->b0.f32;
                active_bqs[num_active].b1 = bq->b1.f32;
                active_bqs[num_active].b2 = bq->b2.f32;
                active_bqs[num_active].a1 = bq->a1.f32;
                active_bqs[num_active].a2 = bq->a2.f32;
                active_bqs[num_active].pR1 = bq->pR1;
                active_bqs[num_active].pR2 = bq->pR2;
                num_active++;
            }
        }

        if (num_active > 0)
        {
            float *pSamples = ppFramesOut[0];
            ma_uint32 ch = pEq->channels;

            if (ch == 2)
            {
                /* Fused Stereo Kernel with Packed SIMD Block Vectorization:
                 * 1. Hoist filter delay registers (s1, s2) into contiguous stack arrays
                 *    before the frame loop, eliminating 81,920 pointer dereferences per buffer.
                 * 2. Process audio in L1 cache-resident blocks (MAP_DSP_STEREO_BLOCK_SIZE = 64 frames).
                 * 3. Vectorize stereo L/R channel processing using packed SIMD (SSE / NEON / portable fallback).
                 * 4. Write back final filter states to abq->pR1/pR2 only ONCE at buffer completion.
                 */
                MAP_ALIGN_CACHE_LINE float s1_l[10];
                MAP_ALIGN_CACHE_LINE float s2_l[10];
                MAP_ALIGN_CACHE_LINE float s1_r[10];
                MAP_ALIGN_CACHE_LINE float s2_r[10];

                for (i = 0; i < num_active; i++)
                {
                    s1_l[i] = active_bqs[i].pR1[0].f32;
                    s2_l[i] = active_bqs[i].pR2[0].f32;
                    s1_r[i] = active_bqs[i].pR1[1].f32;
                    s2_r[i] = active_bqs[i].pR2[1].f32;
                }

                ma_uint32 f_start;
                for (f_start = 0; f_start < frameCount; f_start += MAP_DSP_STEREO_BLOCK_SIZE)
                {
                    ma_uint32 block_count = ((frameCount - f_start) < MAP_DSP_STEREO_BLOCK_SIZE) ?
                                            (frameCount - f_start) : MAP_DSP_STEREO_BLOCK_SIZE;

                    for (i = 0; i < num_active; i++)
                    {
                        float b0 = active_bqs[i].b0;
                        float b1 = active_bqs[i].b1;
                        float b2 = active_bqs[i].b2;
                        float a1 = active_bqs[i].a1;
                        float a2 = active_bqs[i].a2;

#if defined(MAP_HAS_SSE)
                        __m128 vb0 = _mm_set1_ps(b0);
                        __m128 vb1 = _mm_set1_ps(b1);
                        __m128 vb2 = _mm_set1_ps(b2);
                        __m128 va1 = _mm_set1_ps(a1);
                        __m128 va2 = _mm_set1_ps(a2);
                        __m128 vs1 = _mm_setr_ps(s1_l[i], s1_r[i], 0.0f, 0.0f);
                        __m128 vs2 = _mm_setr_ps(s2_l[i], s2_r[i], 0.0f, 0.0f);
                        const __m128 v_thresh = _mm_set1_ps(1e-20f);
                        ma_uint32 k;

                        for (k = 0; k < block_count; k++)
                        {
                            float *pFrame = &pSamples[(f_start + k) * 2];
                            __m128 vin = _mm_setr_ps(pFrame[0], pFrame[1], 0.0f, 0.0f);

                            __m128 vy = _mm_add_ps(_mm_mul_ps(vb0, vin), vs1);
                            __m128 vr1 = _mm_add_ps(_mm_sub_ps(_mm_mul_ps(vb1, vin), _mm_mul_ps(va1, vy)), vs2);
                            __m128 vr2 = _mm_sub_ps(_mm_mul_ps(vb2, vin), _mm_mul_ps(va2, vy));

                            /* Anti-denormal flush */
                            __m128 mask1 = _mm_cmpge_ps(map_mm_abs_ps(vr1), v_thresh);
                            vs1 = _mm_and_ps(vr1, mask1);

                            __m128 mask2 = _mm_cmpge_ps(map_mm_abs_ps(vr2), v_thresh);
                            vs2 = _mm_and_ps(vr2, mask2);

                            pFrame[0] = _mm_cvtss_f32(vy);
                            pFrame[1] = _mm_cvtss_f32(_mm_shuffle_ps(vy, vy, _MM_SHUFFLE(1, 1, 1, 1)));
                        }

                        s1_l[i] = _mm_cvtss_f32(vs1);
                        s1_r[i] = _mm_cvtss_f32(_mm_shuffle_ps(vs1, vs1, _MM_SHUFFLE(1, 1, 1, 1)));
                        s2_l[i] = _mm_cvtss_f32(vs2);
                        s2_r[i] = _mm_cvtss_f32(_mm_shuffle_ps(vs2, vs2, _MM_SHUFFLE(1, 1, 1, 1)));

#elif defined(MAP_HAS_NEON)
                        float32x2_t vb0 = vdup_n_f32(b0);
                        float32x2_t vb1 = vdup_n_f32(b1);
                        float32x2_t vb2 = vdup_n_f32(b2);
                        float32x2_t va1 = vdup_n_f32(a1);
                        float32x2_t va2 = vdup_n_f32(a2);
                        float32x2_t v_thresh = vdup_n_f32(1e-20f);

                        float init_s1[2] = {s1_l[i], s1_r[i]};
                        float init_s2[2] = {s2_l[i], s2_r[i]};
                        float32x2_t vs1 = vld1_f32(init_s1);
                        float32x2_t vs2 = vld1_f32(init_s2);
                        ma_uint32 k;

                        for (k = 0; k < block_count; k++)
                        {
                            float *pFrame = &pSamples[(f_start + k) * 2];
                            float32x2_t vin = vld1_f32(pFrame);

                            float32x2_t vy = vmla_f32(vs1, vb0, vin);
                            float32x2_t vr1 = vmls_f32(vmla_f32(vs2, vb1, vin), va1, vy);
                            float32x2_t vr2 = vmls_f32(vmul_f32(vb2, vin), va2, vy);

                            uint32x2_t mask1 = vcge_f32(vabs_f32(vr1), v_thresh);
                            vs1 = vreinterpret_f32_u32(vand_u32(vreinterpret_u32_f32(vr1), mask1));

                            uint32x2_t mask2 = vcge_f32(vabs_f32(vr2), v_thresh);
                            vs2 = vreinterpret_f32_u32(vand_u32(vreinterpret_u32_f32(vr2), mask2));

                            vst1_f32(pFrame, vy);
                        }

                        float end_s1[2], end_s2[2];
                        vst1_f32(end_s1, vs1);
                        vst1_f32(end_s2, vs2);
                        s1_l[i] = end_s1[0];
                        s1_r[i] = end_s1[1];
                        s2_l[i] = end_s2[0];
                        s2_r[i] = end_s2[1];

#else
                        float cur_s1_l = s1_l[i];
                        float cur_s2_l = s2_l[i];
                        float cur_s1_r = s1_r[i];
                        float cur_s2_r = s2_r[i];
                        ma_uint32 k;

                        for (k = 0; k < block_count; k++)
                        {
                            float l = pSamples[(f_start + k) * 2 + 0];
                            float r = pSamples[(f_start + k) * 2 + 1];

                            float y_l = b0 * l + cur_s1_l;
                            float next_r1_l = b1 * l - a1 * y_l + cur_s2_l;
                            float next_r2_l = b2 * l - a2 * y_l;
                            if (fabsf(next_r1_l) < 1e-20f) next_r1_l = 0.0f;
                            if (fabsf(next_r2_l) < 1e-20f) next_r2_l = 0.0f;
                            cur_s1_l = next_r1_l;
                            cur_s2_l = next_r2_l;

                            float y_r = b0 * r + cur_s1_r;
                            float next_r1_r = b1 * r - a1 * y_r + cur_s2_r;
                            float next_r2_r = b2 * r - a2 * y_r;
                            if (fabsf(next_r1_r) < 1e-20f) next_r1_r = 0.0f;
                            if (fabsf(next_r2_r) < 1e-20f) next_r2_r = 0.0f;
                            cur_s1_r = next_r1_r;
                            cur_s2_r = next_r2_r;

                            pSamples[(f_start + k) * 2 + 0] = y_l;
                            pSamples[(f_start + k) * 2 + 1] = y_r;
                        }

                        s1_l[i] = cur_s1_l;
                        s2_l[i] = cur_s2_l;
                        s1_r[i] = cur_s1_r;
                        s2_r[i] = cur_s2_r;
#endif
                    }
                }

                /* Write back final filter states to abq->pR1/pR2 only ONCE at buffer completion */
                for (i = 0; i < num_active; i++)
                {
                    active_bqs[i].pR1[0].f32 = s1_l[i];
                    active_bqs[i].pR2[0].f32 = s2_l[i];
                    active_bqs[i].pR1[1].f32 = s1_r[i];
                    active_bqs[i].pR2[1].f32 = s2_r[i];
                }
            }
            else if (ch == 1)
            {
                /* Fused Mono Kernel with Local State Hoisting */
                MAP_ALIGN_CACHE_LINE float s1[10];
                MAP_ALIGN_CACHE_LINE float s2[10];

                for (i = 0; i < num_active; i++)
                {
                    s1[i] = active_bqs[i].pR1[0].f32;
                    s2[i] = active_bqs[i].pR2[0].f32;
                }

                ma_uint32 f_start;
                for (f_start = 0; f_start < frameCount; f_start += MAP_DSP_STEREO_BLOCK_SIZE)
                {
                    ma_uint32 block_count = ((frameCount - f_start) < MAP_DSP_STEREO_BLOCK_SIZE) ?
                                            (frameCount - f_start) : MAP_DSP_STEREO_BLOCK_SIZE;

                    for (i = 0; i < num_active; i++)
                    {
                        float b0 = active_bqs[i].b0;
                        float b1 = active_bqs[i].b1;
                        float b2 = active_bqs[i].b2;
                        float a1 = active_bqs[i].a1;
                        float a2 = active_bqs[i].a2;
                        float r1 = s1[i];
                        float r2 = s2[i];
                        ma_uint32 k;

                        for (k = 0; k < block_count; k++)
                        {
                            float x = pSamples[f_start + k];
                            float y = b0 * x + r1;
                            float next_r1 = b1 * x - a1 * y + r2;
                            float next_r2 = b2 * x - a2 * y;
                            if (fabsf(next_r1) < 1e-20f) next_r1 = 0.0f;
                            if (fabsf(next_r2) < 1e-20f) next_r2 = 0.0f;
                            r1 = next_r1;
                            r2 = next_r2;
                            pSamples[f_start + k] = y;
                        }

                        s1[i] = r1;
                        s2[i] = r2;
                    }
                }

                for (i = 0; i < num_active; i++)
                {
                    active_bqs[i].pR1[0].f32 = s1[i];
                    active_bqs[i].pR2[0].f32 = s2[i];
                }
            }
            else
            {
                /* Multichannel Fused Kernel with Local State Hoisting */
                ma_uint32 c;
                for (c = 0; c < ch; c++)
                {
                    MAP_ALIGN_CACHE_LINE float s1[10];
                    MAP_ALIGN_CACHE_LINE float s2[10];

                    for (i = 0; i < num_active; i++)
                    {
                        s1[i] = active_bqs[i].pR1[c].f32;
                        s2[i] = active_bqs[i].pR2[c].f32;
                    }

                    ma_uint32 f_start;
                    for (f_start = 0; f_start < frameCount; f_start += MAP_DSP_STEREO_BLOCK_SIZE)
                    {
                        ma_uint32 block_count = ((frameCount - f_start) < MAP_DSP_STEREO_BLOCK_SIZE) ?
                                                (frameCount - f_start) : MAP_DSP_STEREO_BLOCK_SIZE;

                        for (i = 0; i < num_active; i++)
                        {
                            float b0 = active_bqs[i].b0;
                            float b1 = active_bqs[i].b1;
                            float b2 = active_bqs[i].b2;
                            float a1 = active_bqs[i].a1;
                            float a2 = active_bqs[i].a2;
                            float r1 = s1[i];
                            float r2 = s2[i];
                            ma_uint32 k;

                            for (k = 0; k < block_count; k++)
                            {
                                float x = pSamples[(f_start + k) * ch + c];
                                float y = b0 * x + r1;
                                float next_r1 = b1 * x - a1 * y + r2;
                                float next_r2 = b2 * x - a2 * y;
                                if (fabsf(next_r1) < 1e-20f) next_r1 = 0.0f;
                                if (fabsf(next_r2) < 1e-20f) next_r2 = 0.0f;
                                r1 = next_r1;
                                r2 = next_r2;
                                pSamples[(f_start + k) * ch + c] = y;
                            }

                            s1[i] = r1;
                            s2[i] = r2;
                        }
                    }

                    for (i = 0; i < num_active; i++)
                    {
                        active_bqs[i].pR1[c].f32 = s1[i];
                        active_bqs[i].pR2[c].f32 = s2[i];
                    }
                }
            }
        }
    }

    /* 2.5. Reverb: Algorithmic Stereo Room Simulation (Freeverb) */
    if (pEq->reverb_enabled)
    {
        map_reverb_process_frames(&pEq->reverb, ppFramesOut[0], frameCount, pEq->channels);
    }

    /* 3. Spatial Processing (Crossfeed or Spatializer) */
    if (pEq->channels >= 2)
    {
        if (pEq->crossfeed_mode != MAP_CROSSFEED_OFF)
        {
            map_bs2b_process_frames(&pEq->bs2b, ppFramesOut[0], frameCount, pEq->channels);
        }
        else if (pEq->spatializer_enabled && pEq->spatializer_width > 1.0f)
        {
            ma_uint32 f;
            float w = pEq->spatializer_width;
            float *pSamples = ppFramesOut[0];
            ma_uint32 ch = pEq->channels;
            for (f = 0; f < frameCount; f++)
            {
                float l = pSamples[f * ch];
                float r = pSamples[f * ch + 1];
                float mid = 0.5f * (l + r);
                float side = 0.5f * (l - r) * w;
                pSamples[f * ch] = mid + side;
                pSamples[f * ch + 1] = mid - side;
            }
        }
    }

    /* 4. Mono Downmix */
    if (pEq->mono_enabled && pEq->channels >= 2)
    {
        ma_uint32 f;
        float *pSamples = ppFramesOut[0];
        ma_uint32 ch = pEq->channels;
        for (f = 0; f < frameCount; f++)
        {
            float l = pSamples[f * ch];
            float r = pSamples[f * ch + 1];
            float mono = 0.5f * (l + r);
            pSamples[f * ch] = mono;
            pSamples[f * ch + 1] = mono;
        }
    }

    /* 5. Stereo Balance / Pan (L/R) with optimized smoothing (Zero per-frame trig calls) */
    if (pEq->channels >= 2)
    {
        ma_uint32 f;
        float *pSamples = ppFramesOut[0];
        ma_uint32 ch = pEq->channels;
        float target_bal = pEq->balance;
        float cur_bal = pEq->current_balance;

        float norm = (target_bal + 1.0f) * 0.5f;
        if (norm < 0.0f) norm = 0.0f;
        if (norm > 1.0f) norm = 1.0f;
        float angle = norm * 1.57079632679f; /* PI / 2 */
        float tgt_gl = cosf(angle) * 1.41421356f;
        float tgt_gr = sinf(angle) * 1.41421356f;
        float cur_gl = pEq->current_gl;
        float cur_gr = pEq->current_gr;

        if (cur_bal == target_bal && fabsf(cur_gl - tgt_gl) < 0.0001f && fabsf(cur_gr - tgt_gr) < 0.0001f)
        {
            /* Steady-state path: Vectorized gain scaling */
            for (f = 0; f < frameCount; f++)
            {
                pSamples[f * ch]     *= tgt_gl;
                pSamples[f * ch + 1] *= tgt_gr;
            }
            pEq->current_gl = tgt_gl;
            pEq->current_gr = tgt_gr;
        }
        else
        {
            /* Ramp path: Linear step without per-frame trig calculations */
            float gl_step = (tgt_gl - cur_gl) / (float)frameCount;
            float gr_step = (tgt_gr - cur_gr) / (float)frameCount;
            for (f = 0; f < frameCount; f++)
            {
                cur_gl += gl_step;
                cur_gr += gr_step;
                pSamples[f * ch]     *= cur_gl;
                pSamples[f * ch + 1] *= cur_gr;
            }
            pEq->current_gl = tgt_gl;
            pEq->current_gr = tgt_gr;
            pEq->current_balance = target_bal;
        }
    }

    /* 6. Pre-Fader Visualizer Tap (measures balanced & equalized audio before master fader) */
    if (pEq->visualizer_enabled)
    {
        ma_uint32 totalFrames = frameCount;
        ma_uint32 ch = pEq->channels;
        float *pSamples = ppFramesOut[0];
        float sum_sq_l = 0.0f, sum_sq_r = 0.0f;
        float peak_l = 0.0f, peak_r = 0.0f;
        ma_uint32 s;
        int b;

        /* Hoist visualizer BPF states and coefficients to 64-byte aligned local arrays.
         * Padded to 12 elements (3 x 4-wide SIMD vectors across filter bands sharing scalar mono input). */
        MAP_ALIGN_CACHE_LINE float b0[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float b1[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float b2[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float a1[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float a2[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float s1[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float s2[12] = {0.0f};
        MAP_ALIGN_CACHE_LINE float band_sq[12] = {0.0f};

        for (b = 0; b < 10; b++)
        {
            b0[b] = pEq->vis_bpf[b].b0;
            b1[b] = pEq->vis_bpf[b].b1;
            b2[b] = pEq->vis_bpf[b].b2;
            a1[b] = pEq->vis_bpf[b].a1;
            a2[b] = pEq->vis_bpf[b].a2;
            s1[b] = pEq->vis_bpf[b].s1;
            s2[b] = pEq->vis_bpf[b].s2;
        }

        ma_uint32 eval_count = 0;

#if defined(MAP_HAS_SSE)
        __m128 vb0_0 = _mm_load_ps(&b0[0]);
        __m128 vb1_0 = _mm_load_ps(&b1[0]);
        __m128 vb2_0 = _mm_load_ps(&b2[0]);
        __m128 va1_0 = _mm_load_ps(&a1[0]);
        __m128 va2_0 = _mm_load_ps(&a2[0]);
        __m128 vs1_0 = _mm_load_ps(&s1[0]);
        __m128 vs2_0 = _mm_load_ps(&s2[0]);
        __m128 vsq_0 = _mm_setzero_ps();

        __m128 vb0_1 = _mm_load_ps(&b0[4]);
        __m128 vb1_1 = _mm_load_ps(&b1[4]);
        __m128 vb2_1 = _mm_load_ps(&b2[4]);
        __m128 va1_1 = _mm_load_ps(&a1[4]);
        __m128 va2_1 = _mm_load_ps(&a2[4]);
        __m128 vs1_1 = _mm_load_ps(&s1[4]);
        __m128 vs2_1 = _mm_load_ps(&s2[4]);
        __m128 vsq_1 = _mm_setzero_ps();

        __m128 vb0_2 = _mm_load_ps(&b0[8]);
        __m128 vb1_2 = _mm_load_ps(&b1[8]);
        __m128 vb2_2 = _mm_load_ps(&b2[8]);
        __m128 va1_2 = _mm_load_ps(&a1[8]);
        __m128 va2_2 = _mm_load_ps(&a2[8]);
        __m128 vs1_2 = _mm_load_ps(&s1[8]);
        __m128 vs2_2 = _mm_load_ps(&s2[8]);
        __m128 vsq_2 = _mm_setzero_ps();
#elif defined(MAP_HAS_NEON)
        float32x4_t vb0_0 = vld1q_f32(&b0[0]);
        float32x4_t vb1_0 = vld1q_f32(&b1[0]);
        float32x4_t vb2_0 = vld1q_f32(&b2[0]);
        float32x4_t va1_0 = vld1q_f32(&a1[0]);
        float32x4_t va2_0 = vld1q_f32(&a2[0]);
        float32x4_t vs1_0 = vld1q_f32(&s1[0]);
        float32x4_t vs2_0 = vld1q_f32(&s2[0]);
        float32x4_t vsq_0 = vdupq_n_f32(0.0f);

        float32x4_t vb0_1 = vld1q_f32(&b0[4]);
        float32x4_t vb1_1 = vld1q_f32(&b1[4]);
        float32x4_t vb2_1 = vld1q_f32(&b2[4]);
        float32x4_t va1_1 = vld1q_f32(&a1[4]);
        float32x4_t va2_1 = vld1q_f32(&a2[4]);
        float32x4_t vs1_1 = vld1q_f32(&s1[4]);
        float32x4_t vs2_1 = vld1q_f32(&s2[4]);
        float32x4_t vsq_1 = vdupq_n_f32(0.0f);

        float32x4_t vb0_2 = vld1q_f32(&b0[8]);
        float32x4_t vb1_2 = vld1q_f32(&b1[8]);
        float32x4_t vb2_2 = vld1q_f32(&b2[8]);
        float32x4_t va1_2 = vld1q_f32(&a1[8]);
        float32x4_t va2_2 = vld1q_f32(&a2[8]);
        float32x4_t vs1_2 = vld1q_f32(&s1[8]);
        float32x4_t vs2_2 = vld1q_f32(&s2[8]);
        float32x4_t vsq_2 = vdupq_n_f32(0.0f);
#endif

        /* Visualizer evaluation loop: full sample rate evaluation with SIMD across all 10 bands */
        for (s = 0; s < totalFrames; s++)
        {
            float l = pSamples[s * ch];
            float r = (ch > 1) ? pSamples[s * ch + 1] : l;
            float abs_l = fabsf(l);
            float abs_r = fabsf(r);
            float mono = 0.5f * (l + r);

            sum_sq_l += l * l;
            sum_sq_r += r * r;
            if (abs_l > peak_l) peak_l = abs_l;
            if (abs_r > peak_r) peak_r = abs_r;

            eval_count++;

            /* Anti-denormal DC bias injection: eliminates branching fabsf checks */
            const float x = mono + 1e-25f;

#if defined(MAP_HAS_SSE)
            __m128 vx = _mm_set1_ps(x);

            /* Group 0: Bands 0..3 */
            {
                __m128 vy = _mm_add_ps(_mm_mul_ps(vb0_0, vx), vs1_0);
                __m128 vt1 = _mm_sub_ps(_mm_mul_ps(vb1_0, vx), _mm_mul_ps(va1_0, vy));
                vs1_0 = _mm_add_ps(vt1, vs2_0);
                vs2_0 = _mm_sub_ps(_mm_mul_ps(vb2_0, vx), _mm_mul_ps(va2_0, vy));
                vsq_0 = _mm_add_ps(vsq_0, _mm_mul_ps(vy, vy));
            }

            /* Group 1: Bands 4..7 */
            {
                __m128 vy = _mm_add_ps(_mm_mul_ps(vb0_1, vx), vs1_1);
                __m128 vt1 = _mm_sub_ps(_mm_mul_ps(vb1_1, vx), _mm_mul_ps(va1_1, vy));
                vs1_1 = _mm_add_ps(vt1, vs2_1);
                vs2_1 = _mm_sub_ps(_mm_mul_ps(vb2_1, vx), _mm_mul_ps(va2_1, vy));
                vsq_1 = _mm_add_ps(vsq_1, _mm_mul_ps(vy, vy));
            }

            /* Group 2: Bands 8..11 (10 & 11 are zero-padded) */
            {
                __m128 vy = _mm_add_ps(_mm_mul_ps(vb0_2, vx), vs1_2);
                __m128 vt1 = _mm_sub_ps(_mm_mul_ps(vb1_2, vx), _mm_mul_ps(va1_2, vy));
                vs1_2 = _mm_add_ps(vt1, vs2_2);
                vs2_2 = _mm_sub_ps(_mm_mul_ps(vb2_2, vx), _mm_mul_ps(va2_2, vy));
                vsq_2 = _mm_add_ps(vsq_2, _mm_mul_ps(vy, vy));
            }
#elif defined(MAP_HAS_NEON)
            float32x4_t vx = vdupq_n_f32(x);

            /* Group 0: Bands 0..3 */
            {
                float32x4_t vy = vmlaq_f32(vs1_0, vb0_0, vx);
                vs1_0 = vmlsq_f32(vmlaq_f32(vs2_0, vb1_0, vx), va1_0, vy);
                vs2_0 = vmlsq_f32(vmulq_f32(vb2_0, vx), va2_0, vy);
                vsq_0 = vmlaq_f32(vsq_0, vy, vy);
            }

            /* Group 1: Bands 4..7 */
            {
                float32x4_t vy = vmlaq_f32(vs1_1, vb0_1, vx);
                vs1_1 = vmlsq_f32(vmlaq_f32(vs2_1, vb1_1, vx), va1_1, vy);
                vs2_1 = vmlsq_f32(vmulq_f32(vb2_1, vx), va2_1, vy);
                vsq_1 = vmlaq_f32(vsq_1, vy, vy);
            }

            /* Group 2: Bands 8..11 (10 & 11 are zero-padded) */
            {
                float32x4_t vy = vmlaq_f32(vs1_2, vb0_2, vx);
                vs1_2 = vmlsq_f32(vmlaq_f32(vs2_2, vb1_2, vx), va1_2, vy);
                vs2_2 = vmlsq_f32(vmulq_f32(vb2_2, vx), va2_2, vy);
                vsq_2 = vmlaq_f32(vsq_2, vy, vy);
            }
#else
            for (b = 0; b < 10; b++)
            {
                float y = b0[b] * x + s1[b];
                s1[b] = b1[b] * x - a1[b] * y + s2[b];
                s2[b] = b2[b] * x - a2[b] * y;
                band_sq[b] += y * y;
            }
#endif
        }

#if defined(MAP_HAS_SSE)
        _mm_store_ps(&s1[0], vs1_0);
        _mm_store_ps(&s2[0], vs2_0);
        _mm_store_ps(&band_sq[0], vsq_0);

        _mm_store_ps(&s1[4], vs1_1);
        _mm_store_ps(&s2[4], vs2_1);
        _mm_store_ps(&band_sq[4], vsq_1);

        _mm_store_ps(&s1[8], vs1_2);
        _mm_store_ps(&s2[8], vs2_2);
        _mm_store_ps(&band_sq[8], vsq_2);
#elif defined(MAP_HAS_NEON)
        vst1q_f32(&s1[0], vs1_0);
        vst1q_f32(&s2[0], vs2_0);
        vst1q_f32(&band_sq[0], vsq_0);

        vst1q_f32(&s1[4], vs1_1);
        vst1q_f32(&s2[4], vs2_1);
        vst1q_f32(&band_sq[4], vsq_1);

        vst1q_f32(&s1[8], vs1_2);
        vst1q_f32(&s2[8], vs2_2);
        vst1q_f32(&band_sq[8], vsq_2);
#endif

        /* Block-level anti-denormal flush and write back filter states */
        for (b = 0; b < 10; b++)
        {
            if (fabsf(s1[b]) < 1e-20f) s1[b] = 0.0f;
            if (fabsf(s2[b]) < 1e-20f) s2[b] = 0.0f;
            pEq->vis_bpf[b].s1 = s1[b];
            pEq->vis_bpf[b].s2 = s2[b];
        }

        float invFrames = (totalFrames > 0) ? (1.0f / (float)totalFrames) : 0.0f;
        float invEval = (eval_count > 0) ? (1.0f / (float)eval_count) : 0.0f;
        float rms_l = sqrtf(sum_sq_l * invFrames);
        float rms_r = sqrtf(sum_sq_r * invFrames);
        float global_rms = 0.5f * (rms_l + rms_r);
        float global_peak = (peak_l > peak_r) ? peak_l : peak_r;

        /* Sample-rate and buffer-duration adaptive decay: 100ms standard release envelope */
        float dt = (totalFrames > 0 && pEq->sampleRate > 0) ? ((float)totalFrames / (float)pEq->sampleRate) : 0.0213f;
        float decay = expf(-dt / 0.100f);
        if (decay < 0.1f) decay = 0.1f;
        if (decay > 0.99f) decay = 0.99f;
        static const float band_weights[10] = {
            1.4f, 1.6f, 1.8f, 2.0f, 2.2f, 2.4f, 2.8f, 3.2f, 3.6f, 4.0f
        };

        /* Stage visualizer math into stack buffer outside Seqlock */
        miniaudio_player_visualizer_data_t local_vis = pEq->visualizer_data;

        for (b = 0; b < 10; b++)
        {
            float b_rms = sqrtf(band_sq[b] * invEval) * band_weights[b];
            if (b_rms > 1.0f) b_rms = 1.0f;

            if (b_rms >= local_vis.bands[b])
                local_vis.bands[b] = b_rms;
            else
                local_vis.bands[b] = local_vis.bands[b] * decay + b_rms * (1.0f - decay);
        }

        if (global_rms >= local_vis.rms)
            local_vis.rms = (global_rms > 1.0f) ? 1.0f : global_rms;
        else
            local_vis.rms = local_vis.rms * decay;

        if (global_peak >= local_vis.peak)
            local_vis.peak = (global_peak > 1.0f) ? 1.0f : global_peak;
        else
            local_vis.peak = local_vis.peak * decay;

        if (rms_l >= local_vis.left)
            local_vis.left = (rms_l > 1.0f) ? 1.0f : rms_l;
        else
            local_vis.left = local_vis.left * decay;

        if (rms_r >= local_vis.right)
            local_vis.right = (rms_r > 1.0f) ? 1.0f : rms_r;
        else
            local_vis.right = local_vis.right * decay;

        /* Ultra-fast atomic commit: single 56-byte struct assignment */
        map_seqlock_write_begin(&pEq->vis_seqlock);
        pEq->visualizer_data = local_vis;
        map_seqlock_write_end(&pEq->vis_seqlock);
    }

    /* 7. Master Volume Fader (Post-visualizer, with sample-rate adapted smoothing) */
    {
        ma_uint32 totalSamples = frameCount * pEq->channels;
        float *pSamples = ppFramesOut[0];
        float cur_vol = pEq->current_volume;
        float tgt_vol = pEq->target_volume;
        float sf = pEq->smooth_factor;

        float diff = fabsf(tgt_vol - cur_vol);
        if (diff < 1e-6f)
        {
            /* Steady-state: Vectorize directly at memory bandwidth speed */
            ma_uint32 s = 0;
#if defined(MAP_HAS_SSE)
            __m128 v_vol = _mm_set1_ps(tgt_vol);
            for (; s + 3 < totalSamples; s += 4)
            {
                __m128 v_s = _mm_loadu_ps(&pSamples[s]);
                _mm_storeu_ps(&pSamples[s], _mm_mul_ps(v_s, v_vol));
            }
#elif defined(MAP_HAS_NEON)
            float32x4_t v_vol = vdupq_n_f32(tgt_vol);
            for (; s + 3 < totalSamples; s += 4)
            {
                float32x4_t v_s = vld1q_f32(&pSamples[s]);
                vst1q_f32(&pSamples[s], vmulq_f32(v_s, v_vol));
            }
#endif
            for (; s < totalSamples; s++) pSamples[s] *= tgt_vol;
            pEq->current_volume = tgt_vol;
        }
        else
        {
            /* Dynamic ramp state: scalar recurrence */
            ma_uint32 s;
            for (s = 0; s < totalSamples; s++)
            {
                cur_vol += (tgt_vol - cur_vol) * sf;
                pSamples[s] *= cur_vol;
            }
            if (fabsf(cur_vol) < 1e-15f) cur_vol = 0.0f;
            pEq->current_volume = cur_vol;
        }
    }

    /* 8. True-Peak Soft-Knee Limiter (DAC Protector at 0.95f threshold with branch optimization) */
    if (pEq->limiter_enabled)
    {
        ma_uint32 totalSamples = frameCount * pEq->channels;
        float *pSamples = ppFramesOut[0];
        ma_uint32 s = 0;
        const float threshold = 0.95f;
        const float range = 0.05f;
        const float invRange = 20.0f;

#if defined(MAP_HAS_SSE)
        __m128 v_thresh    = _mm_set1_ps(threshold);
        __m128 v_range     = _mm_set1_ps(range);
        __m128 v_inv_range = _mm_set1_ps(invRange);
        __m128 v_one       = _mm_set1_ps(1.0f);
        __m128 v_sign_mask = _mm_castsi128_ps(_mm_set1_epi32(0x7fffffff));
        __m128 v_neg_mask  = _mm_castsi128_ps(_mm_set1_epi32(0x80000000));

        for (; s + 3 < totalSamples; s += 4)
        {
            __m128 vx = _mm_loadu_ps(&pSamples[s]);
            __m128 v_abs = _mm_and_ps(vx, v_sign_mask);
            __m128 v_mask = _mm_cmpgt_ps(v_abs, v_thresh);

            if (_mm_movemask_ps(v_mask) != 0)
            {
                __m128 v_excess = _mm_mul_ps(_mm_sub_ps(v_abs, v_thresh), v_inv_range);
                __m128 v_sat = _mm_add_ps(v_thresh, _mm_mul_ps(v_range, _mm_div_ps(v_excess, _mm_add_ps(v_one, v_excess))));
                __m128 v_sign = _mm_and_ps(vx, v_neg_mask);
                v_sat = _mm_or_ps(v_sat, v_sign);
#if defined(__SSE4_1__)
                vx = _mm_blendv_ps(vx, v_sat, v_mask);
#else
                vx = _mm_or_ps(_mm_and_ps(v_mask, v_sat), _mm_andnot_ps(v_mask, vx));
#endif
                _mm_storeu_ps(&pSamples[s], vx);
            }
        }
#elif defined(MAP_HAS_NEON)
        float32x4_t v_thresh    = vdupq_n_f32(threshold);
        float32x4_t v_range     = vdupq_n_f32(range);
        float32x4_t v_inv_range = vdupq_n_f32(invRange);
        float32x4_t v_one       = vdupq_n_f32(1.0f);

        for (; s + 3 < totalSamples; s += 4)
        {
            float32x4_t vx = vld1q_f32(&pSamples[s]);
            float32x4_t v_abs = vabsq_f32(vx);
            uint32x4_t v_mask = vcgtq_f32(v_abs, v_thresh);

            /* Evaluate if any lane clipped */
#if defined(__aarch64__)
            if (vmaxvq_u32(v_mask) != 0)
#else
            uint32x2_t v_max2 = vpmax_u32(vget_low_u32(v_mask), vget_high_u32(v_mask));
            v_max2 = vpmax_u32(v_max2, v_max2);
            if (vget_lane_u32(v_max2, 0) != 0)
#endif
            {
                float32x4_t v_excess = vmulq_f32(vsubq_f32(v_abs, v_thresh), v_inv_range);
                float32x4_t v_den = vaddq_f32(v_one, v_excess);
                float32x4_t v_rec = vrecpeq_f32(v_den);
                v_rec = vmulq_f32(vrecpsq_f32(v_den, v_rec), v_rec); /* 1 Newton-Raphson step */
                float32x4_t v_sat = vmlaq_f32(v_thresh, v_range, vmulq_f32(v_excess, v_rec));

                /* Re-apply sign */
                uint32x4_t sign_bit = vandq_u32(vreinterpretq_u32_f32(vx), vdupq_n_u32(0x80000000));
                v_sat = vreinterpretq_f32_u32(vorrq_u32(vreinterpretq_u32_f32(v_sat), sign_bit));

                vx = vbslq_f32(v_mask, v_sat, vx);
                vst1q_f32(&pSamples[s], vx);
            }
        }
#endif
        /* Scalar tail */
        for (; s < totalSamples; s++)
        {
            float x = pSamples[s];
            float abs_x = fabsf(x);
            if (abs_x > threshold)
            {
                float excess = (abs_x - threshold) * invRange;
                float sat = threshold + range * (excess / (1.0f + excess));
                pSamples[s] = (x > 0.0f) ? sat : -sat;
            }
        }
    }

    ma_spinlock_unlock(&pEq->lock);
}

static ma_node_vtable g_ma_equalizer_node_vtable = {
    ma_equalizer_node_process_pcm_frames,
    NULL,
    1, /* 1 input bus */
    1, /* 1 output bus */
    0
};

ma_result ma_equalizer_node_init(
    ma_node_graph *pNodeGraph,
    ma_uint32 channels,
    ma_uint32 sampleRate,
    ma_equalizer_node *pNode)
{
    ma_result result;
    ma_node_config baseConfig;
    int i;

    if (pNode == NULL || pNodeGraph == NULL || channels == 0 || sampleRate == 0)
    {
        return MA_INVALID_ARGS;
    }

    memset(pNode, 0, sizeof(*pNode));
    pNode->channels = channels;
    pNode->sampleRate = sampleRate;
    pNode->lock = 0;

    /* Band 0: 31 Hz low-shelf */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], sampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, channels, sampleRate, 0.0, MAP_EQ_SHELF_SLOPE, f);
        result = ma_loshelf2_init(&config, NULL, &pNode->loshelf);
        if (result != MA_SUCCESS)
            return result;
    }

    /* Bands 1..8: Peaking EQ filters */
    for (i = 0; i < 8; i++)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[i + 1], sampleRate);
        ma_peak2_config config = ma_peak2_config_init(
            ma_format_f32, channels, sampleRate, 0.0, MAP_EQ_Q, f);
        result = ma_peak2_init(&config, NULL, &pNode->peaks[i]);
        if (result != MA_SUCCESS)
        {
            int j;
            ma_loshelf2_uninit(&pNode->loshelf, NULL);
            for (j = 0; j < i; j++)
            {
                ma_peak2_uninit(&pNode->peaks[j], NULL);
            }
            return result;
        }
    }

    /* Band 9: 16 kHz high-shelf */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], sampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, channels, sampleRate, 0.0, MAP_EQ_SHELF_SLOPE, f);
        result = ma_hishelf2_init(&config, NULL, &pNode->hishelf);
        if (result != MA_SUCCESS)
        {
            int j;
            ma_loshelf2_uninit(&pNode->loshelf, NULL);
            for (j = 0; j < 8; j++)
            {
                ma_peak2_uninit(&pNode->peaks[j], NULL);
            }
            return result;
        }
    }

    /* Visualizer BPF filters for the 10 frequency bands */
    pNode->visualizer_enabled = 0;
    memset(&pNode->visualizer_data, 0, sizeof(pNode->visualizer_data));
    for (i = 0; i < 10; i++)
    {
        map_biquad_bpf_init(&pNode->vis_bpf[i], g_map_eq_frequencies[i], (double)sampleRate, 1.2);
    }

    /* Base node setup */
    baseConfig = ma_node_config_init();
    baseConfig.vtable = &g_ma_equalizer_node_vtable;
    baseConfig.pInputChannels = &pNode->channels;
    baseConfig.pOutputChannels = &pNode->channels;

    result = ma_node_init(pNodeGraph, &baseConfig, NULL, &pNode->baseNode);
    if (result != MA_SUCCESS)
    {
        int j;
        ma_loshelf2_uninit(&pNode->loshelf, NULL);
        for (j = 0; j < 8; j++)
        {
            ma_peak2_uninit(&pNode->peaks[j], NULL);
        }
        ma_hishelf2_uninit(&pNode->hishelf, NULL);
        return result;
    }

    pNode->preamp_db = 0.0f;
    pNode->current_preamp_linear = 1.0f;
    pNode->target_preamp_linear = 1.0f;
    pNode->balance = 0.0f;
    pNode->current_balance = 0.0f;
    pNode->target_gl = 1.0f;
    pNode->target_gr = 1.0f;
    pNode->current_gl = 1.0f;
    pNode->current_gr = 1.0f;
    pNode->mono_enabled = 0;
    pNode->crossfeed_mode = MAP_CROSSFEED_OFF;
    map_bs2b_init(&pNode->bs2b, sampleRate, MAP_BS2B_DEFAULT_CLEVEL);
    pNode->spatializer_enabled = 0;
    pNode->spatializer_width = 1.0f;
    pNode->reverb_enabled = 0;
    map_reverb_init(&pNode->reverb, sampleRate);
    pNode->current_volume = 1.0f;
    pNode->target_volume = 1.0f;
    pNode->smooth_factor = 1.0f - expf(-1.0f / ((float)sampleRate * 0.005f));
    if (pNode->smooth_factor <= 0.0f || pNode->smooth_factor > 0.05f)
    {
        pNode->smooth_factor = 0.005f;
    }
    map_seqlock_init(&pNode->vis_seqlock);
    memset(pNode->band_gains, 0, sizeof(pNode->band_gains));
    pNode->limiter_enabled = 0;

    return MA_SUCCESS;
}

void ma_equalizer_node_uninit(ma_equalizer_node *pNode)
{
    int i;
    if (pNode == NULL)
        return;
    ma_node_uninit(&pNode->baseNode, NULL);
    ma_loshelf2_uninit(&pNode->loshelf, NULL);
    for (i = 0; i < 8; i++)
    {
        ma_peak2_uninit(&pNode->peaks[i], NULL);
    }
    ma_hishelf2_uninit(&pNode->hishelf, NULL);
    map_reverb_uninit(&pNode->reverb);
}

ma_result ma_equalizer_node_set_band(
    ma_equalizer_node *pEq,
    ma_uint32 bandIndex,
    float gainDB)
{
    float clampedGain;
    if (pEq == NULL || bandIndex >= MAP_EQ_BAND_COUNT)
        return MA_INVALID_ARGS;
    clampedGain = map_clamp_gain_db(gainDB);

    ma_spinlock_lock(&pEq->lock);

    /* Skip redundant filter reinitialization if gain is unchanged */
    if (fabsf(clampedGain - pEq->band_gains[bandIndex]) < 0.0001f)
    {
        ma_spinlock_unlock(&pEq->lock);
        return MA_SUCCESS;
    }
    pEq->band_gains[bandIndex] = clampedGain;

    if (bandIndex == 0)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], pEq->sampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)clampedGain, MAP_EQ_SHELF_SLOPE, f);
        ma_loshelf2_reinit(&config, &pEq->loshelf);
    }
    else if (bandIndex >= 1 && bandIndex <= 8)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[bandIndex], pEq->sampleRate);
        ma_peak2_config config = ma_peak2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)clampedGain, MAP_EQ_Q, f);
        ma_peak2_reinit(&config, &pEq->peaks[bandIndex - 1]);
    }
    else if (bandIndex == 9)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], pEq->sampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)clampedGain, MAP_EQ_SHELF_SLOPE, f);
        ma_hishelf2_reinit(&config, &pEq->hishelf);
    }

    ma_spinlock_unlock(&pEq->lock);
    return MA_SUCCESS;
}

ma_result ma_equalizer_node_set_all(
    ma_equalizer_node *pEq,
    const miniaudio_player_equalizer_params_t *pParams)
{
    float gains[10];
    int i;
    ma_bool32 all_same = MA_TRUE;

    if (pEq == NULL || pParams == NULL)
        return MA_INVALID_ARGS;

    gains[0] = map_clamp_gain_db(pParams->hz31);
    gains[1] = map_clamp_gain_db(pParams->hz63);
    gains[2] = map_clamp_gain_db(pParams->hz125);
    gains[3] = map_clamp_gain_db(pParams->hz250);
    gains[4] = map_clamp_gain_db(pParams->hz500);
    gains[5] = map_clamp_gain_db(pParams->hz1k);
    gains[6] = map_clamp_gain_db(pParams->hz2k);
    gains[7] = map_clamp_gain_db(pParams->hz4k);
    gains[8] = map_clamp_gain_db(pParams->hz8k);
    gains[9] = map_clamp_gain_db(pParams->hz16k);

    ma_spinlock_lock(&pEq->lock);

    for (i = 0; i < 10; i++)
    {
        if (fabsf(gains[i] - pEq->band_gains[i]) >= 0.0001f)
        {
            all_same = MA_FALSE;
            break;
        }
    }
    if (all_same)
    {
        ma_spinlock_unlock(&pEq->lock);
        return MA_SUCCESS;
    }

    /* Band 0: 31 Hz low-shelf */
    if (fabsf(gains[0] - pEq->band_gains[0]) >= 0.0001f)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], pEq->sampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)gains[0], MAP_EQ_SHELF_SLOPE, f);
        ma_loshelf2_reinit(&config, &pEq->loshelf);
        pEq->band_gains[0] = gains[0];
    }

    /* Bands 1..8: Peaking EQ filters */
    for (i = 0; i < 8; i++)
    {
        if (fabsf(gains[i + 1] - pEq->band_gains[i + 1]) >= 0.0001f)
        {
            double f = map_clamp_frequency(g_map_eq_frequencies[i + 1], pEq->sampleRate);
            ma_peak2_config config = ma_peak2_config_init(
                ma_format_f32, pEq->channels, pEq->sampleRate, (double)gains[i + 1], MAP_EQ_Q, f);
            ma_peak2_reinit(&config, &pEq->peaks[i]);
            pEq->band_gains[i + 1] = gains[i + 1];
        }
    }

    /* Band 9: 16 kHz high-shelf */
    if (fabsf(gains[9] - pEq->band_gains[9]) >= 0.0001f)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], pEq->sampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)gains[9], MAP_EQ_SHELF_SLOPE, f);
        ma_hishelf2_reinit(&config, &pEq->hishelf);
        pEq->band_gains[9] = gains[9];
    }

    ma_spinlock_unlock(&pEq->lock);
    return MA_SUCCESS;
}

ma_result ma_equalizer_node_set_sample_rate(ma_equalizer_node *pEq, ma_uint32 newSampleRate)
{
    ma_uint32 oldRate;
    float ratio;
    ma_uint32 ch, c;
    int i;

    if (pEq == NULL || newSampleRate == 0)
        return MA_INVALID_ARGS;

    ma_spinlock_lock(&pEq->lock);

    oldRate = pEq->sampleRate;
    if (oldRate == newSampleRate)
    {
        ma_spinlock_unlock(&pEq->lock);
        return MA_SUCCESS;
    }

    ratio = (float)oldRate / (float)newSampleRate;
    if (ratio < 0.1f) ratio = 0.1f;
    if (ratio > 10.0f) ratio = 10.0f;

    ch = pEq->channels;

    /* 1. Scale delay registers s1, s2 across all biquad filters to preserve state energy (NP3-04) */
    for (c = 0; c < ch; c++)
    {
        pEq->loshelf.bq.pR1[c].f32 *= ratio;
        pEq->loshelf.bq.pR2[c].f32 *= ratio;
        for (i = 0; i < 8; i++)
        {
            pEq->peaks[i].bq.pR1[c].f32 *= ratio;
            pEq->peaks[i].bq.pR2[c].f32 *= ratio;
        }
        pEq->hishelf.bq.pR1[c].f32 *= ratio;
        pEq->hishelf.bq.pR2[c].f32 *= ratio;
    }

    /* 2. Recompute filter coefficients with newSampleRate while preserving gains */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], newSampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, ch, newSampleRate, (double)pEq->band_gains[0], MAP_EQ_SHELF_SLOPE, f);
        ma_loshelf2_reinit(&config, &pEq->loshelf);
    }

    for (i = 0; i < 8; i++)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[i + 1], newSampleRate);
        ma_peak2_config config = ma_peak2_config_init(
            ma_format_f32, ch, newSampleRate, (double)pEq->band_gains[i + 1], MAP_EQ_Q, f);
        ma_peak2_reinit(&config, &pEq->peaks[i]);
    }

    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], newSampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, ch, newSampleRate, (double)pEq->band_gains[9], MAP_EQ_SHELF_SLOPE, f);
        ma_hishelf2_reinit(&config, &pEq->hishelf);
    }

    /* 3. Scale visualizer BPF states and re-init */
    for (i = 0; i < 10; i++)
    {
        float s1 = pEq->vis_bpf[i].s1 * ratio;
        float s2 = pEq->vis_bpf[i].s2 * ratio;
        map_biquad_bpf_init(&pEq->vis_bpf[i], g_map_eq_frequencies[i], (double)newSampleRate, 1.2);
        pEq->vis_bpf[i].s1 = s1;
        pEq->vis_bpf[i].s2 = s2;
    }

    /* 4. Update bs2b crossfeed and smooth factors */
    if (pEq->crossfeed_mode != MAP_CROSSFEED_OFF)
    {
        map_bs2b_init(&pEq->bs2b, newSampleRate,
                      (pEq->crossfeed_mode == MAP_CROSSFEED_CHU_MOY) ? MAP_BS2B_CMOY_CLEVEL : MAP_BS2B_DEFAULT_CLEVEL);
    }

    pEq->smooth_factor = 1.0f - expf(-1.0f / ((float)newSampleRate * 0.005f));
    if (pEq->smooth_factor <= 0.0f || pEq->smooth_factor > 0.05f)
    {
        pEq->smooth_factor = 0.005f;
    }

    /* 5. Update reverb sample rate (re-scale delay lengths with zero heap allocation) */
    map_reverb_set_sample_rate(&pEq->reverb, newSampleRate);

    pEq->sampleRate = newSampleRate;

    ma_spinlock_unlock(&pEq->lock);
    return MA_SUCCESS;
}
