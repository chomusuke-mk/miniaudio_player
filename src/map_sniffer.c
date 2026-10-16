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
    return MA_FALSE;
}
