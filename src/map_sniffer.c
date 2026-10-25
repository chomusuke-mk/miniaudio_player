/**
 * @file map_sniffer.c
 * @brief Audio stream format detection, header sniffing and duration estimation.
 */

#include "map_sniffer.h"
#include <string.h>

ma_bool32 map_sniff_mp3_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms)
{
    size_t start_offset = 0;
    uint32_t id3_total_size = 0;
    size_t scan_limit;

    if (data == NULL || data_size < 10 || out_bitrate == NULL || out_duration_ms == NULL)
    {
        return MA_FALSE;
    }

    /* 1. Skip ID3v2 tag if present */
    if (data[0] == 'I' && data[1] == 'D' && data[2] == '3')
    {
        uint32_t id3_size = ((uint32_t)(data[6] & 0x7F) << 21) |
                            ((uint32_t)(data[7] & 0x7F) << 14) |
                            ((uint32_t)(data[8] & 0x7F) << 7)  |
                            ((uint32_t)(data[9] & 0x7F));
        id3_total_size = 10 + id3_size;
        if (data[5] & 0x10) /* ID3v2.4 footer */
        {
            id3_total_size += 10;
        }

        if (id3_total_size < data_size)
        {
            start_offset = id3_total_size;
        }
        else
        {
            start_offset = data_size;
        }
    }

    if (start_offset + 4 > data_size)
    {
        return MA_FALSE;
    }

    /* 2. Scan for valid MPEG audio sync word (0xFFE0) */
    scan_limit = (start_offset + 32768 < data_size) ? (start_offset + 32768) : data_size;
    for (size_t i = start_offset; i + 4 <= scan_limit; i++)
    {
        if (data[i] == 0xFF && (data[i + 1] & 0xE0) == 0xE0)
        {
            uint8_t b1 = data[i + 1];
            uint8_t b2 = data[i + 2];
            uint8_t b3 = data[i + 3];

            uint32_t ver = (b1 >> 3) & 0x03;
            uint32_t layer = (b1 >> 1) & 0x03;
            if (ver == 1 || layer == 0) continue; /* ver 1 is reserved; layer 0 is reserved */

            uint32_t br_idx = (b2 >> 4) & 0x0F;
            if (br_idx == 0 || br_idx == 15) continue; /* 0 is free, 15 is bad */

            uint32_t sr_idx = (b2 >> 2) & 0x03;
            if (sr_idx == 3) continue; /* 3 is reserved */

            uint32_t padding = (b2 >> 1) & 0x01;
            uint32_t channel_mode = (b3 >> 6) & 0x03;
            int has_crc = !(b1 & 0x01);

            static const uint32_t s_mpeg1_l3_bitrates[16] = {
                0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0
            };
            static const uint32_t s_mpeg1_l2_bitrates[16] = {
                0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0
            };
            static const uint32_t s_mpeg1_l1_bitrates[16] = {
                0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0
            };
            static const uint32_t s_mpeg2_l1_bitrates[16] = {
                0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0
            };
            static const uint32_t s_mpeg2_l23_bitrates[16] = {
                0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0
            };

            uint32_t bitrate_kbps = 0;
            if (ver == 3) /* MPEG-1 */
            {
                if (layer == 1) bitrate_kbps = s_mpeg1_l3_bitrates[br_idx];
                else if (layer == 2) bitrate_kbps = s_mpeg1_l2_bitrates[br_idx];
                else if (layer == 3) bitrate_kbps = s_mpeg1_l1_bitrates[br_idx];
            }
            else /* MPEG-2 or MPEG-2.5 */
            {
                if (layer == 3) bitrate_kbps = s_mpeg2_l1_bitrates[br_idx];
                else bitrate_kbps = s_mpeg2_l23_bitrates[br_idx];
            }
            if (bitrate_kbps == 0) continue;

            static const uint32_t s_sample_rates[4][3] = {
                {11025, 12000, 8000},  /* MPEG-2.5 (ver == 0) */
                {0, 0, 0},             /* Reserved (ver == 1) */
                {22050, 24000, 16000},  /* MPEG-2   (ver == 2) */
                {44100, 48000, 32000}   /* MPEG-1   (ver == 3) */
            };
            uint32_t frame_sample_rate = s_sample_rates[ver][sr_idx];
            if (frame_sample_rate == 0) continue;

            uint32_t samples_per_frame = 0;
            uint32_t frame_size = 0;

            if (layer == 3) /* Layer I */
            {
                samples_per_frame = 384;
                frame_size = (12 * bitrate_kbps * 1000 / frame_sample_rate + padding) * 4;
            }
            else if (layer == 2) /* Layer II */
            {
                samples_per_frame = 1152;
                frame_size = 144 * bitrate_kbps * 1000 / frame_sample_rate + padding;
            }
            else /* Layer III */
            {
                samples_per_frame = (ver == 3) ? 1152 : 576;
                if (ver == 3)
                {
                    frame_size = 144 * bitrate_kbps * 1000 / frame_sample_rate + padding;
                }
                else
                {
                    frame_size = 72 * bitrate_kbps * 1000 / frame_sample_rate + padding;
                }
            }
            if (frame_size == 0) continue;

            /* Verify subsequent sync word if within buffer */
            if (i + frame_size + 4 <= data_size)
            {
                if (data[i + frame_size] != 0xFF || (data[i + frame_size + 1] & 0xE0) != 0xE0)
                {
                    continue; /* Possible false sync */
                }
            }

            /* Check for Xing / Info header (VBR metadata) */
            size_t side_info = 0;
            if (layer == 1)
            {
                if (ver == 3)
                {
                    side_info = (channel_mode == 3) ? 17 : 32;
                }
                else
                {
                    side_info = (channel_mode == 3) ? 9 : 17;
                }
            }

            size_t xing_offset = 4 + (has_crc ? 2 : 0) + side_info;
            if (layer == 1 && i + xing_offset + 12 <= data_size)
            {
                const uint8_t *tag = data + i + xing_offset;
                if ((tag[0] == 'X' && tag[1] == 'i' && tag[2] == 'n' && tag[3] == 'g') ||
                    (tag[0] == 'I' && tag[1] == 'n' && tag[2] == 'f' && tag[3] == 'o'))
                {
                    uint32_t flags = ((uint32_t)tag[4] << 24) | ((uint32_t)tag[5] << 16) |
                                     ((uint32_t)tag[6] << 8)  | (uint32_t)tag[7];
                    if (flags & 0x01) /* Frames field present */
                    {
                        uint32_t total_mpeg_frames = ((uint32_t)tag[8] << 24) | ((uint32_t)tag[9] << 16) |
                                                     ((uint32_t)tag[10] << 8) | (uint32_t)tag[11];
                        uint64_t total_pcm = (uint64_t)total_mpeg_frames * (uint64_t)samples_per_frame;
                        *out_duration_ms = (int64_t)((double)total_pcm * 1000.0 / (double)frame_sample_rate + 0.5);
                        if ((flags & 0x02) && *out_duration_ms > 0)
                        {
                            uint32_t total_audio_bytes = ((uint32_t)tag[12] << 24) | ((uint32_t)tag[13] << 16) |
                                                         ((uint32_t)tag[14] << 8)  | (uint32_t)tag[15];
                            *out_bitrate = (uint32_t)(((uint64_t)total_audio_bytes * 8000ULL) / (uint64_t)*out_duration_ms);
                        }
                        else if (total_size > 0 && *out_duration_ms > 0)
                        {
                            *out_bitrate = (uint32_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)*out_duration_ms);
                        }
                        else
                        {
                            *out_bitrate = bitrate_kbps * 1000;
                        }
                        return MA_TRUE;
                    }
                }
            }

            /* Check for Fraunhofer VBRI header */
            size_t vbri_offset = 4 + (has_crc ? 2 : 0) + 32;
            if (layer == 1 && i + vbri_offset + 18 <= data_size)
            {
                const uint8_t *tag = data + i + vbri_offset;
                if (tag[0] == 'V' && tag[1] == 'B' && tag[2] == 'R' && tag[3] == 'I')
                {
                    uint32_t total_mpeg_frames = ((uint32_t)tag[14] << 24) | ((uint32_t)tag[15] << 16) |
                                                 ((uint32_t)tag[16] << 8)  | (uint32_t)tag[17];
                    uint64_t total_pcm = (uint64_t)total_mpeg_frames * (uint64_t)samples_per_frame;
                    *out_duration_ms = (int64_t)((double)total_pcm * 1000.0 / (double)frame_sample_rate + 0.5);
                    if (*out_duration_ms > 0)
                    {
                        uint32_t total_audio_bytes = ((uint32_t)tag[10] << 24) | ((uint32_t)tag[11] << 16) |
                                                     ((uint32_t)tag[12] << 8)  | (uint32_t)tag[13];
                        *out_bitrate = (uint32_t)(((uint64_t)total_audio_bytes * 8000ULL) / (uint64_t)*out_duration_ms);
                    }
                    else
                    {
                        *out_bitrate = bitrate_kbps * 1000;
                    }
                    return MA_TRUE;
                }
            }

            /* Standard CBR MP3 */
            *out_bitrate = bitrate_kbps * 1000;
            if (total_size > 0)
            {
                uint64_t audio_bytes = (total_size > (int64_t)id3_total_size) ?
                                       (uint64_t)(total_size - (int64_t)id3_total_size) :
                                       (uint64_t)total_size;
                *out_duration_ms = (int64_t)((audio_bytes * 8000ULL) / (uint64_t)*out_bitrate);
            }
            else
            {
                *out_duration_ms = 0;
            }
            return MA_TRUE;
        }
    }

    return MA_FALSE;
}

ma_bool32 map_sniff_ogg_vorbis_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms)
{
    if (data == NULL || data_size < 40 || out_bitrate == NULL || out_duration_ms == NULL)
    {
        return MA_FALSE;
    }

    if (memcmp(data, "OggS", 4) != 0)
    {
        return MA_FALSE;
    }

    size_t scan_limit = data_size > 4096 ? 4096 : data_size;
    for (size_t i = 0; i + 28 <= scan_limit; i++)
    {
        if (memcmp(data + i, "\x01vorbis", 7) == 0)
        {
            uint32_t sample_rate = (uint32_t)data[i + 12] |
                                  ((uint32_t)data[i + 13] << 8) |
                                  ((uint32_t)data[i + 14] << 16) |
                                  ((uint32_t)data[i + 15] << 24);
            int32_t bitrate_nominal = (int32_t)(
                (uint32_t)data[i + 20] |
                ((uint32_t)data[i + 21] << 8) |
                ((uint32_t)data[i + 22] << 16) |
                ((uint32_t)data[i + 23] << 24));
            int32_t bitrate_max = (int32_t)(
                (uint32_t)data[i + 16] |
                ((uint32_t)data[i + 17] << 8) |
                ((uint32_t)data[i + 18] << 16) |
                ((uint32_t)data[i + 19] << 24));

            if (total_size > 0 && (int64_t)data_size >= total_size && sample_rate > 0)
            {
                size_t scan_start = data_size >= 27 ? data_size - 27 : 0;
                size_t min_scan = (data_size > 65536) ? (data_size - 65536) : 0;
                for (size_t j = scan_start; j >= min_scan; j--)
                {
                    if (memcmp(data + j, "OggS", 4) == 0 && data[j + 4] == 0)
                    {
                        uint64_t granule_pos = (uint64_t)data[j + 6] |
                                               ((uint64_t)data[j + 7] << 8) |
                                               ((uint64_t)data[j + 8] << 16) |
                                               ((uint64_t)data[j + 9] << 24) |
                                               ((uint64_t)data[j + 10] << 32) |
                                               ((uint64_t)data[j + 11] << 40) |
                                               ((uint64_t)data[j + 12] << 48) |
                                               ((uint64_t)data[j + 13] << 56);
                        if (granule_pos > 0 && granule_pos != (uint64_t)-1)
                        {
                            int64_t dur_ms = (int64_t)((granule_pos * 1000ULL) / (uint64_t)sample_rate);
                            if (dur_ms > 0)
                            {
                                *out_duration_ms = dur_ms;
                                *out_bitrate = (uint32_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)dur_ms);
                                return MA_TRUE;
                            }
                        }
                    }
                    if (j == 0) break;
                }
            }

            uint32_t br = 0;
            if (bitrate_nominal > 0)
            {
                br = (uint32_t)bitrate_nominal;
            }
            else if (bitrate_max > 0)
            {
                br = (uint32_t)bitrate_max;
            }

            if (br > 0)
            {
                *out_bitrate = br;
                if (total_size > 0)
                {
                    *out_duration_ms = (int64_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)br);
                }
                else
                {
                    *out_duration_ms = 0;
                }
                return MA_TRUE;
            }
        }
    }
    return MA_FALSE;
}

ma_bool32 map_sniff_ogg_opus_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms)
{
    if (data == NULL || data_size < 40 || out_bitrate == NULL || out_duration_ms == NULL)
    {
        return MA_FALSE;
    }

    if (memcmp(data, "OggS", 4) != 0)
    {
        return MA_FALSE;
    }

    size_t scan_limit = data_size > 4096 ? 4096 : data_size;
    for (size_t i = 0; i + 19 <= scan_limit; i++)
    {
        if (memcmp(data + i, "OpusHead", 8) == 0)
        {
            if (total_size > 0 && (int64_t)data_size >= total_size)
            {
                size_t scan_start = data_size >= 27 ? data_size - 27 : 0;
                size_t min_scan = (data_size > 65536) ? (data_size - 65536) : 0;
                for (size_t j = scan_start; j >= min_scan; j--)
                {
                    if (memcmp(data + j, "OggS", 4) == 0 && data[j + 4] == 0)
                    {
                        uint64_t granule_pos = (uint64_t)data[j + 6] |
                                               ((uint64_t)data[j + 7] << 8) |
                                               ((uint64_t)data[j + 8] << 16) |
                                               ((uint64_t)data[j + 9] << 24) |
                                               ((uint64_t)data[j + 10] << 32) |
                                               ((uint64_t)data[j + 11] << 40) |
                                               ((uint64_t)data[j + 12] << 48) |
                                               ((uint64_t)data[j + 13] << 56);
                        if (granule_pos > 0 && granule_pos != (uint64_t)-1)
                        {
                            int64_t dur_ms = (int64_t)((granule_pos * 1000ULL) / 48000ULL);
                            if (dur_ms > 0)
                            {
                                *out_duration_ms = dur_ms;
                                *out_bitrate = (uint32_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)dur_ms);
                                return MA_TRUE;
                            }
                        }
                    }
                    if (j == 0) break;
                }
            }

            uint8_t channels = data[i + 9];
            uint32_t br = (channels >= 2) ? 128000 : 64000;
            *out_bitrate = br;
            if (total_size > 0)
            {
                *out_duration_ms = (int64_t)(((uint64_t)total_size * 8000ULL) / (uint64_t)br);
            }
            else
            {
                *out_duration_ms = 0;
            }
            return MA_TRUE;
        }
    }
    return MA_FALSE;
}

ma_bool32 map_sniff_stream_info(
    const uint8_t *data,
    size_t data_size,
    int64_t total_size,
    uint32_t *out_bitrate,
    int64_t *out_duration_ms)
{
    if (map_sniff_mp3_stream_info(data, data_size, total_size, out_bitrate, out_duration_ms))
    {
        return MA_TRUE;
    }
    if (map_sniff_ogg_vorbis_stream_info(data, data_size, total_size, out_bitrate, out_duration_ms))
    {
        return MA_TRUE;
    }
    if (map_sniff_ogg_opus_stream_info(data, data_size, total_size, out_bitrate, out_duration_ms))
    {
        return MA_TRUE;
    }
    return MA_FALSE;
}

/* ========================================================================= */
/* Tripartite boundary detection (HEAD | PURE AUDIO | TAIL)                  */
/* ========================================================================= */

/** Hard upper bound for any header structure we are willing to scan (64 MB). */
#define MAP_SNIFF_MAX_HEAD_SCAN ((int64_t)64 * 1024 * 1024)
/** Maximum distance scanned for the first MPEG / ADTS sync word after the tags. */
#define MAP_SNIFF_SYNC_SCAN_LIMIT ((int64_t)64 * 1024)

static uint32_t map_rd_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t map_rd_be64(const uint8_t *p)
{
    return ((uint64_t)map_rd_be32(p) << 32) | (uint64_t)map_rd_be32(p + 4);
}

static uint16_t map_rd_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t map_rd_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t map_rd_le64(const uint8_t *p)
{
    return (uint64_t)map_rd_le32(p) | ((uint64_t)map_rd_le32(p + 4) << 32);
}

static uint32_t map_rd_synchsafe32(const uint8_t *p)
{
    return ((uint32_t)(p[0] & 0x7F) << 21) | ((uint32_t)(p[1] & 0x7F) << 14) |
           ((uint32_t)(p[2] & 0x7F) << 7) | (uint32_t)(p[3] & 0x7F);
}

void map_boundary_info_reset(map_boundary_info_t *info)
{
    if (info == NULL)
        return;
    memset(info, 0, sizeof(*info));
    info->container = MAP_CONTAINER_UNKNOWN;
    info->audio_start = 0;
    info->audio_end = -1;
    info->wav_data_size_field_offset = -1;
    info->mp4_mdat_atom_offset = -1;
    info->mp4_mdat_header_size = 0;
    info->head_has_mpeg_frame = 0;
    info->bytes_per_frame = 1;
    info->needed_bytes = 0;
}

int map_container_needs_tail_scan(map_container_format_t container)
{
    return (container == MAP_CONTAINER_MP3 ||
            container == MAP_CONTAINER_ADTS ||
            container == MAP_CONTAINER_FLAC) ? 1 : 0;
}

/* Returns NEED_MORE (with needed_bytes) or UNSUPPORTED when the stream already ended. */
static map_boundary_status_t map_sniff_need_more(
    map_boundary_info_t *out,
    int64_t needed,
    int64_t total_size,
    size_t available)
{
    if (needed > MAP_SNIFF_MAX_HEAD_SCAN)
    {
        return MAP_BOUNDARY_UNSUPPORTED;
    }
    if (total_size > 0 && needed > total_size)
    {
        needed = total_size;
    }
    if (needed <= (int64_t)available)
    {
        /* The whole stream is available but the structure never completed: malformed. */
        return MAP_BOUNDARY_UNSUPPORTED;
    }
    out->needed_bytes = needed;
    return MAP_BOUNDARY_NEED_MORE;
}

typedef struct map_mpeg_header
{
    uint32_t frame_size;
    uint32_t side_info;
    uint32_t layer; /* 1 = Layer III, 2 = Layer II, 3 = Layer I */
    uint32_t has_crc;
} map_mpeg_header_t;

static int map_mpeg_parse_header(const uint8_t *h, map_mpeg_header_t *out)
{
    static const uint32_t s_mpeg1_l3[16] = {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0};
    static const uint32_t s_mpeg1_l2[16] = {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0};
    static const uint32_t s_mpeg1_l1[16] = {0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0};
    static const uint32_t s_mpeg2_l1[16] = {0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0};
    static const uint32_t s_mpeg2_l23[16] = {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0};
    static const uint32_t s_rates[4][3] = {
        {11025, 12000, 8000}, {0, 0, 0}, {22050, 24000, 16000}, {44100, 48000, 32000}};

    if (h[0] != 0xFF || (h[1] & 0xE0) != 0xE0)
        return 0;

    uint32_t ver = (h[1] >> 3) & 0x03;
    uint32_t layer = (h[1] >> 1) & 0x03;
    uint32_t br_idx = (h[2] >> 4) & 0x0F;
    uint32_t sr_idx = (h[2] >> 2) & 0x03;
    uint32_t padding = (h[2] >> 1) & 0x01;
    uint32_t channel_mode = (h[3] >> 6) & 0x03;

    if (ver == 1 || layer == 0 || br_idx == 0 || br_idx == 15 || sr_idx == 3)
        return 0;
    if ((h[3] & 0x03) == 2) /* reserved emphasis */
        return 0;

    uint32_t kbps;
    if (ver == 3)
        kbps = (layer == 1) ? s_mpeg1_l3[br_idx] : (layer == 2) ? s_mpeg1_l2[br_idx] : s_mpeg1_l1[br_idx];
    else
        kbps = (layer == 3) ? s_mpeg2_l1[br_idx] : s_mpeg2_l23[br_idx];

    uint32_t sr = s_rates[ver][sr_idx];
    if (kbps == 0 || sr == 0)
        return 0;

    uint32_t fs;
    if (layer == 3)
        fs = (12 * kbps * 1000 / sr + padding) * 4;
    else if (layer == 2 || ver == 3)
        fs = 144 * kbps * 1000 / sr + padding;
    else
        fs = 72 * kbps * 1000 / sr + padding;
    if (fs < 4)
        return 0;

    out->frame_size = fs;
    out->layer = layer;
    out->has_crc = (h[1] & 0x01) ? 0 : 1;
    out->side_info = 0;
    if (layer == 1)
    {
        if (ver == 3)
            out->side_info = (channel_mode == 3) ? 17 : 32;
        else
            out->side_info = (channel_mode == 3) ? 9 : 17;
    }
    return 1;
}

static int map_adts_is_sync(const uint8_t *h)
{
    return h[0] == 0xFF && (h[1] & 0xF6) == 0xF0 &&
           ((h[2] >> 6) & 0x03) != 3 && ((h[2] >> 2) & 0x0F) <= 11;
}

static map_boundary_status_t map_sniff_detect_mpeg(
    const uint8_t *d,
    size_t avail,
    int64_t total,
    int64_t p,
    map_boundary_info_t *out)
{
    int64_t limit = p + MAP_SNIFF_SYNC_SCAN_LIMIT;

    for (int64_t i = p; i < limit; i++)
    {
        if (total > 0 && i + 4 > total)
            return MAP_BOUNDARY_UNSUPPORTED;
        if (i + 7 > (int64_t)avail)
            return map_sniff_need_more(out, i + 7, total, avail);

        const uint8_t *h = d + i;
        if (h[0] != 0xFF)
            continue;

        /* AAC ADTS */
        if (map_adts_is_sync(h))
        {
            uint32_t flen = ((uint32_t)(h[3] & 0x03) << 11) | ((uint32_t)h[4] << 3) | ((uint32_t)h[5] >> 5);
            if (flen < 7)
                continue;
            int64_t next = i + (int64_t)flen;
            if (next + 2 <= (int64_t)avail)
            {
                if (!map_adts_is_sync(d + next) && !(next + 2 <= (int64_t)avail && d[next] == 0xFF && (d[next + 1] & 0xF6) == 0xF0))
                    continue;
            }
            else if (total <= 0 || next + 2 <= total)
            {
                return map_sniff_need_more(out, next + 7, total, avail);
            }
            out->container = MAP_CONTAINER_ADTS;
            out->audio_start = i;
            out->audio_end = -1;
            return MAP_BOUNDARY_FOUND;
        }

        /* MPEG audio */
        map_mpeg_header_t hdr;
        if (!map_mpeg_parse_header(h, &hdr))
            continue;

        int64_t next = i + (int64_t)hdr.frame_size;
        if (next + 4 <= (int64_t)avail)
        {
            map_mpeg_header_t nh;
            if (!map_mpeg_parse_header(d + next, &nh))
                continue; /* false sync */
        }
        else if (total <= 0 || next + 4 <= total)
        {
            return map_sniff_need_more(out, next + 4, total, avail);
        }

        out->container = MAP_CONTAINER_MP3;
        out->audio_start = i;
        out->audio_end = -1;

        /* Xing / Info / VBRI frame: it carries no audio, so it belongs to HEAD. */
        if (hdr.layer == 1 && next <= (int64_t)avail)
        {
            int64_t xing = i + 4 + (hdr.has_crc ? 2 : 0) + hdr.side_info;
            int64_t vbri = i + 4 + 32;
            int is_vbr_frame = 0;
            if (xing + 4 <= next)
            {
                const uint8_t *t = d + xing;
                if ((t[0] == 'X' && t[1] == 'i' && t[2] == 'n' && t[3] == 'g') ||
                    (t[0] == 'I' && t[1] == 'n' && t[2] == 'f' && t[3] == 'o'))
                    is_vbr_frame = 1;
            }
            if (!is_vbr_frame && vbri + 4 <= next)
            {
                const uint8_t *t = d + vbri;
                if (t[0] == 'V' && t[1] == 'B' && t[2] == 'R' && t[3] == 'I')
                    is_vbr_frame = 1;
            }
            if (is_vbr_frame)
            {
                out->audio_start = next;
                out->head_has_mpeg_frame = 1;
            }
        }
        return MAP_BOUNDARY_FOUND;
    }
    return MAP_BOUNDARY_UNSUPPORTED;
}

static map_boundary_status_t map_sniff_detect_flac(
    const uint8_t *d,
    size_t avail,
    int64_t total,
    int64_t p,
    map_boundary_info_t *out)
{
    int64_t q = p + 4;
    int first = 1;
    for (;;)
    {
        if (q + 4 > (int64_t)avail)
            return map_sniff_need_more(out, q + 4, total, avail);

        uint8_t hb = d[q];
        int is_last = (hb & 0x80) != 0;
        int type = hb & 0x7F;
        if (type == 127 || (first && type != 0))
            return MAP_BOUNDARY_UNSUPPORTED;

        uint32_t len = ((uint32_t)d[q + 1] << 16) | ((uint32_t)d[q + 2] << 8) | (uint32_t)d[q + 3];
        q += 4 + (int64_t)len;
        first = 0;
        if (q > MAP_SNIFF_MAX_HEAD_SCAN || (total > 0 && q > total))
            return MAP_BOUNDARY_UNSUPPORTED;
        if (is_last)
        {
            out->container = MAP_CONTAINER_FLAC;
            out->audio_start = q; /* == firstFLACFramePosInBytes */
            out->audio_end = -1;
            return MAP_BOUNDARY_FOUND;
        }
    }
}

static map_boundary_status_t map_sniff_detect_ogg(
    const uint8_t *d,
    size_t avail,
    int64_t total,
    map_boundary_info_t *out)
{
    int64_t p = 0;
    uint32_t serial = 0;
    int have_serial = 0;
    int required = 0;
    int packets = 0;
    map_container_format_t container = MAP_CONTAINER_UNKNOWN;

    for (;;)
    {
        if (p + 27 > (int64_t)avail)
            return map_sniff_need_more(out, p + 27, total, avail);
        if (memcmp(d + p, "OggS", 4) != 0 || d[p + 4] != 0)
            return MAP_BOUNDARY_UNSUPPORTED;

        uint32_t nseg = d[p + 26];
        if (p + 27 + (int64_t)nseg > (int64_t)avail)
            return map_sniff_need_more(out, p + 27 + nseg, total, avail);

        int64_t body = 0;
        for (uint32_t i = 0; i < nseg; i++)
            body += d[p + 27 + i];
        int64_t body_start = p + 27 + nseg;
        int64_t page_end = body_start + body;
        uint32_t ser = map_rd_le32(d + p + 14);

        if (!have_serial)
        {
            if ((d[p + 5] & 0x02) == 0) /* must be BOS */
                return MAP_BOUNDARY_UNSUPPORTED;
            if (body_start + 8 > (int64_t)avail)
                return map_sniff_need_more(out, body_start + 8, total, avail);
            if (memcmp(d + body_start, "\x01vorbis", 7) == 0)
            {
                required = 3;
                container = MAP_CONTAINER_OGG_VORBIS;
            }
            else if (memcmp(d + body_start, "OpusHead", 8) == 0)
            {
                required = 2;
                container = MAP_CONTAINER_OGG_OPUS;
            }
            else
            {
                return MAP_BOUNDARY_UNSUPPORTED;
            }
            serial = ser;
            have_serial = 1;
        }

        if (ser == serial)
        {
            for (uint32_t i = 0; i < nseg; i++)
            {
                if (d[p + 27 + i] < 255)
                {
                    packets++;
                    if (packets >= required)
                    {
                        /* Header packets always finish their page: audio starts on a fresh page. */
                        out->container = container;
                        out->audio_start = page_end;
                        out->audio_end = (total > 0) ? total : -1;
                        return MAP_BOUNDARY_FOUND;
                    }
                }
            }
        }

        p = page_end;
        if (p > MAP_SNIFF_MAX_HEAD_SCAN || (total > 0 && p >= total))
            return MAP_BOUNDARY_UNSUPPORTED;
    }
}

static map_boundary_status_t map_sniff_detect_wav(
    const uint8_t *d,
    size_t avail,
    int64_t total,
    map_boundary_info_t *out)
{
    int rf64 = (memcmp(d, "RF64", 4) == 0);
    uint64_t ds64_data = 0;
    int64_t p = 12;

    for (;;)
    {
        if (p + 8 > (int64_t)avail)
            return map_sniff_need_more(out, p + 8, total, avail);

        const uint8_t *c = d + p;
        uint32_t size = map_rd_le32(c + 4);

        if (rf64 && memcmp(c, "ds64", 4) == 0)
        {
            if (p + 24 > (int64_t)avail)
                return map_sniff_need_more(out, p + 24, total, avail);
            ds64_data = map_rd_le64(c + 16);
        }

        if (memcmp(c, "fmt ", 4) == 0 && size >= 14)
        {
            if (p + 22 <= (int64_t)avail)
            {
                uint16_t block_align = map_rd_le16(c + 20);
                if (block_align > 0)
                {
                    out->bytes_per_frame = (uint32_t)block_align;
                }
            }
        }

        if (memcmp(c, "data", 4) == 0)
        {
            uint64_t data_size = size;
            if (rf64 && size == 0xFFFFFFFFu)
                data_size = ds64_data;

            out->container = MAP_CONTAINER_WAV;
            out->wav_data_size_field_offset = p + 4;
            out->audio_start = p + 8;
            if (data_size == 0 || data_size == 0xFFFFFFFFu)
            {
                /* Streaming WAV with unknown data size: audio runs until EOF. */
                out->audio_end = (total > 0) ? total : -1;
            }
            else
            {
                out->audio_end = out->audio_start + (int64_t)data_size;
                if (total > 0 && out->audio_end > total)
                    out->audio_end = total;
            }
            return MAP_BOUNDARY_FOUND;
        }

        p += 8 + (int64_t)size + (int64_t)(size & 1u);
        if (p > MAP_SNIFF_MAX_HEAD_SCAN || (total > 0 && p >= total))
            return MAP_BOUNDARY_UNSUPPORTED;
    }
}

static map_boundary_status_t map_sniff_detect_mp4(
    const uint8_t *d,
    size_t avail,
    int64_t total,
    map_boundary_info_t *out)
{
    int64_t p = 0;
    for (;;)
    {
        if (p + 8 > (int64_t)avail)
            return map_sniff_need_more(out, p + 8, total, avail);

        uint32_t size32 = map_rd_be32(d + p);
        const uint8_t *type = d + p + 4;
        uint64_t atom_size = size32;
        uint32_t hdr = 8;

        if (size32 == 1)
        {
            if (p + 16 > (int64_t)avail)
                return map_sniff_need_more(out, p + 16, total, avail);
            atom_size = map_rd_be64(d + p + 8);
            hdr = 16;
        }
        else if (size32 == 0)
        {
            atom_size = (total > 0) ? (uint64_t)(total - p) : 0;
        }

        if (memcmp(type, "mdat", 4) == 0)
        {
            out->container = MAP_CONTAINER_MP4;
            out->mp4_mdat_atom_offset = p;
            out->mp4_mdat_header_size = hdr;
            out->audio_start = p + hdr;
            if (size32 == 0)
                out->audio_end = (total > 0) ? total : -1;
            else
            {
                out->audio_end = p + (int64_t)atom_size;
                if (total > 0 && out->audio_end > total)
                    out->audio_end = total;
            }
            if (out->audio_end >= 0 && out->audio_end < out->audio_start)
                out->audio_end = out->audio_start;
            return MAP_BOUNDARY_FOUND;
        }

        if (memcmp(type, "moof", 4) == 0)
        {
            /* Fragmented MP4: every fragment after the init segment is media. */
            out->container = MAP_CONTAINER_MP4;
            out->mp4_mdat_atom_offset = -1;
            out->mp4_mdat_header_size = 0;
            out->audio_start = p;
            out->audio_end = (total > 0) ? total : -1;
            return MAP_BOUNDARY_FOUND;
        }

        if (atom_size < hdr)
            return MAP_BOUNDARY_UNSUPPORTED;

        p += (int64_t)atom_size;
        if (p > MAP_SNIFF_MAX_HEAD_SCAN || (total > 0 && p >= total))
            return MAP_BOUNDARY_UNSUPPORTED;
    }
}

map_boundary_status_t map_sniffer_detect_head_boundary(
    const uint8_t *data,
    size_t available,
    int64_t total_size,
    map_boundary_info_t *out)
{
    if (out == NULL)
        return MAP_BOUNDARY_UNSUPPORTED;
    map_boundary_info_reset(out);
    if (data == NULL && available > 0)
        return MAP_BOUNDARY_UNSUPPORTED;

    if (available < 12)
        return map_sniff_need_more(out, 12, total_size, available);

    if ((memcmp(data, "RIFF", 4) == 0 || memcmp(data, "RF64", 4) == 0) && memcmp(data + 8, "WAVE", 4) == 0)
        return map_sniff_detect_wav(data, available, total_size, out);
    if (memcmp(data, "fLaC", 4) == 0)
        return map_sniff_detect_flac(data, available, total_size, 0, out);
    if (memcmp(data, "OggS", 4) == 0)
        return map_sniff_detect_ogg(data, available, total_size, out);
    if (memcmp(data + 4, "ftyp", 4) == 0)
        return map_sniff_detect_mp4(data, available, total_size, out);

    /* Leading ID3v2 tags (possibly several) followed by MPEG, ADTS or FLAC. */
    int64_t p = 0;
    for (;;)
    {
        if (p + 10 > (int64_t)available)
            return map_sniff_need_more(out, p + 10, total_size, available);
        const uint8_t *t = data + p;
        if (t[0] == 'I' && t[1] == 'D' && t[2] == '3' && t[3] != 0xFF && t[4] != 0xFF &&
            ((t[6] | t[7] | t[8] | t[9]) & 0x80) == 0)
        {
            uint32_t tag_size = map_rd_synchsafe32(t + 6);
            uint32_t footer = (t[5] & 0x10) ? 10 : 0;
            p += 10 + (int64_t)tag_size + footer;
            if (p > MAP_SNIFF_MAX_HEAD_SCAN || (total_size > 0 && p > total_size))
                return MAP_BOUNDARY_UNSUPPORTED;
            continue;
        }
        break;
    }

    if (p + 4 > (int64_t)available)
        return map_sniff_need_more(out, p + 4, total_size, available);
    if (memcmp(data + p, "fLaC", 4) == 0)
        return map_sniff_detect_flac(data, available, total_size, p, out);

    return map_sniff_detect_mpeg(data, available, total_size, p, out);
}

map_boundary_status_t map_sniffer_detect_tail_boundary(
    map_container_format_t container,
    const uint8_t *tail,
    size_t tail_len,
    int64_t tail_offset,
    int64_t total_size,
    int64_t audio_start,
    int64_t *out_audio_end)
{
    if (out_audio_end == NULL || total_size <= 0)
        return MAP_BOUNDARY_UNSUPPORTED;

    *out_audio_end = total_size;
    if (!map_container_needs_tail_scan(container))
        return MAP_BOUNDARY_FOUND;
    if (tail == NULL || tail_len == 0 || tail_offset + (int64_t)tail_len != total_size)
        return MAP_BOUNDARY_UNSUPPORTED;
    if (audio_start < 0)
        audio_start = 0;

#define MAP_TAIL_AT(off) (tail + ((off) - tail_offset))

    int64_t end = total_size;
    map_boundary_status_t status = MAP_BOUNDARY_FOUND;
    int changed = 1;

    while (changed)
    {
        changed = 0;

        /* 1. ID3v1 (128 bytes) and ID3v1 Enhanced "TAG+" (227 bytes) */
        if (end - 128 >= audio_start)
        {
            if (end - 128 < tail_offset)
            {
                status = MAP_BOUNDARY_NEED_MORE;
                break;
            }
            const uint8_t *t = MAP_TAIL_AT(end - 128);
            if (t[0] == 'T' && t[1] == 'A' && t[2] == 'G')
            {
                end -= 128;
                if (end - 227 >= audio_start && end - 227 >= tail_offset &&
                    memcmp(MAP_TAIL_AT(end - 227), "TAG+", 4) == 0)
                {
                    end -= 227;
                }
                changed = 1;
                continue;
            }
        }

        /* 2. APEv2 / APEv1 footer (32 bytes) */
        if (end - 32 >= audio_start && end - 32 >= tail_offset &&
            memcmp(MAP_TAIL_AT(end - 32), "APETAGEX", 8) == 0)
        {
            const uint8_t *f = MAP_TAIL_AT(end - 32);
            uint32_t ape_size = map_rd_le32(f + 12);  /* items + footer, without header */
            uint32_t ape_flags = map_rd_le32(f + 20);
            int64_t ape_total = (int64_t)ape_size + ((ape_flags & 0x80000000u) ? 32 : 0);
            if (ape_total >= 32 && end - ape_total >= audio_start)
            {
                end -= ape_total;
                changed = 1;
                if (end < tail_offset)
                {
                    status = MAP_BOUNDARY_NEED_MORE;
                    break;
                }
                continue;
            }
        }

        /* 3. Lyrics3v2: "<6 ascii digits>LYRICS200" */
        if (end - 15 >= audio_start && end - 15 >= tail_offset &&
            memcmp(MAP_TAIL_AT(end - 9), "LYRICS200", 9) == 0)
        {
            const uint8_t *s = MAP_TAIL_AT(end - 15);
            int64_t lyrics_size = 0;
            int valid = 1;
            for (int i = 0; i < 6; i++)
            {
                if (s[i] < '0' || s[i] > '9')
                {
                    valid = 0;
                    break;
                }
                lyrics_size = lyrics_size * 10 + (s[i] - '0');
            }
            int64_t lyr_total = lyrics_size + 6 + 9;
            if (valid && end - lyr_total >= audio_start)
            {
                end -= lyr_total;
                changed = 1;
                if (end < tail_offset)
                {
                    status = MAP_BOUNDARY_NEED_MORE;
                    break;
                }
                continue;
            }
        }

        /* 4. Appended ID3v2 tag with footer ("3DI") */
        if (end - 10 >= audio_start && end - 10 >= tail_offset)
        {
            const uint8_t *f = MAP_TAIL_AT(end - 10);
            if (f[0] == '3' && f[1] == 'D' && f[2] == 'I' && ((f[6] | f[7] | f[8] | f[9]) & 0x80) == 0)
            {
                int64_t id3_total = (int64_t)map_rd_synchsafe32(f + 6) + 20;
                if (end - id3_total >= audio_start)
                {
                    end -= id3_total;
                    changed = 1;
                    if (end < tail_offset)
                    {
                        status = MAP_BOUNDARY_NEED_MORE;
                        break;
                    }
                    continue;
                }
            }
        }
    }

#undef MAP_TAIL_AT

    *out_audio_end = end;
    return status;
}

ma_bool32 map_sniffer_extract_tail_duration_ms(
    map_container_format_t container,
    uint32_t sample_rate,
    const uint8_t *tail,
    size_t tail_len,
    int64_t *out_duration_ms)
{
    if (out_duration_ms == NULL || tail == NULL || tail_len < 27)
    {
        return MA_FALSE;
    }

    if (container != MAP_CONTAINER_OGG_VORBIS && container != MAP_CONTAINER_OGG_OPUS)
    {
        return MA_FALSE;
    }

    uint32_t srate = (container == MAP_CONTAINER_OGG_OPUS) ? 48000 : sample_rate;
    if (srate == 0)
    {
        return MA_FALSE;
    }

    size_t scan_start = tail_len - 27;
    for (size_t j = scan_start;; j--)
    {
        if (memcmp(tail + j, "OggS", 4) == 0 && tail[j + 4] == 0)
        {
            uint64_t granule_pos = map_rd_le64(tail + j + 6);
            if (granule_pos > 0 && granule_pos != (uint64_t)-1)
            {
                int64_t dur_ms = (int64_t)((granule_pos * 1000ULL) / (uint64_t)srate);
                if (dur_ms > 0)
                {
                    *out_duration_ms = dur_ms;
                    return MA_TRUE;
                }
            }
        }
        if (j == 0)
        {
            break;
        }
    }

    return MA_FALSE;
}
