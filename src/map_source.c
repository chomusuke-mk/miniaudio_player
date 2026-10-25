/**
 * @file map_source.c
 * @brief SPSC ring buffer, Sonic time-stretching, and asynchronous decoding data source implementation.
 */

#include "map_source.h"
#include "map_event_dispatcher.h"

static ma_thread_result MA_THREADCALL map_decoder_worker_entry(void *pData)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pData;
    if (pDS == NULL)
        return (ma_thread_result)0;

    map_disable_denormals();

    while (!ma_atomic_load_32(&pDS->worker_stop))
    {
        ma_uint32 writeFrames = 8192;
        void *pWriteBuf = NULL;
        ma_result res;

        if (ma_atomic_load_32(&pDS->decoder_eof))
        {
            /* Sleep until a seek signals us to resume buffering */
            ma_atomic_store_32(&pDS->worker_is_sleeping, 1);
            ma_event_wait(&pDS->worker_event);
            ma_atomic_store_32(&pDS->worker_is_sleeping, 0);
            if (ma_atomic_load_32(&pDS->worker_stop)) break;
            continue;
        }

        /* Check ring buffer fill level and available write capacity */
        ma_uint32 cap = ma_pcm_rb_get_subbuffer_size(&pDS->rb);
        ma_uint32 fill = ma_pcm_rb_available_read(&pDS->rb);
        ma_uint32 avail_write = ma_pcm_rb_available_write(&pDS->rb);

        if (avail_write == 0)
        {
            /* Ring buffer is completely full; sleep until consumer drops below watermark and signals */
            ma_atomic_store_32(&pDS->worker_is_sleeping, 1);
            ma_event_wait(&pDS->worker_event);
            ma_atomic_store_32(&pDS->worker_is_sleeping, 0);
            if (ma_atomic_load_32(&pDS->worker_stop)) break;
            continue;
        }

        if (cap > 0 && fill >= (cap * 4) / 5)
        {
            /* Buffer fill level is above 80% capacity:
             * Use adaptive backoff sleep (progressive 5-15ms) to yield the CPU,
             * preventing busy spinning and high CPU context switches. */
            ma_uint32 sleep_ms = 10;
            if (fill >= (cap * 95) / 100)
            {
                sleep_ms = 15;
            }
            else if (fill >= (cap * 9) / 10)
            {
                sleep_ms = 10;
            }
            else
            {
                sleep_ms = 5;
            }
            ma_atomic_store_32(&pDS->worker_is_sleeping, 1);
            ma_sleep(sleep_ms);
            ma_atomic_store_32(&pDS->worker_is_sleeping, 0);
            if (ma_atomic_load_32(&pDS->worker_stop)) break;
        }

        res = ma_pcm_rb_acquire_write(&pDS->rb, &writeFrames, &pWriteBuf);
        if (res == MA_SUCCESS && writeFrames > 0)
        {
            ma_uint64 readFromDecoder = 0;
            ma_result decRes;

            ma_mutex_lock(&pDS->decoder_mutex);
            if (ma_atomic_load_32(&pDS->worker_stop))
            {
                ma_mutex_unlock(&pDS->decoder_mutex);
                break;
            }
            decRes = ma_decoder_read_pcm_frames(&pDS->decoder, pWriteBuf, writeFrames, &readFromDecoder);

            ma_bool32 was_aborted = MA_FALSE;
            ma_bool32 is_buffer_eof = MA_FALSE;
            ma_bool32 is_buffer_exhausted = MA_FALSE;

            if (pDS->is_stream)
            {
                ma_mutex_lock(&pDS->buffer.lock);
                was_aborted = pDS->buffer.should_abort;
                is_buffer_eof = pDS->buffer.is_eof;
                if (is_buffer_eof)
                {
                    int64_t end_limit = (pDS->buffer.tail_locked && pDS->buffer.audio_end > 0)
                        ? pDS->buffer.audio_end
                        : pDS->buffer.total_size;
                    if (end_limit > 0 && pDS->buffer.read_cursor >= end_limit)
                    {
                        is_buffer_exhausted = MA_TRUE;
                    }
                    else if (end_limit <= 0 && pDS->buffer.read_cursor >= pDS->buffer.range_end)
                    {
                        is_buffer_exhausted = MA_TRUE;
                    }
                }
                ma_mutex_unlock(&pDS->buffer.lock);
            }

            if (!was_aborted)
            {
                if (readFromDecoder > 0)
                {
                    ma_pcm_rb_commit_write(&pDS->rb, (ma_uint32)readFromDecoder);
                }

                if (pDS->is_stream)
                {
                    if (is_buffer_eof && (decRes == MA_AT_END || (is_buffer_exhausted && readFromDecoder == 0)))
                    {
                        pDS->state = MAP_SOURCE_STATE_DRAINING;
                        ma_atomic_store_32(&pDS->decoder_eof, 1);
                    }
                }
                else if (decRes == MA_AT_END || (decRes != MA_SUCCESS && readFromDecoder == 0))
                {
                    pDS->state = MAP_SOURCE_STATE_DRAINING;
                    ma_atomic_store_32(&pDS->decoder_eof, 1);
                }
            }
            ma_mutex_unlock(&pDS->decoder_mutex);

            if (!was_aborted && pDS->is_stream && !is_buffer_eof && readFromDecoder == 0)
            {
                /* Waiting for more chunks from provider */
                ma_sleep(5);
            }
        }
        else
        {
            /* Ring buffer is full; sleep until consumer signals available space */
            ma_atomic_store_32(&pDS->worker_is_sleeping, 1);
            ma_event_wait(&pDS->worker_event);
            ma_atomic_store_32(&pDS->worker_is_sleeping, 0);
            if (ma_atomic_load_32(&pDS->worker_stop)) break;
        }
    }

    return (ma_thread_result)0;
}

static MA_INLINE void map_time_stretch_ds_check_signal_worker(map_time_stretch_ds *pDS)
{
    if (pDS != NULL && pDS->has_worker)
    {
        /* Lock-free check: only invoke event signal if worker is confirmed waiting */
        if (ma_atomic_load_32(&pDS->worker_is_sleeping) != 0)
        {
            ma_uint32 cap = ma_pcm_rb_get_subbuffer_size(&pDS->rb);
            ma_uint32 fill = ma_pcm_rb_available_read(&pDS->rb);
            /* Watermark hysteresis: signal decode worker only when buffer fill drops below 50% capacity */
            if (cap == 0 || fill < (cap / 2))
            {
                ma_event_signal(&pDS->worker_event);
            }
        }
    }
}

static ma_result map_time_stretch_ds_read_filtered(
    map_time_stretch_ds *pDS,
    float *pFramesOut,
    ma_uint64 framesToRead,
    ma_uint64 *pFramesRead,
    ma_uint64 *pRealFramesRead)
{
    map_silence_detector *pDet = &pDS->silence;
    ma_uint32 channels = pDS->channels;
    ma_uint64 totalRead = 0;
    ma_uint64 realRead = 0;

    if (pFramesRead != NULL)
        *pFramesRead = 0;
    if (pRealFramesRead != NULL)
        *pRealFramesRead = 0;
    if (framesToRead == 0)
        return MA_SUCCESS;

    /* Fast path if silence detection is disabled and no buffered frames */
    if (pDet->config.mode == MAP_SILENCE_MODE_DISABLED &&
        pDet->hold_frames_read_pos >= pDet->hold_frames_count &&
        pDS->rawBufferReadPos >= pDS->rawBufferCount)
    {
        if (pDS->has_worker)
        {
            ma_uint64 fastRead = 0;
            while (fastRead < framesToRead)
            {
                ma_uint32 toRead = (ma_uint32)(framesToRead - fastRead);
                void *pReadBuf = NULL;
                ma_result rbRes = ma_pcm_rb_acquire_read(&pDS->rb, &toRead, &pReadBuf);
                if (rbRes == MA_SUCCESS && toRead > 0)
                {
                    if (pFramesOut != NULL)
                    {
                        memcpy(pFramesOut + fastRead * channels, pReadBuf, toRead * channels * sizeof(float));
                    }
                    ma_pcm_rb_commit_read(&pDS->rb, toRead);
                    fastRead += toRead;
                    continue;
                }
                break;
            }

            if (fastRead > 0)
            {
                if (pFramesRead != NULL) *pFramesRead = fastRead;
                if (pRealFramesRead != NULL) *pRealFramesRead = fastRead;
                map_time_stretch_ds_check_signal_worker(pDS);
                return MA_SUCCESS;
            }
            if (ma_atomic_load_32(&pDS->decoder_eof))
            {
                if (ma_pcm_rb_available_read(&pDS->rb) == 0)
                {
                    pDS->is_eof = MA_TRUE;
                    if (pFramesRead != NULL) *pFramesRead = 0;
                    if (pRealFramesRead != NULL) *pRealFramesRead = 0;
                    return MA_AT_END;
                }
            }

            /* Transient buffer lag / starvation: synthesize silence without blocking RT thread */
            ma_atomic_fetch_add_32(&pDS->underrun_count, 1);
            if (pFramesOut != NULL && framesToRead > 0)
            {
                memset(pFramesOut, 0, framesToRead * channels * sizeof(float));
            }
            if (pFramesRead != NULL) *pFramesRead = framesToRead;
            if (pRealFramesRead != NULL) *pRealFramesRead = 0;
            map_time_stretch_ds_check_signal_worker(pDS);
            return MA_SUCCESS;
        }
        else
        {
            ma_result decRes = ma_decoder_read_pcm_frames(&pDS->decoder, pFramesOut, framesToRead, pFramesRead);
            if (pRealFramesRead != NULL)
            {
                *pRealFramesRead = (pFramesRead != NULL) ? *pFramesRead : 0;
            }
#if defined(__EMSCRIPTEN__)
            if (decRes == MA_BUSY)
            {
                if (pFramesOut != NULL && framesToRead > 0)
                {
                    ma_uint64 done = (pFramesRead != NULL) ? *pFramesRead : 0;
                    if (done < framesToRead)
                    {
                        memset(pFramesOut + done * channels, 0, (framesToRead - done) * channels * sizeof(float));
                    }
                }
                if (pFramesRead != NULL) *pFramesRead = framesToRead;
                return MA_SUCCESS;
            }
#endif
            return decRes;
        }
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
            realRead += to_copy;
            if (pDet->hold_frames_read_pos >= pDet->hold_frames_count)
            {
                pDet->hold_frames_read_pos = 0;
                pDet->hold_frames_count = 0;
            }
            continue;
        }

        /* 2. Replenish rawBuffer from lock-free SPSC ring buffer (or fallback) if empty (NP3-01) */
        if (pDS->rawBufferReadPos >= pDS->rawBufferCount)
        {
            ma_uint32 maxFrames = (channels > 0) ? (pDS->rawBufferCapacity / channels) : 4096;
            if (maxFrames == 0) maxFrames = 4096;
            ma_uint32 framesFetched = 0;

            if (pDS->has_worker)
            {
                ma_uint32 availFrames = maxFrames;
                void *pReadBuf = NULL;
                ma_result rbRes = ma_pcm_rb_acquire_read(&pDS->rb, &availFrames, &pReadBuf);
                if (rbRes == MA_SUCCESS && availFrames > 0)
                {
                    memcpy(pDS->rawBuffer, pReadBuf, availFrames * channels * sizeof(float));
                    ma_pcm_rb_commit_read(&pDS->rb, availFrames);
                    framesFetched = availFrames;
                    map_time_stretch_ds_check_signal_worker(pDS);
                }
                else if (ma_atomic_load_32(&pDS->decoder_eof))
                {
                    if (ma_pcm_rb_available_read(&pDS->rb) == 0)
                    {
                        pDS->is_eof = MA_TRUE;
                    }
                }
                else
                {
                    /* Ring buffer underflow / starvation: synthesize silence without blocking RT thread */
                    ma_uint64 remaining = framesToRead - totalRead;
                    ma_atomic_fetch_add_32(&pDS->underrun_count, 1);
                    if (pFramesOut != NULL && remaining > 0)
                    {
                        memset(pFramesOut + totalRead * channels, 0, remaining * channels * sizeof(float));
                    }
                    totalRead += remaining;
                    map_time_stretch_ds_check_signal_worker(pDS);
                    break;
                }
            }
            else
            {
                ma_uint64 rawRead = 0;
                ma_result res = ma_decoder_read_pcm_frames(&pDS->decoder, pDS->rawBuffer, maxFrames, &rawRead);
                framesFetched = (ma_uint32)rawRead;
#if defined(__EMSCRIPTEN__)
                if (res == MA_BUSY)
                {
                    /* Buffering in web: do not mark is_eof */
                }
                else if (res != MA_SUCCESS || rawRead == 0)
                {
                    pDS->is_eof = MA_TRUE;
                }
#else
                if (res != MA_SUCCESS || rawRead == 0)
                {
                    pDS->is_eof = MA_TRUE;
                }
#endif
            }

            pDS->rawBufferCount = framesFetched;
            pDS->rawBufferReadPos = 0;

            if (framesFetched == 0)
            {
#if defined(__EMSCRIPTEN__)
                if (!pDS->is_eof)
                {
                    ma_uint64 remaining = framesToRead - totalRead;
                    if (pFramesOut != NULL && remaining > 0)
                    {
                        memset(pFramesOut + totalRead * channels, 0, remaining * channels * sizeof(float));
                    }
                    totalRead += remaining;
                    break;
                }
#endif
                if (!pDS->has_worker || ma_atomic_load_32(&pDS->decoder_eof))
                {
                    pDS->is_eof = MA_TRUE;
                }
                /* If we reached EOF while holding silence, discard the held silence (lead-out trim) */
                if (pDS->is_eof && pDet->state == MAP_SILENCE_STATE_HOLDING)
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

            /* Calculate frame peak amplitude using vectorized reduction (NP3-06) */
            float peak = map_frame_peak(frame, channels);

            ma_bool32 is_silent_enter = (peak <= pDet->threshold_amp_linear);
            ma_bool32 is_silent_exit  = (peak <= pDet->threshold_amp_exit);

            /* Check disabled mode: block copy all remaining frames directly */
            if (pDet->config.mode == MAP_SILENCE_MODE_DISABLED)
            {
                ma_uint64 remaining_raw = (ma_uint64)(pDS->rawBufferCount - (pDS->rawBufferReadPos - 1));
                ma_uint64 needed_frames = framesToRead - totalRead;
                ma_uint64 chunk = (remaining_raw < needed_frames) ? remaining_raw : needed_frames;
                if (pFramesOut != NULL && chunk > 0)
                {
                    memcpy(pFramesOut + totalRead * channels, frame, chunk * channels * sizeof(float));
                }
                pDS->rawBufferReadPos += (ma_uint32)(chunk - 1);
                totalRead += chunk;
                realRead += chunk;
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
                ma_uint64 total_len = pDS->totalFrames;
                ma_uint64 cur_cursor = pDS->readCursorFrames + totalRead;
                if (total_len > 0 && cur_cursor + (pDS->sampleRate * 5) >= total_len)
                {
                    body_skip_enabled = MA_TRUE;
                }
            }

            if (!body_skip_enabled)
            {
                ma_uint64 remaining_raw = (ma_uint64)(pDS->rawBufferCount - (pDS->rawBufferReadPos - 1));
                ma_uint64 needed_frames = framesToRead - totalRead;
                ma_uint64 chunk = (remaining_raw < needed_frames) ? remaining_raw : needed_frames;
                if (pFramesOut != NULL && chunk > 0)
                {
                    memcpy(pFramesOut + totalRead * channels, frame, chunk * channels * sizeof(float));
                }
                if (chunk > 0)
                {
                    float *last_frame = frame + (chunk - 1) * channels;
                    for (ma_uint32 c = 0; c < channels && c < 8; c++)
                        pDet->last_sample[c] = last_frame[c];
                }
                pDS->rawBufferReadPos += (ma_uint32)(chunk - 1);
                totalRead += chunk;
                realRead += chunk;
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
                    realRead++;
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
                    realRead++;
                }
            }
        }
    }

    if (pFramesRead != NULL)
    {
        *pFramesRead = totalRead;
    }
    if (pRealFramesRead != NULL)
    {
        *pRealFramesRead = realRead;
    }
    return MA_SUCCESS;
}

ma_result map_time_stretch_ds_read(
    ma_data_source *pDataSource,
    void *pFramesOut,
    ma_uint64 frameCount,
    ma_uint64 *pFramesRead)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    map_silence_detector *pDet;
    ma_uint64 totalFramesOut = 0;
    ma_uint64 realFramesOut = 0;
    double deltaTrackFrames = 0.0;
    float *pOut = (float *)pFramesOut;
    float discardBuf[128 * 8];
    const ma_uint32 maxChunkFrames = 2048;

    if (pDS == NULL)
        return MA_INVALID_ARGS;
    pDet = &pDS->silence;
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
                realFramesOut += (ma_uint64)readCount;
                deltaTrackFrames += (double)readCount * (double)pDS->speed;
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
            ma_uint64 realRead = 0;
            ma_result res = map_time_stretch_ds_read_filtered(
                pDS,
                pOut ? (pOut + totalFramesOut * pDS->channels) : discardBuf,
                framesToRead,
                &directRead,
                &realRead);
            totalFramesOut += directRead;
            realFramesOut += realRead;
            deltaTrackFrames += (double)(pDS->is_stream ? realRead : directRead);
            if (res == MA_AT_END || pDS->is_eof)
            {
                pDS->is_eof = MA_TRUE;
                break;
            }
            if (directRead == 0)
            {
                break;
            }
            continue;
        }

        /* Direct SPSC zero-copy bypass to sonic stream when silence detection is disabled */
        if (pDet->config.mode == MAP_SILENCE_MODE_DISABLED &&
            pDet->hold_frames_read_pos >= pDet->hold_frames_count &&
            pDS->rawBufferReadPos >= pDS->rawBufferCount &&
            pDS->has_worker &&
            pDS->sonic != NULL)
        {
            ma_uint32 toRead = maxChunkFrames;
            void *pReadBuf = NULL;
            ma_result rbRes = ma_pcm_rb_acquire_read(&pDS->rb, &toRead, &pReadBuf);
            if (rbRes == MA_SUCCESS && toRead > 0)
            {
                sonicWriteFloatToStream(pDS->sonic, (const float *)pReadBuf, (int)toRead);
                ma_pcm_rb_commit_read(&pDS->rb, toRead);
                map_time_stretch_ds_check_signal_worker(pDS);
                continue;
            }
            if (ma_atomic_load_32(&pDS->decoder_eof))
            {
                if (ma_pcm_rb_available_read(&pDS->rb) == 0)
                {
                    pDS->is_eof = MA_TRUE;
                    sonicFlushStream(pDS->sonic);
                    if (sonicSamplesAvailable(pDS->sonic) == 0)
                    {
                        break;
                    }
                    continue;
                }
            }
        }

        /* Pull from decoder through silence filter and write to sonic */
        ma_uint64 framesFromDecoder = 0;
        ma_uint64 realFromDecoder = 0;
        ma_result readRes = map_time_stretch_ds_read_filtered(
            pDS,
            pDS->scratchBuffer,
            maxChunkFrames,
            &framesFromDecoder,
            &realFromDecoder);

        if (realFromDecoder > 0 && pDS->sonic != NULL)
        {
            sonicWriteFloatToStream(pDS->sonic, pDS->scratchBuffer, (int)realFromDecoder);
        }

        if (realFromDecoder == 0 && (pDS->sonic == NULL || sonicSamplesAvailable(pDS->sonic) == 0))
        {
            if (readRes == MA_AT_END || pDS->is_eof)
            {
                pDS->is_eof = MA_TRUE;
                pDS->state = MAP_SOURCE_STATE_EOF;
            }
            else
            {
                /* Ring buffer starvation: fill remaining requested frames with silence and break */
                if (pOut != NULL && totalFramesOut < frameCount)
                {
                    memset(pOut + totalFramesOut * pDS->channels, 0, (frameCount - totalFramesOut) * pDS->channels * sizeof(float));
                }
                totalFramesOut = frameCount;
                if (pDS->pDispatcher != NULL && pDS->is_stream && map_buffer_is_starving(&pDS->buffer))
                {
                    map_event_dispatcher_post_buffering(pDS->pDispatcher, 1);
                }
            }
            break;
        }

        if (readRes != MA_SUCCESS || framesFromDecoder == 0)
        {
            if (readRes == MA_AT_END || pDS->is_eof)
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
            else
            {
                break;
            }
        }
    }

    pDS->read_cursor_fraction += deltaTrackFrames;
    ma_uint64 wholeFrames = (ma_uint64)pDS->read_cursor_fraction;
    pDS->readCursorFrames += wholeFrames;
    pDS->read_cursor_fraction -= (double)wholeFrames;

    if (pDS->totalFrames > 0 && pDS->readCursorFrames > pDS->totalFrames)
    {
        pDS->readCursorFrames = pDS->totalFrames;
        pDS->read_cursor_fraction = 0.0;
    }

    if (pDS->pDispatcher != NULL && pDS->sampleRate > 0)
    {
        int64_t pos_ms = (int64_t)((pDS->readCursorFrames * 1000) / pDS->sampleRate);
        map_event_dispatcher_post_position(pDS->pDispatcher, pos_ms);
        int64_t saved_ms = map_silence_detector_get_saved_ms(&pDS->silence);
        map_event_dispatcher_post_silence_saved(pDS->pDispatcher, saved_ms);
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

static void map_time_stretch_ds_prefill_locked(map_time_stretch_ds *pDS, ma_uint32 maxPrefillFrames)
{
    if (pDS == NULL || !pDS->has_worker || maxPrefillFrames == 0)
    {
        return;
    }

    ma_uint32 prefillFrames = maxPrefillFrames;
    void *pPrefillBuf = NULL;
    if (ma_pcm_rb_acquire_write(&pDS->rb, &prefillFrames, &pPrefillBuf) == MA_SUCCESS && prefillFrames > 0)
    {
        ma_bool32 saved_probing = pDS->buffer.is_probing;
        pDS->buffer.is_probing = MA_TRUE;
        ma_uint64 readFrames = 0;
        ma_result decRes = ma_decoder_read_pcm_frames(&pDS->decoder, pPrefillBuf, prefillFrames, &readFrames);
        pDS->buffer.is_probing = saved_probing;

        if (readFrames > 0)
        {
            ma_pcm_rb_commit_write(&pDS->rb, (ma_uint32)readFrames);
        }
        if (pDS->buffer.is_eof && (decRes == MA_AT_END || (decRes == MA_SUCCESS && readFrames == 0)))
        {
            pDS->state = MAP_SOURCE_STATE_DRAINING;
            ma_atomic_store_32(&pDS->decoder_eof, 1);
        }
    }
}

int32_t map_time_stretch_ds_seek_stream(
    map_time_stretch_ds *pDS,
    ma_uint64 targetFrame,
    int64_t newStreamOffset)
{
    if (pDS == NULL || !pDS->is_stream)
    {
        return 0;
    }

    /* Step 1: Signal abort so worker wakes up immediately if blocked in map_buffer_read */
    map_buffer_abort(&pDS->buffer);

    if (pDS->has_worker)
    {
        ma_mutex_lock(&pDS->decoder_mutex);
    }

    /* Step 2: Check RAM cache and update buffer cursor/window atomically */
    ma_bool32 seek_from_start = MA_FALSE;
    int32_t is_cache_hit = map_buffer_try_seek_cached(&pDS->buffer, newStreamOffset, &seek_from_start);

    /* Step 3: Reset or seek decoder (with is_probing=MA_TRUE so main thread NEVER blocks on data_ready_event) */
    pDS->readCursorFrames = targetFrame;
    if (is_cache_hit)
    {
        ma_bool32 saved_probing = pDS->buffer.is_probing;
        pDS->buffer.is_probing = MA_TRUE;
        if (seek_from_start)
        {
            map_decoder_reset_stream(&pDS->decoder, 0, targetFrame);
            if (targetFrame > 0)
            {
                ma_result sres = ma_decoder_seek_to_pcm_frame(&pDS->decoder, targetFrame);
                if (sres != MA_SUCCESS)
                {
                    int64_t fallback_off = (newStreamOffset < pDS->buffer.audio_start)
                        ? pDS->buffer.audio_start
                        : newStreamOffset;
                    pDS->buffer.read_cursor = fallback_off;
                    map_decoder_reset_stream(&pDS->decoder, fallback_off, targetFrame);
                }
            }
        }
        else
        {
            map_decoder_reset_stream(&pDS->decoder, newStreamOffset, targetFrame);
        }
        pDS->buffer.is_probing = saved_probing;
    }
    else
    {
        map_decoder_reset_stream(&pDS->decoder, newStreamOffset, targetFrame);
    }

    /* Step 4: Reset downstream PCM ring buffer, silence detector, and Sonic under spinlock */
    ma_spinlock_lock(&pDS->lock);
    pDS->rawBufferCount = 0;
    pDS->rawBufferReadPos = 0;
    pDS->read_cursor_fraction = 0.0;
    map_silence_detector_reset(&pDS->silence, targetFrame == 0);
    if (pDS->has_worker)
    {
        ma_pcm_rb_reset(&pDS->rb);
    }
    if (pDS->sonic != NULL)
    {
        sonicResetStream(pDS->sonic);
    }
    ma_atomic_store_32(&pDS->decoder_eof, 0);
    pDS->is_eof = MA_FALSE;
    pDS->state = MAP_SOURCE_STATE_DECODING;
    ma_spinlock_unlock(&pDS->lock);

    /* Step 5: On cache hit, prefill initial PCM frames synchronously so RT callback has zero underrun */
    if (is_cache_hit && pDS->has_worker)
    {
        map_time_stretch_ds_prefill_locked(pDS, 2048);
    }

    if (pDS->has_worker)
    {
        ma_mutex_unlock(&pDS->decoder_mutex);
        ma_event_signal(&pDS->worker_event);
    }

    return is_cache_hit;
}

void map_time_stretch_ds_set_speed(map_time_stretch_ds *pDS, float speed)
{
    if (pDS == NULL)
        return;

    ma_spinlock_lock(&pDS->lock);
    pDS->speed = speed;
    if (pDS->sonic != NULL)
    {
        sonicSetSpeed(pDS->sonic, speed);
    }
    ma_spinlock_unlock(&pDS->lock);
}

void map_time_stretch_ds_set_pitch(map_time_stretch_ds *pDS, float pitch)
{
    if (pDS == NULL)
        return;

    ma_spinlock_lock(&pDS->lock);
    pDS->pitch = pitch;
    if (pDS->sonic != NULL)
    {
        sonicSetPitch(pDS->sonic, pitch);
    }
    ma_spinlock_unlock(&pDS->lock);
}

ma_result map_time_stretch_ds_seek(ma_data_source *pDataSource, ma_uint64 frameIndex)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    if (pDS == NULL || !pDS->is_stream)
        return MA_INVALID_ARGS;

    if (frameIndex != 0 && pDS->readCursorFrames == frameIndex && !pDS->is_eof && !ma_atomic_load_32(&pDS->decoder_eof))
    {
        return MA_SUCCESS;
    }

    int64_t seekByte = (frameIndex == 0)
        ? ((pDS->buffer.audio_start > 0) ? pDS->buffer.audio_start : 0)
        : map_decoder_get_stream_seek_byte(&pDS->decoder, frameIndex);
    if (seekByte < 0)
    {
        seekByte = pDS->buffer.read_cursor;
    }

    map_time_stretch_ds_seek_stream(pDS, frameIndex, seekByte);
    return MA_SUCCESS;
}

ma_result map_time_stretch_ds_get_data_format(
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

ma_result map_time_stretch_ds_get_cursor(ma_data_source *pDataSource, ma_uint64 *pCursor)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    if (pDS == NULL || pCursor == NULL)
        return MA_INVALID_ARGS;
    ma_spinlock_lock(&pDS->lock);
    if (pDS->is_eof && pDS->totalFrames > 0)
    {
        *pCursor = pDS->totalFrames;
    }
    else
    {
        *pCursor = pDS->readCursorFrames;
    }
    ma_spinlock_unlock(&pDS->lock);
    return MA_SUCCESS;
}

ma_result map_time_stretch_ds_get_length(ma_data_source *pDataSource, ma_uint64 *pLength)
{
    map_time_stretch_ds *pDS = (map_time_stretch_ds *)pDataSource;
    if (pDS == NULL || pLength == NULL)
        return MA_INVALID_ARGS;
    *pLength = pDS->totalFrames;
    return MA_SUCCESS;
}

ma_result map_time_stretch_ds_set_looping(ma_data_source *pDataSource, ma_bool32 isLooping)
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
    0
};

static ma_result map_time_stretch_ds_finish_init(
    map_time_stretch_ds *pDS,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate)
{
    ma_data_source_config baseConfig;
    ma_result result;

    pDS->state = MAP_SOURCE_STATE_IDLE;
    pDS->channels = targetChannels;
    pDS->sampleRate = targetSampleRate;
    pDS->speed = 1.0f;
    pDS->pitch = 1.0f;
    pDS->is_eof = MA_FALSE;
    pDS->readCursorFrames = 0;
    pDS->read_cursor_fraction = 0.0;
    pDS->totalFrames = 0;
    ma_atomic_store_32(&pDS->underrun_count, 0);
    if (!pDS->is_stream || !pDS->buffer.is_live)
    {
        ma_decoder_get_length_in_pcm_frames(&pDS->decoder, &pDS->totalFrames);
    }

    pDS->sonic = sonicCreateStream((int)targetSampleRate, (int)targetChannels);
    if (pDS->sonic == NULL)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        ma_decoder_uninit(&pDS->decoder);
        return MA_OUT_OF_MEMORY;
    }
    sonicSetQuality(pDS->sonic, 1);

    pDS->scratchCapacity = 8192 * targetChannels;
    pDS->scratchBuffer = (float *)ma_aligned_malloc(pDS->scratchCapacity * sizeof(float), 64, NULL);
    if (pDS->scratchBuffer == NULL)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        sonicDestroyStream(pDS->sonic);
        ma_decoder_uninit(&pDS->decoder);
        return MA_OUT_OF_MEMORY;
    }
    memset(pDS->scratchBuffer, 0, pDS->scratchCapacity * sizeof(float));

    pDS->rawBufferCapacity = 16384 * targetChannels;
    pDS->rawBuffer = (float *)ma_aligned_malloc(pDS->rawBufferCapacity * sizeof(float), 64, NULL);
    if (pDS->rawBuffer == NULL)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        ma_aligned_free(pDS->scratchBuffer, NULL);
        sonicDestroyStream(pDS->sonic);
        ma_decoder_uninit(&pDS->decoder);
        return MA_OUT_OF_MEMORY;
    }
    memset(pDS->rawBuffer, 0, pDS->rawBufferCapacity * sizeof(float));
    pDS->rawBufferCount = 0;
    pDS->rawBufferReadPos = 0;

    /* Pre-allocate buffer headroom to upper bound (65,536 frames) to prevent realloc on RT thread */
    sonicWriteFloatToStream(pDS->sonic, pDS->scratchBuffer, 8192);
    sonicReadFloatFromStream(pDS->sonic, pDS->scratchBuffer, 8192);

    map_silence_detector_init(&pDS->silence, targetChannels, targetSampleRate);

    baseConfig = ma_data_source_config_init();
    baseConfig.vtable = &g_map_time_stretch_ds_vtable;

    result = ma_data_source_init(&baseConfig, &pDS->base);
    if (result != MA_SUCCESS)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        map_silence_detector_uninit(&pDS->silence);
        ma_aligned_free(pDS->rawBuffer, NULL);
        ma_aligned_free(pDS->scratchBuffer, NULL);
        sonicDestroyStream(pDS->sonic);
        ma_decoder_uninit(&pDS->decoder);
        return result;
    }

    /* Initialize decoupled background decoder worker and lock-free SPSC ring buffer (NP3-01) */
    pDS->has_worker = MA_FALSE;
    ma_atomic_store_32(&pDS->worker_is_sleeping, 0);
    ma_atomic_store_32(&pDS->worker_stop, 0);
    ma_atomic_store_32(&pDS->decoder_eof, 0);
    pDS->state = MAP_SOURCE_STATE_DECODING;

#if defined(__EMSCRIPTEN__)
    /* En WebAssembly, el motor completo ya se ejecuta dentro de un Web Worker dedicado.
     * Desactivar el sub-worker pthread evita depender de SharedArrayBuffer (COOP/COEP)
     * y ahorra 163,840 floats (640 KB) del ring buffer intermedio por reproductor. */
#else
    if (ma_pcm_rb_init(ma_format_f32, targetChannels, 65536, NULL, NULL, &pDS->rb) == MA_SUCCESS)
    {
        if (ma_mutex_init(&pDS->decoder_mutex) == MA_SUCCESS)
        {
            if (ma_event_init(&pDS->worker_event) == MA_SUCCESS)
            {
                /* Synchronously prefill up to 4096 initial PCM frames while is_probing is true
                 * so startup is instantaneous with zero initial underruns. */
                ma_uint32 prefillFrames = 4096;
                void *pPrefillBuf = NULL;
                if (ma_pcm_rb_acquire_write(&pDS->rb, &prefillFrames, &pPrefillBuf) == MA_SUCCESS && prefillFrames > 0)
                {
                    ma_uint64 readFrames = 0;
                    ma_result decRes = ma_decoder_read_pcm_frames(&pDS->decoder, pPrefillBuf, prefillFrames, &readFrames);
                    if (readFrames > 0)
                    {
                        ma_pcm_rb_commit_write(&pDS->rb, (ma_uint32)readFrames);
                    }
                    if (pDS->buffer.is_eof && (decRes == MA_AT_END || (decRes == MA_SUCCESS && readFrames == 0)))
                    {
                        pDS->state = MAP_SOURCE_STATE_DRAINING;
                        ma_atomic_store_32(&pDS->decoder_eof, 1);
                    }
                }

                if (ma_thread_create(&pDS->worker_thread, ma_thread_priority_normal, 0, map_decoder_worker_entry, pDS, NULL) == MA_SUCCESS)
                {
                    pDS->has_worker = MA_TRUE;
                }
                else
                {
                    ma_event_uninit(&pDS->worker_event);
                    ma_mutex_uninit(&pDS->decoder_mutex);
                    ma_pcm_rb_uninit(&pDS->rb);
                }
            }
            else
            {
                ma_mutex_uninit(&pDS->decoder_mutex);
                ma_pcm_rb_uninit(&pDS->rb);
            }
        }
        else
        {
            ma_pcm_rb_uninit(&pDS->rb);
        }
    }
#endif

    pDS->is_initialized = MA_TRUE;
    return MA_SUCCESS;
}

ma_result map_time_stretch_ds_init_stream_ex(
    map_time_stretch_ds *pDS,
    const uint8_t *initialData,
    size_t initialDataSize,
    const uint8_t *tailData,
    size_t tailDataSize,
    int64_t totalSize,
    ma_bool32 isLive,
    size_t bufferCapacity,
    int32_t encodingFormat,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate)
{
    ma_result result;
    ma_decoder_config decoder_cfg;
    ma_uint32 custom_count;
    size_t cap = bufferCapacity;

    if (pDS == NULL || initialData == NULL || initialDataSize == 0)
        return MA_INVALID_ARGS;

    struct map_event_dispatcher *saved_disp3 = pDS->pDispatcher;
    memset(pDS, 0, sizeof(*pDS));
    pDS->pDispatcher = saved_disp3;
    pDS->state = MAP_SOURCE_STATE_UNINITIALIZED;

    if (cap == 0)
    {
        cap = 4 * 1024 * 1024; /* Default 4 MB ring buffer */
    }
    {
        map_boundary_info_t binfo;
        size_t initialAudioSize = initialDataSize;
        map_boundary_info_reset(&binfo);
        if (map_sniffer_detect_head_boundary(initialData, initialDataSize, totalSize, &binfo) == MAP_BOUNDARY_FOUND &&
            binfo.audio_start > 0 && (size_t)binfo.audio_start <= initialDataSize)
        {
            initialAudioSize = initialDataSize - (size_t)binfo.audio_start;
        }
        if (cap < initialAudioSize)
        {
            cap = initialAudioSize;
        }
        if (cap < 65536)
        {
            cap = 65536;
        }
    }

    result = map_buffer_init(&pDS->buffer, cap, totalSize, isLive);
    if (result != MA_SUCCESS)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        return result;
    }

    /* Seed initial probe bytes */
    pDS->buffer.is_probing = MA_TRUE;
    pDS->buffer.initial_bytes = initialDataSize;
    result = map_buffer_write(&pDS->buffer, 0, initialData, initialDataSize);
    if (result != MA_SUCCESS)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        map_buffer_uninit(&pDS->buffer);
        return result;
    }

    /* If finite stream was already completely provided in initialData, mark buffer EOF before decoder init */
    if (!isLive && totalSize > 0 && (int64_t)initialDataSize >= totalSize)
    {
        map_buffer_end(&pDS->buffer);
    }

    /* Seed optional tail probe bytes (e.g. MP4 moov atom located at EOF) */
    if (tailData != NULL && tailDataSize > 0)
    {
        map_buffer_set_tail(&pDS->buffer, tailData, tailDataSize);
    }

    pDS->is_stream = MA_TRUE;

    decoder_cfg = ma_decoder_config_init(ma_format_f32, targetChannels, targetSampleRate);
    decoder_cfg.resampling.linear.lpfOrder = MA_MAX_FILTER_ORDER;
    if (encodingFormat > 0)
    {
        decoder_cfg.encodingFormat = (ma_encoding_format)encodingFormat;
    }
    custom_count = map_get_custom_decoder_count();
    if (custom_count > 0)
    {
        decoder_cfg.ppCustomBackendVTables = g_map_custom_decoders;
        decoder_cfg.customBackendCount = custom_count;
    }

    result = map_decoder_init_ex(
        map_buffer_decoder_read,
        map_buffer_decoder_seek,
        map_buffer_decoder_tell,
        &pDS->buffer,
        &decoder_cfg,
        &pDS->decoder);

    if (result != MA_SUCCESS)
    {
        pDS->state = MAP_SOURCE_STATE_ERROR;
        pDS->buffer.is_probing = MA_FALSE;
        map_buffer_uninit(&pDS->buffer);
        pDS->is_stream = MA_FALSE;
        return result;
    }

    result = map_time_stretch_ds_finish_init(pDS, targetChannels, targetSampleRate);
    pDS->buffer.is_probing = MA_FALSE;
    map_buffer_set_decoding_audio(&pDS->buffer, MA_TRUE);
    return result;
}

ma_result map_time_stretch_ds_init_stream(
    map_time_stretch_ds *pDS,
    const uint8_t *initialData,
    size_t initialDataSize,
    int64_t totalSize,
    ma_bool32 isLive,
    size_t bufferCapacity,
    int32_t encodingFormat,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate)
{
    return map_time_stretch_ds_init_stream_ex(
        pDS,
        initialData,
        initialDataSize,
        NULL,
        0,
        totalSize,
        isLive,
        bufferCapacity,
        encodingFormat,
        targetChannels,
        targetSampleRate);
}

ma_result map_time_stretch_ds_stream_feed(
    map_time_stretch_ds *pDS,
    const uint8_t *data,
    size_t size)
{
    if (pDS == NULL || !pDS->is_stream || data == NULL || size == 0)
        return MA_INVALID_ARGS;

    return map_buffer_feed(&pDS->buffer, data, size);
}

ma_result map_time_stretch_ds_stream_flush(
    map_time_stretch_ds *pDS,
    int64_t newStreamOffset)
{
    if (pDS == NULL || !pDS->is_stream)
        return MA_INVALID_ARGS;

    /* Step 1: Signal abort to interrupt any active map_buffer_decoder_read */
    map_buffer_abort(&pDS->buffer);

    /* Step 2: Acquire decoder_mutex. Because should_abort is MA_TRUE,
     * worker is guaranteed to exit ma_decoder_read_pcm_frames with MA_INTERRUPT. */
    if (pDS->has_worker)
    {
        ma_mutex_lock(&pDS->decoder_mutex);

        /* Step 3: Now that worker is NOT decoding, safely flush buffer window */
        map_buffer_flush(&pDS->buffer, newStreamOffset);

        /* Step 4: Reset decoder backend and data converter */
        map_decoder_reset_stream(&pDS->decoder, newStreamOffset, pDS->readCursorFrames);

        /* Step 5: Purge downstream PCM buffers and Sonic state under spinlock */
        ma_spinlock_lock(&pDS->lock);
        pDS->rawBufferCount = 0;
        pDS->rawBufferReadPos = 0;
        pDS->read_cursor_fraction = 0.0;
        map_silence_detector_reset(&pDS->silence, MA_TRUE);
        ma_pcm_rb_reset(&pDS->rb);
        if (pDS->sonic != NULL)
        {
            sonicResetStream(pDS->sonic);
        }
        ma_atomic_store_32(&pDS->decoder_eof, 0);
        pDS->is_eof = MA_FALSE;
        pDS->state = MAP_SOURCE_STATE_DECODING;
        ma_spinlock_unlock(&pDS->lock);

        ma_mutex_unlock(&pDS->decoder_mutex);
        ma_event_signal(&pDS->worker_event);
    }
    else
    {
        map_buffer_flush(&pDS->buffer, newStreamOffset);
        map_decoder_reset_stream(&pDS->decoder, newStreamOffset, pDS->readCursorFrames);

        ma_spinlock_lock(&pDS->lock);
        pDS->rawBufferCount = 0;
        pDS->rawBufferReadPos = 0;
        pDS->read_cursor_fraction = 0.0;
        map_silence_detector_reset(&pDS->silence, MA_TRUE);
        ma_pcm_rb_reset(&pDS->rb);
        if (pDS->sonic != NULL)
        {
            sonicResetStream(pDS->sonic);
        }
        ma_atomic_store_32(&pDS->decoder_eof, 0);
        pDS->is_eof = MA_FALSE;
        pDS->state = MAP_SOURCE_STATE_DECODING;
        ma_spinlock_unlock(&pDS->lock);
    }

    return MA_SUCCESS;
}

ma_result map_time_stretch_ds_stream_end(
    map_time_stretch_ds *pDS)
{
    if (pDS == NULL || !pDS->is_stream)
        return MA_INVALID_ARGS;

    return map_buffer_end(&pDS->buffer);
}

void map_time_stretch_ds_uninit(map_time_stretch_ds *pDS)
{
    if (pDS == NULL || !pDS->is_initialized)
        return;

    if (pDS->has_worker)
    {
        ma_atomic_store_32(&pDS->worker_stop, 1);
        ma_event_signal(&pDS->worker_event);
        if (pDS->is_stream)
        {
            map_buffer_abort(&pDS->buffer);
        }
        ma_thread_wait(&pDS->worker_thread);
        ma_event_uninit(&pDS->worker_event);
        ma_mutex_uninit(&pDS->decoder_mutex);
        ma_pcm_rb_uninit(&pDS->rb);
        pDS->has_worker = MA_FALSE;
    }

    ma_spinlock_lock(&pDS->lock);
    if (pDS->sonic != NULL)
    {
        sonicDestroyStream(pDS->sonic);
        pDS->sonic = NULL;
    }
    ma_decoder_uninit(&pDS->decoder);
    if (pDS->scratchBuffer != NULL)
    {
        ma_aligned_free(pDS->scratchBuffer, NULL);
        pDS->scratchBuffer = NULL;
    }
    if (pDS->rawBuffer != NULL)
    {
        ma_aligned_free(pDS->rawBuffer, NULL);
        pDS->rawBuffer = NULL;
    }
    map_silence_detector_uninit(&pDS->silence);

    if (pDS->is_stream)
    {
        map_buffer_uninit(&pDS->buffer);
        pDS->is_stream = MA_FALSE;
    }

    pDS->state = MAP_SOURCE_STATE_UNINITIALIZED;
    pDS->is_initialized = MA_FALSE;
    ma_spinlock_unlock(&pDS->lock);

    ma_data_source_uninit(&pDS->base);
}

void map_time_stretch_ds_set_dispatcher(
    map_time_stretch_ds *pDS,
    struct map_event_dispatcher *pDispatcher)
{
    if (pDS != NULL)
    {
        pDS->pDispatcher = pDispatcher;
    }
}
