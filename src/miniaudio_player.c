/**
 * @file miniaudio_player.c
 * @brief Thread-safe, reentrant native audio engine coordinator and public API.
 */

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_seqlock.h"
#include "map_silence.h"
#include "map_dsp.h"
#include "map_source.h"
#include "map_device.h"
#include "map_analysis.h"
#include "sonic.h"

#if !defined(_WIN32)
#include <pthread.h>
#endif

#if !defined(MA_NO_LIBOPUS)
#include "decoders/libopus/miniaudio_libopus.h"
#endif

#if !defined(MA_NO_AAC)
#include "decoders/aac/miniaudio_aac.h"
#endif

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#include <stdarg.h>
#include <stddef.h>

#if defined(__ANDROID__)
#include <android/log.h>
#include <jni.h>
#include <dlfcn.h>
#include <strings.h>
#include <link.h>
#include <elf.h>
#endif

/* ========================================================================= */
/* Custom Decoder Backend Registry                                           */
/* ========================================================================= */

ma_decoding_backend_vtable *g_map_custom_decoders[4] = {NULL, NULL, NULL, NULL};
static int g_map_custom_decoders_initialized = 0;

ma_uint32 map_get_custom_decoder_count(void)
{
    ma_uint32 count = 0;
    if (!g_map_custom_decoders_initialized)
    {
#if !defined(MA_NO_LIBOPUS)
        if (ma_decoding_backend_libopus != NULL)
        {
            g_map_custom_decoders[count++] = ma_decoding_backend_libopus;
        }
#endif
#if !defined(MA_NO_AAC)
        if (ma_decoding_backend_aac != NULL)
        {
            g_map_custom_decoders[count++] = ma_decoding_backend_aac;
        }
#endif
        g_map_custom_decoders_initialized = 1;
    }
    else
    {
        while (count < 4 && g_map_custom_decoders[count] != NULL)
        {
            count++;
        }
    }
    return count;
}

/* ========================================================================= */
/* Logging Infrastructure                                                    */
/* ========================================================================= */

int32_t g_map_log_level = MAP_LOG_LEVEL_NONE;

MAP_API void miniaudio_player_set_log_level(int32_t level)
{
    g_map_log_level = level;
}

MAP_API int32_t miniaudio_player_get_log_level(void)
{
    return g_map_log_level;
}

void map_log_print(int32_t level, const char *tag, const char *fmt, ...)
{
    va_list args;
    const char *level_str;
    if (g_map_log_level < level)
        return;

    level_str = "DEBUG";
    if (level == MAP_LOG_LEVEL_ERROR)
        level_str = "ERROR";
    else if (level == MAP_LOG_LEVEL_WARNING)
        level_str = "WARN";
    else if (level == MAP_LOG_LEVEL_INFO)
        level_str = "INFO";
    else if (level == MAP_LOG_LEVEL_VERBOSE)
        level_str = "VERBOSE";

#if defined(__ANDROID__)
    android_LogPriority prio = ANDROID_LOG_DEBUG;
    if (level == MAP_LOG_LEVEL_ERROR)
        prio = ANDROID_LOG_ERROR;
    else if (level == MAP_LOG_LEVEL_WARNING)
        prio = ANDROID_LOG_WARN;
    else if (level == MAP_LOG_LEVEL_INFO)
        prio = ANDROID_LOG_INFO;
    else if (level == MAP_LOG_LEVEL_VERBOSE)
        prio = ANDROID_LOG_VERBOSE;

    va_start(args, fmt);
    __android_log_vprint(prio, "miniaudio_player", fmt, args);
    va_end(args);
#else
    fprintf(stderr, "[miniaudio_player][%s][%s] ", level_str, tag);
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
    fflush(stderr);
#endif
}

void map_miniaudio_log_callback(void *pUserData, ma_uint32 level, const char *pMessage)
{
    int32_t map_level;
    (void)pUserData;
    map_level = MAP_LOG_LEVEL_DEBUG;
    if (level == MA_LOG_LEVEL_ERROR)
        map_level = MAP_LOG_LEVEL_ERROR;
    else if (level == MA_LOG_LEVEL_WARNING)
        map_level = MAP_LOG_LEVEL_WARNING;
    else if (level == MA_LOG_LEVEL_INFO)
        map_level = MAP_LOG_LEVEL_INFO;

    if (g_map_log_level >= map_level)
    {
        map_log_print(map_level, "miniaudio", "%s", pMessage);
    }
}

/* ========================================================================= */
/* Player Internal Structure                                                 */
/* ========================================================================= */

struct miniaudio_player
{
    ma_engine engine;
    ma_resource_manager resource_manager;
    ma_bool32 has_resource_manager;
    uint32_t buffer_size;
    map_time_stretch_ds stretch_ds;
    miniaudio_player_silence_config_t silence_config;
    ma_sound sound;
    ma_bool32 sound_loaded;
    ma_equalizer_node eq_node;
    ma_mutex lock;
    miniaudio_player_playback_state_t state;
    ma_bool32 is_completed;
    ma_bool32 is_buffering;
    float volume;
    float rate;
    float pitch;
    miniaudio_player_equalizer_params_t eq_params;
    char *file_path;
    ma_uint32 sample_rate;
    ma_uint32 channels;
    int64_t duration_ms;
    uint32_t bitrate;
    miniaudio_player_completed_cb on_completed;
    void *user_data;
    ma_log log;
    ma_bool32 has_log;
    ma_context context;
    ma_bool32 has_context;
    miniaudio_device_info_t current_device;
    ma_device_id custom_device_id;
    ma_bool32 has_custom_device;
    MA_ATOMIC(4, ma_int32) needs_device_fallback;
    MA_ATOMIC(4, ma_int32) is_switching_device;
    int32_t device_changed;
};

/* End-of-sound callback executed on audio device thread */
static void miniaudio_player_on_sound_end(void *pUserData, ma_sound *pSound)
{
    miniaudio_player_t *player = (miniaudio_player_t *)pUserData;
    miniaudio_player_completed_cb cb = NULL;
    void *udata = NULL;
    (void)pSound;

    if (player == NULL)
        return;

    ma_mutex_lock(&player->lock);
    if (player->is_completed)
    {
        /* Idempotent guard: already completed, prevent duplicate triggers */
        ma_mutex_unlock(&player->lock);
        return;
    }
    player->is_completed = 1;
    player->state = MAP_PLAYBACK_STATE_COMPLETED;
    cb = player->on_completed;
    udata = player->user_data;
    ma_mutex_unlock(&player->lock);

    if (cb != NULL)
    {
        cb(udata);
    }
}

static miniaudio_player_device_notification_cb g_device_notification_cb = NULL;
static void *g_device_notification_user_data = NULL;

MAP_API void miniaudio_player_set_device_notification_callback(
    miniaudio_player_device_notification_cb on_device_notification,
    void *user_data)
{
    g_device_notification_cb = on_device_notification;
    g_device_notification_user_data = user_data;
}

/* Device notification callback for OS rerouting and hot-unplug detection */
static void map_miniaudio_device_notification(const ma_device_notification *pNotification)
{
    miniaudio_player_t *player;
    if (pNotification == NULL || pNotification->pDevice == NULL)
        return;
    /* In ma_engine, pDevice->pUserData points to pEngine */
    player = (miniaudio_player_t *)((char *)pNotification->pDevice->pUserData - offsetof(miniaudio_player_t, engine));
    if (player == NULL)
        return;

    if (pNotification->type == ma_device_notification_type_rerouted)
    {
        ma_device_info info;
        if (ma_device_get_info(pNotification->pDevice, ma_device_type_playback, &info) == MA_SUCCESS)
        {
            ma_mutex_lock(&player->lock);
            if (player->has_custom_device)
            {
                strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                if (player->custom_device_id.aaudio > 0 &&
                    (pNotification->pDevice->pContext == NULL || pNotification->pDevice->pContext->backend == ma_backend_aaudio || pNotification->pDevice->pContext->backend == ma_backend_opensl
#if defined(__ANDROID__)
                     || 1
#endif
                    ))
                {
                    snprintf(player->current_device.id, sizeof(player->current_device.id), "%d", (int)player->custom_device_id.aaudio);
                }
                else
                {
                    map_device_id_to_string(&info.id, player->current_device.id, sizeof(player->current_device.id));
                }
                player->current_device.is_default = info.isDefault;
                player->current_device.is_auto = 0;
            }
            else
            {
                strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                player->current_device.id[0] = '\0';
                player->current_device.is_default = 1;
                player->current_device.is_auto = 1;
            }
            player->device_changed = 1;
            ma_mutex_unlock(&player->lock);

            if (pNotification->pDevice != NULL && pNotification->pDevice->sampleRate > 0 &&
                pNotification->pDevice->sampleRate != player->eq_node.sampleRate)
            {
                ma_equalizer_node_set_sample_rate(&player->eq_node, pNotification->pDevice->sampleRate);
                ma_mutex_lock(&player->lock);
                player->sample_rate = pNotification->pDevice->sampleRate;
                ma_mutex_unlock(&player->lock);
            }

            map_log_print(MAP_LOG_LEVEL_INFO, "core", "device notification: rerouted to '%s'", player->current_device.name);
        }
    }
    else if (pNotification->type == ma_device_notification_type_stopped)
    {
        if (!ma_atomic_load_32(&player->is_switching_device) && player->has_custom_device)
        {
            map_log_print(MAP_LOG_LEVEL_WARNING, "core", "device notification: playback device stopped (unplugged/disconnected)");
            ma_atomic_store_32(&player->needs_device_fallback, 1);
        }
        else
        {
            map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "device notification: playback device stopped (switch in progress or default device)");
        }
    }

    if (g_device_notification_cb != NULL)
    {
        g_device_notification_cb(g_device_notification_user_data);
    }
}

/* Helper to apply/reconfigure output device without losing playback state */
static int32_t map_player_apply_device(miniaudio_player_t *player, const char *device_id)
{
    ma_device *pDevice;
    ma_context *pContext;
    ma_device_config dev_cfg;
    ma_device_id target_id;
    ma_device_info dev_info;
    ma_result res;
    ma_bool32 was_started;
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t buffer_size;
    miniaudio_player_playback_state_t state;
    ma_bool32 has_custom = MA_FALSE;
    miniaudio_device_info_t new_dev_info;

    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;
    pDevice = ma_engine_get_device(&player->engine);
    if (pDevice == NULL)
        return MAP_ERROR_INVALID_STATE;
    if (player->has_context)
    {
        pContext = &player->context;
    }
    else
    {
        pContext = pDevice->pContext;
    }
    if (pContext == NULL)
        return MAP_ERROR_INVALID_STATE;

    ma_atomic_store_32(&player->is_switching_device, 1);
#if defined(__ANDROID__)
    if (pContext->backend == ma_backend_aaudio)
    {
        ma_atomic_bool32_set(&pDevice->aaudio.isTearingDown, MA_TRUE);
    }
#endif

    ma_mutex_lock(&player->lock);
    channels = player->channels;
    sample_rate = player->sample_rate;
    buffer_size = player->buffer_size;
    state = player->state;
    ma_mutex_unlock(&player->lock);

    was_started = ma_device_is_started(pDevice);
    if (was_started)
    {
        ma_device_stop(pDevice);
    }

    dev_cfg = ma_device_config_init(ma_device_type_playback);
    dev_cfg.wasapi.usage = ma_wasapi_usage_pro_audio;
    dev_cfg.playback.format = ma_format_f32;
    dev_cfg.playback.channels = channels;
    dev_cfg.sampleRate = sample_rate;
    dev_cfg.dataCallback = pDevice->onData;
    dev_cfg.pUserData = pDevice->pUserData;
    dev_cfg.notificationCallback = map_miniaudio_device_notification;
    dev_cfg.periodSizeInFrames = buffer_size;
    dev_cfg.noPreSilencedOutputBuffer = MA_TRUE;
    dev_cfg.noClip = MA_FALSE;
    dev_cfg.resampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;

    if (!map_is_device_id_default(device_id))
    {
        if (map_string_to_device_id(device_id, &target_id) && map_is_device_connected(pContext, &target_id))
        {
            dev_cfg.playback.pDeviceID = &target_id;
            has_custom = MA_TRUE;
#if defined(__ANDROID__)
            /* Explicit non-default Android device routing: use conservative performance profile.
               This forces AAudio to use AudioStreamTrack (tryMMap = false), avoiding exclusive
               hardware MMAP conflicts and "requestStart() error = -898, stream was probably stolen". */
            dev_cfg.performanceProfile = ma_performance_profile_conservative;
#endif
        }
        else
        {
            map_log_print(MAP_LOG_LEVEL_WARNING, "core", "target device '%s' not found or disconnected, falling back to default", device_id);
            dev_cfg.playback.pDeviceID = NULL;
            has_custom = MA_FALSE;
            memset(&target_id, 0, sizeof(target_id));
        }
    }
    else
    {
        dev_cfg.playback.pDeviceID = NULL;
        has_custom = MA_FALSE;
        memset(&target_id, 0, sizeof(target_id));
    }

    ma_device_uninit(pDevice);
    res = ma_device_init(pContext, &dev_cfg, pDevice);
    if (res != MA_SUCCESS && dev_cfg.playback.pDeviceID != NULL)
    {
        map_log_print(MAP_LOG_LEVEL_WARNING, "core", "failed to init target device (res %d), falling back to default", res);
        dev_cfg.playback.pDeviceID = NULL;
        has_custom = MA_FALSE;
        res = ma_device_init(pContext, &dev_cfg, pDevice);
    }

    if (res != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "failed to reinit playback device: %d", res);
        ma_atomic_store_32(&player->is_switching_device, 0);
        return MAP_ERROR_GENERIC;
    }

    if (pDevice->sampleRate > 0 && pDevice->sampleRate != player->eq_node.sampleRate)
    {
        ma_equalizer_node_set_sample_rate(&player->eq_node, pDevice->sampleRate);
        ma_mutex_lock(&player->lock);
        player->sample_rate = pDevice->sampleRate;
        ma_mutex_unlock(&player->lock);
    }

    memset(&new_dev_info, 0, sizeof(new_dev_info));
    if (ma_device_get_info(pDevice, ma_device_type_playback, &dev_info) == MA_SUCCESS)
    {
        if (has_custom)
        {
            strncpy(new_dev_info.name, dev_info.name, sizeof(new_dev_info.name) - 1);
            new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
            if (target_id.aaudio > 0 &&
                (pContext->backend == ma_backend_aaudio || pContext->backend == ma_backend_opensl
#if defined(__ANDROID__)
                 || 1
#endif
                ))
            {
                snprintf(new_dev_info.id, sizeof(new_dev_info.id), "%d", (int)target_id.aaudio);
            }
            else
            {
                map_device_id_to_string(&dev_info.id, new_dev_info.id, sizeof(new_dev_info.id));
            }
            new_dev_info.is_default = dev_info.isDefault;
            new_dev_info.is_auto = 0;
        }
        else
        {
            strncpy(new_dev_info.name, dev_info.name, sizeof(new_dev_info.name) - 1);
            new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
            new_dev_info.id[0] = '\0';
            new_dev_info.is_default = 1;
            new_dev_info.is_auto = 1;
        }
    }
    else
    {
        strncpy(new_dev_info.name, "Default", sizeof(new_dev_info.name) - 1);
        new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
        new_dev_info.id[0] = '\0';
        new_dev_info.is_default = 1;
        new_dev_info.is_auto = 1;
    }

    ma_mutex_lock(&player->lock);
    player->has_custom_device = has_custom;
    player->custom_device_id = target_id;
    player->current_device = new_dev_info;
    player->device_changed = 1;
    ma_atomic_store_32(&player->needs_device_fallback, 0);
    ma_mutex_unlock(&player->lock);

    if (was_started || state == MAP_PLAYBACK_STATE_PLAYING)
    {
        res = ma_device_start(pDevice);
        if (res != MA_SUCCESS && has_custom)
        {
            map_log_print(MAP_LOG_LEVEL_WARNING, "core", "failed to start custom device '%s' (res %d), falling back to default", device_id, res);
#if defined(__ANDROID__)
            if (pContext->backend == ma_backend_aaudio)
            {
                ma_atomic_bool32_set(&pDevice->aaudio.isTearingDown, MA_TRUE);
            }
#endif
            dev_cfg.playback.pDeviceID = NULL;
            dev_cfg.performanceProfile = ma_performance_profile_low_latency;
            has_custom = MA_FALSE;
            memset(&target_id, 0, sizeof(target_id));
            ma_device_uninit(pDevice);
            if (ma_device_init(pContext, &dev_cfg, pDevice) == MA_SUCCESS)
            {
                if (pDevice->sampleRate > 0 && pDevice->sampleRate != player->eq_node.sampleRate)
                {
                    ma_equalizer_node_set_sample_rate(&player->eq_node, pDevice->sampleRate);
                    ma_mutex_lock(&player->lock);
                    player->sample_rate = pDevice->sampleRate;
                    ma_mutex_unlock(&player->lock);
                }
                if (ma_device_get_info(pDevice, ma_device_type_playback, &dev_info) == MA_SUCCESS)
                {
                    strncpy(new_dev_info.name, dev_info.name, sizeof(new_dev_info.name) - 1);
                    new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
                }
                else
                {
                    strncpy(new_dev_info.name, "Default", sizeof(new_dev_info.name) - 1);
                }
                new_dev_info.id[0] = '\0';
                new_dev_info.is_default = 1;
                new_dev_info.is_auto = 1;

                ma_mutex_lock(&player->lock);
                player->has_custom_device = 0;
                player->custom_device_id = target_id;
                player->current_device = new_dev_info;
                player->device_changed = 1;
                ma_atomic_store_32(&player->needs_device_fallback, 0);
                ma_mutex_unlock(&player->lock);

                ma_device_start(pDevice);
                ma_atomic_store_32(&player->is_switching_device, 0);
                map_log_print(MAP_LOG_LEVEL_INFO, "core", "playback device active (fallback): '%s' (default: %d)",
                              new_dev_info.name, new_dev_info.is_default);
                return MAP_SUCCESS;
            }
            ma_atomic_store_32(&player->is_switching_device, 0);
            return MAP_ERROR_GENERIC;
        }
    }

    ma_atomic_store_32(&player->is_switching_device, 0);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "playback device active: '%s' (default: %d)",
                  new_dev_info.name, new_dev_info.is_default);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Public Lifecycle API                                                      */
/* ========================================================================= */

MAP_API miniaudio_player_t *miniaudio_player_create(
    const miniaudio_player_config_t *config,
    int32_t *out_result)
{
    miniaudio_player_t *player;
    ma_engine_config engine_cfg;
    ma_result result;
    int32_t fail_result = MAP_ERROR_GENERIC;

    player = (miniaudio_player_t *)ma_aligned_malloc(sizeof(miniaudio_player_t), 64, NULL);
    if (player == NULL)
    {
        if (out_result)
            *out_result = MAP_ERROR_OUT_OF_MEMORY;
        return NULL;
    }
    memset(player, 0, sizeof(miniaudio_player_t));

    result = ma_mutex_init(&player->lock);
    if (result != MA_SUCCESS)
    {
        ma_aligned_free(player, NULL);
        if (out_result)
            *out_result = MAP_ERROR_GENERIC;
        return NULL;
    }

    /* Initialize default parameters */
    player->volume = 1.0f;
    player->rate = 1.0f;
    player->pitch = 1.0f;
    player->state = MAP_PLAYBACK_STATE_STOPPED;
    player->is_completed = 0;
    player->is_buffering = 0;
    player->sound_loaded = MA_FALSE;
    memset(&player->eq_params, 0, sizeof(player->eq_params));
    player->silence_config.mode = MAP_SILENCE_MODE_DISABLED;
    player->silence_config.threshold_db = -45.0f;
    player->silence_config.min_silence_duration_ms = 300;
    player->silence_config.padding_ms = 50;

    player->buffer_size = (config != NULL && config->period_size_in_frames > 0)
                              ? config->period_size_in_frames
                              : 1024;
    player->has_resource_manager = MA_FALSE;

    if (config != NULL)
    {
        player->on_completed = config->on_completed;
        player->user_data = config->user_data;
    }

    player->has_log = MA_FALSE;
    result = ma_log_init(NULL, &player->log);
    if (result == MA_SUCCESS)
    {
        ma_log_register_callback(&player->log, ma_log_callback_init(map_miniaudio_log_callback, player));
        player->has_log = MA_TRUE;
    }

    engine_cfg = ma_engine_config_init();
    if (player->has_log)
    {
        engine_cfg.pLog = &player->log;
    }

    player->has_context = MA_FALSE;
    {
        ma_context_config context_cfg = ma_context_config_init();
        if (player->has_log)
        {
            context_cfg.pLog = &player->log;
        }
        result = ma_context_init(NULL, 0, &context_cfg, &player->context);
        if (result == MA_SUCCESS)
        {
            player->has_context = MA_TRUE;
            engine_cfg.pContext = &player->context;
        }
    }

    if (config != NULL)
    {
        if (config->sample_rate > 0)
            engine_cfg.sampleRate = config->sample_rate;
        if (config->channels > 0)
            engine_cfg.channels = config->channels;
    }
#if defined(_WIN32)
    timeBeginPeriod(1); /* Ensure 1ms timer precision for decoder worker thread */
#endif
    engine_cfg.periodSizeInFrames = player->buffer_size;
    engine_cfg.notificationCallback = map_miniaudio_device_notification;
    engine_cfg.resourceManagerResampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
    engine_cfg.pitchResampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;

    if (config != NULL && !map_is_device_id_default(config->playback_device_id))
    {
        if (map_string_to_device_id(config->playback_device_id, &player->custom_device_id))
        {
            engine_cfg.pPlaybackDeviceID = &player->custom_device_id;
            player->has_custom_device = MA_TRUE;
        }
    }

    {
        ma_uint32 custom_count = map_get_custom_decoder_count();
        if (custom_count > 0)
        {
            ma_resource_manager_config rm_cfg = ma_resource_manager_config_init();
            if (player->has_log)
            {
                rm_cfg.pLog = &player->log;
            }
            rm_cfg.ppCustomDecodingBackendVTables = g_map_custom_decoders;
            rm_cfg.customDecodingBackendCount = custom_count;
            rm_cfg.resampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
            result = ma_resource_manager_init(&rm_cfg, &player->resource_manager);
            if (result == MA_SUCCESS)
            {
                player->has_resource_manager = MA_TRUE;
                engine_cfg.pResourceManager = &player->resource_manager;
            }
        }
    }

    result = ma_engine_init(&engine_cfg, &player->engine);
    if (result != MA_SUCCESS && engine_cfg.pPlaybackDeviceID != NULL)
    {
        map_log_print(MAP_LOG_LEVEL_WARNING, "core", "ma_engine_init failed with custom device (%d), retrying with default device", result);
        engine_cfg.pPlaybackDeviceID = NULL;
        player->has_custom_device = MA_FALSE;
        result = ma_engine_init(&engine_cfg, &player->engine);
    }
#if defined(__ANDROID__)
    if (result != MA_SUCCESS && player->has_context && player->context.backend == ma_backend_aaudio)
    {
        map_log_print(MAP_LOG_LEVEL_WARNING, "core", "ma_engine_init failed with AAudio (%d), retrying with OpenSL ES fallback", result);
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;

        ma_backend backends[1] = { ma_backend_opensl };
        ma_context_config ctx_cfg = ma_context_config_init();
        if (player->has_log)
            ctx_cfg.pLog = &player->log;
        if (ma_context_init(backends, 1, &ctx_cfg, &player->context) == MA_SUCCESS)
        {
            player->has_context = MA_TRUE;
            engine_cfg.pContext = &player->context;
            result = ma_engine_init(&engine_cfg, &player->engine);
        }
    }
#endif
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_engine_init failed: %d", result);
        fail_result = MAP_ERROR_ENGINE_INIT;
        goto cleanup_error;
    }

    player->sample_rate = ma_engine_get_sample_rate(&player->engine);
    player->channels = ma_engine_get_channels(&player->engine);

    /* Initialize composite equalizer node */
    result = ma_equalizer_node_init(&player->engine.nodeGraph, player->channels, player->sample_rate, &player->eq_node);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_equalizer_node_init failed: %d", result);
        ma_engine_uninit(&player->engine);
        fail_result = MAP_ERROR_NODE_FAILED;
        goto cleanup_error;
    }

    /* Attach equalizer output to engine master endpoint */
    result = ma_node_attach_output_bus(&player->eq_node.baseNode, 0, ma_engine_get_endpoint(&player->engine), 0);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_node_attach_output_bus failed: %d", result);
        ma_equalizer_node_uninit(&player->eq_node);
        ma_engine_uninit(&player->engine);
        fail_result = MAP_ERROR_NODE_FAILED;
        goto cleanup_error;
    }
    player->eq_node.limiter_enabled = 1;

    {
        ma_device *pDevice = ma_engine_get_device(&player->engine);
        if (pDevice != NULL)
        {
            ma_device_info info;
            if (ma_device_get_info(pDevice, ma_device_type_playback, &info) == MA_SUCCESS)
            {
                if (player->has_custom_device)
                {
                    strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                    player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                    if (player->custom_device_id.aaudio > 0 &&
                        (pDevice->pContext == NULL || pDevice->pContext->backend == ma_backend_aaudio || pDevice->pContext->backend == ma_backend_opensl
#if defined(__ANDROID__)
                         || 1
#endif
                        ))
                    {
                        snprintf(player->current_device.id, sizeof(player->current_device.id), "%d", (int)player->custom_device_id.aaudio);
                    }
                    else
                    {
                        map_device_id_to_string(&info.id, player->current_device.id, sizeof(player->current_device.id));
                    }
                    player->current_device.is_default = info.isDefault;
                    player->current_device.is_auto = 0;
                }
                else
                {
                    strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                    player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                    player->current_device.id[0] = '\0';
                    player->current_device.is_default = 1;
                    player->current_device.is_auto = 1;
                }
            }
            else
            {
                strncpy(player->current_device.name, "Default", sizeof(player->current_device.name) - 1);
                player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                player->current_device.id[0] = '\0';
                player->current_device.is_default = 1;
                player->current_device.is_auto = 1;
            }
        }
    }

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player created (rate=%u, ch=%u, period=%u, device='%s')",
                  player->sample_rate, player->channels, player->buffer_size, player->current_device.name);

    if (out_result)
        *out_result = MAP_SUCCESS;
    return player;

cleanup_error:
    if (player->has_resource_manager)
    {
        ma_resource_manager_uninit(&player->resource_manager);
        player->has_resource_manager = MA_FALSE;
    }
    if (player->has_log)
    {
        ma_log_uninit(&player->log);
        player->has_log = MA_FALSE;
    }
    if (player->has_context)
    {
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;
    }
#if defined(_WIN32)
    timeEndPeriod(1);
#endif
    ma_mutex_uninit(&player->lock);
    ma_aligned_free(player, NULL);
    if (out_result)
        *out_result = fail_result;
    return NULL;
}

MAP_API int32_t miniaudio_player_destroy(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player destroy initiated");

    ma_atomic_store_32(&player->is_switching_device, 1);

    ma_mutex_lock(&player->lock);

    /* Disarm callbacks and stop/uninit sound */
    player->on_completed = NULL;
    if (player->sound_loaded)
    {
        ma_sound_set_end_callback(&player->sound, NULL, NULL);
        ma_sound_stop(&player->sound);
        ma_sound_uninit(&player->sound);
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->sound_loaded = MA_FALSE;
    }

    ma_equalizer_node_uninit(&player->eq_node);

    if (player->file_path != NULL)
    {
        free(player->file_path);
        player->file_path = NULL;
    }

    ma_mutex_unlock(&player->lock);

    /* Stop and uninit engine outside the mutex to avoid deadlock with audio device thread */
    ma_engine_stop(&player->engine);
    ma_engine_uninit(&player->engine);

    if (player->has_resource_manager)
    {
        ma_resource_manager_uninit(&player->resource_manager);
        player->has_resource_manager = MA_FALSE;
    }

    if (player->has_log)
    {
        ma_log_uninit(&player->log);
        player->has_log = MA_FALSE;
    }

    if (player->has_context)
    {
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;
    }

#if defined(_WIN32)
    timeEndPeriod(1);
#endif

    ma_mutex_uninit(&player->lock);
    ma_aligned_free(player, NULL);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player destroy completed");
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Media Loading API                                                         */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_open_file(
    miniaudio_player_t *player,
    const char *file_path)
{
    ma_sound_config sound_cfg;
    ma_result result;
    FILE *f;
    long file_size;

    if (player == NULL || file_path == NULL || file_path[0] == '\0')
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_file: %s", file_path);

    /* Synchronous pre-validation: verify file exists and is non-empty */
#if defined(_WIN32)
    {
        wchar_t *wpath = map_utf8_to_wchar(file_path);
        if (wpath == NULL)
        {
            map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (invalid path): %s", file_path);
            return MAP_ERROR_FILE_NOT_FOUND;
        }
        f = _wfopen(wpath, L"rb");
        free(wpath);
    }
#else
    f = fopen(file_path, "rb");
#endif
    if (f == NULL)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (not found): %s", file_path);
        return MAP_ERROR_FILE_NOT_FOUND;
    }
    if (fseek(f, 0, SEEK_END) != 0)
    {
        fclose(f);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (fseek error): %s", file_path);
        return MAP_ERROR_DECODE_FAILED;
    }
    file_size = ftell(f);
    fclose(f);

    if (file_size <= 0)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (empty file): %s", file_path);
        return MAP_ERROR_DECODE_FAILED;
    }

    ma_mutex_lock(&player->lock);

    /* Unload any previous sound */
    if (player->sound_loaded)
    {
        ma_sound_set_end_callback(&player->sound, NULL, NULL);
        ma_sound_stop(&player->sound);
        ma_sound_uninit(&player->sound);
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->sound_loaded = MA_FALSE;
    }

    /* Initialize time stretch data source wrapping ma_decoder and sonic */
    result = map_time_stretch_ds_init(
        &player->stretch_ds,
        file_path,
        player->channels,
        player->sample_rate);
    if (result != MA_SUCCESS)
    {
        player->state = MAP_PLAYBACK_STATE_ERROR;
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file decoder init failed: %d (%s)", result, file_path);
        return (result == MA_DOES_NOT_EXIST) ? MAP_ERROR_FILE_NOT_FOUND : MAP_ERROR_DECODE_FAILED;
    }

    /* Apply cached rate (speed) and pitch */
    ma_spinlock_lock(&player->stretch_ds.lock);
    player->stretch_ds.speed = player->rate;
    player->stretch_ds.pitch = player->pitch;
    if (player->stretch_ds.sonic != NULL)
    {
        sonicSetSpeed(player->stretch_ds.sonic, player->rate);
        sonicSetPitch(player->stretch_ds.sonic, player->pitch);
    }
    map_silence_detector_set_config(&player->stretch_ds.silence, &player->silence_config);
    map_silence_detector_reset(&player->stretch_ds.silence, MA_TRUE);
    ma_spinlock_unlock(&player->stretch_ds.lock);

    sound_cfg = ma_sound_config_init();
    sound_cfg.pDataSource = &player->stretch_ds.base;
    sound_cfg.flags = MA_SOUND_FLAG_NO_SPATIALIZATION;
    sound_cfg.pInitialAttachment = &player->eq_node.baseNode;
    sound_cfg.initialAttachmentInputBusIndex = 0;
    sound_cfg.endCallback = miniaudio_player_on_sound_end;
    sound_cfg.pEndCallbackUserData = player;

    result = ma_sound_init_ex(&player->engine, &sound_cfg, &player->sound);
    if (result != MA_SUCCESS)
    {
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->state = MAP_PLAYBACK_STATE_ERROR;
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_init_ex failed: %d (%s)", result, file_path);
        return MAP_ERROR_DECODE_FAILED;
    }

    player->sound_loaded = MA_TRUE;
    player->is_completed = 0;
    player->is_buffering = 0;
    player->state = MAP_PLAYBACK_STATE_STOPPED;

    /* Master volume fader operates in DSP node; sound is kept at unity gain */
    ma_sound_set_volume(&player->sound, 1.0f);
    ma_spinlock_lock(&player->eq_node.lock);
    player->eq_node.target_volume = player->volume;
    player->eq_node.current_volume = player->volume;
    ma_spinlock_unlock(&player->eq_node.lock);

    /* Precise duration from underlying decoder */
    {
        ma_uint64 total_frames = player->stretch_ds.totalFrames;
        if (total_frames > 0 && player->stretch_ds.sampleRate > 0)
        {
            player->duration_ms = (int64_t)((double)total_frames * 1000.0 / player->stretch_ds.sampleRate + 0.5);
        }
        else
        {
            float len_sec = 0.0f;
            if (ma_sound_get_length_in_seconds(&player->sound, &len_sec) == MA_SUCCESS && len_sec >= 0.0f)
            {
                player->duration_ms = (int64_t)((double)len_sec * 1000.0 + 0.5);
            }
            else
            {
                player->duration_ms = 0;
            }
        }
    }

    /* Compute nominal audio bitrate in bits per second */
    if (player->duration_ms > 0 && file_size > 0)
    {
        player->bitrate = (uint32_t)(((uint64_t)file_size * 8000ULL) / (uint64_t)player->duration_ms);
    }
    else if (player->sample_rate > 0 && player->channels > 0)
    {
        player->bitrate = player->sample_rate * player->channels * 16;
    }
    else
    {
        player->bitrate = 0;
    }

    if (player->file_path != NULL)
    {
        free(player->file_path);
    }
    player->file_path = map_strdup(file_path);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_file success: dur=%lld ms, bitrate=%u bps (%s)",
                  (long long)player->duration_ms, player->bitrate, file_path);

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Playback Controls                                                         */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_play(miniaudio_player_t *player)
{
    ma_result result;
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "play command");

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    /* Auto-rewind if at end or marked completed */
    if (player->is_completed || ma_sound_at_end(&player->sound))
    {
        ma_sound_seek_to_pcm_frame(&player->sound, 0);
        player->is_completed = 0;
    }

    result = ma_sound_start(&player->sound);
    if (result != MA_SUCCESS)
    {
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_start failed: %d", result);
        return MAP_ERROR_GENERIC;
    }

    player->state = MAP_PLAYBACK_STATE_PLAYING;
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_pause(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "pause command");

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_sound_stop(&player->sound);
    player->state = MAP_PLAYBACK_STATE_PAUSED;
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_stop(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "stop command");

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_sound_stop(&player->sound);
    ma_sound_seek_to_pcm_frame(&player->sound, 0);
    if (player->sound.pDataSource != NULL)
    {
        ma_data_source_seek_to_pcm_frame(player->sound.pDataSource, 0);
    }
    ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
    player->is_completed = 0;
    player->state = MAP_PLAYBACK_STATE_STOPPED;
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_seek(miniaudio_player_t *player, int64_t position_ms)
{
    float seek_sec;
    ma_result result;

    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "seek to %lld ms", (long long)position_ms);

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    if (position_ms < 0)
        position_ms = 0;
    if (player->duration_ms > 0 && position_ms > player->duration_ms)
    {
        position_ms = player->duration_ms;
    }

    seek_sec = (float)((double)position_ms / 1000.0);
    result = ma_sound_seek_to_second(&player->sound, seek_sec);
    if (result != MA_SUCCESS)
    {
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_seek_to_second failed: %d", result);
        return MAP_ERROR_SEEK_FAILED;
    }

    if (position_ms >= player->duration_ms && player->duration_ms > 0)
    {
        ma_sound_stop(&player->sound);
        if (player->sound.pDataSource != NULL)
        {
            ma_uint64 total_frames = 0;
            if (ma_data_source_get_length_in_pcm_frames(player->sound.pDataSource, &total_frames) == MA_SUCCESS && total_frames > 0)
            {
                ma_data_source_seek_to_pcm_frame(player->sound.pDataSource, total_frames);
            }
        }
        ma_atomic_exchange_32(&player->sound.atEnd, MA_TRUE);
        player->is_completed = 1;
        player->state = MAP_PLAYBACK_STATE_COMPLETED;
    }
    else
    {
        ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
        player->is_completed = 0;
        if (player->state == MAP_PLAYBACK_STATE_COMPLETED)
        {
            player->state = MAP_PLAYBACK_STATE_PAUSED;
        }
    }

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Volume, Rate & Pitch Adjustments                                          */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_volume(miniaudio_player_t *player, float volume)
{
    if (player == NULL || isnan(volume) || isinf(volume) || volume < 0.0f)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_DEBUG, "dsp", "set_volume: %.2f", volume);

    ma_mutex_lock(&player->lock);
    player->volume = volume;
    ma_spinlock_lock(&player->eq_node.lock);
    player->eq_node.target_volume = volume;
    ma_spinlock_unlock(&player->eq_node.lock);
    if (player->sound_loaded)
    {
        ma_sound_set_volume(&player->sound, 1.0f);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_rate(miniaudio_player_t *player, float rate)
{
    if (player == NULL || isnan(rate) || isinf(rate) || rate <= 0.0f)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_DEBUG, "dsp", "set_rate: %.2f", rate);

    ma_mutex_lock(&player->lock);
    player->rate = rate;
    if (player->sound_loaded)
    {
        ma_spinlock_lock(&player->stretch_ds.lock);
        player->stretch_ds.speed = rate;
        if (player->stretch_ds.sonic != NULL)
        {
            sonicSetSpeed(player->stretch_ds.sonic, rate);
        }
        ma_spinlock_unlock(&player->stretch_ds.lock);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_pitch(miniaudio_player_t *player, float pitch)
{
    if (player == NULL || isnan(pitch) || isinf(pitch) || pitch <= 0.0f)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_DEBUG, "dsp", "set_pitch: %.2f", pitch);

    ma_mutex_lock(&player->lock);
    player->pitch = pitch;
    if (player->sound_loaded)
    {
        ma_spinlock_lock(&player->stretch_ds.lock);
        player->stretch_ds.pitch = pitch;
        if (player->stretch_ds.sonic != NULL)
        {
            sonicSetPitch(player->stretch_ds.sonic, pitch);
        }
        ma_spinlock_unlock(&player->stretch_ds.lock);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Buffer Size Configuration                                                 */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_buffer_size(miniaudio_player_t *player, uint32_t buffer_size_in_frames)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "set_buffer_size: %u frames", buffer_size_in_frames);

    ma_mutex_lock(&player->lock);
    player->buffer_size = buffer_size_in_frames;
    ma_mutex_unlock(&player->lock);

    return MAP_SUCCESS;
}

MAP_API uint32_t miniaudio_player_get_buffer_size(const miniaudio_player_t *player)
{
    uint32_t size;
    if (player == NULL)
        return 0;

    ma_mutex_lock((ma_mutex *)&player->lock);
    size = player->buffer_size;
    ma_mutex_unlock((ma_mutex *)&player->lock);

    return size;
}

/* ========================================================================= */
/* Device Selection API                                                      */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_device(
    miniaudio_player_t *player,
    const char *device_id)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;
    return map_player_apply_device(player, device_id);
}

MAP_API int32_t miniaudio_player_get_current_device(
    const miniaudio_player_t *player,
    miniaudio_device_info_t *out_device)
{
    miniaudio_player_t *mut_player;
    if (player == NULL || out_device == NULL)
        return MAP_ERROR_INVALID_ARGS;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    *out_device = mut_player->current_device;
    ma_mutex_unlock(&mut_player->lock);

    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Equalizer Controls                                                        */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_equalizer(
    miniaudio_player_t *player,
    const miniaudio_player_equalizer_params_t *eq)
{
    ma_result res;
    if (player == NULL || eq == NULL)
        return MAP_ERROR_INVALID_ARGS;

    if (isnan(eq->hz31) || isinf(eq->hz31) ||
        isnan(eq->hz63) || isinf(eq->hz63) ||
        isnan(eq->hz125) || isinf(eq->hz125) ||
        isnan(eq->hz250) || isinf(eq->hz250) ||
        isnan(eq->hz500) || isinf(eq->hz500) ||
        isnan(eq->hz1k) || isinf(eq->hz1k) ||
        isnan(eq->hz2k) || isinf(eq->hz2k) ||
        isnan(eq->hz4k) || isinf(eq->hz4k) ||
        isnan(eq->hz8k) || isinf(eq->hz8k) ||
        isnan(eq->hz16k) || isinf(eq->hz16k))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_mutex_lock(&player->lock);
    res = ma_equalizer_node_set_all(&player->eq_node, eq);
    if (res == MA_SUCCESS)
    {
        player->eq_params = *eq;
    }
    ma_mutex_unlock(&player->lock);
    return (res == MA_SUCCESS) ? MAP_SUCCESS : MAP_ERROR_NODE_FAILED;
}

MAP_API int32_t miniaudio_player_set_equalizer_band(
    miniaudio_player_t *player,
    uint32_t band_index,
    float gain_db)
{
    ma_result res;
    float *pBands;

    if (player == NULL || band_index >= MAP_EQ_BAND_COUNT ||
        isnan(gain_db) || isinf(gain_db))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_mutex_lock(&player->lock);
    res = ma_equalizer_node_set_band(&player->eq_node, band_index, gain_db);
    if (res == MA_SUCCESS)
    {
        pBands = (float *)&player->eq_params;
        pBands[band_index] = gain_db;
    }
    ma_mutex_unlock(&player->lock);
    return (res == MA_SUCCESS) ? MAP_SUCCESS : MAP_ERROR_NODE_FAILED;
}

/* ========================================================================= */
/* Advanced DSP Controls (ReplayGain, Preamp, Spatial, Balance, Limiter)     */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_replay_gain(
    miniaudio_player_t *player,
    float gain_db,
    float peak,
    float preamp_db,
    int32_t prevent_clipping)
{
    if (player == NULL || isnan(gain_db) || isinf(gain_db) ||
        isnan(peak) || isinf(peak) || isnan(preamp_db) || isinf(preamp_db))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.rg_config.gain_db = gain_db;
    player->eq_node.rg_config.peak = (peak > 0.0f) ? peak : 0.0f;
    player->eq_node.rg_config.preamp_db = preamp_db;
    player->eq_node.rg_config.prevent_clipping = prevent_clipping ? 1 : 0;
    player->eq_node.rg_config.enabled = 1;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_clear_replay_gain(miniaudio_player_t *player)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.rg_config.enabled = 0;
    player->eq_node.rg_config.gain_db = 0.0f;
    player->eq_node.rg_config.peak = 0.0f;
    player->eq_node.rg_config.preamp_db = 0.0f;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_preamp(miniaudio_player_t *player, float preamp_db)
{
    if (player == NULL || isnan(preamp_db) || isinf(preamp_db))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.preamp_db = preamp_db;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_balance(miniaudio_player_t *player, float pan)
{
    if (player == NULL || isnan(pan) || isinf(pan))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    if (pan < -1.0f) pan = -1.0f;
    if (pan > 1.0f) pan = 1.0f;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.balance = pan;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_mono(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.mono_enabled = (enabled != 0) ? 1 : 0;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_crossfeed(miniaudio_player_t *player, int32_t mode)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.crossfeed_mode = mode;
    if (mode == MAP_CROSSFEED_MOFFAT_BAUER)
    {
        map_bs2b_init(&player->eq_node.bs2b, player->sample_rate, MAP_BS2B_DEFAULT_CLEVEL);
    }
    else if (mode == MAP_CROSSFEED_CHU_MOY)
    {
        map_bs2b_init(&player->eq_node.bs2b, player->sample_rate, MAP_BS2B_CMOY_CLEVEL);
    }

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_spatializer(miniaudio_player_t *player, int32_t enabled, float width)
{
    if (player == NULL || isnan(width) || isinf(width))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    if (width < 1.0f) width = 1.0f;
    if (width > 2.0f) width = 2.0f;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.spatializer_enabled = (enabled != 0) ? 1 : 0;
    player->eq_node.spatializer_width = width;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_reverb(
    miniaudio_player_t *player,
    int32_t enabled,
    float room_size,
    float damping,
    float width,
    float wet,
    float dry)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.reverb_enabled = (enabled != 0) ? 1 : 0;
    map_reverb_set_params(&player->eq_node.reverb, enabled, room_size, damping, width, wet, dry);

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_limiter(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.limiter_enabled = (enabled != 0) ? 1 : 0;

    ma_spinlock_unlock(&player->eq_node.lock);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Silence Detection & Skipping Controls                                     */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_silence_config(
    miniaudio_player_t *player,
    const miniaudio_player_silence_config_t *config)
{
    if (player == NULL || config == NULL)
        return MAP_ERROR_INVALID_ARGS;

    if (config->mode < MAP_SILENCE_MODE_DISABLED || config->mode > MAP_SILENCE_MODE_ALL)
        return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);

    player->silence_config = *config;
    if (player->silence_config.threshold_db < -90.0f)
        player->silence_config.threshold_db = -90.0f;
    else if (player->silence_config.threshold_db > -10.0f)
        player->silence_config.threshold_db = -10.0f;

    if (player->silence_config.min_silence_duration_ms < 50)
        player->silence_config.min_silence_duration_ms = 50;
    else if (player->silence_config.min_silence_duration_ms > 5000)
        player->silence_config.min_silence_duration_ms = 5000;

    if (player->silence_config.padding_ms > player->silence_config.min_silence_duration_ms / 2)
        player->silence_config.padding_ms = player->silence_config.min_silence_duration_ms / 2;

    if (player->sound_loaded)
    {
        map_silence_detector *pDet = &player->stretch_ds.silence;
        ma_uint32 min_frames = (player->silence_config.min_silence_duration_ms * pDet->sample_rate) / 1000;
        ma_uint32 pad_frames = (player->silence_config.padding_ms * pDet->sample_rate) / 1000;
        ma_uint32 required = min_frames + pad_frames + 2048;

        float *new_buf = NULL;
        float *old_buf = NULL;

        /* Allocate outside spinlock */
        if (required > pDet->hold_buffer_capacity && pDet->channels > 0)
        {
            size_t new_size = required * pDet->channels * sizeof(float);
            new_buf = (float *)ma_aligned_malloc(new_size, 64, NULL);
            if (new_buf != NULL)
            {
                memset(new_buf, 0, new_size);
            }
        }

        /* Swap buffer pointers and update configuration under spinlock */
        ma_spinlock_lock(&player->stretch_ds.lock);
        map_silence_detector_set_config_buffers(pDet, &player->silence_config, new_buf, required, &old_buf);
        ma_spinlock_unlock(&player->stretch_ds.lock);

        /* Free outside spinlock */
        if (old_buf != NULL)
        {
            ma_aligned_free(old_buf, NULL);
        }
        else if (new_buf != NULL && pDet->hold_buffer != new_buf)
        {
            ma_aligned_free(new_buf, NULL);
        }
    }

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_get_silence_config(
    const miniaudio_player_t *player,
    miniaudio_player_silence_config_t *out_config)
{
    miniaudio_player_t *mut_player;
    if (player == NULL || out_config == NULL)
        return MAP_ERROR_INVALID_ARGS;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    *out_config = mut_player->silence_config;
    ma_mutex_unlock(&mut_player->lock);
    return MAP_SUCCESS;
}

MAP_API int64_t miniaudio_player_get_silence_saved_ms(const miniaudio_player_t *player)
{
    miniaudio_player_t *mut_player;
    int64_t saved_ms = 0;
    if (player == NULL)
        return 0;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    if (mut_player->sound_loaded)
    {
        ma_spinlock_lock(&mut_player->stretch_ds.lock);
        saved_ms = map_silence_detector_get_saved_ms(&mut_player->stretch_ds.silence);
        ma_spinlock_unlock(&mut_player->stretch_ds.lock);
    }
    ma_mutex_unlock(&mut_player->lock);
    return saved_ms;
}

/* ========================================================================= */
/* State Snapshot & Query API                                                */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_get_status(
    const miniaudio_player_t *player,
    miniaudio_player_status_t *out_status)
{
    miniaudio_player_t *mut_player;

    if (player == NULL || out_status == NULL)
        return MAP_ERROR_INVALID_ARGS;

    mut_player = (miniaudio_player_t *)player;
    memset(out_status, 0, sizeof(*out_status));

    ma_mutex_lock(&mut_player->lock);

    out_status->duration_ms = mut_player->duration_ms;
    out_status->volume = mut_player->volume;
    out_status->rate = mut_player->rate;
    out_status->pitch = mut_player->pitch;
    out_status->bitrate = mut_player->bitrate;
    out_status->equalizer = mut_player->eq_params;
    out_status->is_buffering = mut_player->is_buffering;
    out_status->silence = mut_player->silence_config;
    if (mut_player->sound_loaded)
    {
        ma_spinlock_lock(&mut_player->stretch_ds.lock);
        out_status->silence_saved_ms = map_silence_detector_get_saved_ms(&mut_player->stretch_ds.silence);
        ma_spinlock_unlock(&mut_player->stretch_ds.lock);
    }
    else
    {
        out_status->silence_saved_ms = 0;
    }

    if (mut_player->sound_loaded)
    {
        float cursor_sec = 0.0f;
        if (ma_sound_get_cursor_in_seconds(&mut_player->sound, &cursor_sec) == MA_SUCCESS && cursor_sec >= 0.0f)
        {
            out_status->position_ms = (int64_t)((double)cursor_sec * 1000.0 + 0.5);
        }
        else
        {
            out_status->position_ms = 0;
        }
        if (mut_player->duration_ms > 0 && out_status->position_ms > mut_player->duration_ms)
        {
            out_status->position_ms = mut_player->duration_ms;
        }

        if (mut_player->state == MAP_PLAYBACK_STATE_STOPPED)
        {
            out_status->is_completed = 0;
            out_status->is_playing = 0;
            out_status->state = MAP_PLAYBACK_STATE_STOPPED;
        }
        else if (mut_player->state == MAP_PLAYBACK_STATE_PLAYING)
        {
            if (mut_player->is_completed || ma_sound_at_end(&mut_player->sound))
            {
                mut_player->is_completed = 1;
                mut_player->state = MAP_PLAYBACK_STATE_COMPLETED;
                out_status->is_completed = 1;
                out_status->is_playing = 0;
                out_status->state = MAP_PLAYBACK_STATE_COMPLETED;
                out_status->position_ms = mut_player->duration_ms;
            }
            else
            {
                out_status->is_completed = 0;
                out_status->is_playing = ma_sound_is_playing(&mut_player->sound) ? 1 : 0;
                out_status->state = MAP_PLAYBACK_STATE_PLAYING;
            }
        }
        else if (mut_player->state == MAP_PLAYBACK_STATE_COMPLETED)
        {
            out_status->is_completed = 1;
            out_status->is_playing = 0;
            out_status->state = MAP_PLAYBACK_STATE_COMPLETED;
            out_status->position_ms = mut_player->duration_ms;
        }
        else
        {
            out_status->is_completed = 0;
            out_status->is_playing = ma_sound_is_playing(&mut_player->sound) ? 1 : 0;
            out_status->state = mut_player->state;
        }
    }
    else
    {
        out_status->state = mut_player->state;
    }

    if (ma_atomic_load_32(&mut_player->needs_device_fallback) && !ma_atomic_load_32(&mut_player->is_switching_device))
    {
        ma_atomic_store_32(&mut_player->needs_device_fallback, 0);
        if (mut_player->has_custom_device)
        {
            ma_mutex_unlock(&mut_player->lock);
            map_player_apply_device(mut_player, NULL);
            ma_mutex_lock(&mut_player->lock);
        }
    }
    else
    {
        ma_device *pDev = ma_engine_get_device(&mut_player->engine);
        if (pDev != NULL)
        {
            ma_device_info devInfo;
            if (ma_device_get_info(pDev, ma_device_type_playback, &devInfo) == MA_SUCCESS)
            {
                if (mut_player->has_custom_device)
                {
                    if ((int32_t)devInfo.isDefault != mut_player->current_device.is_default)
                    {
                        mut_player->current_device.is_default = (int32_t)devInfo.isDefault;
                        mut_player->device_changed = 1;
                    }
                }
                else
                {
                    if (strcmp(mut_player->current_device.name, devInfo.name) != 0)
                    {
                        strncpy(mut_player->current_device.name, devInfo.name, sizeof(mut_player->current_device.name) - 1);
                        mut_player->current_device.name[sizeof(mut_player->current_device.name) - 1] = '\0';
                        mut_player->device_changed = 1;
                    }
                }
            }
        }
    }
    out_status->device = mut_player->current_device;

    out_status->visualizer_enabled = mut_player->eq_node.visualizer_enabled;
    if (out_status->is_playing && mut_player->eq_node.visualizer_enabled)
    {
        uint32_t seq;
        int attempts = 0;
        ma_bool32 retry;
        do
        {
            seq = map_seqlock_read_begin(&mut_player->eq_node.vis_seqlock);
            out_status->visualizer = mut_player->eq_node.visualizer_data;
            retry = map_seqlock_read_retry(&mut_player->eq_node.vis_seqlock, seq);
        } while (retry && ++attempts < 16);

        if (retry)
        {
            memset(&out_status->visualizer, 0, sizeof(out_status->visualizer));
        }
    }
    else
    {
        memset(&out_status->visualizer, 0, sizeof(out_status->visualizer));
    }

    out_status->preamp_db = mut_player->eq_node.preamp_db;
    out_status->replay_gain = mut_player->eq_node.rg_config;
    out_status->balance = mut_player->eq_node.balance;
    out_status->mono_enabled = mut_player->eq_node.mono_enabled;
    out_status->crossfeed_mode = mut_player->eq_node.crossfeed_mode;
    out_status->spatializer_enabled = mut_player->eq_node.spatializer_enabled;
    out_status->spatializer_width = mut_player->eq_node.spatializer_width;
    out_status->reverb.enabled = mut_player->eq_node.reverb_enabled;
    out_status->reverb.room_size = mut_player->eq_node.reverb.room_size;
    out_status->reverb.damping = mut_player->eq_node.reverb.damping;
    out_status->reverb.width = mut_player->eq_node.reverb.width;
    out_status->reverb.wet = mut_player->eq_node.reverb.wet;
    out_status->reverb.dry = mut_player->eq_node.reverb.dry;
    out_status->limiter_enabled = mut_player->eq_node.limiter_enabled;

    ma_mutex_unlock(&mut_player->lock);
    return MAP_SUCCESS;
}

MAP_API int64_t miniaudio_player_get_position_ms(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.position_ms;
}

MAP_API int64_t miniaudio_player_get_duration_ms(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.duration_ms;
}

MAP_API int32_t miniaudio_player_is_playing(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.is_playing;
}

MAP_API int32_t miniaudio_player_is_completed(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.is_completed;
}

MAP_API float miniaudio_player_get_volume(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 1.0f;
    return status.volume;
}

MAP_API float miniaudio_player_get_rate(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 1.0f;
    return status.rate;
}

MAP_API float miniaudio_player_get_pitch(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 1.0f;
    return status.pitch;
}

MAP_API uint32_t miniaudio_player_get_bitrate(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.bitrate;
}

MAP_API int32_t miniaudio_player_get_equalizer(
    const miniaudio_player_t *player,
    miniaudio_player_equalizer_params_t *out_equalizer)
{
    miniaudio_player_status_t status;
    if (player == NULL || out_equalizer == NULL)
        return MAP_ERROR_INVALID_ARGS;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return MAP_ERROR_GENERIC;
    *out_equalizer = status.equalizer;
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_visualizer_enabled(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;
    ma_spinlock_lock(&player->eq_node.lock);
    player->eq_node.visualizer_enabled = (enabled != 0) ? 1 : 0;
    if (!player->eq_node.visualizer_enabled)
    {
        memset(&player->eq_node.visualizer_data, 0, sizeof(player->eq_node.visualizer_data));
    }
    ma_spinlock_unlock(&player->eq_node.lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_is_visualizer_enabled(const miniaudio_player_t *player)
{
    if (player == NULL) return 0;
    return player->eq_node.visualizer_enabled;
}

MAP_API int32_t miniaudio_player_get_visualizer_data(
    const miniaudio_player_t *player,
    miniaudio_player_visualizer_data_t *out_data)
{
    miniaudio_player_t *mut_player;
    uint32_t seq;
    int attempts = 0;
    ma_bool32 retry;

    if (player == NULL || out_data == NULL) return MAP_ERROR_INVALID_ARGS;
    mut_player = (miniaudio_player_t *)player;
    do
    {
        seq = map_seqlock_read_begin(&mut_player->eq_node.vis_seqlock);
        *out_data = mut_player->eq_node.visualizer_data;
        retry = map_seqlock_read_retry(&mut_player->eq_node.vis_seqlock, seq);
    } while (retry && ++attempts < 16);

    if (retry)
    {
        memset(out_data, 0, sizeof(*out_data));
        return MAP_ERROR_GENERIC;
    }

    return MAP_SUCCESS;
}
