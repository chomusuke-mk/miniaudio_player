/**
 * @file miniaudio_player.c
 * @brief Thread-safe, reentrant native audio engine implementation.
 */

#define STB_VORBIS_HEADER_ONLY
#include "decoders/stb_vorbis.c"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#undef STB_VORBIS_HEADER_ONLY
#include "decoders/stb_vorbis.c"

#include "miniaudio_player.h"
#include "sonic.h"

#if !defined(MA_NO_LIBOPUS)
#include "decoders/libopus/miniaudio_libopus.h"
#endif

static ma_decoding_backend_vtable *g_map_custom_decoders[2] = {NULL, NULL};
static int g_map_custom_decoders_initialized = 0;

static ma_uint32 map_get_custom_decoder_count(void)
{
    ma_uint32 count = 0;
    if (!g_map_custom_decoders_initialized)
    {
#if !defined(MA_NO_LIBOPUS)
        if (ma_decoding_backend_libopus != NULL)
        {
            g_map_custom_decoders[count++] = ma_decoding_backend_libopus;
        }
#endif
        g_map_custom_decoders_initialized = 1;
    }
    else
    {
        while (count < 2 && g_map_custom_decoders[count] != NULL)
        {
            count++;
        }
    }
    return count;
}

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#include <stdarg.h>
#include <stddef.h>

static int32_t g_map_log_level = MAP_LOG_LEVEL_NONE;

MAP_API void miniaudio_player_set_log_level(int32_t level)
{
    g_map_log_level = level;
}

MAP_API int32_t miniaudio_player_get_log_level(void)
{
    return g_map_log_level;
}

#if defined(__ANDROID__)
#include <android/log.h>
#endif

static void map_log_print(int32_t level, const char *tag, const char *fmt, ...)
{
    va_list args;
    const char *level_str;
    if (g_map_log_level < level)
        return;

    level_str = "DEBUG";
    if (level == MAP_LOG_LEVEL_ERROR)
        level_str = "ERROR";
    else if (level == MAP_LOG_LEVEL_WARNING)
        level_str = "WARN";
    else if (level == MAP_LOG_LEVEL_INFO)
        level_str = "INFO";
    else if (level == MAP_LOG_LEVEL_VERBOSE)
        level_str = "VERBOSE";

#if defined(__ANDROID__)
    android_LogPriority prio = ANDROID_LOG_DEBUG;
    if (level == MAP_LOG_LEVEL_ERROR)
        prio = ANDROID_LOG_ERROR;
    else if (level == MAP_LOG_LEVEL_WARNING)
        prio = ANDROID_LOG_WARN;
    else if (level == MAP_LOG_LEVEL_INFO)
        prio = ANDROID_LOG_INFO;
    else if (level == MAP_LOG_LEVEL_VERBOSE)
        prio = ANDROID_LOG_VERBOSE;

    va_start(args, fmt);
    __android_log_vprint(prio, "miniaudio_player", fmt, args);
    va_end(args);
#else
    fprintf(stderr, "[miniaudio_player][%s][%s] ", level_str, tag);
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fprintf(stderr, "\n");
    fflush(stderr);
#endif
}

static void map_miniaudio_log_callback(void *pUserData, ma_uint32 level, const char *pMessage)
{
    int32_t map_level;
    (void)pUserData;
    map_level = MAP_LOG_LEVEL_DEBUG;
    if (level == MA_LOG_LEVEL_ERROR)
        map_level = MAP_LOG_LEVEL_ERROR;
    else if (level == MA_LOG_LEVEL_WARNING)
        map_level = MAP_LOG_LEVEL_WARNING;
    else if (level == MA_LOG_LEVEL_INFO)
        map_level = MAP_LOG_LEVEL_INFO;

    if (g_map_log_level >= map_level)
    {
        map_log_print(map_level, "miniaudio", "%s", pMessage);
    }
}

#define MAP_EQ_BAND_COUNT 10
#define MAP_EQ_Q 1.15f
#define MAP_EQ_SHELF_SLOPE 0.7071067811865475

static const double g_map_eq_frequencies[MAP_EQ_BAND_COUNT] = {
    60.0,
    170.0,
    310.0,
    600.0,
    1000.0,
    3000.0,
    6000.0,
    12000.0,
    14000.0,
    16000.0};

/* Portable string duplication helper */
static char *map_strdup(const char *s)
{
    size_t len;
    char *copy;
    if (s == NULL)
        return NULL;
    len = strlen(s);
    copy = (char *)malloc(len + 1);
    if (copy != NULL)
    {
        memcpy(copy, s, len + 1);
    }
    return copy;
}

#if defined(_WIN32)
static wchar_t *map_utf8_to_wchar(const char *str)
{
    int len;
    wchar_t *wstr;
    if (str == NULL)
        return NULL;
    len = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
    if (len <= 0)
        return NULL;
    wstr = (wchar_t *)malloc((size_t)len * sizeof(wchar_t));
    if (wstr == NULL)
        return NULL;
    MultiByteToWideChar(CP_UTF8, 0, str, -1, wstr, len);
    return wstr;
}
#endif

/* Device ID serialization: converts ma_device_id to/from 512-character hex string */
static void map_device_id_to_string(const ma_device_id *pID, char *out_str, size_t max_len)
{
    const unsigned char *bytes = (const unsigned char *)pID;
    size_t i;
    if (out_str == NULL || max_len == 0)
        return;
    if (pID == NULL || max_len < (sizeof(ma_device_id) * 2 + 1))
    {
        out_str[0] = '\0';
        return;
    }
    for (i = 0; i < sizeof(ma_device_id); i++)
    {
        sprintf(out_str + (i * 2), "%02x", bytes[i]);
    }
    out_str[sizeof(ma_device_id) * 2] = '\0';
}

static ma_bool32 map_string_to_device_id(const char *str, ma_device_id *out_id)
{
    unsigned char *bytes = (unsigned char *)out_id;
    size_t i;
    if (str == NULL || out_id == NULL)
        return MA_FALSE;
    if (strlen(str) != sizeof(ma_device_id) * 2)
        return MA_FALSE;
    for (i = 0; i < sizeof(ma_device_id); i++)
    {
        unsigned int val;
        if (sscanf(str + (i * 2), "%02x", &val) != 1)
        {
            return MA_FALSE;
        }
        bytes[i] = (unsigned char)val;
    }
    return MA_TRUE;
}

/* Clamps frequency safely below the Nyquist limit */
static MA_INLINE double map_clamp_frequency(double freq, ma_uint32 sampleRate)
{
    double nyquist = (double)sampleRate * 0.499;
    if (freq > nyquist)
        return nyquist;
    return freq;
}

/* Clamps gain in dB to [-24.0, +24.0] */
static MA_INLINE float map_clamp_gain_db(float gainDB)
{
    if (gainDB < -24.0f)
        return -24.0f;
    if (gainDB > 24.0f)
        return 24.0f;
    return gainDB;
}

/* ========================================================================= */
/* Equalizer Composite Node Internal Definition                             */
/* ========================================================================= */

typedef struct
{
    ma_node_base baseNode;
    ma_spinlock lock;
    ma_loshelf2 loshelf;
    ma_peak2 peaks[8];
    ma_hishelf2 hishelf;
    ma_uint32 channels;
    ma_uint32 sampleRate;
} ma_equalizer_node;

static void ma_equalizer_node_process_pcm_frames(
    ma_node *pNode,
    const float **ppFramesIn,
    ma_uint32 *pFrameCountIn,
    float **ppFramesOut,
    ma_uint32 *pFrameCountOut)
{
    ma_equalizer_node *pEq = (ma_equalizer_node *)pNode;
    ma_uint32 frameCount;
    int i;
    (void)pFrameCountIn;

    if (pEq == NULL || ppFramesIn == NULL || ppFramesOut == NULL ||
        ppFramesIn[0] == NULL || ppFramesOut[0] == NULL || pFrameCountOut == NULL)
    {
        return;
    }

    frameCount = *pFrameCountOut;
    if (frameCount == 0)
    {
        return;
    }

    ma_spinlock_lock(&pEq->lock);

    /* Band 0: Low-shelf filter at 60 Hz */
    ma_loshelf2_process_pcm_frames(&pEq->loshelf, ppFramesOut[0], ppFramesIn[0], frameCount);

    /* Bands 1..8: 8x Peaking EQ filters in-place on ppFramesOut[0] */
    for (i = 0; i < 8; i++)
    {
        ma_peak2_process_pcm_frames(&pEq->peaks[i], ppFramesOut[0], ppFramesOut[0], frameCount);
    }

    /* Band 9: High-shelf filter at 16 kHz in-place on ppFramesOut[0] */
    ma_hishelf2_process_pcm_frames(&pEq->hishelf, ppFramesOut[0], ppFramesOut[0], frameCount);

    /* Studio-grade soft-saturation curve:
       Keeps audio dynamic and punchy, preventing harsh digital square-wave clipping
       at the DAC when EQ boosts are active.
       Linear (y = x) for |x| <= 0.80f (-1.94 dBFS), smooth rational saturation above 0.80f. */
    {
        ma_uint32 totalSamples = frameCount * pEq->channels;
        float *pSamples = ppFramesOut[0];
        ma_uint32 s;
        const float threshold = 0.80f;
        const float range = 1.0f - threshold; /* 0.20f */
        const float invRange = 1.0f / range;  /* 5.0f */

        for (s = 0; s < totalSamples; s++)
        {
            float x = pSamples[s];
            if (x > threshold)
            {
                float excess = (x - threshold) * invRange;
                pSamples[s] = threshold + range * (excess / (1.0f + excess));
            }
            else if (x < -threshold)
            {
                float excess = (-x - threshold) * invRange;
                pSamples[s] = -(threshold + range * (excess / (1.0f + excess)));
            }
        }
    }

    ma_spinlock_unlock(&pEq->lock);
}

static ma_node_vtable g_ma_equalizer_node_vtable = {
    ma_equalizer_node_process_pcm_frames,
    NULL,
    1, /* 1 input bus */
    1, /* 1 output bus */
    0};

static ma_result ma_equalizer_node_init(
    ma_node_graph *pNodeGraph,
    ma_uint32 channels,
    ma_uint32 sampleRate,
    ma_equalizer_node *pNode)
{
    ma_result result;
    ma_node_config baseConfig;
    int i;

    if (pNode == NULL || pNodeGraph == NULL || channels == 0 || sampleRate == 0)
    {
        return MA_INVALID_ARGS;
    }

    memset(pNode, 0, sizeof(*pNode));
    pNode->channels = channels;
    pNode->sampleRate = sampleRate;
    pNode->lock = 0;

    /* Band 0: 60 Hz low-shelf */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], sampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, channels, sampleRate, 0.0, MAP_EQ_SHELF_SLOPE, f);
        result = ma_loshelf2_init(&config, NULL, &pNode->loshelf);
        if (result != MA_SUCCESS)
            return result;
    }

    /* Bands 1..8: Peaking EQ filters */
    for (i = 0; i < 8; i++)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[i + 1], sampleRate);
        ma_peak2_config config = ma_peak2_config_init(
            ma_format_f32, channels, sampleRate, 0.0, MAP_EQ_Q, f);
        result = ma_peak2_init(&config, NULL, &pNode->peaks[i]);
        if (result != MA_SUCCESS)
        {
            int j;
            ma_loshelf2_uninit(&pNode->loshelf, NULL);
            for (j = 0; j < i; j++)
            {
                ma_peak2_uninit(&pNode->peaks[j], NULL);
            }
            return result;
        }
    }

    /* Band 9: 16 kHz high-shelf */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], sampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, channels, sampleRate, 0.0, MAP_EQ_SHELF_SLOPE, f);
        result = ma_hishelf2_init(&config, NULL, &pNode->hishelf);
        if (result != MA_SUCCESS)
        {
            int j;
            ma_loshelf2_uninit(&pNode->loshelf, NULL);
            for (j = 0; j < 8; j++)
            {
                ma_peak2_uninit(&pNode->peaks[j], NULL);
            }
            return result;
        }
    }

    /* Base node setup */
    baseConfig = ma_node_config_init();
    baseConfig.vtable = &g_ma_equalizer_node_vtable;
    baseConfig.pInputChannels = &pNode->channels;
    baseConfig.pOutputChannels = &pNode->channels;

    result = ma_node_init(pNodeGraph, &baseConfig, NULL, &pNode->baseNode);
    if (result != MA_SUCCESS)
    {
        int j;
        ma_loshelf2_uninit(&pNode->loshelf, NULL);
        for (j = 0; j < 8; j++)
        {
            ma_peak2_uninit(&pNode->peaks[j], NULL);
        }
        ma_hishelf2_uninit(&pNode->hishelf, NULL);
        return result;
    }

    return MA_SUCCESS;
}

static void ma_equalizer_node_uninit(ma_equalizer_node *pNode)
{
    int i;
    if (pNode == NULL)
        return;
    ma_node_uninit(&pNode->baseNode, NULL);
    ma_loshelf2_uninit(&pNode->loshelf, NULL);
    for (i = 0; i < 8; i++)
    {
        ma_peak2_uninit(&pNode->peaks[i], NULL);
    }
    ma_hishelf2_uninit(&pNode->hishelf, NULL);
}

static ma_result ma_equalizer_node_set_band(
    ma_equalizer_node *pEq,
    ma_uint32 bandIndex,
    float gainDB)
{
    float clampedGain;
    if (pEq == NULL || bandIndex >= MAP_EQ_BAND_COUNT)
        return MA_INVALID_ARGS;
    clampedGain = map_clamp_gain_db(gainDB);

    ma_spinlock_lock(&pEq->lock);

    if (bandIndex == 0)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], pEq->sampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)clampedGain, MAP_EQ_SHELF_SLOPE, f);
        ma_loshelf2_reinit(&config, &pEq->loshelf);
    }
    else if (bandIndex >= 1 && bandIndex <= 8)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[bandIndex], pEq->sampleRate);
        ma_peak2_config config = ma_peak2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)clampedGain, MAP_EQ_Q, f);
        ma_peak2_reinit(&config, &pEq->peaks[bandIndex - 1]);
    }
    else if (bandIndex == 9)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], pEq->sampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)clampedGain, MAP_EQ_SHELF_SLOPE, f);
        ma_hishelf2_reinit(&config, &pEq->hishelf);
    }

    ma_spinlock_unlock(&pEq->lock);
    return MA_SUCCESS;
}

static ma_result ma_equalizer_node_set_all(
    ma_equalizer_node *pEq,
    const miniaudio_player_equalizer_params_t *pParams)
{
    float gains[10];
    int i;

    if (pEq == NULL || pParams == NULL)
        return MA_INVALID_ARGS;

    gains[0] = map_clamp_gain_db(pParams->hz60);
    gains[1] = map_clamp_gain_db(pParams->hz170);
    gains[2] = map_clamp_gain_db(pParams->hz310);
    gains[3] = map_clamp_gain_db(pParams->hz600);
    gains[4] = map_clamp_gain_db(pParams->hz1k);
    gains[5] = map_clamp_gain_db(pParams->hz3k);
    gains[6] = map_clamp_gain_db(pParams->hz6k);
    gains[7] = map_clamp_gain_db(pParams->hz12k);
    gains[8] = map_clamp_gain_db(pParams->hz14k);
    gains[9] = map_clamp_gain_db(pParams->hz16k);

    ma_spinlock_lock(&pEq->lock);

    /* Band 0 */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[0], pEq->sampleRate);
        ma_loshelf2_config config = ma_loshelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)gains[0], MAP_EQ_SHELF_SLOPE, f);
        ma_loshelf2_reinit(&config, &pEq->loshelf);
    }

    /* Bands 1..8 */
    for (i = 0; i < 8; i++)
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[i + 1], pEq->sampleRate);
        ma_peak2_config config = ma_peak2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)gains[i + 1], MAP_EQ_Q, f);
        ma_peak2_reinit(&config, &pEq->peaks[i]);
    }

    /* Band 9 */
    {
        double f = map_clamp_frequency(g_map_eq_frequencies[9], pEq->sampleRate);
        ma_hishelf2_config config = ma_hishelf2_config_init(
            ma_format_f32, pEq->channels, pEq->sampleRate, (double)gains[9], MAP_EQ_SHELF_SLOPE, f);
        ma_hishelf2_reinit(&config, &pEq->hishelf);
    }

    ma_spinlock_unlock(&pEq->lock);
    return MA_SUCCESS;
}

/* ========================================================================= */
/* Time-Stretching & Pitch-Shifting Custom Data Source (Sonic DSP)           */
/* ========================================================================= */

typedef struct
{
    ma_data_source_base base;
    ma_decoder decoder;
    sonicStream sonic;
    ma_spinlock lock;
    ma_uint32 channels;
    ma_uint32 sampleRate;
    float speed;
    float pitch;
    ma_bool32 is_initialized;
    ma_bool32 is_eof;
    float *scratchBuffer;
    ma_uint32 scratchCapacity; /* in floats */
} map_time_stretch_ds;

static ma_result map_time_stretch_ds_read(
    ma_data_source *pDataSource,
    void *pFramesOut,
    ma_uint64 frameCount,
    ma_uint64 *pFramesRead)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    ma_uint64 totalFramesOut = 0;
    float *pOut = (float *)pFramesOut;
    float discardBuf[128 * 8];
    const ma_uint32 maxChunkFrames = 2048;

    if (pDS == NULL)
        return MA_INVALID_ARGS;
    if (pFramesRead != NULL)
        *pFramesRead = 0;
    if (frameCount == 0)
        return MA_SUCCESS;

    ma_spinlock_lock(&pDS->lock);

    while (totalFramesOut < frameCount)
    {
        ma_uint64 needed = frameCount - totalFramesOut;
        int avail = (pDS->sonic != NULL) ? sonicSamplesAvailable(pDS->sonic) : 0;

        if (avail > 0)
        {
            int toRead = (int)((needed < (ma_uint64)avail) ? needed : (ma_uint64)avail);
            int readCount = 0;
            if (pOut != NULL)
            {
                readCount = sonicReadFloatFromStream(
                    pDS->sonic,
                    pOut + totalFramesOut * pDS->channels,
                    toRead);
            }
            else
            {
                int batch = (toRead < 128) ? toRead : 128;
                readCount = sonicReadFloatFromStream(pDS->sonic, discardBuf, batch);
            }
            if (readCount > 0)
            {
                totalFramesOut += (ma_uint64)readCount;
                continue;
            }
        }

        if (pDS->is_eof)
        {
            break;
        }

        /* Fast bypass if speed == 1.0, pitch == 1.0 and no leftover samples in sonic */
        if (pDS->speed >= 0.99999f && pDS->speed <= 1.00001f &&
            pDS->pitch >= 0.99999f && pDS->pitch <= 1.00001f &&
            avail == 0)
        {
            ma_uint64 framesToRead = needed;
            ma_uint64 directRead = 0;
            ma_result res = ma_decoder_read_pcm_frames(
                &pDS->decoder,
                pOut ? (pOut + totalFramesOut * pDS->channels) : NULL,
                framesToRead,
                &directRead);
            totalFramesOut += directRead;
            if (res != MA_SUCCESS || directRead == 0)
            {
                pDS->is_eof = MA_TRUE;
                break;
            }
            continue;
        }

        /* Pull from decoder and write to sonic */
        ma_uint64 framesFromDecoder = 0;
        ma_result readRes = ma_decoder_read_pcm_frames(
            &pDS->decoder,
            pDS->scratchBuffer,
            maxChunkFrames,
            &framesFromDecoder);

        if (framesFromDecoder > 0 && pDS->sonic != NULL)
        {
            sonicWriteFloatToStream(pDS->sonic, pDS->scratchBuffer, (int)framesFromDecoder);
        }

        if (readRes != MA_SUCCESS || framesFromDecoder == 0)
        {
            pDS->is_eof = MA_TRUE;
            if (pDS->sonic != NULL)
            {
                sonicFlushStream(pDS->sonic);
            }
            if (pDS->sonic == NULL || sonicSamplesAvailable(pDS->sonic) == 0)
            {
                break;
            }
        }
    }

    ma_spinlock_unlock(&pDS->lock);

    if (pFramesRead != NULL)
    {
        *pFramesRead = totalFramesOut;
    }

    if (totalFramesOut == 0 && pDS->is_eof)
    {
        return MA_AT_END;
    }

    return MA_SUCCESS;
}

static ma_result map_time_stretch_ds_seek(ma_data_source *pDataSource, ma_uint64 frameIndex)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    ma_result res;
    if (pDS == NULL)
        return MA_INVALID_ARGS;

    ma_spinlock_lock(&pDS->lock);
    res = ma_decoder_seek_to_pcm_frame(&pDS->decoder, frameIndex);
    if (pDS->sonic != NULL)
    {
        sonicResetStream(pDS->sonic);
    }
    pDS->is_eof = MA_FALSE;
    ma_spinlock_unlock(&pDS->lock);

    return res;
}

static ma_result map_time_stretch_ds_get_data_format(
    ma_data_source *pDataSource,
    ma_format *pFormat,
    ma_uint32 *pChannels,
    ma_uint32 *pSampleRate,
    ma_channel *pChannelMap,
    size_t channelMapCap)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    if (pDS == NULL)
        return MA_INVALID_ARGS;

    if (pFormat != NULL)
        *pFormat = ma_format_f32;
    if (pChannels != NULL)
        *pChannels = pDS->channels;
    if (pSampleRate != NULL)
        *pSampleRate = pDS->sampleRate;
    if (pChannelMap != NULL)
    {
        ma_channel_map_init_standard(ma_standard_channel_map_default, pChannelMap, channelMapCap, pDS->channels);
    }
    return MA_SUCCESS;
}

static ma_result map_time_stretch_ds_get_cursor(ma_data_source *pDataSource, ma_uint64 *pCursor)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    if (pDS == NULL || pCursor == NULL)
        return MA_INVALID_ARGS;
    return ma_decoder_get_cursor_in_pcm_frames(&pDS->decoder, pCursor);
}

static ma_result map_time_stretch_ds_get_length(ma_data_source *pDataSource, ma_uint64 *pLength)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    if (pDS == NULL || pLength == NULL)
        return MA_INVALID_ARGS;
    return ma_decoder_get_length_in_pcm_frames(&pDS->decoder, pLength);
}

static ma_result map_time_stretch_ds_set_looping(ma_data_source *pDataSource, ma_bool32 isLooping)
{
    (void)pDataSource;
    (void)isLooping;
    return MA_SUCCESS;
}

static ma_data_source_vtable g_map_time_stretch_ds_vtable = {
    map_time_stretch_ds_read,
    map_time_stretch_ds_seek,
    map_time_stretch_ds_get_data_format,
    map_time_stretch_ds_get_cursor,
    map_time_stretch_ds_get_length,
    map_time_stretch_ds_set_looping,
    0};

static ma_result map_time_stretch_ds_init(
    map_time_stretch_ds *pDS,
    const char *file_path,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate)
{
    ma_result result;
    ma_decoder_config decoder_cfg;
    ma_data_source_config baseConfig;
    ma_uint32 custom_count;

    if (pDS == NULL || file_path == NULL)
        return MA_INVALID_ARGS;

    memset(pDS, 0, sizeof(*pDS));

    decoder_cfg = ma_decoder_config_init(ma_format_f32, targetChannels, targetSampleRate);
    decoder_cfg.resampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
    custom_count = map_get_custom_decoder_count();
    if (custom_count > 0)
    {
        decoder_cfg.ppCustomBackendVTables = g_map_custom_decoders;
        decoder_cfg.customBackendCount = custom_count;
    }

#if defined(_WIN32)
    {
        wchar_t *wpath = map_utf8_to_wchar(file_path);
        if (wpath != NULL)
        {
            result = ma_decoder_init_file_w(wpath, &decoder_cfg, &pDS->decoder);
            free(wpath);
        }
        else
        {
            result = ma_decoder_init_file(file_path, &decoder_cfg, &pDS->decoder);
        }
    }
#else
    result = ma_decoder_init_file(file_path, &decoder_cfg, &pDS->decoder);
#endif
    if (result != MA_SUCCESS)
    {
        return result;
    }

    pDS->channels = targetChannels;
    pDS->sampleRate = targetSampleRate;
    pDS->speed = 1.0f;
    pDS->pitch = 1.0f;
    pDS->is_eof = MA_FALSE;

    pDS->sonic = sonicCreateStream((int)targetSampleRate, (int)targetChannels);
    if (pDS->sonic == NULL)
    {
        ma_decoder_uninit(&pDS->decoder);
        return MA_OUT_OF_MEMORY;
    }
    sonicSetQuality(pDS->sonic, 1);

    pDS->scratchCapacity = 8192 * targetChannels;
    pDS->scratchBuffer = (float *)malloc(pDS->scratchCapacity * sizeof(float));
    if (pDS->scratchBuffer == NULL)
    {
        sonicDestroyStream(pDS->sonic);
        ma_decoder_uninit(&pDS->decoder);
        return MA_OUT_OF_MEMORY;
    }

    baseConfig = ma_data_source_config_init();
    baseConfig.vtable = &g_map_time_stretch_ds_vtable;

    result = ma_data_source_init(&baseConfig, &pDS->base);
    if (result != MA_SUCCESS)
    {
        free(pDS->scratchBuffer);
        sonicDestroyStream(pDS->sonic);
        ma_decoder_uninit(&pDS->decoder);
        return result;
    }

    pDS->is_initialized = MA_TRUE;
    return MA_SUCCESS;
}

static void map_time_stretch_ds_uninit(map_time_stretch_ds *pDS)
{
    if (pDS == NULL || !pDS->is_initialized)
        return;

    ma_spinlock_lock(&pDS->lock);
    if (pDS->sonic != NULL)
    {
        sonicDestroyStream(pDS->sonic);
        pDS->sonic = NULL;
    }
    ma_decoder_uninit(&pDS->decoder);
    if (pDS->scratchBuffer != NULL)
    {
        free(pDS->scratchBuffer);
        pDS->scratchBuffer = NULL;
    }
    pDS->is_initialized = MA_FALSE;
    ma_spinlock_unlock(&pDS->lock);

    ma_data_source_uninit(&pDS->base);
}

/* ========================================================================= */
/* Player Internal Structure                                                 */
/* ========================================================================= */

struct miniaudio_player
{
    ma_engine engine;
    ma_resource_manager resource_manager;
    ma_bool32 has_resource_manager;
    uint32_t buffer_size;
    map_time_stretch_ds stretch_ds;
    ma_sound sound;
    ma_bool32 sound_loaded;
    ma_equalizer_node eq_node;
    ma_mutex lock;
    miniaudio_player_playback_state_t state;
    ma_bool32 is_completed;
    ma_bool32 is_buffering;
    float volume;
    float rate;
    float pitch;
    miniaudio_player_equalizer_params_t eq_params;
    char *file_path;
    ma_uint32 sample_rate;
    ma_uint32 channels;
    int64_t duration_ms;
    uint32_t bitrate;
    miniaudio_player_completed_cb on_completed;
    void *user_data;
    ma_log log;
    ma_bool32 has_log;
    ma_context context;
    ma_bool32 has_context;
    miniaudio_device_info_t current_device;
    ma_device_id custom_device_id;
    ma_bool32 has_custom_device;
    volatile int32_t needs_device_fallback;
    volatile int32_t is_switching_device;
    int32_t device_changed;
};

/* End-of-sound callback executed on audio device thread */
static void miniaudio_player_on_sound_end(void *pUserData, ma_sound *pSound)
{
    miniaudio_player_t *player = (miniaudio_player_t *)pUserData;
    miniaudio_player_completed_cb cb = NULL;
    void *udata = NULL;
    (void)pSound;

    if (player == NULL)
        return;

    ma_mutex_lock(&player->lock);
    player->is_completed = 1;
    player->state = MAP_PLAYBACK_STATE_COMPLETED;
    cb = player->on_completed;
    udata = player->user_data;
    ma_mutex_unlock(&player->lock);

    if (cb != NULL)
    {
        cb(udata);
    }
}

/* Device notification callback for OS rerouting and hot-unplug detection */
static void map_miniaudio_device_notification(const ma_device_notification *pNotification)
{
    miniaudio_player_t *player;
    if (pNotification == NULL || pNotification->pDevice == NULL)
        return;
    /* In ma_engine, pDevice->pUserData points to pEngine */
    player = (miniaudio_player_t *)((char *)pNotification->pDevice->pUserData - offsetof(miniaudio_player_t, engine));
    if (player == NULL)
        return;

    if (pNotification->type == ma_device_notification_type_rerouted)
    {
        ma_device_info info;
        if (ma_device_get_info(pNotification->pDevice, ma_device_type_playback, &info) == MA_SUCCESS)
        {
            ma_mutex_lock(&player->lock);
            if (player->has_custom_device)
            {
                strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                map_device_id_to_string(&info.id, player->current_device.id, sizeof(player->current_device.id));
                player->current_device.is_default = info.isDefault;
                player->current_device.is_auto = 0;
            }
            else
            {
                snprintf(player->current_device.name, sizeof(player->current_device.name), "Default -> %.240s", info.name);
                player->current_device.id[0] = '\0';
                player->current_device.is_default = 1;
                player->current_device.is_auto = 1;
            }
            player->device_changed = 1;
            ma_mutex_unlock(&player->lock);
            map_log_print(MAP_LOG_LEVEL_INFO, "core", "device notification: rerouted to '%s'", player->current_device.name);
        }
    }
    else if (pNotification->type == ma_device_notification_type_stopped)
    {
        if (!player->is_switching_device && player->has_custom_device)
        {
            map_log_print(MAP_LOG_LEVEL_WARNING, "core", "device notification: playback device stopped (unplugged/disconnected)");
            player->needs_device_fallback = 1;
        }
        else
        {
            map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "device notification: playback device stopped (switch in progress or default device)");
        }
    }
}

static ma_bool32 map_is_device_connected(ma_context *pContext, const ma_device_id *pTargetID)
{
    ma_device_info *pPlaybackInfos;
    ma_uint32 playbackCount = 0;
    ma_uint32 i;
    ma_result res;

    if (pContext == NULL || pTargetID == NULL)
        return MA_FALSE;

    res = ma_context_get_devices(pContext, &pPlaybackInfos, &playbackCount, NULL, NULL);
    if (res != MA_SUCCESS || playbackCount == 0)
        return MA_FALSE;

    for (i = 0; i < playbackCount; i++)
    {
        if (memcmp(&pPlaybackInfos[i].id, pTargetID, sizeof(ma_device_id)) == 0)
        {
            return MA_TRUE;
        }
    }
    return MA_FALSE;
}

/* Helper to apply/reconfigure output device without losing playback state */
static int32_t map_player_apply_device(miniaudio_player_t *player, const char *device_id)
{
    ma_device *pDevice;
    ma_context *pContext;
    ma_device_config dev_cfg;
    ma_device_id target_id;
    ma_device_info dev_info;
    ma_result res;
    ma_bool32 was_started;
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t buffer_size;
    miniaudio_player_playback_state_t state;
    ma_bool32 has_custom = MA_FALSE;
    miniaudio_device_info_t new_dev_info;

    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;
    pDevice = ma_engine_get_device(&player->engine);
    if (pDevice == NULL)
        return MAP_ERROR_INVALID_STATE;
    if (player->has_context)
    {
        pContext = &player->context;
    }
    else
    {
        pContext = pDevice->pContext;
    }
    if (pContext == NULL)
        return MAP_ERROR_INVALID_STATE;

    player->is_switching_device = 1;

    ma_mutex_lock(&player->lock);
    channels = player->channels;
    sample_rate = player->sample_rate;
    buffer_size = player->buffer_size;
    state = player->state;
    ma_mutex_unlock(&player->lock);

    was_started = ma_device_is_started(pDevice);
    if (was_started)
    {
        ma_device_stop(pDevice);
    }

    dev_cfg = ma_device_config_init(ma_device_type_playback);
    dev_cfg.playback.format = ma_format_f32;
    dev_cfg.playback.channels = channels;
    dev_cfg.sampleRate = sample_rate;
    dev_cfg.dataCallback = pDevice->onData;
    dev_cfg.pUserData = pDevice->pUserData;
    dev_cfg.notificationCallback = map_miniaudio_device_notification;
    dev_cfg.periodSizeInFrames = buffer_size;
    dev_cfg.noPreSilencedOutputBuffer = MA_TRUE;
    dev_cfg.noClip = MA_FALSE;
    dev_cfg.resampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;

    if (device_id != NULL && device_id[0] != '\0' && strcmp(device_id, "auto") != 0)
    {
        if (map_string_to_device_id(device_id, &target_id) && map_is_device_connected(pContext, &target_id))
        {
            dev_cfg.playback.pDeviceID = &target_id;
            has_custom = MA_TRUE;
        }
        else
        {
            map_log_print(MAP_LOG_LEVEL_WARNING, "core", "target device '%s' not found or disconnected, falling back to default", device_id);
            dev_cfg.playback.pDeviceID = NULL;
            has_custom = MA_FALSE;
            memset(&target_id, 0, sizeof(target_id));
        }
    }
    else
    {
        dev_cfg.playback.pDeviceID = NULL;
        has_custom = MA_FALSE;
        memset(&target_id, 0, sizeof(target_id));
    }

    ma_device_uninit(pDevice);
    res = ma_device_init(pContext, &dev_cfg, pDevice);
    if (res != MA_SUCCESS && dev_cfg.playback.pDeviceID != NULL)
    {
        map_log_print(MAP_LOG_LEVEL_WARNING, "core", "failed to init target device (res %d), falling back to default", res);
        dev_cfg.playback.pDeviceID = NULL;
        has_custom = MA_FALSE;
        res = ma_device_init(pContext, &dev_cfg, pDevice);
    }

    if (res != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "failed to reinit playback device: %d", res);
        player->is_switching_device = 0;
        return MAP_ERROR_GENERIC;
    }

    memset(&new_dev_info, 0, sizeof(new_dev_info));
    if (ma_device_get_info(pDevice, ma_device_type_playback, &dev_info) == MA_SUCCESS)
    {
        if (has_custom)
        {
            strncpy(new_dev_info.name, dev_info.name, sizeof(new_dev_info.name) - 1);
            new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
            map_device_id_to_string(&dev_info.id, new_dev_info.id, sizeof(new_dev_info.id));
            new_dev_info.is_default = dev_info.isDefault;
            new_dev_info.is_auto = 0;
        }
        else
        {
            snprintf(new_dev_info.name, sizeof(new_dev_info.name), "Default -> %.240s", dev_info.name);
            new_dev_info.id[0] = '\0';
            new_dev_info.is_default = 1;
            new_dev_info.is_auto = 1;
        }
    }
    else
    {
        strncpy(new_dev_info.name, "Default", sizeof(new_dev_info.name) - 1);
        new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
        new_dev_info.id[0] = '\0';
        new_dev_info.is_default = 1;
        new_dev_info.is_auto = 1;
    }

    ma_mutex_lock(&player->lock);
    player->has_custom_device = has_custom;
    player->custom_device_id = target_id;
    player->current_device = new_dev_info;
    player->device_changed = 1;
    player->needs_device_fallback = 0;
    ma_mutex_unlock(&player->lock);

    if (was_started || state == MAP_PLAYBACK_STATE_PLAYING)
    {
        ma_device_start(pDevice);
    }

    player->is_switching_device = 0;

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "playback device active: '%s' (default: %d)",
                  new_dev_info.name, new_dev_info.is_default);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Public Lifecycle API                                                      */
/* ========================================================================= */

MAP_API miniaudio_player_t *miniaudio_player_create(
    const miniaudio_player_config_t *config,
    int32_t *out_result)
{
    miniaudio_player_t *player;
    ma_engine_config engine_cfg;
    ma_result result;

    player = (miniaudio_player_t *)calloc(1, sizeof(miniaudio_player_t));
    if (player == NULL)
    {
        if (out_result)
            *out_result = MAP_ERROR_OUT_OF_MEMORY;
        return NULL;
    }

    result = ma_mutex_init(&player->lock);
    if (result != MA_SUCCESS)
    {
        free(player);
        if (out_result)
            *out_result = MAP_ERROR_GENERIC;
        return NULL;
    }

    /* Initialize default parameters */
    player->volume = 1.0f;
    player->rate = 1.0f;
    player->pitch = 1.0f;
    player->state = MAP_PLAYBACK_STATE_STOPPED;
    player->is_completed = 0;
    player->is_buffering = 0;
    player->sound_loaded = MA_FALSE;
    memset(&player->eq_params, 0, sizeof(player->eq_params));

    player->buffer_size = (config != NULL && config->period_size_in_frames > 0)
                              ? config->period_size_in_frames
                              : 1024;
    player->has_resource_manager = MA_FALSE;

    if (config != NULL)
    {
        player->on_completed = config->on_completed;
        player->user_data = config->user_data;
    }

    engine_cfg = ma_engine_config_init();
    player->has_context = MA_FALSE;
    result = ma_context_init(NULL, 0, NULL, &player->context);
    if (result == MA_SUCCESS)
    {
        player->has_context = MA_TRUE;
        engine_cfg.pContext = &player->context;
    }

    if (config != NULL)
    {
        if (config->sample_rate > 0)
            engine_cfg.sampleRate = config->sample_rate;
        if (config->channels > 0)
            engine_cfg.channels = config->channels;
    }
    engine_cfg.periodSizeInFrames = player->buffer_size;
    engine_cfg.notificationCallback = map_miniaudio_device_notification;
    engine_cfg.resourceManagerResampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
    engine_cfg.pitchResampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;

    if (config != NULL && config->playback_device_id != NULL &&
        config->playback_device_id[0] != '\0' && strcmp(config->playback_device_id, "auto") != 0)
    {
        if (map_string_to_device_id(config->playback_device_id, &player->custom_device_id))
        {
            engine_cfg.pPlaybackDeviceID = &player->custom_device_id;
            player->has_custom_device = MA_TRUE;
        }
    }

    {
        ma_uint32 custom_count = map_get_custom_decoder_count();
        if (custom_count > 0)
        {
            ma_resource_manager_config rm_cfg = ma_resource_manager_config_init();
            rm_cfg.ppCustomDecodingBackendVTables = g_map_custom_decoders;
            rm_cfg.customDecodingBackendCount = custom_count;
            rm_cfg.resampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
            result = ma_resource_manager_init(&rm_cfg, &player->resource_manager);
            if (result == MA_SUCCESS)
            {
                player->has_resource_manager = MA_TRUE;
                engine_cfg.pResourceManager = &player->resource_manager;
            }
        }
    }

    player->has_log = MA_FALSE;
    result = ma_log_init(NULL, &player->log);
    if (result == MA_SUCCESS)
    {
        ma_log_register_callback(&player->log, ma_log_callback_init(map_miniaudio_log_callback, player));
        engine_cfg.pLog = &player->log;
        player->has_log = MA_TRUE;
    }

    result = ma_engine_init(&engine_cfg, &player->engine);
    if (result != MA_SUCCESS)
    {
        if (player->has_log)
            ma_log_uninit(&player->log);
        ma_mutex_uninit(&player->lock);
        free(player);
        if (out_result)
            *out_result = MAP_ERROR_ENGINE_INIT;
        return NULL;
    }

    player->sample_rate = ma_engine_get_sample_rate(&player->engine);
    player->channels = ma_engine_get_channels(&player->engine);

    /* Initialize composite equalizer node */
    result = ma_equalizer_node_init(&player->engine.nodeGraph, player->channels, player->sample_rate, &player->eq_node);
    if (result != MA_SUCCESS)
    {
        ma_engine_uninit(&player->engine);
        if (player->has_log)
            ma_log_uninit(&player->log);
        ma_mutex_uninit(&player->lock);
        free(player);
        if (out_result)
            *out_result = MAP_ERROR_NODE_FAILED;
        return NULL;
    }

    /* Attach equalizer output to engine master endpoint */
    result = ma_node_attach_output_bus(&player->eq_node.baseNode, 0, ma_engine_get_endpoint(&player->engine), 0);
    if (result != MA_SUCCESS)
    {
        ma_equalizer_node_uninit(&player->eq_node);
        ma_engine_uninit(&player->engine);
        if (player->has_log)
            ma_log_uninit(&player->log);
        ma_mutex_uninit(&player->lock);
        free(player);
        if (out_result)
            *out_result = MAP_ERROR_NODE_FAILED;
        return NULL;
    }

    {
        ma_device *pDevice = ma_engine_get_device(&player->engine);
        if (pDevice != NULL)
        {
            ma_device_info info;
            if (ma_device_get_info(pDevice, ma_device_type_playback, &info) == MA_SUCCESS)
            {
                if (player->has_custom_device)
                {
                    strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                    player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                    map_device_id_to_string(&info.id, player->current_device.id, sizeof(player->current_device.id));
                    player->current_device.is_default = info.isDefault;
                    player->current_device.is_auto = 0;
                }
                else
                {
                    snprintf(player->current_device.name, sizeof(player->current_device.name), "Default -> %.240s", info.name);
                    player->current_device.id[0] = '\0';
                    player->current_device.is_default = 1;
                    player->current_device.is_auto = 1;
                }
            }
            else
            {
                strncpy(player->current_device.name, "Default", sizeof(player->current_device.name) - 1);
                player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
                player->current_device.id[0] = '\0';
                player->current_device.is_default = 1;
                player->current_device.is_auto = 1;
            }
        }
    }

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player created (rate=%u, ch=%u, period=%u, device='%s')",
                  player->sample_rate, player->channels, player->buffer_size, player->current_device.name);

    if (out_result)
        *out_result = MAP_SUCCESS;
    return player;
}

MAP_API int32_t miniaudio_player_destroy(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player destroy initiated");

    player->is_switching_device = 1;

    ma_mutex_lock(&player->lock);

    /* Disarm callbacks and stop/uninit sound */
    player->on_completed = NULL;
    if (player->sound_loaded)
    {
        ma_sound_set_end_callback(&player->sound, NULL, NULL);
        ma_sound_stop(&player->sound);
        ma_sound_uninit(&player->sound);
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->sound_loaded = MA_FALSE;
    }

    ma_equalizer_node_uninit(&player->eq_node);

    if (player->file_path != NULL)
    {
        free(player->file_path);
        player->file_path = NULL;
    }

    ma_mutex_unlock(&player->lock);

    /* Stop and uninit engine outside the mutex to avoid deadlock with audio device thread */
    ma_engine_stop(&player->engine);
    ma_engine_uninit(&player->engine);

    if (player->has_resource_manager)
    {
        ma_resource_manager_uninit(&player->resource_manager);
        player->has_resource_manager = MA_FALSE;
    }

    if (player->has_log)
    {
        ma_log_uninit(&player->log);
        player->has_log = MA_FALSE;
    }

    if (player->has_context)
    {
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;
    }

    ma_mutex_uninit(&player->lock);
    free(player);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "player destroy completed");
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Media Loading API                                                         */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_open_file(
    miniaudio_player_t *player,
    const char *file_path)
{
    ma_sound_config sound_cfg;
    ma_result result;
    FILE *f;
    long file_size;

    if (player == NULL || file_path == NULL || file_path[0] == '\0')
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_file: %s", file_path);

    /* Synchronous pre-validation: verify file exists and is non-empty */
#if defined(_WIN32)
    {
        wchar_t *wpath = map_utf8_to_wchar(file_path);
        if (wpath == NULL)
        {
            map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (invalid path): %s", file_path);
            return MAP_ERROR_FILE_NOT_FOUND;
        }
        f = _wfopen(wpath, L"rb");
        free(wpath);
    }
#else
    f = fopen(file_path, "rb");
#endif
    if (f == NULL)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (not found): %s", file_path);
        return MAP_ERROR_FILE_NOT_FOUND;
    }
    if (fseek(f, 0, SEEK_END) != 0)
    {
        fclose(f);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (fseek error): %s", file_path);
        return MAP_ERROR_DECODE_FAILED;
    }
    file_size = ftell(f);
    fclose(f);

    if (file_size <= 0)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file failed (empty file): %s", file_path);
        return MAP_ERROR_DECODE_FAILED;
    }

    ma_mutex_lock(&player->lock);

    /* Unload any previous sound */
    if (player->sound_loaded)
    {
        ma_sound_set_end_callback(&player->sound, NULL, NULL);
        ma_sound_stop(&player->sound);
        ma_sound_uninit(&player->sound);
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->sound_loaded = MA_FALSE;
    }

    /* Initialize time stretch data source wrapping ma_decoder and sonic */
    result = map_time_stretch_ds_init(
        &player->stretch_ds,
        file_path,
        player->channels,
        player->sample_rate);
    if (result != MA_SUCCESS)
    {
        player->state = MAP_PLAYBACK_STATE_ERROR;
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "open_file decoder init failed: %d (%s)", result, file_path);
        return (result == MA_DOES_NOT_EXIST) ? MAP_ERROR_FILE_NOT_FOUND : MAP_ERROR_DECODE_FAILED;
    }

    /* Apply cached rate (speed) and pitch */
    ma_spinlock_lock(&player->stretch_ds.lock);
    player->stretch_ds.speed = player->rate;
    player->stretch_ds.pitch = player->pitch;
    if (player->stretch_ds.sonic != NULL)
    {
        sonicSetSpeed(player->stretch_ds.sonic, player->rate);
        sonicSetPitch(player->stretch_ds.sonic, player->pitch);
    }
    ma_spinlock_unlock(&player->stretch_ds.lock);

    sound_cfg = ma_sound_config_init();
    sound_cfg.pDataSource = &player->stretch_ds.base;
    sound_cfg.flags = MA_SOUND_FLAG_NO_SPATIALIZATION;
    sound_cfg.pInitialAttachment = &player->eq_node.baseNode;
    sound_cfg.initialAttachmentInputBusIndex = 0;
    sound_cfg.endCallback = miniaudio_player_on_sound_end;
    sound_cfg.pEndCallbackUserData = player;

    result = ma_sound_init_ex(&player->engine, &sound_cfg, &player->sound);
    if (result != MA_SUCCESS)
    {
        map_time_stretch_ds_uninit(&player->stretch_ds);
        player->state = MAP_PLAYBACK_STATE_ERROR;
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_init_ex failed: %d (%s)", result, file_path);
        return MAP_ERROR_DECODE_FAILED;
    }

    player->sound_loaded = MA_TRUE;
    player->is_completed = 0;
    player->is_buffering = 0;
    player->state = MAP_PLAYBACK_STATE_STOPPED;

    /* Apply cached volume */
    ma_sound_set_volume(&player->sound, player->volume);

    /* Precise duration from underlying decoder */
    {
        ma_uint64 total_frames = 0;
        if (ma_decoder_get_length_in_pcm_frames(&player->stretch_ds.decoder, &total_frames) == MA_SUCCESS && total_frames > 0)
        {
            player->duration_ms = (int64_t)((double)total_frames * 1000.0 / player->stretch_ds.sampleRate + 0.5);
        }
        else
        {
            float len_sec = 0.0f;
            if (ma_sound_get_length_in_seconds(&player->sound, &len_sec) == MA_SUCCESS && len_sec >= 0.0f)
            {
                player->duration_ms = (int64_t)((double)len_sec * 1000.0 + 0.5);
            }
            else
            {
                player->duration_ms = 0;
            }
        }
    }

    /* Compute nominal audio bitrate in bits per second */
    if (player->duration_ms > 0 && file_size > 0)
    {
        player->bitrate = (uint32_t)(((uint64_t)file_size * 8000ULL) / (uint64_t)player->duration_ms);
    }
    else if (player->sample_rate > 0 && player->channels > 0)
    {
        player->bitrate = player->sample_rate * player->channels * 16;
    }
    else
    {
        player->bitrate = 0;
    }

    if (player->file_path != NULL)
    {
        free(player->file_path);
    }
    player->file_path = map_strdup(file_path);

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "open_file success: dur=%lld ms, bitrate=%u bps (%s)",
                  (long long)player->duration_ms, player->bitrate, file_path);

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Playback Controls                                                         */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_play(miniaudio_player_t *player)
{
    ma_result result;
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "play command");

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    /* Auto-rewind if at end or marked completed */
    if (player->is_completed || ma_sound_at_end(&player->sound))
    {
        ma_sound_seek_to_pcm_frame(&player->sound, 0);
        player->is_completed = 0;
    }

    result = ma_sound_start(&player->sound);
    if (result != MA_SUCCESS)
    {
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_start failed: %d", result);
        return MAP_ERROR_GENERIC;
    }

    player->state = MAP_PLAYBACK_STATE_PLAYING;
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_pause(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "pause command");

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_sound_stop(&player->sound);
    player->state = MAP_PLAYBACK_STATE_PAUSED;
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_stop(miniaudio_player_t *player)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "stop command");

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    ma_sound_stop(&player->sound);
    ma_sound_seek_to_pcm_frame(&player->sound, 0);
    player->is_completed = 0;
    player->state = MAP_PLAYBACK_STATE_STOPPED;
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_seek(miniaudio_player_t *player, int64_t position_ms)
{
    float seek_sec;
    ma_result result;

    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_DEBUG, "core", "seek to %lld ms", (long long)position_ms);

    ma_mutex_lock(&player->lock);
    if (!player->sound_loaded)
    {
        ma_mutex_unlock(&player->lock);
        return MAP_ERROR_INVALID_STATE;
    }

    if (position_ms < 0)
        position_ms = 0;
    if (player->duration_ms > 0 && position_ms > player->duration_ms)
    {
        position_ms = player->duration_ms;
    }

    seek_sec = (float)((double)position_ms / 1000.0);
    result = ma_sound_seek_to_second(&player->sound, seek_sec);
    if (result != MA_SUCCESS)
    {
        ma_mutex_unlock(&player->lock);
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_sound_seek_to_second failed: %d", result);
        return MAP_ERROR_SEEK_FAILED;
    }

    if (position_ms >= player->duration_ms && player->duration_ms > 0)
    {
        player->is_completed = 1;
        player->state = MAP_PLAYBACK_STATE_COMPLETED;
    }
    else
    {
        player->is_completed = 0;
        if (player->state == MAP_PLAYBACK_STATE_COMPLETED)
        {
            player->state = MAP_PLAYBACK_STATE_PAUSED;
        }
    }

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Volume, Rate & Pitch Adjustments                                          */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_volume(miniaudio_player_t *player, float volume)
{
    if (player == NULL || isnan(volume) || isinf(volume) || volume < 0.0f)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_DEBUG, "dsp", "set_volume: %.2f", volume);

    ma_mutex_lock(&player->lock);
    player->volume = volume;
    if (player->sound_loaded)
    {
        ma_sound_set_volume(&player->sound, volume);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_rate(miniaudio_player_t *player, float rate)
{
    if (player == NULL || isnan(rate) || isinf(rate) || rate <= 0.0f)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_DEBUG, "dsp", "set_rate: %.2f", rate);

    ma_mutex_lock(&player->lock);
    player->rate = rate;
    if (player->sound_loaded)
    {
        ma_spinlock_lock(&player->stretch_ds.lock);
        player->stretch_ds.speed = rate;
        if (player->stretch_ds.sonic != NULL)
        {
            sonicSetSpeed(player->stretch_ds.sonic, rate);
        }
        ma_spinlock_unlock(&player->stretch_ds.lock);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_set_pitch(miniaudio_player_t *player, float pitch)
{
    if (player == NULL || isnan(pitch) || isinf(pitch) || pitch <= 0.0f)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    map_log_print(MAP_LOG_LEVEL_DEBUG, "dsp", "set_pitch: %.2f", pitch);

    ma_mutex_lock(&player->lock);
    player->pitch = pitch;
    if (player->sound_loaded)
    {
        ma_spinlock_lock(&player->stretch_ds.lock);
        player->stretch_ds.pitch = pitch;
        if (player->stretch_ds.sonic != NULL)
        {
            sonicSetPitch(player->stretch_ds.sonic, pitch);
        }
        ma_spinlock_unlock(&player->stretch_ds.lock);
    }
    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Buffer Size Configuration                                                 */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_buffer_size(miniaudio_player_t *player, uint32_t buffer_size_in_frames)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;

    map_log_print(MAP_LOG_LEVEL_INFO, "core", "set_buffer_size: %u frames", buffer_size_in_frames);

    ma_mutex_lock(&player->lock);
    player->buffer_size = buffer_size_in_frames;
    ma_mutex_unlock(&player->lock);

    return MAP_SUCCESS;
}

MAP_API uint32_t miniaudio_player_get_buffer_size(const miniaudio_player_t *player)
{
    uint32_t size;
    if (player == NULL)
        return 0;

    ma_mutex_lock((ma_mutex *)&player->lock);
    size = player->buffer_size;
    ma_mutex_unlock((ma_mutex *)&player->lock);

    return size;
}

/* ========================================================================= */
/* Audio Device Management                                                   */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_get_devices(
    miniaudio_device_info_t **out_devices,
    uint32_t *out_count)
{
    ma_context context;
    ma_result result;
    ma_device_info *pPlaybackInfos;
    ma_uint32 playbackCount = 0;
    ma_device_info *pCaptureInfos;
    ma_uint32 captureCount = 0;
    miniaudio_device_info_t *devices = NULL;

    if (out_devices == NULL || out_count == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    *out_devices = NULL;
    *out_count = 0;

    result = ma_context_init(NULL, 0, NULL, &context);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_context_init failed: %d", result);
        return MAP_ERROR_GENERIC;
    }

    result = ma_context_get_devices(&context, &pPlaybackInfos, &playbackCount, NULL, NULL);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_context_get_devices failed: %d", result);
        ma_context_uninit(&context);
        return MAP_ERROR_GENERIC;
    }

    if (playbackCount > 0)
    {
        devices = (miniaudio_device_info_t *)calloc(playbackCount, sizeof(miniaudio_device_info_t));
        if (devices == NULL)
        {
            ma_context_uninit(&context);
            return MAP_ERROR_OUT_OF_MEMORY;
        }

        for (ma_uint32 i = 0; i < playbackCount; ++i)
        {
            strncpy(devices[i].name, pPlaybackInfos[i].name, sizeof(devices[i].name) - 1);
            devices[i].name[sizeof(devices[i].name) - 1] = '\0';
            map_device_id_to_string(&pPlaybackInfos[i].id, devices[i].id, sizeof(devices[i].id));
            devices[i].is_default = pPlaybackInfos[i].isDefault;
            devices[i].is_auto = 0;
        }
    }

    ma_context_uninit(&context);

    *out_devices = devices;
    *out_count = playbackCount;
    return MAP_SUCCESS;
}

MAP_API void miniaudio_player_free_devices(
    miniaudio_device_info_t *devices,
    uint32_t count)
{
    (void)count;
    if (devices != NULL)
    {
        free(devices);
    }
}

MAP_API int32_t miniaudio_player_set_device(
    miniaudio_player_t *player,
    const char *device_id)
{
    if (player == NULL)
        return MAP_ERROR_INVALID_ARGS;
    return map_player_apply_device(player, device_id);
}

MAP_API int32_t miniaudio_player_get_current_device(
    const miniaudio_player_t *player,
    miniaudio_device_info_t *out_device)
{
    miniaudio_player_t *mut_player;
    if (player == NULL || out_device == NULL)
        return MAP_ERROR_INVALID_ARGS;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    *out_device = mut_player->current_device;
    ma_mutex_unlock(&mut_player->lock);

    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Equalizer Controls                                                        */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_equalizer(
    miniaudio_player_t *player,
    const miniaudio_player_equalizer_params_t *eq)
{
    ma_result res;
    if (player == NULL || eq == NULL)
        return MAP_ERROR_INVALID_ARGS;

    if (isnan(eq->hz60) || isinf(eq->hz60) ||
        isnan(eq->hz170) || isinf(eq->hz170) ||
        isnan(eq->hz310) || isinf(eq->hz310) ||
        isnan(eq->hz600) || isinf(eq->hz600) ||
        isnan(eq->hz1k) || isinf(eq->hz1k) ||
        isnan(eq->hz3k) || isinf(eq->hz3k) ||
        isnan(eq->hz6k) || isinf(eq->hz6k) ||
        isnan(eq->hz12k) || isinf(eq->hz12k) ||
        isnan(eq->hz14k) || isinf(eq->hz14k) ||
        isnan(eq->hz16k) || isinf(eq->hz16k))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_mutex_lock(&player->lock);
    res = ma_equalizer_node_set_all(&player->eq_node, eq);
    if (res == MA_SUCCESS)
    {
        player->eq_params = *eq;
    }
    ma_mutex_unlock(&player->lock);
    return (res == MA_SUCCESS) ? MAP_SUCCESS : MAP_ERROR_NODE_FAILED;
}

MAP_API int32_t miniaudio_player_set_equalizer_band(
    miniaudio_player_t *player,
    uint32_t band_index,
    float gain_db)
{
    ma_result res;
    float *pBands;

    if (player == NULL || band_index >= MAP_EQ_BAND_COUNT ||
        isnan(gain_db) || isinf(gain_db))
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    ma_mutex_lock(&player->lock);
    res = ma_equalizer_node_set_band(&player->eq_node, band_index, gain_db);
    if (res == MA_SUCCESS)
    {
        pBands = (float *)&player->eq_params;
        pBands[band_index] = gain_db;
    }
    ma_mutex_unlock(&player->lock);
    return (res == MA_SUCCESS) ? MAP_SUCCESS : MAP_ERROR_NODE_FAILED;
}

/* ========================================================================= */
/* State Snapshot & Query API                                                */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_get_status(
    const miniaudio_player_t *player,
    miniaudio_player_status_t *out_status)
{
    miniaudio_player_t *mut_player;

    if (player == NULL || out_status == NULL)
        return MAP_ERROR_INVALID_ARGS;

    mut_player = (miniaudio_player_t *)player;
    memset(out_status, 0, sizeof(*out_status));

    ma_mutex_lock(&mut_player->lock);

    out_status->duration_ms = mut_player->duration_ms;
    out_status->volume = mut_player->volume;
    out_status->rate = mut_player->rate;
    out_status->pitch = mut_player->pitch;
    out_status->bitrate = mut_player->bitrate;
    out_status->equalizer = mut_player->eq_params;
    out_status->is_buffering = mut_player->is_buffering;

    if (mut_player->sound_loaded)
    {
        float cursor_sec = 0.0f;
        if (ma_sound_get_cursor_in_seconds(&mut_player->sound, &cursor_sec) == MA_SUCCESS && cursor_sec >= 0.0f)
        {
            out_status->position_ms = (int64_t)((double)cursor_sec * 1000.0 + 0.5);
        }
        else
        {
            out_status->position_ms = 0;
        }
        if (mut_player->duration_ms > 0 && out_status->position_ms > mut_player->duration_ms)
        {
            out_status->position_ms = mut_player->duration_ms;
        }

        if (mut_player->is_completed || ma_sound_at_end(&mut_player->sound))
        {
            out_status->is_completed = 1;
            out_status->is_playing = 0;
            out_status->state = MAP_PLAYBACK_STATE_COMPLETED;
            out_status->position_ms = mut_player->duration_ms;
        }
        else
        {
            out_status->is_completed = 0;
            out_status->is_playing = ma_sound_is_playing(&mut_player->sound) ? 1 : 0;
            out_status->state = mut_player->state;
        }
    }
    else
    {
        out_status->state = mut_player->state;
    }

    if (mut_player->needs_device_fallback && !mut_player->is_switching_device)
    {
        mut_player->needs_device_fallback = 0;
        if (mut_player->has_custom_device)
        {
            ma_mutex_unlock(&mut_player->lock);
            map_player_apply_device(mut_player, NULL);
            ma_mutex_lock(&mut_player->lock);
        }
    }
    else
    {
        ma_device *pDev = ma_engine_get_device(&mut_player->engine);
        if (pDev != NULL)
        {
            ma_device_info devInfo;
            if (ma_device_get_info(pDev, ma_device_type_playback, &devInfo) == MA_SUCCESS)
            {
                if (mut_player->has_custom_device)
                {
                    if (devInfo.isDefault != mut_player->current_device.is_default)
                    {
                        mut_player->current_device.is_default = devInfo.isDefault;
                        mut_player->device_changed = 1;
                    }
                }
                else
                {
                    char expectedName[256];
                    snprintf(expectedName, sizeof(expectedName), "Default -> %.240s", devInfo.name);
                    if (strcmp(mut_player->current_device.name, expectedName) != 0)
                    {
                        strncpy(mut_player->current_device.name, expectedName, sizeof(mut_player->current_device.name) - 1);
                        mut_player->current_device.name[sizeof(mut_player->current_device.name) - 1] = '\0';
                        mut_player->device_changed = 1;
                    }
                }
            }
        }
    }
    out_status->device = mut_player->current_device;

    ma_mutex_unlock(&mut_player->lock);
    return MAP_SUCCESS;
}

MAP_API int64_t miniaudio_player_get_position_ms(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.position_ms;
}

MAP_API int64_t miniaudio_player_get_duration_ms(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.duration_ms;
}

MAP_API int32_t miniaudio_player_is_playing(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.is_playing;
}

MAP_API int32_t miniaudio_player_is_completed(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.is_completed;
}

MAP_API float miniaudio_player_get_volume(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 1.0f;
    return status.volume;
}

MAP_API float miniaudio_player_get_rate(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 1.0f;
    return status.rate;
}

MAP_API float miniaudio_player_get_pitch(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 1.0f;
    return status.pitch;
}

MAP_API uint32_t miniaudio_player_get_bitrate(const miniaudio_player_t *player)
{
    miniaudio_player_status_t status;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return 0;
    return status.bitrate;
}

MAP_API int32_t miniaudio_player_get_equalizer(
    const miniaudio_player_t *player,
    miniaudio_player_equalizer_params_t *out_equalizer)
{
    miniaudio_player_status_t status;
    if (player == NULL || out_equalizer == NULL)
        return MAP_ERROR_INVALID_ARGS;
    if (miniaudio_player_get_status(player, &status) != MAP_SUCCESS)
        return MAP_ERROR_GENERIC;
    *out_equalizer = status.equalizer;
    return MAP_SUCCESS;
}
