/**
 * @file map_buffer.h
 * @brief Unified Two-Tier Audio Buffer: Bidirectional circular sliding window cache,
 *        decoupled stream ingest, and low-level decoder abstraction.
 */

#ifndef MAP_BUFFER_H
#define MAP_BUFFER_H

#include <stdint.h>
#include <stddef.h>
#include "miniaudio.h"
#include "map_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Telemetry snapshot of the high-level buffer cache.
 */
typedef struct map_buffer_range
{
    int64_t start_byte;       /**< Earliest valid byte offset retained in RAM */
    int64_t end_byte;         /**< Furthest continuous byte offset loaded in RAM */
    int64_t total_bytes;      /**< Total stream size (-1 if unknown / live stream) */
    int64_t read_cursor_byte; /**< Current position of the low-level decoding reader */
    float fill_percentage;    /**< 0.0 to 1.0 fraction of capacity currently held */
    float stream_percentage;  /**< 0.0 to 1.0 fraction of total file loaded */
    int32_t is_buffering;     /**< 1 if reader is stalled waiting for provider data */
    int32_t is_eof;           /**< 1 if provider reached stream EOF */
} map_buffer_range_t;

/**
 * @brief High-level abstract bidirectional sliding-window circular buffer.
 */
typedef struct map_buffer
{
    uint8_t *data;            /**< Contiguous memory block of `capacity` bytes */
    size_t capacity;          /**< Total ring buffer capacity in bytes */
    int64_t range_start;      /**< Earliest byte offset present in ring buffer */
    int64_t range_end;        /**< Furthest byte offset loaded in ring buffer */
    int64_t read_cursor;      /**< Absolute byte offset requested by decoder */
    int64_t total_size;       /**< Total stream size in bytes (-1 for live streams) */
    ma_bool32 is_live;        /**< 1 for continuous livestreams, 0 for finite files */
    ma_bool32 is_eof;         /**< 1 when provider has finished sending data */
    ma_bool32 should_abort;   /**< 1 to abort any waiting decoder readers */
    ma_bool32 is_probing;     /**< 1 during initial header format sniffing */
    size_t initial_bytes;     /**< Bytes provided during initial probe */
    ma_mutex lock;            /**< Mutex protecting buffer bounds and state */
    ma_event data_ready_event;/**< Event signaling available data to decoder thread */
    ma_bool32 is_initialized; /**< 1 if buffer is valid and initialized */
} map_buffer_t;

/**
 * @brief Initializes a new unified high-level buffer.
 * @param mb Pointer to map_buffer_t instance.
 * @param capacity_bytes Capacity in bytes (e.g. configured MB * 1024 * 1024).
 * @param total_size Total file size in bytes (-1 if unknown or live stream).
 * @param is_live 1 for continuous livestreams, 0 for finite files.
 * @return MA_SUCCESS or error code.
 */
ma_result map_buffer_init(
    map_buffer_t *mb,
    size_t capacity_bytes,
    int64_t total_size,
    ma_bool32 is_live);

/**
 * @brief Frees and uninitializes the high-level buffer.
 */
void map_buffer_uninit(map_buffer_t *mb);

/**
 * @brief Aborts all waiting reads and marks the buffer as aborted.
 */
void map_buffer_abort(map_buffer_t *mb);

/**
 * @brief Feeds encoded audio chunks from any input source (file, network, stream) into the buffer.
 * @param mb Buffer instance.
 * @param offset Absolute stream byte offset of incoming data.
 * @param pData Pointer to incoming byte chunk.
 * @param size Number of bytes in chunk.
 * @return MA_SUCCESS or error code.
 */
ma_result map_buffer_write(
    map_buffer_t *mb,
    int64_t offset,
    const uint8_t *pData,
    size_t size);

/**
 * @brief Feeds sequential chunks (advancing from range_end).
 */
ma_result map_buffer_feed(
    map_buffer_t *mb,
    const uint8_t *pData,
    size_t size);

/**
 * @brief Reads bytes from the buffer at the current read cursor or specified offset.
 * Serves in O(1) directly from RAM if present within [range_start, range_end).
 * Waits with timeout if data is not yet available, or returns MA_BUSY / MA_AT_END.
 */
ma_result map_buffer_read(
    map_buffer_t *mb,
    int64_t offset,
    void *pBufferOut,
    size_t bytesToRead,
    size_t *pBytesRead);

/**
 * @brief Seeks the low-level read cursor.
 * If target_offset is within [range_start, range_end), it's an instantaneous cache hit in RAM!
 * If outside, repositions the window to prepare for new range ingestion.
 */
ma_result map_buffer_seek(
    map_buffer_t *mb,
    int64_t target_offset);

/**
 * @brief Flushes the buffer window and positions read cursor and range at new_offset.
 */
ma_result map_buffer_flush(
    map_buffer_t *mb,
    int64_t new_offset);

/**
 * @brief Signals that provider has sent all bytes (EOF).
 */
ma_result map_buffer_end(map_buffer_t *mb);

/**
 * @brief Queries current telemetry snapshot (for UI preloaded progress bar).
 */
ma_result map_buffer_get_range(
    const map_buffer_t *mb,
    map_buffer_range_t *out_range);

/**
 * @brief ma_decoder callback implementations wrapping map_buffer_t directly.
 */
ma_result map_buffer_decoder_read(
    ma_decoder *pDecoder,
    void *pBufferOut,
    size_t bytesToRead,
    size_t *pBytesRead);

ma_result map_buffer_decoder_seek(
    ma_decoder *pDecoder,
    ma_int64 byteOffset,
    ma_seek_origin origin);

ma_result map_buffer_decoder_tell(
    ma_decoder *pDecoder,
    ma_int64 *pCursor);

#ifdef __cplusplus
}
#endif

#endif /* MAP_BUFFER_H */
