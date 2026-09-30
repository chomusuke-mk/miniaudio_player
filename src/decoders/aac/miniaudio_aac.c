#ifndef miniaudio_aac_c
#define miniaudio_aac_c

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#if defined(_MSC_VER) && !defined(strdup)
#define strdup _strdup
#endif

#define MINIMP4_IMPLEMENTATION
#include "minimp4.h"
#include "aacdec.h"
#include "alac.h"
#include "miniaudio_aac.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#endif

/*
 * Helix AAC allocator functions
 */
void *helix_malloc(int size)
{
    return malloc((size_t)size);
}

void helix_free(void *ptr)
{
    free(ptr);
}

/*
 * Data Source vtable forward declarations
 */
static ma_result ma_aac_ds_read(ma_data_source *pDataSource, void *pFramesOut, ma_uint64 frameCount, ma_uint64 *pFramesRead)
{
    return ma_aac_read_pcm_frames((ma_aac *)pDataSource, pFramesOut, frameCount, pFramesRead);
}

static ma_result ma_aac_ds_seek(ma_data_source *pDataSource, ma_uint64 frameIndex)
{
    return ma_aac_seek_to_pcm_frame((ma_aac *)pDataSource, frameIndex);
}

static ma_result ma_aac_ds_get_data_format(ma_data_source *pDataSource, ma_format *pFormat, ma_uint32 *pChannels, ma_uint32 *pSampleRate, ma_channel *pChannelMap, size_t channelMapCap)
{
    return ma_aac_get_data_format((ma_aac *)pDataSource, pFormat, pChannels, pSampleRate, pChannelMap, channelMapCap);
}

static ma_result ma_aac_ds_get_cursor(ma_data_source *pDataSource, ma_uint64 *pCursor)
{
    return ma_aac_get_cursor_in_pcm_frames((ma_aac *)pDataSource, pCursor);
}

static ma_result ma_aac_ds_get_length(ma_data_source *pDataSource, ma_uint64 *pLength)
{
    return ma_aac_get_length_in_pcm_frames((ma_aac *)pDataSource, pLength);
}

static ma_data_source_vtable g_ma_aac_ds_vtable = {
    ma_aac_ds_read,
    ma_aac_ds_seek,
    ma_aac_ds_get_data_format,
    ma_aac_ds_get_cursor,
    ma_aac_ds_get_length,
    NULL, /* onSetLooping */
    0     /* flags */
};

/*
 * Stream I/O helpers
 */
static size_t ma_aac_stream_read(ma_aac *pAac, void *buf, size_t size)
{
    if (pAac->pFile != NULL)
    {
        return fread(buf, 1, size, (FILE *)pAac->pFile);
    }
    else if (pAac->onRead != NULL)
    {
        size_t bytesRead = 0;
        ma_result result = pAac->onRead(pAac->pReadSeekTellUserData, buf, size, &bytesRead);
        if (result != MA_SUCCESS)
        {
            return 0;
        }
        return bytesRead;
    }
    return 0;
}

static ma_result ma_aac_stream_seek(ma_aac *pAac, ma_int64 offset, ma_seek_origin origin)
{
    if (pAac->pFile != NULL)
    {
        int whence = SEEK_SET;
        if (origin == ma_seek_origin_current)
            whence = SEEK_CUR;
        else if (origin == ma_seek_origin_end)
            whence = SEEK_END;

#if defined(_WIN32)
        if (_fseeki64((FILE *)pAac->pFile, offset, whence) != 0)
            return MA_ERROR;
#else
        if (fseeko((FILE *)pAac->pFile, (off_t)offset, whence) != 0)
            return MA_ERROR;
#endif
        return MA_SUCCESS;
    }
    else if (pAac->onSeek != NULL)
    {
        return pAac->onSeek(pAac->pReadSeekTellUserData, offset, origin);
    }
    return MA_INVALID_OPERATION;
}

static ma_result ma_aac_stream_tell(ma_aac *pAac, ma_int64 *pCursor)
{
    if (pCursor == NULL)
        return MA_INVALID_ARGS;

    if (pAac->pFile != NULL)
    {
#if defined(_WIN32)
        *pCursor = _ftelli64((FILE *)pAac->pFile);
#else
        *pCursor = ftello((FILE *)pAac->pFile);
#endif
        return (*pCursor >= 0) ? MA_SUCCESS : MA_ERROR;
    }
    else if (pAac->onTell != NULL)
    {
        return pAac->onTell(pAac->pReadSeekTellUserData, pCursor);
    }
    return MA_INVALID_OPERATION;
}

static ma_int64 ma_aac_get_stream_size(ma_aac *pAac)
{
    ma_int64 cur = 0;
    ma_int64 end = 0;
    if (ma_aac_stream_tell(pAac, &cur) != MA_SUCCESS)
        cur = 0;
    if (ma_aac_stream_seek(pAac, 0, ma_seek_origin_end) != MA_SUCCESS)
        return -1;
    if (ma_aac_stream_tell(pAac, &end) != MA_SUCCESS)
        return -1;
    ma_aac_stream_seek(pAac, cur, ma_seek_origin_start);
    return end;
}

static int ma_aac_mp4_read_cb(int64_t offset, void *buffer, size_t size, void *token)
{
    ma_aac *pAac = (ma_aac *)token;
    if (ma_aac_stream_seek(pAac, offset, ma_seek_origin_start) != MA_SUCCESS)
    {
        return 1;
    }
    return (ma_aac_stream_read(pAac, buffer, size) != size);
}

/*
 * PCM buffer conversion helpers
 */
static void ma_aac_store_alac_pcm(ma_aac *pAac, int decodedBytes)
{
    int bytesPerSample = pAac->alacSampleSize / 8;
    ma_uint32 pcmFrames = (ma_uint32)(decodedBytes / (pAac->channels * bytesPerSample));
    ma_uint32 totalSamples = pcmFrames * pAac->channels;

    if (pAac->alacSampleSize == 24)
    {
        const uint8_t *raw = pAac->alacRawBuffer;
        if (pAac->format == ma_format_f32)
        {
            for (ma_uint32 i = 0; i < totalSamples; i++)
            {
                uint8_t b0 = raw[i * 3 + 0];
                uint8_t b1 = raw[i * 3 + 1];
                uint8_t b2 = raw[i * 3 + 2];
                int32_t val = (int32_t)((uint32_t)b0 | ((uint32_t)b1 << 8) | ((uint32_t)b2 << 16));
                if (val & 0x800000)
                    val |= 0xFF000000;
                pAac->floatBuffer[i] = (float)val / 8388608.0f;
            }
        }
        else
        {
            for (ma_uint32 i = 0; i < totalSamples; i++)
            {
                uint8_t b0 = raw[i * 3 + 0];
                uint8_t b1 = raw[i * 3 + 1];
                uint8_t b2 = raw[i * 3 + 2];
                int32_t val = (int32_t)((uint32_t)b0 | ((uint32_t)b1 << 8) | ((uint32_t)b2 << 16));
                if (val & 0x800000)
                    val |= 0xFF000000;
                pAac->shortBuffer[i] = (short)(val >> 8);
            }
        }
    }
    else
    {
        const int16_t *s16 = (const int16_t *)pAac->alacRawBuffer;
        if (pAac->format == ma_format_f32)
        {
            for (ma_uint32 i = 0; i < totalSamples; i++)
            {
                pAac->floatBuffer[i] = (float)s16[i] / 32768.0f;
            }
        }
        else
        {
            memcpy(pAac->shortBuffer, s16, totalSamples * sizeof(short));
        }
    }

    pAac->bufferFrames = pcmFrames;
    pAac->bufferIndex = 0;
}

static void ma_aac_store_helix_pcm(ma_aac *pAac, int outputSamps)
{
    ma_uint32 pcmFrames = (ma_uint32)(outputSamps / pAac->channels);
    ma_uint32 totalSamples = (ma_uint32)outputSamps;

    if (pAac->format == ma_format_f32)
    {
        for (ma_uint32 i = 0; i < totalSamples; i++)
        {
            pAac->floatBuffer[i] = (float)pAac->shortBuffer[i] / 32768.0f;
        }
    }

    pAac->bufferFrames = pcmFrames;
    pAac->bufferIndex = 0;
}

/*
 * Internal initialization and parsing
 */
static ma_result ma_aac_init_internal(const ma_decoding_backend_config *pConfig, ma_aac *pAac)
{
    ma_data_source_config dsConfig;
    ma_int64 fileSize;
    uint8_t header[16];
    size_t headerBytes;
    static const int sample_rates[16] = {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0};

    if (pAac == NULL)
        return MA_INVALID_ARGS;

    pAac->format = ma_format_f32;
    if (pConfig != NULL && (pConfig->preferredFormat == ma_format_f32 || pConfig->preferredFormat == ma_format_s16))
    {
        pAac->format = pConfig->preferredFormat;
    }

    dsConfig = ma_data_source_config_init();
    dsConfig.vtable = &g_ma_aac_ds_vtable;
    if (ma_data_source_init(&dsConfig, &pAac->ds) != MA_SUCCESS)
    {
        return MA_ERROR;
    }

    fileSize = ma_aac_get_stream_size(pAac);
    if (fileSize <= 0)
    {
        return MA_INVALID_FILE;
    }

    if (ma_aac_stream_seek(pAac, 0, ma_seek_origin_start) != MA_SUCCESS)
    {
        return MA_INVALID_FILE;
    }

    headerBytes = ma_aac_stream_read(pAac, header, sizeof(header));
    if (headerBytes < 8)
    {
        return MA_INVALID_FILE;
    }
    ma_aac_stream_seek(pAac, 0, ma_seek_origin_start);

    /* 1. Try MP4 / M4A container if header has 'ftyp' */
    if (header[4] == 'f' && header[5] == 't' && header[6] == 'y' && header[7] == 'p')
    {
        MP4D_demux_t *pMp4 = (MP4D_demux_t *)malloc(sizeof(MP4D_demux_t));
        int audioTrack = -1;

        if (pMp4 == NULL)
            return MA_OUT_OF_MEMORY;
        memset(pMp4, 0, sizeof(*pMp4));

        if (!MP4D_open(pMp4, ma_aac_mp4_read_cb, pAac, (int64_t)fileSize))
        {
            free(pMp4);
            return MA_INVALID_FILE;
        }

        for (unsigned i = 0; i < pMp4->track_count; i++)
        {
            if (pMp4->track[i].handler_type == MP4D_HANDLER_TYPE_SOUN ||
                pMp4->track[i].object_type_indication == 0x40 ||
                pMp4->track[i].object_type_indication == 0xC0)
            {
                audioTrack = (int)i;
                break;
            }
        }

        if (audioTrack < 0 || pMp4->track[audioTrack].sample_count == 0)
        {
            MP4D_close(pMp4);
            free(pMp4);
            return MA_INVALID_FILE;
        }

        /* Check whether track is ALAC */
        if (pMp4->track[audioTrack].object_type_indication == 0xC0 ||
            (pMp4->track[audioTrack].dsi && pMp4->track[audioTrack].dsi_bytes == 24))
        {
            uint8_t *cookie = pMp4->track[audioTrack].dsi;
            int bitDepth = cookie[5];
            int channels = cookie[9];
            uint32_t sampleRate = (uint32_t)(((uint32_t)cookie[20] << 24) | ((uint32_t)cookie[21] << 16) | ((uint32_t)cookie[22] << 8) | (uint32_t)cookie[23]);
            uint32_t maxSamples = (uint32_t)(((uint32_t)cookie[0] << 24) | ((uint32_t)cookie[1] << 16) | ((uint32_t)cookie[2] << 8) | (uint32_t)cookie[3]);
            unsigned frameBytes = 0, ts = 0, dur = 0;
            MP4D_file_offset_t offset;
            uint8_t *frameData;
            int decodedBytes = 0;

            if (maxSamples == 0)
                maxSamples = 4096;

            pAac->codec = MA_AAC_CODEC_ALAC;
            pAac->container = MA_AAC_CONTAINER_MP4;
            pAac->pMp4 = pMp4;
            pAac->mp4AudioTrack = (ma_uint32)audioTrack;
            pAac->channels = (ma_uint32)(channels ? channels : 2);
            pAac->sampleRate = sampleRate ? sampleRate : 44100;
            pAac->alacSampleSize = bitDepth ? bitDepth : 16;

            pAac->pAlac = alac_create(pAac->alacSampleSize, (int)pAac->channels);
            if (pAac->pAlac == NULL)
            {
                MP4D_close(pMp4);
                free(pMp4);
                return MA_OUT_OF_MEMORY;
            }
            alac_set_info_cookie((alac_file *)pAac->pAlac, cookie);

            pAac->alacRawBuffer = (uint8_t *)malloc(maxSamples * pAac->channels * (pAac->alacSampleSize / 8));
            if (pAac->alacRawBuffer == NULL)
            {
                alac_free((alac_file *)pAac->pAlac);
                pAac->pAlac = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_OUT_OF_MEMORY;
            }

            /* Decode sample 0 to initialize state */
            offset = MP4D_frame_offset(pMp4, audioTrack, 0, &frameBytes, &ts, &dur);
            frameData = (uint8_t *)malloc(frameBytes);
            if (frameData == NULL)
            {
                free(pAac->alacRawBuffer);
                pAac->alacRawBuffer = NULL;
                alac_free((alac_file *)pAac->pAlac);
                pAac->pAlac = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_OUT_OF_MEMORY;
            }

            ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
            if (ma_aac_stream_read(pAac, frameData, frameBytes) != frameBytes)
            {
                free(frameData);
                free(pAac->alacRawBuffer);
                pAac->alacRawBuffer = NULL;
                alac_free((alac_file *)pAac->pAlac);
                pAac->pAlac = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_INVALID_FILE;
            }

            alac_decode_frame((alac_file *)pAac->pAlac, frameData, pAac->alacRawBuffer, &decodedBytes);
            free(frameData);

            if (decodedBytes <= 0)
            {
                free(pAac->alacRawBuffer);
                pAac->alacRawBuffer = NULL;
                alac_free((alac_file *)pAac->pAlac);
                pAac->pAlac = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_INVALID_FILE;
            }

            ma_aac_store_alac_pcm(pAac, decodedBytes);
            pAac->mp4CurrentSample = 1;
            pAac->currentPCMFrame = 0;
            pAac->totalPCMFrameCount = (ma_uint64)pMp4->track[audioTrack].sample_count * pAac->bufferFrames;

            return MA_SUCCESS;
        }

        /* AAC in MP4 */
        {
            AACFrameInfo aacInfo;
            unsigned frameBytes = 0, ts = 0, dur = 0;
            MP4D_file_offset_t offset;
            uint8_t *frameData;
            uint8_t *inPtr;
            int bytesLeft;
            int err;
            AACFrameInfo curInfo;

            pAac->hDecoder = AACInitDecoder();
            if (pAac->hDecoder == NULL)
            {
                MP4D_close(pMp4);
                free(pMp4);
                return MA_OUT_OF_MEMORY;
            }

            memset(&aacInfo, 0, sizeof(aacInfo));
            aacInfo.nChans = 2;
            aacInfo.sampRateCore = (int)pMp4->track[audioTrack].timescale;
            if (aacInfo.sampRateCore == 0)
                aacInfo.sampRateCore = 44100;
            aacInfo.profile = AAC_PROFILE_LC;

            if (pMp4->track[audioTrack].dsi && pMp4->track[audioTrack].dsi_bytes >= 2)
            {
                uint8_t *dsi = pMp4->track[audioTrack].dsi;
                int sfi = ((dsi[0] & 7) << 1) | ((dsi[1] >> 7) & 1);
                int ch = (dsi[1] >> 3) & 0xF;
                int rate = (sfi < 16) ? sample_rates[sfi] : aacInfo.sampRateCore;
                if (ch > 0)
                    aacInfo.nChans = ch;
                if (rate > 0)
                    aacInfo.sampRateCore = rate;
            }
            AACSetRawBlockParams((HAACDecoder)pAac->hDecoder, 0, &aacInfo);

            /* Decode sample 0 */
            offset = MP4D_frame_offset(pMp4, audioTrack, 0, &frameBytes, &ts, &dur);
            frameData = (uint8_t *)malloc(frameBytes);
            if (frameData == NULL)
            {
                AACFreeDecoder((HAACDecoder)pAac->hDecoder);
                pAac->hDecoder = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_OUT_OF_MEMORY;
            }

            ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
            if (ma_aac_stream_read(pAac, frameData, frameBytes) != frameBytes)
            {
                free(frameData);
                AACFreeDecoder((HAACDecoder)pAac->hDecoder);
                pAac->hDecoder = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_INVALID_FILE;
            }

            inPtr = frameData;
            bytesLeft = (int)frameBytes;
            err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->shortBuffer);
            free(frameData);
            if (err != 0)
            {
                AACFreeDecoder((HAACDecoder)pAac->hDecoder);
                pAac->hDecoder = NULL;
                MP4D_close(pMp4);
                free(pMp4);
                return MA_INVALID_FILE;
            }

            AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
            pAac->codec = MA_AAC_CODEC_AAC;
            pAac->container = MA_AAC_CONTAINER_MP4;
            pAac->pMp4 = pMp4;
            pAac->mp4AudioTrack = (ma_uint32)audioTrack;
            pAac->channels = (ma_uint32)curInfo.nChans;
            pAac->sampleRate = (ma_uint32)curInfo.sampRateOut;

            ma_aac_store_helix_pcm(pAac, curInfo.outputSamps);
            pAac->mp4CurrentSample = 1;
            pAac->currentPCMFrame = 0;
            pAac->totalPCMFrameCount = (ma_uint64)pMp4->track[audioTrack].sample_count * pAac->bufferFrames;

            return MA_SUCCESS;
        }
    }

    /* 2. Try ADTS stream (.aac) */
    {
        ma_uint64 offset = 0;
        ma_uint32 cap = 2048;
        uint8_t syncHdr[7];
        uint32_t f0_offset;
        uint32_t f0_len;
        uint8_t *frameData;
        uint8_t *inPtr;
        int bytesLeft;
        int err;
        AACFrameInfo curInfo;

        /* Skip ID3 tag if present */
        if (header[0] == 'I' && header[1] == 'D' && header[2] == '3')
        {
            offset = 10 + (ma_uint64)(((header[6] & 0x7F) << 21) |
                                      ((header[7] & 0x7F) << 14) |
                                      ((header[8] & 0x7F) << 7) |
                                      (header[9] & 0x7F));
        }

        pAac->adtsDataStartOffset = offset;
        pAac->adtsFileSize = (ma_uint64)fileSize;

        /* Verify syncword at start offset */
        ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, syncHdr, 7) != 7 || syncHdr[0] != 0xFF || (syncHdr[1] & 0xF0) != 0xF0)
        {
            return MA_INVALID_FILE;
        }

        pAac->adtsFrameOffsets = (ma_uint32 *)malloc(cap * sizeof(ma_uint32));
        if (pAac->adtsFrameOffsets == NULL)
        {
            return MA_OUT_OF_MEMORY;
        }
        pAac->adtsFrameCount = 0;

        /* Scan ADTS frame headers */
        while (offset + 7 <= pAac->adtsFileSize)
        {
            ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
            if (ma_aac_stream_read(pAac, syncHdr, 7) != 7)
                break;

            if (syncHdr[0] == 0xFF && (syncHdr[1] & 0xF0) == 0xF0)
            {
                int frameLen = ((syncHdr[3] & 3) << 11) | (syncHdr[4] << 3) | ((syncHdr[5] & 0xE0) >> 5);
                if (frameLen < 7)
                    break;

                if (pAac->adtsFrameCount >= cap)
                {
                    cap *= 2;
                    ma_uint32 *newOffsets = (ma_uint32 *)realloc(pAac->adtsFrameOffsets, cap * sizeof(ma_uint32));
                    if (newOffsets == NULL)
                    {
                        free(pAac->adtsFrameOffsets);
                        pAac->adtsFrameOffsets = NULL;
                        return MA_OUT_OF_MEMORY;
                    }
                    pAac->adtsFrameOffsets = newOffsets;
                }
                pAac->adtsFrameOffsets[pAac->adtsFrameCount++] = (ma_uint32)offset;
                offset += (ma_uint64)frameLen;
            }
            else
            {
                offset++;
            }
        }

        if (pAac->adtsFrameCount == 0)
        {
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_INVALID_FILE;
        }

        pAac->hDecoder = AACInitDecoder();
        if (pAac->hDecoder == NULL)
        {
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_OUT_OF_MEMORY;
        }

        /* Decode frame 0 to get parameters */
        f0_offset = pAac->adtsFrameOffsets[0];
        f0_len = (pAac->adtsFrameCount > 1) ? (pAac->adtsFrameOffsets[1] - f0_offset) : (uint32_t)(pAac->adtsFileSize - f0_offset);
        frameData = (uint8_t *)malloc(f0_len);
        if (frameData == NULL)
        {
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            pAac->hDecoder = NULL;
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_OUT_OF_MEMORY;
        }

        ma_aac_stream_seek(pAac, f0_offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, frameData, f0_len) != f0_len)
        {
            free(frameData);
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            pAac->hDecoder = NULL;
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_INVALID_FILE;
        }

        inPtr = frameData;
        bytesLeft = (int)f0_len;
        err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->shortBuffer);
        free(frameData);
        if (err != 0)
        {
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            pAac->hDecoder = NULL;
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_INVALID_FILE;
        }

        AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
        pAac->codec = MA_AAC_CODEC_AAC;
        pAac->container = MA_AAC_CONTAINER_ADTS;
        pAac->channels = (ma_uint32)curInfo.nChans;
        pAac->sampleRate = (ma_uint32)curInfo.sampRateOut;

        ma_aac_store_helix_pcm(pAac, curInfo.outputSamps);
        pAac->adtsCurrentFrame = 1;
        pAac->currentPCMFrame = 0;
        pAac->totalPCMFrameCount = (ma_uint64)pAac->adtsFrameCount * pAac->bufferFrames;

        return MA_SUCCESS;
    }
}

MA_API ma_result ma_aac_init(ma_read_proc onRead, ma_seek_proc onSeek, ma_tell_proc onTell, void *pReadSeekTellUserData, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_aac *pAac)
{
    (void)pAllocationCallbacks;

    if (pAac == NULL)
        return MA_INVALID_ARGS;
    if (onRead == NULL || onSeek == NULL)
        return MA_INVALID_ARGS;

    memset(pAac, 0, sizeof(*pAac));
    pAac->onRead = onRead;
    pAac->onSeek = onSeek;
    pAac->onTell = onTell;
    pAac->pReadSeekTellUserData = pReadSeekTellUserData;
    pAac->pFile = NULL;
    pAac->ownsFile = MA_FALSE;

    return ma_aac_init_internal(pConfig, pAac);
}

MA_API ma_result ma_aac_init_file(const char *pFilePath, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_aac *pAac)
{
    FILE *pFile;
    ma_result result;

    (void)pAllocationCallbacks;

    if (pAac == NULL || pFilePath == NULL)
        return MA_INVALID_ARGS;

    pFile = fopen(pFilePath, "rb");
    if (pFile == NULL)
        return MA_INVALID_FILE;

    memset(pAac, 0, sizeof(*pAac));
    pAac->pFile = pFile;
    pAac->ownsFile = MA_TRUE;

    result = ma_aac_init_internal(pConfig, pAac);
    if (result != MA_SUCCESS)
    {
        fclose(pFile);
        pAac->pFile = NULL;
        return result;
    }

    return MA_SUCCESS;
}

MA_API ma_result ma_aac_init_file_w(const wchar_t *pFilePath, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_aac *pAac)
{
    FILE *pFile = NULL;
    ma_result result;

    (void)pAllocationCallbacks;

    if (pAac == NULL || pFilePath == NULL)
        return MA_INVALID_ARGS;

#if defined(_WIN32)
    pFile = _wfopen(pFilePath, L"rb");
#else
    /* Non-Windows wide char path fallback */
    (void)pFilePath;
    return MA_NOT_IMPLEMENTED;
#endif

    if (pFile == NULL)
        return MA_INVALID_FILE;

    memset(pAac, 0, sizeof(*pAac));
    pAac->pFile = pFile;
    pAac->ownsFile = MA_TRUE;

    result = ma_aac_init_internal(pConfig, pAac);
    if (result != MA_SUCCESS)
    {
        fclose(pFile);
        pAac->pFile = NULL;
        return result;
    }

    return MA_SUCCESS;
}

MA_API void ma_aac_uninit(ma_aac *pAac, const ma_allocation_callbacks *pAllocationCallbacks)
{
    (void)pAllocationCallbacks;

    if (pAac == NULL)
        return;

    if (pAac->hDecoder != NULL)
    {
        AACFreeDecoder((HAACDecoder)pAac->hDecoder);
        pAac->hDecoder = NULL;
    }

    if (pAac->pAlac != NULL)
    {
        alac_free((alac_file *)pAac->pAlac);
        pAac->pAlac = NULL;
    }

    if (pAac->alacRawBuffer != NULL)
    {
        free(pAac->alacRawBuffer);
        pAac->alacRawBuffer = NULL;
    }

    if (pAac->container == MA_AAC_CONTAINER_MP4 && pAac->pMp4 != NULL)
    {
        MP4D_close((MP4D_demux_t *)pAac->pMp4);
        free(pAac->pMp4);
        pAac->pMp4 = NULL;
    }
    else if (pAac->container == MA_AAC_CONTAINER_ADTS && pAac->adtsFrameOffsets != NULL)
    {
        free(pAac->adtsFrameOffsets);
        pAac->adtsFrameOffsets = NULL;
    }

    if (pAac->ownsFile && pAac->pFile != NULL)
    {
        fclose((FILE *)pAac->pFile);
        pAac->pFile = NULL;
    }

    ma_data_source_uninit(&pAac->ds);
}

MA_API ma_result ma_aac_read_pcm_frames(ma_aac *pAac, void *pFramesOut, ma_uint64 frameCount, ma_uint64 *pFramesRead)
{
    ma_uint64 totalFramesRead = 0;

    if (pFramesRead != NULL)
        *pFramesRead = 0;

    if (pAac == NULL || pFramesOut == NULL || frameCount == 0)
        return MA_INVALID_ARGS;

    while (totalFramesRead < frameCount)
    {
        ma_uint32 available;
        ma_uint32 toCopy;

        /* 1. Copy available decoded frames from internal buffer */
        if (pAac->bufferIndex < pAac->bufferFrames)
        {
            available = pAac->bufferFrames - pAac->bufferIndex;
            toCopy = (ma_uint32)((frameCount - totalFramesRead < available) ? (frameCount - totalFramesRead) : available);

            if (pAac->format == ma_format_f32)
            {
                float *pOut = (float *)ma_offset_pcm_frames_ptr(pFramesOut, totalFramesRead, ma_format_f32, pAac->channels);
                const float *pIn = &pAac->floatBuffer[pAac->bufferIndex * pAac->channels];
                memcpy(pOut, pIn, toCopy * pAac->channels * sizeof(float));
            }
            else
            {
                short *pOut = (short *)ma_offset_pcm_frames_ptr(pFramesOut, totalFramesRead, ma_format_s16, pAac->channels);
                const short *pIn = &pAac->shortBuffer[pAac->bufferIndex * pAac->channels];
                memcpy(pOut, pIn, toCopy * pAac->channels * sizeof(short));
            }

            pAac->bufferIndex += toCopy;
            pAac->currentPCMFrame += toCopy;
            totalFramesRead += toCopy;
            continue;
        }

        /* 2. Internal buffer empty, decode next frame */
        if (pAac->container == MA_AAC_CONTAINER_MP4)
        {
            MP4D_demux_t *pMp4 = (MP4D_demux_t *)pAac->pMp4;
            unsigned frameBytes = 0, ts = 0, dur = 0;
            MP4D_file_offset_t offset;
            uint8_t *frameData;

            if (pAac->mp4CurrentSample >= pMp4->track[pAac->mp4AudioTrack].sample_count)
            {
                break; /* End of stream */
            }

            offset = MP4D_frame_offset(pMp4, pAac->mp4AudioTrack, pAac->mp4CurrentSample++, &frameBytes, &ts, &dur);
            frameData = (uint8_t *)malloc(frameBytes);
            if (frameData == NULL)
                return MA_OUT_OF_MEMORY;

            ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
            if (ma_aac_stream_read(pAac, frameData, frameBytes) != frameBytes)
            {
                free(frameData);
                break;
            }

            if (pAac->codec == MA_AAC_CODEC_ALAC)
            {
                int decodedBytes = 0;
                alac_decode_frame((alac_file *)pAac->pAlac, frameData, pAac->alacRawBuffer, &decodedBytes);
                free(frameData);

                if (decodedBytes > 0)
                {
                    ma_aac_store_alac_pcm(pAac, decodedBytes);
                }
                else
                {
                    pAac->bufferFrames = 0;
                    pAac->bufferIndex = 0;
                }
            }
            else
            {
                uint8_t *inPtr = frameData;
                int bytesLeft = (int)frameBytes;
                int err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->shortBuffer);
                free(frameData);

                if (err == 0)
                {
                    AACFrameInfo curInfo;
                    AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
                    ma_aac_store_helix_pcm(pAac, curInfo.outputSamps);
                }
                else
                {
                    pAac->bufferFrames = 0;
                    pAac->bufferIndex = 0;
                }
            }
        }
        else if (pAac->container == MA_AAC_CONTAINER_ADTS)
        {
            uint32_t offset;
            uint32_t len;
            uint8_t *frameData;
            uint8_t *inPtr;
            int bytesLeft;
            int err;

            if (pAac->adtsCurrentFrame >= pAac->adtsFrameCount)
            {
                break;
            }

            offset = pAac->adtsFrameOffsets[pAac->adtsCurrentFrame];
            len = (pAac->adtsCurrentFrame + 1 < pAac->adtsFrameCount)
                      ? (pAac->adtsFrameOffsets[pAac->adtsCurrentFrame + 1] - offset)
                      : (uint32_t)(pAac->adtsFileSize - offset);

            pAac->adtsCurrentFrame++;
            frameData = (uint8_t *)malloc(len);
            if (frameData == NULL)
                return MA_OUT_OF_MEMORY;

            ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
            if (ma_aac_stream_read(pAac, frameData, len) != len)
            {
                free(frameData);
                break;
            }

            inPtr = frameData;
            bytesLeft = (int)len;
            err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->shortBuffer);
            free(frameData);

            if (err == 0)
            {
                AACFrameInfo curInfo;
                AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
                ma_aac_store_helix_pcm(pAac, curInfo.outputSamps);
            }
            else
            {
                pAac->bufferFrames = 0;
                pAac->bufferIndex = 0;
            }
        }
        else
        {
            break;
        }
    }

    if (pFramesRead != NULL)
    {
        *pFramesRead = totalFramesRead;
    }

    if (totalFramesRead == 0)
    {
        return MA_AT_END;
    }

    return MA_SUCCESS;
}

MA_API ma_result ma_aac_seek_to_pcm_frame(ma_aac *pAac, ma_uint64 frameIndex)
{
    ma_uint32 nominalFrameSamples;
    ma_uint64 sampleIdx;
    ma_uint32 remainder;

    if (pAac == NULL)
        return MA_INVALID_ARGS;

    nominalFrameSamples = (pAac->bufferFrames > 0) ? pAac->bufferFrames : 1024;
    if (nominalFrameSamples == 0)
        nominalFrameSamples = 1024;

    if (frameIndex >= pAac->totalPCMFrameCount)
    {
        pAac->currentPCMFrame = pAac->totalPCMFrameCount;
        pAac->bufferFrames = 0;
        pAac->bufferIndex = 0;
        if (pAac->container == MA_AAC_CONTAINER_MP4 && pAac->pMp4 != NULL)
        {
            pAac->mp4CurrentSample = ((MP4D_demux_t *)pAac->pMp4)->track[pAac->mp4AudioTrack].sample_count;
        }
        else if (pAac->container == MA_AAC_CONTAINER_ADTS)
        {
            pAac->adtsCurrentFrame = pAac->adtsFrameCount;
        }
        return MA_SUCCESS;
    }

    sampleIdx = frameIndex / nominalFrameSamples;
    remainder = (ma_uint32)(frameIndex % nominalFrameSamples);

    if (pAac->container == MA_AAC_CONTAINER_MP4)
    {
        MP4D_demux_t *pMp4 = (MP4D_demux_t *)pAac->pMp4;
        unsigned frameBytes = 0, ts = 0, dur = 0;
        MP4D_file_offset_t offset = MP4D_frame_offset(pMp4, pAac->mp4AudioTrack, (unsigned)sampleIdx, &frameBytes, &ts, &dur);
        uint8_t *frameData = (uint8_t *)malloc(frameBytes);

        if (frameData == NULL)
            return MA_OUT_OF_MEMORY;

        ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, frameData, frameBytes) != frameBytes)
        {
            free(frameData);
            return MA_ERROR;
        }

        if (pAac->codec == MA_AAC_CODEC_ALAC)
        {
            int decodedBytes = 0;
            alac_decode_frame((alac_file *)pAac->pAlac, frameData, pAac->alacRawBuffer, &decodedBytes);
            free(frameData);

            if (decodedBytes <= 0)
                return MA_ERROR;

            ma_aac_store_alac_pcm(pAac, decodedBytes);
        }
        else
        {
            uint8_t *inPtr = frameData;
            int bytesLeft = (int)frameBytes;
            int err;

            AACFlushCodec((HAACDecoder)pAac->hDecoder);
            err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->shortBuffer);
            free(frameData);

            if (err != 0)
                return MA_ERROR;

            AACFrameInfo curInfo;
            AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
            ma_aac_store_helix_pcm(pAac, curInfo.outputSamps);
        }

        pAac->bufferIndex = (remainder < pAac->bufferFrames) ? remainder : pAac->bufferFrames;
        pAac->mp4CurrentSample = (ma_uint32)sampleIdx + 1;
        pAac->currentPCMFrame = frameIndex;
        return MA_SUCCESS;
    }
    else if (pAac->container == MA_AAC_CONTAINER_ADTS)
    {
        uint32_t offset = pAac->adtsFrameOffsets[sampleIdx];
        uint32_t len = (sampleIdx + 1 < pAac->adtsFrameCount)
                           ? (pAac->adtsFrameOffsets[sampleIdx + 1] - offset)
                           : (uint32_t)(pAac->adtsFileSize - offset);
        uint8_t *frameData = (uint8_t *)malloc(len);
        uint8_t *inPtr;
        int bytesLeft;
        int err;
        AACFrameInfo curInfo;

        if (frameData == NULL)
            return MA_OUT_OF_MEMORY;

        ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, frameData, len) != len)
        {
            free(frameData);
            return MA_ERROR;
        }

        AACFlushCodec((HAACDecoder)pAac->hDecoder);
        inPtr = frameData;
        bytesLeft = (int)len;
        err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->shortBuffer);
        free(frameData);

        if (err != 0)
            return MA_ERROR;

        AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
        ma_aac_store_helix_pcm(pAac, curInfo.outputSamps);
        pAac->bufferIndex = (remainder < pAac->bufferFrames) ? remainder : pAac->bufferFrames;
        pAac->adtsCurrentFrame = (ma_uint32)sampleIdx + 1;
        pAac->currentPCMFrame = frameIndex;
        return MA_SUCCESS;
    }

    return MA_INVALID_OPERATION;
}

MA_API ma_result ma_aac_get_data_format(ma_aac *pAac, ma_format *pFormat, ma_uint32 *pChannels, ma_uint32 *pSampleRate, ma_channel *pChannelMap, size_t channelMapCap)
{
    if (pFormat != NULL)
        *pFormat = ma_format_unknown;
    if (pChannels != NULL)
        *pChannels = 0;
    if (pSampleRate != NULL)
        *pSampleRate = 0;
    if (pChannelMap != NULL)
        memset(pChannelMap, 0, sizeof(*pChannelMap) * channelMapCap);

    if (pAac == NULL)
        return MA_INVALID_OPERATION;

    if (pFormat != NULL)
        *pFormat = pAac->format;
    if (pChannels != NULL)
        *pChannels = pAac->channels;
    if (pSampleRate != NULL)
        *pSampleRate = pAac->sampleRate;
    if (pChannelMap != NULL)
    {
        ma_channel_map_init_standard(ma_standard_channel_map_vorbis, pChannelMap, channelMapCap, pAac->channels);
    }

    return MA_SUCCESS;
}

MA_API ma_result ma_aac_get_cursor_in_pcm_frames(ma_aac *pAac, ma_uint64 *pCursor)
{
    if (pCursor == NULL)
        return MA_INVALID_ARGS;
    if (pAac == NULL)
        return MA_INVALID_OPERATION;

    *pCursor = pAac->currentPCMFrame;
    return MA_SUCCESS;
}

MA_API ma_result ma_aac_get_length_in_pcm_frames(ma_aac *pAac, ma_uint64 *pLength)
{
    if (pLength == NULL)
        return MA_INVALID_ARGS;
    if (pAac == NULL)
        return MA_INVALID_OPERATION;

    *pLength = pAac->totalPCMFrameCount;
    return MA_SUCCESS;
}

/*
 * Decoding backend vtable implementation
 */
static ma_result ma_decoding_backend_init__aac(void *pUserData, ma_read_proc onRead, ma_seek_proc onSeek, ma_tell_proc onTell, void *pReadSeekTellUserData, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_data_source **ppBackend)
{
    ma_result result;
    ma_aac *pAac;

    (void)pUserData;

    pAac = (ma_aac *)ma_malloc(sizeof(*pAac), pAllocationCallbacks);
    if (pAac == NULL)
        return MA_OUT_OF_MEMORY;

    result = ma_aac_init(onRead, onSeek, onTell, pReadSeekTellUserData, pConfig, pAllocationCallbacks, pAac);
    if (result != MA_SUCCESS)
    {
        ma_free(pAac, pAllocationCallbacks);
        return result;
    }

    *ppBackend = (ma_data_source *)pAac;
    return MA_SUCCESS;
}

static ma_result ma_decoding_backend_init_file__aac(void *pUserData, const char *pFilePath, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_data_source **ppBackend)
{
    ma_result result;
    ma_aac *pAac;

    (void)pUserData;

    pAac = (ma_aac *)ma_malloc(sizeof(*pAac), pAllocationCallbacks);
    if (pAac == NULL)
        return MA_OUT_OF_MEMORY;

    result = ma_aac_init_file(pFilePath, pConfig, pAllocationCallbacks, pAac);
    if (result != MA_SUCCESS)
    {
        ma_free(pAac, pAllocationCallbacks);
        return result;
    }

    *ppBackend = (ma_data_source *)pAac;
    return MA_SUCCESS;
}

static ma_result ma_decoding_backend_init_file_w__aac(void *pUserData, const wchar_t *pFilePath, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_data_source **ppBackend)
{
    ma_result result;
    ma_aac *pAac;

    (void)pUserData;

    pAac = (ma_aac *)ma_malloc(sizeof(*pAac), pAllocationCallbacks);
    if (pAac == NULL)
        return MA_OUT_OF_MEMORY;

    result = ma_aac_init_file_w(pFilePath, pConfig, pAllocationCallbacks, pAac);
    if (result != MA_SUCCESS)
    {
        ma_free(pAac, pAllocationCallbacks);
        return result;
    }

    *ppBackend = (ma_data_source *)pAac;
    return MA_SUCCESS;
}

static void ma_decoding_backend_uninit__aac(void *pUserData, ma_data_source *pBackend, const ma_allocation_callbacks *pAllocationCallbacks)
{
    ma_aac *pAac = (ma_aac *)pBackend;

    (void)pUserData;

    ma_aac_uninit(pAac, pAllocationCallbacks);
    ma_free(pAac, pAllocationCallbacks);
}

static ma_decoding_backend_vtable ma_gDecodingBackendVTable_aac = {
    ma_decoding_backend_init__aac,
    ma_decoding_backend_init_file__aac,
    ma_decoding_backend_init_file_w__aac,
    NULL, /* onInitMemory */
    ma_decoding_backend_uninit__aac};

ma_decoding_backend_vtable *ma_decoding_backend_aac = &ma_gDecodingBackendVTable_aac;

#endif /* miniaudio_aac_c */
