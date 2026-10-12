/**
 * @file map_silence.h
 * @brief Silence detection and skipping state machine and hold buffer.
 */

#ifndef MAP_SILENCE_H
#define MAP_SILENCE_H

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"

typedef enum
{
    MAP_SILENCE_STATE_VOICE = 0,
    MAP_SILENCE_STATE_HOLDING = 1,
    MAP_SILENCE_STATE_SKIPPING = 2
} map_silence_state_t;

typedef struct
{
    miniaudio_player_silence_config_t config;
    map_silence_state_t state;
    ma_uint32 channels;
    ma_uint32 sample_rate;

    float threshold_amp_linear;
    float threshold_amp_exit;

    ma_uint32 min_silence_frames;
    ma_uint32 padding_frames;

    ma_bool32 lead_in_active;
    int64_t silence_saved_frames;

    float *hold_buffer;
    ma_uint32 hold_buffer_capacity; /* in frames */
    ma_uint32 hold_frames_count;
    ma_uint32 hold_frames_read_pos;

    float last_sample[8];
    ma_uint32 crossfade_length;
    ma_uint32 crossfade_remaining;
} map_silence_detector;

ma_result map_silence_detector_init(
    map_silence_detector *pDet,
    ma_uint32 channels,
    ma_uint32 sample_rate);

void map_silence_detector_uninit(map_silence_detector *pDet);

void map_silence_detector_set_config(
    map_silence_detector *pDet,
    const miniaudio_player_silence_config_t *config);

void map_silence_detector_set_config_buffers(
    map_silence_detector *pDet,
    const miniaudio_player_silence_config_t *config,
    float *new_buf,
    ma_uint32 new_capacity,
    float **pOldBufToFree);

void map_silence_detector_reset(map_silence_detector *pDet, ma_bool32 is_start);

void map_silence_detector_update_params(map_silence_detector *pDet);

int64_t map_silence_detector_get_saved_ms(const map_silence_detector *pDet);

#endif /* MAP_SILENCE_H */
