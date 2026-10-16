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

#ifdef __cplusplus
}
#endif

#endif /* MAP_SNIFFER_H */
