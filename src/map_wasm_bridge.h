/**
 * @file map_wasm_bridge.h
 * @brief WebAssembly C99 bridge for miniaudio_player without int64_t/BigInt exposure.
 */

#ifndef MAP_WASM_BRIDGE_H
#define MAP_WASM_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include "miniaudio_player.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Staging buffer */
#define MAP_WASM_STAGING_SIZE (64 * 1024)
MAP_API uint8_t *map_wasm_get_staging_ptr(void);
MAP_API uint32_t map_wasm_get_staging_capacity(void);

/* Lifecycle */
MAP_API void map_wasm_set_log_level(int32_t level);
MAP_API miniaudio_player_t *map_wasm_player_create(uint32_t sample_rate, uint32_t channels, uint32_t period_size);
MAP_API void map_wasm_player_destroy(miniaudio_player_t *player);

/* Memory allocations */
MAP_API void *map_wasm_malloc(uint32_t size);
MAP_API void map_wasm_free(void *ptr);

/* Transport */
MAP_API int32_t map_wasm_play(miniaudio_player_t *player);
MAP_API int32_t map_wasm_pause(miniaudio_player_t *player);
MAP_API int32_t map_wasm_stop(miniaudio_player_t *player);
MAP_API int32_t map_wasm_seek(miniaudio_player_t *player, double position_ms);
MAP_API double map_wasm_get_position_ms(const miniaudio_player_t *player);
MAP_API double map_wasm_get_duration_ms(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_get_state(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_is_playing(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_is_buffering(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_is_completed(const miniaudio_player_t *player);
MAP_API double map_wasm_get_silence_saved_ms(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_get_bitrate(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_get_sample_rate(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_get_channels(const miniaudio_player_t *player);

/* Source Opening */
MAP_API int32_t map_wasm_open_memory(miniaudio_player_t *player, const uint8_t *data, uint32_t data_size);
MAP_API int32_t map_wasm_open_stream(
    miniaudio_player_t *player,
    const uint8_t *initial_data,
    uint32_t initial_data_size,
    double total_size,
    int32_t is_live,
    uint32_t buffer_capacity_bytes,
    int32_t encoding_format);
MAP_API int32_t map_wasm_open_stream_ex(
    miniaudio_player_t *player,
    const uint8_t *initial_data,
    uint32_t initial_data_size,
    const uint8_t *tail_data,
    uint32_t tail_data_size,
    double total_size,
    int32_t is_live,
    uint32_t buffer_capacity_bytes,
    int32_t encoding_format);

/* Streaming and Buffer Control */
MAP_API int32_t map_wasm_stream_feed(miniaudio_player_t *player, const uint8_t *data, uint32_t data_size);
MAP_API int32_t map_wasm_stream_flush(miniaudio_player_t *player, double new_stream_offset);
MAP_API int32_t map_wasm_stream_seek(miniaudio_player_t *player, double position_ms, double new_stream_offset);
MAP_API double map_wasm_stream_get_seek_byte(const miniaudio_player_t *player, double position_ms);
MAP_API double map_wasm_get_audio_data_offset(const miniaudio_player_t *player);
MAP_API double map_wasm_stream_get_pinned_head_size(const miniaudio_player_t *player);
MAP_API int32_t map_wasm_stream_end(miniaudio_player_t *player);
MAP_API int32_t map_wasm_probe_tail(miniaudio_player_t *player, const uint8_t *tail_data, uint32_t tail_size, double tail_offset);

/* DSP and Parameters */
MAP_API void map_wasm_set_volume(miniaudio_player_t *player, float volume);
MAP_API float map_wasm_get_volume(const miniaudio_player_t *player);
MAP_API void map_wasm_set_playback_rate(miniaudio_player_t *player, float rate);
MAP_API float map_wasm_get_playback_rate(const miniaudio_player_t *player);
MAP_API void map_wasm_set_pitch(miniaudio_player_t *player, float pitch);
MAP_API float map_wasm_get_pitch(const miniaudio_player_t *player);
MAP_API void map_wasm_set_pan(miniaudio_player_t *player, float pan);
MAP_API void map_wasm_set_mono(miniaudio_player_t *player, int32_t enabled);
MAP_API void map_wasm_set_spatializer(miniaudio_player_t *player, int32_t enabled, float width);
MAP_API void map_wasm_set_preamp(miniaudio_player_t *player, float preamp_db);
MAP_API void map_wasm_set_replay_gain(
    miniaudio_player_t *player,
    int32_t enabled,
    float gain_db,
    float peak,
    float preamp_db,
    int32_t prevent_clipping);
MAP_API void map_wasm_clear_replay_gain(miniaudio_player_t *player);
MAP_API void map_wasm_set_equalizer_band(miniaudio_player_t *player, uint32_t band, float gain_db);
MAP_API void map_wasm_set_equalizer_bands(miniaudio_player_t *player, const float *gains_db, uint32_t count);
MAP_API void map_wasm_set_equalizer_enabled(miniaudio_player_t *player, int32_t enabled);
MAP_API void map_wasm_set_reverb(miniaudio_player_t *player, int32_t enabled, float room_size, float damping, float width, float wet, float dry);
MAP_API void map_wasm_set_reverb_enabled(miniaudio_player_t *player, int32_t enabled);
MAP_API void map_wasm_set_reverb_preset(miniaudio_player_t *player, int32_t preset);
MAP_API void map_wasm_set_crossfeed_enabled(miniaudio_player_t *player, int32_t enabled);
MAP_API void map_wasm_set_crossfeed_preset(miniaudio_player_t *player, int32_t preset);
MAP_API void map_wasm_set_limiter_enabled(miniaudio_player_t *player, int32_t enabled);
MAP_API void map_wasm_set_silence_skip(miniaudio_player_t *player, int32_t mode, float threshold_db, uint32_t min_duration_ms);
MAP_API void map_wasm_set_visualizer_enabled(miniaudio_player_t *player, int32_t enabled);

/* Real-Time PCM Audio Rendering with SIMD Deinterleave */
MAP_API uint32_t map_wasm_render_pcm_frames(
    miniaudio_player_t *player,
    float *out_frames,
    uint32_t frame_count);

/* Unified Telemetry */
MAP_API void map_wasm_poll_telemetry(
    miniaudio_player_t *player,
    double *out_telemetry_f64);

/* Offline Audio Analysis */
MAP_API int32_t map_wasm_analyze_audio_memory(
    const void *data,
    uint32_t data_size,
    uint32_t flags,
    float target_lufs,
    uint32_t waveform_points,
    double *out_data,
    float **out_waveform_points);

#ifdef __cplusplus
}
#endif

#endif /* MAP_WASM_BRIDGE_H */
