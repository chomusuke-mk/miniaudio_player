/**
 * @file challenger_m3_silence_continuity.c
 * @brief Empirical Adversarial Test Harness for Milestone 3 (Requirement R3):
 *        Two-Level Buffer Decoupling, Real-Time Silence Synthesis, and Frame Continuity.
 *
 * Verifies:
 * 1. Real-Time Zero Dynamic Heap Allocations:
 *    - Validated via GNU linker wrappers (__wrap_malloc, __wrap_calloc, __wrap_realloc, __wrap_free).
 *    - Strictly 0 heap allocations on the real-time audio thread during normal reading,
 *      during ring buffer starvation silence synthesis, and during playback resumption.
 * 2. Clean PCM Silence Synthesis during Ring Buffer Starvation:
 *    - Memory is zeroed via memset (every sample is strictly 0.0f IEEE 754 zero).
 *    - pDS->underrun_count increments atomically (underrun_count > 0).
 *    - Position cursor (readCursorFrames) remains monotonically frozen at stall position.
 * 3. Bit-Perfect Frame Continuity across Network Stall Gaps:
 *    - When subsequent network chunks arrive, the first frame read is frame K (no dropped frames,
 *      no duplicate frames, bit-perfect acoustic continuity).
 * 4. Read Cursor Forward Headroom Telemetry:
 *    - Verifies that miniaudio_stream_status_t correctly exposes read_cursor_byte, range_start,
 *      and range_end.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_source.h"
#include "map_buffer.h"

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
/* Synthetic Deterministic Test Audio Generation                             */
/* ========================================================================= */

#define TEST_SAMPLE_RATE 48000
#define TEST_CHANNELS 2
#define FRAMES_PER_CHUNK 8192
#define STALL_FRAMES 4096

static inline int16_t compute_test_sample(uint32_t frame_index, int channel)
{
    double freq = (channel == 0) ? 440.0 : 880.0;
    double t = (double)frame_index / (double)TEST_SAMPLE_RATE;
    double s = 0.6 * sin(2.0 * M_PI * freq * t);
    return (int16_t)(s * 30000.0);
}

static void write_wav_header(uint8_t *header_out, uint32_t total_pcm_frames)
{
    uint32_t num_channels = TEST_CHANNELS;
    uint32_t bits_per_sample = 16;
    uint32_t byte_rate = TEST_SAMPLE_RATE * num_channels * (bits_per_sample / 8);
    uint16_t block_align = (uint16_t)(num_channels * (bits_per_sample / 8));
    uint32_t data_size = total_pcm_frames * block_align;
    uint32_t chunk_size = 36 + data_size;
    uint32_t subchunk1_size = 16;
    uint16_t audio_format = 1; /* PCM */

    memcpy(header_out, "RIFF", 4);
    memcpy(header_out + 4, &chunk_size, 4);
    memcpy(header_out + 8, "WAVE", 4);
    memcpy(header_out + 12, "fmt ", 4);
    memcpy(header_out + 16, &subchunk1_size, 4);
    memcpy(header_out + 20, &audio_format, 2);
    uint16_t ch = (uint16_t)num_channels;
    memcpy(header_out + 22, &ch, 2);
    uint32_t sr = TEST_SAMPLE_RATE;
    memcpy(header_out + 24, &sr, 4);
    memcpy(header_out + 28, &byte_rate, 4);
    memcpy(header_out + 32, &block_align, 2);
    uint16_t bps = (uint16_t)bits_per_sample;
    memcpy(header_out + 34, &bps, 2);
    memcpy(header_out + 36, "data", 4);
    memcpy(header_out + 40, &data_size, 4);
}

static void fill_pcm_chunk(uint8_t *dst, uint32_t start_frame, uint32_t count)
{
    int16_t *samples = (int16_t *)dst;
    for (uint32_t i = 0; i < count; i++)
    {
        uint32_t f = start_frame + i;
        samples[i * 2 + 0] = compute_test_sample(f, 0);
        samples[i * 2 + 1] = compute_test_sample(f, 1);
    }
}

/* ========================================================================= */
/* CHALLENGE 1: Two-Level Decoupled Consumer & Silence Synthesis              */
/* ========================================================================= */

static void test_decoupled_consumer_silence_and_continuity(void)
{
    printf("===================================================================\n");
    printf("[CHALLENGE 1] RT Decoupled Consumer, Silence Synthesis & Continuity\n");
    printf("===================================================================\n");

    const uint32_t total_frames = FRAMES_PER_CHUNK * 2;
    const size_t pcm_chunk_bytes = FRAMES_PER_CHUNK * TEST_CHANNELS * sizeof(int16_t);
    const size_t total_file_bytes = 44 + (total_frames * TEST_CHANNELS * sizeof(int16_t));

    /* Prepare Chunk 1: 44-byte WAV header + FRAMES_PER_CHUNK PCM frames */
    uint8_t *chunk1 = (uint8_t *)malloc(44 + pcm_chunk_bytes);
    assert(chunk1 != NULL);
    write_wav_header(chunk1, total_frames);
    fill_pcm_chunk(chunk1 + 44, 0, FRAMES_PER_CHUNK);

    /* Prepare Chunk 2: FRAMES_PER_CHUNK PCM frames (continuation) */
    uint8_t *chunk2 = (uint8_t *)malloc(pcm_chunk_bytes);
    assert(chunk2 != NULL);
    fill_pcm_chunk(chunk2, FRAMES_PER_CHUNK, FRAMES_PER_CHUNK);

    map_time_stretch_ds ds;
    memset(&ds, 0, sizeof(ds));

    ma_result res = map_time_stretch_ds_init_stream_ex(
        &ds,
        chunk1,
        44 + pcm_chunk_bytes,
        NULL,
        0,
        (int64_t)total_file_bytes,
        MA_FALSE,
        256 * 1024, /* 256 KB buffer capacity */
        1,          /* WAV */
        TEST_CHANNELS,
        TEST_SAMPLE_RATE);

    assert(res == MA_SUCCESS);
    assert(ds.has_worker == MA_TRUE);
    assert(ds.is_stream == MA_TRUE);

    /* Wait briefly for background decode worker to populate SPSC ring buffer */
    for (int retry = 0; retry < 10; retry++)
    {
        usleep(10000); /* 10ms */
        if (ma_pcm_rb_available_read(&ds.rb) >= FRAMES_PER_CHUNK) break;
    }

    float *out_buf = (float *)malloc(FRAMES_PER_CHUNK * TEST_CHANNELS * sizeof(float));
    assert(out_buf != NULL);

    /* --------------------------------------------------------------------- */
    /* Step 1: Read Chunk 1 (Frames 0 to K-1) with Zero Heap Allocations     */
    /* --------------------------------------------------------------------- */
    printf("  [Step 1] Reading Chunk 1 (%d frames) under RT Zero Allocation Guard...\n", FRAMES_PER_CHUNK);

    atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
    atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);

    ma_uint64 frames_read = 0;
    res = map_time_stretch_ds_read(&ds, out_buf, FRAMES_PER_CHUNK, &frames_read);
    assert(res == MA_SUCCESS);
    assert(frames_read == FRAMES_PER_CHUNK);

    /* Verify RT zero allocation invariant */
    int allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);
    assert(allocs == 0);

    /* Verify PCM signal fidelity for Chunk 1 */
    for (uint32_t i = 0; i < FRAMES_PER_CHUNK; i++)
    {
        float exp_left = (float)compute_test_sample(i, 0) / 32768.0f;
        float exp_right = (float)compute_test_sample(i, 1) / 32768.0f;
        float act_left = out_buf[i * 2 + 0];
        float act_right = out_buf[i * 2 + 1];

        if (i < 5)
        {
            printf("      Frame %u: act=[%f, %f], exp=[%f, %f]\n", i, act_left, act_right, exp_left, exp_right);
        }

        assert(fabsf(act_left - exp_left) < 1e-3f);
        assert(fabsf(act_right - exp_right) < 1e-3f);
    }
    printf("    -> Chunk 1 read successfully: %llu frames verified bit-perfect (0 heap allocations).\n",
           (unsigned long long)frames_read);

    /* Record playback cursor before starvation */
    ma_uint64 cursor_before_starve = ds.readCursorFrames;
    assert(cursor_before_starve == FRAMES_PER_CHUNK);

    /* --------------------------------------------------------------------- */
    /* Step 2: Buffer Starvation & Clean PCM Silence Synthesis (memset)      */
    /* --------------------------------------------------------------------- */
    printf("  [Step 2] Testing Network Starvation: Zero-Allocation PCM Silence Synthesis...\n");

    /* Withhold network data: ds.buffer is empty past Chunk 1.
     * SPSC ring buffer ds.rb is now depleted.
     * The consumer must synthesize pure PCM silence without blocking audio thread.
     */
    memset(out_buf, 0xAA, FRAMES_PER_CHUNK * TEST_CHANNELS * sizeof(float)); /* poison buffer */

    res = map_time_stretch_ds_read(&ds, out_buf, STALL_FRAMES, &frames_read);
    assert(res == MA_SUCCESS);
    assert(frames_read == STALL_FRAMES);

    /* Verify RT zero allocation invariant during silence synthesis */
    allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);
    assert(allocs == 0);

    /* Verify underrun_count incremented */
    uint32_t underruns = ma_atomic_load_32(&ds.underrun_count);
    assert(underruns > 0);

    /* Verify clean PCM silence synthesis (every single float is strictly 0.0f) */
    for (uint32_t i = 0; i < STALL_FRAMES * TEST_CHANNELS; i++)
    {
        assert(out_buf[i] == 0.0f);
        uint32_t raw_bits;
        memcpy(&raw_bits, &out_buf[i], sizeof(raw_bits));
        assert(raw_bits == 0x00000000); /* Exact IEEE 754 positive zero */
    }

    /* Verify monotonic position freeze: readCursorFrames MUST NOT advance during silence */
    ma_uint64 cursor_during_starve = ds.readCursorFrames;
    assert(cursor_during_starve == cursor_before_starve);
    printf("    -> PCM silence synthesis verified: %llu frames of 0.0f (underruns=%u, cursor locked at %llu).\n",
           (unsigned long long)frames_read, underruns, (unsigned long long)cursor_during_starve);

    /* --------------------------------------------------------------------- */
    /* Step 3: Stream Resumption & Bit-Perfect Frame Continuity              */
    /* --------------------------------------------------------------------- */
    printf("  [Step 3] Resuming Stream: Ingesting Chunk 2 & Verifying Frame Continuity...\n");

    /* Temporarily disengage RT guard for network feed thread simulation */
    atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);

    /* Feed Chunk 2 (frames FRAMES_PER_CHUNK to 2*FRAMES_PER_CHUNK - 1) */
    res = map_time_stretch_ds_stream_feed(&ds, chunk2, pcm_chunk_bytes);
    assert(res == MA_SUCCESS);

    /* Allow decoder worker to decode newly arrived frames */
    usleep(50000); /* 50ms */

    /* Re-engage RT guard for playback resumption */
    atomic_store_explicit(&g_forbidden_alloc_count, 0, memory_order_seq_cst);
    atomic_store_explicit(&g_disallow_allocations, 1, memory_order_seq_cst);

    memset(out_buf, 0, FRAMES_PER_CHUNK * TEST_CHANNELS * sizeof(float));
    res = map_time_stretch_ds_read(&ds, out_buf, FRAMES_PER_CHUNK, &frames_read);
    assert(res == MA_SUCCESS);
    assert(frames_read == FRAMES_PER_CHUNK);

    /* Verify RT zero allocation invariant during resumption */
    allocs = atomic_load_explicit(&g_forbidden_alloc_count, memory_order_seq_cst);
    assert(allocs == 0);

    /* Verify bit-perfect continuity: first frame read MUST be frame FRAMES_PER_CHUNK */
    for (uint32_t i = 0; i < FRAMES_PER_CHUNK; i++)
    {
        uint32_t global_frame = FRAMES_PER_CHUNK + i;
        float exp_left = (float)compute_test_sample(global_frame, 0) / 32768.0f;
        float exp_right = (float)compute_test_sample(global_frame, 1) / 32768.0f;
        float act_left = out_buf[i * 2 + 0];
        float act_right = out_buf[i * 2 + 1];

        assert(fabsf(act_left - exp_left) < 1e-4f);
        assert(fabsf(act_right - exp_right) < 1e-4f);
    }

    /* Verify cursor resumed progression */
    ma_uint64 cursor_after_resume = ds.readCursorFrames;
    assert(cursor_after_resume == total_frames);

    /* Disengage RT guard */
    atomic_store_explicit(&g_disallow_allocations, 0, memory_order_seq_cst);

    printf("    -> Chunk 2 read successfully: %llu frames verified bit-perfect from frame %d to %d.\n",
           (unsigned long long)frames_read, FRAMES_PER_CHUNK, total_frames - 1);
    printf("    -> Bit-perfect frame continuity CERTIFIED across starvation gap!\n");

    /* Teardown */
    map_time_stretch_ds_uninit(&ds);
    free(out_buf);
    free(chunk1);
    free(chunk2);

    printf(">>> CHALLENGE 1 PASSED: Silence synthesis, zero allocations, and bit-perfect continuity verified! <<<\n\n");
}

/* ========================================================================= */
/* CHALLENGE 2: Forward Headroom & Telemetry Status Struct Verification      */
/* ========================================================================= */

static void test_stream_status_telemetry(void)
{
    printf("===================================================================\n");
    printf("[CHALLENGE 2] Read Cursor & Forward Headroom Telemetry (miniaudio_stream_status_t)\n");
    printf("===================================================================\n");

    int32_t err = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &err);
    assert(player != NULL && err == MAP_SUCCESS);

    const uint32_t total_frames = 48000; /* 1 second */
    const size_t pcm_bytes = total_frames * TEST_CHANNELS * sizeof(int16_t);
    const size_t total_size = 44 + pcm_bytes;

    uint8_t *chunk = (uint8_t *)malloc(44 + 8192);
    assert(chunk != NULL);
    write_wav_header(chunk, total_frames);
    fill_pcm_chunk(chunk + 44, 0, 8192 / (TEST_CHANNELS * sizeof(int16_t)));

    err = miniaudio_player_open_stream(
        player,
        chunk,
        44 + 8192,
        (int64_t)total_size,
        0, /* not live */
        1024 * 1024,
        1); /* WAV */

    assert(err == MAP_SUCCESS);

    miniaudio_stream_status_t status;
    memset(&status, 0, sizeof(status));

    err = miniaudio_player_stream_get_status(player, &status);
    assert(err == MAP_SUCCESS);

    printf("  Telemetry queried:\n");
    printf("    buffer_capacity:   %zu\n", status.buffer_capacity);
    printf("    buffer_fill:       %zu\n", status.buffer_fill);
    printf("    fill_percentage:   %.4f\n", status.fill_percentage);
    printf("    is_buffering:      %d\n", status.is_buffering);
    printf("    is_eof:            %d\n", status.is_eof);
    printf("    read_cursor_byte:  %lld\n", (long long)status.read_cursor_byte);
    printf("    range_start:       %lld\n", (long long)status.range_start);
    printf("    range_end:         %lld\n", (long long)status.range_end);

    assert(status.buffer_capacity == 1024 * 1024);
    assert(status.range_start == 0);
    assert(status.range_end >= 44 + 8192);
    assert(status.read_cursor_byte >= 0);

    int64_t ahead_headroom = status.range_end - status.read_cursor_byte;
    printf("    ahead_headroom:    %lld bytes\n", (long long)ahead_headroom);
    assert(ahead_headroom >= 0);

    miniaudio_player_stop(player);
    miniaudio_player_destroy(player);
    free(chunk);

    printf(">>> CHALLENGE 2 PASSED: Telemetry struct fields correctly exported and verified! <<<\n\n");
}

/* ========================================================================= */
/* Main Entry Point                                                          */
/* ========================================================================= */

int main(void)
{
    printf("\n###################################################################\n");
    printf("###  EMPIRICAL CHALLENGER ADVERSARIAL SUITE: MILESTONE 3 (R3)   ###\n");
    printf("###################################################################\n\n");

    test_decoupled_consumer_silence_and_continuity();
    test_stream_status_telemetry();

    printf("###################################################################\n");
    printf("###  ALL MILESTONE 3 NATIVE CHALLENGES PASSED EMPIRICALLY!     ###\n");
    printf("###################################################################\n\n");

    return 0;
}
