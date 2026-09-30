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
        AACFrameInfo aacInfo;
        unsigned frameBytes = 0, ts = 0, dur = 0;
        MP4D_file_offset_t offset;
        uint8_t *frameData;
        uint8_t *inPtr;
        int bytesLeft;
        int err;
        AACFrameInfo curInfo;

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
                pMp4->track[i].object_type_indication == MP4_OBJECT_TYPE_AUDIO_ISO_IEC_14496_3)
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

        /* Decode sample 0 to initialize codec state and detect parameters */
        offset = MP4D_frame_offset(pMp4, audioTrack, 0, &frameBytes, &ts, &dur);
        frameData = (uint8_t *)malloc(frameBytes);
        if (frameData == NULL)
        {
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            MP4D_close(pMp4);
            free(pMp4);
            return MA_OUT_OF_MEMORY;
        }

        ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, frameData, frameBytes) != frameBytes)
        {
            free(frameData);
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            MP4D_close(pMp4);
            free(pMp4);
            return MA_INVALID_FILE;
        }

        inPtr = frameData;
        bytesLeft = (int)frameBytes;
        err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->pcmBuffer);
        free(frameData);
        if (err != 0)
        {
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            MP4D_close(pMp4);
            free(pMp4);
            return MA_INVALID_FILE;
        }

        AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
        pAac->container = MA_AAC_CONTAINER_MP4;
        pAac->pMp4 = pMp4;
        pAac->mp4AudioTrack = (ma_uint32)audioTrack;
        pAac->channels = (ma_uint32)curInfo.nChans;
        pAac->sampleRate = (ma_uint32)curInfo.sampRateOut;
        pAac->pcmBufferFrames = (ma_uint32)(curInfo.outputSamps / curInfo.nChans);
        pAac->pcmBufferIndex = 0;
        pAac->mp4CurrentSample = 1;
        pAac->currentPCMFrame = 0;
        pAac->totalPCMFrameCount = (ma_uint64)pMp4->track[audioTrack].sample_count * pAac->pcmBufferFrames;

        return MA_SUCCESS;
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
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_OUT_OF_MEMORY;
        }

        ma_aac_stream_seek(pAac, f0_offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, frameData, f0_len) != f0_len)
        {
            free(frameData);
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_INVALID_FILE;
        }

        inPtr = frameData;
        bytesLeft = (int)f0_len;
        err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->pcmBuffer);
        free(frameData);
        if (err != 0)
        {
            AACFreeDecoder((HAACDecoder)pAac->hDecoder);
            free(pAac->adtsFrameOffsets);
            pAac->adtsFrameOffsets = NULL;
            return MA_INVALID_FILE;
        }

        AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
        pAac->container = MA_AAC_CONTAINER_ADTS;
        pAac->channels = (ma_uint32)curInfo.nChans;
        pAac->sampleRate = (ma_uint32)curInfo.sampRateOut;
        pAac->pcmBufferFrames = (ma_uint32)(curInfo.outputSamps / curInfo.nChans);
        pAac->pcmBufferIndex = 0;
        pAac->adtsCurrentFrame = 1;
        pAac->currentPCMFrame = 0;
        pAac->totalPCMFrameCount = (ma_uint64)pAac->adtsFrameCount * pAac->pcmBufferFrames;

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
        if (pAac->pcmBufferIndex < pAac->pcmBufferFrames)
        {
            available = pAac->pcmBufferFrames - pAac->pcmBufferIndex;
            toCopy = (ma_uint32)((frameCount - totalFramesRead < available) ? (frameCount - totalFramesRead) : available);

            if (pAac->format == ma_format_f32)
            {
                float *pOut = (float *)ma_offset_pcm_frames_ptr(pFramesOut, totalFramesRead, ma_format_f32, pAac->channels);
                const short *pIn = &pAac->pcmBuffer[pAac->pcmBufferIndex * pAac->channels];
                ma_uint32 totalSamples = toCopy * pAac->channels;
                for (ma_uint32 i = 0; i < totalSamples; i++)
                {
                    pOut[i] = (float)pIn[i] / 32768.0f;
                }
            }
            else
            {
                short *pOut = (short *)ma_offset_pcm_frames_ptr(pFramesOut, totalFramesRead, ma_format_s16, pAac->channels);
                const short *pIn = &pAac->pcmBuffer[pAac->pcmBufferIndex * pAac->channels];
                memcpy(pOut, pIn, toCopy * pAac->channels * sizeof(short));
            }

            pAac->pcmBufferIndex += toCopy;
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
            uint8_t *inPtr;
            int bytesLeft;
            int err;
            AACFrameInfo curInfo;

            if (pAac->mp4CurrentSample >= pMp4->track[pAac->mp4AudioTrack].sample_count)
            {
                break; /* Reached end of audio stream */
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

            inPtr = frameData;
            bytesLeft = (int)frameBytes;
            err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->pcmBuffer);
            free(frameData);

            if (err == 0)
            {
                AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
                pAac->pcmBufferFrames = (ma_uint32)(curInfo.outputSamps / curInfo.nChans);
                pAac->pcmBufferIndex = 0;
            }
            else
            {
                /* Decode error on frame, keep going or finish */
                pAac->pcmBufferFrames = 0;
                pAac->pcmBufferIndex = 0;
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
            AACFrameInfo curInfo;

            if (pAac->adtsCurrentFrame >= pAac->adtsFrameCount)
            {
                break; /* Reached end of ADTS stream */
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
            err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->pcmBuffer);
            free(frameData);

            if (err == 0)
            {
                AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
                pAac->pcmBufferFrames = (ma_uint32)(curInfo.outputSamps / curInfo.nChans);
                pAac->pcmBufferIndex = 0;
            }
            else
            {
                pAac->pcmBufferFrames = 0;
                pAac->pcmBufferIndex = 0;
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

    nominalFrameSamples = (pAac->pcmBufferFrames > 0) ? pAac->pcmBufferFrames : 1024;
    if (nominalFrameSamples == 0)
        nominalFrameSamples = 1024;

    if (frameIndex >= pAac->totalPCMFrameCount)
    {
        pAac->currentPCMFrame = pAac->totalPCMFrameCount;
        pAac->pcmBufferFrames = 0;
        pAac->pcmBufferIndex = 0;
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

    AACFlushCodec((HAACDecoder)pAac->hDecoder);

    if (pAac->container == MA_AAC_CONTAINER_MP4)
    {
        MP4D_demux_t *pMp4 = (MP4D_demux_t *)pAac->pMp4;
        unsigned frameBytes = 0, ts = 0, dur = 0;
        MP4D_file_offset_t offset = MP4D_frame_offset(pMp4, pAac->mp4AudioTrack, (unsigned)sampleIdx, &frameBytes, &ts, &dur);
        uint8_t *frameData = (uint8_t *)malloc(frameBytes);
        uint8_t *inPtr;
        int bytesLeft;
        int err;
        AACFrameInfo curInfo;

        if (frameData == NULL)
            return MA_OUT_OF_MEMORY;

        ma_aac_stream_seek(pAac, offset, ma_seek_origin_start);
        if (ma_aac_stream_read(pAac, frameData, frameBytes) != frameBytes)
        {
            free(frameData);
            return MA_ERROR;
        }

        inPtr = frameData;
        bytesLeft = (int)frameBytes;
        err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->pcmBuffer);
        free(frameData);

        if (err != 0)
            return MA_ERROR;

        AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
        pAac->pcmBufferFrames = (ma_uint32)(curInfo.outputSamps / curInfo.nChans);
        pAac->pcmBufferIndex = (remainder < pAac->pcmBufferFrames) ? remainder : pAac->pcmBufferFrames;
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

        inPtr = frameData;
        bytesLeft = (int)len;
        err = AACDecode((HAACDecoder)pAac->hDecoder, &inPtr, &bytesLeft, pAac->pcmBuffer);
        free(frameData);

        if (err != 0)
            return MA_ERROR;

        AACGetLastFrameInfo((HAACDecoder)pAac->hDecoder, &curInfo);
        pAac->pcmBufferFrames = (ma_uint32)(curInfo.outputSamps / curInfo.nChans);
        pAac->pcmBufferIndex = (remainder < pAac->pcmBufferFrames) ? remainder : pAac->pcmBufferFrames;
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
