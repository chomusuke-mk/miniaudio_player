#ifndef MINIAUDIO_DEVICE_BRIDGE_H
#define MINIAUDIO_DEVICE_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct map_device_context map_device_context_t;

/* Callback exportado por Rust para renderizar tramas PCM f32 entrelazadas */
extern void rust_render_pcm_frames(void* user_data, float* output_frames, uint32_t frame_count);

/* Callback exportado por Rust para recibir notificaciones de hardware del SO */
extern void rust_on_device_notification(void* user_data, int32_t notification_type);

/* Funciones de control de dispositivo implementadas en C sobre miniaudio.h */
map_device_context_t* map_device_create(
    uint32_t sample_rate,
    uint32_t channels,
    uint32_t period_size_in_frames,
    const char* playback_device_id,
    void* rust_user_data,
    int32_t* out_result
);

int32_t map_device_start(map_device_context_t* ctx);
int32_t map_device_stop(map_device_context_t* ctx);
int32_t map_device_destroy(map_device_context_t* ctx);

uint32_t map_device_get_sample_rate(const map_device_context_t* ctx);
uint32_t map_device_get_channels(const map_device_context_t* ctx);
int32_t map_device_set_device(map_device_context_t* ctx, const char* device_id);

#ifdef __cplusplus
}
#endif

#endif /* MINIAUDIO_DEVICE_BRIDGE_H */
