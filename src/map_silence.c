/**
 * @file map_silence.c
 * @brief Silence detection and skipping implementation.
 */

#include "map_silence.h"

void map_silence_detector_update_params(map_silence_detector *pDet)
{
    if (pDet == NULL)
        return;

    pDet->threshold_amp_linear = powf(10.0f, pDet->config.threshold_db / 20.0f);
    /* 2 dB hysteresis for exiting silence */
    pDet->threshold_amp_exit = powf(10.0f, (pDet->config.threshold_db + 2.0f) / 20.0f);

    if (pDet->sample_rate > 0)
    {
        pDet->min_silence_frames = (pDet->config.min_silence_duration_ms * pDet->sample_rate) / 1000;
        pDet->padding_frames = (pDet->config.padding_ms * pDet->sample_rate) / 1000;
        pDet->crossfade_length = (5 * pDet->sample_rate) / 1000; /* 5ms */
        if (pDet->crossfade_length == 0)
            pDet->crossfade_length = 1;
    }
}

ma_result map_silence_detector_init(
    map_silence_detector *pDet,
    ma_uint32 channels,
    ma_uint32 sample_rate)
{
    if (pDet == NULL)
        return MA_INVALID_ARGS;

    memset(pDet, 0, sizeof(*pDet));
    pDet->channels = channels;
    pDet->sample_rate = sample_rate;

    pDet->config.mode = MAP_SILENCE_MODE_DISABLED;
    pDet->config.threshold_db = -45.0f;
    pDet->config.min_silence_duration_ms = 300;
    pDet->config.padding_ms = 50;

    map_silence_detector_update_params(pDet);

    /* Allocate hold buffer: precisely sized and 64-byte aligned to prevent cache thrashing and split-loads */
    pDet->hold_buffer_capacity = pDet->min_silence_frames + pDet->padding_frames + 2048;
    if (channels > 0 && pDet->hold_buffer_capacity > 0)
    {
        size_t size_bytes = pDet->hold_buffer_capacity * channels * sizeof(float);
        pDet->hold_buffer = (float *)ma_aligned_malloc(size_bytes, 64, NULL);
        if (pDet->hold_buffer != NULL)
        {
            memset(pDet->hold_buffer, 0, size_bytes);
        }
        else
        {
            return MA_OUT_OF_MEMORY;
        }
    }

    return MA_SUCCESS;
}

void map_silence_detector_uninit(map_silence_detector *pDet)
{
    if (pDet == NULL)
        return;
    if (pDet->hold_buffer != NULL)
    {
        ma_aligned_free(pDet->hold_buffer, NULL);
        pDet->hold_buffer = NULL;
    }
}

void map_silence_detector_set_config_buffers(
    map_silence_detector *pDet,
    const miniaudio_player_silence_config_t *config,
    float *new_buf,
    ma_uint32 new_capacity,
    float **pOldBufToFree)
{
    if (pOldBufToFree != NULL)
    {
        *pOldBufToFree = NULL;
    }

    if (pDet == NULL || config == NULL)
        return;

    pDet->config = *config;
    map_silence_detector_update_params(pDet);

    if (new_buf != NULL && new_capacity > pDet->hold_buffer_capacity)
    {
        if (pDet->hold_buffer != NULL && pDet->hold_frames_count > 0)
        {
            ma_uint32 frames_to_copy = pDet->hold_frames_count;
            if (frames_to_copy > new_capacity)
                frames_to_copy = new_capacity;
            memcpy(new_buf, pDet->hold_buffer, frames_to_copy * pDet->channels * sizeof(float));
        }
        if (pOldBufToFree != NULL)
        {
            *pOldBufToFree = pDet->hold_buffer;
        }
        else if (pDet->hold_buffer != NULL)
        {
            ma_aligned_free(pDet->hold_buffer, NULL);
        }
        pDet->hold_buffer = new_buf;
        pDet->hold_buffer_capacity = new_capacity;
    }
}

void map_silence_detector_set_config(
    map_silence_detector *pDet,
    const miniaudio_player_silence_config_t *config)
{
    if (pDet == NULL || config == NULL)
        return;

    ma_uint32 min_frames = (config->min_silence_duration_ms * pDet->sample_rate) / 1000;
    ma_uint32 pad_frames = (config->padding_ms * pDet->sample_rate) / 1000;
    ma_uint32 required = min_frames + pad_frames + 2048;

    float *new_buf = NULL;
    float *old_buf = NULL;

    if (required > pDet->hold_buffer_capacity && pDet->channels > 0)
    {
        size_t new_size = required * pDet->channels * sizeof(float);
        new_buf = (float *)ma_aligned_malloc(new_size, 64, NULL);
        if (new_buf != NULL)
            memset(new_buf, 0, new_size);
    }

    map_silence_detector_set_config_buffers(pDet, config, new_buf, required, &old_buf);

    if (old_buf != NULL)
    {
        ma_aligned_free(old_buf, NULL);
    }
    else if (new_buf != NULL && pDet->hold_buffer != new_buf)
    {
        ma_aligned_free(new_buf, NULL);
    }
}

void map_silence_detector_reset(map_silence_detector *pDet, ma_bool32 is_start)
{
    if (pDet == NULL)
        return;

    pDet->state = MAP_SILENCE_STATE_VOICE;
    pDet->hold_frames_count = 0;
    pDet->hold_frames_read_pos = 0;
    pDet->crossfade_remaining = 0;
    memset(pDet->last_sample, 0, sizeof(pDet->last_sample));

    if (is_start && (pDet->config.mode == MAP_SILENCE_MODE_TRIM_EDGES || pDet->config.mode == MAP_SILENCE_MODE_ALL))
    {
        pDet->lead_in_active = MA_TRUE;
    }
    else
    {
        pDet->lead_in_active = MA_FALSE;
    }
}

int64_t map_silence_detector_get_saved_ms(const map_silence_detector *pDet)
{
    if (pDet == NULL || pDet->sample_rate == 0)
        return 0;
    return (pDet->silence_saved_frames * 1000) / pDet->sample_rate;
}
