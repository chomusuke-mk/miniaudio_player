/**
 * @file map_dsp.h
 * @brief Equalizer composite node, biquad filters, crossfeed, and limiter DSP pipeline.
 */

#ifndef MAP_DSP_H
#define MAP_DSP_H

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_seqlock.h"
#include "map_reverb.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define MAP_BS2B_DEFAULT_CLEVEL ((uint32_t)700 | ((uint32_t)45 << 16)) /* Moffat-Bauer: 700 Hz, 4.5 dB */
#define MAP_BS2B_CMOY_CLEVEL    ((uint32_t)700 | ((uint32_t)60 << 16)) /* Chu Moy: 700 Hz, 6.0 dB */

/* ========================================================================= */
/* Direct Form II Transposed Biquad Filter                                   */
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
    /* Anti-denormal protection: flush subnormal filter state registers to zero */
    if (fabsf(f->s1) < 1e-20f) f->s1 = 0.0f;
    if (fabsf(f->s2) < 1e-20f) f->s2 = 0.0f;
    return y;
}

void map_biquad_bpf_init(map_biquad_df2t_t *filter, double f0, double fs, double q);

/* ========================================================================= */
/* BS2B Binaural Crossfeed Filter                                            */
/* ========================================================================= */

#define MAP_DSP_STEREO_BLOCK_SIZE 64

typedef struct
{
    uint32_t level;
    uint32_t srate;
    double a0_lo, b1_lo;
    double a0_hi, a1_hi, b1_hi;
    double gain;
    struct { double asis[2], lo[2], hi[2]; } lfs;
    /* 32-bit single-precision float coefficients for fast SIMD crossfeed kernel */
    float a0_lo_f, b1_lo_f;
    float a0_hi_f, a1_hi_f, b1_hi_f;
    float gain_f;
} map_bs2b_t;

void map_bs2b_init(map_bs2b_t *bs2b, uint32_t srate, uint32_t level);
void map_bs2b_process_frames(map_bs2b_t *bs2b, float *pSamples, ma_uint32 frameCount, ma_uint32 channels);

/* ========================================================================= */
/* Equalizer Composite Node                                                  */
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
    int32_t visualizer_enabled;
    map_biquad_df2t_t vis_bpf[10];

    /* Cache-line aligned telemetry section to prevent false sharing with audio processing state */
    MAP_ALIGN_CACHE_LINE miniaudio_player_visualizer_data_t visualizer_data;
    union {
        MAP_ALIGN_CACHE_LINE map_seqlock_t vis_seqlock;
        MAP_ALIGN_CACHE_LINE MA_ATOMIC(4, ma_uint32) vis_seq;
    };

    /* DSP Chain Extensions */
    MAP_ALIGN_CACHE_LINE float preamp_db;
    miniaudio_player_replay_gain_config_t rg_config;
    float current_preamp_linear;
    float target_preamp_linear;

    float balance;
    float current_balance;
    float target_gl;
    float target_gr;
    float current_gl;
    float current_gr;

    int32_t mono_enabled;

    int32_t crossfeed_mode;
    map_bs2b_t bs2b;

    int32_t spatializer_enabled;
    float spatializer_width;

    int32_t reverb_enabled;
    map_reverb_t reverb;

    float current_volume;
    float target_volume;
    float smooth_factor;

    float band_gains[10];

    int32_t limiter_enabled;
} ma_equalizer_node;

float map_calculate_effective_preamp(const miniaudio_player_replay_gain_config_t *rg, float standalone_preamp_db);

ma_result ma_equalizer_node_init(
    ma_node_graph *pNodeGraph,
    ma_uint32 channels,
    ma_uint32 sampleRate,
    ma_equalizer_node *pNode);

void ma_equalizer_node_uninit(ma_equalizer_node *pNode);

void ma_equalizer_node_process_pcm_frames(
    ma_node *pNode,
    const float **ppFramesIn,
    ma_uint32 *pFrameCountIn,
    float **ppFramesOut,
    ma_uint32 *pFrameCountOut);

ma_result ma_equalizer_node_set_band(
    ma_equalizer_node *pEq,
    ma_uint32 bandIndex,
    float gainDB);

ma_result ma_equalizer_node_set_all(
    ma_equalizer_node *pEq,
    const miniaudio_player_equalizer_params_t *pParams);

ma_result ma_equalizer_node_set_sample_rate(
    ma_equalizer_node *pEq,
    ma_uint32 newSampleRate);

#endif /* MAP_DSP_H */
