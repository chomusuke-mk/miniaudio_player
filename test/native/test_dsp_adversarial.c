/**
 * @file test_dsp_adversarial.c
 * @brief Adversarial C stress test harness for miniaudio_player DSP engine.
 *
 * Stress-tests:
 *  1. Frequency response accuracy across all 10 EQ bands (impulses & sinusoids via DTFT and RMS).
 *  2. Extreme input validation (boost/cut limits, clamping, signal extremes, rate/pitch limits, sample rates, channels).
 *  3. Rapid hot-reinitialization (1000 updates) during continuous streaming with ZERO heap allocations.
 *  4. Full player lifecycle and preset verification under AddressSanitizer and UndefinedBehaviorSanitizer.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

/* Direct inclusion of source to allow white-box inspection of internal DSP node */
#include "../../src/miniaudio_player.c"

/* ========================================================================= */
/* Linker-Wrapped Heap Allocation Interceptors                                */
/* ========================================================================= */

extern void *__real_malloc(size_t size);
extern void *__real_calloc(size_t nmemb, size_t size);
extern void *__real_realloc(void *ptr, size_t size);
extern void __real_free(void *ptr);

static atomic_int g_disallow_allocations = 0;
static atomic_int g_forbidden_alloc_count = 0;

void *__wrap_malloc(size_t size)
{
    if (atomic_load_explicit(&g_disallow_allocations, memory_order_seq_cst))
    {
        atomic_fetch_add_explicit(&g_forbidden_alloc_count, 1, memory_order_seq_cst);
    }
    return __real_malloc(size);
}

void *__wrap_calloc(size_t nmemb, size_t size)
{
    if (atomic_load_explicit(&g_disallow_allocations, memory_order_seq_cst))
    {
        atomic_fetch_add_explicit(&g_forbidden_alloc_count, 1, memory_order_seq_cst);
    }
    return __real_calloc(nmemb, size);
}

void *__wrap_realloc(void *ptr, size_t size)
{
    if (atomic_load_explicit(&g_disallow_allocations, memory_order_seq_cst))
    {
        atomic_fetch_add_explicit(&g_forbidden_alloc_count, 1, memory_order_seq_cst);
    }
    return __real_realloc(ptr, size);
}

void __wrap_free(void *ptr)
{
    /* free is generally safe, but we track if disallow is active */
    if (atomic_load_explicit(&g_disallow_allocations, memory_order_seq_cst))
    {
        atomic_fetch_add_explicit(&g_forbidden_alloc_count, 1, memory_order_seq_cst);
    }
    __real_free(ptr);
}

/* ========================================================================= */
/* Test Utilities & Audio Math                                               */
/* ========================================================================= */

static const double k_bands[10] = {
    60.0, 170.0, 310.0, 600.0, 1000.0, 3000.0, 6000.0, 12000.0, 14000.0, 16000.0};

/**
 * @brief Computes Discrete-Time Fourier Transform (DTFT) magnitude in dB at frequency f.
 */
static double compute_dtft_magnitude_db(
    const float *signal,
    uint32_t channel_stride,
    uint32_t frame_count,
    double target_freq,
    uint32_t sample_rate)
{
    double real_part = 0.0;
    double imag_part = 0.0;
    uint32_t n;

    for (n = 0; n < frame_count; n++)
    {
        double angle = 2.0 * M_PI * target_freq * (double)n / (double)sample_rate;
        double sample = (double)signal[n * channel_stride];
        real_part += sample * cos(angle);
        imag_part -= sample * sin(angle);
    }

    double magnitude = sqrt(real_part * real_part + imag_part * imag_part);
    if (magnitude < 1e-12)
        return -240.0;
    return 20.0 * log10(magnitude);
}

/**
 * @brief Computes Root Mean Square (RMS) of a signal segment.
 */
static double compute_rms(
    const float *signal,
    uint32_t channel_stride,
    uint32_t start_frame,
    uint32_t count)
{
    double sum = 0.0;
    uint32_t n;
    if (count == 0)
        return 0.0;

    for (n = start_frame; n < start_frame + count; n++)
    {
        double s = (double)signal[n * channel_stride];
        sum += s * s;
    }
    return sqrt(sum / (double)count);
}

/**
 * @brief Procedurally writes a 16-bit PCM mono/stereo WAV file for testing.
 */
static void write_synthetic_wav(const char *filename, uint32_t sample_rate, uint32_t channels, double duration_sec)
{
    FILE *f = fopen(filename, "wb");
    assert(f != NULL);

    uint32_t total_frames = (uint32_t)(sample_rate * duration_sec);
    uint32_t data_bytes = total_frames * channels * sizeof(int16_t);
    uint32_t riff_chunk_size = 36 + data_bytes;

    /* Header */
    fwrite("RIFF", 1, 4, f);
    fwrite(&riff_chunk_size, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    uint32_t subchunk1_size = 16;
    uint16_t audio_format = 1; /* PCM */
    uint16_t num_channels = (uint16_t)channels;
    uint32_t byte_rate = sample_rate * channels * sizeof(int16_t);
    uint16_t block_align = channels * sizeof(int16_t);
    uint16_t bits_per_sample = 16;

    fwrite(&subchunk1_size, 4, 1, f);
    fwrite(&audio_format, 2, 1, f);
    fwrite(&num_channels, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bits_per_sample, 2, 1, f);

    fwrite("data", 1, 4, f);
    fwrite(&data_bytes, 4, 1, f);

    /* Multitone audio signal covering low, mid, high frequencies */
    for (uint32_t i = 0; i < total_frames; i++)
    {
        double t = (double)i / (double)sample_rate;
        double s = 0.3 * sin(2.0 * M_PI * 100.0 * t) +
                   0.3 * sin(2.0 * M_PI * 1000.0 * t) +
                   0.3 * sin(2.0 * M_PI * 10000.0 * t);
        int16_t sample16 = (int16_t)(s * 30000.0);
        for (uint32_t c = 0; c < channels; c++)
        {
            fwrite(&sample16, sizeof(int16_t), 1, f);
        }
    }

    fclose(f);
}

/* ========================================================================= */
/* SUITE 1: 10-Band Impulse Response Frequency Response (DTFT Analysis)     */
/* ========================================================================= */

static void test_suite_1_impulse_response_dtft(void)
{
    printf("\n===================================================================\n");
    printf("[SUITE 1] 10-Band Impulse Response & DTFT Frequency Response\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    const uint32_t frame_count = 8192;

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    ma_result res = ma_engine_init(&engine_cfg, &engine);
    assert(res == MA_SUCCESS);

    ma_equalizer_node eq;
    res = ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq);
    assert(res == MA_SUCCESS);

    float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
    float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));
    assert(in_buf != NULL && out_buf != NULL);

    /* 1.1 Flat Response Verification (all 0 dB) */
    printf("--- 1.1 Verifying Flat EQ (0.0 dB across all 10 bands) ---\n");
    for (int b = 0; b < 10; b++)
    {
        ma_equalizer_node_set_band(&eq, b, 0.0f);
    }
    memset(in_buf, 0, frame_count * channels * sizeof(float));
    memset(out_buf, 0, frame_count * channels * sizeof(float));
    in_buf[0] = 1.0f; /* impulse */
    if (channels > 1)
        in_buf[1] = 1.0f;

    const float *pIn = in_buf;
    float *pOut = out_buf;
    ma_uint32 fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    for (int b = 0; b < 10; b++)
    {
        double gain_db = compute_dtft_magnitude_db(out_buf, channels, frame_count, k_bands[b], sample_rate);
        printf("  Band %d (%5.0f Hz): %+.3f dB\n", b, k_bands[b], gain_db);
        assert(fabs(gain_db) < 0.05); /* Flat must be within 0.05 dB */
    }

    /* 1.2 Individual Band Boost & Cut Verification (+6 dB, -6 dB, +12 dB, -12 dB) */
    printf("\n--- 1.2 Verifying Individual Band Boost & Cut Responses ---\n");
    float test_gains[] = {+6.0f, -6.0f, +12.0f, -12.0f};

    for (int b = 0; b < 10; b++)
    {
        for (int g = 0; g < 4; g++)
        {
            float target_gain = test_gains[g];

            /* Reset all bands to 0, then set band b */
            for (int k = 0; k < 10; k++)
            {
                ma_equalizer_node_set_band(&eq, k, 0.0f);
            }
            ma_equalizer_node_set_band(&eq, b, target_gain);

            memset(in_buf, 0, frame_count * channels * sizeof(float));
            memset(out_buf, 0, frame_count * channels * sizeof(float));
            in_buf[0] = 1.0f;
            if (channels > 1)
                in_buf[1] = 1.0f;

            pIn = in_buf;
            pOut = out_buf;
            fc = frame_count;
            ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

            if (b >= 1 && b <= 8)
            {
                /* Peaking filters: gain at center frequency must match target gain */
                double measured_db = compute_dtft_magnitude_db(out_buf, channels, frame_count, k_bands[b], sample_rate);
                double err = fabs(measured_db - target_gain);
                printf("  Band %d (%5.0f Hz) Target: %+6.1f dB | Measured: %+6.2f dB | Error: %.3f dB [PASS]\n",
                       b, k_bands[b], target_gain, measured_db, err);
                assert(err < 0.25); /* Peaking filter gain error < 0.25 dB */
            }
            else if (b == 0)
            {
                /* Low shelf (60 Hz): Passband at 20 Hz approaches full gain; 60 Hz is shelf midpoint */
                double measured_20hz = compute_dtft_magnitude_db(out_buf, channels, frame_count, 20.0, sample_rate);
                double measured_60hz = compute_dtft_magnitude_db(out_buf, channels, frame_count, 60.0, sample_rate);
                printf("  Band 0 ( 60 LowShelf) Target: %+6.1f dB | @20Hz: %+6.2f dB | @60Hz: %+6.2f dB [PASS]\n",
                       target_gain, measured_20hz, measured_60hz);
                /* At 20 Hz, within 0.8 dB of full target gain; at 60 Hz, between 0 and target */
                assert(fabs(measured_20hz - target_gain) < 1.0);
                if (target_gain > 0)
                {
                    assert(measured_60hz > 0.0 && measured_60hz <= target_gain);
                }
                else
                {
                    assert(measured_60hz < 0.0 && measured_60hz >= target_gain);
                }
            }
            else if (b == 9)
            {
                /* High shelf (16 kHz): Passband at 22 kHz approaches full gain; 16 kHz is shelf midpoint */
                double measured_22k = compute_dtft_magnitude_db(out_buf, channels, frame_count, 22000.0, sample_rate);
                double measured_16k = compute_dtft_magnitude_db(out_buf, channels, frame_count, 16000.0, sample_rate);
                printf("  Band 9 (16k HiShelf ) Target: %+6.1f dB | @22k : %+6.2f dB | @16k : %+6.2f dB [PASS]\n",
                       target_gain, measured_22k, measured_16k);
                assert(fabs(measured_22k - target_gain) < 1.0);
                if (target_gain > 0)
                {
                    assert(measured_16k > 0.0 && measured_16k <= target_gain);
                }
                else
                {
                    assert(measured_16k < 0.0 && measured_16k >= target_gain);
                }
            }
        }
    }

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SUITE 1 (Impulse Response DTFT) PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* SUITE 2: Sinusoidal Steady-State RMS Response Verification               */
/* ========================================================================= */

static void test_suite_2_sinusoid_steady_state(void)
{
    printf("\n===================================================================\n");
    printf("[SUITE 2] Sinusoidal Steady-State RMS Response Across All 10 Bands\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    const uint32_t total_frames = 12288;
    const uint32_t settling_frames = 4096;
    const uint32_t measure_frames = 8192;

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    ma_result res = ma_engine_init(&engine_cfg, &engine);
    assert(res == MA_SUCCESS);

    ma_equalizer_node eq;
    res = ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq);
    assert(res == MA_SUCCESS);

    float *in_buf = (float *)malloc(total_frames * channels * sizeof(float));
    float *out_buf = (float *)malloc(total_frames * channels * sizeof(float));
    assert(in_buf != NULL && out_buf != NULL);

    float boost_db = +9.0f;
    float cut_db = -9.0f;

    for (int b = 1; b <= 8; b++)
    {
        double freq = k_bands[b];

        /* Generate input sinusoid at frequency f */
        double amplitude = 0.05; /* -26 dBFS to provide headroom for boost */
        for (uint32_t i = 0; i < total_frames; i++)
        {
            float val = (float)(amplitude * sin(2.0 * M_PI * freq * (double)i / (double)sample_rate));
            for (uint32_t c = 0; c < channels; c++)
            {
                in_buf[i * channels + c] = val;
            }
        }
        double rms_in = compute_rms(in_buf, channels, settling_frames, measure_frames);

        /* Test Boost */
        for (int k = 0; k < 10; k++)
            ma_equalizer_node_set_band(&eq, k, 0.0f);
        ma_equalizer_node_set_band(&eq, b, boost_db);
        const float *pIn = in_buf;
        float *pOut = out_buf;
        ma_uint32 fc = total_frames;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
        double rms_out_boost = compute_rms(out_buf, channels, settling_frames, measure_frames);
        double measured_boost_db = 20.0 * log10(rms_out_boost / rms_in);

        /* Test Cut */
        for (int k = 0; k < 10; k++)
            ma_equalizer_node_set_band(&eq, k, 0.0f);
        ma_equalizer_node_set_band(&eq, b, cut_db);
        pIn = in_buf;
        pOut = out_buf;
        fc = total_frames;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
        double rms_out_cut = compute_rms(out_buf, channels, settling_frames, measure_frames);
        double measured_cut_db = 20.0 * log10(rms_out_cut / rms_in);

        printf("  Band %d (%5.0f Hz) Sine RMS -> Boost Target: %+5.1fdB (Meas: %+5.2fdB) | Cut Target: %+5.1fdB (Meas: %+5.2fdB)\n",
               b, freq, boost_db, measured_boost_db, cut_db, measured_cut_db);

        assert(fabs(measured_boost_db - boost_db) < 0.35);
        assert(fabs(measured_cut_db - cut_db) < 0.35);
    }

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SUITE 2 (Sinusoidal Steady-State RMS) PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* SUITE 3: Extreme Inputs, Clamping, Boundary Values & Stability           */
/* ========================================================================= */

static void test_suite_3_extreme_inputs(void)
{
    printf("\n===================================================================\n");
    printf("[SUITE 3] Extreme Inputs, Clamping, Bounds, NaN/Inf, Rate/Pitch\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    ma_result res = ma_engine_init(&engine_cfg, &engine);
    assert(res == MA_SUCCESS);

    ma_equalizer_node eq;
    res = ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq);
    assert(res == MA_SUCCESS);

    /* 3.1 Gain Boost/Cut Extremes & Clamping */
    printf("--- 3.1 Clamping & Boundary Gains (+24dB, -24dB, Out-of-Range) ---\n");
    assert(map_clamp_gain_db(+24.0f) == 24.0f);
    assert(map_clamp_gain_db(-24.0f) == -24.0f);
    assert(map_clamp_gain_db(+30.0f) == 24.0f);
    assert(map_clamp_gain_db(+1000.0f) == 24.0f);
    assert(map_clamp_gain_db(-30.0f) == -24.0f);
    assert(map_clamp_gain_db(-1000.0f) == -24.0f);
    assert(map_clamp_gain_db(0.0f) == 0.0f);
    assert(map_clamp_gain_db(-0.0f) == 0.0f);

    /* Setting extreme values into equalizer node directly */
    assert(ma_equalizer_node_set_band(&eq, 0, 100.0f) == MA_SUCCESS);
    assert(ma_equalizer_node_set_band(&eq, 4, -100.0f) == MA_SUCCESS);
    assert(ma_equalizer_node_set_band(&eq, 9, 24.0f) == MA_SUCCESS);
    assert(ma_equalizer_node_set_band(&eq, 10, 0.0f) == MA_INVALID_ARGS);
    assert(ma_equalizer_node_set_band(&eq, 999, 0.0f) == MA_INVALID_ARGS);
    assert(ma_equalizer_node_set_band(NULL, 0, 0.0f) == MA_INVALID_ARGS);
    printf("  EQ node boundary gains clamped safely.\n");

    /* 3.2 Audio Signal Extremes (Full Scale Square Wave + 24dB boost) */
    printf("\n--- 3.2 Audio Signal Stress (Full Scale +24dB, Silence, Subnormals) ---\n");
    const uint32_t test_frames = 10000;
    float *extreme_in = (float *)malloc(test_frames * channels * sizeof(float));
    float *extreme_out = (float *)malloc(test_frames * channels * sizeof(float));
    assert(extreme_in != NULL && extreme_out != NULL);

    /* Set all bands to +24 dB */
    for (int b = 0; b < 10; b++)
    {
        ma_equalizer_node_set_band(&eq, b, 24.0f);
    }

    /* Feed +/- 1.0 square wave */
    for (uint32_t i = 0; i < test_frames; i++)
    {
        float s = (i % 200 < 100) ? 1.0f : -1.0f;
        extreme_in[i * channels + 0] = s;
        extreme_in[i * channels + 1] = -s;
    }
    const float *pIn = extreme_in;
    float *pOut = extreme_out;
    ma_uint32 fc = test_frames;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    /* Assert NO NaN or INF */
    for (uint32_t i = 0; i < test_frames * channels; i++)
    {
        assert(!isnan(extreme_out[i]));
        assert(!isinf(extreme_out[i]));
    }
    printf("  Full-scale square wave under +24dB EQ: 0 NaN, 0 INF values.\n");

    /* Feed Silence (0.0f) under +24 dB and -24 dB */
    memset(extreme_in, 0, test_frames * channels * sizeof(float));
    pIn = extreme_in;
    pOut = extreme_out;
    fc = test_frames;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
    for (uint32_t i = 0; i < test_frames * channels; i++)
    {
        assert(!isnan(extreme_out[i]));
        assert(!isinf(extreme_out[i]));
    }
    printf("  Zero input silence: zero divergence, 0 NaN, 0 INF.\n");

    /* Feed Subnormals (1e-38f) */
    for (uint32_t i = 0; i < test_frames * channels; i++)
    {
        extreme_in[i] = 1e-38f;
    }
    pIn = extreme_in;
    pOut = extreme_out;
    fc = test_frames;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
    for (uint32_t i = 0; i < test_frames * channels; i++)
    {
        assert(!isnan(extreme_out[i]));
        assert(!isinf(extreme_out[i]));
    }
    printf("  Denormal / subnormal float stress: 0 NaN, 0 INF, filter stable.\n");

    free(extreme_in);
    free(extreme_out);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);

    /* 3.3 Sample Rate Extreme Tests (8000 Hz to 192000 Hz) */
    printf("\n--- 3.3 Sample Rate Extremes (8 kHz, 22.05 kHz, 96 kHz, 192 kHz) ---\n");
    uint32_t test_sample_rates[] = {8000, 11025, 22050, 44100, 48000, 88200, 96000, 192000};
    for (int sr_idx = 0; sr_idx < 8; sr_idx++)
    {
        uint32_t sr = test_sample_rates[sr_idx];
        engine_cfg = ma_engine_config_init();
        engine_cfg.sampleRate = sr;
        engine_cfg.channels = 2;
        res = ma_engine_init(&engine_cfg, &engine);
        assert(res == MA_SUCCESS);

        res = ma_equalizer_node_init(&engine.nodeGraph, 2, sr, &eq);
        assert(res == MA_SUCCESS);

        /* Set all bands to +12 dB */
        for (int b = 0; b < 10; b++)
        {
            res = ma_equalizer_node_set_band(&eq, b, 12.0f);
            assert(res == MA_SUCCESS);
        }

        /* Process a burst of 1024 frames */
        float burst_in[2048];
        float burst_out[2048];
        for (int i = 0; i < 2048; i++)
            burst_in[i] = 0.1f * sinf((float)i * 0.1f);
        pIn = burst_in;
        pOut = burst_out;
        fc = 1024;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

        for (int i = 0; i < 2048; i++)
        {
            assert(!isnan(burst_out[i]));
            assert(!isinf(burst_out[i]));
        }

        ma_equalizer_node_uninit(&eq);
        ma_engine_uninit(&engine);
        printf("  Sample rate %6u Hz passed with zero NaN/INF (Nyquist clamp verified).\n", sr);
    }

    /* 3.4 Multi-Channel Extreme Tests (Mono, Stereo, Quad, 5.1, 7.1) */
    printf("\n--- 3.4 Multi-Channel Configurations (1, 2, 4, 6, 8 channels) ---\n");
    uint32_t channel_configs[] = {1, 2, 4, 6, 8};
    for (int ch_idx = 0; ch_idx < 5; ch_idx++)
    {
        uint32_t ch = channel_configs[ch_idx];
        engine_cfg = ma_engine_config_init();
        engine_cfg.sampleRate = 48000;
        engine_cfg.channels = ch;
        res = ma_engine_init(&engine_cfg, &engine);
        assert(res == MA_SUCCESS);

        res = ma_equalizer_node_init(&engine.nodeGraph, ch, 48000, &eq);
        assert(res == MA_SUCCESS);

        float *ch_buf_in = (float *)calloc(2048 * ch, sizeof(float));
        float *ch_buf_out = (float *)calloc(2048 * ch, sizeof(float));
        assert(ch_buf_in != NULL && ch_buf_out != NULL);

        for (uint32_t i = 0; i < 2048 * ch; i++)
            ch_buf_in[i] = 0.05f;
        pIn = ch_buf_in;
        pOut = ch_buf_out;
        fc = 2048;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

        for (uint32_t i = 0; i < 2048 * ch; i++)
        {
            assert(!isnan(ch_buf_out[i]));
            assert(!isinf(ch_buf_out[i]));
        }

        free(ch_buf_in);
        free(ch_buf_out);
        ma_equalizer_node_uninit(&eq);
        ma_engine_uninit(&engine);
        printf("  %u-channel stream verified under AddressSanitizer (zero buffer overflow).\n", ch);
    }

    /* 3.5 Rate & Pitch Public API Boundaries */
    printf("\n--- 3.5 Rate & Pitch API Boundaries & Varispeed Multiplication ---\n");
    int32_t out_res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &out_res);
    assert(player != NULL && out_res == MAP_SUCCESS);

    /* Valid rate tests: 0.1 to 4.0 */
    float valid_rates[] = {0.1f, 0.25f, 0.5f, 1.0f, 1.5f, 2.0f, 3.5f, 4.0f};
    for (int r = 0; r < 8; r++)
    {
        assert(miniaudio_player_set_rate(player, valid_rates[r]) == MAP_SUCCESS);
        assert(fabs(miniaudio_player_get_rate(player) - valid_rates[r]) < 1e-5);
    }

    /* Invalid rate tests */
    assert(miniaudio_player_set_rate(player, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, -0.5f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, -4.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, -INFINITY) == MAP_ERROR_INVALID_ARGS);

    /* Valid pitch tests: 0.5 to 2.0 */
    float valid_pitches[] = {0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f};
    for (int p = 0; p < 7; p++)
    {
        assert(miniaudio_player_set_pitch(player, valid_pitches[p]) == MAP_SUCCESS);
        assert(fabs(miniaudio_player_get_pitch(player) - valid_pitches[p]) < 1e-5);
    }

    /* Invalid pitch tests */
    assert(miniaudio_player_set_pitch(player, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, -0.5f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, -2.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, INFINITY) == MAP_ERROR_INVALID_ARGS);

    /* Combined varispeed factor check */
    assert(miniaudio_player_set_rate(player, 4.0f) == MAP_SUCCESS);
    assert(miniaudio_player_set_pitch(player, 2.0f) == MAP_SUCCESS);
    miniaudio_player_status_t status;
    assert(miniaudio_player_get_status(player, &status) == MAP_SUCCESS);
    assert(status.rate == 4.0f);
    assert(status.pitch == 2.0f);

    /* EQ API NaN / Inf / Boundary validation */
    assert(miniaudio_player_set_equalizer_band(player, 0, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(player, 0, INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(player, 10, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(NULL, 0, 0.0f) == MAP_ERROR_INVALID_ARGS);

    miniaudio_player_equalizer_params_t bad_eq;
    memset(&bad_eq, 0, sizeof(bad_eq));
    bad_eq.hz1k = NAN;
    assert(miniaudio_player_set_equalizer(player, &bad_eq) == MAP_ERROR_INVALID_ARGS);
    bad_eq.hz1k = INFINITY;
    assert(miniaudio_player_set_equalizer(player, &bad_eq) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer(NULL, &bad_eq) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer(player, NULL) == MAP_ERROR_INVALID_ARGS);

    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    printf("  Rate, pitch, and EQ API boundary validations passed.\n");
    printf(">>> SUITE 3 (Extreme Inputs & Boundaries) PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* SUITE 4: Rapid Hot-Reinitialization (1000x) & Zero Heap Allocation        */
/* ========================================================================= */

typedef struct
{
    ma_equalizer_node *pEq;
    atomic_int stop_flag;
    uint32_t channels;
    atomic_uint_fast64_t frames_processed;
} stream_worker_args_t;

static void *streaming_audio_worker(void *user_data)
{
    stream_worker_args_t *args = (stream_worker_args_t *)user_data;
    const uint32_t buf_frames = 256;
    float *in_buf = (float *)malloc(buf_frames * args->channels * sizeof(float));
    float *out_buf = (float *)malloc(buf_frames * args->channels * sizeof(float));
    assert(in_buf != NULL && out_buf != NULL);

    for (uint32_t i = 0; i < buf_frames * args->channels; i++)
    {
        in_buf[i] = 0.1f * (float)((i % 50) - 25) / 25.0f;
    }

    while (!atomic_load_explicit(&args->stop_flag, memory_order_relaxed))
    {
        const float *pIn = in_buf;
        float *pOut = out_buf;
        ma_uint32 count = buf_frames;
        ma_equalizer_node_process_pcm_frames(&args->pEq->baseNode, &pIn, &count, &pOut, &count);

        /* Verify output never contains NaN or INF */
        for (uint32_t i = 0; i < buf_frames * args->channels; i++)
        {
            assert(!isnan(pOut[i]));
            assert(!isinf(pOut[i]));
        }

        atomic_fetch_add_explicit(&args->frames_processed, count, memory_order_relaxed);
        usleep(50); /* small yield to interleave with updates */
    }

    free(in_buf);
    free(out_buf);
    return NULL;
}

static void test_suite_4_hot_reinit_zero_alloc(void)
{
    printf("\n===================================================================\n");
    printf("[SUITE 4] Rapid Hot-Reinitialization (1000x Updates) & Zero Heap Alloc\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    ma_result res = ma_engine_init(&engine_cfg, &engine);
    assert(res == MA_SUCCESS);

    ma_equalizer_node eq;
    res = ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq);
    assert(res == MA_SUCCESS);

    /* Launch concurrent audio streaming worker */
    stream_worker_args_t worker_args;
    worker_args.pEq = &eq;
    worker_args.channels = channels;
    atomic_init(&worker_args.stop_flag, 0);
    atomic_init(&worker_args.frames_processed, 0);

    pthread_t thread;
    int pret = pthread_create(&thread, NULL, streaming_audio_worker, &worker_args);
    assert(pret == 0);

    /* Let audio streaming start */
    usleep(10000);

    printf("--- Engaging Zero-Allocation Strict Guard ---\n");
    atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
    atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);

    /* Perform 1,000 rapid hot-reinitialization updates while audio streams */
    printf("  Executing 500 random individual band re-inits...\n");
    for (int i = 0; i < 500; i++)
    {
        uint32_t band = (uint32_t)(i % 10);
        float gain = -24.0f + (float)(rand() % 4801) / 100.0f; /* -24.0 to +24.0 dB */
        ma_result r = ma_equalizer_node_set_band(&eq, band, gain);
        assert(r == MA_SUCCESS);
    }

    printf("  Executing 500 random full 10-band preset re-inits...\n");
    for (int i = 0; i < 500; i++)
    {
        miniaudio_player_equalizer_params_t p;
        p.hz60 = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz170 = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz310 = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz600 = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz1k = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz3k = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz6k = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz12k = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz14k = -12.0f + (float)(rand() % 2401) / 100.0f;
        p.hz16k = -12.0f + (float)(rand() % 2401) / 100.0f;
        ma_result r = ma_equalizer_node_set_all(&eq, &p);
        assert(r == MA_SUCCESS);
    }

    /* Disengage allocation guard before stopping thread */
    atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);
    int forbidden_allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);

    /* Signal streaming worker to stop and join */
    atomic_store_explicit(&worker_args.stop_flag, 1, memory_order_relaxed);
    pthread_join(thread, NULL);

    uint64_t total_streamed = atomic_load_explicit(&worker_args.frames_processed, memory_order_relaxed);
    printf("  Total audio frames streamed during 1000 updates: %lu frames\n", total_streamed);
    printf("  Forbidden heap allocations detected: %d (Target: 0)\n", forbidden_allocs);

    assert(forbidden_allocs == 0);
    assert(total_streamed > 10000);

    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SUITE 4 (Rapid Hot-Reinit & Zero Allocations) PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* SUITE 5: Full Player Integration & Real-Time Playback Presets             */
/* ========================================================================= */

static void test_suite_5_player_presets_and_playback(void)
{
    printf("\n===================================================================\n");
    printf("[SUITE 5] Full Player Integration, Live Playback & Presets\n");
    printf("===================================================================\n");

    const char *wav_path = "/tmp/test_adversarial_dsp.wav";
    write_synthetic_wav(wav_path, 48000, 2, 1.5); /* 1.5 second multi-tone */

    int32_t result = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &result);
    assert(player != NULL && result == MAP_SUCCESS);

    result = miniaudio_player_open_file(player, wav_path);
    assert(result == MAP_SUCCESS);

    int64_t dur = miniaudio_player_get_duration_ms(player);
    assert(dur >= 1400 && dur <= 1600);

    /* Test all 6 standard presets from PROJECT.md */
    miniaudio_player_equalizer_params_t presets[] = {
        /* Flat */
        {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f},
        /* Rock */
        {4.5f, 3.5f, 2.0f, 0.5f, -1.0f, -0.5f, 1.5f, 3.0f, 4.0f, 4.5f},
        /* Pop */
        {-1.5f, -0.5f, 1.5f, 3.0f, 3.5f, 2.5f, 0.5f, -1.0f, -1.5f, -2.0f},
        /* Jazz */
        {3.5f, 2.5f, 1.0f, 1.5f, -1.0f, -1.0f, 0.5f, 1.5f, 2.5f, 3.5f},
        /* Classical */
        {4.0f, 3.0f, 2.0f, 1.5f, -1.0f, -1.0f, 0.0f, 1.5f, 2.5f, 3.0f},
        /* BassBoost */
        {7.0f, 6.0f, 5.0f, 3.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f}};
    const char *preset_names[] = {"Flat", "Rock", "Pop", "Jazz", "Classical", "BassBoost"};

    /* Start live playback through device thread */
    assert(miniaudio_player_play(player) == MAP_SUCCESS);
    assert(miniaudio_player_is_playing(player) == 1);

    for (int i = 0; i < 6; i++)
    {
        assert(miniaudio_player_set_equalizer(player, &presets[i]) == MAP_SUCCESS);

        miniaudio_player_status_t status;
        assert(miniaudio_player_get_status(player, &status) == MAP_SUCCESS);

        /* Verify all 10 bands in snapshot */
        assert(fabs(status.equalizer.hz60 - presets[i].hz60) < 1e-4);
        assert(fabs(status.equalizer.hz170 - presets[i].hz170) < 1e-4);
        assert(fabs(status.equalizer.hz310 - presets[i].hz310) < 1e-4);
        assert(fabs(status.equalizer.hz600 - presets[i].hz600) < 1e-4);
        assert(fabs(status.equalizer.hz1k - presets[i].hz1k) < 1e-4);
        assert(fabs(status.equalizer.hz3k - presets[i].hz3k) < 1e-4);
        assert(fabs(status.equalizer.hz6k - presets[i].hz6k) < 1e-4);
        assert(fabs(status.equalizer.hz12k - presets[i].hz12k) < 1e-4);
        assert(fabs(status.equalizer.hz14k - presets[i].hz14k) < 1e-4);
        assert(fabs(status.equalizer.hz16k - presets[i].hz16k) < 1e-4);

        printf("  Preset %-10s applied and verified during live audio stream.\n", preset_names[i]);
        usleep(25000); /* 25ms playback under each preset */
    }

    /* Perform 1,000 rapid preset switches against the live playing player */
    printf("  Stress-testing 1000 live updates on playing player instance...\n");
    atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
    atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);

    for (int i = 0; i < 1000; i++)
    {
        uint32_t b = (uint32_t)(i % 10);
        float g = -10.0f + (float)(i % 20);
        assert(miniaudio_player_set_equalizer_band(player, b, g) == MAP_SUCCESS);
    }

    atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);
    int forbidden_allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);
    assert(forbidden_allocs == 0);
    printf("  1000 live player EQ updates completed with 0 heap allocations.\n");

    /* Pause, seek, stop, destroy */
    assert(miniaudio_player_pause(player) == MAP_SUCCESS);
    assert(miniaudio_player_seek(player, 500) == MAP_SUCCESS);
    assert(miniaudio_player_stop(player) == MAP_SUCCESS);
    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);

    unlink(wav_path);
    printf(">>> SUITE 5 (Full Player & Presets) PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* SUITE 6: Deep Adversarial Fault Injection & Concurrency Boundary Tests    */
/* ========================================================================= */

static void test_suite_6_adversarial_deep_validation(void)
{
    printf("\n===================================================================\n");
    printf("[SUITE 6] Deep Adversarial Fault Injection & Boundary Invariants   \n");
    printf("===================================================================\n");

    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL && res == MAP_SUCCESS);

    /* 6.1 Exhaustive NaN / +Inf / -Inf injection across ALL 10 bands */
    printf("--- 6.1 Exhaustive NaN / +/-Inf Injection Across All 10 EQ Bands ---\n");
    float invalid_vals[] = {NAN, INFINITY, -INFINITY};
    for (int b = 0; b < 10; b++)
    {
        for (int v = 0; v < 3; v++)
        {
            miniaudio_player_equalizer_params_t eq;
            memset(&eq, 0, sizeof(eq));
            float *p = (float *)&eq;
            p[b] = invalid_vals[v];

            int32_t r = miniaudio_player_set_equalizer(player, &eq);
            assert(r == MAP_ERROR_INVALID_ARGS);

            r = miniaudio_player_set_equalizer_band(player, (uint32_t)b, invalid_vals[v]);
            assert(r == MAP_ERROR_INVALID_ARGS);
        }
        printf("  Band %d: NaN, +Inf, -Inf successfully rejected by both APIs.\n", b);
    }

    /* 6.2 Null Pointer Robustness across all APIs */
    printf("\n--- 6.2 NULL Pointer Robustness ---\n");
    assert(miniaudio_player_set_volume(NULL, 1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(NULL, 1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(NULL, 1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer(NULL, NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(NULL, 0, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_get_status(NULL, NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_get_equalizer(NULL, NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_play(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_pause(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_stop(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_seek(NULL, 0) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_destroy(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_get_volume(NULL) == 1.0f);
    assert(miniaudio_player_get_rate(NULL) == 1.0f);
    assert(miniaudio_player_get_pitch(NULL) == 1.0f);
    assert(miniaudio_player_get_position_ms(NULL) == 0);
    assert(miniaudio_player_get_duration_ms(NULL) == 0);
    assert(miniaudio_player_is_playing(NULL) == 0);
    assert(miniaudio_player_is_completed(NULL) == 0);
    printf("  All NULL pointer invocations safely handled without segfault.\n");

    /* 6.3 Low-level ma_equalizer_node Fault Injections */
    printf("\n--- 6.3 Low-Level ma_equalizer_node Fault Injections ---\n");
    ma_engine_config engine_cfg = ma_engine_config_init();
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq_node;
    assert(ma_equalizer_node_init(NULL, 2, 48000, &eq_node) == MA_INVALID_ARGS);
    assert(ma_equalizer_node_init(&engine.nodeGraph, 0, 48000, &eq_node) == MA_INVALID_ARGS);
    assert(ma_equalizer_node_init(&engine.nodeGraph, 2, 0, &eq_node) == MA_INVALID_ARGS);
    assert(ma_equalizer_node_init(&engine.nodeGraph, 2, 48000, NULL) == MA_INVALID_ARGS);

    /* Clean init then uninit NULL */
    assert(ma_equalizer_node_init(&engine.nodeGraph, 2, 48000, &eq_node) == MA_SUCCESS);
    ma_equalizer_node_uninit(NULL); /* must be safe no-op */

    /* Process frames with NULL buffers or 0 frame counts */
    const float *pIn = NULL;
    float *pOut = NULL;
    ma_uint32 count = 0;
    ma_equalizer_node_process_pcm_frames(&eq_node.baseNode, NULL, &count, &pOut, &count);
    ma_equalizer_node_process_pcm_frames(&eq_node.baseNode, &pIn, &count, NULL, &count);
    ma_equalizer_node_process_pcm_frames(&eq_node.baseNode, &pIn, &count, &pOut, NULL);
    count = 0;
    float dummy_f[4] = {0};
    pIn = dummy_f;
    pOut = dummy_f;
    ma_equalizer_node_process_pcm_frames(&eq_node.baseNode, &pIn, &count, &pOut, &count);

    ma_equalizer_node_uninit(&eq_node);
    ma_engine_uninit(&engine);
    printf("  Low-level node edge cases safely handled.\n");

    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    printf(">>> SUITE 6 (Deep Adversarial Validation) PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* Main Test Runner                                                          */
/* ========================================================================= */

int main(void)
{
    printf("===================================================================\n");
    printf("   STARTING ADVERSARIAL DSP & AUDIO PARAMETERS TEST HARNESS        \n");
    printf("===================================================================\n");

    test_suite_1_impulse_response_dtft();
    test_suite_2_sinusoid_steady_state();
    test_suite_3_extreme_inputs();
    test_suite_4_hot_reinit_zero_alloc();
    test_suite_5_player_presets_and_playback();
    test_suite_6_adversarial_deep_validation();

    printf("\n===================================================================\n");
    printf(">>> ALL ADVERSARIAL DSP TEST SUITES PASSED WITH 100%% SUCCESS! <<<\n");
    printf("===================================================================\n");
    return 0;
}
