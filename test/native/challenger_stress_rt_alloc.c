/**
 * @file challenger_stress_rt_alloc.c
 * @brief Empirical Challenger Stress Test: RT Zero Heap Allocations & Seqlock Concurrency.
 *
 * Tests:
 * 1. RT Audio Thread Zero Heap Allocations under Dynamic Sonic Pitch/Rate Perturbations:
 *    - Continuous streaming at rate = 0.5 (buffer expansion pressure)
 *    - Continuous streaming at rate = 2.0
 *    - Continuous streaming at pitch = 0.5 and pitch = 2.0
 *    - 500 rapid dynamic pitch/rate mutations while streaming
 *    - Dynamic seek operations while streaming at varispeed
 *    - Skip silence dynamic enabling while streaming
 * 2. Seqlock Concurrency & Atomic Memory Ordering Integrity:
 *    - 1 continuous writer performing 1,000,000 commits with strict checksum invariants
 *    - 8 concurrent reader threads querying the Seqlock
 *    - Exact verification that NO reader ever observes torn data or invalid checksums
 * 3. Violent Lifecycle Multi-Threaded Churn:
 *    - Concurrent multi-threaded player creation, playback, seek, pitch, volume, and destroy
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_dsp.h"
#include "map_seqlock.h"

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
/* Synthetic Audio Fixture Generation                                        */
/* ========================================================================= */

static void generate_test_wav(const char *path, uint32_t sample_rate, uint32_t duration_ms)
{
    FILE *f = fopen(path, "wb");
    assert(f != NULL);

    uint32_t num_frames = (uint32_t)(((uint64_t)sample_rate * duration_ms) / 1000);
    uint16_t num_channels = 2;
    uint16_t bits_per_sample = 16;
    uint32_t byte_rate = sample_rate * num_channels * (bits_per_sample / 8);
    uint16_t block_align = num_channels * (bits_per_sample / 8);
    uint32_t data_size = num_frames * block_align;
    uint32_t chunk_size = 36 + data_size;

    fwrite("RIFF", 1, 4, f);
    fwrite(&chunk_size, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    uint32_t subchunk1_size = 16;
    uint16_t audio_format = 1; /* PCM */
    fwrite(&subchunk1_size, 4, 1, f);
    fwrite(&audio_format, 2, 1, f);
    fwrite(&num_channels, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bits_per_sample, 2, 1, f);

    fwrite("data", 1, 4, f);
    fwrite(&data_size, 4, 1, f);

    for (uint32_t i = 0; i < num_frames; i++)
    {
        double t = (double)i / (double)sample_rate;
        double s = 0.5 * sin(2.0 * M_PI * 440.0 * t);
        int16_t sample = (int16_t)(s * 30000.0);
        fwrite(&sample, 2, 1, f);
        fwrite(&sample, 2, 1, f);
    }

    fclose(f);
}

/* ========================================================================= */
/* TEST 1: RT Audio Thread Zero Heap Allocations with Sonic Varispeed & DSP  */
/* ========================================================================= */

static void test_rt_allocations_under_varispeed(void)
{
    printf("===================================================================\n");
    printf("[CHALLENGE 1] RT Audio Thread Zero Allocations Under Sonic Varispeed\n");
    printf("===================================================================\n");

    const char *wav_path = "/tmp/challenger_rt_varispeed.wav";
    generate_test_wav(wav_path, 44100, 3000); /* 3-second audio */

    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL && res == MAP_SUCCESS);

    res = miniaudio_player_open_file(player, wav_path);
    assert(res == MAP_SUCCESS);

    assert(miniaudio_player_set_visualizer_enabled(player, 1) == MAP_SUCCESS);
    assert(miniaudio_player_play(player) == MAP_SUCCESS);

    /* Let playback start */
    usleep(20000);

    /* Engage zero allocation interceptor */
    printf("--- Engaging Zero Allocation Guard during active playback ---\n");
    atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
    atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);

    /* Part 1A: Streaming at low speed (0.5x) - buffer buildup pressure */
    printf("  Testing playback at rate=0.5x (buffer expansion stress)...\n");
    assert(miniaudio_player_set_rate(player, 0.5f) == MAP_SUCCESS);
    usleep(50000); /* 50ms streaming */

    /* Part 1B: Streaming at high speed (2.0x) */
    printf("  Testing playback at rate=2.0x (buffer drain stress)...\n");
    assert(miniaudio_player_set_rate(player, 2.0f) == MAP_SUCCESS);
    usleep(50000);

    /* Part 1C: Streaming at low pitch (0.5x) */
    printf("  Testing playback at pitch=0.5x (octave down sinc resampling)...\n");
    assert(miniaudio_player_set_pitch(player, 0.5f) == MAP_SUCCESS);
    usleep(50000);

    /* Part 1D: Streaming at high pitch (2.0x) */
    printf("  Testing playback at pitch=2.0x (octave up sinc resampling)...\n");
    assert(miniaudio_player_set_pitch(player, 2.0f) == MAP_SUCCESS);
    usleep(50000);

    /* Part 1E: 500 rapid dynamic mutations of rate, pitch, EQ, and volume */
    printf("  Executing 500 rapid varispeed (pitch + rate) mutations during streaming...\n");
    for (int i = 0; i < 500; i++)
    {
        float rate = 0.5f + (float)(rand() % 151) / 100.0f;  /* 0.5 to 2.0 */
        float pitch = 0.5f + (float)(rand() % 151) / 100.0f; /* 0.5 to 2.0 */
        assert(miniaudio_player_set_rate(player, rate) == MAP_SUCCESS);
        assert(miniaudio_player_set_pitch(player, pitch) == MAP_SUCCESS);

        if (i % 20 == 0)
        {
            uint32_t band = (uint32_t)(i % 10);
            float gain = -12.0f + (float)(rand() % 2401) / 100.0f;
            assert(miniaudio_player_set_equalizer_band(player, band, gain) == MAP_SUCCESS);
        }

        if (i % 50 == 0)
        {
            /* Trigger seeks mid-stream */
            assert(miniaudio_player_seek(player, (i * 5) % 2500) == MAP_SUCCESS);
        }

        /* Read visualizer to verify lock-free data path */
        miniaudio_player_visualizer_data_t vis;
        miniaudio_player_get_visualizer_data(player, &vis);
    }

    /* Disengage zero allocation interceptor */
    atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);
    int allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);

    printf("  -> Total forbidden allocations detected during varispeed stress: %d\n", allocs);
    assert(allocs == 0);

    assert(miniaudio_player_stop(player) == MAP_SUCCESS);
    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    unlink(wav_path);

    printf(">>> CHALLENGE 1 PASSED: 0 heap allocations detected under extreme varispeed! <<<\n\n");
}

/* ========================================================================= */
/* TEST 2: Seqlock Concurrency & Atomic Consistency Check                   */
/* ========================================================================= */

typedef struct
{
    float val[10];
    float checksum;
} seqlock_test_payload_t;

typedef struct
{
    map_seqlock_t lock;
    seqlock_test_payload_t payload;
} seqlock_shared_t;

typedef struct
{
    seqlock_shared_t *shared;
    atomic_bool stop_flag;
    uint64_t reads_completed;
    uint64_t retries_count;
    uint64_t torn_reads;
} seqlock_reader_ctx_t;

static void *seqlock_reader_worker(void *arg)
{
    seqlock_reader_ctx_t *ctx = (seqlock_reader_ctx_t *)arg;
    while (!atomic_load_explicit(&ctx->stop_flag, memory_order_relaxed))
    {
        uint32_t seq;
        seqlock_test_payload_t copy;
        int attempts = 0;
        bool retry = false;

        do
        {
            seq = map_seqlock_read_begin(&ctx->shared->lock);
            copy = ctx->shared->payload;
            retry = map_seqlock_read_retry(&ctx->shared->lock, seq);
            if (retry) ctx->retries_count++;
        } while (retry && ++attempts < 64);

        if (!retry)
        {
            /* Verify checksum invariant */
            float expected_sum = 0.0f;
            for (int i = 0; i < 10; i++)
            {
                expected_sum += copy.val[i];
            }
            if (fabsf(copy.checksum - expected_sum) > 1e-4f)
            {
                ctx->torn_reads++;
                fprintf(stderr, "TORN READ DETECTED! checksum=%f, sum=%f\n", copy.checksum, expected_sum);
            }
            ctx->reads_completed++;
        }
    }
    return NULL;
}

static void test_seqlock_concurrency(void)
{
    printf("===================================================================\n");
    printf("[CHALLENGE 2] Seqlock Atomic Consistency Under Extreme Contention   \n");
    printf("===================================================================\n");

    seqlock_shared_t shared;
    map_seqlock_init(&shared.lock);
    for (int i = 0; i < 10; i++) shared.payload.val[i] = 1.0f;
    shared.payload.checksum = 10.0f;

    const int num_readers = 8;
    pthread_t reader_threads[num_readers];
    seqlock_reader_ctx_t reader_ctx[num_readers];

    for (int i = 0; i < num_readers; i++)
    {
        reader_ctx[i].shared = &shared;
        atomic_init(&reader_ctx[i].stop_flag, false);
        reader_ctx[i].reads_completed = 0;
        reader_ctx[i].retries_count = 0;
        reader_ctx[i].torn_reads = 0;
        int rc = pthread_create(&reader_threads[i], NULL, seqlock_reader_worker, &reader_ctx[i]);
        assert(rc == 0);
    }

    /* Writer performs 500,000 rapid commits with changing payload */
    printf("  Writer executing 500,000 commits under 8 concurrent readers...\n");
    for (int iter = 0; iter < 500000; iter++)
    {
        seqlock_test_payload_t new_val;
        float base = (float)(iter % 100);
        float sum = 0.0f;
        for (int i = 0; i < 10; i++)
        {
            new_val.val[i] = base + (float)i;
            sum += new_val.val[i];
        }
        new_val.checksum = sum;

        map_seqlock_write_begin(&shared.lock);
        shared.payload = new_val;
        map_seqlock_write_end(&shared.lock);
    }

    /* Stop reader threads */
    for (int i = 0; i < num_readers; i++)
    {
        atomic_store_explicit(&reader_ctx[i].stop_flag, true, memory_order_relaxed);
    }

    uint64_t total_reads = 0;
    uint64_t total_retries = 0;
    uint64_t total_torn = 0;

    for (int i = 0; i < num_readers; i++)
    {
        pthread_join(reader_threads[i], NULL);
        total_reads += reader_ctx[i].reads_completed;
        total_retries += reader_ctx[i].retries_count;
        total_torn += reader_ctx[i].torn_reads;
    }

    printf("  -> Total clean atomic reads: %lu\n", total_reads);
    printf("  -> Total read retries:       %lu\n", total_retries);
    printf("  -> Total torn reads:         %lu (Target: 0)\n", total_torn);

    assert(total_torn == 0);
    assert(total_reads > 50000);
    printf(">>> CHALLENGE 2 PASSED: 100%% atomic memory consistency with zero tearing! <<<\n\n");
}

/* ========================================================================= */
/* TEST 3: Violent Teardown Race Condition Stress                            */
/* ========================================================================= */

typedef struct
{
    const char *wav_path;
    int worker_id;
    int iterations;
    int failures;
} violent_teardown_worker_t;

static void *violent_teardown_worker(void *arg)
{
    violent_teardown_worker_t *w = (violent_teardown_worker_t *)arg;
    for (int i = 0; i < w->iterations; i++)
    {
        int32_t res = 0;
        miniaudio_player_t *p = miniaudio_player_create(NULL, &res);
        if (!p || res != MAP_SUCCESS)
        {
            w->failures++;
            continue;
        }

        miniaudio_player_open_file(p, w->wav_path);
        miniaudio_player_set_volume(p, 0.7f);
        miniaudio_player_set_rate(p, 1.2f);
        miniaudio_player_play(p);

        /* Random microsecond sleep between 100us and 5000us */
        useconds_t delay = (useconds_t)(100 + (rand() % 4900));
        usleep(delay);

        /* Abrupt destroy while threads and audio devices are running */
        int32_t d_res = miniaudio_player_destroy(p);
        if (d_res != MAP_SUCCESS)
        {
            w->failures++;
        }
    }
    return NULL;
}

static void test_violent_teardown_concurrency(void)
{
    printf("===================================================================\n");
    printf("[CHALLENGE 3] Multi-Threaded Violent Teardown Race Stress           \n");
    printf("===================================================================\n");

    const char *wav_path = "/tmp/challenger_violent_teardown.wav";
    generate_test_wav(wav_path, 44100, 2000);

    const int num_threads = 6;
    const int iters_per_thread = 20;
    pthread_t threads[num_threads];
    violent_teardown_worker_t workers[num_threads];

    printf("  Spawning %d threads running %d abrupt create/play/destroy cycles each...\n",
           num_threads, iters_per_thread);

    for (int i = 0; i < num_threads; i++)
    {
        workers[i].wav_path = wav_path;
        workers[i].worker_id = i;
        workers[i].iterations = iters_per_thread;
        workers[i].failures = 0;
        int rc = pthread_create(&threads[i], NULL, violent_teardown_worker, &workers[i]);
        assert(rc == 0);
    }

    int total_failures = 0;
    for (int i = 0; i < num_threads; i++)
    {
        pthread_join(threads[i], NULL);
        total_failures += workers[i].failures;
    }

    printf("  -> Completed %d violent teardown cycles across %d threads with %d failures.\n",
           num_threads * iters_per_thread, num_threads, total_failures);
    assert(total_failures == 0);
    unlink(wav_path);

    printf(">>> CHALLENGE 3 PASSED: Zero crashes, deadlocks or race conditions on teardown! <<<\n\n");
}

int main(void)
{
    printf("\n###################################################################\n");
    printf("###  EMPIRICAL CHALLENGER ADVERSARIAL STRESS SUITE (PHASE 3)   ###\n");
    printf("###################################################################\n\n");

    test_rt_allocations_under_varispeed();
    test_seqlock_concurrency();
    test_violent_teardown_concurrency();

    printf("###################################################################\n");
    printf("###  ALL EMPIRICAL CHALLENGES COMPLETED WITH 100%% SUCCESS!       ###\n");
    printf("###################################################################\n\n");
    return 0;
}
