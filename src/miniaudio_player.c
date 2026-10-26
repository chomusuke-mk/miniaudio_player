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
#include "map_sniffer.h"
#include "map_event_dispatcher.h"
#include "sonic.h"

#if !defined(_WIN32)
#include <pthread.h>
#include <sys/stat.h>
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
    MA_ATOMIC(4, ma_int32) state;
    MA_ATOMIC(4, ma_int32) is_completed;
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
    int64_t audio_data_offset;
    miniaudio_player_completed_cb on_completed;
    void *user_data;
    ma_log log;
    ma_bool32 has_log;
#if !defined(MA_NO_DEVICE_IO)
    ma_context context;
    ma_bool32 has_context;
    ma_device_id custom_device_id;
    ma_bool32 has_custom_device;
#endif
    miniaudio_device_info_t current_device;
    MA_ATOMIC(4, ma_int32) needs_device_fallback;
    MA_ATOMIC(4, ma_int32) is_switching_device;
    int32_t device_changed;
    map_event_dispatcher_t dispatcher;
};

static void map_player_set_state(miniaudio_player_t *player, miniaudio_player_playback_state_t next_state)
{
    ma_int32 is_playing = (next_state == MAP_PLAYBACK_STATE_PLAYING) ? 1 : 0;
    ma_int32 is_completed = (next_state == MAP_PLAYBACK_STATE_COMPLETED) ? 1 : 0;

    ma_atomic_store_32(&player->state, (ma_int32)next_state);
    ma_atomic_store_32(&player->is_completed, is_completed);

    map_event_dispatcher_post_state(&player->dispatcher, next_state);
    map_event_dispatcher_post_playing(&player->dispatcher, is_playing);
    map_event_dispatcher_post_completed(&player->dispatcher, is_completed);
    if (next_state != MAP_PLAYBACK_STATE_PLAYING && next_state != MAP_PLAYBACK_STATE_BUFFERING)
    {
        player->is_buffering = 0;
        map_event_dispatcher_post_buffering(&player->dispatcher, 0);
    }
}

/* End-of-sound callback executed on audio device thread (lock-free wrt player->lock) */
static void miniaudio_player_on_sound_end(void *pUserData, ma_sound *pSound)
{
    miniaudio_player_t *player = (miniaudio_player_t *)pUserData;
    miniaudio_player_completed_cb cb = NULL;
    void *udata = NULL;
    (void)pSound;

    if (player == NULL)
        return;

    /* Idempotent atomic guard: transition to completed exactly once */
    if (ma_atomic_exchange_32(&player->is_completed, 1) == 1)
    {
        return;
    }

    ma_atomic_store_32(&player->state, (ma_int32)MAP_PLAYBACK_STATE_COMPLETED);
    if (player->duration_ms > 0)
    {
        map_event_dispatcher_post_position(&player->dispatcher, player->duration_ms);
    }
    map_event_dispatcher_post_completed(&player->dispatcher, 1);
    map_event_dispatcher_post_state(&player->dispatcher, MAP_PLAYBACK_STATE_COMPLETED);
    map_event_dispatcher_post_playing(&player->dispatcher, 0);
    map_event_dispatcher_post_buffering(&player->dispatcher, 0);
#if defined(__EMSCRIPTEN__)
    map_event_dispatcher_flush(&player->dispatcher);
#endif

    cb = player->on_completed;
    udata = player->user_data;
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

#if !defined(MA_NO_DEVICE_IO)
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
    state = (miniaudio_player_playback_state_t)ma_atomic_load_32(&player->state);
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
    map_event_dispatcher_post_device(&player->dispatcher, &player->current_device);
    map_event_dispatcher_flush(&player->dispatcher);
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
                map_event_dispatcher_post_device(&player->dispatcher, &player->current_device);
                map_event_dispatcher_flush(&player->dispatcher);
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
#endif

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
    ma_atomic_store_32(&player->state, (ma_int32)MAP_PLAYBACK_STATE_STOPPED);
    ma_atomic_store_32(&player->is_completed, 0);
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
    strcpy(player->current_device.name, "System Default");
    player->current_device.is_default = 1;
    player->current_device.is_auto = 1;

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

#if defined(__EMSCRIPTEN__)
    engine_cfg.noDevice = MA_TRUE;
    engine_cfg.channels = (config != NULL && config->channels > 0) ? config->channels : 2;
    engine_cfg.sampleRate = (config != NULL && config->sample_rate > 0) ? config->sample_rate : 48000;
#else
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
#endif
#if defined(_WIN32)
    timeBeginPeriod(1); /* Ensure 1ms timer precision for decoder worker thread */
#endif
    engine_cfg.periodSizeInFrames = player->buffer_size;
#if !defined(MA_NO_DEVICE_IO)
    engine_cfg.notificationCallback = map_miniaudio_device_notification;

    if (config != NULL && !map_is_device_id_default(config->playback_device_id))
    {
        if (map_string_to_device_id(config->playback_device_id, &player->custom_device_id))
        {
            engine_cfg.pPlaybackDeviceID = &player->custom_device_id;
            player->has_custom_device = MA_TRUE;
        }
    }
#endif
    engine_cfg.resourceManagerResampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
    engine_cfg.pitchResampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;

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
#if !defined(MA_NO_DEVICE_IO)
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

#if !defined(MA_NO_DEVICE_IO)
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
#endif

    /* Initialize native reactive event dispatcher */
    {
        result = map_event_dispatcher_init(&player->dispatcher, player, NULL, NULL);
        if (result != MA_SUCCESS)
        {
            map_log_print(MAP_LOG_LEVEL_ERROR, "core", "map_event_dispatcher_init failed: %d", result);
            ma_equalizer_node_uninit(&player->eq_node);
            ma_engine_uninit(&player->engine);
            fail_result = MAP_ERROR_ENGINE_INIT;
            goto cleanup_error;
        }

        ma_equalizer_node_set_dispatcher(&player->eq_node, &player->dispatcher);
        map_time_stretch_ds_set_dispatcher(&player->stretch_ds, &player->dispatcher);

        /* Post initial state */
        map_event_dispatcher_post_state(&player->dispatcher, MAP_PLAYBACK_STATE_STOPPED);
        map_event_dispatcher_post_playing(&player->dispatcher, 0);
        map_event_dispatcher_post_completed(&player->dispatcher, 0);
        map_event_dispatcher_post_buffering(&player->dispatcher, 0);
        map_event_dispatcher_post_volume(&player->dispatcher, player->volume);
        map_event_dispatcher_post_rate(&player->dispatcher, player->rate);
        map_event_dispatcher_post_pitch(&player->dispatcher, player->pitch);
        map_event_dispatcher_post_position(&player->dispatcher, 0);
        map_event_dispatcher_post_duration(&player->dispatcher, 0);
        map_event_dispatcher_post_buffer_size(&player->dispatcher, player->buffer_size);
        map_event_dispatcher_post_device(&player->dispatcher, &player->current_device);
        map_event_dispatcher_post_silence_config(&player->dispatcher, &player->silence_config);
        map_event_dispatcher_post_visualizer_enabled(&player->dispatcher, player->eq_node.visualizer_enabled);
        map_event_dispatcher_flush(&player->dispatcher);
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
    strcpy(player->current_device.name, "System Default");
    player->current_device.is_default = 1;
    player->current_device.is_auto = 1;
    }
    if (player->has_log)
    {
        ma_log_uninit(&player->log);
        player->has_log = MA_FALSE;
    }
#if !defined(MA_NO_DEVICE_IO)
    if (player->has_context)
    {
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;
    }
#endif
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
    map_event_dispatcher_uninit(&player->dispatcher);
    if (player->sound_loaded)
    {
        ma_sound_set_end_callback(&player->sound, NULL, NULL);
        ma_sound_stop(&player->sound);
        ma_sound_uninit(&player->sound);
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->sound_loaded = MA_FALSE;
    }
    else if (player->stretch_ds.is_stream)
    {
        map_time_stretch_ds_uninit(&player->stretch_ds);
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
    strcpy(player->current_device.name, "System Default");
    player->current_device.is_default = 1;
    player->current_device.is_auto = 1;
    }

    if (player->has_log)
    {
        ma_log_uninit(&player->log);
        player->has_log = MA_FALSE;
    }

#if !defined(MA_NO_DEVICE_IO)
    if (player->has_context)
    {
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;
    }
#endif

#if defined(_WIN32)
    timeEndPeriod(1);
#endif

    ma_mutex_uninit(&player->lock);
    ma_aligned_free(player, NULL);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player destroy completed");
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_event_callback(
    miniaudio_player_t *player,
    miniaudio_player_event_cb callback,
    void *user_data)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_event_dispatcher_set_callback(&player->dispatcher, callback, user_data);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Media Loading API                                                         */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_begin_open(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "begin_open: transition to OPENING");

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
    else if (player->stretch_ds.is_stream)
    {
        map_time_stretch_ds_uninit(&player->stretch_ds);
    }

    if (player->file_path != NULL)
    {
        free(player->file_path);
        player->file_path = NULL;
    }

    player->duration_ms = 0;
    player->bitrate = 0;
    player->audio_data_offset = 0;

    map_player_set_state(player, MAP_PLAYBACK_STATE_OPENING);
    map_event_dispatcher_post_position(&player->dispatcher, 0);
    map_event_dispatcher_post_duration(&player->dispatcher, 0);
    map_event_dispatcher_post_bitrate(&player->dispatcher, 0);
    map_event_dispatcher_flush(&player->dispatcher);

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_open_memory(
    miniaudio_player_t *player,
    const void *data,
    size_t size,
    int32_t take_ownership)
{
    int32_t res;
    uint32_t cap;

    if (player == NULL || data == NULL || size == 0)
    {
        if (take_ownership && data != NULL)
        {
            free((void *)data);
        }
        return MAP_ERROR_INVALID_ARGS;
    }

    cap = (size > 256 * 1024) ? (uint32_t)size : (uint32_t)(256 * 1024);
    res = miniaudio_player_open_stream_ex(
        player,
        (const uint8_t *)data,
        size,
        NULL,
        0,
        (int64_t)size,
        0,
        cap,
        0);

    if (take_ownership)
    {
        free((void *)data);
    }

    if (res == MAP_SUCCESS)
    {
        miniaudio_player_stream_end(player);
        ma_mutex_lock(&player->lock);
        if (player->file_path != NULL)
        {
            free(player->file_path);
        }
        player->file_path = map_strdup("memory://");
        ma_mutex_unlock(&player->lock);
    }

    return res;
}

MAP_API int32_t miniaudio_player_open_file(
    miniaudio_player_t *player,
    const char *file_path)
{
    FILE *f = NULL;
    long file_size = 0;
    uint8_t *file_buf = NULL;
    size_t bytes_read = 0;
    int32_t res;

    if (player == NULL || file_path == NULL || file_path[0] == '\0')
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_file: %s", file_path);

#if defined(_WIN32)
    {
        wchar_t *wpath = map_utf8_to_wchar(file_path);
        if (wpath == NULL)
        {
            ma_mutex_lock(&player->lock);
            map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
            map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_FILE_NOT_FOUND);
            map_event_dispatcher_flush(&player->dispatcher);
            ma_mutex_unlock(&player->lock);
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
        ma_mutex_lock(&player->lock);
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_FILE_NOT_FOUND);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_FILE_NOT_FOUND;
    }

#if !defined(_WIN32)
    {
        struct stat st;
        if (fstat(fileno(f), &st) != 0 || S_ISDIR(st.st_mode))
        {
            fclose(f);
            ma_mutex_lock(&player->lock);
            map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
            map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_DECODE_FAILED);
            map_event_dispatcher_flush(&player->dispatcher);
            ma_mutex_unlock(&player->lock);
            return MAP_ERROR_DECODE_FAILED;
        }
    }
#endif

    if (fseek(f, 0, SEEK_END) != 0)
    {
        fclose(f);
        ma_mutex_lock(&player->lock);
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_DECODE_FAILED);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_DECODE_FAILED;
    }
    file_size = ftell(f);
    if (file_size <= 0 || fseek(f, 0, SEEK_SET) != 0)
    {
        fclose(f);
        ma_mutex_lock(&player->lock);
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_DECODE_FAILED);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_DECODE_FAILED;
    }

    file_buf = (uint8_t *)malloc((size_t)file_size);
    if (file_buf == NULL)
    {
        fclose(f);
        ma_mutex_lock(&player->lock);
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_OUT_OF_MEMORY);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_OUT_OF_MEMORY;
    }

    bytes_read = fread(file_buf, 1, (size_t)file_size, f);
    if (bytes_read == 0 || ferror(f))
    {
        free(file_buf);
        fclose(f);
        ma_mutex_lock(&player->lock);
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_DECODE_FAILED);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_DECODE_FAILED;
    }
    fclose(f);

    res = miniaudio_player_open_memory(player, file_buf, bytes_read, 1);
    if (res == MAP_SUCCESS)
    {
        ma_mutex_lock(&player->lock);
        if (player->file_path != NULL)
        {
            free(player->file_path);
        }
        player->file_path = map_strdup(file_path);
        ma_mutex_unlock(&player->lock);
    }
    return res;
}

MAP_API int32_t miniaudio_player_open_stream_ex(
    miniaudio_player_t *player,
    const uint8_t *initial_data,
    size_t initial_data_size,
    const uint8_t *tail_data,
    size_t tail_data_size,
    int64_t total_size,
    int32_t is_live,
    uint32_t buffer_capacity_bytes,
    int32_t encoding_format)
{
    ma_sound_config sound_cfg;
    ma_result result;

    if (player == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    if (initial_data == NULL || initial_data_size == 0)
    {
        if (ma_atomic_load_32(&player->state) == MAP_PLAYBACK_STATE_OPENING)
        {
            int32_t err_code = (encoding_format < 0) ? encoding_format : MAP_ERROR_DECODE_FAILED;
            ma_mutex_lock(&player->lock);
            map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
            map_event_dispatcher_post_error(&player->dispatcher, err_code);
            map_event_dispatcher_flush(&player->dispatcher);
            ma_mutex_unlock(&player->lock);
            return err_code;
        }
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_stream_ex: initial_size=%zu, tail_size=%zu, total_size=%lld, is_live=%d, cap=%u",
                  initial_data_size, tail_data_size, (long long)total_size, is_live, buffer_capacity_bytes);

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
    else if (player->stretch_ds.is_stream)
    {
        map_time_stretch_ds_uninit(&player->stretch_ds);
    }

    player->duration_ms = 0;
    player->bitrate = 0;
    player->audio_data_offset = 0;
    map_player_set_state(player, MAP_PLAYBACK_STATE_OPENING);
    map_event_dispatcher_flush(&player->dispatcher);

    /* Initialize time stretch data source wrapping streaming buffer */
    result = map_time_stretch_ds_init_stream_ex(
        &player->stretch_ds,
        initial_data,
        initial_data_size,
        tail_data,
        tail_data_size,
        total_size,
        is_live ? MA_TRUE : MA_FALSE,
        buffer_capacity_bytes,
        encoding_format,
        player->channels,
        player->sample_rate);
    if (result != MA_SUCCESS)
    {
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_DECODE_FAILED);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_stream decoder init failed: %d", result);
        return MAP_ERROR_DECODE_FAILED;
    }

    /* Apply cached rate (speed), pitch, and silence config */
    map_time_stretch_ds_set_speed(&player->stretch_ds, player->rate);
    map_time_stretch_ds_set_pitch(&player->stretch_ds, player->pitch);
    ma_spinlock_lock(&player->stretch_ds.lock);
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
        map_player_set_state(player, MAP_PLAYBACK_STATE_ERROR);
        map_event_dispatcher_post_error(&player->dispatcher, MAP_ERROR_DECODE_FAILED);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_init_ex from stream failed: %d", result);
        return MAP_ERROR_DECODE_FAILED;
    }

    player->sound_loaded = MA_TRUE;

    ma_sound_set_volume(&player->sound, 1.0f);
    ma_spinlock_lock(&player->eq_node.lock);
    player->eq_node.target_volume = player->volume;
    player->eq_node.current_volume = player->volume;
    ma_spinlock_unlock(&player->eq_node.lock);

    /* Duration: 0 if live, or from decoder totalFrames */
    if (is_live)
    {
        player->duration_ms = 0;
    }
    else
    {
        ma_uint64 total_frames = player->stretch_ds.totalFrames;
        if (total_frames > 0 && player->stretch_ds.sampleRate > 0)
        {
            player->duration_ms = (int64_t)((double)total_frames * 1000.0 / player->stretch_ds.sampleRate + 0.5);
        }
        else
        {
            player->duration_ms = 0;
        }
    }

    /* Fallback metadata sniffer for finite streams where decoder could not seek to EOF (e.g. CBR MP3, Vorbis, Opus) */
    if (!is_live && initial_data != NULL && initial_data_size > 0)
    {
        uint32_t sniffed_bitrate = 0;
        int64_t sniffed_duration_ms = 0;

        if (map_sniff_stream_info(initial_data, initial_data_size, total_size,
                                  &sniffed_bitrate, &sniffed_duration_ms) && sniffed_duration_ms > 0)
        {
            if (player->duration_ms == 0 || (total_size > 0 && (int64_t)initial_data_size < total_size))
            {
                player->duration_ms = sniffed_duration_ms;
                player->bitrate = sniffed_bitrate;
                if (player->stretch_ds.sampleRate > 0)
                {
                    player->stretch_ds.totalFrames = (ma_uint64)((double)player->duration_ms * (double)player->stretch_ds.sampleRate / 1000.0 + 0.5);
                }
            }
        }

        {
            map_container_format_t container = player->stretch_ds.buffer.container_format;
            if (container == MAP_CONTAINER_OGG_VORBIS || container == MAP_CONTAINER_OGG_OPUS)
            {
                uint32_t srate = 0;
                if (player->stretch_ds.decoder.pBackend != NULL)
                {
                    ma_data_source_get_data_format(player->stretch_ds.decoder.pBackend, NULL, NULL, &srate, NULL, 0);
                }
                if (srate == 0)
                {
                    srate = player->stretch_ds.sampleRate;
                }
                const uint8_t * scan_buf = NULL;
                size_t scan_len = 0;
                if (tail_data != NULL && tail_data_size >= 27)
                {
                    scan_buf = tail_data;
                    scan_len = tail_data_size;
                }
                else if (total_size > 0 && (int64_t)initial_data_size >= total_size && initial_data_size >= 27)
                {
                    scan_buf = initial_data;
                    scan_len = initial_data_size;
                }
                if (scan_buf != NULL)
                {
                    int64_t ogg_dur_ms = 0;
                    if (map_sniffer_extract_tail_duration_ms(container, srate, scan_buf, scan_len, &ogg_dur_ms) && ogg_dur_ms > 0)
                    {
                        player->duration_ms = ogg_dur_ms;
                        if (total_size > 0)
                        {
                            player->bitrate = (uint32_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)ogg_dur_ms);
                        }
                        if (player->stretch_ds.sampleRate > 0)
                        {
                            player->stretch_ds.totalFrames = (ma_uint64)((double)player->duration_ms * (double)player->stretch_ds.sampleRate / 1000.0 + 0.5);
                        }
                    }
                }
            }
        }
    }

    /* Bitrate: from total_size & duration, or nominal if still unresolved */
    if (player->bitrate == 0)
    {
        if (player->duration_ms > 0 && total_size > 0)
        {
            player->bitrate = (uint32_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)player->duration_ms);
        }
        else if (player->sample_rate > 0 && player->channels > 0)
        {
            player->bitrate = player->sample_rate * player->channels * 16;
        }
    }

    if (player->file_path != NULL)
    {
        free(player->file_path);
        player->file_path = NULL;
    }
    player->file_path = map_strdup("stream://");

    player->audio_data_offset = map_decoder_get_audio_data_offset(&player->stretch_ds.decoder);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_stream success: dur=%lld ms, bitrate=%u bps, audio_offset=%lld",
                  (long long)player->duration_ms, player->bitrate, (long long)player->audio_data_offset);

    map_player_set_state(player, MAP_PLAYBACK_STATE_STOPPED);
    map_event_dispatcher_post_duration(&player->dispatcher, player->duration_ms);
    map_event_dispatcher_post_bitrate(&player->dispatcher, player->bitrate);
    map_event_dispatcher_post_position(&player->dispatcher, 0);
    map_event_dispatcher_flush(&player->dispatcher);

    ma_mutex_unlock(&player->lock);

    {
        miniaudio_buffered_range_t range;
        if (miniaudio_player_get_buffered_range(player, &range) == MAP_SUCCESS)
        {
            map_event_dispatcher_post_buffered_range(&player->dispatcher, &range);
            map_event_dispatcher_flush(&player->dispatcher);
        }
    }

    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_open_stream(
    miniaudio_player_t *player,
    const uint8_t *initial_data,
    size_t initial_data_size,
    int64_t total_size,
    int32_t is_live,
    uint32_t buffer_capacity_bytes,
    int32_t encoding_format)
{
    return miniaudio_player_open_stream_ex(
        player,
        initial_data,
        initial_data_size,
        NULL,
        0,
        total_size,
        is_live,
        buffer_capacity_bytes,
        encoding_format);
}

MAP_API int32_t miniaudio_player_stream_feed(
    miniaudio_player_t *player,
    const uint8_t *data,
    size_t size)
{
    ma_result res;
    if (player == NULL || data == NULL || size == 0)
        return MAP_ERROR_INVALID_ARGS;

    if (!player->sound_loaded || !player->stretch_ds.is_stream)
        return MAP_ERROR_INVALID_STATE;

    res = map_time_stretch_ds_stream_feed(&player->stretch_ds, data, size);
    if (res == MA_BUSY)
        return MAP_ERROR_BUSY;
    if (res == MA_SUCCESS)
    {
        miniaudio_buffered_range_t range;
        if (miniaudio_player_get_buffered_range(player, &range) == MAP_SUCCESS)
        {
            map_event_dispatcher_post_buffered_range(&player->dispatcher, &range);
            if (!range.is_buffering)
            {
                map_event_dispatcher_post_buffering(&player->dispatcher, 0);
            }
        }
        return MAP_SUCCESS;
    }
    return MAP_ERROR_DECODE_FAILED;
}

static int64_t map_player_get_seek_byte_locked(
    miniaudio_player_t *player,
    int64_t position_ms)
{
    int64_t seek_byte = 0;

    if (!player->sound_loaded || !player->stretch_ds.is_stream)
    {
        return -1;
    }

    if (position_ms < 0)
        position_ms = 0;
    if (player->duration_ms > 0 && position_ms > player->duration_ms)
        position_ms = player->duration_ms;

    map_time_stretch_ds *pDS = &player->stretch_ds;

    ma_uint64 targetFrame = (ma_uint64)(((double)position_ms / 1000.0) * (double)pDS->sampleRate);
    int64_t container_byte = map_decoder_get_stream_seek_byte(&pDS->decoder, targetFrame);
    if (container_byte >= 0)
    {
        seek_byte = container_byte;
        ma_uint32 bytesPerFrame = map_decoder_get_raw_bytes_per_frame(&pDS->decoder);
        if (pDS->buffer.total_size > 0 && seek_byte >= pDS->buffer.total_size)
        {
            seek_byte = pDS->buffer.total_size - bytesPerFrame;
            if (seek_byte < 0)
            {
                seek_byte = 0;
            }
        }
        return seek_byte;
    }

    if (position_ms <= 0)
    {
        seek_byte = player->audio_data_offset;
    }
    else if (pDS->buffer.total_size > 0 && player->duration_ms > 0)
    {
        int64_t audio_start = player->audio_data_offset;
        int64_t audio_bytes = (pDS->buffer.total_size > audio_start) ? (pDS->buffer.total_size - audio_start) : pDS->buffer.total_size;
        ma_uint32 bpf = map_decoder_get_raw_bytes_per_frame(&pDS->decoder);
        if (bpf == 0)
        {
            bpf = 4;
        }
        int64_t rel_off = (position_ms * audio_bytes) / player->duration_ms;
        rel_off = (rel_off / (int64_t)bpf) * (int64_t)bpf;
        seek_byte = audio_start + rel_off;
        if (seek_byte >= pDS->buffer.total_size)
        {
            seek_byte = pDS->buffer.total_size - (int64_t)bpf;
            if (seek_byte < 0)
            {
                seek_byte = 0;
            }
        }
    }
    else
    {
        seek_byte = player->audio_data_offset;
    }

    return seek_byte;
}

MAP_API int32_t miniaudio_player_stream_flush(
    miniaudio_player_t *player,
    int64_t new_stream_offset)
{
    ma_result res;
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded || !player->stretch_ds.is_stream)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_uint64 scheduledSeek = ma_atomic_load_64(&player->sound.seekTarget);
    if (scheduledSeek != MA_SEEK_TARGET_NONE)
    {
        player->stretch_ds.readCursorFrames = scheduledSeek;
        ma_node_set_time(&player->sound, scheduledSeek);
        ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
    }
    ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
    ma_atomic_store_32(&player->is_completed, 0);

    res = map_time_stretch_ds_stream_flush(&player->stretch_ds, new_stream_offset);
    ma_mutex_unlock(&player->lock);
    return (res == MA_SUCCESS) ? MAP_SUCCESS : MAP_ERROR_DECODE_FAILED;
}

MAP_API int32_t miniaudio_player_stream_seek(
    miniaudio_player_t *player,
    int64_t position_ms,
    int64_t new_stream_offset)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    miniaudio_player_playback_state_t cur_state =
        (miniaudio_player_playback_state_t)ma_atomic_load_32(&player->state);
    if (!player->sound_loaded || !player->stretch_ds.is_stream || cur_state == MAP_PLAYBACK_STATE_OPENING)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    if (position_ms < 0)
        position_ms = 0;
    if (player->duration_ms > 0 && position_ms >= player->duration_ms)
    {
        position_ms = player->duration_ms;
        ma_sound_stop(&player->sound);
        ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
        ma_node_set_time(&player->sound, player->stretch_ds.totalFrames);
        player->stretch_ds.readCursorFrames = player->stretch_ds.totalFrames;
        ma_atomic_exchange_32(&player->sound.atEnd, MA_TRUE);
        map_player_set_state(player, MAP_PLAYBACK_STATE_COMPLETED);
        map_event_dispatcher_post_position(&player->dispatcher, position_ms);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_STREAM_SEEK_CACHE_HIT;
    }

    map_time_stretch_ds *pDS = &player->stretch_ds;
    ma_uint64 targetFrame = (ma_uint64)(((double)position_ms / 1000.0) * (double)pDS->sampleRate);

    ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
    ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
    ma_atomic_store_32(&player->is_completed, 0);
    map_event_dispatcher_post_completed(&player->dispatcher, 0);
    ma_node_set_time(&player->sound, targetFrame);

    int32_t seek_res = map_time_stretch_ds_seek_stream(pDS, targetFrame, new_stream_offset);

    if (cur_state == MAP_PLAYBACK_STATE_COMPLETED)
    {
        map_player_set_state(player, MAP_PLAYBACK_STATE_PAUSED);
    }
    else if (cur_state == MAP_PLAYBACK_STATE_PLAYING)
    {
        if (!ma_sound_is_playing(&player->sound))
        {
            ma_sound_start(&player->sound);
        }
        map_player_set_state(player, MAP_PLAYBACK_STATE_PLAYING);
    }
    else
    {
        map_player_set_state(player, cur_state);
    }

    if (seek_res == MAP_STREAM_SEEK_CACHE_MISS)
    {
        map_event_dispatcher_post_buffering(&player->dispatcher, 1);
    }
    else
    {
        map_event_dispatcher_post_buffering(&player->dispatcher, 0);
    }
    map_event_dispatcher_post_position(&player->dispatcher, position_ms);
    map_event_dispatcher_flush(&player->dispatcher);

    ma_mutex_unlock(&player->lock);
    return seek_res;
}

MAP_API int64_t miniaudio_player_stream_get_seek_byte(
    const miniaudio_player_t *player,
    int64_t position_ms)
{
    miniaudio_player_t *mut_player;
    int64_t seek_byte;

    if (player == NULL)
        return -1;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    seek_byte = map_player_get_seek_byte_locked(mut_player, position_ms);
    ma_mutex_unlock(&mut_player->lock);
    return seek_byte;
}

MAP_API int64_t miniaudio_player_get_audio_data_offset(const miniaudio_player_t *player)
{
    miniaudio_player_t *mut_player;
    int64_t offset;
    if (player == NULL)
        return 0;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    offset = mut_player->audio_data_offset;
    ma_mutex_unlock(&mut_player->lock);

    return (offset > 0) ? offset : 0;
}

MAP_API int32_t miniaudio_player_stream_end(
    miniaudio_player_t *player)
{
    ma_result res;
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    if (!player->sound_loaded || !player->stretch_ds.is_stream)
        return MAP_ERROR_INVALID_STATE;

    res = map_time_stretch_ds_stream_end(&player->stretch_ds);
    if (res == MA_SUCCESS)
    {
        miniaudio_buffered_range_t range;
        if (miniaudio_player_get_buffered_range(player, &range) == MAP_SUCCESS)
        {
            map_event_dispatcher_post_buffered_range(&player->dispatcher, &range);
            if (!range.is_buffering)
            {
                map_event_dispatcher_post_buffering(&player->dispatcher, 0);
            }
        }
        return MAP_SUCCESS;
    }
    return MAP_ERROR_DECODE_FAILED;
}

MAP_API int64_t miniaudio_player_stream_get_pinned_head_size(const miniaudio_player_t *player)
{
    if (player == NULL || !player->sound_loaded || !player->stretch_ds.is_stream)
        return 0;

    ma_mutex_lock((ma_mutex *)&player->stretch_ds.buffer.lock);
    int64_t hs = (int64_t)player->stretch_ds.buffer.head_size;
    ma_mutex_unlock((ma_mutex *)&player->stretch_ds.buffer.lock);
    return hs;
}

MAP_API int32_t miniaudio_player_stream_get_status(
    miniaudio_player_t *player,
    miniaudio_stream_status_t *out_status)
{
    if (player == NULL || out_status == NULL)
        return MAP_ERROR_INVALID_ARGS;

    if (!player->sound_loaded || !player->stretch_ds.is_stream)
        return MAP_ERROR_INVALID_STATE;

    map_buffer_range_t r;
    map_buffer_get_range(&player->stretch_ds.buffer, &r);
    out_status->buffer_capacity = player->stretch_ds.buffer.capacity;
    out_status->buffer_fill = (size_t)(r.end_byte - r.start_byte);
    out_status->fill_percentage = r.fill_percentage;
    out_status->is_buffering = r.is_buffering;
    out_status->is_eof = r.is_eof;
    out_status->read_cursor_byte = r.read_cursor_byte;
    out_status->range_start = r.start_byte;
    out_status->range_end = r.end_byte;

    return MAP_SUCCESS;
}

MAP_API uint32_t miniaudio_player_get_meta_bytes_version(const miniaudio_player_t *player)
{
    if (player == NULL)
        return 0;

    miniaudio_player_t *mut = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut->lock);
    uint32_t v = mut->stretch_ds.is_stream
        ? map_buffer_get_meta_version(&mut->stretch_ds.buffer)
        : 0;
    ma_mutex_unlock(&mut->lock);
    return v;
}

MAP_API size_t miniaudio_player_get_meta_bytes_size(const miniaudio_player_t *player)
{
    if (player == NULL)
        return 0;

    miniaudio_player_t *mut = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut->lock);
    size_t s = mut->stretch_ds.is_stream
        ? map_buffer_get_meta_bytes_size(&mut->stretch_ds.buffer)
        : 0;
    ma_mutex_unlock(&mut->lock);
    return s;
}

MAP_API size_t miniaudio_player_copy_meta_bytes(
    const miniaudio_player_t *player,
    uint8_t *out_buffer,
    size_t max_len)
{
    if (player == NULL || out_buffer == NULL || max_len == 0)
        return 0;

    miniaudio_player_t *mut = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut->lock);
    size_t copied = mut->stretch_ds.is_stream
        ? map_buffer_copy_meta_bytes(&mut->stretch_ds.buffer, out_buffer, max_len)
        : 0;
    ma_mutex_unlock(&mut->lock);
    return copied;
}

MAP_API int32_t miniaudio_player_set_icy_meta(
    miniaudio_player_t *player,
    const uint8_t *data,
    size_t size)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    if (player->stretch_ds.is_stream)
    {
        map_buffer_set_icy_meta(&player->stretch_ds.buffer, data, size);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_probe_tail(
    miniaudio_player_t *player,
    const uint8_t *tail_data,
    size_t tail_size,
    int64_t tail_offset)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    if (player->stretch_ds.is_stream)
    {
        map_buffer_probe_tail(&player->stretch_ds.buffer, tail_data, tail_size, tail_offset);

        map_container_format_t container = player->stretch_ds.buffer.container_format;
        if ((container == MAP_CONTAINER_OGG_VORBIS || container == MAP_CONTAINER_OGG_OPUS) &&
            tail_data != NULL && tail_size >= 27)
        {
            uint32_t srate = 0;
            if (player->stretch_ds.decoder.pBackend != NULL)
            {
                ma_data_source_get_data_format(player->stretch_ds.decoder.pBackend, NULL, NULL, &srate, NULL, 0);
            }
            if (srate == 0)
            {
                srate = player->stretch_ds.sampleRate;
            }
            int64_t dur_ms = 0;
            if (map_sniffer_extract_tail_duration_ms(container, srate, tail_data, tail_size, &dur_ms) && dur_ms > 0)
            {
                player->duration_ms = dur_ms;
                if (player->stretch_ds.sampleRate > 0)
                {
                    player->stretch_ds.totalFrames = (ma_uint64)(((double)dur_ms / 1000.0) * (double)player->stretch_ds.sampleRate + 0.5);
                }
                if (player->stretch_ds.buffer.total_size > 0)
                {
                    player->bitrate = (uint32_t)(((uint64_t)player->stretch_ds.buffer.total_size * 8000ULL) / (uint64_t)dur_ms);
                    map_event_dispatcher_post_bitrate(&player->dispatcher, player->bitrate);
                }
                map_event_dispatcher_post_duration(&player->dispatcher, player->duration_ms);
                map_event_dispatcher_flush(&player->dispatcher);
            }
        }
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_get_buffered_range(
    const miniaudio_player_t *player,
    miniaudio_buffered_range_t *out_range)
{
    if (player == NULL || out_range == NULL)
        return MAP_ERROR_INVALID_ARGS;

    miniaudio_player_t *mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);

    if (!mut_player->sound_loaded)
    {
        memset(out_range, 0, sizeof(*out_range));
        ma_mutex_unlock(&mut_player->lock);
        return MAP_SUCCESS;
    }

    out_range->duration_ms = mut_player->duration_ms;

    if (mut_player->stretch_ds.is_stream)
    {
        map_buffer_range_t r;
        map_buffer_get_range(&mut_player->stretch_ds.buffer, &r);

        if (mut_player->duration_ms > 0 && r.total_bytes > 0)
        {
            out_range->start_ms = (r.start_byte * mut_player->duration_ms) / r.total_bytes;
            out_range->end_ms = (r.end_byte * mut_player->duration_ms) / r.total_bytes;
        }
        else if (mut_player->bitrate > 0)
        {
            out_range->start_ms = (r.start_byte * 8000) / mut_player->bitrate;
            out_range->end_ms = (r.end_byte * 8000) / mut_player->bitrate;
        }
        else
        {
            out_range->start_ms = 0;
            out_range->end_ms = (r.end_byte > 0 && mut_player->duration_ms > 0) ? mut_player->duration_ms : 0;
        }

        if (out_range->end_ms > mut_player->duration_ms && mut_player->duration_ms > 0)
        {
            out_range->end_ms = mut_player->duration_ms;
        }

        out_range->fill_percentage = r.fill_percentage;
        out_range->stream_percentage = r.stream_percentage;
        out_range->is_buffering = r.is_buffering;
        out_range->is_eof = r.is_eof;
    }
    else
    {
        out_range->start_ms = 0;
        out_range->end_ms = mut_player->duration_ms;
        out_range->fill_percentage = 1.0f;
        out_range->stream_percentage = 1.0f;
        out_range->is_buffering = 0;
        out_range->is_eof = 1;
    }

    ma_mutex_unlock(&mut_player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_read_pcm_frames(
    miniaudio_player_t *player,
    void *frames_out,
    uint32_t frame_count,
    uint32_t *out_frames_read)
{
    if (player == NULL || frames_out == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_uint64 read = 0;
    ma_result res = ma_engine_read_pcm_frames(&player->engine, frames_out, (ma_uint64)frame_count, &read);
    if (out_frames_read != NULL)
    {
        *out_frames_read = (uint32_t)read;
    }
    return (res == MA_SUCCESS) ? MAP_SUCCESS : MAP_ERROR_DECODE_FAILED;
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
    miniaudio_player_playback_state_t cur_state =
        (miniaudio_player_playback_state_t)ma_atomic_load_32(&player->state);
    if (!player->sound_loaded || cur_state == MAP_PLAYBACK_STATE_OPENING)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    /* Auto-rewind on caller thread if at end or marked completed */
    if (ma_atomic_load_32(&player->is_completed) || ma_sound_at_end(&player->sound))
    {
        ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
        ma_node_set_time(&player->sound, 0);
        map_time_stretch_ds_seek_stream(&player->stretch_ds, 0, player->audio_data_offset);
        ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
        ma_atomic_store_32(&player->is_completed, 0);
        map_event_dispatcher_post_completed(&player->dispatcher, 0);
        map_event_dispatcher_post_position(&player->dispatcher, 0);
    }

    result = ma_sound_start(&player->sound);
    if (result != MA_SUCCESS)
    {
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_start failed: %d", result);
        return MAP_ERROR_GENERIC;
    }

    map_player_set_state(player, MAP_PLAYBACK_STATE_PLAYING);
    map_event_dispatcher_flush(&player->dispatcher);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_pause(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "pause command");

    ma_mutex_lock(&player->lock);
    miniaudio_player_playback_state_t cur_state =
        (miniaudio_player_playback_state_t)ma_atomic_load_32(&player->state);
    if (!player->sound_loaded || cur_state == MAP_PLAYBACK_STATE_OPENING)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_sound_stop(&player->sound);
    if (player->stretch_ds.is_stream)
    {
        map_buffer_set_buffering(&player->stretch_ds.buffer, MA_FALSE);
    }
    map_player_set_state(player, MAP_PLAYBACK_STATE_PAUSED);
    map_event_dispatcher_post_buffering(&player->dispatcher, 0);
    map_event_dispatcher_flush(&player->dispatcher);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_stop(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "stop command");

    ma_mutex_lock(&player->lock);
    miniaudio_player_playback_state_t cur_state =
        (miniaudio_player_playback_state_t)ma_atomic_load_32(&player->state);
    if (cur_state == MAP_PLAYBACK_STATE_OPENING)
    {
        /* Stop explicitly cancels opening and returns to STOPPED */
        map_player_set_state(player, MAP_PLAYBACK_STATE_STOPPED);
        map_event_dispatcher_post_position(&player->dispatcher, 0);
        map_event_dispatcher_flush(&player->dispatcher);
        ma_mutex_unlock(&player->lock);
        return MAP_SUCCESS;
    }
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_sound_stop(&player->sound);
    ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
    ma_node_set_time(&player->sound, 0);
    map_time_stretch_ds_seek_stream(&player->stretch_ds, 0, player->audio_data_offset);
    ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
    map_player_set_state(player, MAP_PLAYBACK_STATE_STOPPED);
    map_event_dispatcher_post_position(&player->dispatcher, 0);
    map_event_dispatcher_flush(&player->dispatcher);
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_seek(miniaudio_player_t *player, int64_t position_ms)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "seek to %lld ms", (long long)position_ms);

    ma_mutex_lock(&player->lock);
    miniaudio_player_playback_state_t cur_state =
        (miniaudio_player_playback_state_t)ma_atomic_load_32(&player->state);
    if (!player->sound_loaded || cur_state == MAP_PLAYBACK_STATE_OPENING)
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

    if (position_ms >= player->duration_ms && player->duration_ms > 0)
    {
        ma_sound_stop(&player->sound);
        ma_uint64 total_frames = player->stretch_ds.totalFrames;
        ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
        ma_node_set_time(&player->sound, total_frames);
        player->stretch_ds.readCursorFrames = total_frames;
        ma_atomic_exchange_32(&player->sound.atEnd, MA_TRUE);
        map_player_set_state(player, MAP_PLAYBACK_STATE_COMPLETED);
        map_event_dispatcher_post_position(&player->dispatcher, position_ms);
        map_event_dispatcher_flush(&player->dispatcher);
    }
    else
    {
        int64_t seek_byte = map_player_get_seek_byte_locked(player, position_ms);
        ma_uint64 targetFrame = (ma_uint64)(((double)position_ms / 1000.0) * (double)player->stretch_ds.sampleRate);
        ma_atomic_exchange_64(&player->sound.seekTarget, MA_SEEK_TARGET_NONE);
        ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
        ma_node_set_time(&player->sound, targetFrame);
        map_time_stretch_ds_seek_stream(&player->stretch_ds, targetFrame, seek_byte);

        if (cur_state == MAP_PLAYBACK_STATE_COMPLETED)
        {
            map_player_set_state(player, MAP_PLAYBACK_STATE_PAUSED);
        }
        else
        {
            map_player_set_state(player, cur_state);
        }
        map_event_dispatcher_post_position(&player->dispatcher, position_ms);
        map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_volume(&player->dispatcher, volume);
    map_event_dispatcher_flush(&player->dispatcher);
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
        map_time_stretch_ds_set_speed(&player->stretch_ds, rate);
    }
    map_event_dispatcher_post_rate(&player->dispatcher, rate);
    map_event_dispatcher_flush(&player->dispatcher);
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
        map_time_stretch_ds_set_pitch(&player->stretch_ds, pitch);
    }
    map_event_dispatcher_post_pitch(&player->dispatcher, pitch);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_buffer_size(&player->dispatcher, buffer_size_in_frames);
    map_event_dispatcher_flush(&player->dispatcher);
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

#if defined(MA_NO_DEVICE_IO)
MAP_API int32_t miniaudio_player_set_device(
    miniaudio_player_t *player,
    const char *device_id)
{
    (void)player;
    (void)device_id;
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_get_current_device(
    const miniaudio_player_t *player,
    miniaudio_device_info_t *out_device)
{
    (void)player;
    if (out_device != NULL)
    {
        memset(out_device, 0, sizeof(*out_device));
        strcpy(out_device->name, "System Default");
        out_device->is_default = 1;
        out_device->is_auto = 1;
    }
    return MAP_SUCCESS;
}
#else
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
#endif

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
        map_event_dispatcher_post_equalizer(&player->dispatcher, eq);
        map_event_dispatcher_flush(&player->dispatcher);
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
        map_event_dispatcher_post_equalizer(&player->dispatcher, &player->eq_params);
        map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_replay_gain(&player->dispatcher, &player->eq_node.rg_config);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_replay_gain(&player->dispatcher, &player->eq_node.rg_config);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_preamp(&player->dispatcher, preamp_db);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_balance(&player->dispatcher, pan);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_mono(&player->dispatcher, player->eq_node.mono_enabled);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_crossfeed(&player->dispatcher, mode);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_spatializer(&player->dispatcher, player->eq_node.spatializer_enabled, width);
    map_event_dispatcher_flush(&player->dispatcher);
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
    miniaudio_player_reverb_config_t rev_cfg;

    if (player == NULL) return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);
    ma_spinlock_lock(&player->eq_node.lock);

    player->eq_node.reverb_enabled = (enabled != 0) ? 1 : 0;
    map_reverb_set_params(&player->eq_node.reverb, enabled, room_size, damping, width, wet, dry);

    rev_cfg.enabled = player->eq_node.reverb_enabled;
    rev_cfg.room_size = room_size;
    rev_cfg.damping = damping;
    rev_cfg.width = width;
    rev_cfg.wet = wet;
    rev_cfg.dry = dry;

    ma_spinlock_unlock(&player->eq_node.lock);
    map_event_dispatcher_post_reverb(&player->dispatcher, &rev_cfg);
    map_event_dispatcher_flush(&player->dispatcher);
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
    map_event_dispatcher_post_limiter(&player->dispatcher, player->eq_node.limiter_enabled);
    map_event_dispatcher_flush(&player->dispatcher);
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

    map_event_dispatcher_post_silence_config(&player->dispatcher, &player->silence_config);
    map_event_dispatcher_flush(&player->dispatcher);
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
    if (mut_player->sound_loaded && mut_player->stretch_ds.is_stream)
    {
        map_buffer_range_t r;
        map_buffer_get_range(&mut_player->stretch_ds.buffer, &r);
        out_status->is_buffering = r.is_buffering;
    }
    else
    {
        out_status->is_buffering = mut_player->is_buffering;
    }
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

    miniaudio_player_playback_state_t cur_state =
        (miniaudio_player_playback_state_t)ma_atomic_load_32(&mut_player->state);
    ma_int32 is_completed = ma_atomic_load_32(&mut_player->is_completed);

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

        if (cur_state == MAP_PLAYBACK_STATE_OPENING)
        {
            out_status->is_completed = 0;
            out_status->is_playing = 0;
            out_status->is_buffering = 0;
            out_status->position_ms = 0;
            out_status->state = MAP_PLAYBACK_STATE_OPENING;
        }
        else if (cur_state == MAP_PLAYBACK_STATE_STOPPED)
        {
            out_status->is_completed = 0;
            out_status->is_playing = 0;
            out_status->is_buffering = 0;
            out_status->state = MAP_PLAYBACK_STATE_STOPPED;
        }
        else if (cur_state == MAP_PLAYBACK_STATE_PAUSED)
        {
            out_status->is_completed = 0;
            out_status->is_playing = 0;
            out_status->is_buffering = 0;
            out_status->state = MAP_PLAYBACK_STATE_PAUSED;
        }
        else if (cur_state == MAP_PLAYBACK_STATE_PLAYING)
        {
            if (is_completed || ma_sound_at_end(&mut_player->sound))
            {
                out_status->is_completed = 1;
                out_status->is_playing = 0;
                out_status->is_buffering = 0;
                out_status->state = MAP_PLAYBACK_STATE_COMPLETED;
                if (mut_player->duration_ms > 0)
                {
                    out_status->position_ms = mut_player->duration_ms;
                }
            }
            else
            {
                out_status->is_completed = 0;
                out_status->is_playing = ma_sound_is_playing(&mut_player->sound) ? 1 : 0;
                out_status->state = MAP_PLAYBACK_STATE_PLAYING;
            }
        }
        else if (cur_state == MAP_PLAYBACK_STATE_COMPLETED)
        {
            out_status->is_completed = 1;
            out_status->is_playing = 0;
            out_status->is_buffering = 0;
            out_status->state = MAP_PLAYBACK_STATE_COMPLETED;
            if (mut_player->duration_ms > 0)
            {
                out_status->position_ms = mut_player->duration_ms;
            }
        }
        else
        {
            out_status->is_completed = 0;
            out_status->is_playing = 0;
            out_status->state = cur_state;
        }
    }
    else
    {
        out_status->state = cur_state;
        out_status->is_completed = is_completed ? 1 : 0;
        out_status->is_playing = 0;
        out_status->is_buffering = 0;
    }

#if !defined(MA_NO_DEVICE_IO)
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
#else
    memset(&out_status->device, 0, sizeof(out_status->device));
    strcpy(out_status->device.name, "System Default");
    out_status->device.is_default = 1;
    out_status->device.is_auto = 1;
#endif

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

MAP_API uint32_t miniaudio_player_get_sample_rate(const miniaudio_player_t *player)
{
    if (player == NULL)
        return 0;
    return player->sample_rate;
}

MAP_API uint32_t miniaudio_player_get_channels(const miniaudio_player_t *player)
{
    if (player == NULL)
        return 0;
    return player->channels;
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
    map_event_dispatcher_post_visualizer_enabled(&player->dispatcher, player->eq_node.visualizer_enabled);
    map_event_dispatcher_flush(&player->dispatcher);
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
