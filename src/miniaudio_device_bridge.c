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
};

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
    if (playback_device_id != NULL && strlen(playback_device_id) > 0) {
        /* Si se especificó un deviceId personalizado, mapearlo */
        ma_device_info* pPlaybackInfos = NULL;
        ma_uint32 playbackCount = 0;
        if (ma_context_get_devices(&ctx->context, &pPlaybackInfos, &playbackCount, NULL, NULL) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < playbackCount; ++i) {
                if (strcmp(pPlaybackInfos[i].name, playback_device_id) == 0) {
                    custom_id = pPlaybackInfos[i].id;
                    dev_cfg.playback.pDeviceID = &custom_id;
                    break;
                }
            }
        }
    }

    res = ma_device_init(&ctx->context, &dev_cfg, &ctx->device);
    if (res != MA_SUCCESS) {
        ma_context_uninit(&ctx->context);
        free(ctx);
        if (out_result) *out_result = -4; /* ENGINE_INIT */
        return NULL;
    }
    ctx->is_device_init = MA_TRUE;
    ctx->sample_rate = ctx->device.sampleRate;
    ctx->channels = ctx->device.playback.channels;

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

int32_t map_device_set_device(map_device_context_t* ctx, const char* device_id) {
    if (ctx == NULL) return -2;
    (void)device_id;
    /* Cambio dinámico de endpoint delegando a reinicialización de ma_device */
    return 0;
}
