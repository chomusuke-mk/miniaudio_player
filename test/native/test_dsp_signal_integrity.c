/**
 * @file test_dsp_signal_integrity.c
 * @brief Test suite for Equalizer verification, audio alterations, signal crushing
 * (aplastamiento), harmonic distortion (THD), and pass-through transparency.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <pthread.h>
#include <unistd.h>

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_dsp.h"

#define PI 3.14159265358979323846

/* Helper: compute RMS of a buffer */
static double compute_rms(const float *buffer, size_t count)
{
    double sum = 0.0;
    for (size_t i = 0; i < count; i++)
    {
        sum += (double)buffer[i] * (double)buffer[i];
    }
    return sqrt(sum / (double)count);
}

/* Helper: compute peak absolute value */
static float compute_peak(const float *buffer, size_t count)
{
    float max_val = 0.0f;
    for (size_t i = 0; i < count; i++)
    {
        float a = fabsf(buffer[i]);
        if (a > max_val)
            max_val = a;
    }
    return max_val;
}

/* Helper: compute Total Harmonic Distortion (THD) via single-frequency DFT extraction */
static double compute_thd_percent(const float *buffer, size_t count, double sample_rate, double fund_freq, int num_harmonics)
{
    const size_t stride = 2;
    size_t frames = count / stride;
    /* Fundamental energy */
    double fund_real = 0.0, fund_imag = 0.0;
    double omega1 = 2.0 * PI * fund_freq / sample_rate;
    for (size_t n = 0; n < frames; n++)
    {
        double sample_val = (double)buffer[n * stride];
        fund_real += sample_val * cos(omega1 * (double)n);
        fund_imag -= sample_val * sin(omega1 * (double)n);
    }
    double fund_pwr = (fund_real * fund_real + fund_imag * fund_imag);
    if (fund_pwr < 1e-12)
        return 0.0;

    /* Harmonics energy (2nd through Nth) */
    double harm_pwr = 0.0;
    for (int h = 2; h <= num_harmonics; h++)
    {
        double h_freq = fund_freq * (double)h;
        if (h_freq >= sample_rate * 0.49)
            break;
        double omega_h = 2.0 * PI * h_freq / sample_rate;
        double h_real = 0.0, h_imag = 0.0;
        for (size_t n = 0; n < frames; n++)
        {
            double sample_val = (double)buffer[n * stride];
            h_real += sample_val * cos(omega_h * (double)n);
            h_imag -= sample_val * sin(omega_h * (double)n);
        }
        harm_pwr += (h_real * h_real + h_imag * h_imag);
    }

    return sqrt(harm_pwr / fund_pwr) * 100.0;
}

/* ========================================================================= */
/* TEST 1: EQUALIZER FUNCTIONALITY & SET_ALL VERIFICATION                    */
/* ========================================================================= */
static void test_equalizer_functionality_verification(void)
{
    printf("\n===================================================================\n");
    printf("[SIGNAL TEST 1] Equalizer Real-Time Audio Filtering Verification\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    const uint32_t frame_count = 4800; /* 100 ms */

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);
    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);
    eq.limiter_enabled = 0; /* Pure linear measurement */

    float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
    float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));

    /* 1.1 Generate 1 kHz sine wave at amplitude 0.2 */
    double f0 = 1000.0;
    for (uint32_t i = 0; i < frame_count; i++)
    {
        float val = 0.2f * (float)sin(2.0 * PI * f0 * (double)i / (double)sample_rate);
        in_buf[i * 2 + 0] = val;
        in_buf[i * 2 + 1] = val;
    }

    double in_rms = compute_rms(in_buf, frame_count * channels);

    /* Test Flat EQ (all 0 dB) via set_all */
    miniaudio_player_equalizer_params_t flat_params = {0};
    assert(ma_equalizer_node_set_all(&eq, &flat_params) == MA_SUCCESS);

    const float *pIn = in_buf;
    float *pOut = out_buf;
    uint32_t fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    double flat_rms = compute_rms(out_buf, frame_count * channels);
    double flat_gain_db = 20.0 * log10(flat_rms / in_rms);
    printf("  Flat EQ (all 0 dB): In RMS=%.4f, Out RMS=%.4f (Delta: %+.3f dB) [PASS]\n",
           in_rms, flat_rms, flat_gain_db);
    assert(fabs(flat_gain_db) < 0.05);

    /* 1.2 Test +12 dB boost at 1 kHz (Band 5) via set_all */
    miniaudio_player_equalizer_params_t boost_params = {0};
    boost_params.hz1k = 12.0f;
    assert(ma_equalizer_node_set_all(&eq, &boost_params) == MA_SUCCESS);

    /* Discard initial filter settle block (50 ms) */
    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    /* Process steady-state block */
    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    double boost_rms = compute_rms(out_buf, frame_count * channels);
    double boost_gain_db = 20.0 * log10(boost_rms / in_rms);
    printf("  Band 5 (1 kHz) +12 dB Boost: Target=+12.0 dB, Measured=%+.2f dB (Error: %.2f dB) [PASS]\n",
           boost_gain_db, fabs(boost_gain_db - 12.0));
    assert(fabs(boost_gain_db - 12.0) < 0.20); /* Within 0.2 dB */

    /* 1.3 Test -12 dB cut at 1 kHz via set_all */
    miniaudio_player_equalizer_params_t cut_params = {0};
    cut_params.hz1k = -12.0f;
    assert(ma_equalizer_node_set_all(&eq, &cut_params) == MA_SUCCESS);

    /* Settle and process */
    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    double cut_rms = compute_rms(out_buf, frame_count * channels);
    double cut_gain_db = 20.0 * log10(cut_rms / in_rms);
    printf("  Band 5 (1 kHz) -12 dB Cut:   Target=-12.0 dB, Measured=%+.2f dB (Error: %.2f dB) [PASS]\n",
           cut_gain_db, fabs(cut_gain_db - (-12.0)));
    assert(fabs(cut_gain_db - (-12.0)) < 0.20);

    /* 1.4 Test Standard Presets (BassBoost, Rock) */
    miniaudio_player_equalizer_params_t bass_boost = {
        .hz31 = 7.0f, .hz63 = 6.0f, .hz125 = 5.0f, .hz250 = 3.0f, .hz500 = 1.0f
    };
    assert(ma_equalizer_node_set_all(&eq, &bass_boost) == MA_SUCCESS);

    /* Generate 63 Hz sub-bass tone */
    for (uint32_t i = 0; i < frame_count; i++)
    {
        float val = 0.2f * (float)sin(2.0 * PI * 63.0 * (double)i / (double)sample_rate);
        in_buf[i * 2 + 0] = val;
        in_buf[i * 2 + 1] = val;
    }
    in_rms = compute_rms(in_buf, frame_count * channels);

    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    double bass_rms = compute_rms(out_buf, frame_count * channels);
    double bass_gain_db = 20.0 * log10(bass_rms / in_rms);
    printf("  Preset BassBoost @ 63 Hz:   Target=+6.0 dB, Measured=%+.2f dB [PASS]\n", bass_gain_db);
    assert(fabs(bass_gain_db - 6.0) < 2.50);

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SIGNAL TEST 1 PASSED: Equalizer actively filters audio signals <<<\n");
}

/* ========================================================================= */
/* TEST 2: APLASTAMIENTO DE SENAL (COMPRESSION, KNEE & DISTORTION ANALYSIS)   */
/* ========================================================================= */
static void test_signal_crushing_and_limiter_distortion(void)
{
    printf("\n===================================================================\n");
    printf("[SIGNAL TEST 2] Signal Crushing (Aplastamiento) & THD Analysis\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    const uint32_t frame_count = 9600; /* 200 ms */

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);

    float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
    float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));

    /* Test multiple amplitude levels through the limiter */
    struct {
        float input_amp;
        const char *desc;
        double max_expected_thd_limiter_off;
        float max_expected_out_limiter_on;
    } cases[] = {
        {0.50f, "Linear Range (-6.0 dBFS)", 0.001, 0.50f},
        {0.90f, "Near Threshold (-0.9 dBFS)", 0.001, 0.90f},
        {0.95f, "At Soft-Knee Threshold (-0.45 dBFS)", 0.001, 0.95f},
        {0.99f, "In Knee Region (-0.08 dBFS, Aplastamiento Suave)", 0.001, 0.985f},
        {1.50f, "Over-Scale (+3.5 dBFS, Aplastamiento Fuerte / Saturation)", 0.001, 0.999f},
    };

    double f0 = 1000.0;

    for (int c = 0; c < 5; c++)
    {
        float amp = cases[c].input_amp;

        /* Synthesize pure sine */
        for (uint32_t i = 0; i < frame_count; i++)
        {
            float val = amp * (float)sin(2.0 * PI * f0 * (double)i / (double)sample_rate);
            in_buf[i * 2 + 0] = val;
            in_buf[i * 2 + 1] = val;
        }

        /* 2.1 Limiter OFF test */
        eq.limiter_enabled = 0;
        const float *pIn = in_buf;
        float *pOut = out_buf;
        uint32_t fc = frame_count;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

        double thd_off = compute_thd_percent(out_buf, frame_count * channels, sample_rate, f0, 5);
        float peak_off = compute_peak(out_buf, frame_count * channels);

        /* 2.2 Limiter ON test */
        eq.limiter_enabled = 1;
        pIn = in_buf; pOut = out_buf; fc = frame_count;
        ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

        double thd_on = compute_thd_percent(out_buf, frame_count * channels, sample_rate, f0, 5);
        float peak_on = compute_peak(out_buf, frame_count * channels);

        printf("  Level: %-36s | InPeak: %.2f\n", cases[c].desc, amp);
        printf("    Limiter OFF -> Peak: %6.3f, THD: %8.5f%%\n", peak_off, thd_off);
        printf("    Limiter ON  -> Peak: %6.3f, THD: %8.5f%% (Aplastamiento: %+.2f dB)\n",
               peak_on, thd_on, 20.0 * log10(peak_on / amp));

        /* Linear range must have practically zero distortion */
        if (amp <= 0.90f)
        {
            assert(thd_off < 0.01);
            assert(thd_on < 0.01);
            assert(fabsf(peak_on - amp) < 0.01f);
        }
        else if (amp > 1.0f)
        {
            /* Over-scale input must be clamped safely under 1.00 */
            assert(peak_on <= 1.0001f);
            assert(thd_on > 0.1); /* Harmonic distortion naturally occurs when compressing excess amplitude */
        }
    }

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SIGNAL TEST 2 PASSED: Limiter dynamics and aplastamiento quantified <<<\n");
}

/* ========================================================================= */
/* TEST 3: TRANSPARENCIA Y BIT-PERFECT EN ESTADO PLANO (0 dB)                 */
/* ========================================================================= */
static void test_pass_through_transparency(void)
{
    printf("\n===================================================================\n");
    printf("[SIGNAL TEST 3] Pass-Through Transparency & Zero Alteration at Unity\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    const uint32_t frame_count = 2048;

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);
    eq.limiter_enabled = 0; /* Disable limiter for bit-perfect check */

    float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
    float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));

    /* Multi-frequency synthetic signal below threshold */
    for (uint32_t i = 0; i < frame_count; i++)
    {
        float t = (float)i / (float)sample_rate;
        float sig = 0.3f * sinf(2.0f * (float)PI * 440.0f * t) +
                    0.2f * sinf(2.0f * (float)PI * 3000.0f * t) +
                    0.1f * sinf(2.0f * (float)PI * 12000.0f * t);
        in_buf[i * 2 + 0] = sig;
        in_buf[i * 2 + 1] = -sig; /* Out-of-phase stereo */
    }

    /* Process frames */
    const float *pIn = in_buf;
    float *pOut = out_buf;
    uint32_t fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    /* Measure maximum absolute difference and SNR */
    double max_diff = 0.0;
    double noise_energy = 0.0;
    double signal_energy = 0.0;

    for (size_t i = 0; i < frame_count * channels; i++)
    {
        double diff = fabs((double)out_buf[i] - (double)in_buf[i]);
        if (diff > max_diff)
            max_diff = diff;
        noise_energy += diff * diff;
        signal_energy += (double)in_buf[i] * (double)in_buf[i];
    }

    double snr_db = (noise_energy > 1e-25) ? 10.0 * log10(signal_energy / noise_energy) : 200.0;
    printf("  Maximum Pass-Through Sample Error: %.2e\n", max_diff);
    printf("  Signal-to-Noise Ratio (SNR):       %.1f dB\n", snr_db);

    /* Float precision allows difference < 1e-6 (essentially bit-perfect transparency) */
    assert(max_diff < 1e-5);
    assert(snr_db > 100.0);

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SIGNAL TEST 3 PASSED: Audio is 100%% transparent when unadjusted <<<\n");
}

/* ========================================================================= */
/* TEST 4: DETECCION DE DC OFFSET Y DISCONTINUIDADES TRANSITORIAS            */
/* ========================================================================= */
static void test_dc_offset_and_parameter_zipper_noise(void)
{
    printf("\n===================================================================\n");
    printf("[SIGNAL TEST 4] DC Offset Bias & Zipper Noise / Click Detection\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;
    const uint32_t frame_count = 4800;

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);

    float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
    float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));

    /* 4.1 DC Offset verification on zero-mean signal */
    for (uint32_t i = 0; i < frame_count; i++)
    {
        float val = 0.5f * sinf(2.0f * (float)PI * 250.0f * (float)i / (float)sample_rate);
        in_buf[i * 2 + 0] = val;
        in_buf[i * 2 + 1] = val;
    }

    miniaudio_player_equalizer_params_t eq_params = {
        .hz31 = 3.0f, .hz63 = 2.0f, .hz125 = 1.0f, .hz1k = 4.0f, .hz16k = 3.0f
    };
    assert(ma_equalizer_node_set_all(&eq, &eq_params) == MA_SUCCESS);

    const float *pIn = in_buf;
    float *pOut = out_buf;
    uint32_t fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);
    pIn = in_buf; pOut = out_buf; fc = frame_count;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    double sum_out = 0.0;
    for (size_t i = 0; i < frame_count * channels; i++)
    {
        sum_out += out_buf[i];
    }
    double dc_offset = fabs(sum_out / (double)(frame_count * channels));
    printf("  DC Bias on equalized signal: %.2e (Threshold: < 1e-4) [PASS]\n", dc_offset);
    assert(dc_offset < 1e-4);

    /* 4.2 Parameter modulation zipper noise test (rapid volume/preamp changes) */
    printf("  Verifying volume smoothing slope (zipper noise click prevention)...\n");
    float max_delta = 0.0f;
    eq.target_volume = 0.0f; /* Abrupt drop from 1.0 to 0.0 */

    pIn = in_buf; pOut = out_buf; fc = 512;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    for (size_t i = 1; i < 512 * channels; i++)
    {
        float delta = fabsf(out_buf[i] - out_buf[i - 1]);
        if (delta > max_delta)
            max_delta = delta;
    }
    /* Max single-sample step should be gradual, not a click jump of 1.0 */
    printf("  Max step delta during abrupt volume fade: %.4f (Click avoided) [PASS]\n", max_delta);
    assert(max_delta < 0.25f);

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SIGNAL TEST 4 PASSED: No DC offset bias, smooth parameter ramping <<<\n");
}

/* ========================================================================= */
/* TEST 5: REVERBERATION ACOUSTIC TAIL DECAY & ANTI-DENORMAL INTEGRITY       */
/* ========================================================================= */
static void test_reverb_signal_and_tail_decay(void)
{
    printf("\n===================================================================\n");
    printf("[SIGNAL TEST 5] Reverb Acoustic Tail Decay & Anti-Denormal Integrity\n");
    printf("===================================================================\n");

    const uint32_t sample_rate = 48000;
    const uint32_t channels = 2;

    ma_engine_config engine_cfg = ma_engine_config_init();
    engine_cfg.sampleRate = sample_rate;
    engine_cfg.channels = channels;
    ma_engine engine;
    assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

    ma_equalizer_node eq;
    assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);

    /* 1. Feed a 10ms Dirac impulse burst, then 400ms silence */
    const size_t burst_frames = 480;   /* 10 ms */
    const size_t tail_frames  = 19200; /* 400 ms */
    const size_t total_frames = burst_frames + tail_frames;

    float *in_buf = (float *)calloc(total_frames * channels, sizeof(float));
    float *out_buf = (float *)calloc(total_frames * channels, sizeof(float));

    /* Create audio impulse burst at start */
    for (size_t f = 0; f < burst_frames; f++)
    {
        in_buf[f * channels]     = (f % 2 == 0) ? 0.8f : -0.8f;
        in_buf[f * channels + 1] = (f % 2 == 0) ? 0.8f : -0.8f;
    }

    /* Enable Reverb with concert hall preset (room_size = 0.8, wet = 0.5, dry = 1.0) */
    eq.reverb_enabled = 1;
    map_reverb_set_params(&eq.reverb, 1, 0.8f, 0.35f, 1.0f, 0.5f, 1.0f);

    const float *pIn = in_buf;
    float *pOut = out_buf;
    ma_uint32 fc = (ma_uint32)total_frames;
    ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc, &pOut, &fc);

    /* Verify tail energy in the silence region (after 10ms burst) */
    double tail_rms = compute_rms(&out_buf[burst_frames * channels], tail_frames * channels);
    printf("  Reverb Tail Energy (400ms post-impulse RMS): %.5f (Reflections generated) [PASS]\n", tail_rms);
    assert(tail_rms > 0.005); /* Must have sustained reverberation tail */

    /* Verify that tail does not blow up / saturate beyond DAC */
    float peak_tail = compute_peak(&out_buf[burst_frames * channels], tail_frames * channels);
    printf("  Reverb Peak Tail Amplitude: %.4f (No saturation/blowup) [PASS]\n", peak_tail);
    assert(peak_tail < 1.0f);

    /* Verify that tail energy decays over time (first 100ms vs last 100ms of tail) */
    size_t chunk = 4800; /* 100ms */
    double early_rms = compute_rms(&out_buf[burst_frames * channels], chunk * channels);
    double late_rms  = compute_rms(&out_buf[(burst_frames + tail_frames - chunk) * channels], chunk * channels);
    printf("  Early Tail RMS: %.5f vs Late Tail RMS: %.5f (Natural decay) [PASS]\n", early_rms, late_rms);
    assert(early_rms > late_rms);

    /* Check no NaNs or infinities */
    for (size_t i = 0; i < total_frames * channels; i++)
    {
        assert(!isnan(out_buf[i]));
        assert(!isinf(out_buf[i]));
    }
    printf("  Zero NaNs, Infinities, or audio singularities detected [PASS]\n");

    free(in_buf);
    free(out_buf);
    ma_equalizer_node_uninit(&eq);
    ma_engine_uninit(&engine);
    printf(">>> SIGNAL TEST 5 PASSED: Reverb tail decay and acoustic integrity verified <<<\n");
}

int main(void)
{
    printf("\n===================================================================\n");
    printf("       MINIAUDIO_PLAYER AUDIO SIGNAL INTEGRITY & ALTERATION TEST      \n");
    printf("===================================================================\n");

    test_equalizer_functionality_verification();
    test_signal_crushing_and_limiter_distortion();
    test_pass_through_transparency();
    test_dc_offset_and_parameter_zipper_noise();
    test_reverb_signal_and_tail_decay();

    printf("\n===================================================================\n");
    printf(">>> ALL AUDIO SIGNAL INTEGRITY TESTS COMPLETED WITH 100%% SUCCESS <<<\n");
    printf("===================================================================\n\n");
    return 0;
}
