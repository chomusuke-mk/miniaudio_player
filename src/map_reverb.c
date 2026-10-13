/**
 * @file map_reverb.c
 * @brief Algorithmic stereo reverberation implementation with Freeverb topology.
 */

#include "map_reverb.h"
#include <string.h>

static const int32_t g_map_comb_tunings_l[MAP_REVERB_NUM_COMBS] = {
    1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617
};

static const int32_t g_map_allpass_tunings_l[MAP_REVERB_NUM_ALLPASS] = {
    556, 441, 341, 225
};

#define MAP_REVERB_STEREO_SPREAD 23

ma_result map_reverb_init(map_reverb_t *pReverb, uint32_t sampleRate)
{
    if (pReverb == NULL)
    {
        return MA_INVALID_ARGS;
    }

    memset(pReverb, 0, sizeof(*pReverb));

    /* Total buffer allocation: 16 combs * 8192 + 8 allpasses * 4096 = 163,840 floats (640 KB) */
    size_t total_floats = (size_t)MAP_REVERB_NUM_COMBS * 2 * MAP_REVERB_MAX_COMB_SIZE +
                          (size_t)MAP_REVERB_NUM_ALLPASS * 2 * MAP_REVERB_MAX_ALLPASS_SIZE;

    pReverb->buffer_memory = (float *)ma_aligned_malloc(total_floats * sizeof(float), 64, NULL);
    if (pReverb->buffer_memory == NULL)
    {
        return MA_OUT_OF_MEMORY;
    }
    memset(pReverb->buffer_memory, 0, total_floats * sizeof(float));

    /* Distribute contiguous memory to individual filters */
    float *ptr = pReverb->buffer_memory;
    int i;
    for (i = 0; i < MAP_REVERB_NUM_COMBS; i++)
    {
        pReverb->combs_l[i].buffer = ptr;
        ptr += MAP_REVERB_MAX_COMB_SIZE;
    }
    for (i = 0; i < MAP_REVERB_NUM_COMBS; i++)
    {
        pReverb->combs_r[i].buffer = ptr;
        ptr += MAP_REVERB_MAX_COMB_SIZE;
    }
    for (i = 0; i < MAP_REVERB_NUM_ALLPASS; i++)
    {
        pReverb->allpasses_l[i].buffer = ptr;
        ptr += MAP_REVERB_MAX_ALLPASS_SIZE;
    }
    for (i = 0; i < MAP_REVERB_NUM_ALLPASS; i++)
    {
        pReverb->allpasses_r[i].buffer = ptr;
        ptr += MAP_REVERB_MAX_ALLPASS_SIZE;
    }

    map_reverb_set_sample_rate(pReverb, sampleRate);
    map_reverb_set_params(pReverb, 0, 0.5f, 0.5f, 1.0f, 0.33f, 1.0f);

    pReverb->current_dry = 1.0f;
    pReverb->current_wet1 = 0.0f;
    pReverb->current_wet2 = 0.0f;

    return MA_SUCCESS;
}

void map_reverb_uninit(map_reverb_t *pReverb)
{
    if (pReverb == NULL)
    {
        return;
    }
    if (pReverb->buffer_memory != NULL)
    {
        ma_aligned_free(pReverb->buffer_memory, NULL);
        pReverb->buffer_memory = NULL;
    }
}

void map_reverb_clear(map_reverb_t *pReverb)
{
    if (pReverb == NULL || pReverb->buffer_memory == NULL)
    {
        return;
    }

    size_t total_floats = (size_t)MAP_REVERB_NUM_COMBS * 2 * MAP_REVERB_MAX_COMB_SIZE +
                          (size_t)MAP_REVERB_NUM_ALLPASS * 2 * MAP_REVERB_MAX_ALLPASS_SIZE;
    memset(pReverb->buffer_memory, 0, total_floats * sizeof(float));

    int i;
    for (i = 0; i < MAP_REVERB_NUM_COMBS; i++)
    {
        pReverb->combs_l[i].bufidx = 0;
        pReverb->combs_l[i].filterstore = 0.0f;
        pReverb->combs_r[i].bufidx = 0;
        pReverb->combs_r[i].filterstore = 0.0f;
    }
    for (i = 0; i < MAP_REVERB_NUM_ALLPASS; i++)
    {
        pReverb->allpasses_l[i].bufidx = 0;
        pReverb->allpasses_r[i].bufidx = 0;
    }
}

void map_reverb_set_sample_rate(map_reverb_t *pReverb, uint32_t newSampleRate)
{
    if (pReverb == NULL)
    {
        return;
    }
    if (newSampleRate == 0)
    {
        newSampleRate = 44100;
    }

    pReverb->sample_rate = newSampleRate;
    double rate_scale = (double)newSampleRate / 44100.0;
    int i;

    /* Scaled Comb lengths */
    for (i = 0; i < MAP_REVERB_NUM_COMBS; i++)
    {
        int32_t len_l = (int32_t)((double)g_map_comb_tunings_l[i] * rate_scale + 0.5);
        int32_t len_r = (int32_t)(((double)g_map_comb_tunings_l[i] + (double)MAP_REVERB_STEREO_SPREAD) * rate_scale + 0.5);

        if (len_l < 1) len_l = 1;
        if (len_l > MAP_REVERB_MAX_COMB_SIZE) len_l = MAP_REVERB_MAX_COMB_SIZE;
        if (len_r < 1) len_r = 1;
        if (len_r > MAP_REVERB_MAX_COMB_SIZE) len_r = MAP_REVERB_MAX_COMB_SIZE;

        pReverb->combs_l[i].bufsize = len_l;
        pReverb->combs_l[i].bufidx = 0;
        pReverb->combs_l[i].filterstore = 0.0f;

        pReverb->combs_r[i].bufsize = len_r;
        pReverb->combs_r[i].bufidx = 0;
        pReverb->combs_r[i].filterstore = 0.0f;
    }

    /* Scaled Allpass lengths */
    for (i = 0; i < MAP_REVERB_NUM_ALLPASS; i++)
    {
        int32_t len_l = (int32_t)((double)g_map_allpass_tunings_l[i] * rate_scale + 0.5);
        int32_t len_r = (int32_t)(((double)g_map_allpass_tunings_l[i] + (double)MAP_REVERB_STEREO_SPREAD) * rate_scale + 0.5);

        if (len_l < 1) len_l = 1;
        if (len_l > MAP_REVERB_MAX_ALLPASS_SIZE) len_l = MAP_REVERB_MAX_ALLPASS_SIZE;
        if (len_r < 1) len_r = 1;
        if (len_r > MAP_REVERB_MAX_ALLPASS_SIZE) len_r = MAP_REVERB_MAX_ALLPASS_SIZE;

        pReverb->allpasses_l[i].bufsize = len_l;
        pReverb->allpasses_l[i].bufidx = 0;

        pReverb->allpasses_r[i].bufsize = len_r;
        pReverb->allpasses_r[i].bufidx = 0;
    }

    /* Clear memory without reallocating */
    map_reverb_clear(pReverb);
}

void map_reverb_set_params(
    map_reverb_t *pReverb,
    int32_t enabled,
    float room_size,
    float damping,
    float width,
    float wet,
    float dry)
{
    if (pReverb == NULL)
    {
        return;
    }

    if (room_size < 0.0f) room_size = 0.0f;
    if (room_size > 1.0f) room_size = 1.0f;
    if (damping < 0.0f) damping = 0.0f;
    if (damping > 1.0f) damping = 1.0f;
    if (width < 0.0f) width = 0.0f;
    if (width > 1.0f) width = 1.0f;
    if (wet < 0.0f) wet = 0.0f;
    if (wet > 2.0f) wet = 2.0f;
    if (dry < 0.0f) dry = 0.0f;
    if (dry > 2.0f) dry = 2.0f;

    pReverb->enabled = enabled;
    pReverb->room_size = room_size;
    pReverb->damping = damping;
    pReverb->width = width;
    pReverb->wet = wet;
    pReverb->dry = dry;

    pReverb->feedback = room_size * MAP_REVERB_SCALE_ROOM + MAP_REVERB_OFFSET_ROOM;
    pReverb->damp = damping * MAP_REVERB_SCALE_DAMP;
    pReverb->target_wet1 = wet * (width * 0.5f + 0.5f) * MAP_REVERB_SCALE_WET;
    pReverb->target_wet2 = wet * ((1.0f - width) * 0.5f) * MAP_REVERB_SCALE_WET;
    pReverb->target_dry = dry;
}

void map_reverb_process_frames(
    map_reverb_t *pReverb,
    float *pSamples,
    ma_uint32 frameCount,
    ma_uint32 channels)
{
    if (pReverb == NULL || pSamples == NULL || frameCount == 0 || channels == 0)
    {
        return;
    }

    /* Fast bypass when disabled and smoothed wet tails have fully decayed */
    if (!pReverb->enabled &&
        pReverb->current_wet1 < 1e-5f &&
        pReverb->current_wet2 < 1e-5f &&
        fabsf(pReverb->current_dry - 1.0f) < 1e-5f)
    {
        return;
    }

    float damp = pReverb->damp;
    float feedback = pReverb->feedback;

    float tgt_dry  = pReverb->enabled ? pReverb->target_dry : 1.0f;
    float tgt_wet1 = pReverb->enabled ? pReverb->target_wet1 : 0.0f;
    float tgt_wet2 = pReverb->enabled ? pReverb->target_wet2 : 0.0f;

    float cur_dry  = pReverb->current_dry;
    float cur_wet1 = pReverb->current_wet1;
    float cur_wet2 = pReverb->current_wet2;

    float dry_step  = (tgt_dry - cur_dry) / (float)frameCount;
    float wet1_step = (tgt_wet1 - cur_wet1) / (float)frameCount;
    float wet2_step = (tgt_wet2 - cur_wet2) / (float)frameCount;

    ma_uint32 f;

    if (channels >= 2)
    {
        for (f = 0; f < frameCount; f++)
        {
            float in_l = pSamples[f * channels];
            float in_r = pSamples[f * channels + 1];
            float input = (in_l + in_r) * MAP_REVERB_SCALE_INPUT;

            float out_comb_l = 0.0f;
            float out_comb_r = 0.0f;
            int i;

            /* 8 Parallel Low-Pass Comb Filters */
            for (i = 0; i < MAP_REVERB_NUM_COMBS; i++)
            {
                /* Left Comb */
                {
                    map_comb_filter_t *c = &pReverb->combs_l[i];
                    float out = c->buffer[c->bufidx];
                    float store = out * (1.0f - damp) + c->filterstore * damp;
                    if (fabsf(store) < 1e-20f) store = 0.0f;
                    c->filterstore = store;

                    float in_val = input + store * feedback;
                    if (fabsf(in_val) < 1e-20f) in_val = 0.0f;
                    c->buffer[c->bufidx] = in_val;

                    c->bufidx++;
                    if (c->bufidx >= c->bufsize) c->bufidx = 0;
                    out_comb_l += out;
                }

                /* Right Comb */
                {
                    map_comb_filter_t *c = &pReverb->combs_r[i];
                    float out = c->buffer[c->bufidx];
                    float store = out * (1.0f - damp) + c->filterstore * damp;
                    if (fabsf(store) < 1e-20f) store = 0.0f;
                    c->filterstore = store;

                    float in_val = input + store * feedback;
                    if (fabsf(in_val) < 1e-20f) in_val = 0.0f;
                    c->buffer[c->bufidx] = in_val;

                    c->bufidx++;
                    if (c->bufidx >= c->bufsize) c->bufidx = 0;
                    out_comb_r += out;
                }
            }

            /* 4 Cascaded Allpass Filters */
            for (i = 0; i < MAP_REVERB_NUM_ALLPASS; i++)
            {
                /* Left Allpass */
                {
                    map_allpass_filter_t *a = &pReverb->allpasses_l[i];
                    float bufout = a->buffer[a->bufidx];
                    if (fabsf(bufout) < 1e-20f) bufout = 0.0f;

                    float out = -out_comb_l + bufout;
                    float in_val = out_comb_l + bufout * MAP_REVERB_ALLPASS_FB;
                    if (fabsf(in_val) < 1e-20f) in_val = 0.0f;
                    a->buffer[a->bufidx] = in_val;

                    a->bufidx++;
                    if (a->bufidx >= a->bufsize) a->bufidx = 0;
                    out_comb_l = out;
                }

                /* Right Allpass */
                {
                    map_allpass_filter_t *a = &pReverb->allpasses_r[i];
                    float bufout = a->buffer[a->bufidx];
                    if (fabsf(bufout) < 1e-20f) bufout = 0.0f;

                    float out = -out_comb_r + bufout;
                    float in_val = out_comb_r + bufout * MAP_REVERB_ALLPASS_FB;
                    if (fabsf(in_val) < 1e-20f) in_val = 0.0f;
                    a->buffer[a->bufidx] = in_val;

                    a->bufidx++;
                    if (a->bufidx >= a->bufsize) a->bufidx = 0;
                    out_comb_r = out;
                }
            }

            /* Linear parameter smoothing */
            cur_dry  += dry_step;
            cur_wet1 += wet1_step;
            cur_wet2 += wet2_step;

            /* Matrix mix output */
            pSamples[f * channels]     = in_l * cur_dry + out_comb_l * cur_wet1 + out_comb_r * cur_wet2;
            pSamples[f * channels + 1] = in_r * cur_dry + out_comb_r * cur_wet1 + out_comb_l * cur_wet2;
        }
    }
    else
    {
        /* Mono processing */
        for (f = 0; f < frameCount; f++)
        {
            float in = pSamples[f];
            float input = in * MAP_REVERB_SCALE_INPUT;
            float out_comb = 0.0f;
            int i;

            for (i = 0; i < MAP_REVERB_NUM_COMBS; i++)
            {
                map_comb_filter_t *c = &pReverb->combs_l[i];
                float out = c->buffer[c->bufidx];
                float store = out * (1.0f - damp) + c->filterstore * damp;
                if (fabsf(store) < 1e-20f) store = 0.0f;
                c->filterstore = store;

                float in_val = input + store * feedback;
                if (fabsf(in_val) < 1e-20f) in_val = 0.0f;
                c->buffer[c->bufidx] = in_val;

                c->bufidx++;
                if (c->bufidx >= c->bufsize) c->bufidx = 0;
                out_comb += out;
            }

            for (i = 0; i < MAP_REVERB_NUM_ALLPASS; i++)
            {
                map_allpass_filter_t *a = &pReverb->allpasses_l[i];
                float bufout = a->buffer[a->bufidx];
                if (fabsf(bufout) < 1e-20f) bufout = 0.0f;

                float out = -out_comb + bufout;
                float in_val = out_comb + bufout * MAP_REVERB_ALLPASS_FB;
                if (fabsf(in_val) < 1e-20f) in_val = 0.0f;
                a->buffer[a->bufidx] = in_val;

                a->bufidx++;
                if (a->bufidx >= a->bufsize) a->bufidx = 0;
                out_comb = out;
            }

            cur_dry  += dry_step;
            cur_wet1 += wet1_step;

            pSamples[f] = in * cur_dry + out_comb * cur_wet1;
        }
    }

    if (fabsf(cur_dry) < 1e-15f) cur_dry = 0.0f;
    if (fabsf(cur_wet1) < 1e-15f) cur_wet1 = 0.0f;
    if (fabsf(cur_wet2) < 1e-15f) cur_wet2 = 0.0f;

    pReverb->current_dry = cur_dry;
    pReverb->current_wet1 = cur_wet1;
    pReverb->current_wet2 = cur_wet2;
}
