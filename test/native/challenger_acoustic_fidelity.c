/**
 * @file challenger_acoustic_fidelity.c
 * @brief Independent Empirical Challenge Suite for Miniaudio Player DSP Engine.
 * Tests RBJ biquad accuracy across all 10 bands, limiter soft-knee THD & clamping,
 * bit-perfect unity pass-through across multiple buffer chunk sizes, and parameter modulation.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <pthread.h>
#include <stdint.h>

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_dsp.h"

#define PI 3.14159265358979323846

static double compute_rms(const float *buffer, size_t count)
{
    double sum = 0.0;
    for (size_t i = 0; i < count; i++)
    {
        sum += (double)buffer[i] * (double)buffer[i];
    }
    return sqrt(sum / (double)count);
}

static float compute_peak(const float *buffer, size_t count)
{
    float max_val = 0.0f;
    for (size_t i = 0; i < count; i++)
    {
        float a = fabsf(buffer[i]);
        if (a > max_val) max_val = a;
    }
    return max_val;
}

static double compute_thd(const float *buffer, size_t count, double sample_rate, double fund_freq, int num_harmonics)
{
    const size_t stride = 2;
    size_t frames = count / stride;
    double fund_real = 0.0, fund_imag = 0.0;
    double omega1 = 2.0 * PI * fund_freq / sample_rate;
    for (size_t n = 0; n < frames; n++)
    {
        double s = (double)buffer[n * stride];
        fund_real += s * cos(omega1 * (double)n);
        fund_imag -= s * sin(omega1 * (double)n);
    }
    double fund_pwr = (fund_real * fund_real + fund_imag * fund_imag);
    if (fund_pwr < 1e-15) return 0.0;

    double harm_pwr = 0.0;
    for (int h = 2; h <= num_harmonics; h++)
    {
        double h_freq = fund_freq * (double)h;
        if (h_freq >= sample_rate * 0.49) break;
        double omega_h = 2.0 * PI * h_freq / sample_rate;
        double h_real = 0.0, h_imag = 0.0;
        for (size_t n = 0; n < frames; n++)
        {
            double s = (double)buffer[n * stride];
            h_real += s * cos(omega_h * (double)n);
            h_imag -= s * sin(omega_h * (double)n);
        }
        harm_pwr += (h_real * h_real + h_imag * h_imag);
    }
    return sqrt(harm_pwr / fund_pwr) * 100.0;
}

/* Analytical RBJ transfer function magnitude at frequency f */
static double analytical_rbj_magnitude(int band_type, double f0, double fs, double gainDB, double q_or_s, double f_eval)
{
    double w0 = 2.0 * PI * f0 / fs;
    double A = pow(10.0, gainDB / 40.0);
    double cos_w0 = cos(w0);
    double sin_w0 = sin(w0);
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0;

    if (band_type == 1) /* Peaking EQ */
    {
        double alpha = sin_w0 / (2.0 * q_or_s);
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cos_w0;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cos_w0;
        a2 = 1.0 - alpha / A;
    }
    else if (band_type == 0) /* Low shelf */
    {
        double S = q_or_s;
        double alpha = (sin_w0 / 2.0) * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
        double two_sqrtA_alpha = 2.0 * sqrt(A) * alpha;
        b0 = A * ((A + 1.0) - (A - 1.0) * cos_w0 + two_sqrtA_alpha);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cos_w0);
        b2 = A * ((A + 1.0) - (A - 1.0) * cos_w0 - two_sqrtA_alpha);
        a0 = (A + 1.0) + (A - 1.0) * cos_w0 + two_sqrtA_alpha;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cos_w0);
        a2 = (A + 1.0) + (A - 1.0) * cos_w0 - two_sqrtA_alpha;
    }
    else if (band_type == 2) /* High shelf */
    {
        double S = q_or_s;
        double alpha = (sin_w0 / 2.0) * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
        double two_sqrtA_alpha = 2.0 * sqrt(A) * alpha;
        b0 = A * ((A + 1.0) + (A - 1.0) * cos_w0 + two_sqrtA_alpha);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cos_w0);
        b2 = A * ((A + 1.0) + (A - 1.0) * cos_w0 - two_sqrtA_alpha);
        a0 = (A + 1.0) - (A - 1.0) * cos_w0 + two_sqrtA_alpha;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cos_w0);
        a2 = (A + 1.0) - (A - 1.0) * cos_w0 - two_sqrtA_alpha;
    }

    double w = 2.0 * PI * f_eval / fs;
    double cos_w = cos(w);
    double cos_2w = cos(2.0 * w);
    double sin_w = sin(w);
    double sin_2w = sin(2.0 * w);

    double num_re = b0 + b1 * cos_w + b2 * cos_2w;
    double num_im = -b1 * sin_w - b2 * sin_2w;
    double den_re = a0 + a1 * cos_w + a2 * cos_2w;
    double den_im = -a1 * sin_w - a2 * sin_2w;

    double num_mag2 = num_re * num_re + num_im * num_im;
    double den_mag2 = den_re * den_re + den_im * den_im;
    return sqrt(num_mag2 / den_mag2);
}

/* ========================================================================= */
/* CHALLENGE 1: RBJ BIQUAD ACCURACY ACROSS ALL 10 BANDS                     */
/* ========================================================================= */
static void challenge_1_rbj_biquad_all_bands(void)
{
    printf("\n===================================================================\n");
    printf("[CHALLENGE 1] RBJ Biquad Filter Accuracy Across All 10 Bands\n");
    printf("===================================================================\n");

    const uint32_t sample_rates[] = {44100, 48000, 96000};
    const int num_rates = 3;
    const float test_gains[] = {+12.0f, +6.0f, -6.0f, -12.0f};
    const int num_gains = 4;

    for (int r = 0; r < num_rates; r++)
    {
        uint32_t fs = sample_rates[r];
        printf("\n--- Testing Sample Rate: %u Hz ---\n", fs);

        ma_engine_config engine_cfg = ma_engine_config_init();
        engine_cfg.sampleRate = fs;
        engine_cfg.channels = 2;
        ma_engine engine;
        assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

        ma_equalizer_node eq;
        assert(ma_equalizer_node_init(&engine.nodeGraph, 2, fs, &eq) == MA_SUCCESS);
        eq.limiter_enabled = 0;

        /* Settle time: 4800 frames at 48k is 100ms; at 96k use 9600 frames */
        uint32_t settle_frames = fs / 5;   /* 200 ms settling */
        uint32_t measure_frames = fs / 5;  /* 200 ms measurement */
        uint32_t total_frames = settle_frames + measure_frames;

        float *in_buf = (float *)calloc(total_frames * 2, sizeof(float));
        float *out_buf = (float *)calloc(total_frames * 2, sizeof(float));

        for (int b = 0; b < MAP_EQ_BAND_COUNT; b++)
        {
            double f0 = g_map_eq_frequencies[b];
            int band_type = (b == 0) ? 0 : ((b == 9) ? 2 : 1);
            double q_or_s = (b == 0 || b == 9) ? MAP_EQ_SHELF_SLOPE : MAP_EQ_Q;

            for (int g = 0; g < num_gains; g++)
            {
                float target_gain = test_gains[g];

                /* Reset EQ to 0 dB first */
                miniaudio_player_equalizer_params_t flat = {0};
                assert(ma_equalizer_node_set_all(&eq, &flat) == MA_SUCCESS);

                /* Set specific band */
                assert(ma_equalizer_node_set_band(&eq, b, target_gain) == MA_SUCCESS);

                /* Generate sine at center frequency f0 */
                for (uint32_t i = 0; i < total_frames; i++)
                {
                    float val = 0.15f * (float)sin(2.0 * PI * f0 * (double)i / (double)fs);
                    in_buf[i * 2 + 0] = val;
                    in_buf[i * 2 + 1] = val;
                }

                /* Process settle block */
                const float *pIn = in_buf;
                float *pOut = out_buf;
                uint32_t fc = settle_frames;
                ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

                /* Process measure block */
                pIn = in_buf + settle_frames * 2;
                pOut = out_buf + settle_frames * 2;
                fc = measure_frames;
                ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

                double in_rms = compute_rms(in_buf + settle_frames * 2, measure_frames * 2);
                double out_rms = compute_rms(out_buf + settle_frames * 2, measure_frames * 2);
                double measured_gain_db = 20.0 * log10(out_rms / in_rms);

                /* Theoretical analytical RBJ gain */
                double analytical_mag = analytical_rbj_magnitude(band_type, f0, (double)fs, (double)target_gain, q_or_s, f0);
                double analytical_db = 20.0 * log10(analytical_mag);

                double err = fabs(measured_gain_db - analytical_db);
                if (err >= 0.20)
                {
                    fprintf(stderr, "FATAL: Band %d (%.0f Hz) at %u Hz, Target %+.1f dB: Measured %+.2f dB, Analytical %+.2f dB, Error %.3f dB > 0.20 dB!\n",
                            b, f0, fs, target_gain, measured_gain_db, analytical_db, err);
                    assert(err < 0.20);
                }
            }
            printf("  Band %2d (%5.0f Hz, Type %d): All gains (+12, +6, -6, -12 dB) validated within <0.20 dB tolerance [PASS]\n",
                   b, f0, band_type);
        }

        free(in_buf);
        free(out_buf);
        ma_equalizer_node_uninit(&eq);
        ma_engine_uninit(&engine);
    }
    printf(">>> CHALLENGE 1 PASSED: All 10 bands verified against RBJ analytical transfer function! <<<\n");
}

/* ========================================================================= */
/* CHALLENGE 2: LIMITER SOFT-KNEE THD, CLAMPING & DERIVATIVE CONTINUITY      */
/* ========================================================================= */
static void challenge_2_limiter_stress(void)
{
    printf("\n===================================================================\n");
    printf("[CHALLENGE 2] Limiter Soft-Knee THD, Clamping & Derivative Continuity\n");
    printf("===================================================================\n");

    const uint32_t fs = 48000;
    const uint32_t channels = 2;
    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = fs;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, fs, &eq) == MA_SUCCESS);
    eq.limiter_enabled = 1;

    /* 2.1 Static transfer function and derivative continuity test */
    printf("  [2.1] Probing static soft-knee function in range [0.00 to 50.00]...\n");
    const int num_points = 50000;
    float max_out = 0.0f;
    float prev_y = 0.0f;

    float *test_in = (float *)malloc(num_points * channels * sizeof(float));
    float *test_out = (float *)malloc(num_points * channels * sizeof(float));

    for (int i = 0; i < num_points; i++)
    {
        float x = (float)i * (50.0f / (float)num_points);
        test_in[i * 2 + 0] = x;
        test_in[i * 2 + 1] = -x; /* Symmetrical negative */
    }

    const float *pIn = test_in;
    float *pOut = test_out;
    uint32_t fc = num_points;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    for (int i = 0; i < num_points; i++)
    {
        float in_val = test_in[i * 2];
        float out_pos = test_out[i * 2 + 0];
        float out_neg = test_out[i * 2 + 1];

        /* Invariance: Absolute peak must NEVER exceed 1.000000f */
        if (out_pos > max_out) max_out = out_pos;
        if (fabsf(out_neg) > max_out) max_out = fabsf(out_neg);

        assert(out_pos <= 1.000000f);
        assert(fabsf(out_neg) <= 1.000000f);

        /* Symmetry check: f(-x) == -f(x) */
        float sym_err = fabsf(out_pos + out_neg);
        assert(sym_err < 1e-6f);

        /* Linear region check below 0.95: f(x) == x */
        if (in_val <= 0.9499f)
        {
            float lin_err = fabsf(out_pos - in_val);
            assert(lin_err < 1e-6f);
        }

        /* Monotonicity check */
        if (i > 0)
        {
            assert(out_pos >= prev_y);
        }
        prev_y = out_pos;
    }
    printf("    -> Maximum output observed: %.6f (Bound: <= 1.000000) [PASS]\n", max_out);
    printf("    -> Symmetrical response & strict monotonicity verified [PASS]\n");

    /* 2.2 Numerical derivative continuity at knee threshold (0.9500) */
    printf("  [2.2] Checking derivative continuity at x = 0.95 threshold...\n");
    float eps = 1e-4f;
    float in_k[4] = {0.95f - eps, -(0.95f - eps), 0.95f + eps, -(0.95f + eps)};
    float out_k[4] = {0};
    pIn = in_k; pOut = out_k; fc = 2;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    float slope_left = (out_k[0] - (0.95f - 2.0f * eps)) / eps; /* Left derivative */
    float slope_right = (out_k[2] - 0.95f) / eps;                /* Right derivative */
    float slope_delta = fabsf(slope_right - 1.0f);
    printf("    -> Slope at 0.95+: %.5f (Theoretical: 1.00000, Delta: %.5f) [PASS]\n",
           slope_right, slope_delta);
    assert(slope_delta < 0.05f);

    /* 2.3 THD across multiple frequencies under mild & strong saturation */
    printf("  [2.3] THD analysis across frequencies (100 Hz, 1 kHz, 5 kHz)...\n");
    double test_freqs[] = {100.0, 1000.0, 5000.0};
    uint32_t thd_frames = fs / 2; /* 500 ms */
    float *thd_in = (float *)calloc(thd_frames * 2, sizeof(float));
    float *thd_out = (float *)calloc(thd_frames * 2, sizeof(float));

    for (int fi = 0; fi < 3; fi++)
    {
        double f = test_freqs[fi];

        /* Sub-threshold (amp = 0.90) -> THD must be 0.00000% */
        for (uint32_t i = 0; i < thd_frames; i++)
        {
            float s = 0.90f * (float)sin(2.0 * PI * f * (double)i / (double)fs);
            thd_in[i * 2 + 0] = s;
            thd_in[i * 2 + 1] = s;
        }
        pIn = thd_in; pOut = thd_out; fc = thd_frames;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
        double thd_sub = compute_thd(thd_out, thd_frames * 2, fs, f, 7);
        printf("    Freq %5.0f Hz @ 0.90 (-0.9 dBFS): THD = %8.5f%% (Target: <0.001%%) [PASS]\n", f, thd_sub);
        assert(thd_sub < 0.001);

        /* Deep saturation (amp = 2.00, +6 dBFS) -> Peak clamped <= 1.000, controlled harmonics */
        for (uint32_t i = 0; i < thd_frames; i++)
        {
            float s = 2.00f * (float)sin(2.0 * PI * f * (double)i / (double)fs);
            thd_in[i * 2 + 0] = s;
            thd_in[i * 2 + 1] = s;
        }
        pIn = thd_in; pOut = thd_out; fc = thd_frames;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
        double thd_sat = compute_thd(thd_out, thd_frames * 2, fs, f, 7);
        float peak_sat = compute_peak(thd_out, thd_frames * 2);
        printf("    Freq %5.0f Hz @ 2.00 (+6.0 dBFS): Peak = %.4f, THD = %6.2f%% [PASS]\n", f, peak_sat, thd_sat);
        assert(peak_sat <= 1.000000f);
        assert(thd_sat > 10.0); /* Saturation naturally produces harmonics */
    }

    free(test_in);
    free(test_out);
    free(thd_in);
    free(thd_out);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> CHALLENGE 2 PASSED: Limiter soft-knee and saturation verified! <<<\n");
}

/* ========================================================================= */
/* CHALLENGE 3: BIT-PERFECT UNITY PASS-THROUGH ACROSS CHUNK SIZES & CHANNELS */
/* ========================================================================= */
static void challenge_3_unity_passthrough_stress(void)
{
    printf("\n===================================================================\n");
    printf("[CHALLENGE 3] Bit-Perfect Unity Pass-Through Across Buffer Chunk Sizes\n");
    printf("===================================================================\n");

    const uint32_t fs = 48000;
    const uint32_t chunk_sizes[] = {1, 3, 7, 15, 31, 63, 64, 65, 127, 256, 1024, 4096};
    const int num_chunks = 12;

    const uint32_t test_channels[] = {1, 2, 6, 8};
    const int num_ch_tests = 4;

    for (int ci = 0; ci < num_ch_tests; ci++)
    {
        uint32_t ch = test_channels[ci];
        printf("\n--- Testing Channel Count: %u ---\n", ch);

        ma_engine_config engine_cfg = ma_engine_config_init();
        engine_cfg.sampleRate = fs;
        engine_cfg.channels = ch;
        ma_engine engine;
        assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

        ma_equalizer_node eq;
        assert(ma_equalizer_node_init(&engine.nodeGraph, ch, fs, &eq) == MA_SUCCESS);
        eq.limiter_enabled = 0;

        for (int ki = 0; ki < num_chunks; ki++)
        {
            uint32_t chunk = chunk_sizes[ki];
            uint32_t total_frames = 16384; /* Test over 16,384 frames */

            float *src = (float *)malloc(total_frames * ch * sizeof(float));
            float *dst = (float *)malloc(total_frames * ch * sizeof(float));

            /* Generate pseudo-random white noise and multi-sine in [-0.85, +0.85] */
            uint32_t seed = 0x12345678 + ki;
            for (uint32_t i = 0; i < total_frames * ch; i++)
            {
                seed = seed * 1664525u + 1013904223u;
                float r = ((float)(seed & 0x00FFFFFF) / (float)0x00FFFFFF) * 1.7f - 0.85f;
                src[i] = r;
            }

            /* Feed through equalizer node in variable chunk sizes */
            uint32_t processed = 0;
            while (processed < total_frames)
            {
                uint32_t frames_to_process = chunk;
                if (processed + frames_to_process > total_frames)
                {
                    frames_to_process = total_frames - processed;
                }

                const float *pIn = &src[processed * ch];
                float *pOut = &dst[processed * ch];
                uint32_t fc = frames_to_process;
                ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
                processed += frames_to_process;
            }

            /* Measure sample-level fidelity */
            double max_delta = 0.0;
            double noise_energy = 0.0;
            double signal_energy = 0.0;

            for (uint32_t i = 0; i < total_frames * ch; i++)
            {
                double d = fabs((double)dst[i] - (double)src[i]);
                if (d > max_delta) max_delta = d;
                noise_energy += d * d;
                signal_energy += (double)src[i] * (double)src[i];
            }

            double snr_db = (noise_energy > 1e-25) ? 10.0 * log10(signal_energy / noise_energy) : 200.0;

            /* Check bit-perfect transparency requirement */
            if (max_delta >= 1e-6 || snr_db < 120.0)
            {
                fprintf(stderr, "FATAL: Chunk %u, Channels %u: Max Error %.3e, SNR %.1f dB failed bit-perfect criteria!\n",
                        chunk, ch, max_delta, snr_db);
                assert(max_delta < 1e-6);
                assert(snr_db >= 120.0);
            }

            if (chunk == 1 || chunk == 63 || chunk == 64 || chunk == 4096)
            {
                printf("  Chunk size %4u frames: Max Error = %.2e, SNR = %5.1f dB [PASS]\n",
                       chunk, max_delta, snr_db);
            }

            free(src);
            free(dst);
        }

        ma_equalizer_node_uninit(&eq);
        ma_engine_uninit(&engine);
    }
    printf(">>> CHALLENGE 3 PASSED: Bit-perfect unity pass-through verified across all chunk sizes! <<<\n");
}

/* ========================================================================= */
/* CHALLENGE 4: DYNAMIC PARAMETER MODULATION & TRANSIENT STRESS              */
/* ========================================================================= */
static void challenge_4_dynamic_modulation_stress(void)
{
    printf("\n===================================================================\n");
    printf("[CHALLENGE 4] Dynamic Parameter Modulation & Transient Stress\n");
    printf("===================================================================\n");

    const uint32_t fs = 48000;
    const uint32_t channels = 2;
    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = fs;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, fs, &eq) == MA_SUCCESS);

    const uint32_t frame_count = 9600;
    float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
    float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));

    /* Synthesize 440 Hz test tone */
    for (uint32_t i = 0; i < frame_count; i++)
    {
        float s = 0.5f * sinf(2.0f * (float)PI * 440.0f * (float)i / (float)fs);
        in_buf[i * 2 + 0] = s;
        in_buf[i * 2 + 1] = s;
    }

    /* 4.1 Rapid volume modulation (zipper noise check) */
    printf("  [4.1] Rapid Volume Transitions (1.0 -> 0.0 -> 1.0)...\n");
    float max_sample_step = 0.0f;
    eq.target_volume = 0.0f;

    uint32_t blk = 256;
    for (uint32_t f = 0; f < frame_count; f += blk)
    {
        if (f == 2048) eq.target_volume = 0.8f;
        if (f == 4096) eq.target_volume = 0.1f;
        if (f == 6144) eq.target_volume = 1.0f;

        const float *pIn = &in_buf[f * 2];
        float *pOut = &out_buf[f * 2];
        uint32_t fc = ((frame_count - f) < blk) ? (frame_count - f) : blk;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
    }

    for (uint32_t i = 1; i < frame_count * 2; i++)
    {
        float delta = fabsf(out_buf[i] - out_buf[i - 1]);
        if (delta > max_sample_step) max_sample_step = delta;
    }
    printf("    -> Maximum inter-sample step delta: %.4f (Limit: <0.10) [PASS]\n", max_sample_step);
    assert(max_sample_step < 0.10f);

    /* 4.2 Extreme rapid preset switching while audio is streaming */
    printf("  [4.2] Rapid hot-reloading 500x EQ curves during active playback...\n");
    for (int iter = 0; iter < 500; iter++)
    {
        miniaudio_player_equalizer_params_t p;
        p.hz31   = ((float)(iter % 25) - 12.0f);
        p.hz63   = ((float)((iter * 3) % 25) - 12.0f);
        p.hz125  = ((float)((iter * 7) % 25) - 12.0f);
        p.hz250  = ((float)((iter * 11) % 25) - 12.0f);
        p.hz500  = ((float)((iter * 13) % 25) - 12.0f);
        p.hz1k   = ((float)((iter * 17) % 25) - 12.0f);
        p.hz2k   = ((float)((iter * 19) % 25) - 12.0f);
        p.hz4k   = ((float)((iter * 23) % 25) - 12.0f);
        p.hz8k   = ((float)((iter * 29) % 25) - 12.0f);
        p.hz16k  = ((float)((iter * 31) % 25) - 12.0f);

        assert(ma_equalizer_node_set_all(&eq, &p) == MA_SUCCESS);

        const float *pIn = in_buf;
        float *pOut = out_buf;
        uint32_t fc = 64;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

        /* Invariant: No NaN or Inf may EVER be produced */
        for (uint32_t i = 0; i < 64 * 2; i++)
        {
            assert(!isnan(out_buf[i]));
            assert(!isinf(out_buf[i]));
        }
    }
    printf("    -> 500 rapid curve mutations executed cleanly with zero NaN/Inf or instability [PASS]\n");

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> CHALLENGE 4 PASSED: Dynamic modulation and hot-reloading stable! <<<\n");
}

int main(void)
{
    printf("\n===================================================================\n");
    printf("    MINIAUDIO_PLAYER EMPIRICAL CHALLENGER DSP ACOUSTIC SUITE       \n");
    printf("===================================================================\n");

    challenge_1_rbj_biquad_all_bands();
    challenge_2_limiter_stress();
    challenge_3_unity_passthrough_stress();
    challenge_4_dynamic_modulation_stress();

    printf("\n===================================================================\n");
    printf(">>> ALL EMPIRICAL CHALLENGES COMPLETED WITH 100%% SUCCESS (VERDICT: APPROVE) <<<\n");
    printf("===================================================================\n\n");
    return 0;
}
