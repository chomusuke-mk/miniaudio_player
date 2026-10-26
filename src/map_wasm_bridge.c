/**
 * @file map_wasm_bridge.c
 * @brief WebAssembly C99 bridge implementation for miniaudio_player.
 */

#include "map_wasm_bridge.h"
#include "map_common.h"
#include "map_analysis.h"
#include <stdlib.h>
#include <string.h>

#define MAP_WASM_MAX_RENDER_FRAMES 4096
static float g_interleaved_buffer[MAP_WASM_MAX_RENDER_FRAMES * 2] __attribute__((aligned(64)));

static uint8_t g_wasm_staging_buffer[MAP_WASM_STAGING_SIZE] __attribute__((aligned(64)));

MAP_API uint8_t *map_wasm_get_staging_ptr(void)
{
    return g_wasm_staging_buffer;
}

MAP_API uint32_t map_wasm_get_staging_capacity(void)
{
    return MAP_WASM_STAGING_SIZE;
}

MAP_API void *map_wasm_malloc(uint32_t size)
{
    return malloc(size);
}

MAP_API void map_wasm_free(void *ptr)
{
    if (ptr != NULL)
    {
        free(ptr);
    }
}

MAP_API void map_wasm_set_log_level(int32_t level)
{
    miniaudio_player_set_log_level(level);
}

MAP_API miniaudio_player_t *map_wasm_player_create(uint32_t sample_rate, uint32_t channels, uint32_t period_size)
{
    miniaudio_player_config_t config;
    memset(&config, 0, sizeof(config));
    config.sample_rate = sample_rate > 0 ? sample_rate : 48000;
    config.channels = channels > 0 ? channels : 2;
    config.period_size_in_frames = period_size > 0 ? period_size : 2048;
    int32_t out_result = 0;
    return miniaudio_player_create(&config, &out_result);
}

MAP_API void map_wasm_player_destroy(miniaudio_player_t *player)
{
    if (player != NULL)
    {
        miniaudio_player_destroy(player);
    }
}

MAP_API int32_t map_wasm_play(miniaudio_player_t *player)
{
    return miniaudio_player_play(player);
}

MAP_API int32_t map_wasm_pause(miniaudio_player_t *player)
{
    return miniaudio_player_pause(player);
}

MAP_API int32_t map_wasm_stop(miniaudio_player_t *player)
{
    return miniaudio_player_stop(player);
}

MAP_API int32_t map_wasm_seek(miniaudio_player_t *player, double position_ms)
{
    return miniaudio_player_seek(player, (int64_t)position_ms);
}

MAP_API double map_wasm_get_position_ms(const miniaudio_player_t *player)
{
    return (double)miniaudio_player_get_position_ms(player);
}

MAP_API double map_wasm_get_duration_ms(const miniaudio_player_t *player)
{
    return (double)miniaudio_player_get_duration_ms(player);
}

MAP_API int32_t map_wasm_get_state(const miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_PLAYBACK_STATE_STOPPED;
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) == MAP_SUCCESS)
    {
        return status.state;
    }
    return MAP_PLAYBACK_STATE_STOPPED;
}

MAP_API int32_t map_wasm_is_playing(const miniaudio_player_t *player)
{
    return miniaudio_player_is_playing(player);
}

MAP_API int32_t map_wasm_is_buffering(const miniaudio_player_t *player)
{
    if (player == NULL)
        return 0;
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) == MAP_SUCCESS)
    {
        return status.is_buffering;
    }
    return 0;
}

MAP_API int32_t map_wasm_is_completed(const miniaudio_player_t *player)
{
    return miniaudio_player_is_completed(player);
}

MAP_API double map_wasm_get_silence_saved_ms(const miniaudio_player_t *player)
{
    return (double)miniaudio_player_get_silence_saved_ms(player);
}

MAP_API int32_t map_wasm_get_bitrate(const miniaudio_player_t *player)
{
    return miniaudio_player_get_bitrate(player);
}

MAP_API int32_t map_wasm_get_sample_rate(const miniaudio_player_t *player)
{
    return miniaudio_player_get_sample_rate(player);
}

MAP_API int32_t map_wasm_get_channels(const miniaudio_player_t *player)
{
    return miniaudio_player_get_channels(player);
}

MAP_API int32_t map_wasm_open_memory(miniaudio_player_t *player, const uint8_t *data, uint32_t data_size)
{
    return miniaudio_player_open_memory(player, data, (size_t)data_size, 1);
}

MAP_API int32_t map_wasm_open_stream(
    miniaudio_player_t *player,
    const uint8_t *initial_data,
    uint32_t initial_data_size,
    double total_size,
    int32_t is_live,
    uint32_t buffer_capacity_bytes,
    int32_t encoding_format)
{
    return miniaudio_player_open_stream(
        player,
        initial_data,
        (size_t)initial_data_size,
        (int64_t)total_size,
        is_live,
        buffer_capacity_bytes,
        encoding_format);
}

MAP_API int32_t map_wasm_open_stream_ex(
    miniaudio_player_t *player,
    const uint8_t *initial_data,
    uint32_t initial_data_size,
    const uint8_t *tail_data,
    uint32_t tail_data_size,
    double total_size,
    int32_t is_live,
    uint32_t buffer_capacity_bytes,
    int32_t encoding_format)
{
    return miniaudio_player_open_stream_ex(
        player,
        initial_data,
        (size_t)initial_data_size,
        tail_data,
        (size_t)tail_data_size,
        (int64_t)total_size,
        is_live,
        buffer_capacity_bytes,
        encoding_format);
}

MAP_API int32_t map_wasm_stream_feed(miniaudio_player_t *player, const uint8_t *data, uint32_t data_size)
{
    return miniaudio_player_stream_feed(player, data, (size_t)data_size);
}

MAP_API int32_t map_wasm_stream_flush(miniaudio_player_t *player, double new_stream_offset)
{
    return miniaudio_player_stream_flush(player, (int64_t)new_stream_offset);
}

MAP_API int32_t map_wasm_stream_seek(miniaudio_player_t *player, double position_ms, double new_stream_offset)
{
    return miniaudio_player_stream_seek(player, (int64_t)position_ms, (int64_t)new_stream_offset);
}

MAP_API double map_wasm_stream_get_seek_byte(const miniaudio_player_t *player, double position_ms)
{
    return (double)miniaudio_player_stream_get_seek_byte(player, (int64_t)position_ms);
}

MAP_API double map_wasm_get_audio_data_offset(const miniaudio_player_t *player)
{
    return (double)miniaudio_player_get_audio_data_offset(player);
}

MAP_API double map_wasm_stream_get_pinned_head_size(const miniaudio_player_t *player)
{
    return (double)miniaudio_player_stream_get_pinned_head_size(player);
}

MAP_API int32_t map_wasm_stream_end(miniaudio_player_t *player)
{
    return miniaudio_player_stream_end(player);
}

MAP_API int32_t map_wasm_probe_tail(miniaudio_player_t *player, const uint8_t *tail_data, uint32_t tail_size, double tail_offset)
{
    return miniaudio_player_probe_tail(player, tail_data, (size_t)tail_size, (int64_t)tail_offset);
}

MAP_API void map_wasm_set_volume(miniaudio_player_t *player, float volume)
{
    miniaudio_player_set_volume(player, volume);
}

MAP_API float map_wasm_get_volume(const miniaudio_player_t *player)
{
    return miniaudio_player_get_volume(player);
}

MAP_API void map_wasm_set_playback_rate(miniaudio_player_t *player, float rate)
{
    miniaudio_player_set_rate(player, rate);
}

MAP_API float map_wasm_get_playback_rate(const miniaudio_player_t *player)
{
    return miniaudio_player_get_rate(player);
}

MAP_API void map_wasm_set_pitch(miniaudio_player_t *player, float pitch)
{
    miniaudio_player_set_pitch(player, pitch);
}

MAP_API float map_wasm_get_pitch(const miniaudio_player_t *player)
{
    return miniaudio_player_get_pitch(player);
}

MAP_API void map_wasm_set_pan(miniaudio_player_t *player, float pan)
{
    miniaudio_player_set_balance(player, pan);
}

MAP_API void map_wasm_set_mono(miniaudio_player_t *player, int32_t enabled)
{
    miniaudio_player_set_mono(player, enabled);
}

MAP_API void map_wasm_set_spatializer(miniaudio_player_t *player, int32_t enabled, float width)
{
    miniaudio_player_set_spatializer(player, enabled, width);
}

MAP_API void map_wasm_set_preamp(miniaudio_player_t *player, float preamp_db)
{
    miniaudio_player_set_preamp(player, preamp_db);
}

MAP_API void map_wasm_set_replay_gain(
    miniaudio_player_t *player,
    int32_t enabled,
    float gain_db,
    float peak,
    int32_t prevent_clipping)
{
    if (player == NULL)
        return;
    if (enabled)
    {
        miniaudio_player_set_replay_gain(player, gain_db, peak, prevent_clipping);
    }
    else
    {
        miniaudio_player_clear_replay_gain(player);
    }
}

MAP_API void map_wasm_clear_replay_gain(miniaudio_player_t *player)
{
    miniaudio_player_clear_replay_gain(player);
}

MAP_API void map_wasm_set_reverb(miniaudio_player_t *player, int32_t enabled, float room_size, float damping, float width, float wet, float dry)
{
    miniaudio_player_set_reverb(player, enabled, room_size, damping, width, wet, dry);
}

MAP_API void map_wasm_set_equalizer_band(miniaudio_player_t *player, uint32_t band, float gain_db)
{
    miniaudio_player_set_equalizer_band(player, band, gain_db);
}

MAP_API void map_wasm_set_equalizer_bands(miniaudio_player_t *player, const float *gains_db, uint32_t count)
{
    if (player == NULL || gains_db == NULL)
        return;
    miniaudio_player_equalizer_params_t eq;
    memset(&eq, 0, sizeof(eq));
    float *pBands = (float *)&eq;
    for (uint32_t i = 0; i < 10 && i < count; i++)
    {
        pBands[i] = gains_db[i];
    }
    miniaudio_player_set_equalizer(player, &eq);
}

MAP_API void map_wasm_set_equalizer_enabled(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL)
        return;
    if (!enabled)
    {
        miniaudio_player_equalizer_params_t eq;
        memset(&eq, 0, sizeof(eq));
        miniaudio_player_set_equalizer(player, &eq);
    }
}

MAP_API void map_wasm_set_reverb_enabled(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL)
        return;
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) == MAP_SUCCESS)
    {
        miniaudio_player_set_reverb(player, enabled, status.reverb.room_size, status.reverb.damping,
                                   status.reverb.width, status.reverb.wet, status.reverb.dry);
    }
    else
    {
        miniaudio_player_set_reverb(player, enabled, 0.5f, 0.5f, 1.0f, 0.33f, 0.67f);
    }
}

MAP_API void map_wasm_set_reverb_preset(miniaudio_player_t *player, int32_t preset)
{
    if (player == NULL)
        return;
    switch (preset)
    {
        case 0: /* Small Room */
            miniaudio_player_set_reverb(player, 1, 0.3f, 0.6f, 0.7f, 0.25f, 0.75f);
            break;
        case 1: /* Medium Room */
            miniaudio_player_set_reverb(player, 1, 0.5f, 0.5f, 1.0f, 0.33f, 0.67f);
            break;
        case 2: /* Large Hall */
            miniaudio_player_set_reverb(player, 1, 0.8f, 0.3f, 1.0f, 0.45f, 0.55f);
            break;
        case 3: /* Plate */
            miniaudio_player_set_reverb(player, 1, 0.7f, 0.1f, 1.0f, 0.4f, 0.6f);
            break;
        default:
            miniaudio_player_set_reverb(player, 0, 0.5f, 0.5f, 1.0f, 0.33f, 0.67f);
            break;
    }
}

MAP_API void map_wasm_set_crossfeed_enabled(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL)
        return;
    miniaudio_player_set_crossfeed(player, enabled ? MAP_CROSSFEED_MOFFAT_BAUER : MAP_CROSSFEED_OFF);
}

MAP_API void map_wasm_set_crossfeed_preset(miniaudio_player_t *player, int32_t preset)
{
    if (player == NULL)
        return;
    miniaudio_player_set_crossfeed(player, preset);
}

MAP_API void map_wasm_set_limiter_enabled(miniaudio_player_t *player, int32_t enabled)
{
    miniaudio_player_set_limiter(player, enabled);
}

MAP_API void map_wasm_set_silence_skip(miniaudio_player_t *player, int32_t mode, float threshold_db, uint32_t min_duration_ms)
{
    if (player == NULL)
        return;
    miniaudio_player_silence_config_t cfg;
    cfg.mode = mode;
    cfg.threshold_db = threshold_db;
    cfg.min_silence_duration_ms = min_duration_ms;
    cfg.padding_ms = 50;
    miniaudio_player_set_silence_config(player, &cfg);
}

MAP_API void map_wasm_set_visualizer_enabled(miniaudio_player_t *player, int32_t enabled)
{
    miniaudio_player_set_visualizer_enabled(player, enabled);
}

MAP_API uint32_t map_wasm_render_pcm_frames(
    miniaudio_player_t *player,
    float *out_frames,
    uint32_t frame_count)
{
    if (player == NULL || out_frames == NULL || frame_count == 0)
        return 0;

    uint32_t to_render = frame_count;
    if (to_render > MAP_WASM_MAX_RENDER_FRAMES)
        to_render = MAP_WASM_MAX_RENDER_FRAMES;

    if (map_wasm_is_buffering(player))
    {
        memset(out_frames, 0, frame_count * 2 * sizeof(float));
        return 0;
    }

    uint32_t frames_read = 0;
    int32_t res = miniaudio_player_read_pcm_frames(player, g_interleaved_buffer, to_render, &frames_read);
    if (res != MAP_SUCCESS && frames_read == 0)
    {
        memset(out_frames, 0, frame_count * 2 * sizeof(float));
        return 0;
    }

    if (frames_read < to_render)
    {
        memset(&g_interleaved_buffer[frames_read * 2], 0, (to_render - frames_read) * 2 * sizeof(float));
    }

    float *out_left = out_frames;
    float *out_right = out_frames + frame_count;
    uint32_t i = 0;

#if defined(MAP_HAS_WASM_SIMD)
    for (; i + 3 < to_render; i += 4)
    {
        v128_t v0 = wasm_v128_load(&g_interleaved_buffer[i * 2]);     /* L0, R0, L1, R1 */
        v128_t v1 = wasm_v128_load(&g_interleaved_buffer[i * 2 + 4]); /* L2, R2, L3, R3 */

        v128_t v_L = wasm_i32x4_shuffle(v0, v1, 0, 2, 4, 6);        /* L0, L1, L2, L3 */
        v128_t v_R = wasm_i32x4_shuffle(v0, v1, 1, 3, 5, 7);        /* R0, R1, R2, R3 */

        wasm_v128_store(&out_left[i], v_L);
        wasm_v128_store(&out_right[i], v_R);
    }
#endif

    for (; i < to_render; i++)
    {
        out_left[i] = g_interleaved_buffer[i * 2];
        out_right[i] = g_interleaved_buffer[i * 2 + 1];
    }

    if (to_render < frame_count)
    {
        memset(&out_left[to_render], 0, (frame_count - to_render) * sizeof(float));
        memset(&out_right[to_render], 0, (frame_count - to_render) * sizeof(float));
    }

    return frames_read;
}

MAP_API void map_wasm_poll_telemetry(
    miniaudio_player_t *player,
    double *out_telemetry_f64)
{
    if (player == NULL || out_telemetry_f64 == NULL)
        return;

    memset(out_telemetry_f64, 0, 48 * sizeof(double));

    miniaudio_player_status_t status;
    memset(&status, 0, sizeof(status));
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
    {
        return;
    }

    out_telemetry_f64[0] = (double)status.position_ms;
    out_telemetry_f64[1] = (double)status.duration_ms;
    out_telemetry_f64[2] = (double)status.state;
    out_telemetry_f64[3] = status.is_playing ? 1.0 : 0.0;
    out_telemetry_f64[4] = status.is_buffering ? 1.0 : 0.0;
    out_telemetry_f64[5] = status.is_completed ? 1.0 : 0.0;
    out_telemetry_f64[6] = (double)status.bitrate;
    out_telemetry_f64[7] = (double)miniaudio_player_get_sample_rate(player);
    out_telemetry_f64[8] = (double)miniaudio_player_get_channels(player);
    out_telemetry_f64[9] = (double)status.silence_saved_ms;

    miniaudio_buffered_range_t buf_range;
    memset(&buf_range, 0, sizeof(buf_range));
    miniaudio_player_get_buffered_range(player, &buf_range);

    out_telemetry_f64[10] = (double)buf_range.start_ms;
    out_telemetry_f64[11] = (double)buf_range.end_ms;
    out_telemetry_f64[12] = (double)buf_range.fill_percentage;
    out_telemetry_f64[13] = (double)buf_range.stream_percentage;
    out_telemetry_f64[14] = buf_range.is_eof ? 1.0 : 0.0;

    out_telemetry_f64[15] = status.visualizer_enabled ? 1.0 : 0.0;
    for (int b = 0; b < 10; b++)
    {
        out_telemetry_f64[16 + b] = (double)status.visualizer.bands[b];
    }
    out_telemetry_f64[26] = (double)status.visualizer.rms;
    out_telemetry_f64[27] = (double)status.visualizer.peak;
    out_telemetry_f64[28] = (double)status.visualizer.left;
    out_telemetry_f64[29] = (double)status.visualizer.right;
    out_telemetry_f64[30] = (double)status.volume;
    out_telemetry_f64[31] = (double)status.rate;
    out_telemetry_f64[32] = (double)status.pitch;
    out_telemetry_f64[33] = (double)status.balance;
    out_telemetry_f64[34] = status.mono_enabled ? 1.0 : 0.0;
    out_telemetry_f64[35] = (double)status.crossfeed_mode;
    out_telemetry_f64[36] = status.spatializer_enabled ? 1.0 : 0.0;
    out_telemetry_f64[37] = (double)status.spatializer_width;
    out_telemetry_f64[38] = status.reverb.enabled ? 1.0 : 0.0;
    out_telemetry_f64[39] = status.limiter_enabled ? 1.0 : 0.0;
    out_telemetry_f64[40] = (double)status.preamp_db;
    out_telemetry_f64[41] = status.replay_gain.enabled ? 1.0 : 0.0;
    out_telemetry_f64[42] = (double)status.replay_gain.gain_db;
    out_telemetry_f64[43] = (double)status.replay_gain.peak;
    out_telemetry_f64[44] = 0.0;
    out_telemetry_f64[45] = status.replay_gain.prevent_clipping ? 1.0 : 0.0;
    miniaudio_stream_status_t stream_status;
    memset(&stream_status, 0, sizeof(stream_status));
    if (miniaudio_player_stream_get_status(player, &stream_status) == MAP_SUCCESS)
    {
        out_telemetry_f64[46] = (double)stream_status.read_cursor_byte;
        out_telemetry_f64[47] = (double)stream_status.buffer_capacity;
    }
    else
    {
        out_telemetry_f64[46] = -1.0;
        out_telemetry_f64[47] = 0.0;
    }
}

MAP_API int32_t map_wasm_analyze_audio_memory(
    const void *data,
    uint32_t data_size,
    uint32_t flags,
    float target_lufs,
    uint32_t waveform_points,
    double *out_data,
    float **out_waveform_points)
{
    if (data == NULL || data_size == 0 || out_data == NULL)
        return MAP_ERROR_INVALID_ARGS;

    miniaudio_audio_analysis_config_t config;
    memset(&config, 0, sizeof(config));
    config.flags = flags;
    config.target_lufs = target_lufs;
    config.waveform_points = waveform_points;

    miniaudio_audio_analysis_result_t result;
    memset(&result, 0, sizeof(result));

    int32_t status = miniaudio_player_analyze_audio_memory(data, (size_t)data_size, &config, &result);
    if (status != MAP_SUCCESS)
    {
        return status;
    }

    out_data[0] = (double)result.duration_ms;
    out_data[1] = (double)result.peak;
    out_data[2] = (double)result.bitrate;
    out_data[3] = (double)result.sample_rate;
    out_data[4] = (double)result.channels;
    out_data[5] = result.has_replay_gain ? 1.0 : 0.0;
    out_data[6] = (double)result.replay_gain.gain_db;
    out_data[7] = (double)result.replay_gain.peak;
    out_data[8] = (double)result.replay_gain.lufs;
    out_data[9] = (double)result.waveform.point_count;

    if (out_waveform_points != NULL)
    {
        *out_waveform_points = result.waveform.points;
    }
    else if (result.waveform.points != NULL)
    {
        free(result.waveform.points);
    }

    return MAP_SUCCESS;
}
