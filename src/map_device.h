/**
 * @file map_device.h
 * @brief Audio hardware device enumeration, string serialization, and platform routing.
 */

#ifndef MAP_DEVICE_H
#define MAP_DEVICE_H

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"

#if defined(__ANDROID__)
int ma_android_sdk_version(void);
#endif

#if !defined(MA_NO_DEVICE_IO)
void map_device_id_to_string(const ma_device_id *pID, char *out_str, size_t max_len);
ma_bool32 map_string_to_device_id(const char *str, ma_device_id *out_id);
ma_bool32 map_is_device_connected(ma_context *pContext, const ma_device_id *pTargetID);
#endif
ma_bool32 map_is_device_id_default(const char *str);

MAP_API int32_t miniaudio_player_get_devices(
    miniaudio_device_info_t **out_devices,
    uint32_t *out_count);

MAP_API void miniaudio_player_free_devices(
    miniaudio_device_info_t *devices,
    uint32_t count);

MAP_API void miniaudio_player_set_jvm(void *jvm);

#endif /* MAP_DEVICE_H */
