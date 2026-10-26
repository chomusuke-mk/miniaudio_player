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

/**
 * @brief Explicit Finite State Machine for the low-level decoder data source (map_time_stretch_ds).
 */
typedef enum map_source_state
{
    MAP_SOURCE_STATE_UNINITIALIZED = 0, /**< Data source not initialized */
    MAP_SOURCE_STATE_IDLE          = 1, /**< Initialized and ready at start or seek position */
    MAP_SOURCE_STATE_DECODING      = 2, /**< Worker / reader actively decoding frames from map_buffer_t */
    MAP_SOURCE_STATE_BUFFERING     = 3, /**< Data source paused because underlying stream buffer is starved */
    MAP_SOURCE_STATE_DRAINING      = 4, /**< Decoder reached container EOF; draining remaining PCM frames from rb/sonic */
    MAP_SOURCE_STATE_EOF           = 5, /**< All PCM frames drained; source is at end */
    MAP_SOURCE_STATE_ERROR         = 6  /**< Fatal decoding error */
} map_source_state_t;

typedef struct
{
    ma_data_source_base base;
    map_source_state_t state;
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

/**
 * @brief Seeks the low-level decoder data source and high-level buffer atomically.
 * @return 1 on RAM cache HIT, 0 on cache MISS.
 */
int32_t map_time_stretch_ds_seek_stream(
    map_time_stretch_ds *pDS,
    ma_uint64 targetFrame,
    int64_t newStreamOffset);

void map_time_stretch_ds_set_speed(
    map_time_stretch_ds *pDS,
    float speed);

void map_time_stretch_ds_set_pitch(
    map_time_stretch_ds *pDS,
    float pitch);

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
