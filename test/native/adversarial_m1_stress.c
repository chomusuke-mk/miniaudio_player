/**
 * @file adversarial_m1_stress.c
 * @brief Adversarial C stress-test suite for Milestone 1 (Lifecycle & Concurrency).
 *
 * Rigorously challenges:
 *  1. Rapid lifecycle: 100 consecutive create/destroy cycles under ASan/UBSan.
 *  2. Multi-instance concurrency: 4 independent players running concurrently with zero crosstalk.
 *  3. Mid-playback destruction: Destroying active instances during active PCM streaming.
 *  4. High-frequency concurrent operations on the same player instance.
 *  5. End-of-stream callback stress and teardown races.
 *  6. Boundary conditions, extreme audio parameters, and corrupted inputs.
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
#include <time.h>
#include <errno.h>

#include "miniaudio_player.h"

#define TEST_SAMPLE_RATE 44100
#define NUM_CONCURRENT_PLAYERS 4
#define TOTAL_LIFECYCLE_CYCLES 100

static const char *G_NORMAL_WAV = "/tmp/adv_m1_normal_1000ms.wav";
static const char *G_SHORT_WAV = "/tmp/adv_m1_short_100ms.wav";
static const char *G_CORRUPT_WAV = "/tmp/adv_m1_corrupt.wav";
static const char *G_EMPTY_WAV = "/tmp/adv_m1_empty.wav";

/* Helper: Generate a valid 16-bit PCM RIFF WAV file */
static void generate_wav(const char *path, uint32_t sample_rate, uint32_t duration_ms, float freq_hz)
{
    FILE *f = fopen(path, "wb");
    if (!f)
    {
        fprintf(stderr, "Failed to create WAV file: %s\n", path);
        exit(1);
    }

    uint32_t num_frames = (sample_rate * duration_ms) / 1000;
    uint16_t num_channels = 2;
    uint16_t bits_per_sample = 16;
    uint32_t byte_rate = sample_rate * num_channels * (bits_per_sample / 8);
    uint16_t block_align = num_channels * (bits_per_sample / 8);
    uint32_t data_size = num_frames * block_align;
    uint32_t chunk_size = 36 + data_size;

    /* RIFF Header */
    fwrite("RIFF", 1, 4, f);
    fwrite(&chunk_size, 4, 1, f);
    fwrite("WAVE", 1, 4, f);

    /* "fmt " Subchunk */
    fwrite("fmt ", 1, 4, f);
    uint32_t subchunk1_size = 16;
    uint16_t audio_format = 1; /* PCM */
    fwrite(&subchunk1_size, 4, 1, f);
    fwrite(&audio_format, 2, 1, f);
    fwrite(&num_channels, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bits_per_sample, 2, 1, f);

    /* "data" Subchunk */
    fwrite("data", 1, 4, f);
    fwrite(&data_size, 4, 1, f);

    /* Stereo sine wave samples */
    for (uint32_t i = 0; i < num_frames; i++)
    {
        double t = (double)i / (double)sample_rate;
        int16_t sample = (int16_t)(sin(2.0 * 3.141592653589793 * (double)freq_hz * t) * 16384.0);
        fwrite(&sample, 2, 1, f);
        fwrite(&sample, 2, 1, f);
    }

    fclose(f);
}

/* ========================================================================= */
/* TEST 1: Rapid Lifecycle (100 consecutive create/destroy cycles)           */
/* ========================================================================= */

static void test_rapid_lifecycle(void)
{
    printf("[CHALLENGE 1/6] Running 100 consecutive rapid create/destroy cycles...\n");

    for (int cycle = 0; cycle < TOTAL_LIFECYCLE_CYCLES; cycle++)
    {
        int32_t res = 0;
        miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
        assert(player != NULL);
        assert(res == MAP_SUCCESS);

        int phase = cycle % 4;
        if (phase == 0)
        {
            /* Create and immediately destroy without loading media */
            int32_t d_res = miniaudio_player_destroy(player);
            assert(d_res == MAP_SUCCESS);
        }
        else if (phase == 1)
        {
            /* Create -> open file -> immediately destroy without play */
            int32_t open_res = miniaudio_player_open_file(player, G_NORMAL_WAV);
            assert(open_res == MAP_SUCCESS);
            int32_t d_res = miniaudio_player_destroy(player);
            assert(d_res == MAP_SUCCESS);
        }
        else if (phase == 2)
        {
            /* Create -> open file -> play -> sleep 5ms -> destroy while streaming */
            int32_t open_res = miniaudio_player_open_file(player, G_NORMAL_WAV);
            assert(open_res == MAP_SUCCESS);
            int32_t play_res = miniaudio_player_play(player);
            assert(play_res == MAP_SUCCESS);
            usleep(5000); /* 5ms active audio rendering */
            int32_t d_res = miniaudio_player_destroy(player);
            assert(d_res == MAP_SUCCESS);
        }
        else
        {
            /* Create -> open file -> play -> pause -> seek -> stop -> destroy */
            int32_t open_res = miniaudio_player_open_file(player, G_NORMAL_WAV);
            assert(open_res == MAP_SUCCESS);
            assert(miniaudio_player_play(player) == MAP_SUCCESS);
            assert(miniaudio_player_pause(player) == MAP_SUCCESS);
            assert(miniaudio_player_seek(player, 350) == MAP_SUCCESS);
            assert(miniaudio_player_stop(player) == MAP_SUCCESS);
            assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
        }

        if ((cycle + 1) % 25 == 0)
        {
            printf("      -> Completed %d / %d cycles successfully\n", cycle + 1, TOTAL_LIFECYCLE_CYCLES);
        }
    }

    printf("      -> PASSED: 100 consecutive create/destroy cycles with zero leaks!\n");
}

/* ========================================================================= */
/* TEST 2: Multi-Instance Concurrency (4 independent instances)             */
/* ========================================================================= */

typedef struct
{
    int instance_id;
    float assigned_volume;
    float assigned_rate;
    float assigned_pitch;
    float assigned_eq_gain;
    uint32_t assigned_eq_band;
    int operations_completed;
    int crosstalk_violations;
} concurrency_worker_data_t;

static void *concurrency_worker(void *arg)
{
    concurrency_worker_data_t *data = (concurrency_worker_data_t *)arg;
    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL);
    assert(res == MAP_SUCCESS);

    res = miniaudio_player_open_file(player, G_NORMAL_WAV);
    assert(res == MAP_SUCCESS);

    /* Apply instance-specific parameters */
    assert(miniaudio_player_set_volume(player, data->assigned_volume) == MAP_SUCCESS);
    assert(miniaudio_player_set_rate(player, data->assigned_rate) == MAP_SUCCESS);
    assert(miniaudio_player_set_pitch(player, data->assigned_pitch) == MAP_SUCCESS);
    assert(miniaudio_player_set_equalizer_band(player, data->assigned_eq_band, data->assigned_eq_gain) == MAP_SUCCESS);

    assert(miniaudio_player_play(player) == MAP_SUCCESS);

    /* Perform 150 fast interleaved operations, validating state isolation */
    for (int op = 0; op < 150; op++)
    {
        int act = op % 6;
        if (act == 0)
        {
            miniaudio_player_pause(player);
        }
        else if (act == 1)
        {
            miniaudio_player_play(player);
        }
        else if (act == 2)
        {
            int64_t target_ms = (op * 7) % 900;
            miniaudio_player_seek(player, target_ms);
        }
        else if (act == 3)
        {
            miniaudio_player_set_volume(player, data->assigned_volume);
        }
        else if (act == 4)
        {
            miniaudio_player_set_rate(player, data->assigned_rate);
        }
        else
        {
            miniaudio_player_set_equalizer_band(player, data->assigned_eq_band, data->assigned_eq_gain);
        }

        /* Continuous status validation: assert NO cross-talk */
        miniaudio_player_status_t status;
        if (miniaudio_player_get_status(player, &status) == MAP_SUCCESS)
        {
            if (fabs(status.volume - data->assigned_volume) > 0.001f)
            {
                fprintf(stderr, "CROSSTALK DETECTED on Instance %d: Volume expected %f but got %f\n",
                        data->instance_id, data->assigned_volume, status.volume);
                data->crosstalk_violations++;
            }
            if (fabs(status.rate - data->assigned_rate) > 0.001f)
            {
                fprintf(stderr, "CROSSTALK DETECTED on Instance %d: Rate expected %f but got %f\n",
                        data->instance_id, data->assigned_rate, status.rate);
                data->crosstalk_violations++;
            }
            if (fabs(status.pitch - data->assigned_pitch) > 0.001f)
            {
                fprintf(stderr, "CROSSTALK DETECTED on Instance %d: Pitch expected %f but got %f\n",
                        data->instance_id, data->assigned_pitch, status.pitch);
                data->crosstalk_violations++;
            }
            float *eq_bands = (float *)&status.equalizer;
            if (fabs(eq_bands[data->assigned_eq_band] - data->assigned_eq_gain) > 0.001f)
            {
                fprintf(stderr, "CROSSTALK DETECTED on Instance %d: EQ Band %u expected %f but got %f\n",
                        data->instance_id, data->assigned_eq_band, data->assigned_eq_gain, eq_bands[data->assigned_eq_band]);
                data->crosstalk_violations++;
            }
        }

        data->operations_completed++;
        usleep(1000); /* 1ms pacing */
    }

    assert(miniaudio_player_stop(player) == MAP_SUCCESS);
    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    return NULL;
}

static void test_multi_instance_concurrency(void)
{
    printf("[CHALLENGE 2/6] Running 4 independent player instances simultaneously...\n");
    pthread_t threads[NUM_CONCURRENT_PLAYERS];
    concurrency_worker_data_t worker_data[NUM_CONCURRENT_PLAYERS];

    /* Assign distinct, isolated configuration per instance */
    for (int i = 0; i < NUM_CONCURRENT_PLAYERS; i++)
    {
        worker_data[i].instance_id = i;
        worker_data[i].assigned_volume = 0.25f * (float)(i + 1);  /* 0.25, 0.50, 0.75, 1.00 */
        worker_data[i].assigned_rate = 0.8f + 0.2f * (float)i;    /* 0.8, 1.0, 1.2, 1.4 */
        worker_data[i].assigned_pitch = 0.75f + 0.25f * (float)i; /* 0.75, 1.0, 1.25, 1.5 */
        worker_data[i].assigned_eq_gain = (float)(i * 3.0 - 4.5); /* -4.5, -1.5, +1.5, +4.5 */
        worker_data[i].assigned_eq_band = (uint32_t)(i * 2 + 1);  /* Bands 1, 3, 5, 7 */
        worker_data[i].operations_completed = 0;
        worker_data[i].crosstalk_violations = 0;

        int rc = pthread_create(&threads[i], NULL, concurrency_worker, &worker_data[i]);
        assert(rc == 0);
    }

    for (int i = 0; i < NUM_CONCURRENT_PLAYERS; i++)
    {
        pthread_join(threads[i], NULL);
        assert(worker_data[i].crosstalk_violations == 0);
        assert(worker_data[i].operations_completed >= 150);
        printf("      -> Instance %d: %d concurrent operations, 0 crosstalk violations\n",
               i, worker_data[i].operations_completed);
    }

    printf("      -> PASSED: Multi-instance concurrency verified with 0 crosstalk or corruption!\n");
}

/* ========================================================================= */
/* TEST 3: Mid-Playback Destruction (Violent Teardown during Audio I/O)      */
/* ========================================================================= */

static void test_mid_playback_destruction(void)
{
    printf("[CHALLENGE 3/6] Stress testing mid-playback destruction (violent teardown)...\n");

    for (int iter = 0; iter < 20; iter++)
    {
        miniaudio_player_t *players[4];
        for (int i = 0; i < 4; i++)
        {
            int32_t res = 0;
            players[i] = miniaudio_player_create(NULL, &res);
            assert(players[i] != NULL);
            assert(res == MAP_SUCCESS);

            assert(miniaudio_player_open_file(players[i], G_NORMAL_WAV) == MAP_SUCCESS);
            assert(miniaudio_player_set_volume(players[i], 0.5f) == MAP_SUCCESS);
            assert(miniaudio_player_play(players[i]) == MAP_SUCCESS);
        }

        /* Allow audio threads to spin and stream frames for a short random duration */
        useconds_t delay = (useconds_t)(5000 + (iter * 1500) % 25000);
        usleep(delay);

        /* Destroy each player abruptly while actively playing */
        for (int i = 0; i < 4; i++)
        {
            int32_t d_res = miniaudio_player_destroy(players[i]);
            assert(d_res == MAP_SUCCESS);
        }

        if ((iter + 1) % 5 == 0)
        {
            printf("      -> Mid-playback teardown iteration %d / 20 complete\n", iter + 1);
        }
    }

    printf("      -> PASSED: 20 iterations of mid-playback teardown passed cleanly!\n");
}

/* ========================================================================= */
/* TEST 4: Concurrent Access on the SAME Player Handle                       */
/* ========================================================================= */

typedef struct
{
    miniaudio_player_t *player;
    volatile bool stop_flag;
    int queries_completed;
} hammer_worker_t;

static void *hammer_reader(void *arg)
{
    hammer_worker_t *hw = (hammer_worker_t *)arg;
    miniaudio_player_status_t status;
    while (!hw->stop_flag)
    {
        int32_t res = miniaudio_player_get_status(hw->player, &status);
        assert(res == MAP_SUCCESS);
        hw->queries_completed++;
        usleep(500); /* 0.5ms */
    }
    return NULL;
}

static void *hammer_writer(void *arg)
{
    hammer_worker_t *hw = (hammer_worker_t *)arg;
    int step = 0;
    while (!hw->stop_flag)
    {
        step++;
        if (step % 4 == 0)
        {
            miniaudio_player_set_volume(hw->player, 0.5f + (step % 5) * 0.1f);
        }
        else if (step % 4 == 1)
        {
            miniaudio_player_seek(hw->player, (step * 23) % 800);
        }
        else if (step % 4 == 2)
        {
            miniaudio_player_set_equalizer_band(hw->player, step % 10, (float)((step % 7) - 3));
        }
        else
        {
            miniaudio_player_set_rate(hw->player, 0.9f + (step % 3) * 0.2f);
        }
        usleep(800);
    }
    return NULL;
}

static void test_concurrent_same_handle_hammer(void)
{
    printf("[CHALLENGE 4/6] Hammering same player instance concurrently with reader & writer threads...\n");
    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL);
    assert(miniaudio_player_open_file(player, G_NORMAL_WAV) == MAP_SUCCESS);
    assert(miniaudio_player_play(player) == MAP_SUCCESS);

    hammer_worker_t hw;
    hw.player = player;
    hw.stop_flag = false;
    hw.queries_completed = 0;

    pthread_t r_thread, w_thread;
    pthread_create(&r_thread, NULL, hammer_reader, &hw);
    pthread_create(&w_thread, NULL, hammer_writer, &hw);

    /* Run concurrent race test for 300 milliseconds */
    usleep(300000);

    hw.stop_flag = true;
    pthread_join(r_thread, NULL);
    pthread_join(w_thread, NULL);

    assert(hw.queries_completed > 50);
    printf("      -> %d concurrent read queries completed during continuous mutation\n", hw.queries_completed);

    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    printf("      -> PASSED: Same-handle concurrency verified with zero deadlocks or corruption!\n");
}

/* ========================================================================= */
/* TEST 5: Completion Callback Stress & Teardown Race                        */
/* ========================================================================= */

typedef struct
{
    volatile int callback_count;
    pthread_mutex_t cb_lock;
} callback_context_t;

static void on_track_completed(void *user_data)
{
    callback_context_t *ctx = (callback_context_t *)user_data;
    pthread_mutex_lock(&ctx->cb_lock);
    ctx->callback_count++;
    pthread_mutex_unlock(&ctx->cb_lock);
}

static void test_completion_callback_and_race(void)
{
    printf("[CHALLENGE 5/6] Testing completion callback and destruction during EOF trigger...\n");

    for (int iter = 0; iter < 10; iter++)
    {
        callback_context_t ctx;
        ctx.callback_count = 0;
        pthread_mutex_init(&ctx.cb_lock, NULL);

        miniaudio_player_config_t config;
        memset(&config, 0, sizeof(config));
        config.on_completed = on_track_completed;
        config.user_data = &ctx;

        int32_t res = 0;
        miniaudio_player_t *player = miniaudio_player_create(&config, &res);
        assert(player != NULL);
        assert(res == MAP_SUCCESS);

        assert(miniaudio_player_open_file(player, G_SHORT_WAV) == MAP_SUCCESS);
        assert(miniaudio_player_play(player) == MAP_SUCCESS);

        /* Wait for track to near completion (G_SHORT_WAV is 100ms) */
        usleep(90000 + (iter * 3000)); /* ~90-117ms: close to or right at callback trigger */

        /* Destroy player right as completion callback occurs */
        assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
        pthread_mutex_destroy(&ctx.cb_lock);
    }

    printf("      -> PASSED: Completion callback teardown race handled cleanly!\n");
}

/* ========================================================================= */
/* TEST 6: Boundary Values, Corrupted Files & Malformed Inputs               */
/* ========================================================================= */

static void test_boundary_and_fuzz(void)
{
    printf("[CHALLENGE 6/6] Testing boundary values, corrupted files, and malformed inputs...\n");
    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL);

    /* 1. NULL pointer robustness */
    assert(miniaudio_player_destroy(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_open_file(NULL, G_NORMAL_WAV) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_open_file(player, NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_open_file(player, "") == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_play(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_pause(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_stop(NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_seek(NULL, 100) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_volume(NULL, 1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(NULL, 1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(NULL, 1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer(NULL, NULL) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(NULL, 0, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_get_status(NULL, NULL) == MAP_ERROR_INVALID_ARGS);

    /* 2. Operations on unloaded player */
    assert(miniaudio_player_play(player) == MAP_ERROR_INVALID_STATE);
    assert(miniaudio_player_pause(player) == MAP_ERROR_INVALID_STATE);
    assert(miniaudio_player_stop(player) == MAP_ERROR_INVALID_STATE);
    assert(miniaudio_player_seek(player, 500) == MAP_ERROR_INVALID_STATE);

    /* 3. Missing file */
    assert(miniaudio_player_open_file(player, "/tmp/this_file_does_not_exist_at_all.wav") == MAP_ERROR_FILE_NOT_FOUND);

    /* 4. Empty (0-byte) file */
    assert(miniaudio_player_open_file(player, G_EMPTY_WAV) == MAP_ERROR_DECODE_FAILED);

    /* 5. Corrupt file (random garbage) */
    assert(miniaudio_player_open_file(player, G_CORRUPT_WAV) == MAP_ERROR_DECODE_FAILED);

    /* 6. Directory passed as audio file */
    assert(miniaudio_player_open_file(player, "/tmp") != MAP_SUCCESS);

    /* 7. Load valid file */
    assert(miniaudio_player_open_file(player, G_NORMAL_WAV) == MAP_SUCCESS);

    /* 8. Extreme and invalid volume values */
    assert(miniaudio_player_set_volume(player, -0.01f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_volume(player, -100.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_volume(player, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_volume(player, INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_volume(player, -INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_volume(player, 0.0f) == MAP_SUCCESS);
    assert(miniaudio_player_set_volume(player, 2.0f) == MAP_SUCCESS);

    /* 9. Extreme and invalid rate values */
    assert(miniaudio_player_set_rate(player, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, -0.5f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_rate(player, 0.25f) == MAP_SUCCESS);
    assert(miniaudio_player_set_rate(player, 4.0f) == MAP_SUCCESS);

    /* 10. Extreme and invalid pitch values */
    assert(miniaudio_player_set_pitch(player, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, -1.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_pitch(player, 0.5f) == MAP_SUCCESS);
    assert(miniaudio_player_set_pitch(player, 2.0f) == MAP_SUCCESS);

    /* 11. Equalizer band index boundaries */
    assert(miniaudio_player_set_equalizer_band(player, 10, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(player, 999, 0.0f) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(player, 0, NAN) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(player, 0, INFINITY) == MAP_ERROR_INVALID_ARGS);
    assert(miniaudio_player_set_equalizer_band(player, 0, -50.0f) == MAP_SUCCESS); /* Clamps to -24 */
    assert(miniaudio_player_set_equalizer_band(player, 9, 50.0f) == MAP_SUCCESS);  /* Clamps to +24 */

    /* 12. Seeking boundaries */
    assert(miniaudio_player_seek(player, -500) == MAP_SUCCESS); /* Clamps to 0 */
    miniaudio_player_status_t st;
    assert(miniaudio_player_get_status(player, &st) == MAP_SUCCESS);
    assert(st.position_ms == 0);

    assert(miniaudio_player_seek(player, 999999) == MAP_SUCCESS); /* Beyond duration */
    assert(miniaudio_player_get_status(player, &st) == MAP_SUCCESS);
    assert(st.position_ms == st.duration_ms);
    assert(st.is_completed == 1);

    /* 13. Auto-rewind on play after completed */
    assert(miniaudio_player_play(player) == MAP_SUCCESS);
    assert(miniaudio_player_get_status(player, &st) == MAP_SUCCESS);
    assert(st.is_completed == 0);

    /* 14. Multiple file re-openings on same instance */
    for (int r = 0; r < 5; r++)
    {
        assert(miniaudio_player_open_file(player, G_NORMAL_WAV) == MAP_SUCCESS);
        assert(miniaudio_player_play(player) == MAP_SUCCESS);
        usleep(5000);
        assert(miniaudio_player_pause(player) == MAP_SUCCESS);
    }

    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    printf("      -> PASSED: Boundary and malformed inputs handled robustly!\n");
}

/* ========================================================================= */
/* MAIN ENTRY POINT                                                          */
/* ========================================================================= */

int main(void)
{
    printf("=================================================================\n");
    printf("   MINIAUDIO_PLAYER MILESTONE 1 ADVERSARIAL STRESS-TEST SUITE    \n");
    printf("=================================================================\n\n");

    /* Create test assets */
    printf("Preparing test WAV fixtures...\n");
    generate_wav(G_NORMAL_WAV, TEST_SAMPLE_RATE, 1000, 440.0f); /* 1000ms 440Hz sine */
    generate_wav(G_SHORT_WAV, TEST_SAMPLE_RATE, 100, 880.0f);   /* 100ms 880Hz sine */

    /* Empty 0-byte file */
    FILE *ef = fopen(G_EMPTY_WAV, "wb");
    assert(ef != NULL);
    fclose(ef);

    /* Corrupt file with pseudo-random garbage */
    FILE *cf = fopen(G_CORRUPT_WAV, "wb");
    assert(cf != NULL);
    uint8_t garbage[512];
    for (int i = 0; i < 512; i++)
        garbage[i] = (uint8_t)(i * 37 + 13);
    fwrite(garbage, 1, sizeof(garbage), cf);
    fclose(cf);

    printf("Fixtures ready. Commencing empirical verification...\n\n");

    test_rapid_lifecycle();
    test_multi_instance_concurrency();
    test_mid_playback_destruction();
    test_concurrent_same_handle_hammer();
    test_completion_callback_and_race();
    test_boundary_and_fuzz();

    /* Clean up fixtures */
    unlink(G_NORMAL_WAV);
    unlink(G_SHORT_WAV);
    unlink(G_EMPTY_WAV);
    unlink(G_CORRUPT_WAV);

    printf("\n=================================================================\n");
    printf(">>> ALL ADVERSARIAL CHALLENGES PASSED EMPIRICALLY WITH ZERO DEFECTS! <<<\n");
    printf("=================================================================\n");

    return 0;
}
