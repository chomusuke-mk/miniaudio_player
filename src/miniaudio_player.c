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

#if !defined(_WIN32)
#include <pthread.h>
#endif

#if !defined(MA_NO_LIBOPUS)
#include "decoders/libopus/miniaudio_libopus.h"
#endif

#if !defined(MA_NO_AAC)
#include "decoders/aac/miniaudio_aac.h"
#endif

static ma_decoding_backend_vtable *g_map_custom_decoders[4] = {NULL, NULL, NULL, NULL};
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
#if !defined(MA_NO_AAC)
        if (ma_decoding_backend_aac != NULL)
        {
            g_map_custom_decoders[count++] = ma_decoding_backend_aac;
        }
#endif
        g_map_custom_decoders_initialized = 1;
    }
    else
    {
        while (count < 4 && g_map_custom_decoders[count] != NULL)
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
#include <jni.h>
#include <dlfcn.h>
#include <strings.h>
#include <link.h>
#include <elf.h>
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

/* Helper to check if a device ID string represents the automatic/default output */
static ma_bool32 map_is_device_id_default(const char *str)
{
    size_t i, len;
    if (str == NULL || str[0] == '\0')
        return MA_TRUE;
    if (strcmp(str, "auto") == 0 || strcmp(str, "default") == 0 || strcmp(str, "0") == 0)
        return MA_TRUE;
    len = strlen(str);
    if (len == sizeof(ma_device_id) * 2)
    {
        for (i = 0; i < len; i++)
        {
            if (str[i] != '0')
                return MA_FALSE;
        }
        return MA_TRUE;
    }
    return MA_FALSE;
}

/* Device ID serialization: converts ma_device_id to/from 512-character hex string, or integer on Android */
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
#if defined(__ANDROID__)
    if (pID->aaudio > 0)
    {
        snprintf(out_str, max_len, "%d", (int)pID->aaudio);
        return;
    }
    else
    {
        out_str[0] = '\0';
        return;
    }
#endif
    for (i = 0; i < sizeof(ma_device_id); i++)
    {
        sprintf(out_str + (i * 2), "%02x", bytes[i]);
    }
    out_str[sizeof(ma_device_id) * 2] = '\0';
}

static ma_bool32 map_string_to_device_id(const char *str, ma_device_id *out_id)
{
    size_t i;
    if (str == NULL || out_id == NULL)
        return MA_FALSE;

    memset(out_id, 0, sizeof(ma_device_id));

    if (strlen(str) == sizeof(ma_device_id) * 2)
    {
        unsigned char *bytes = (unsigned char *)out_id;
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

    const char *num_str = str;
    if (strncmp(str, "android:", 8) == 0)
    {
        num_str = str + 8;
    }

    char *endptr = NULL;
    long int_val = strtol(num_str, &endptr, 10);
    if (endptr != num_str && *endptr == '\0')
    {
        out_id->aaudio = (ma_int32)int_val;
        out_id->opensl = (ma_uint32)int_val;
        return MA_TRUE;
    }

    return MA_FALSE;
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
    float b0, b1, b2, a1, a2;
    float s1, s2;
} map_biquad_df2t_t;

static MA_INLINE float map_biquad_df2t_process(map_biquad_df2t_t *f, float x)
{
    float y = f->b0 * x + f->s1;
    f->s1 = f->b1 * x - f->a1 * y + f->s2;
    f->s2 = f->b2 * x - f->a2 * y;
    return y;
}

static void map_biquad_bpf_init(map_biquad_df2t_t *filter, double f0, double fs, double q)
{
    double w0, alpha, cos_w, b0, b1, b2, a0, a1, a2;
    if (fs <= 0.0) fs = 44100.0;
    if (f0 >= fs * 0.49) f0 = fs * 0.49;
    if (f0 < 10.0) f0 = 10.0;
    if (q <= 0.0) q = 1.0;

    w0 = 2.0 * MA_PI_D * f0 / fs;
    alpha = sin(w0) / (2.0 * q);
    cos_w = cos(w0);

    b0 = alpha;
    b1 = 0.0;
    b2 = -alpha;
    a0 = 1.0 + alpha;
    a1 = -2.0 * cos_w;
    a2 = 1.0 - alpha;

    filter->b0 = (float)(b0 / a0);
    filter->b1 = (float)(b1 / a0);
    filter->b2 = (float)(b2 / a0);
    filter->a1 = (float)(a1 / a0);
    filter->a2 = (float)(a2 / a0);
    filter->s1 = 0.0f;
    filter->s2 = 0.0f;
}

typedef struct
{
    ma_node_base baseNode;
    ma_spinlock lock;
    ma_loshelf2 loshelf;
    ma_peak2 peaks[8];
    ma_hishelf2 hishelf;
    ma_uint32 channels;
    ma_uint32 sampleRate;
    int32_t visualizer_enabled;
    map_biquad_df2t_t vis_bpf[10];
    miniaudio_player_visualizer_data_t visualizer_data;
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

    if (pEq->visualizer_enabled)
    {
        ma_uint32 totalFrames = frameCount;
        ma_uint32 ch = pEq->channels;
        float *pSamples = ppFramesOut[0];
        float sum_sq_l = 0.0f, sum_sq_r = 0.0f;
        float peak_l = 0.0f, peak_r = 0.0f;
        float band_sq[10] = {0.0f};
        ma_uint32 s;
        int b;

        for (s = 0; s < totalFrames; s++)
        {
            float l = pSamples[s * ch];
            float r = (ch > 1) ? pSamples[s * ch + 1] : l;
            float mono = 0.5f * (l + r);
            float abs_l = fabsf(l);
            float abs_r = fabsf(r);

            sum_sq_l += l * l;
            sum_sq_r += r * r;
            if (abs_l > peak_l) peak_l = abs_l;
            if (abs_r > peak_r) peak_r = abs_r;

            for (b = 0; b < 10; b++)
            {
                float y = map_biquad_df2t_process(&pEq->vis_bpf[b], mono);
                band_sq[b] += y * y;
            }
        }

        float invFrames = (totalFrames > 0) ? (1.0f / (float)totalFrames) : 0.0f;
        float rms_l = sqrtf(sum_sq_l * invFrames);
        float rms_r = sqrtf(sum_sq_r * invFrames);
        float global_rms = 0.5f * (rms_l + rms_r);
        float global_peak = (peak_l > peak_r) ? peak_l : peak_r;

        const float decay = 0.82f;
        static const float band_weights[10] = {
            1.4f, 1.6f, 1.8f, 2.0f, 2.2f, 2.4f, 2.8f, 3.2f, 3.6f, 4.0f
        };

        for (b = 0; b < 10; b++)
        {
            float b_rms = sqrtf(band_sq[b] * invFrames) * band_weights[b];
            if (b_rms > 1.0f) b_rms = 1.0f;

            if (b_rms >= pEq->visualizer_data.bands[b])
                pEq->visualizer_data.bands[b] = b_rms;
            else
                pEq->visualizer_data.bands[b] = pEq->visualizer_data.bands[b] * decay + b_rms * (1.0f - decay);
        }

        if (global_rms >= pEq->visualizer_data.rms)
            pEq->visualizer_data.rms = (global_rms > 1.0f) ? 1.0f : global_rms;
        else
            pEq->visualizer_data.rms = pEq->visualizer_data.rms * decay;

        if (global_peak >= pEq->visualizer_data.peak)
            pEq->visualizer_data.peak = (global_peak > 1.0f) ? 1.0f : global_peak;
        else
            pEq->visualizer_data.peak = pEq->visualizer_data.peak * decay;

        if (rms_l >= pEq->visualizer_data.left)
            pEq->visualizer_data.left = (rms_l > 1.0f) ? 1.0f : rms_l;
        else
            pEq->visualizer_data.left = pEq->visualizer_data.left * decay;

        if (rms_r >= pEq->visualizer_data.right)
            pEq->visualizer_data.right = (rms_r > 1.0f) ? 1.0f : rms_r;
        else
            pEq->visualizer_data.right = pEq->visualizer_data.right * decay;
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

    /* Visualizer BPF filters for the 10 frequency bands */
    pNode->visualizer_enabled = 0;
    memset(&pNode->visualizer_data, 0, sizeof(pNode->visualizer_data));
    for (i = 0; i < 10; i++)
    {
        map_biquad_bpf_init(&pNode->vis_bpf[i], g_map_eq_frequencies[i], (double)sampleRate, 1.2);
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
/* Silence Detection & Skipping DSP                                          */
/* ========================================================================= */

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

static void map_silence_detector_update_params(map_silence_detector *pDet)
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

static void map_silence_detector_init(
    map_silence_detector *pDet,
    ma_uint32 channels,
    ma_uint32 sample_rate)
{
    if (pDet == NULL)
        return;

    memset(pDet, 0, sizeof(*pDet));
    pDet->channels = channels;
    pDet->sample_rate = sample_rate;

    pDet->config.mode = MAP_SILENCE_MODE_DISABLED;
    pDet->config.threshold_db = -45.0f;
    pDet->config.min_silence_duration_ms = 300;
    pDet->config.padding_ms = 50;

    map_silence_detector_update_params(pDet);

    /* Allocate hold buffer: default up to 3 seconds of frames */
    pDet->hold_buffer_capacity = sample_rate * 3;
    if (channels > 0 && pDet->hold_buffer_capacity > 0)
    {
        pDet->hold_buffer = (float *)malloc(pDet->hold_buffer_capacity * channels * sizeof(float));
    }
}

static void map_silence_detector_uninit(map_silence_detector *pDet)
{
    if (pDet == NULL)
        return;
    if (pDet->hold_buffer != NULL)
    {
        free(pDet->hold_buffer);
        pDet->hold_buffer = NULL;
    }
}

static void map_silence_detector_set_config(
    map_silence_detector *pDet,
    const miniaudio_player_silence_config_t *config)
{
    if (pDet == NULL || config == NULL)
        return;

    pDet->config = *config;
    map_silence_detector_update_params(pDet);

    /* Ensure hold buffer can hold at least min_silence_frames + padding_frames */
    ma_uint32 required = pDet->min_silence_frames + pDet->padding_frames + (pDet->sample_rate * 2);
    if (required > pDet->hold_buffer_capacity)
    {
        float *new_buf = (float *)realloc(pDet->hold_buffer, required * pDet->channels * sizeof(float));
        if (new_buf != NULL)
        {
            pDet->hold_buffer = new_buf;
            pDet->hold_buffer_capacity = required;
        }
    }
}

static void map_silence_detector_reset(map_silence_detector *pDet, ma_bool32 is_start)
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

static int64_t map_silence_detector_get_saved_ms(const map_silence_detector *pDet)
{
    if (pDet == NULL || pDet->sample_rate == 0)
        return 0;
    return (pDet->silence_saved_frames * 1000) / pDet->sample_rate;
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
    float *rawBuffer;
    ma_uint32 rawBufferCapacity; /* in floats */
    ma_uint32 rawBufferCount;    /* in frames */
    ma_uint32 rawBufferReadPos;  /* in frames */
    map_silence_detector silence;
} map_time_stretch_ds;

static ma_result map_time_stretch_ds_read_filtered(
    map_time_stretch_ds *pDS,
    float *pFramesOut,
    ma_uint64 framesToRead,
    ma_uint64 *pFramesRead)
{
    map_silence_detector *pDet = &pDS->silence;
    ma_uint32 channels = pDS->channels;
    ma_uint64 totalRead = 0;

    if (pFramesRead != NULL)
        *pFramesRead = 0;
    if (framesToRead == 0)
        return MA_SUCCESS;

    /* Fast path if silence detection is disabled and no buffered frames */
    if (pDet->config.mode == MAP_SILENCE_MODE_DISABLED &&
        pDet->hold_frames_read_pos >= pDet->hold_frames_count &&
        pDS->rawBufferReadPos >= pDS->rawBufferCount)
    {
        return ma_decoder_read_pcm_frames(&pDS->decoder, pFramesOut, framesToRead, pFramesRead);
    }

    while (totalRead < framesToRead && !pDS->is_eof)
    {
        /* 1. Flush held frames from detector if any are ready to be read */
        if (pDet->state != MAP_SILENCE_STATE_HOLDING && pDet->hold_frames_read_pos < pDet->hold_frames_count)
        {
            ma_uint64 avail = pDet->hold_frames_count - pDet->hold_frames_read_pos;
            ma_uint64 to_copy = (avail < (framesToRead - totalRead)) ? avail : (framesToRead - totalRead);
            if (pFramesOut != NULL)
            {
                memcpy(pFramesOut + totalRead * channels,
                       pDet->hold_buffer + pDet->hold_frames_read_pos * channels,
                       to_copy * channels * sizeof(float));
            }
            if (to_copy > 0)
            {
                float *last_frame = pDet->hold_buffer + (pDet->hold_frames_read_pos + to_copy - 1) * channels;
                for (ma_uint32 c = 0; c < channels && c < 8; c++)
                {
                    pDet->last_sample[c] = last_frame[c];
                }
            }
            pDet->hold_frames_read_pos += (ma_uint32)to_copy;
            totalRead += to_copy;
            if (pDet->hold_frames_read_pos >= pDet->hold_frames_count)
            {
                pDet->hold_frames_read_pos = 0;
                pDet->hold_frames_count = 0;
            }
            continue;
        }

        /* 2. Replenish rawBuffer from decoder if empty */
        if (pDS->rawBufferReadPos >= pDS->rawBufferCount)
        {
            ma_uint64 rawRead = 0;
            ma_result res = ma_decoder_read_pcm_frames(
                &pDS->decoder,
                pDS->rawBuffer,
                1024,
                &rawRead);

            pDS->rawBufferCount = (ma_uint32)rawRead;
            pDS->rawBufferReadPos = 0;

            if (res != MA_SUCCESS || rawRead == 0)
            {
                pDS->is_eof = MA_TRUE;
                /* If we reached EOF while holding silence, discard the held silence (lead-out trim) */
                if (pDet->state == MAP_SILENCE_STATE_HOLDING)
                {
                    pDet->silence_saved_frames += (pDet->hold_frames_count - pDet->hold_frames_read_pos);
                    pDet->hold_frames_count = 0;
                    pDet->hold_frames_read_pos = 0;
                }
                break;
            }
        }

        /* 3. Process frames from rawBuffer */
        while (pDS->rawBufferReadPos < pDS->rawBufferCount && totalRead < framesToRead)
        {
            float *frame = pDS->rawBuffer + pDS->rawBufferReadPos * channels;
            pDS->rawBufferReadPos++;

            /* Calculate frame peak amplitude */
            float peak = 0.0f;
            for (ma_uint32 c = 0; c < channels; c++)
            {
                float val = fabsf(frame[c]);
                if (val > peak)
                    peak = val;
            }

            ma_bool32 is_silent_enter = (peak <= pDet->threshold_amp_linear);
            ma_bool32 is_silent_exit  = (peak <= pDet->threshold_amp_exit);

            /* Check disabled mode */
            if (pDet->config.mode == MAP_SILENCE_MODE_DISABLED)
            {
                if (pFramesOut != NULL)
                {
                    memcpy(pFramesOut + totalRead * channels, frame, channels * sizeof(float));
                }
                totalRead++;
                continue;
            }

            /* Lead-in silence trim */
            if (pDet->lead_in_active)
            {
                if (is_silent_enter)
                {
                    pDet->silence_saved_frames++;
                    continue;
                }
                else
                {
                    pDet->lead_in_active = MA_FALSE;
                    pDet->crossfade_remaining = pDet->crossfade_length;
                    for (ma_uint32 c = 0; c < channels && c < 8; c++)
                        pDet->last_sample[c] = 0.0f;
                }
            }

            /* Continuous or Edge trimming state machine */
            ma_bool32 body_skip_enabled = (pDet->config.mode == MAP_SILENCE_MODE_CONTINUOUS ||
                                           pDet->config.mode == MAP_SILENCE_MODE_ALL);

            if (pDet->config.mode == MAP_SILENCE_MODE_TRIM_EDGES)
            {
                /* In TRIM_EDGES, also enable silence holding if near EOF */
                ma_uint64 total_len = 0, cur_cursor = 0;
                if (ma_decoder_get_length_in_pcm_frames(&pDS->decoder, &total_len) == MA_SUCCESS && total_len > 0 &&
                    ma_decoder_get_cursor_in_pcm_frames(&pDS->decoder, &cur_cursor) == MA_SUCCESS)
                {
                    if (cur_cursor + (pDS->sampleRate * 5) >= total_len)
                    {
                        body_skip_enabled = MA_TRUE;
                    }
                }
            }

            if (!body_skip_enabled)
            {
                if (pFramesOut != NULL)
                {
                    memcpy(pFramesOut + totalRead * channels, frame, channels * sizeof(float));
                }
                totalRead++;
                continue;
            }

            /* State machine */
            if (pDet->state == MAP_SILENCE_STATE_VOICE)
            {
                if (!is_silent_enter)
                {
                    /* Sound playing */
                    if (pDet->crossfade_remaining > 0 && pDet->crossfade_length > 0)
                    {
                        float alpha = 1.0f - ((float)pDet->crossfade_remaining / (float)pDet->crossfade_length);
                        for (ma_uint32 c = 0; c < channels && c < 8; c++)
                        {
                            frame[c] = (1.0f - alpha) * pDet->last_sample[c] + alpha * frame[c];
                        }
                        pDet->crossfade_remaining--;
                    }
                    for (ma_uint32 c = 0; c < channels && c < 8; c++)
                    {
                        pDet->last_sample[c] = frame[c];
                    }
                    if (pFramesOut != NULL)
                    {
                        memcpy(pFramesOut + totalRead * channels, frame, channels * sizeof(float));
                    }
                    totalRead++;
                }
                else
                {
                    /* Transition to HOLDING */
                    pDet->state = MAP_SILENCE_STATE_HOLDING;
                    pDet->hold_frames_count = 0;
                    pDet->hold_frames_read_pos = 0;
                    if (pDet->hold_buffer != NULL && pDet->hold_buffer_capacity > 0)
                    {
                        memcpy(pDet->hold_buffer, frame, channels * sizeof(float));
                        pDet->hold_frames_count = 1;
                    }
                }
            }
            else if (pDet->state == MAP_SILENCE_STATE_HOLDING)
            {
                if (is_silent_enter)
                {
                    if (pDet->hold_buffer != NULL && pDet->hold_frames_count < pDet->hold_buffer_capacity)
                    {
                        memcpy(pDet->hold_buffer + pDet->hold_frames_count * channels, frame, channels * sizeof(float));
                        pDet->hold_frames_count++;
                    }
                    if (pDet->hold_frames_count >= pDet->min_silence_frames)
                    {
                        /* Silence duration exceeded threshold: prune to padding_frames and transition to SKIPPING */
                        ma_uint32 keep = pDet->padding_frames;
                        if (keep > pDet->hold_frames_count)
                            keep = pDet->hold_frames_count;
                        pDet->silence_saved_frames += (pDet->hold_frames_count - keep);
                        pDet->hold_frames_count = keep;
                        pDet->hold_frames_read_pos = 0;
                        pDet->state = MAP_SILENCE_STATE_SKIPPING;

                        /* Break inner loop to flush padding frames on next outer iteration */
                        break;
                    }
                }
                else
                {
                    /* Voice resumed before min_silence_frames: flush held frames */
                    pDet->state = MAP_SILENCE_STATE_VOICE;
                    pDet->hold_frames_read_pos = 0;
                    /* Rewind current frame so it will be processed after held frames are flushed */
                    pDS->rawBufferReadPos--;
                    break;
                }
            }
            else if (pDet->state == MAP_SILENCE_STATE_SKIPPING)
            {
                if (is_silent_exit)
                {
                    /* Discard frame */
                    pDet->silence_saved_frames++;
                }
                else
                {
                    /* Voice resumed! */
                    pDet->state = MAP_SILENCE_STATE_VOICE;
                    pDet->crossfade_remaining = pDet->crossfade_length;

                    if (pDet->crossfade_remaining > 0 && pDet->crossfade_length > 0)
                    {
                        float alpha = 1.0f - ((float)pDet->crossfade_remaining / (float)pDet->crossfade_length);
                        for (ma_uint32 c = 0; c < channels && c < 8; c++)
                        {
                            frame[c] = (1.0f - alpha) * pDet->last_sample[c] + alpha * frame[c];
                        }
                        pDet->crossfade_remaining--;
                    }
                    for (ma_uint32 c = 0; c < channels && c < 8; c++)
                    {
                        pDet->last_sample[c] = frame[c];
                    }
                    if (pFramesOut != NULL)
                    {
                        memcpy(pFramesOut + totalRead * channels, frame, channels * sizeof(float));
                    }
                    totalRead++;
                }
            }
        }
    }

    if (pFramesRead != NULL)
    {
        *pFramesRead = totalRead;
    }
    return MA_SUCCESS;
}

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
            ma_result res = map_time_stretch_ds_read_filtered(
                pDS,
                pOut ? (pOut + totalFramesOut * pDS->channels) : discardBuf,
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

        /* Pull from decoder through silence filter and write to sonic */
        ma_uint64 framesFromDecoder = 0;
        ma_result readRes = map_time_stretch_ds_read_filtered(
            pDS,
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
    ma_uint64 total_frames = 0;
    if (pDS == NULL)
        return MA_INVALID_ARGS;

    ma_spinlock_lock(&pDS->lock);
    pDS->rawBufferCount = 0;
    pDS->rawBufferReadPos = 0;
    map_silence_detector_reset(&pDS->silence, frameIndex == 0);

    if (ma_decoder_get_length_in_pcm_frames(&pDS->decoder, &total_frames) == MA_SUCCESS && total_frames > 0)
    {
        if (frameIndex >= total_frames)
        {
            /* Seeking at or beyond EOF:
             * Many decoders (e.g. stb_vorbis for OGG/OGA and opusfile for OPUS)
             * return error (OP_EINVAL or VORBIS_seek_failed) if attempting to
             * seek at or beyond total_frames.
             * Handle EOF cleanly: seek to the last valid frame (total_frames - 1) and mark is_eof.
             */
            ma_decoder_seek_to_pcm_frame(&pDS->decoder, total_frames - 1);
            if (pDS->sonic != NULL)
            {
                sonicResetStream(pDS->sonic);
            }
            pDS->is_eof = MA_TRUE;
            ma_spinlock_unlock(&pDS->lock);
            return MA_SUCCESS;
        }
    }

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
    if (pDS->is_eof)
    {
        return ma_decoder_get_length_in_pcm_frames(&pDS->decoder, pCursor);
    }
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

    pDS->rawBufferCapacity = 1024 * targetChannels;
    pDS->rawBuffer = (float *)malloc(pDS->rawBufferCapacity * sizeof(float));
    if (pDS->rawBuffer == NULL)
    {
        free(pDS->scratchBuffer);
        sonicDestroyStream(pDS->sonic);
        ma_decoder_uninit(&pDS->decoder);
        return MA_OUT_OF_MEMORY;
    }
    pDS->rawBufferCount = 0;
    pDS->rawBufferReadPos = 0;

    map_silence_detector_init(&pDS->silence, targetChannels, targetSampleRate);

    baseConfig = ma_data_source_config_init();
    baseConfig.vtable = &g_map_time_stretch_ds_vtable;

    result = ma_data_source_init(&baseConfig, &pDS->base);
    if (result != MA_SUCCESS)
    {
        map_silence_detector_uninit(&pDS->silence);
        free(pDS->rawBuffer);
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
    if (pDS->rawBuffer != NULL)
    {
        free(pDS->rawBuffer);
        pDS->rawBuffer = NULL;
    }
    map_silence_detector_uninit(&pDS->silence);
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
    miniaudio_player_silence_config_t silence_config;
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

static miniaudio_player_device_notification_cb g_device_notification_cb = NULL;
static void *g_device_notification_user_data = NULL;

MAP_API void miniaudio_player_set_device_notification_callback(
    miniaudio_player_device_notification_cb on_device_notification,
    void *user_data)
{
    g_device_notification_cb = on_device_notification;
    g_device_notification_user_data = user_data;
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
                if (player->custom_device_id.aaudio > 0 &&
                    (pNotification->pDevice->pContext == NULL || pNotification->pDevice->pContext->backend == ma_backend_aaudio || pNotification->pDevice->pContext->backend == ma_backend_opensl
#if defined(__ANDROID__)
                     || 1
#endif
                    ))
                {
                    snprintf(player->current_device.id, sizeof(player->current_device.id), "%d", (int)player->custom_device_id.aaudio);
                }
                else
                {
                    map_device_id_to_string(&info.id, player->current_device.id, sizeof(player->current_device.id));
                }
                player->current_device.is_default = info.isDefault;
                player->current_device.is_auto = 0;
            }
            else
            {
                strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
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

    if (g_device_notification_cb != NULL)
    {
        g_device_notification_cb(g_device_notification_user_data);
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

    if (pContext->backend == ma_backend_aaudio)
    {
        return (pTargetID->aaudio > 0) ? MA_TRUE : MA_FALSE;
    }

#if defined(__ANDROID__)
    if (pContext->backend == ma_backend_opensl)
    {
        return (pTargetID->opensl > 0 || pTargetID->aaudio > 0) ? MA_TRUE : MA_FALSE;
    }
#endif

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
#if defined(__ANDROID__)
    if (pContext->backend == ma_backend_aaudio)
    {
        ma_atomic_bool32_set(&pDevice->aaudio.isTearingDown, MA_TRUE);
    }
#endif

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

    if (!map_is_device_id_default(device_id))
    {
        if (map_string_to_device_id(device_id, &target_id) && map_is_device_connected(pContext, &target_id))
        {
            dev_cfg.playback.pDeviceID = &target_id;
            has_custom = MA_TRUE;
#if defined(__ANDROID__)
            /* Explicit non-default Android device routing: use conservative performance profile.
               This forces AAudio to use AudioStreamTrack (tryMMap = false), avoiding exclusive
               hardware MMAP conflicts and "requestStart() error = -898, stream was probably stolen". */
            dev_cfg.performanceProfile = ma_performance_profile_conservative;
#endif
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
            if (target_id.aaudio > 0 &&
                (pContext->backend == ma_backend_aaudio || pContext->backend == ma_backend_opensl
#if defined(__ANDROID__)
                 || 1
#endif
                ))
            {
                snprintf(new_dev_info.id, sizeof(new_dev_info.id), "%d", (int)target_id.aaudio);
            }
            else
            {
                map_device_id_to_string(&dev_info.id, new_dev_info.id, sizeof(new_dev_info.id));
            }
            new_dev_info.is_default = dev_info.isDefault;
            new_dev_info.is_auto = 0;
        }
        else
        {
            strncpy(new_dev_info.name, dev_info.name, sizeof(new_dev_info.name) - 1);
            new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
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
        res = ma_device_start(pDevice);
        if (res != MA_SUCCESS && has_custom)
        {
            map_log_print(MAP_LOG_LEVEL_WARNING, "core", "failed to start custom device '%s' (res %d), falling back to default", device_id, res);
#if defined(__ANDROID__)
            if (pContext->backend == ma_backend_aaudio)
            {
                ma_atomic_bool32_set(&pDevice->aaudio.isTearingDown, MA_TRUE);
            }
#endif
            dev_cfg.playback.pDeviceID = NULL;
            dev_cfg.performanceProfile = ma_performance_profile_low_latency;
            has_custom = MA_FALSE;
            memset(&target_id, 0, sizeof(target_id));
            ma_device_uninit(pDevice);
            if (ma_device_init(pContext, &dev_cfg, pDevice) == MA_SUCCESS)
            {
                if (ma_device_get_info(pDevice, ma_device_type_playback, &dev_info) == MA_SUCCESS)
                {
                    strncpy(new_dev_info.name, dev_info.name, sizeof(new_dev_info.name) - 1);
                    new_dev_info.name[sizeof(new_dev_info.name) - 1] = '\0';
                }
                else
                {
                    strncpy(new_dev_info.name, "Default", sizeof(new_dev_info.name) - 1);
                }
                new_dev_info.id[0] = '\0';
                new_dev_info.is_default = 1;
                new_dev_info.is_auto = 1;

                ma_mutex_lock(&player->lock);
                player->has_custom_device = 0;
                player->custom_device_id = target_id;
                player->current_device = new_dev_info;
                player->device_changed = 1;
                player->needs_device_fallback = 0;
                ma_mutex_unlock(&player->lock);

                ma_device_start(pDevice);
                player->is_switching_device = 0;
                map_log_print(MAP_LOG_LEVEL_INFO, "core", "playback device active (fallback): '%s' (default: %d)",
                              new_dev_info.name, new_dev_info.is_default);
                return MAP_SUCCESS;
            }
            player->is_switching_device = 0;
            return MAP_ERROR_GENERIC;
        }
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
    int32_t fail_result = MAP_ERROR_GENERIC;

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
    player->silence_config.mode = MAP_SILENCE_MODE_DISABLED;
    player->silence_config.threshold_db = -45.0f;
    player->silence_config.min_silence_duration_ms = 300;
    player->silence_config.padding_ms = 50;

    player->buffer_size = (config != NULL && config->period_size_in_frames > 0)
                              ? config->period_size_in_frames
                              : 1024;
    player->has_resource_manager = MA_FALSE;

    if (config != NULL)
    {
        player->on_completed = config->on_completed;
        player->user_data = config->user_data;
    }

    player->has_log = MA_FALSE;
    result = ma_log_init(NULL, &player->log);
    if (result == MA_SUCCESS)
    {
        ma_log_register_callback(&player->log, ma_log_callback_init(map_miniaudio_log_callback, player));
        player->has_log = MA_TRUE;
    }

    engine_cfg = ma_engine_config_init();
    if (player->has_log)
    {
        engine_cfg.pLog = &player->log;
    }

    player->has_context = MA_FALSE;
    {
        ma_context_config context_cfg = ma_context_config_init();
        if (player->has_log)
        {
            context_cfg.pLog = &player->log;
        }
        result = ma_context_init(NULL, 0, &context_cfg, &player->context);
        if (result == MA_SUCCESS)
        {
            player->has_context = MA_TRUE;
            engine_cfg.pContext = &player->context;
        }
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

    if (config != NULL && !map_is_device_id_default(config->playback_device_id))
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
            if (player->has_log)
            {
                rm_cfg.pLog = &player->log;
            }
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

    result = ma_engine_init(&engine_cfg, &player->engine);
    if (result != MA_SUCCESS && engine_cfg.pPlaybackDeviceID != NULL)
    {
        map_log_print(MAP_LOG_LEVEL_WARNING, "core", "ma_engine_init failed with custom device (%d), retrying with default device", result);
        engine_cfg.pPlaybackDeviceID = NULL;
        player->has_custom_device = MA_FALSE;
        result = ma_engine_init(&engine_cfg, &player->engine);
    }
#if defined(__ANDROID__)
    if (result != MA_SUCCESS && player->has_context && player->context.backend == ma_backend_aaudio)
    {
        map_log_print(MAP_LOG_LEVEL_WARNING, "core", "ma_engine_init failed with AAudio (%d), retrying with OpenSL ES fallback", result);
        ma_context_uninit(&player->context);
        player->has_context = MA_FALSE;

        ma_backend backends[1] = { ma_backend_opensl };
        ma_context_config ctx_cfg = ma_context_config_init();
        if (player->has_log)
            ctx_cfg.pLog = &player->log;
        if (ma_context_init(backends, 1, &ctx_cfg, &player->context) == MA_SUCCESS)
        {
            player->has_context = MA_TRUE;
            engine_cfg.pContext = &player->context;
            result = ma_engine_init(&engine_cfg, &player->engine);
        }
    }
#endif
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_engine_init failed: %d", result);
        fail_result = MAP_ERROR_ENGINE_INIT;
        goto cleanup_error;
    }

    player->sample_rate = ma_engine_get_sample_rate(&player->engine);
    player->channels = ma_engine_get_channels(&player->engine);

    /* Initialize composite equalizer node */
    result = ma_equalizer_node_init(&player->engine.nodeGraph, player->channels, player->sample_rate, &player->eq_node);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_equalizer_node_init failed: %d", result);
        ma_engine_uninit(&player->engine);
        fail_result = MAP_ERROR_NODE_FAILED;
        goto cleanup_error;
    }

    /* Attach equalizer output to engine master endpoint */
    result = ma_node_attach_output_bus(&player->eq_node.baseNode, 0, ma_engine_get_endpoint(&player->engine), 0);
    if (result != MA_SUCCESS)
    {
        map_log_print(MAP_LOG_LEVEL_ERROR, "core", "ma_node_attach_output_bus failed: %d", result);
        ma_equalizer_node_uninit(&player->eq_node);
        ma_engine_uninit(&player->engine);
        fail_result = MAP_ERROR_NODE_FAILED;
        goto cleanup_error;
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
                    if (player->custom_device_id.aaudio > 0 &&
                        (pDevice->pContext == NULL || pDevice->pContext->backend == ma_backend_aaudio || pDevice->pContext->backend == ma_backend_opensl
#if defined(__ANDROID__)
                         || 1
#endif
                        ))
                    {
                        snprintf(player->current_device.id, sizeof(player->current_device.id), "%d", (int)player->custom_device_id.aaudio);
                    }
                    else
                    {
                        map_device_id_to_string(&info.id, player->current_device.id, sizeof(player->current_device.id));
                    }
                    player->current_device.is_default = info.isDefault;
                    player->current_device.is_auto = 0;
                }
                else
                {
                    strncpy(player->current_device.name, info.name, sizeof(player->current_device.name) - 1);
                    player->current_device.name[sizeof(player->current_device.name) - 1] = '\0';
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

cleanup_error:
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
    if (out_result)
        *out_result = fail_result;
    return NULL;
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
    map_silence_detector_set_config(&player->stretch_ds.silence, &player->silence_config);
    map_silence_detector_reset(&player->stretch_ds.silence, MA_TRUE);
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
    if (player->sound.pDataSource != NULL)
    {
        ma_data_source_seek_to_pcm_frame(player->sound.pDataSource, 0);
    }
    ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
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
        ma_sound_stop(&player->sound);
        if (player->sound.pDataSource != NULL)
        {
            ma_uint64 total_frames = 0;
            if (ma_data_source_get_length_in_pcm_frames(player->sound.pDataSource, &total_frames) == MA_SUCCESS && total_frames > 0)
            {
                ma_data_source_seek_to_pcm_frame(player->sound.pDataSource, total_frames);
            }
        }
        ma_atomic_exchange_32(&player->sound.atEnd, MA_TRUE);
        player->is_completed = 1;
        player->state = MAP_PLAYBACK_STATE_COMPLETED;
    }
    else
    {
        ma_atomic_exchange_32(&player->sound.atEnd, MA_FALSE);
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

#if defined(__ANDROID__)

static JavaVM *g_map_jvm = NULL;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)reserved;
    g_map_jvm = vm;
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] JNI_OnLoad called, captured JavaVM: %p", vm);
    return JNI_VERSION_1_6;
}

MAP_API void miniaudio_player_set_jvm(void *jvm)
{
    if (jvm != NULL)
    {
        g_map_jvm = (JavaVM *)jvm;
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] miniaudio_player_set_jvm called: %p", jvm);
    }
}

typedef struct {
    const char *target_symbol;
    int match_specific_libs;
    void *found_addr;
} map_symbol_search_t;

static int map_android_phdr_callback(struct dl_phdr_info *info, size_t size, void *data)
{
    (void)size;
    map_symbol_search_t *search = (map_symbol_search_t *)data;
    if (search == NULL || search->found_addr != NULL || info->dlpi_name == NULL)
    {
        return 0;
    }

    if (search->match_specific_libs)
    {
        if (strstr(info->dlpi_name, "libart.so") == NULL &&
            strstr(info->dlpi_name, "libnativehelper.so") == NULL &&
            strstr(info->dlpi_name, "libdvm.so") == NULL &&
            strstr(info->dlpi_name, "libandroid_runtime.so") == NULL)
        {
            return 0;
        }
    }

    ElfW(Addr) base = info->dlpi_addr;
    const ElfW(Phdr) *dynamic_phdr = NULL;
    for (int i = 0; i < info->dlpi_phnum; i++)
    {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC)
        {
            dynamic_phdr = &info->dlpi_phdr[i];
            break;
        }
    }
    if (dynamic_phdr == NULL)
    {
        return 0;
    }

    const ElfW(Dyn) *dyn = (const ElfW(Dyn) *)(base + dynamic_phdr->p_vaddr);
    const ElfW(Sym) *symtab = NULL;
    const char *strtab = NULL;
    const uint32_t *hash = NULL;
    const uint32_t *gnu_hash = NULL;

    for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++)
    {
        ElfW(Addr) ptr = d->d_un.d_ptr;
        if (ptr < base)
        {
            ptr += base;
        }
        if (d->d_tag == DT_SYMTAB)
        {
            symtab = (const ElfW(Sym) *)ptr;
        }
        else if (d->d_tag == DT_STRTAB)
        {
            strtab = (const char *)ptr;
        }
        else if (d->d_tag == DT_HASH)
        {
            hash = (const uint32_t *)ptr;
        }
        else if (d->d_tag == DT_GNU_HASH)
        {
            gnu_hash = (const uint32_t *)ptr;
        }
    }

    if (symtab == NULL || strtab == NULL)
    {
        return 0;
    }

    size_t sym_count = 0;
    if (hash != NULL)
    {
        sym_count = hash[1];
    }
    else if (gnu_hash != NULL)
    {
        uint32_t nbuckets = gnu_hash[0];
        uint32_t symoffset = gnu_hash[1];
        uint32_t bloom_size = gnu_hash[2];
        const uint32_t *buckets = (const uint32_t *)((const char *)&gnu_hash[4] + bloom_size * sizeof(ElfW(Addr)));
        const uint32_t *chains = &buckets[nbuckets];
        uint32_t max_chain = 0;
        for (uint32_t b = 0; b < nbuckets; b++)
        {
            if (buckets[b] > max_chain)
            {
                max_chain = buckets[b];
            }
        }
        if (max_chain >= symoffset)
        {
            while (!(chains[max_chain - symoffset] & 1))
            {
                max_chain++;
            }
            sym_count = max_chain + 1;
        }
    }

    for (size_t i = 0; i < sym_count; i++)
    {
        const char *name = strtab + symtab[i].st_name;
        if (strcmp(name, search->target_symbol) == 0)
        {
            search->found_addr = (void *)(base + symtab[i].st_value);
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
                "[JNI] Symbol %s found in %s at %p (base=%p)", search->target_symbol, info->dlpi_name, search->found_addr, (void *)base);
            return 1;
        }
    }

    return 0;
}

static JavaVM *map_android_get_jvm(void)
{
    if (g_map_jvm != NULL)
    {
        return g_map_jvm;
    }

    typedef jint (*GetCreatedJavaVMsFn)(JavaVM **, jsize, jsize *);
    GetCreatedJavaVMsFn pfn = NULL;

    /* 1. Try RTLD_DEFAULT */
    pfn = (GetCreatedJavaVMsFn)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    if (pfn != NULL)
    {
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via RTLD_DEFAULT");
    }

    /* 2. Try libnativehelper.so (public NDK library on Android 12+ / API 31+) */
    if (pfn == NULL)
    {
        void *nh_handle = dlopen("libnativehelper.so", RTLD_NOW);
        if (nh_handle != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)dlsym(nh_handle, "JNI_GetCreatedJavaVMs");
            if (pfn != NULL)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via libnativehelper.so");
            }
        }
        else
        {
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] dlopen(libnativehelper.so) failed: %s", dlerror());
        }
    }

    /* 3. Try dlopen on libart.so */
    if (pfn == NULL)
    {
        void *art_handle = dlopen("libart.so", RTLD_NOW);
        if (art_handle != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)dlsym(art_handle, "JNI_GetCreatedJavaVMs");
            if (pfn != NULL)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via libart.so");
            }
        }
        else
        {
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] dlopen(libart.so) failed: %s", dlerror());
        }
    }

    /* 4. Try dlopen on libdvm.so (older Android Dalvik) */
    if (pfn == NULL)
    {
        void *dvm_handle = dlopen("libdvm.so", RTLD_NOW);
        if (dvm_handle != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)dlsym(dvm_handle, "JNI_GetCreatedJavaVMs");
            if (pfn != NULL)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via libdvm.so");
            }
        }
    }

    /* 5. Try dl_iterate_phdr memory scanning on runtime libraries */
    if (pfn == NULL)
    {
        map_symbol_search_t search;
        search.target_symbol = "JNI_GetCreatedJavaVMs";
        search.match_specific_libs = 1;
        search.found_addr = NULL;
        dl_iterate_phdr(map_android_phdr_callback, &search);
        if (search.found_addr != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)search.found_addr;
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via dl_iterate_phdr (targeted)");
        }
    }

    /* 6. Try dl_iterate_phdr memory scanning on ALL loaded libraries */
    if (pfn == NULL)
    {
        map_symbol_search_t search;
        search.target_symbol = "JNI_GetCreatedJavaVMs";
        search.match_specific_libs = 0;
        search.found_addr = NULL;
        dl_iterate_phdr(map_android_phdr_callback, &search);
        if (search.found_addr != NULL)
        {
            pfn = (GetCreatedJavaVMsFn)search.found_addr;
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Resolved JNI_GetCreatedJavaVMs via dl_iterate_phdr (global)");
        }
    }

    if (pfn != NULL)
    {
        JavaVM *vm = NULL;
        jsize count = 0;
        jint res = pfn(&vm, 1, &count);
        if (res == JNI_OK && count > 0 && vm != NULL)
        {
            g_map_jvm = vm;
            __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully obtained JavaVM: %p (count: %d)", vm, (int)count);
            return g_map_jvm;
        }
        else
        {
            __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] JNI_GetCreatedJavaVMs invocation failed: res=%d, count=%d, vm=%p", (int)res, (int)count, vm);
        }
    }
    else
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not locate JNI_GetCreatedJavaVMs through any resolution strategy");
    }

    return NULL;
}

static const char *map_android_device_type_name(int type)
{
    switch (type)
    {
    case 1:  return "Earpiece";                  /* TYPE_BUILTIN_EARPIECE */
    case 2:  return "Speaker";                   /* TYPE_BUILTIN_SPEAKER */
    case 3:  return "Wired Headset";             /* TYPE_WIRED_HEADSET */
    case 4:  return "Wired Headphones";          /* TYPE_WIRED_HEADPHONES */
    case 5:  return "Line Analog";               /* TYPE_LINE_ANALOG */
    case 6:  return "Line Digital";              /* TYPE_LINE_DIGITAL */
    case 7:  return "Bluetooth Headset";         /* TYPE_BLUETOOTH_SCO */
    case 8:  return "Bluetooth Audio";           /* TYPE_BLUETOOTH_A2DP */
    case 9:  return "HDMI";                      /* TYPE_HDMI */
    case 10: return "HDMI ARC";                  /* TYPE_HDMI_ARC */
    case 11: return "USB Audio Device";          /* TYPE_USB_DEVICE */
    case 12: return "USB Audio Accessory";       /* TYPE_USB_ACCESSORY */
    case 13: return "Dock Audio";                /* TYPE_DOCK */
    case 14: return "FM Radio";                  /* TYPE_FM */
    case 15: return "Built-in Microphone";       /* TYPE_BUILTIN_MIC */
    case 16: return "FM Tuner";                  /* TYPE_FM_TUNER */
    case 17: return "TV Tuner";                  /* TYPE_TV_TUNER */
    case 18: return "Telephony";                 /* TYPE_TELEPHONY */
    case 19: return "AUX Line";                  /* TYPE_AUX_LINE */
    case 20: return "IP Audio";                  /* TYPE_IP */
    case 21: return "Bus Audio";                 /* TYPE_BUS */
    case 22: return "USB Headset";               /* TYPE_USB_HEADSET */
    case 23: return "Hearing Aid";               /* TYPE_HEARING_AID */
    case 24: return "Speaker (Safe)";            /* TYPE_BUILTIN_SPEAKER_SAFE */
    case 25: return "Remote Submix";             /* TYPE_REMOTE_SUBMIX */
    case 26: return "BLE Headset";               /* TYPE_BLE_HEADSET */
    case 27: return "BLE Speaker";               /* TYPE_BLE_SPEAKER */
    case 28: return "Echo Reference";            /* TYPE_ECHO_REFERENCE */
    case 29: return "HDMI eARC";                 /* TYPE_HDMI_EARC */
    case 30: return "BLE Broadcast";             /* TYPE_BLE_BROADCAST */
    case 31: return "Dock Analog";               /* TYPE_DOCK_ANALOG */
    case 32: return "Multichannel Group";        /* TYPE_MULTICHANNEL_GROUP */
    case 33: return "BLE Hearing Aid";           /* TYPE_BLE_HEARING_AID */
    case 34: return "BLE Central";               /* TYPE_BLE_CENTRAL */
    case 35: return "BLE Central Broadcast";     /* TYPE_BLE_CENTRAL_BROADCAST */
    default: return "Audio Output";
    }
}

static int32_t map_android_get_devices(
    miniaudio_device_info_t **out_devices,
    uint32_t *out_count)
{
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] map_android_get_devices: Starting Android audio device query...");

    JavaVM *jvm = map_android_get_jvm();
    if (jvm == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] map_android_get_devices: FAILED: Unable to obtain JavaVM instance");
        return MAP_ERROR_GENERIC;
    }

    JNIEnv *env = NULL;
    jint get_env_res = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    ma_bool32 need_detach = MA_FALSE;

    if (get_env_res == JNI_EDETACHED)
    {
        JavaVMAttachArgs attach_args;
        attach_args.version = JNI_VERSION_1_6;
        attach_args.name = "miniaudio_get_devices";
        attach_args.group = NULL;
        if ((*jvm)->AttachCurrentThread(jvm, &env, &attach_args) != JNI_OK || env == NULL)
        {
            __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] map_android_get_devices: FAILED to attach thread to JavaVM");
            return MAP_ERROR_GENERIC;
        }
        need_detach = MA_TRUE;
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully attached current thread as daemon (env=%p)", env);
    }
    else if (get_env_res != JNI_OK || env == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] GetEnv returned error code %d", get_env_res);
        return MAP_ERROR_GENERIC;
    }
    else
    {
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Current thread already attached to JVM (env=%p)", env);
    }

    int32_t status = MAP_ERROR_GENERIC;
    jclass actThreadCls = NULL;
    jobject context = NULL;
    jclass contextCls = NULL;
    jstring audioServiceStr = NULL;
    jobject audioManager = NULL;
    jclass audioManagerCls = NULL;
    jclass devInfoCls = NULL;
    jclass charSequenceCls = NULL;
    jobjectArray deviceArray = NULL;
    miniaudio_device_info_t *devices = NULL;

    actThreadCls = (*env)->FindClass(env, "android/app/ActivityThread");
    if ((*env)->ExceptionCheck(env) || actThreadCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.app.ActivityThread");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID curAppMethod = (*env)->GetStaticMethodID(env, actThreadCls, "currentApplication", "()Landroid/app/Application;");
    if (!(*env)->ExceptionCheck(env) && curAppMethod != NULL)
    {
        context = (*env)->CallStaticObjectMethod(env, actThreadCls, curAppMethod);
    }
    if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    /* Fallback: currentActivityThread().getApplication() */
    if (context == NULL)
    {
        __android_log_print(ANDROID_LOG_WARN, "miniaudio_player", "[JNI] ActivityThread.currentApplication() returned null, trying currentActivityThread().getApplication()...");
        jmethodID curActThreadMethod = (*env)->GetStaticMethodID(env, actThreadCls, "currentActivityThread", "()Landroid/app/ActivityThread;");
        if (!(*env)->ExceptionCheck(env) && curActThreadMethod != NULL)
        {
            jobject actThreadObj = (*env)->CallStaticObjectMethod(env, actThreadCls, curActThreadMethod);
            if (!(*env)->ExceptionCheck(env) && actThreadObj != NULL)
            {
                jmethodID getAppMethod = (*env)->GetMethodID(env, actThreadCls, "getApplication", "()Landroid/app/Application;");
                if (!(*env)->ExceptionCheck(env) && getAppMethod != NULL)
                {
                    context = (*env)->CallObjectMethod(env, actThreadObj, getAppMethod);
                }
                (*env)->DeleteLocalRef(env, actThreadObj);
            }
        }
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
        }
    }

    if (context == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Failed to obtain Application context from ActivityThread");
        goto cleanup;
    }
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully obtained Application context: %p", context);

    contextCls = (*env)->FindClass(env, "android/content/Context");
    if ((*env)->ExceptionCheck(env) || contextCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.content.Context");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID getSysServiceMethod = (*env)->GetMethodID(env, contextCls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    if ((*env)->ExceptionCheck(env) || getSysServiceMethod == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find getSystemService method");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    audioServiceStr = (*env)->NewStringUTF(env, "audio");
    if ((*env)->ExceptionCheck(env) || audioServiceStr == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] NewStringUTF('audio') failed");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    audioManager = (*env)->CallObjectMethod(env, context, getSysServiceMethod, audioServiceStr);
    if ((*env)->ExceptionCheck(env) || audioManager == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] getSystemService('audio') returned null");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Successfully obtained AudioManager: %p", audioManager);

    audioManagerCls = (*env)->FindClass(env, "android/media/AudioManager");
    if ((*env)->ExceptionCheck(env) || audioManagerCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.media.AudioManager");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID getDevicesMethod = (*env)->GetMethodID(env, audioManagerCls, "getDevices", "(I)[Landroid/media/AudioDeviceInfo;");
    if ((*env)->ExceptionCheck(env) || getDevicesMethod == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] AudioManager.getDevices(int) method not found (requires API 23+)");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    /* 2 = AudioManager.GET_DEVICES_OUTPUTS */
    deviceArray = (jobjectArray)(*env)->CallObjectMethod(env, audioManager, getDevicesMethod, (jint)2);
    if ((*env)->ExceptionCheck(env) || deviceArray == NULL)
    {
        __android_log_print(ANDROID_LOG_WARN, "miniaudio_player", "[JNI] AudioManager.getDevices returned null");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    devInfoCls = (*env)->FindClass(env, "android/media/AudioDeviceInfo");
    if ((*env)->ExceptionCheck(env) || devInfoCls == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] Could not find class android.media.AudioDeviceInfo");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    jmethodID getIdMethod = (*env)->GetMethodID(env, devInfoCls, "getId", "()I");
    jmethodID getTypeMethod = (*env)->GetMethodID(env, devInfoCls, "getType", "()I");
    jmethodID getProductNameMethod = (*env)->GetMethodID(env, devInfoCls, "getProductName", "()Ljava/lang/CharSequence;");

    if ((*env)->ExceptionCheck(env) || getIdMethod == NULL || getTypeMethod == NULL || getProductNameMethod == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] AudioDeviceInfo methods not found");
        (*env)->ExceptionClear(env);
        goto cleanup;
    }

    charSequenceCls = (*env)->FindClass(env, "java/lang/CharSequence");
    jmethodID toStrMethod = NULL;
    if (charSequenceCls != NULL)
    {
        toStrMethod = (*env)->GetMethodID(env, charSequenceCls, "toString", "()Ljava/lang/String;");
    }
    if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    int sdk_version = ma_android_sdk_version();
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Detected Android SDK version: %d", sdk_version);

    /* Query communication device on Android 12+ (API 31+) */
    jint comm_device_id = -1;
    if (sdk_version >= 31)
    {
        jmethodID getCommDevMethod = (*env)->GetMethodID(env, audioManagerCls, "getCommunicationDevice", "()Landroid/media/AudioDeviceInfo;");
        if (!(*env)->ExceptionCheck(env) && getCommDevMethod != NULL)
        {
            jobject commDev = (*env)->CallObjectMethod(env, audioManager, getCommDevMethod);
            if (!(*env)->ExceptionCheck(env) && commDev != NULL)
            {
                comm_device_id = (*env)->CallIntMethod(env, commDev, getIdMethod);
                if ((*env)->ExceptionCheck(env))
                {
                    (*env)->ExceptionClear(env);
                    comm_device_id = -1;
                }
                (*env)->DeleteLocalRef(env, commDev);
            }
        }
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
        }
    }
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Active communication device ID: %d", (int)comm_device_id);

    /* Query wired headset and bluetooth states */
    jboolean is_wired_headset_on = JNI_FALSE;
    jboolean is_bt_a2dp_on = JNI_FALSE;

    jmethodID isWiredHeadsetOnMethod = (*env)->GetMethodID(env, audioManagerCls, "isWiredHeadsetOn", "()Z");
    if (!(*env)->ExceptionCheck(env) && isWiredHeadsetOnMethod != NULL)
    {
        is_wired_headset_on = (*env)->CallBooleanMethod(env, audioManager, isWiredHeadsetOnMethod);
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
            is_wired_headset_on = JNI_FALSE;
        }
    }
    else if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    jmethodID isBtA2dpOnMethod = (*env)->GetMethodID(env, audioManagerCls, "isBluetoothA2dpOn", "()Z");
    if (!(*env)->ExceptionCheck(env) && isBtA2dpOnMethod != NULL)
    {
        is_bt_a2dp_on = (*env)->CallBooleanMethod(env, audioManager, isBtA2dpOnMethod);
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
            is_bt_a2dp_on = JNI_FALSE;
        }
    }
    else if ((*env)->ExceptionCheck(env))
    {
        (*env)->ExceptionClear(env);
    }

    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
        "[JNI] Audio states: wiredHeadsetOn=%d, btA2dpOn=%d",
        (int)is_wired_headset_on, (int)is_bt_a2dp_on);

    jsize raw_count = (*env)->GetArrayLength(env, deviceArray);
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Raw output devices reported by AudioManager: %d", (int)raw_count);

    if (raw_count <= 0)
    {
        *out_devices = NULL;
        *out_count = 0;
        status = MAP_SUCCESS;
        goto cleanup;
    }

    devices = (miniaudio_device_info_t *)calloc((size_t)raw_count, sizeof(miniaudio_device_info_t));
    if (devices == NULL)
    {
        __android_log_print(ANDROID_LOG_ERROR, "miniaudio_player", "[JNI] calloc failed for %d devices", (int)raw_count);
        status = MAP_ERROR_OUT_OF_MEMORY;
        goto cleanup;
    }

    uint32_t valid_count = 0;
    int has_found_default = 0;

    for (jsize i = 0; i < raw_count; ++i)
    {
        jobject devObj = (*env)->GetObjectArrayElement(env, deviceArray, i);
        if (devObj == NULL)
        {
            continue;
        }

        jint dev_id = (*env)->CallIntMethod(env, devObj, getIdMethod);
        jint dev_type = (*env)->CallIntMethod(env, devObj, getTypeMethod);

        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
            (*env)->DeleteLocalRef(env, devObj);
            continue;
        }

        const char *typeFallback = map_android_device_type_name((int)dev_type);

        /* Extract product name */
        char prodNameBuf[256] = {0};
        jobject prodNameObj = (*env)->CallObjectMethod(env, devObj, getProductNameMethod);
        if (!(*env)->ExceptionCheck(env) && prodNameObj != NULL && toStrMethod != NULL)
        {
            jstring nameStr = (jstring)(*env)->CallObjectMethod(env, prodNameObj, toStrMethod);
            if (!(*env)->ExceptionCheck(env) && nameStr != NULL)
            {
                const char *utf = (*env)->GetStringUTFChars(env, nameStr, NULL);
                if (utf != NULL)
                {
                    const char *start = utf;
                    while (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n')
                    {
                        start++;
                    }
                    size_t len = strlen(start);
                    while (len > 0 && (start[len - 1] == ' ' || start[len - 1] == '\t' ||
                                       start[len - 1] == '\r' || start[len - 1] == '\n'))
                    {
                        len--;
                    }
                    if (len > 0 && len < sizeof(prodNameBuf))
                    {
                        memcpy(prodNameBuf, start, len);
                        prodNameBuf[len] = '\0';
                    }
                    (*env)->ReleaseStringUTFChars(env, nameStr, utf);
                }
                (*env)->DeleteLocalRef(env, nameStr);
            }
        }
        if ((*env)->ExceptionCheck(env))
        {
            (*env)->ExceptionClear(env);
        }
        if (prodNameObj != NULL)
        {
            (*env)->DeleteLocalRef(env, prodNameObj);
        }

        /* Format display name */
        if (prodNameBuf[0] != '\0' && strcasecmp(prodNameBuf, "default") != 0)
        {
            snprintf(devices[valid_count].name, sizeof(devices[valid_count].name), "%s (%s)", prodNameBuf, typeFallback);
        }
        else
        {
            snprintf(devices[valid_count].name, sizeof(devices[valid_count].name), "%s", typeFallback);
        }

        /* Device ID formatted as decimal integer string */
        snprintf(devices[valid_count].id, sizeof(devices[valid_count].id), "%d", (int)dev_id);

        /* Default output detection */
        int is_default = 0;
        if (!has_found_default)
        {
            if (comm_device_id >= 0 && dev_id == comm_device_id)
            {
                is_default = 1;
            }
            else
            {
                switch (dev_type)
                {
                case 3:  /* TYPE_WIRED_HEADSET */
                case 4:  /* TYPE_WIRED_HEADPHONES */
                case 22: /* TYPE_USB_HEADSET */
                    is_default = (is_wired_headset_on == JNI_TRUE) ? 1 : 0;
                    break;
                case 8:  /* TYPE_BLUETOOTH_A2DP */
                    is_default = (is_bt_a2dp_on == JNI_TRUE) ? 1 : 0;
                    break;
                case 2:  /* TYPE_BUILTIN_SPEAKER */
                    is_default = (!is_wired_headset_on && !is_bt_a2dp_on) ? 1 : 0;
                    break;
                default:
                    is_default = 0;
                    break;
                }
            }
            if (is_default)
            {
                has_found_default = 1;
            }
        }

        devices[valid_count].is_default = is_default;
        devices[valid_count].is_auto = 0;

        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
            "[JNI] Discovered Audio Output [%u]: id='%s', name='%s', is_default=%d, type=%d (%s)",
            valid_count, devices[valid_count].id, devices[valid_count].name,
            devices[valid_count].is_default, (int)dev_type, typeFallback);

        valid_count++;
        (*env)->DeleteLocalRef(env, devObj);
    }

    if (!has_found_default && valid_count > 0)
    {
        devices[0].is_default = 1;
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
            "[JNI] Default device heuristic did not match; defaulting first device: '%s'", devices[0].name);
    }

    *out_devices = devices;
    *out_count = valid_count;
    status = MAP_SUCCESS;
    __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player",
        "[JNI] map_android_get_devices: Completed successfully, returning %u devices", valid_count);

cleanup:
    if (status != MAP_SUCCESS && devices != NULL)
    {
        free(devices);
        devices = NULL;
    }
    if (deviceArray != NULL)
    {
        (*env)->DeleteLocalRef(env, deviceArray);
    }
    if (charSequenceCls != NULL)
    {
        (*env)->DeleteLocalRef(env, charSequenceCls);
    }
    if (devInfoCls != NULL)
    {
        (*env)->DeleteLocalRef(env, devInfoCls);
    }
    if (audioManagerCls != NULL)
    {
        (*env)->DeleteLocalRef(env, audioManagerCls);
    }
    if (audioManager != NULL)
    {
        (*env)->DeleteLocalRef(env, audioManager);
    }
    if (audioServiceStr != NULL)
    {
        (*env)->DeleteLocalRef(env, audioServiceStr);
    }
    if (contextCls != NULL)
    {
        (*env)->DeleteLocalRef(env, contextCls);
    }
    if (context != NULL)
    {
        (*env)->DeleteLocalRef(env, context);
    }
    if (actThreadCls != NULL)
    {
        (*env)->DeleteLocalRef(env, actThreadCls);
    }

    if (need_detach)
    {
        (*jvm)->DetachCurrentThread(jvm);
        __android_log_print(ANDROID_LOG_DEBUG, "miniaudio_player", "[JNI] Detached current thread from JVM");
    }

    return status;
}

#endif /* __ANDROID__ */

MAP_API int32_t miniaudio_player_get_devices(
    miniaudio_device_info_t **out_devices,
    uint32_t *out_count)
{
    if (out_devices == NULL || out_count == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    *out_devices = NULL;
    *out_count = 0;

#if defined(__ANDROID__)
    int32_t android_res = map_android_get_devices(out_devices, out_count);
    if (android_res == MAP_SUCCESS)
    {
        return MAP_SUCCESS;
    }
    map_log_print(MAP_LOG_LEVEL_WARNING, "android", "JNI device enumeration returned %d, falling back to miniaudio context", android_res);
#endif

    ma_context context;
    ma_result result;
    ma_device_info *pPlaybackInfos;
    ma_uint32 playbackCount = 0;
    ma_device_info *pCaptureInfos;
    ma_uint32 captureCount = 0;
    miniaudio_device_info_t *devices = NULL;

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
/* Silence Detection & Skipping Controls                                     */
/* ========================================================================= */

MAP_API int32_t miniaudio_player_set_silence_config(
    miniaudio_player_t *player,
    const miniaudio_player_silence_config_t *config)
{
    if (player == NULL || config == NULL)
        return MAP_ERROR_INVALID_ARGS;

    if (config->mode < MAP_SILENCE_MODE_DISABLED || config->mode > MAP_SILENCE_MODE_ALL)
        return MAP_ERROR_INVALID_ARGS;

    ma_mutex_lock(&player->lock);

    player->silence_config = *config;
    if (player->silence_config.threshold_db < -90.0f)
        player->silence_config.threshold_db = -90.0f;
    else if (player->silence_config.threshold_db > -10.0f)
        player->silence_config.threshold_db = -10.0f;

    if (player->silence_config.min_silence_duration_ms < 50)
        player->silence_config.min_silence_duration_ms = 50;
    else if (player->silence_config.min_silence_duration_ms > 5000)
        player->silence_config.min_silence_duration_ms = 5000;

    if (player->silence_config.padding_ms > player->silence_config.min_silence_duration_ms / 2)
        player->silence_config.padding_ms = player->silence_config.min_silence_duration_ms / 2;

    if (player->sound_loaded)
    {
        ma_spinlock_lock(&player->stretch_ds.lock);
        map_silence_detector_set_config(&player->stretch_ds.silence, &player->silence_config);
        ma_spinlock_unlock(&player->stretch_ds.lock);
    }

    ma_mutex_unlock(&player->lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_get_silence_config(
    const miniaudio_player_t *player,
    miniaudio_player_silence_config_t *out_config)
{
    miniaudio_player_t *mut_player;
    if (player == NULL || out_config == NULL)
        return MAP_ERROR_INVALID_ARGS;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    *out_config = mut_player->silence_config;
    ma_mutex_unlock(&mut_player->lock);
    return MAP_SUCCESS;
}

MAP_API int64_t miniaudio_player_get_silence_saved_ms(const miniaudio_player_t *player)
{
    miniaudio_player_t *mut_player;
    int64_t saved_ms = 0;
    if (player == NULL)
        return 0;

    mut_player = (miniaudio_player_t *)player;
    ma_mutex_lock(&mut_player->lock);
    if (mut_player->sound_loaded)
    {
        ma_spinlock_lock(&mut_player->stretch_ds.lock);
        saved_ms = map_silence_detector_get_saved_ms(&mut_player->stretch_ds.silence);
        ma_spinlock_unlock(&mut_player->stretch_ds.lock);
    }
    ma_mutex_unlock(&mut_player->lock);
    return saved_ms;
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
    out_status->silence = mut_player->silence_config;
    if (mut_player->sound_loaded)
    {
        ma_spinlock_lock(&mut_player->stretch_ds.lock);
        out_status->silence_saved_ms = map_silence_detector_get_saved_ms(&mut_player->stretch_ds.silence);
        ma_spinlock_unlock(&mut_player->stretch_ds.lock);
    }
    else
    {
        out_status->silence_saved_ms = 0;
    }

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

        if (mut_player->state == MAP_PLAYBACK_STATE_STOPPED)
        {
            out_status->is_completed = 0;
            out_status->is_playing = 0;
            out_status->state = MAP_PLAYBACK_STATE_STOPPED;
        }
        else if (mut_player->state == MAP_PLAYBACK_STATE_PLAYING)
        {
            if (mut_player->is_completed || ma_sound_at_end(&mut_player->sound))
            {
                mut_player->is_completed = 1;
                mut_player->state = MAP_PLAYBACK_STATE_COMPLETED;
                out_status->is_completed = 1;
                out_status->is_playing = 0;
                out_status->state = MAP_PLAYBACK_STATE_COMPLETED;
                out_status->position_ms = mut_player->duration_ms;
            }
            else
            {
                out_status->is_completed = 0;
                out_status->is_playing = ma_sound_is_playing(&mut_player->sound) ? 1 : 0;
                out_status->state = MAP_PLAYBACK_STATE_PLAYING;
            }
        }
        else if (mut_player->state == MAP_PLAYBACK_STATE_COMPLETED)
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
                    if (strcmp(mut_player->current_device.name, devInfo.name) != 0)
                    {
                        strncpy(mut_player->current_device.name, devInfo.name, sizeof(mut_player->current_device.name) - 1);
                        mut_player->current_device.name[sizeof(mut_player->current_device.name) - 1] = '\0';
                        mut_player->device_changed = 1;
                    }
                }
            }
        }
    }
    out_status->device = mut_player->current_device;

    out_status->visualizer_enabled = mut_player->eq_node.visualizer_enabled;
    if (out_status->is_playing && mut_player->eq_node.visualizer_enabled)
    {
        ma_spinlock_lock(&mut_player->eq_node.lock);
        out_status->visualizer = mut_player->eq_node.visualizer_data;
        ma_spinlock_unlock(&mut_player->eq_node.lock);
    }
    else
    {
        memset(&out_status->visualizer, 0, sizeof(out_status->visualizer));
    }

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

MAP_API int32_t miniaudio_player_set_visualizer_enabled(miniaudio_player_t *player, int32_t enabled)
{
    if (player == NULL) return MAP_ERROR_INVALID_ARGS;
    ma_spinlock_lock(&player->eq_node.lock);
    player->eq_node.visualizer_enabled = (enabled != 0) ? 1 : 0;
    if (!player->eq_node.visualizer_enabled)
    {
        memset(&player->eq_node.visualizer_data, 0, sizeof(player->eq_node.visualizer_data));
    }
    ma_spinlock_unlock(&player->eq_node.lock);
    return MAP_SUCCESS;
}

MAP_API int32_t miniaudio_player_is_visualizer_enabled(const miniaudio_player_t *player)
{
    if (player == NULL) return 0;
    return player->eq_node.visualizer_enabled;
}

MAP_API int32_t miniaudio_player_get_visualizer_data(
    const miniaudio_player_t *player,
    miniaudio_player_visualizer_data_t *out_data)
{
    if (player == NULL || out_data == NULL) return MAP_ERROR_INVALID_ARGS;
    miniaudio_player_t *mut_player = (miniaudio_player_t *)player;
    ma_spinlock_lock(&mut_player->eq_node.lock);
    *out_data = mut_player->eq_node.visualizer_data;
    ma_spinlock_unlock(&mut_player->eq_node.lock);
    return MAP_SUCCESS;
}

/* ========================================================================= */
/* Unified Audio Analysis (ReplayGain, Loudness & Waveform)                  */
/* ========================================================================= */

typedef map_biquad_df2t_t map_rg_biquad_t;
#define map_rg_biquad_process map_biquad_df2t_process

MAP_API int32_t miniaudio_player_analyze_audio(
    const char *file_path,
    const miniaudio_audio_analysis_config_t *config,
    miniaudio_audio_analysis_result_t *out_result)
{
    ma_decoder_config decoder_cfg;
    ma_decoder decoder;
    ma_result res;
    ma_uint32 custom_count;
    FILE *f = NULL;
    long file_size = 0;
    uint32_t sample_rate = 0;
    uint32_t flags = MAP_ANALYSIS_FLAG_REPLAY_GAIN | MAP_ANALYSIS_FLAG_WAVEFORM;
    float target_lufs = -18.0f;
    uint32_t waveform_points = 100;
    float *waveform_buf = NULL;
    ma_uint64 total_pcm_frames = 0;
    ma_uint64 total_frames_read = 0;
    float max_peak = 0.0f;
    float buffer[4096 * 2];
    ma_uint64 frames_read = 0;

    /* ReplayGain variables */
    double f0, G, Q, K, Vh, Vb, a0, ra0;
    map_rg_biquad_t hs[2];
    map_rg_biquad_t hp[2];
    size_t samples_per_100ms = 0;
    size_t current_interval_samples = 0;
    double current_interval_sq[2] = {0.0, 0.0};
    size_t capacity = 4096;
    size_t num_intervals = 0;
    float *interval_energies = NULL;
    int ch;

    if (file_path == NULL || file_path[0] == '\0' || out_result == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    memset(out_result, 0, sizeof(*out_result));
    out_result->status = MAP_ERROR_GENERIC;

    if (config != NULL)
    {
        flags = config->flags;
        target_lufs = config->target_lufs;
        waveform_points = config->waveform_points;
    }

    if (target_lufs > 0.0f || target_lufs < -70.0f)
    {
        target_lufs = -18.0f;
    }
    if (waveform_points == 0)
    {
        waveform_points = 100;
    }

    /* Validate file existence and non-zero size */
#if defined(_WIN32)
    wchar_t *wpath = map_utf8_to_wchar(file_path);
    if (wpath == NULL)
    {
        out_result->status = MAP_ERROR_FILE_NOT_FOUND;
        return MAP_ERROR_FILE_NOT_FOUND;
    }
    f = _wfopen(wpath, L"rb");
#else
    f = fopen(file_path, "rb");
#endif
    if (f == NULL)
    {
#if defined(_WIN32)
        free(wpath);
#endif
        out_result->status = MAP_ERROR_FILE_NOT_FOUND;
        return MAP_ERROR_FILE_NOT_FOUND;
    }
    if (fseek(f, 0, SEEK_END) != 0)
    {
        fclose(f);
#if defined(_WIN32)
        free(wpath);
#endif
        out_result->status = MAP_ERROR_DECODE_FAILED;
        return MAP_ERROR_DECODE_FAILED;
    }
    file_size = ftell(f);
    fclose(f);

    if (file_size <= 0)
    {
#if defined(_WIN32)
        free(wpath);
#endif
        out_result->status = MAP_ERROR_DECODE_FAILED;
        return MAP_ERROR_DECODE_FAILED;
    }

    /* Initialize decoder decoding directly to stereo float32 */
    decoder_cfg = ma_decoder_config_init(ma_format_f32, 2, 0);
    custom_count = map_get_custom_decoder_count();
    if (custom_count > 0)
    {
        decoder_cfg.ppCustomBackendVTables = g_map_custom_decoders;
        decoder_cfg.customBackendCount = custom_count;
    }

#if defined(_WIN32)
    res = ma_decoder_init_file_w(wpath, &decoder_cfg, &decoder);
    free(wpath);
#else
    res = ma_decoder_init_file(file_path, &decoder_cfg, &decoder);
#endif

    if (res != MA_SUCCESS)
    {
        out_result->status = MAP_ERROR_DECODE_FAILED;
        return MAP_ERROR_DECODE_FAILED;
    }

    sample_rate = decoder.outputSampleRate;
    if (sample_rate == 0)
    {
        ma_decoder_uninit(&decoder);
        out_result->status = MAP_ERROR_DECODE_FAILED;
        return MAP_ERROR_DECODE_FAILED;
    }

    out_result->sample_rate = sample_rate;
    out_result->channels = decoder.outputChannels;

    /* Get length in frames for waveform splitting */
    ma_decoder_get_length_in_pcm_frames(&decoder, &total_pcm_frames);

    /* Allocate waveform buffer if requested */
    if (flags & MAP_ANALYSIS_FLAG_WAVEFORM)
    {
        waveform_buf = (float *)calloc(waveform_points, sizeof(float));
        if (waveform_buf == NULL)
        {
            ma_decoder_uninit(&decoder);
            out_result->status = MAP_ERROR_OUT_OF_MEMORY;
            return MAP_ERROR_OUT_OF_MEMORY;
        }
    }

    /* Setup ReplayGain filters if requested */
    if (flags & MAP_ANALYSIS_FLAG_REPLAY_GAIN)
    {
        /* Pre-filter Stage 1: High-shelf filter (BS.1770) */
        f0 = 1681.974450955533;
        G = 3.999843853973347;
        Q = 0.7071752369554196;
        K = tan(MA_PI_D * f0 / (double)sample_rate);
        Vh = pow(10.0, G / 20.0);
        Vb = pow(Vh, 0.4996667741545416);
        a0 = 1.0 + K / Q + K * K;

        for (ch = 0; ch < 2; ch++)
        {
            hs[ch].b0 = (float)((Vh + Vb * K / Q + K * K) / a0);
            hs[ch].b1 = (float)(2.0 * (K * K - Vh) / a0);
            hs[ch].b2 = (float)((Vh - Vb * K / Q + K * K) / a0);
            hs[ch].a1 = (float)(2.0 * (K * K - 1.0) / a0);
            hs[ch].a2 = (float)((1.0 - K / Q + K * K) / a0);
            hs[ch].s1 = 0.0f;
            hs[ch].s2 = 0.0f;
        }

        /* RLB Stage 2: High-pass filter (BS.1770) */
        f0 = 38.13547087602444;
        Q = 0.5003270373238773;
        K = tan(MA_PI_D * f0 / (double)sample_rate);
        ra0 = 1.0 + K / Q + K * K;

        for (ch = 0; ch < 2; ch++)
        {
            hp[ch].b0 = 1.0f;
            hp[ch].b1 = -2.0f;
            hp[ch].b2 = 1.0f;
            hp[ch].a1 = (float)(2.0 * (K * K - 1.0) / ra0);
            hp[ch].a2 = (float)((1.0 - K / Q + K * K) / ra0);
            hp[ch].s1 = 0.0f;
            hp[ch].s2 = 0.0f;
        }

        samples_per_100ms = (size_t)(0.1 * sample_rate + 0.5);
        if (samples_per_100ms == 0)
        {
            samples_per_100ms = 1;
        }

        interval_energies = (float *)malloc(capacity * sizeof(float));
        if (interval_energies == NULL)
        {
            if (waveform_buf != NULL) free(waveform_buf);
            ma_decoder_uninit(&decoder);
            out_result->status = MAP_ERROR_OUT_OF_MEMORY;
            return MAP_ERROR_OUT_OF_MEMORY;
        }
    }

    /* Single unified decoding stream loop */
    while (ma_decoder_read_pcm_frames(&decoder, buffer, 4096, &frames_read) == MA_SUCCESS && frames_read > 0)
    {
        ma_uint64 f_idx;
        for (f_idx = 0; f_idx < frames_read; f_idx++)
        {
            ma_uint64 global_frame = total_frames_read + f_idx;
            float s_l = buffer[f_idx * 2 + 0];
            float s_r = buffer[f_idx * 2 + 1];

            float abs_l = fabsf(s_l);
            float abs_r = fabsf(s_r);
            float frame_peak = (abs_l > abs_r) ? abs_l : abs_r;
            if (frame_peak > max_peak) max_peak = frame_peak;

            /* 1. Waveform accumulator */
            if (waveform_buf != NULL && total_pcm_frames > 0)
            {
                size_t pt_idx = (size_t)((double)global_frame * (double)waveform_points / (double)total_pcm_frames);
                if (pt_idx >= waveform_points)
                    pt_idx = waveform_points - 1;
                if (frame_peak > waveform_buf[pt_idx])
                {
                    waveform_buf[pt_idx] = frame_peak;
                }
            }

            /* 2. ReplayGain accumulator */
            if (interval_energies != NULL)
            {
                float y1_l = map_rg_biquad_process(&hs[0], s_l);
                float y2_l = map_rg_biquad_process(&hp[0], y1_l);

                float y1_r = map_rg_biquad_process(&hs[1], s_r);
                float y2_r = map_rg_biquad_process(&hp[1], y1_r);

                current_interval_sq[0] += (double)y2_l * (double)y2_l;
                current_interval_sq[1] += (double)y2_r * (double)y2_r;

                current_interval_samples++;
                if (current_interval_samples >= samples_per_100ms)
                {
                    double interval_e = (current_interval_sq[0] + current_interval_sq[1]) / (double)samples_per_100ms;
                    current_interval_sq[0] = 0.0;
                    current_interval_sq[1] = 0.0;
                    current_interval_samples = 0;

                    if (num_intervals >= capacity)
                    {
                        size_t new_cap = capacity * 2;
                        float *new_buf = (float *)realloc(interval_energies, new_cap * sizeof(float));
                        if (new_buf == NULL)
                        {
                            free(interval_energies);
                            interval_energies = NULL;
                            break;
                        }
                        interval_energies = new_buf;
                        capacity = new_cap;
                    }

                    interval_energies[num_intervals++] = (float)interval_e;
                }
            }
        }
        total_frames_read += frames_read;
    }

    ma_decoder_uninit(&decoder);

    /* Populate basic audio file info */
    out_result->duration_ms = (int64_t)((double)total_frames_read * 1000.0 / (double)sample_rate + 0.5);
    out_result->peak = max_peak;
    if (out_result->duration_ms > 0)
    {
        out_result->bitrate = (uint32_t)(((uint64_t)file_size * 8000) / (uint64_t)out_result->duration_ms);
    }

    /* Finalize Waveform */
    if (waveform_buf != NULL)
    {
        /* Relative normalization to highest peak */
        float max_wf = 0.0f;
        uint32_t i;
        for (i = 0; i < waveform_points; i++)
        {
            if (waveform_buf[i] > max_wf)
                max_wf = waveform_buf[i];
        }
        if (max_wf > 0.0001f)
        {
            for (i = 0; i < waveform_points; i++)
            {
                waveform_buf[i] = waveform_buf[i] / max_wf;
            }
        }

        out_result->has_waveform = 1;
        out_result->waveform.point_count = waveform_points;
        out_result->waveform.points = waveform_buf;
    }

    /* Finalize ReplayGain */
    if (interval_energies != NULL)
    {
        float lufs = -70.0f;
        float gain_db = 0.0f;

        if (current_interval_samples > 0 && num_intervals < capacity)
        {
            double interval_e = (current_interval_sq[0] + current_interval_sq[1]) / (double)current_interval_samples;
            interval_energies[num_intervals++] = (float)interval_e;
        }

        if (num_intervals >= 4)
        {
            size_t num_blocks = num_intervals - 3;
            float *block_energies = (float *)malloc(num_blocks * sizeof(float));
            float *block_loudness = (float *)malloc(num_blocks * sizeof(float));

            if (block_energies != NULL && block_loudness != NULL)
            {
                size_t k;
                double z_unmasked = 0.0;
                size_t count_unmasked = 0;
                float abs_thresh = -70.0f;
                double rel_sum = 0.0;
                size_t count_rel = 0;
                float rel_thresh;
                double z_gated_sum = 0.0;
                size_t count_gated = 0;

                for (k = 0; k < num_blocks; k++)
                {
                    double e4 = (interval_energies[k] + interval_energies[k + 1] + interval_energies[k + 2] + interval_energies[k + 3]) * 0.25;
                    block_energies[k] = (float)e4;
                    if (e4 > 0.0)
                        block_loudness[k] = (float)(-0.691 + 10.0 * log10(e4));
                    else
                        block_loudness[k] = -100.0f;

                    if (block_loudness[k] > abs_thresh)
                    {
                        z_unmasked += e4;
                        count_unmasked++;
                    }
                }

                if (count_unmasked > 0)
                {
                    z_unmasked /= (double)count_unmasked;
                    rel_thresh = (float)(-0.691 + 10.0 * log10(z_unmasked) - 10.0);

                    for (k = 0; k < num_blocks; k++)
                    {
                        if (block_loudness[k] > abs_thresh && block_loudness[k] > rel_thresh)
                        {
                            z_gated_sum += block_energies[k];
                            count_gated++;
                        }
                    }

                    if (count_gated > 0)
                    {
                        double z_final = z_gated_sum / (double)count_gated;
                        lufs = (float)(-0.691 + 10.0 * log10(z_final));
                    }
                    else
                    {
                        lufs = (float)(-0.691 + 10.0 * log10(z_unmasked));
                    }
                }
            }

            if (block_energies != NULL) free(block_energies);
            if (block_loudness != NULL) free(block_loudness);
        }
        else if (num_intervals > 0)
        {
            double total_e = 0.0;
            size_t i;
            for (i = 0; i < num_intervals; i++)
            {
                total_e += interval_energies[i];
            }
            total_e /= (double)num_intervals;
            if (total_e > 0.0)
            {
                lufs = (float)(-0.691 + 10.0 * log10(total_e));
            }
        }

        free(interval_energies);

        if (lufs <= -70.0f)
        {
            gain_db = 0.0f;
        }
        else
        {
            gain_db = target_lufs - lufs;
        }

        out_result->has_replay_gain = 1;
        out_result->replay_gain.gain_db = gain_db;
        out_result->replay_gain.peak = max_peak;
        out_result->replay_gain.lufs = lufs;
    }

    out_result->status = MAP_SUCCESS;
    return MAP_SUCCESS;
}

typedef struct
{
    char *file_path;
    miniaudio_audio_analysis_config_t config;
    miniaudio_audio_analysis_completed_cb on_completed;
    void *user_data;
} map_audio_analysis_task_t;

static ma_thread_result MA_THREADCALL map_audio_analysis_worker_entry(void *pData)
{
    map_audio_analysis_task_t *task = (map_audio_analysis_task_t *)pData;
#if !defined(_WIN32)
    pthread_detach(pthread_self());
#endif
    if (task != NULL)
    {
        miniaudio_audio_analysis_result_t *result =
            (miniaudio_audio_analysis_result_t *)calloc(1, sizeof(miniaudio_audio_analysis_result_t));
        if (result != NULL)
        {
            miniaudio_player_analyze_audio(task->file_path, &task->config, result);
            if (task->on_completed != NULL)
            {
                task->on_completed(result, task->user_data);
            }
            else
            {
                miniaudio_player_free_audio_analysis(result, 1);
            }
        }
        if (task->file_path != NULL)
        {
            free(task->file_path);
        }
        free(task);
    }
    return 0;
}

MAP_API int32_t miniaudio_player_analyze_audio_async(
    const char *file_path,
    const miniaudio_audio_analysis_config_t *config,
    miniaudio_audio_analysis_completed_cb on_completed,
    void *user_data)
{
    map_audio_analysis_task_t *task;
    ma_thread thread;
    ma_result res;
    size_t path_len;

    if (file_path == NULL || file_path[0] == '\0' || on_completed == NULL)
    {
        return MAP_ERROR_INVALID_ARGS;
    }

    task = (map_audio_analysis_task_t *)malloc(sizeof(map_audio_analysis_task_t));
    if (task == NULL)
    {
        return MAP_ERROR_OUT_OF_MEMORY;
    }

    path_len = strlen(file_path);
    task->file_path = (char *)malloc(path_len + 1);
    if (task->file_path == NULL)
    {
        free(task);
        return MAP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(task->file_path, file_path, path_len + 1);

    if (config != NULL)
    {
        task->config = *config;
    }
    else
    {
        task->config.flags = MAP_ANALYSIS_FLAG_REPLAY_GAIN | MAP_ANALYSIS_FLAG_WAVEFORM;
        task->config.target_lufs = -18.0f;
        task->config.waveform_points = 100;
    }
    task->on_completed = on_completed;
    task->user_data = user_data;

    res = ma_thread_create(&thread, ma_thread_priority_normal, 0, map_audio_analysis_worker_entry, task, NULL);
#if defined(_WIN32)
    if (res == MA_SUCCESS)
    {
        CloseHandle((HANDLE)thread);
    }
#endif
    if (res != MA_SUCCESS)
    {
        free(task->file_path);
        free(task);
        return MAP_ERROR_GENERIC;
    }

    return MAP_SUCCESS;
}

MAP_API void miniaudio_player_free_audio_analysis(
    miniaudio_audio_analysis_result_t *result,
    int32_t free_struct)
{
    if (result != NULL)
    {
        if (result->waveform.points != NULL)
        {
            free(result->waveform.points);
            result->waveform.points = NULL;
        }
        if (free_struct)
        {
            free(result);
        }
    }
}

