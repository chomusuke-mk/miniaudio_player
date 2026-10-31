/**
 * @file miniaudio_device_bridge.c
 * @brief Bridge ultradelgado C99 para la gestión de dispositivos de audio del SO con miniaudio.h.
 *
 * Utiliza miniaudio.h 100% original e intacto, configurado exclusivamente como
 * capa de hardware de audio (ma_device y ma_context).
 */

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include "miniaudio_device_bridge.h"

#include <stdlib.h>
#include <string.h>

#if defined(__ANDROID__)
static MA_PFN_AAudioStream_waitForStateChange g_orig_AAudioStream_waitForStateChange = NULL;

static ma_aaudio_result_t map_aaudio_waitForStateChange_hook(
    ma_AAudioStream* stream,
    ma_aaudio_stream_state_t inputState,
    ma_aaudio_stream_state_t* nextState,
    int64_t timeoutNanoseconds)
{
    (void)timeoutNanoseconds;
    if (g_orig_AAudioStream_waitForStateChange == NULL) {
        return -1;
    }

    /* Timeout defensivo de 1 segundo en lugar de 5 segundos */
    int64_t safeTimeout = 1000000000LL;
    ma_aaudio_result_t resultAA = g_orig_AAudioStream_waitForStateChange(stream, inputState, nextState, safeTimeout);
    if (resultAA != 0 /* AAUDIO_OK */) {
        /* En caso de timeout o discrepancia en Android, consultar estado real */
        if (nextState != NULL) {
            /* Devolvemos éxito si ya está en estado STARTING o STARTED para reproducción */
            if (inputState == 2 /* STARTING */ || inputState == 3 /* STARTED */) {
                return 0;
            }
        }
    }
    return resultAA;
}
#endif

struct map_device_context {
    ma_context context;
    ma_device device;
    ma_bool32 has_context;
    ma_bool32 is_device_init;
    void* rust_user_data;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t period_size_in_frames;
    map_device_info_t current_device_info;
};

static void map_device_id_to_string(const ma_device_id* pID, char* out_str, size_t max_len) {
    if (out_str == NULL || max_len == 0) return;
    if (pID == NULL || max_len < (sizeof(ma_device_id) * 2 + 1)) {
        out_str[0] = '\0';
        return;
    }
    const unsigned char* bytes = (const unsigned char*)pID;
    for (size_t i = 0; i < sizeof(ma_device_id); i++) {
        sprintf(out_str + (i * 2), "%02x", bytes[i]);
    }
    out_str[sizeof(ma_device_id) * 2] = '\0';
}

static ma_bool32 map_string_to_device_id(const char* str, ma_device_id* out_id) {
    if (str == NULL || out_id == NULL) return MA_FALSE;
    memset(out_id, 0, sizeof(ma_device_id));
    if (strlen(str) == sizeof(ma_device_id) * 2) {
        unsigned char* bytes = (unsigned char*)out_id;
        for (size_t i = 0; i < sizeof(ma_device_id); i++) {
            unsigned int val;
            if (sscanf(str + (i * 2), "%02x", &val) != 1) {
                return MA_FALSE;
            }
            bytes[i] = (unsigned char)val;
        }
        return MA_TRUE;
    }
    return MA_FALSE;
}

static void map_device_data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pInput;
    map_device_context_t* ctx = (map_device_context_t*)pDevice->pUserData;
    if (ctx != NULL) {
        rust_render_pcm_frames(ctx->rust_user_data, (float*)pOutput, (uint32_t)frameCount);
    }
}

static void map_device_notification_callback(const ma_device_notification* pNotification) {
    if (pNotification == NULL || pNotification->pDevice == NULL) {
        return;
    }
    map_device_context_t* ctx = (map_device_context_t*)pNotification->pDevice->pUserData;
    if (ctx != NULL) {
        rust_on_device_notification(ctx->rust_user_data, (int32_t)pNotification->type);
    }
}

map_device_context_t* map_device_create(
    uint32_t sample_rate,
    uint32_t channels,
    uint32_t period_size_in_frames,
    const char* playback_device_id,
    void* rust_user_data,
    int32_t* out_result
) {
    map_device_context_t* ctx = (map_device_context_t*)calloc(1, sizeof(map_device_context_t));
    if (ctx == NULL) {
        if (out_result) *out_result = -3; /* OUT_OF_MEMORY */
        return NULL;
    }

    ctx->rust_user_data = rust_user_data;
    ctx->sample_rate = sample_rate ? sample_rate : 44100;
    ctx->channels = channels ? channels : 2;
    ctx->period_size_in_frames = period_size_in_frames;

    ma_context_config ctx_cfg = ma_context_config_init();
    ma_result res = ma_context_init(NULL, 0, &ctx_cfg, &ctx->context);
    if (res != MA_SUCCESS) {
        free(ctx);
        if (out_result) *out_result = -4; /* ENGINE_INIT */
        return NULL;
    }
    ctx->has_context = MA_TRUE;

#if defined(__ANDROID__)
    /* Intercepción limpia del hook de AAudio sin tocar miniaudio.h */
    if (ctx->context.backend == ma_backend_aaudio && ctx->context.aaudio.AAudioStream_waitForStateChange != NULL) {
        g_orig_AAudioStream_waitForStateChange = ctx->context.aaudio.AAudioStream_waitForStateChange;
        ctx->context.aaudio.AAudioStream_waitForStateChange = map_aaudio_waitForStateChange_hook;
    }
#endif

    ma_device_config dev_cfg = ma_device_config_init(ma_device_type_playback);
    dev_cfg.playback.format = ma_format_f32;
    dev_cfg.playback.channels = ctx->channels;
    dev_cfg.sampleRate = ctx->sample_rate;
    dev_cfg.periodSizeInFrames = period_size_in_frames;
    dev_cfg.dataCallback = map_device_data_callback;
    dev_cfg.notificationCallback = map_device_notification_callback;
    dev_cfg.pUserData = ctx;

    ma_device_id custom_id;
    ma_bool32 found = MA_FALSE;
    if (playback_device_id != NULL && strlen(playback_device_id) > 0 && strcmp(playback_device_id, "auto") != 0) {
        ma_device_info* pPlaybackInfos = NULL;
        ma_uint32 playbackCount = 0;
        if (ma_context_get_devices(&ctx->context, &pPlaybackInfos, &playbackCount, NULL, NULL) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < playbackCount; ++i) {
                char dev_hex[sizeof(ma_device_id) * 2 + 1];
                map_device_id_to_string(&pPlaybackInfos[i].id, dev_hex, sizeof(dev_hex));
                if (strcmp(pPlaybackInfos[i].name, playback_device_id) == 0 ||
                    strcmp(dev_hex, playback_device_id) == 0) {
                    custom_id = pPlaybackInfos[i].id;
                    dev_cfg.playback.pDeviceID = &custom_id;
                    found = MA_TRUE;
                    break;
                }
            }
        }
        if (!found) {
            if (map_string_to_device_id(playback_device_id, &custom_id)) {
                dev_cfg.playback.pDeviceID = &custom_id;
                found = MA_TRUE;
            }
        }
        if (!found) {
            playback_device_id = "auto";
        }
    }

    res = ma_device_init(&ctx->context, &dev_cfg, &ctx->device);
    if (res != MA_SUCCESS && dev_cfg.playback.pDeviceID != NULL) {
        dev_cfg.playback.pDeviceID = NULL;
        playback_device_id = "auto";
        res = ma_device_init(&ctx->context, &dev_cfg, &ctx->device);
    }
    if (res != MA_SUCCESS) {
        ma_context_uninit(&ctx->context);
        free(ctx);
        if (out_result) *out_result = -4; /* ENGINE_INIT */
        return NULL;
    }
    ctx->is_device_init = MA_TRUE;
    ctx->sample_rate = ctx->device.sampleRate;
    ctx->channels = ctx->device.playback.channels;

    /* Actualizar información de dispositivo actual */
    if (playback_device_id && strlen(playback_device_id) > 0 && strcmp(playback_device_id, "auto") != 0) {
        strncpy(ctx->current_device_info.id, playback_device_id, sizeof(ctx->current_device_info.id) - 1);
        ctx->current_device_info.is_auto = 0;
        ctx->current_device_info.is_default = (ctx->current_device_info.is_auto ? 1 : 0);
    } else {
        strcpy(ctx->current_device_info.id, "auto");
        ctx->current_device_info.is_auto = 1;
        ctx->current_device_info.is_default = 1;
    }
    map_device_id_to_string(&ctx->device.playback.id, ctx->current_device_info.effective_id, sizeof(ctx->current_device_info.effective_id));
    strncpy(ctx->current_device_info.name, ctx->device.playback.name, sizeof(ctx->current_device_info.name) - 1);
    ctx->current_device_info.is_default = (ctx->current_device_info.is_auto ? 1 : 0);

    if (out_result) *out_result = 0;
    return ctx;
}

int32_t map_device_start(map_device_context_t* ctx) {
    if (ctx == NULL || !ctx->is_device_init) return -2;
    return (int32_t)ma_device_start(&ctx->device);
}

int32_t map_device_stop(map_device_context_t* ctx) {
    if (ctx == NULL || !ctx->is_device_init) return -2;
    return (int32_t)ma_device_stop(&ctx->device);
}

int32_t map_device_destroy(map_device_context_t* ctx) {
    if (ctx == NULL) return 0;
    if (ctx->is_device_init) {
        ma_device_uninit(&ctx->device);
        ctx->is_device_init = MA_FALSE;
    }
    if (ctx->has_context) {
        ma_context_uninit(&ctx->context);
        ctx->has_context = MA_FALSE;
    }
    free(ctx);
    return 0;
}

uint32_t map_device_get_sample_rate(const map_device_context_t* ctx) {
    return ctx ? ctx->sample_rate : 0;
}

uint32_t map_device_get_channels(const map_device_context_t* ctx) {
    return ctx ? ctx->channels : 0;
}

int32_t map_device_get_current_device_info(const map_device_context_t* ctx, map_device_info_t* out_device) {
    if (ctx == NULL || out_device == NULL) return -2;
    *out_device = ctx->current_device_info;
    return 0;
}

int32_t map_device_set_device(map_device_context_t* ctx, const char* device_id) {
    if (ctx == NULL) return -2;

    ma_bool32 was_started = (ctx->is_device_init && ma_device_is_started(&ctx->device));
    if (ctx->is_device_init) {
        ma_device_uninit(&ctx->device);
        ctx->is_device_init = MA_FALSE;
    }

    ma_device_config dev_cfg = ma_device_config_init(ma_device_type_playback);
    dev_cfg.playback.format = ma_format_f32;
    dev_cfg.playback.channels = ctx->channels;
    dev_cfg.sampleRate = ctx->sample_rate;
    dev_cfg.periodSizeInFrames = ctx->period_size_in_frames;
    dev_cfg.dataCallback = map_device_data_callback;
    dev_cfg.notificationCallback = map_device_notification_callback;
    dev_cfg.pUserData = ctx;

    ma_device_id custom_id;
    ma_bool32 found = MA_FALSE;
    if (device_id != NULL && strlen(device_id) > 0 && strcmp(device_id, "auto") != 0) {
        ma_device_info* pPlaybackInfos = NULL;
        ma_uint32 playbackCount = 0;
        if (ma_context_get_devices(&ctx->context, &pPlaybackInfos, &playbackCount, NULL, NULL) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < playbackCount; ++i) {
                char dev_hex[sizeof(ma_device_id) * 2 + 1];
                map_device_id_to_string(&pPlaybackInfos[i].id, dev_hex, sizeof(dev_hex));
                if (strcmp(pPlaybackInfos[i].name, device_id) == 0 ||
                    strcmp(dev_hex, device_id) == 0) {
                    custom_id = pPlaybackInfos[i].id;
                    dev_cfg.playback.pDeviceID = &custom_id;
                    found = MA_TRUE;
                    break;
                }
            }
        }
        if (!found) {
            if (map_string_to_device_id(device_id, &custom_id)) {
                dev_cfg.playback.pDeviceID = &custom_id;
                found = MA_TRUE;
            }
        }
        if (!found) {
            dev_cfg.playback.pDeviceID = NULL;
            device_id = "auto";
        }
    }

    ma_result res = ma_device_init(&ctx->context, &dev_cfg, &ctx->device);
    if (res != MA_SUCCESS && dev_cfg.playback.pDeviceID != NULL) {
        dev_cfg.playback.pDeviceID = NULL;
        device_id = "auto";
        res = ma_device_init(&ctx->context, &dev_cfg, &ctx->device);
    }
    if (res != MA_SUCCESS) {
        return -4;
    }
    ctx->is_device_init = MA_TRUE;
    ctx->sample_rate = ctx->device.sampleRate;
    ctx->channels = ctx->device.playback.channels;

    if (device_id && strlen(device_id) > 0 && strcmp(device_id, "auto") != 0) {
        strncpy(ctx->current_device_info.id, device_id, sizeof(ctx->current_device_info.id) - 1);
        ctx->current_device_info.is_auto = 0;
        ctx->current_device_info.is_default = (ctx->current_device_info.is_auto ? 1 : 0);
    } else {
        strcpy(ctx->current_device_info.id, "auto");
        ctx->current_device_info.is_auto = 1;
        ctx->current_device_info.is_default = 1;
    }
    map_device_id_to_string(&ctx->device.playback.id, ctx->current_device_info.effective_id, sizeof(ctx->current_device_info.effective_id));
    strncpy(ctx->current_device_info.name, ctx->device.playback.name, sizeof(ctx->current_device_info.name) - 1);

    if (was_started) {
        ma_device_start(&ctx->device);
    }
    return 0;
}

int32_t map_device_enumerate_devices(map_device_info_t** out_devices, uint32_t* out_count) {
    if (out_devices == NULL || out_count == NULL) return -2;
    *out_devices = NULL;
    *out_count = 0;

    ma_context context;
    ma_result res = ma_context_init(NULL, 0, NULL, &context);
    if (res != MA_SUCCESS) {
        return -4;
    }

    ma_device_info* pPlaybackInfos = NULL;
    ma_uint32 playbackCount = 0;
    res = ma_context_get_devices(&context, &pPlaybackInfos, &playbackCount, NULL, NULL);
    if (res != MA_SUCCESS) {
        ma_context_uninit(&context);
        return -4;
    }

    if (playbackCount > 0) {
        map_device_info_t* devices = (map_device_info_t*)calloc(playbackCount, sizeof(map_device_info_t));
        if (devices == NULL) {
            ma_context_uninit(&context);
            return -3;
        }

        for (ma_uint32 i = 0; i < playbackCount; ++i) {
            strncpy(devices[i].name, pPlaybackInfos[i].name, sizeof(devices[i].name) - 1);
            devices[i].name[sizeof(devices[i].name) - 1] = '\0';
            map_device_id_to_string(&pPlaybackInfos[i].id, devices[i].id, sizeof(devices[i].id));
            map_device_id_to_string(&pPlaybackInfos[i].id, devices[i].effective_id, sizeof(devices[i].effective_id));
            devices[i].is_default = pPlaybackInfos[i].isDefault;
            devices[i].is_auto = 0;
        }

        *out_devices = devices;
        *out_count = playbackCount;
    }

    ma_context_uninit(&context);
    return 0;
}

void map_device_free_devices(map_device_info_t* devices) {
    if (devices != NULL) {
        free(devices);
    }
}
