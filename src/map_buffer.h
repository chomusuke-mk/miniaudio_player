/**
 * @file map_buffer.h
 * @brief Unified Tripartite Audio Buffer: Decoupled Head, Pure Audio Ring, and Tail buffers,
 *        boundary detection, .metaBytes synthesis, and decoder abstraction.
 */

#ifndef MAP_BUFFER_H
#define MAP_BUFFER_H

#include <stdint.h>
#include <stddef.h>
#include "miniaudio.h"
#include "map_common.h"
#include "map_sniffer.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Explicit Finite State Machine for the high-level tripartite buffer (map_buffer_t).
 */
typedef enum map_buffer_state
{
    MAP_BUFFER_STATE_UNINITIALIZED = 0, /**< Buffer memory not allocated or already uninitialized */
    MAP_BUFFER_STATE_PROBING_HEAD  = 1, /**< Accumulating initial prefix to lock audio_start and init decoder */
    MAP_BUFFER_STATE_READY         = 2, /**< Healthy buffered window available for reading */
    MAP_BUFFER_STATE_BUFFERING     = 3, /**< Reader cursor reached range_end while stream is not at EOF */
    MAP_BUFFER_STATE_EOF           = 4, /**< Producer finished delivering all stream bytes */
    MAP_BUFFER_STATE_ABORTED       = 5  /**< Buffer read/write aborted for seek flush or teardown */
} map_buffer_state_t;

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

#define MAP_BUFFER_PINNED_HEAD_DEFAULT_CAPACITY (256 * 1024)

/**
 * @brief Tripartite buffer separating Head (setup/metadata), Pure Audio Ring, and Tail.
 */
typedef struct map_buffer
{
    map_buffer_state_t state; /**< Explicit FSM state of the buffer */

    /* ---------------------------------------------------------------------- */
    /* 1. Pure Audio Ring Buffer: [audio_start .. audio_end)                  */
    /*    Indexed as: (abs_offset - audio_start) % capacity                   */
    /* ---------------------------------------------------------------------- */
    union {
        uint8_t *data;
        uint8_t *ring_data;
    };
    union {
        size_t capacity;
        size_t ring_capacity;
    };
    union {
        int64_t range_start;
        int64_t ring_start_offset;
    };
    union {
        int64_t range_end;
        int64_t ring_end_offset;
    };
    union {
        int64_t read_cursor;
        int64_t read_pos;
    };

    int64_t total_size;       /**< Total stream size in bytes (-1 for live streams) */
    ma_bool32 is_live;        /**< 1 for continuous livestreams, 0 for finite files */
    ma_bool32 is_eof;         /**< 1 when provider has finished sending data */
    ma_bool32 should_abort;   /**< 1 to abort any waiting decoder readers */
    ma_bool32 is_probing;     /**< 1 during initial header format sniffing */
    size_t initial_bytes;     /**< Bytes provided during initial probe */
    ma_bool32 is_buffering;   /**< 1 if decoder is starved waiting on data_ready_event */

    /* ---------------------------------------------------------------------- */
    /* 2. Pinned Head Buffer: [0 .. audio_start)                              */
    /* ---------------------------------------------------------------------- */
    uint8_t *head_data;       /**< Dynamic pinned buffer holding headers & initial tags */
    union {
        size_t head_size;     /**< Valid bytes written into head_data */
        size_t head_written;
    };
    size_t head_capacity;     /**< Allocated capacity of head_data */

    /* ---------------------------------------------------------------------- */
    /* 3. Tail Buffer: [audio_end .. total_size)                              */
    /* ---------------------------------------------------------------------- */
    uint8_t *tail_data;       /**< Buffer holding trailing tags (ID3v1, APEv2) or boxes (moov) */
    union {
        size_t tail_size;     /**< Valid bytes written into tail_data */
        size_t tail_written;
    };
    union {
        int64_t tail_start;   /**< Absolute start offset of tail bytes */
        int64_t tail_base_offset;
    };
    size_t tail_capacity;     /**< Allocated capacity of tail_data */

    /* ---------------------------------------------------------------------- */
    /* 4. Boundaries and Container Detection State                            */
    /* ---------------------------------------------------------------------- */
    int64_t audio_start;      /**< Absolute offset where pure audio begins */
    int64_t audio_end;        /**< Absolute offset where pure audio ends (-1 if unknown) */
    ma_bool32 head_locked;    /**< 1 once audio_start is determined */
    ma_bool32 tail_locked;    /**< 1 once audio_end is determined */
    ma_bool32 is_decoding_audio; /**< 1 after ma_decoder_init; activates EOF at audio_end */
    map_container_format_t container_format;

    /* Offsets for synthesized container headers */
    int64_t wav_data_size_field_offset; /**< Offset of uint32 data chunk size in WAV */
    int64_t mp4_mdat_atom_offset;       /**< Offset of mdat atom header in MP4 */
    uint32_t mp4_mdat_header_size;      /**< 8 or 16 bytes */
    int32_t head_has_mpeg_frame;        /**< 1 if Xing/Info MPEG frame is in Head */
    uint32_t bytes_per_frame;           /**< PCM frame size in bytes (e.g. 6 for 24-bit stereo WAV), or 1 */

    /* ---------------------------------------------------------------------- */
    /* 5. Livestream ICY Metadata & Versioning                                */
    /* ---------------------------------------------------------------------- */
    uint8_t *icy_meta_data;   /**< Latest ICY metadata block */
    size_t icy_meta_size;
    uint32_t meta_version;    /**< Increments whenever Head, Tail, or ICY updates */

    /* ---------------------------------------------------------------------- */
    /* 6. Synchronization                                                     */
    /* ---------------------------------------------------------------------- */
    ma_mutex lock;            /**< Mutex protecting buffer bounds and state */
    ma_event data_ready_event;/**< Event signaling available data to decoder thread */
    ma_bool32 is_initialized; /**< 1 if buffer is valid and initialized */
} map_buffer_t;

/**
 * @brief Sets or updates pinned head data (e.g. format probe headers).
 */
ma_result map_buffer_set_head(
    map_buffer_t *mb,
    const uint8_t *head_data,
    size_t head_size);

/**
 * @brief Sets optional tail probe data (e.g. MP4 moov box located at EOF).
 */
ma_result map_buffer_set_tail(
    map_buffer_t *mb,
    const uint8_t *tail_data,
    size_t tail_size);

/**
 * @brief Probes tail bytes to detect trailing tags (ID3v1, APEv2, Lyrics3) and lock audio_end.
 */
ma_result map_buffer_probe_tail(
    map_buffer_t *mb,
    const uint8_t *tail_data,
    size_t tail_size,
    int64_t tail_offset);

/**
 * @brief Marks that audio frame decoding has begun, activating EOF protection at audio_end.
 */
void map_buffer_set_decoding_audio(
    map_buffer_t *mb,
    ma_bool32 decoding);

/**
 * @brief Overrides or sets audio_start boundary.
 */
void map_buffer_set_audio_start(
    map_buffer_t *mb,
    int64_t audio_start);

/**
 * @brief Ingests or updates ICY metadata chunk in livestreams.
 */
ma_result map_buffer_set_icy_meta(
    map_buffer_t *mb,
    const uint8_t *data,
    size_t size);

/**
 * @brief Returns the current metadata version counter (0 if none available yet).
 */
uint32_t map_buffer_get_meta_version(
    const map_buffer_t *mb);

/**
 * @brief Computes the exact byte length of the synthesized .metaBytes container.
 */
size_t map_buffer_get_meta_bytes_size(
    const map_buffer_t *mb);

/**
 * @brief Copies synthesized .metaBytes into out_buffer up to max_len.
 * @return Number of bytes actually written.
 */
size_t map_buffer_copy_meta_bytes(
    const map_buffer_t *mb,
    uint8_t *out_buffer,
    size_t max_len);

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
 * Serves directly from RAM if present within [range_start, range_end), Head, or Tail.
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
 * @brief Attempts to seek to target_offset within the existing RAM ring buffer.
 * @param mb Buffer instance.
 * @param target_offset Desired stream byte offset.
 * @param out_seek_from_start Set to MA_TRUE if the ring holds contiguous audio from audio_start.
 * @return 1 on RAM cache HIT, 0 on cache MISS (flushes ring window to target_offset and enters BUFFERING).
 */
int32_t map_buffer_try_seek_cached(
    map_buffer_t *mb,
    int64_t target_offset,
    ma_bool32 *out_seek_from_start);

/**
 * @brief Clears the abort flag on the buffer after decoder synchronization.
 */
void map_buffer_clear_abort(map_buffer_t *mb);

/**
 * @brief Returns MA_TRUE if the buffer is actively starving for producer bytes (not EOF).
 */
ma_bool32 map_buffer_is_starving(const map_buffer_t *mb);

/**
 * @brief Returns MA_TRUE if the buffer reached EOF and all buffered audio bytes have been consumed.
 */
ma_bool32 map_buffer_is_eof_and_exhausted(const map_buffer_t *mb);

/**
 * @brief Explicitly sets or clears the buffering state on the buffer.
 */
void map_buffer_set_buffering(map_buffer_t *mb, ma_bool32 buffering);

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
