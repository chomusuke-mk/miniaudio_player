/**
 * @file map_analysis.c
 * @brief Offline and asynchronous ITU-R BS.1770 LUFS loudness measurement and waveform generation.
 */

#include "map_analysis.h"

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

    double waveform_scale = (total_pcm_frames > 0) ? ((double)waveform_points / (double)total_pcm_frames) : 0.0;

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
                size_t pt_idx = (size_t)((double)global_frame * waveform_scale);
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
    map_disable_denormals();
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
