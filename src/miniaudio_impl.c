/**
 * @file miniaudio_impl.c
 * @brief Dedicated translation unit for Miniaudio engine implementation.
 */

#define STB_VORBIS_HEADER_ONLY
#include "decoders/stb_vorbis.c"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-compare"
#endif

#undef STB_VORBIS_HEADER_ONLY
#include "decoders/stb_vorbis.c"

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#include "map_common.h"
#include "decoders/aac/miniaudio_aac.h"
#include "decoders/minimp4/minimp4.h"

ma_result map_thread_create(ma_thread *pThread, map_thread_entry_proc entryProc, void *pData)
{
    return ma_thread_create(pThread, ma_thread_priority_normal, 0, (ma_thread_entry_proc)entryProc, pData, NULL);
}

void map_thread_wait(ma_thread *pThread)
{
    ma_thread_wait(pThread);
}

ma_result map_decoder_reset_stream(ma_decoder *pDecoder, int64_t newStreamOffset, ma_uint64 targetFrame)
{
    if (pDecoder == NULL)
        return MA_INVALID_ARGS;

    /* 1. Reset data converter and internal caches */
    ma_data_converter_reset(&pDecoder->converter);
    pDecoder->inputCacheRemaining = 0;
    pDecoder->inputCacheConsumed = 0;
    pDecoder->readPointerInPCMFrames = targetFrame;

    /* 2. Reset backend if present */
    if (pDecoder->pBackend != NULL)
    {
        ma_uint64 internalTargetFrame = targetFrame;
        ma_uint32 internalSampleRate = 0;
        if (ma_data_source_get_data_format(pDecoder->pBackend, NULL, NULL, &internalSampleRate, NULL, 0) == MA_SUCCESS)
        {
            if (internalSampleRate > 0 && pDecoder->outputSampleRate > 0 && internalSampleRate != pDecoder->outputSampleRate)
            {
                internalTargetFrame = ma_calculate_frame_count_after_resampling(internalSampleRate, pDecoder->outputSampleRate, targetFrame);
            }
        }

#if !defined(MA_NO_MP3)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_mp3)
        {
            ma_mp3 *pMP3 = (ma_mp3 *)pDecoder->pBackend;
            ma_dr_mp3_reset(&pMP3->dr);
            pMP3->dr.streamStartOffset = (ma_uint64)(newStreamOffset > 0 ? newStreamOffset : 0);
            pMP3->dr.streamCursor = pMP3->dr.streamStartOffset;
            pMP3->dr.currentPCMFrame = internalTargetFrame;
            return MA_SUCCESS;
        }
#endif
#if !defined(MA_NO_FLAC)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_flac)
        {
            ma_flac *pFlac = (ma_flac *)pDecoder->pBackend;
            if (pFlac->dr != NULL)
            {
                pFlac->dr->currentPCMFrame = internalTargetFrame;
            }
            return MA_SUCCESS;
        }
#endif
#if !defined(MA_NO_WAV)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_wav)
        {
            ma_wav *pWav = (ma_wav *)pDecoder->pBackend;
            ma_uint32 bytesPerFrame = ma_dr_wav_get_bytes_per_pcm_frame(&pWav->dr);
            pWav->dr.readCursorInPCMFrames = internalTargetFrame;
            if (bytesPerFrame > 0 && pWav->dr.totalPCMFrameCount > internalTargetFrame)
            {
                pWav->dr.bytesRemaining = (pWav->dr.totalPCMFrameCount - internalTargetFrame) * bytesPerFrame;
            }
            else if (pWav->dr.totalPCMFrameCount == 0 && pWav->dr.dataChunkDataSize > 0)
            {
                pWav->dr.bytesRemaining = pWav->dr.dataChunkDataSize;
            }
            else
            {
                pWav->dr.bytesRemaining = 0;
            }
            return MA_SUCCESS;
        }
#endif
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_stbvorbis)
        {
            ma_stbvorbis *pVorbis = (ma_stbvorbis *)pDecoder->pBackend;
            pVorbis->push.dataSize = 0;
            pVorbis->push.framesConsumed = 0;
            pVorbis->push.framesRemaining = 0;
            if (pVorbis->stb != NULL)
            {
                stb_vorbis_flush_pushdata(pVorbis->stb);
            }
            return MA_SUCCESS;
        }

        if (ma_decoding_backend_aac != NULL && pDecoder->pBackendVTable == ma_decoding_backend_aac)
        {
            ma_aac *pAac = (ma_aac *)pDecoder->pBackend;
            if (pAac->container == MA_AAC_CONTAINER_MP4)
            {
                ma_aac_flush_decoder(pAac);
                unsigned nominalFrameSamples = (pAac->codec == MA_AAC_CODEC_ALAC) ? 4096 : 1024;
                pAac->mp4CurrentSample = (ma_uint32)(internalTargetFrame / nominalFrameSamples);
                pAac->currentPCMFrame = internalTargetFrame;
                pAac->bufferFrames = 0;
                pAac->bufferIndex = 0;
                return MA_SUCCESS;
            }
            else if (pAac->container == MA_AAC_CONTAINER_ADTS)
            {
                ma_aac_flush_decoder(pAac);
                pAac->bufferFrames = 0;
                pAac->bufferIndex = 0;
                pAac->currentPCMFrame = internalTargetFrame;
                return MA_SUCCESS;
            }
        }
    }

    return MA_SUCCESS;
}

ma_uint32 map_decoder_get_raw_bytes_per_frame(ma_decoder *pDecoder)
{
    if (pDecoder == NULL)
    {
        return 1;
    }

#if !defined(MA_NO_WAV)
    if (pDecoder->pBackend != NULL && pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_wav)
    {
        ma_wav *pWav = (ma_wav *)pDecoder->pBackend;
        ma_uint32 bpf = ma_dr_wav_get_bytes_per_pcm_frame(&pWav->dr);
        return (bpf > 0) ? bpf : 1;
    }
#endif

    return 1;
}

int64_t map_decoder_get_stream_seek_byte(ma_decoder *pDecoder, ma_uint64 targetFrame)
{
    if (pDecoder == NULL)
    {
        return -1;
    }

    ma_uint64 internalTargetFrame = targetFrame;
    ma_uint32 internalSampleRate = 0;
    if (pDecoder->pBackend != NULL &&
        ma_data_source_get_data_format(pDecoder->pBackend, NULL, NULL, &internalSampleRate, NULL, 0) == MA_SUCCESS)
    {
        if (internalSampleRate > 0 && pDecoder->outputSampleRate > 0 && internalSampleRate != pDecoder->outputSampleRate)
        {
            internalTargetFrame = ma_calculate_frame_count_after_resampling(internalSampleRate, pDecoder->outputSampleRate, targetFrame);
        }
    }

#if !defined(MA_NO_WAV)
    if (pDecoder->pBackend != NULL && pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_wav)
    {
        ma_wav *pWav = (ma_wav *)pDecoder->pBackend;
        ma_uint32 bytesPerFrame = ma_dr_wav_get_bytes_per_pcm_frame(&pWav->dr);
        if (pWav->dr.totalPCMFrameCount > 0 && internalTargetFrame > pWav->dr.totalPCMFrameCount)
        {
            internalTargetFrame = pWav->dr.totalPCMFrameCount;
        }
        return (int64_t)(pWav->dr.dataChunkDataPos + internalTargetFrame * bytesPerFrame);
    }
#endif

#if !defined(MA_NO_MP3)
    if (pDecoder->pBackend != NULL && pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_mp3)
    {
        ma_mp3 *pMp3 = (ma_mp3 *)pDecoder->pBackend;
        if (internalTargetFrame == 0)
        {
            return (int64_t)pMp3->dr.streamStartOffset;
        }
    }
#endif

#if !defined(MA_NO_FLAC)
    if (pDecoder->pBackend != NULL && pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_flac)
    {
        ma_flac *pFlac = (ma_flac *)pDecoder->pBackend;
        if (internalTargetFrame == 0 && pFlac->dr != NULL)
        {
            return (int64_t)pFlac->dr->firstFLACFramePosInBytes;
        }
    }
#endif

    if (ma_decoding_backend_aac != NULL && pDecoder->pBackend != NULL && pDecoder->pBackendVTable == ma_decoding_backend_aac)
    {
        ma_aac *pAac = (ma_aac *)pDecoder->pBackend;
        if (pAac->container == MA_AAC_CONTAINER_MP4 && pAac->pMp4 != NULL)
        {
            MP4D_demux_t *pMp4 = (MP4D_demux_t *)pAac->pMp4;
            unsigned nominalFrameSamples = (pAac->codec == MA_AAC_CODEC_ALAC) ? 4096 : 1024;
            unsigned sampleIdx = (unsigned)(internalTargetFrame / nominalFrameSamples);
            unsigned frameBytes = 0, ts = 0, dur = 0;
            if (sampleIdx < pMp4->track[pAac->mp4AudioTrack].sample_count)
            {
                MP4D_file_offset_t offset = MP4D_frame_offset(pMp4, pAac->mp4AudioTrack, sampleIdx, &frameBytes, &ts, &dur);
                if (offset > 0)
                {
                    return (int64_t)offset;
                }
            }
        }
        else if (pAac->container == MA_AAC_CONTAINER_ADTS)
        {
            unsigned nominalFrameSamples = (pAac->bufferFrames > 0) ? pAac->bufferFrames : 1024;
            unsigned sampleIdx = (unsigned)(internalTargetFrame / nominalFrameSamples);
            if (sampleIdx < pAac->adtsFrameCount && pAac->adtsFrameOffsets != NULL)
            {
                return (int64_t)pAac->adtsFrameOffsets[sampleIdx];
            }
        }
    }

    return -1;
}

int64_t map_decoder_get_audio_data_offset(ma_decoder *pDecoder)
{
    if (pDecoder == NULL)
    {
        return 0;
    }
    int64_t off = map_decoder_get_stream_seek_byte(pDecoder, 0);
    return (off > 0) ? off : 0;
}

ma_result map_decoder_init_ex(
    ma_decoder_read_proc onRead,
    ma_decoder_seek_proc onSeek,
    ma_decoder_tell_proc onTell,
    void *pUserData,
    const ma_decoder_config *pConfig,
    ma_decoder *pDecoder)
{
    ma_decoder_config config;
    ma_result result;

    if (pDecoder == NULL)
    {
        return MA_INVALID_ARGS;
    }

    config = ma_decoder_config_init_copy(pConfig);

    result = ma_decoder__preinit(onRead, onSeek, onTell, pUserData, &config, pDecoder);
    if (result != MA_SUCCESS)
    {
        return result;
    }

    return ma_decoder_init__internal(onRead, onSeek, pUserData, &config, pDecoder);
}
