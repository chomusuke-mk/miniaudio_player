/*
 * Miniaudio custom decoding backend for AAC (.aac ADTS) and M4A (.m4a MP4 container with AAC audio track).
 * Powered by minimp4 and Helix AAC decoder.
 */
#ifndef miniaudio_aac_h
#define miniaudio_aac_h

#ifdef __cplusplus
extern "C"
{
#endif

#include "../../miniaudio.h"

    typedef enum
    {
        MA_AAC_CONTAINER_UNKNOWN = 0,
        MA_AAC_CONTAINER_ADTS = 1,
        MA_AAC_CONTAINER_MP4 = 2
    } ma_aac_container;

    typedef struct ma_aac
    {
        ma_data_source_base ds;
        ma_read_proc onRead;
        ma_seek_proc onSeek;
        ma_tell_proc onTell;
        void *pReadSeekTellUserData;
        ma_format format;          /* Preferred format: f32 or s16 */
        void *pFile;               /* FILE* if opened via init_file */
        ma_bool32 ownsFile;

        /* Helix AAC decoder instance */
        void *hDecoder;

        /* Container mode & audio parameters */
        ma_aac_container container;
        ma_uint32 channels;
        ma_uint32 sampleRate;
        ma_uint64 totalPCMFrameCount;
        ma_uint64 currentPCMFrame;

        /* Decoded PCM buffer */
        short pcmBuffer[2048 * 2];
        ma_uint32 pcmBufferFrames;
        ma_uint32 pcmBufferIndex;

        /* MP4 container state */
        void *pMp4;                /* MP4D_demux_t* */
        ma_uint32 mp4AudioTrack;
        ma_uint32 mp4CurrentSample;

        /* ADTS stream state */
        ma_uint64 adtsDataStartOffset;
        ma_uint64 adtsFileSize;
        ma_uint32 *adtsFrameOffsets;
        ma_uint32 adtsFrameCount;
        ma_uint32 adtsCurrentFrame;
    } ma_aac;

    MA_API ma_result ma_aac_init(ma_read_proc onRead, ma_seek_proc onSeek, ma_tell_proc onTell, void *pReadSeekTellUserData, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_aac *pAac);
    MA_API ma_result ma_aac_init_file(const char *pFilePath, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_aac *pAac);
    MA_API ma_result ma_aac_init_file_w(const wchar_t *pFilePath, const ma_decoding_backend_config *pConfig, const ma_allocation_callbacks *pAllocationCallbacks, ma_aac *pAac);
    MA_API void ma_aac_uninit(ma_aac *pAac, const ma_allocation_callbacks *pAllocationCallbacks);
    MA_API ma_result ma_aac_read_pcm_frames(ma_aac *pAac, void *pFramesOut, ma_uint64 frameCount, ma_uint64 *pFramesRead);
    MA_API ma_result ma_aac_seek_to_pcm_frame(ma_aac *pAac, ma_uint64 frameIndex);
    MA_API ma_result ma_aac_get_data_format(ma_aac *pAac, ma_format *pFormat, ma_uint32 *pChannels, ma_uint32 *pSampleRate, ma_channel *pChannelMap, size_t channelMapCap);
    MA_API ma_result ma_aac_get_cursor_in_pcm_frames(ma_aac *pAac, ma_uint64 *pCursor);
    MA_API ma_result ma_aac_get_length_in_pcm_frames(ma_aac *pAac, ma_uint64 *pLength);

    /* Decoding backend vtable */
    extern ma_decoding_backend_vtable *ma_decoding_backend_aac;

#ifdef __cplusplus
}
#endif

#endif /* miniaudio_aac_h */
