/**
 * @file map_analysis.h
 * @brief Offline and asynchronous ITU-R BS.1770 LUFS loudness measurement and waveform generation.
 */

#ifndef MAP_ANALYSIS_H
#define MAP_ANALYSIS_H

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_dsp.h"

MAP_API int32_t miniaudio_player_analyze_audio(
    const char *file_path,
    const miniaudio_audio_analysis_config_t *config,
    miniaudio_audio_analysis_result_t *out_result);

MAP_API int32_t miniaudio_player_analyze_audio_async(
    const char *file_path,
    const miniaudio_audio_analysis_config_t *config,
    miniaudio_audio_analysis_completed_cb callback,
    void *user_data);

MAP_API void miniaudio_player_free_audio_analysis(
    miniaudio_audio_analysis_result_t *result,
    int32_t free_struct);

#endif /* MAP_ANALYSIS_H */
