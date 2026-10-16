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
#if !defined(MA_NO_MP3)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_mp3)
        {
            ma_mp3 *pMP3 = (ma_mp3 *)pDecoder->pBackend;
            ma_dr_mp3_reset(&pMP3->dr);
            pMP3->dr.streamStartOffset = (ma_uint64)(newStreamOffset > 0 ? newStreamOffset : 0);
            pMP3->dr.currentPCMFrame = targetFrame;
            return MA_SUCCESS;
        }
#endif
#if !defined(MA_NO_FLAC)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_flac)
        {
            ma_flac *pFlac = (ma_flac *)pDecoder->pBackend;
            if (pFlac->dr != NULL)
            {
                pFlac->dr->currentPCMFrame = targetFrame;
            }
            return MA_SUCCESS;
        }
#endif
#if !defined(MA_NO_WAV)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_wav)
        {
            ma_wav *pWav = (ma_wav *)pDecoder->pBackend;
            pWav->dr.readCursorInPCMFrames = targetFrame;
            return MA_SUCCESS;
        }
#endif
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_stbvorbis)
        {
            ma_stbvorbis *pVorbis = (ma_stbvorbis *)pDecoder->pBackend;
            pVorbis->push.dataSize = 0;
            pVorbis->push.framesConsumed = 0;
            pVorbis->push.framesRemaining = 0;
            return MA_SUCCESS;
        }
    }

    return MA_SUCCESS;
}

