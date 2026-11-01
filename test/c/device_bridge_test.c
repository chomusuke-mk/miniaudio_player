/**
 * @file device_bridge_test.c
 * @brief C11 hardware bridge verification suite for `miniaudio_device_bridge.c`.
 *
 * Tests exclusively the thin C hardware abstraction layer (`map_device_*`) over `miniaudio.h`
 * (with `MA_NO_DECODING`, `MA_NO_ENCODING`, `MA_NO_RESOURCE_MANAGER`, `MA_NO_NODE_GRAPH`, `MA_NO_ENGINE`):
 *   1. NULL-pointer and boundary guard contracts across all exported C functions.
 *   2. Playback and capture device enumeration and memory deallocation (`map_device_enumerate_*`).
 *   3. Playback device lifecycle (`create` -> `start` -> `rust_render_pcm_frames` callback -> `stop` -> `destroy`).
 *   4. Device selector fallback (`invalid_hex_id` -> `"auto"`) and hot-swap (`map_device_set_device`).
 *
 * Build & Run (with AddressSanitizer & UndefinedBehaviorSanitizer):
 *   cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
 *      -Irust/c_src test/c/device_bridge_test.c rust/c_src/miniaudio_device_bridge.c \
 *      -lpthread -lm -ldl -o /tmp/device_bridge_test && /tmp/device_bridge_test
 */

#define _DEFAULT_SOURCE
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "miniaudio_device_bridge.h"

typedef struct {
    atomic_uint render_calls;
    atomic_uint frames_rendered;
    atomic_uint capture_calls;
    atomic_int last_notification;
} bridge_test_state_t;

void rust_render_pcm_frames(void* user_data, float* output_frames, uint32_t frame_count) {
    if (output_frames != NULL && frame_count > 0) {
        memset(output_frames, 0, (size_t)frame_count * 2 * sizeof(float));
    }
    if (user_data != NULL) {
        bridge_test_state_t* st = (bridge_test_state_t*)user_data;
        atomic_fetch_add_explicit(&st->render_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&st->frames_rendered, frame_count, memory_order_relaxed);
    }
}

void rust_capture_pcm_frames(void* user_data, const float* input_frames, uint32_t frame_count) {
    (void)input_frames;
    (void)frame_count;
    if (user_data != NULL) {
        bridge_test_state_t* st = (bridge_test_state_t*)user_data;
        atomic_fetch_add_explicit(&st->capture_calls, 1, memory_order_relaxed);
    }
}

void rust_on_device_notification(void* user_data, int32_t notification_type) {
    if (user_data != NULL) {
        bridge_test_state_t* st = (bridge_test_state_t*)user_data;
        atomic_store_explicit(&st->last_notification, notification_type, memory_order_relaxed);
    }
}

static void sleep_ms(long ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static void test_null_pointer_contracts(void) {
    assert(map_device_start(NULL) == -2);
    assert(map_device_stop(NULL) == -2);
    assert(map_device_destroy(NULL) == 0);
    assert(map_device_get_sample_rate(NULL) == 0);
    assert(map_device_get_channels(NULL) == 0);
    assert(map_device_set_device(NULL, "auto") == -2);

    map_device_info_t info;
    assert(map_device_get_current_device_info(NULL, &info) == -2);

    map_device_info_t* devices = NULL;
    uint32_t count = 0;
    assert(map_device_enumerate_devices(NULL, &count) == -2);
    assert(map_device_enumerate_devices(&devices, NULL) == -2);
    assert(map_device_enumerate_capture_devices(NULL, &count) == -2);
    assert(map_device_enumerate_capture_devices(&devices, NULL) == -2);

    map_device_free_devices(NULL);
}

static void test_device_enumeration(void) {
    map_device_info_t* playback_devs = NULL;
    uint32_t playback_count = 0;
    int32_t res = map_device_enumerate_devices(&playback_devs, &playback_count);
    assert(res == 0);
    if (playback_count > 0) {
        assert(playback_devs != NULL);
        assert(strlen(playback_devs[0].name) > 0);
        assert(strlen(playback_devs[0].id) > 0);
    }
    map_device_free_devices(playback_devs);

    map_device_info_t* capture_devs = NULL;
    uint32_t capture_count = 0;
    int32_t cap_res = map_device_enumerate_capture_devices(&capture_devs, &capture_count);
    assert(cap_res == 0);
    map_device_free_devices(capture_devs);
}

static void test_playback_lifecycle_and_callback_bridge(void) {
    bridge_test_state_t state = {0};
    int32_t out_result = -1;

    /* Create with invalid device ID to verify deterministic fallback to "auto" */
    map_device_context_t* ctx = map_device_create(
        48000,
        2,
        512,
        "non_existent_device_id_fallback_to_auto",
        &state,
        &out_result
    );

    if (ctx == NULL) {
        /* Headless CI environment without an audio backend */
        printf("[SKIP] No audio playback backend available on this host (result=%d)\n", out_result);
        return;
    }

    assert(out_result == 0);
    assert(map_device_get_sample_rate(ctx) > 0);
    assert(map_device_get_channels(ctx) == 2);

    map_device_info_t info;
    memset(&info, 0, sizeof(info));
    assert(map_device_get_current_device_info(ctx, &info) == 0);
    assert(strcmp(info.id, "auto") == 0);
    assert(info.is_auto == 1);
    assert(info.is_default == 1);

    assert(map_device_start(ctx) == 0);
    sleep_ms(60);

    unsigned int calls = atomic_load_explicit(&state.render_calls, memory_order_relaxed);
    unsigned int frames = atomic_load_explicit(&state.frames_rendered, memory_order_relaxed);
    assert(calls > 0);
    assert(frames > 0);

    /* Hot-switch device back to "auto" while running */
    assert(map_device_set_device(ctx, "auto") == 0);
    sleep_ms(30);

    assert(map_device_stop(ctx) == 0);
    assert(map_device_destroy(ctx) == 0);
}

int main(void) {
    printf("Running C hardware bridge tests (test/c/device_bridge_test.c)...\n");
    test_null_pointer_contracts();
    test_device_enumeration();
    test_playback_lifecycle_and_callback_bridge();
    printf("All C hardware bridge tests passed!\n");
    return 0;
}
