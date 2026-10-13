/**
 * @file map_reverb.h
 * @brief Studio-grade algorithmic stereo reverberation (Freeverb model) for miniaudio_player.
 *
 * Implements 8 parallel lowpass feedback comb filters (LBCF) and 4 cascaded allpass
 * filters (APF) per channel with stereo decorrelation, cache-aligned buffers,
 * deterministic O(1) execution, and hardware anti-denormal flushes.
 */

#ifndef MAP_REVERB_H
#define MAP_REVERB_H

#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include "miniaudio.h"
#include "map_common.h"

#define MAP_REVERB_NUM_COMBS    8
#define MAP_REVERB_NUM_ALLPASS 4

#define MAP_REVERB_MAX_COMB_SIZE    8192
#define MAP_REVERB_MAX_ALLPASS_SIZE 4096

#define MAP_REVERB_SCALE_ROOM   0.28f
#define MAP_REVERB_OFFSET_ROOM  0.70f
#define MAP_REVERB_SCALE_DAMP   0.40f
#define MAP_REVERB_SCALE_WET    2.50f
#define MAP_REVERB_SCALE_INPUT  0.015f
#define MAP_REVERB_ALLPASS_FB   0.50f

typedef struct
{
    float *buffer;
    int32_t bufsize;
    int32_t bufidx;
    float filterstore;
} map_comb_filter_t;

typedef struct
{
    float *buffer;
    int32_t bufsize;
    int32_t bufidx;
} map_allpass_filter_t;

typedef struct
{
    map_comb_filter_t combs_l[MAP_REVERB_NUM_COMBS];
    map_comb_filter_t combs_r[MAP_REVERB_NUM_COMBS];
    map_allpass_filter_t allpasses_l[MAP_REVERB_NUM_ALLPASS];
    map_allpass_filter_t allpasses_r[MAP_REVERB_NUM_ALLPASS];

    float *buffer_memory;
    uint32_t sample_rate;

    int32_t enabled;
    float room_size;
    float damping;
    float width;
    float wet;
    float dry;

    float feedback;
    float damp;
    float target_wet1;
    float target_wet2;
    float target_dry;
    float current_wet1;
    float current_wet2;
    float current_dry;
} map_reverb_t;

/**
 * @brief Initializes the reverb processor, allocating fixed headroom buffers up-front.
 * @param pReverb Reverb instance pointer.
 * @param sampleRate Initial audio sample rate (e.g. 44100, 48000).
 * @return MA_SUCCESS or error code.
 */
ma_result map_reverb_init(map_reverb_t *pReverb, uint32_t sampleRate);

/**
 * @brief Releases pre-allocated reverb memory.
 * @param pReverb Reverb instance pointer.
 */
void map_reverb_uninit(map_reverb_t *pReverb);

/**
 * @brief Clears all internal delay line buffers and filter histories to zero.
 * @param pReverb Reverb instance pointer.
 */
void map_reverb_clear(map_reverb_t *pReverb);

/**
 * @brief Updates delay buffer lengths when device sample rate changes, with 0 dynamic allocations.
 * @param pReverb Reverb instance pointer.
 * @param newSampleRate New audio sample rate.
 */
void map_reverb_set_sample_rate(map_reverb_t *pReverb, uint32_t newSampleRate);

/**
 * @brief Configures reverb acoustic parameters and derives internal filter coefficients.
 * @param pReverb Reverb instance pointer.
 * @param enabled 1 to enable processing, 0 for bypass.
 * @param room_size Size of simulated acoustic space (0.0 to 1.0).
 * @param damping High-frequency absorption (0.0 to 1.0).
 * @param width Stereo spread of reflections (0.0 to 1.0).
 * @param wet Wet signal mix factor (0.0 to 2.0).
 * @param dry Dry signal mix factor (0.0 to 2.0).
 */
void map_reverb_set_params(
    map_reverb_t *pReverb,
    int32_t enabled,
    float room_size,
    float damping,
    float width,
    float wet,
    float dry);

/**
 * @brief Processes multi-channel PCM audio frames in-place with O(1) determinism.
 * @param pReverb Reverb instance pointer.
 * @param pSamples Interleaved floating point audio frames.
 * @param frameCount Number of frames to process.
 * @param channels Number of audio channels (e.g. 1 mono, 2 stereo).
 */
void map_reverb_process_frames(
    map_reverb_t *pReverb,
    float *pSamples,
    ma_uint32 frameCount,
    ma_uint32 channels);

#endif /* MAP_REVERB_H */
