/**
 * @file map_sniffer.h
 * @brief Audio stream format detection, header sniffing and duration estimation.
 */

#ifndef MAP_SNIFFER_H
#define MAP_SNIFFER_H

#include "miniaudio.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Sniffs MP3 stream header information (ID3v2, MPEG frames, Xing/Info/VBRI tags).
 *
 * @param data Pointer to initial buffered stream bytes.
 * @param data_size Size of initial buffered stream bytes.
 * @param total_size Total stream size in bytes (from Content-Length) or <= 0 if unknown.
 * @param out_bitrate Output bitrate in bits per second (bps).
 * @param out_duration_ms Output estimated duration in milliseconds.
 * @return MA_TRUE if valid MPEG audio frame was found and parsed, MA_FALSE otherwise.
 */
ma_bool32 map_sniff_mp3_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms);

/**
 * @brief Sniffs Ogg Vorbis stream header information (OggS page and vorbis identification header).
 *
 * @param data Pointer to initial buffered stream bytes.
 * @param data_size Size of initial buffered stream bytes.
 * @param total_size Total stream size in bytes (from Content-Length) or <= 0 if unknown.
 * @param out_bitrate Output bitrate in bits per second (bps).
 * @param out_duration_ms Output estimated duration in milliseconds.
 * @return MA_TRUE if valid Vorbis identification header was found and parsed, MA_FALSE otherwise.
 */
ma_bool32 map_sniff_ogg_vorbis_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms);

/**
 * @brief Sniffs Ogg Opus stream header information (OggS page and OpusHead).
 *
 * @param data Pointer to initial buffered stream bytes.
 * @param data_size Size of initial buffered stream bytes.
 * @param total_size Total stream size in bytes (from Content-Length) or <= 0 if unknown.
 * @param out_bitrate Output bitrate in bits per second (bps).
 * @param out_duration_ms Output estimated duration in milliseconds.
 * @return MA_TRUE if valid OpusHead was found and parsed, MA_FALSE otherwise.
 */
ma_bool32 map_sniff_ogg_opus_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms);

/**
 * @brief Generic stream sniffing helper that probes supported formats in order.
 *
 * @param data Pointer to initial buffered stream bytes.
 * @param data_size Size of initial buffered stream bytes.
 * @param total_size Total stream size in bytes or <= 0 if unknown.
 * @param out_bitrate Output bitrate in bits per second (bps).
 * @param out_duration_ms Output estimated duration in milliseconds.
 * @return MA_TRUE if any format matched and produced duration > 0, MA_FALSE otherwise.
 */
ma_bool32 map_sniff_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms);

/* ========================================================================= */
/* Tripartite boundary detection (HEAD | PURE AUDIO | TAIL)                  */
/* ========================================================================= */

/**
 * @brief Container format detected for boundary scanning and .metaBytes synthesis.
 */
typedef enum map_container_format
{
    MAP_CONTAINER_UNKNOWN = 0,
    MAP_CONTAINER_MP3 = 1,        /**< MPEG-1/2/2.5 Audio (with ID3v2 / ID3v1 / APEv2) */
    MAP_CONTAINER_ADTS = 2,       /**< AAC ADTS stream (with ID3v2 / ID3v1 / APEv2) */
    MAP_CONTAINER_FLAC = 3,       /**< Native FLAC ("fLaC" + METADATA_BLOCKs) */
    MAP_CONTAINER_OGG_VORBIS = 4, /**< Ogg Vorbis (3 header packets) */
    MAP_CONTAINER_OGG_OPUS = 5,   /**< Ogg Opus (OpusHead + OpusTags) */
    MAP_CONTAINER_WAV = 6,        /**< RIFF / RF64 WAVE */
    MAP_CONTAINER_MP4 = 7         /**< ISO BMFF (ftyp, moov, mdat, udta) */
} map_container_format_t;

/**
 * @brief Result of a boundary scan.
 */
typedef enum map_boundary_status
{
    MAP_BOUNDARY_UNSUPPORTED = -1, /**< Unknown container or malformed structure */
    MAP_BOUNDARY_NEED_MORE = 0,    /**< More bytes are required (see needed_bytes) */
    MAP_BOUNDARY_FOUND = 1         /**< Boundary determined exactly */
} map_boundary_status_t;

/**
 * @brief Boundary information produced by map_sniffer_detect_head_boundary().
 */
typedef struct map_boundary_info
{
    map_container_format_t container;
    int64_t audio_start;                /**< First byte of pure audio (HEAD = [0 .. audio_start)) */
    int64_t audio_end;                  /**< One past the last pure audio byte, or -1 if it requires a tail scan */
    int64_t wav_data_size_field_offset; /**< Offset of the uint32 'data' chunk size field (WAV), or -1 */
    int64_t mp4_mdat_atom_offset;       /**< Offset of the 'mdat' atom header (MP4), or -1 */
    uint32_t mp4_mdat_header_size;      /**< 8 or 16 (largesize) */
    int32_t head_has_mpeg_frame;        /**< 1 if the Xing/Info/VBRI MPEG frame is retained at the end of HEAD */
    int64_t needed_bytes;               /**< When NEED_MORE: minimum prefix length required to make progress */
} map_boundary_info_t;

/** Initializes a boundary info struct with "unknown" sentinels. */
void map_boundary_info_reset(map_boundary_info_t *info);

/**
 * @brief Scans the stream prefix and determines `audio_start` (and `audio_end`
 * for containers that declare it in the header, i.e. WAV and MP4).
 *
 * @param data Prefix bytes [0 .. available).
 * @param available Number of valid prefix bytes.
 * @param total_size Total stream size or <= 0 if unknown.
 * @param out Output boundary information.
 */
map_boundary_status_t map_sniffer_detect_head_boundary(
    const uint8_t *data,
    size_t available,
    int64_t total_size,
    map_boundary_info_t *out);

/**
 * @brief Scans the final bytes of the stream backwards for trailing tags
 * (ID3v1, ID3v1 Enhanced, APEv2/APEv1, Lyrics3v2, ID3v2 footer) and computes `audio_end`.
 *
 * @param container Container detected in the head scan.
 * @param tail Bytes of the range [tail_offset .. tail_offset + tail_len). Must end at total_size.
 * @param tail_len Number of bytes.
 * @param tail_offset Absolute offset of tail[0].
 * @param total_size Total stream size (> 0).
 * @param audio_start Previously detected audio_start (lower clamp).
 * @param out_audio_end Output audio_end.
 * @return FOUND when audio_end is exact, NEED_MORE when a tag footer needs bytes before tail_offset
 *         (out_audio_end is still filled with the best known value), UNSUPPORTED on invalid args.
 */
map_boundary_status_t map_sniffer_detect_tail_boundary(
    map_container_format_t container,
    const uint8_t *tail,
    size_t tail_len,
    int64_t tail_offset,
    int64_t total_size,
    int64_t audio_start,
    int64_t *out_audio_end);

/** Returns 1 if the container may carry trailing tags that require a tail scan. */
int map_container_needs_tail_scan(map_container_format_t container);

#ifdef __cplusplus
}
#endif

#endif /* MAP_SNIFFER_H */
