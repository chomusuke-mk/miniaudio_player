#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <assert.h>
#include <stdatomic.h>

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_dsp.h"

#define PI 3.14159265358979323846

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
    if (atomic_load_explicit(&g_disallow_allocations, memory_order_seq_cst))
    {
        atomic_fetch_add_explicit(&g_forbidden_alloc_count, 1, memory_order_seq_cst);
    }
    __real_free(ptr);
}

/* ========================================================================= */
/* Test 1: Quantify Frequency Detuning across multiple valid sample rates     */
/* ========================================================================= */
static void test_frequency_detuning_verification(void)
{
    printf("\n===================================================================\n");
    printf("[CHALLENGE TEST 1] Visualizer Frequency Band Tuning & Octave Shift\n");
    printf("===================================================================\n");

    const uint32_t sample_rates[] = { 44100, 48000, 88200, 96000, 192000 };
    const uint32_t channels = 2;
    const uint32_t frame_count = 1024;

    for (size_t s_idx = 0; s_idx < sizeof(sample_rates) / sizeof(sample_rates[0]); s_idx++)
    {
        uint32_t sample_rate = sample_rates[s_idx];
        printf("\n--- Verifying Visualizer Tuning at %u Hz ---\n", sample_rate);

        ma_engine_config engine_cfg = ma_engine_config_init();
        engine_cfg.sampleRate = sample_rate;
        engine_cfg.channels = channels;
        ma_engine engine;
        assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

        ma_equalizer_node eq;
        assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);
        eq.visualizer_enabled = 1;

        float *in_buf = (float *)calloc(frame_count * channels, sizeof(float));
        float *out_buf = (float *)calloc(frame_count * channels, sizeof(float));

        int octave_shift_count = 0;

        for (int target_band = 0; target_band < 10; target_band++)
        {
            double freq = g_map_eq_frequencies[target_band];

            memset(&eq.visualizer_data, 0, sizeof(eq.visualizer_data));
            for (int b = 0; b < 10; b++) {
                eq.vis_bpf[b].s1 = 0.0f;
                eq.vis_bpf[b].s2 = 0.0f;
            }

            for (int buf = 0; buf < 30; buf++)
            {
                for (uint32_t i = 0; i < frame_count; i++)
                {
                    double t = (double)(buf * frame_count + i) / (double)sample_rate;
                    float val = 0.5f * (float)sin(2.0 * PI * freq * t);
                    in_buf[i * 2 + 0] = val;
                    in_buf[i * 2 + 1] = val;
                }
                const float *pIn = in_buf;
                float *pOut = out_buf;
                uint32_t fc_in = frame_count;
                uint32_t fc_out = frame_count;

                atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
                atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);
                ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc_in, &pOut, &fc_out);
                atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);
                assert(atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst) == 0);
            }

            int peak_band = -1;
            float max_energy = -1.0f;
            for (int b = 0; b < 10; b++)
            {
                if (eq.visualizer_data.bands[b] > max_energy)
                {
                    max_energy = eq.visualizer_data.bands[b];
                    peak_band = b;
                }
            }

            printf("  SR %6u Hz | Tone %7.1f Hz (Band %d): Peak Band %d (energy=%.4f), Target energy=%.4f\n",
                   sample_rate, freq, target_band, peak_band, max_energy, eq.visualizer_data.bands[target_band]);

            assert(peak_band == target_band);

            if (target_band < 9 && peak_band == target_band + 1) {
                octave_shift_count++;
            }
        }

        printf("  SR %u Hz - Total bands shifted by +1 octave: %d / 9 [PASS]\n", sample_rate, octave_shift_count);
        assert(octave_shift_count == 0);

        free(in_buf);
        free(out_buf);
        ma_equalizer_node_uninit(&eq);
        ma_engine_uninit(&engine);
    }
}

/* ========================================================================= */
/* Test 2: Odd frame counts and boundary sizes across all sample rates        */
/* ========================================================================= */
static void test_boundary_frame_counts(void)
{
    printf("\n===================================================================\n");
    printf("[CHALLENGE TEST 2] Odd Frame Counts & Boundary Sizes Across Sample Rates\n");
    printf("===================================================================\n");

    const uint32_t sample_rates[] = { 8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 192000 };
    const uint32_t channels = 2;

    const uint32_t test_sizes[] = {
        0, 1, 2, 3, 4, 5, 7, 13, 16, 31, 32, 63, 64, 65, 127, 128, 255, 256, 511, 512, 1023, 1024, 2048, 2049, 4096
    };

    for (size_t s_idx = 0; s_idx < sizeof(sample_rates) / sizeof(sample_rates[0]); s_idx++)
    {
        uint32_t sample_rate = sample_rates[s_idx];
        printf("\n--- Testing Sample Rate %6u Hz across %lu frame sizes ---\n",
               sample_rate, (unsigned long)(sizeof(test_sizes) / sizeof(test_sizes[0])));

        ma_engine_config engine_cfg = ma_engine_config_init();
        engine_cfg.sampleRate = sample_rate;
        engine_cfg.channels = channels;
        ma_engine engine;
        assert(ma_engine_init(&engine_cfg, &engine) == MA_SUCCESS);

        ma_equalizer_node eq;
        assert(ma_equalizer_node_init(&engine.nodeGraph, channels, sample_rate, &eq) == MA_SUCCESS);
        eq.visualizer_enabled = 1;

        for (size_t t = 0; t < sizeof(test_sizes) / sizeof(test_sizes[0]); t++)
        {
            uint32_t fc = test_sizes[t];
            float *buf = (fc > 0) ? (float *)calloc(fc * channels, sizeof(float)) : NULL;
            for (uint32_t i = 0; i < fc; i++) {
                buf[i * 2] = 0.3f;
                buf[i * 2 + 1] = 0.3f;
            }

            const float *pIn = buf;
            float *pOut = buf;
            uint32_t fc_in = fc;
            uint32_t fc_out = fc;

            /* Strict zero-allocation guard during real-time visualizer execution */
            atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
            atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);
            ma_equalizer_node_process_pcm_frames(&eq.baseNode, &pIn, &fc_in, &pOut, &fc_out);
            atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);
            int allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);
            assert(allocs == 0);

            /* Verify no NaN or Inf in visualizer metrics */
            assert(!isnan(eq.visualizer_data.rms));
            assert(!isinf(eq.visualizer_data.rms));
            assert(eq.visualizer_data.rms >= 0.0f);
            assert(!isnan(eq.visualizer_data.peak));
            assert(!isinf(eq.visualizer_data.peak));
            assert(eq.visualizer_data.peak >= 0.0f);
            for (int b = 0; b < 10; b++) {
                assert(!isnan(eq.visualizer_data.bands[b]));
                assert(!isinf(eq.visualizer_data.bands[b]));
                assert(eq.visualizer_data.bands[b] >= 0.0f);
            }

            if (buf) free(buf);
        }

        printf("  SR %6u Hz: PASS across all %lu frame sizes (0 RT heap allocs, 0 NaNs/Infs)\n",
               sample_rate, (unsigned long)(sizeof(test_sizes) / sizeof(test_sizes[0])));

        ma_equalizer_node_uninit(&eq);
        ma_engine_uninit(&engine);
    }
}

int main(void)
{
    printf("===================================================================\n");
    printf("   STARTING ADVERSARIAL VISUALIZER STRESS TEST HARNESS             \n");
    printf("===================================================================\n");

    test_frequency_detuning_verification();
    test_boundary_frame_counts();

    printf("\n===================================================================\n");
    printf(">>> ALL VISUALIZER ADVERSARIAL TESTS PASSED (100%% SUCCESS) <<<\n");
    printf("===================================================================\n");
    return 0;
}
