/**
 * @file test_sample_rate_adversarial.c
 * @brief Adversarial sample rate accuracy verification suite for miniaudio_player.
 *
 * Rigorously challenges:
 *  1. Disparate media rates: 44.1 kHz, 48 kHz, 22.05 kHz, 96 kHz, 88.2 kHz, 11.025 kHz, 192 kHz.
 *  2. Disparate engine rates: 48 kHz, 44.1 kHz, 96 kHz, 22.05 kHz.
 *  3. Explicit duration assertions (44.1 kHz 1000ms -> 1000ms +/- 1ms, NOT 918ms).
 *  4. Explicit seek assertions (44.1 kHz seek 500ms -> 500ms +/- 2ms, NOT 544ms).
 *  5. Active playback tracking across disparate rates.
 *  6. Boundary seeks (negative ms -> 0, past-end -> duration).
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <unistd.h>

#include "miniaudio_player.h"

static void generate_test_wav(
    const char *path,
    uint32_t sample_rate,
    uint32_t duration_ms,
    uint16_t channels,
    float freq_hz)
{
    FILE *f = fopen(path, "wb");
    assert(f != NULL);

    uint32_t num_frames = (uint32_t)(((uint64_t)sample_rate * duration_ms) / 1000);
    uint16_t bits_per_sample = 16;
    uint32_t byte_rate = sample_rate * channels * (bits_per_sample / 8);
    uint16_t block_align = channels * (bits_per_sample / 8);
    uint32_t data_size = num_frames * block_align;
    uint32_t chunk_size = 36 + data_size;

    fwrite("RIFF", 1, 4, f);
    fwrite(&chunk_size, 4, 1, f);
    fwrite("WAVE", 1, 4, f);

    fwrite("fmt ", 1, 4, f);
    uint32_t subchunk1_size = 16;
    uint16_t audio_format = 1; /* PCM */
    fwrite(&subchunk1_size, 4, 1, f);
    fwrite(&audio_format, 2, 1, f);
    fwrite(&channels, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bits_per_sample, 2, 1, f);

    fwrite("data", 1, 4, f);
    fwrite(&data_size, 4, 1, f);

    for (uint32_t i = 0; i < num_frames; i++)
    {
        double t = (double)i / (double)sample_rate;
        int16_t s = (int16_t)(sin(2.0 * M_PI * (double)freq_hz * t) * 16384.0);
        for (uint16_t c = 0; c < channels; c++)
        {
            fwrite(&s, 2, 1, f);
        }
    }
    fclose(f);
}

typedef struct
{
    uint32_t media_rate;
    uint32_t duration_ms;
    const char *path;
} test_fixture_t;

static const test_fixture_t g_fixtures[] = {
    {44100, 1000, "/tmp/adv_sr_44100_1000ms.wav"},
    {44100, 2500, "/tmp/adv_sr_44100_2500ms.wav"},
    {48000, 1000, "/tmp/adv_sr_48000_1000ms.wav"},
    {48000, 3000, "/tmp/adv_sr_48000_3000ms.wav"},
    {22050, 1000, "/tmp/adv_sr_22050_1000ms.wav"},
    {22050, 2500, "/tmp/adv_sr_22050_2500ms.wav"},
    {96000, 1000, "/tmp/adv_sr_96000_1000ms.wav"},
    {96000, 2000, "/tmp/adv_sr_96000_2000ms.wav"},
    {88200, 1000, "/tmp/adv_sr_88200_1000ms.wav"},
    {11025, 1000, "/tmp/adv_sr_11025_1000ms.wav"},
    {192000, 1000, "/tmp/adv_sr_192000_1000ms.wav"}};
#define NUM_FIXTURES (sizeof(g_fixtures) / sizeof(g_fixtures[0]))

static void setup_fixtures(void)
{
    for (size_t i = 0; i < NUM_FIXTURES; i++)
    {
        generate_test_wav(g_fixtures[i].path, g_fixtures[i].media_rate, g_fixtures[i].duration_ms, 2, 440.0f);
    }
}

static void teardown_fixtures(void)
{
    for (size_t i = 0; i < NUM_FIXTURES; i++)
    {
        unlink(g_fixtures[i].path);
    }
}

/* ========================================================================= */
/* TEST 1: Default Engine Rate (48kHz) vs All Disparate Media Rates          */
/* ========================================================================= */

static void test_default_engine_disparate_rates(void)
{
    printf("\n=== [TEST 1] Default Engine Rate vs Disparate Media Rates ===\n");

    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL);
    assert(res == MAP_SUCCESS);

    for (size_t i = 0; i < NUM_FIXTURES; i++)
    {
        const test_fixture_t *fix = &g_fixtures[i];
        printf("--- Testing %6u Hz Media (%u ms) ---\n", fix->media_rate, fix->duration_ms);

        res = miniaudio_player_open_file(player, fix->path);
        assert(res == MAP_SUCCESS);

        miniaudio_player_status_t status;
        res = miniaudio_player_get_status(player, &status);
        assert(res == MAP_SUCCESS);

        int64_t dur_api = miniaudio_player_get_duration_ms(player);
        assert(dur_api == status.duration_ms);

        printf("  Reported duration: %ld ms (Expected: %u ms)\n", (long)dur_api, fix->duration_ms);

        /* Strict duration assertion: +/- 1ms tolerance */
        if (labs(dur_api - (int64_t)fix->duration_ms) > 1)
        {
            fprintf(stderr, "FAIL: Duration mismatch for %u Hz! Expected %u ms, got %ld ms\n",
                    fix->media_rate, fix->duration_ms, (long)dur_api);
            assert(labs(dur_api - (int64_t)fix->duration_ms) <= 1);
        }

        /* Specific assertion for 44.1 kHz 1000ms: MUST NOT be 918ms */
        if (fix->media_rate == 44100 && fix->duration_ms == 1000)
        {
            assert(dur_api != 918);
            assert(dur_api >= 999 && dur_api <= 1001);
        }

        /* Seek tests: 25%, 50%, 75% of duration */
        int64_t seek_points[3] = {
            (int64_t)(fix->duration_ms * 0.25),
            (int64_t)(fix->duration_ms * 0.50),
            (int64_t)(fix->duration_ms * 0.75)};

        for (int s = 0; s < 3; s++)
        {
            int64_t target_ms = seek_points[s];
            res = miniaudio_player_seek(player, target_ms);
            assert(res == MAP_SUCCESS);

            res = miniaudio_player_get_status(player, &status);
            assert(res == MAP_SUCCESS);

            int64_t pos_api = miniaudio_player_get_position_ms(player);
            assert(pos_api == status.position_ms);

            printf("  Seek to %4ld ms -> Landed at %4ld ms (Diff: %ld ms)\n",
                   (long)target_ms, (long)pos_api, (long)labs(pos_api - target_ms));

            /* Strict seek landing assertion: +/- 2ms tolerance */
            if (labs(pos_api - target_ms) > 2)
            {
                fprintf(stderr, "FAIL: Seek target %ld ms missed for %u Hz! Landed at %ld ms\n",
                        (long)target_ms, fix->media_rate, (long)pos_api);
                assert(labs(pos_api - target_ms) <= 2);
            }

            /* Specific assertion for 44.1 kHz seek to 500ms: MUST NOT be 544ms */
            if (fix->media_rate == 44100 && target_ms == 500)
            {
                assert(pos_api != 544);
                assert(pos_api >= 498 && pos_api <= 502);
            }
        }

        /* Boundary Seek: Seek past EOF */
        res = miniaudio_player_seek(player, fix->duration_ms + 1000);
        assert(res == MAP_SUCCESS);
        res = miniaudio_player_get_status(player, &status);
        assert(res == MAP_SUCCESS);
        assert(status.position_ms == (int64_t)fix->duration_ms);
        assert(status.is_completed == 1);

        /* Boundary Seek: Seek negative */
        res = miniaudio_player_seek(player, -500);
        assert(res == MAP_SUCCESS);
        res = miniaudio_player_get_status(player, &status);
        assert(res == MAP_SUCCESS);
        assert(status.position_ms == 0);
        assert(status.is_completed == 0);
    }

    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    printf(">>> TEST 1 PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* TEST 2: Cross-Engine Sample Rate Matrix                                  */
/* ========================================================================= */

static void test_cross_engine_sample_rates(void)
{
    printf("\n=== [TEST 2] Cross-Engine Sample Rate Matrix ===\n");

    uint32_t engine_rates[] = {22050, 44100, 48000, 96000};
    size_t num_engine_rates = sizeof(engine_rates) / sizeof(engine_rates[0]);

    for (size_t e = 0; e < num_engine_rates; e++)
    {
        uint32_t eng_sr = engine_rates[e];
        printf("\n--- Initializing Engine with sample_rate = %u Hz ---\n", eng_sr);

        miniaudio_player_config_t config;
        memset(&config, 0, sizeof(config));
        config.sample_rate = eng_sr;
        config.channels = 2;

        int32_t res = 0;
        miniaudio_player_t *player = miniaudio_player_create(&config, &res);
        assert(player != NULL);
        assert(res == MAP_SUCCESS);

        for (size_t i = 0; i < NUM_FIXTURES; i++)
        {
            const test_fixture_t *fix = &g_fixtures[i];

            res = miniaudio_player_open_file(player, fix->path);
            assert(res == MAP_SUCCESS);

            miniaudio_player_status_t status;
            res = miniaudio_player_get_status(player, &status);
            assert(res == MAP_SUCCESS);

            int64_t dur = miniaudio_player_get_duration_ms(player);
            assert(labs(dur - (int64_t)fix->duration_ms) <= 1);

            /* Test 50% seek */
            int64_t half = fix->duration_ms / 2;
            res = miniaudio_player_seek(player, half);
            assert(res == MAP_SUCCESS);

            res = miniaudio_player_get_status(player, &status);
            assert(res == MAP_SUCCESS);
            assert(labs(status.position_ms - half) <= 2);
        }

        assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    }

    printf(">>> TEST 2 PASSED CLEANLY <<<\n");
}

/* ========================================================================= */
/* TEST 3: Active Playback Progression Across Disparate Media Rates         */
/* ========================================================================= */

static void test_active_playback_tracking(void)
{
    printf("\n=== [TEST 3] Active Playback Progression Across Disparate Media Rates ===\n");

    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL);
    assert(res == MAP_SUCCESS);

    /* Test 44.1 kHz, 48 kHz, 22.05 kHz, 96 kHz active playback progression */
    uint32_t rates[] = {44100, 48000, 22050, 96000};
    const char *paths[] = {
        "/tmp/adv_sr_44100_1000ms.wav",
        "/tmp/adv_sr_48000_1000ms.wav",
        "/tmp/adv_sr_22050_1000ms.wav",
        "/tmp/adv_sr_96000_1000ms.wav"};

    for (int i = 0; i < 4; i++)
    {
        printf("--- Playback tracking for %u Hz ---\n", rates[i]);
        res = miniaudio_player_open_file(player, paths[i]);
        assert(res == MAP_SUCCESS);

        res = miniaudio_player_play(player);
        assert(res == MAP_SUCCESS);

        /* Sleep 120ms to allow audio thread to render */
        usleep(120000);

        miniaudio_player_status_t st;
        res = miniaudio_player_get_status(player, &st);
        assert(res == MAP_SUCCESS);
        assert(st.is_playing == 1);

        printf("  Position after ~120ms: %ld ms\n", (long)st.position_ms);
        /* Position should have advanced realistically between 30ms and 300ms */
        assert(st.position_ms >= 30 && st.position_ms <= 300);

        res = miniaudio_player_pause(player);
        assert(res == MAP_SUCCESS);

        int64_t paused_pos = miniaudio_player_get_position_ms(player);
        usleep(50000);
        int64_t after_pause_pos = miniaudio_player_get_position_ms(player);
        /* Position must remain stable while paused */
        assert(paused_pos == after_pause_pos);

        res = miniaudio_player_stop(player);
        assert(res == MAP_SUCCESS);
        assert(miniaudio_player_get_position_ms(player) == 0);
    }

    assert(miniaudio_player_destroy(player) == MAP_SUCCESS);
    printf(">>> TEST 3 PASSED CLEANLY <<<\n");
}

int main(void)
{
    printf("===================================================================\n");
    printf("   STARTING ADVERSARIAL SAMPLE RATE ACCURACY TEST SUITE            \n");
    printf("===================================================================\n");

    setup_fixtures();

    test_default_engine_disparate_rates();
    test_cross_engine_sample_rates();
    test_active_playback_tracking();

    teardown_fixtures();

    printf("\n===================================================================\n");
    printf(">>> ALL SAMPLE RATE ACCURACY TESTS PASSED WITH 100%% SUCCESS! <<<\n");
    printf("===================================================================\n");
    return 0;
}
