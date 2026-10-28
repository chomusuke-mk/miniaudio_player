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
#include "map_buffer.h"
#include "decoders/aac/miniaudio_aac.h"
#include "decoders/minimp4/minimp4.h"
#if !defined(MA_NO_LIBOPUS)
#include "decoders/libopus/miniaudio_libopus.h"
#endif

#if !defined(MA_NO_THREADING)
ma_result map_thread_create(ma_thread *pThread, map_thread_entry_proc entryProc, void *pData)
{
    return ma_thread_create(pThread, ma_thread_priority_normal, 0, (ma_thread_entry_proc)entryProc, pData, NULL);
}

void map_thread_wait(ma_thread *pThread)
{
    ma_thread_wait(pThread);
}
#endif

ma_result map_decoder_reset_stream(ma_decoder *pDecoder, int64_t newStreamOffset, ma_uint64 targetFrame)
{
    if (pDecoder == NULL)
        return MA_INVALID_ARGS;

    /* 1. Reset data converter and internal caches */
    ma_data_converter_reset(&pDecoder->converter);
    pDecoder->inputCacheRemaining = 0;
    pDecoder->inputCacheConsumed = 0;
    pDecoder->readPointerInPCMFrames = (newStreamOffset == 0) ? 0 : targetFrame;

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
            ma_uint64 actualStart = 0;
            if (pDecoder->pUserData != NULL)
            {
                map_buffer_t *mb = (map_buffer_t *)pDecoder->pUserData;
                if (mb->is_initialized && mb->audio_start > 0)
                {
                    actualStart = (ma_uint64)mb->audio_start;
                    if (newStreamOffset == 0)
                    {
                        mb->read_cursor = mb->audio_start;
                    }
                }
            }
            pMP3->dr.streamStartOffset = (ma_uint64)(newStreamOffset > 0 ? newStreamOffset : actualStart);
            pMP3->dr.streamCursor = pMP3->dr.streamStartOffset;
            pMP3->dr.currentPCMFrame = (newStreamOffset == 0) ? 0 : internalTargetFrame;
            return MA_SUCCESS;
        }
#endif
#if !defined(MA_NO_FLAC)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_flac)
        {
            ma_flac *pFlac = (ma_flac *)pDecoder->pBackend;
            if (pFlac->dr != NULL)
            {
                pFlac->dr->currentPCMFrame = (newStreamOffset == 0) ? 0 : internalTargetFrame;
            }
            return MA_SUCCESS;
        }
#endif
#if !defined(MA_NO_WAV)
        if (pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_wav)
        {
            ma_wav *pWav = (ma_wav *)pDecoder->pBackend;
            ma_uint32 bytesPerFrame = ma_dr_wav_get_bytes_per_pcm_frame(&pWav->dr);
            if (bytesPerFrame == 0)
            {
                bytesPerFrame = 1;
            }
            if (pWav->dr.totalPCMFrameCount > 0 && internalTargetFrame > pWav->dr.totalPCMFrameCount)
            {
                internalTargetFrame = pWav->dr.totalPCMFrameCount;
            }
            int64_t exactOffset = (int64_t)pWav->dr.dataChunkDataPos + (int64_t)(internalTargetFrame * bytesPerFrame);
            if (pWav->onSeek != NULL)
            {
                pWav->onSeek(pWav->pReadSeekTellUserData, exactOffset, ma_seek_origin_start);
            }
            pWav->dr.readCursorInPCMFrames = internalTargetFrame;
            if (pWav->dr.totalPCMFrameCount > internalTargetFrame)
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

            /* Fast Ogg page-header hop when seeking within a contiguous cached buffer:
             * Instead of brute-force decoding Vorbis frames from byte 0, hop OggS page
             * headers (27 + nseg bytes each) to position the stream at the last header
             * page (for target 0) or 2 pages before internalTargetFrame so
             * stb_vorbis_flush_pushdata resyncs CRC on that page and only decodes
             * ~1 page (< 0.1 ms) to reach internalTargetFrame. */
            if (newStreamOffset == 0 && pDecoder->pUserData != NULL)
            {
                map_buffer_t *mb = (map_buffer_t *)pDecoder->pUserData;
                if (mb->is_initialized && mb->container_format == MAP_CONTAINER_OGG_VORBIS &&
                    mb->range_start <= mb->audio_start && mb->audio_start > 0)
                {
                    int64_t page_off = 0;
                    int64_t prev2_off = -1, prev1_off = -1;
                    uint64_t prev2_granule = 0, prev1_granule = 0;
                    int64_t last_hdr_off = -1;
                    uint8_t hdr[27];
                    uint8_t segs[255];
                    size_t got = 0;

                    while (page_off + 27 <= mb->range_end)
                    {
                        if (map_buffer_read(mb, page_off, hdr, 27, &got) != MA_SUCCESS || got != 27)
                            break;
                        if (hdr[0] != 'O' || hdr[1] != 'g' || hdr[2] != 'g' || hdr[3] != 'S' || hdr[4] != 0)
                            break;
                        uint8_t nseg = hdr[26];
                        if (nseg > 0)
                        {
                            if (map_buffer_read(mb, page_off + 27, segs, nseg, &got) != MA_SUCCESS || got != nseg)
                                break;
                        }
                        int64_t body_len = 0;
                        for (uint8_t i = 0; i < nseg; i++)
                        {
                            body_len += segs[i];
                        }
                        int64_t next_off = page_off + 27 + (int64_t)nseg + body_len;
                        uint64_t gpos = (uint64_t)hdr[6] |
                                        ((uint64_t)hdr[7] << 8) |
                                        ((uint64_t)hdr[8] << 16) |
                                        ((uint64_t)hdr[9] << 24) |
                                        ((uint64_t)hdr[10] << 32) |
                                        ((uint64_t)hdr[11] << 40) |
                                        ((uint64_t)hdr[12] << 48) |
                                        ((uint64_t)hdr[13] << 56);

                        if (page_off < mb->audio_start)
                        {
                            last_hdr_off = page_off;
                        }

                        if (internalTargetFrame == 0 && page_off >= mb->audio_start)
                        {
                            break;
                        }

                        if (page_off >= mb->audio_start && gpos != (uint64_t)-1 && gpos >= internalTargetFrame)
                        {
                            break;
                        }

                        if (nseg > 0 && segs[nseg - 1] < 255 && gpos != (uint64_t)-1)
                        {
                            prev2_off = prev1_off;
                            prev2_granule = prev1_granule;
                            prev1_off = page_off;
                            prev1_granule = (page_off < mb->audio_start) ? 0 : gpos;
                        }
                        page_off = next_off;
                    }

                    if (internalTargetFrame == 0 && last_hdr_off >= 0)
                    {
                        mb->read_cursor = last_hdr_off;
                        pVorbis->cursor = 0;
                        if (pVorbis->stb != NULL)
                        {
                            stb_vorbis_flush_pushdata(pVorbis->stb);
                        }
                        return MA_SUCCESS;
                    }
                    else if (prev2_off >= 0 && prev2_granule <= internalTargetFrame)
                    {
                        mb->read_cursor = prev2_off;
                        pVorbis->cursor = prev2_granule;
                        if (pVorbis->stb != NULL)
                        {
                            stb_vorbis_flush_pushdata(pVorbis->stb);
                        }
                        return MA_SUCCESS;
                    }
                    else if (last_hdr_off >= 0)
                    {
                        mb->read_cursor = last_hdr_off;
                        pVorbis->cursor = 0;
                        if (pVorbis->stb != NULL)
                        {
                            stb_vorbis_flush_pushdata(pVorbis->stb);
                        }
                        return MA_SUCCESS;
                    }
                }
            }

            pVorbis->cursor = (newStreamOffset == 0) ? 0 : internalTargetFrame;
            if (pVorbis->stb != NULL)
            {
                stb_vorbis_flush_pushdata(pVorbis->stb);
            }
            return MA_SUCCESS;
        }

#if !defined(MA_NO_LIBOPUS)
        if (ma_decoding_backend_libopus != NULL && pDecoder->pBackendVTable == ma_decoding_backend_libopus)
        {
            ma_libopus *pOpus = (ma_libopus *)pDecoder->pBackend;
            return ma_libopus_reset_stream(pOpus, newStreamOffset, internalTargetFrame);
        }
#endif

        if (ma_decoding_backend_aac != NULL && pDecoder->pBackendVTable == ma_decoding_backend_aac)
        {
            ma_aac *pAac = (ma_aac *)pDecoder->pBackend;
            if (pAac->container == MA_AAC_CONTAINER_MP4)
            {
                ma_aac_flush_decoder(pAac);
                unsigned nominalFrameSamples = (pAac->samplesPerFrame > 0)
                    ? pAac->samplesPerFrame
                    : ((pAac->codec == MA_AAC_CODEC_ALAC) ? 4096 : 1024);
                pAac->mp4CurrentSample = (newStreamOffset == 0) ? 0 : (ma_uint32)(internalTargetFrame / nominalFrameSamples);
                pAac->currentPCMFrame = (newStreamOffset == 0) ? 0 : internalTargetFrame;
                pAac->bufferFrames = 0;
                pAac->bufferIndex = 0;
                return MA_SUCCESS;
            }
            else if (pAac->container == MA_AAC_CONTAINER_ADTS)
            {
                ma_aac_flush_decoder(pAac);
                unsigned nominalFrameSamples = (pAac->samplesPerFrame > 0) ? pAac->samplesPerFrame : 1024;
                unsigned sampleIdx = (newStreamOffset == 0) ? 0 : (unsigned)(internalTargetFrame / nominalFrameSamples);
                pAac->bufferFrames = 0;
                pAac->bufferIndex = 0;
                pAac->adtsCurrentFrame = sampleIdx;
                pAac->currentPCMFrame = (newStreamOffset == 0) ? 0 : internalTargetFrame;
                if (pAac->onSeek != NULL)
                {
                    if (newStreamOffset > 0)
                    {
                        pAac->onSeek(pAac->pReadSeekTellUserData, newStreamOffset, ma_seek_origin_start);
                    }
                    else
                    {
                        pAac->onSeek(pAac->pReadSeekTellUserData, (ma_int64)pAac->adtsDataStartOffset, ma_seek_origin_start);
                    }
                }
                return MA_SUCCESS;
            }
        }
    }

    return MA_SUCCESS;
}

ma_result map_decoder_unlatch_stream_eof(ma_decoder *pDecoder)
{
    if (pDecoder == NULL)
        return MA_INVALID_ARGS;

#if !defined(MA_NO_MP3)
    if (pDecoder->pBackend != NULL && pDecoder->pBackendVTable == &g_ma_decoding_backend_vtable_mp3)
    {
        ma_mp3 *pMP3 = (ma_mp3 *)pDecoder->pBackend;
        pMP3->dr.atEnd = MA_FALSE;
    }
#endif
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
            unsigned nominalFrameSamples = (pAac->samplesPerFrame > 0)
                ? pAac->samplesPerFrame
                : ((pAac->codec == MA_AAC_CODEC_ALAC) ? 4096 : 1024);
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
            unsigned nominalFrameSamples = (pAac->samplesPerFrame > 0)
                ? pAac->samplesPerFrame
                : ((pAac->bufferFrames > 0) ? pAac->bufferFrames : 1024);
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

    /* If the stream starts with an ISO BMFF / MP4 'ftyp' box, only attempt custom
     * backends (AAC / ALAC / Opus-in-MP4). Never fall through to dr_mp3, which could
     * false-match random 0xFF bytes inside an mdat payload when 'moov' is at EOF. */
    if (onRead != NULL && onSeek != NULL)
    {
        unsigned char magic[8];
        size_t bytesRead = 0;
        if (onRead(pDecoder, magic, 8, &bytesRead) == MA_SUCCESS && bytesRead == 8)
        {
            onSeek(pDecoder, 0, ma_seek_origin_start);
            if (magic[4] == 'f' && magic[5] == 't' && magic[6] == 'y' && magic[7] == 'p')
            {
                result = ma_decoder_init_custom__internal(&config, pDecoder);
                if (result != MA_SUCCESS)
                {
                    onSeek(pDecoder, 0, ma_seek_origin_start);
                    ma_data_source_uninit(&pDecoder->ds);
                    return result;
                }
                return ma_decoder__postinit(&config, pDecoder);
            }
        }
        else
        {
            onSeek(pDecoder, 0, ma_seek_origin_start);
        }
    }

    return ma_decoder_init__internal(onRead, onSeek, pUserData, &config, pDecoder);
}
