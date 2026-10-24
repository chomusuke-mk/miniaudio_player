/**
 * @file map_source.h
 * @brief SPSC ring buffer, Sonic time-stretching, and asynchronous decoding data source.
 */

#ifndef MAP_SOURCE_H
#define MAP_SOURCE_H

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "sonic.h"
#include "map_common.h"
#include "map_silence.h"
#include "map_buffer.h"

typedef struct
{
    ma_data_source_base base;
    ma_decoder decoder;
    sonicStream sonic;
    ma_spinlock lock;
    ma_uint32 channels;
    ma_uint32 sampleRate;
    float speed;
    float pitch;
    ma_bool32 is_initialized;
    ma_bool32 is_eof;
    float *scratchBuffer;
    ma_uint32 scratchCapacity; /* in floats */
    float *rawBuffer;
    ma_uint32 rawBufferCapacity; /* in floats */
    ma_uint32 rawBufferCount;    /* in frames */
    ma_uint32 rawBufferReadPos;  /* in frames */
    map_silence_detector silence;

    /* Memory backing */
    const void *memory_buffer;
    size_t memory_size;
    ma_bool32 owns_memory;

    /* High-Level Buffer backing */
    map_buffer_t buffer;
    ma_bool32 is_stream;

    /* Decoupled Asynchronous Decoder Worker & Lock-Free SPSC Ring Buffer (NP3-01) */
    ma_pcm_rb rb;
    ma_thread worker_thread;
    ma_event worker_event;
    ma_mutex decoder_mutex;
    ma_bool32 has_worker;
    MA_ATOMIC(4, ma_uint32) worker_is_sleeping;
    MA_ATOMIC(4, ma_uint32) worker_stop;
    MA_ATOMIC(4, ma_uint32) decoder_eof;
    ma_uint64 totalFrames;
    ma_uint64 readCursorFrames;
    double read_cursor_fraction;
    MA_ATOMIC(4, ma_uint32) underrun_count;
    struct map_event_dispatcher *pDispatcher;
} map_time_stretch_ds;

void map_time_stretch_ds_set_dispatcher(
    map_time_stretch_ds *pDS,
    struct map_event_dispatcher *pDispatcher);

ma_result map_time_stretch_ds_init(
    map_time_stretch_ds *pDS,
    const char *file_path,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate);

ma_result map_time_stretch_ds_init_memory(
    map_time_stretch_ds *pDS,
    const void *pData,
    size_t dataSize,
    ma_bool32 ownsMemory,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate);

ma_result map_time_stretch_ds_init_stream(
    map_time_stretch_ds *pDS,
    const uint8_t *initialData,
    size_t initialDataSize,
    int64_t totalSize,
    ma_bool32 isLive,
    size_t bufferCapacity,
    int32_t encodingFormat,
    ma_uint32 targetChannels,
    ma_uint32 targetSampleRate);

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
    ma_uint32 targetSampleRate);

ma_result map_time_stretch_ds_stream_feed(
    map_time_stretch_ds *pDS,
    const uint8_t *data,
    size_t size);

ma_result map_time_stretch_ds_stream_flush(
    map_time_stretch_ds *pDS,
    int64_t newStreamOffset);

ma_result map_time_stretch_ds_stream_end(
    map_time_stretch_ds *pDS);


void map_time_stretch_ds_uninit(map_time_stretch_ds *pDS);

ma_result map_time_stretch_ds_read(
    ma_data_source *pDataSource,
    void *pFramesOut,
    ma_uint64 frameCount,
    ma_uint64 *pFramesRead);

ma_result map_time_stretch_ds_seek(
    ma_data_source *pDataSource,
    ma_uint64 frameIndex);

ma_result map_time_stretch_ds_get_data_format(
    ma_data_source *pDataSource,
    ma_format *pFormat,
    ma_uint32 *pChannels,
    ma_uint32 *pSampleRate,
    ma_channel *pChannelMap,
    size_t channelMapCap);

ma_result map_time_stretch_ds_get_cursor(
    ma_data_source *pDataSource,
    ma_uint64 *pCursor);

ma_result map_time_stretch_ds_get_length(
    ma_data_source *pDataSource,
    ma_uint64 *pLength);

ma_result map_time_stretch_ds_set_looping(
    ma_data_source *pDataSource,
    ma_bool32 isLooping);

#endif /* MAP_SOURCE_H */
