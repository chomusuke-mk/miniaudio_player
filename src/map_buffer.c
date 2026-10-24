/**
 * @file map_buffer.c
 * @brief Unified Tripartite Audio Buffer: Decoupled Head, Pure Audio Ring, and Tail buffers,
 *        boundary detection, .metaBytes synthesis, and decoder abstraction.
 */

#include "map_buffer.h"
#include <stdlib.h>
#include <string.h>

static const uint8_t s_silent_mp3_header[4] = { 0xFF, 0xFB, 0x90, 0x64 };

/* Minimal 28-byte OggS EOS page */
static const uint8_t s_ogg_eos_page[28] = {
    'O', 'g', 'g', 'S', /* capture pattern */
    0x00,                /* version */
    0x04,                /* header_type: EOS */
    0, 0, 0, 0, 0, 0, 0, 0, /* granule pos 0 */
    0x01, 0x00, 0x00, 0x00, /* stream serial */
    0x01, 0x00, 0x00, 0x00, /* page seq number */
    0x00, 0x00, 0x00, 0x00, /* crc */
    0x01,                /* page_segments: 1 */
    0x00                 /* segment table: 0 length packet */
};

/* Empty 8-byte MP4 mdat atom header */
static const uint8_t s_empty_mdat[8] = { 0x00, 0x00, 0x00, 0x08, 'm', 'd', 'a', 't' };

typedef struct {
    char title[256];
    char artist[256];
    size_t title_len;
    size_t artist_len;
} map_icy_parsed_t;

static void map_parse_icy_string(const uint8_t *icy_data, size_t icy_size, map_icy_parsed_t *out)
{
    memset(out, 0, sizeof(*out));
    if (icy_data == NULL || icy_size == 0)
    {
        strcpy(out->title, "Live Stream");
        out->title_len = 11;
        return;
    }

    /* Make a null-terminated local copy for string operations */
    char raw[512];
    size_t copy_len = (icy_size < sizeof(raw) - 1) ? icy_size : (sizeof(raw) - 1);
    memcpy(raw, icy_data, copy_len);
    raw[copy_len] = '\0';

    /* Look for StreamTitle='...' or StreamTitle="..." */
    const char *st = strstr(raw, "StreamTitle=");
    if (st == NULL)
    {
        st = strstr(raw, "streamtitle=");
    }

    char parsed_str[256];
    parsed_str[0] = '\0';

    if (st != NULL)
    {
        st += 12; /* Skip "StreamTitle=" */
        if (*st == '\'' || *st == '"')
        {
            char quote = *st;
            st++;
            const char *end_quote = strchr(st, quote);
            if (end_quote != NULL)
            {
                size_t len = (size_t)(end_quote - st);
                if (len >= sizeof(parsed_str)) len = sizeof(parsed_str) - 1;
                memcpy(parsed_str, st, len);
                parsed_str[len] = '\0';
            }
            else
            {
                strncpy(parsed_str, st, sizeof(parsed_str) - 1);
            }
        }
        else
        {
            const char *semi = strchr(st, ';');
            if (semi != NULL)
            {
                size_t len = (size_t)(semi - st);
                if (len >= sizeof(parsed_str)) len = sizeof(parsed_str) - 1;
                memcpy(parsed_str, st, len);
                parsed_str[len] = '\0';
            }
            else
            {
                strncpy(parsed_str, st, sizeof(parsed_str) - 1);
            }
        }
    }
    else
    {
        strncpy(parsed_str, raw, sizeof(parsed_str) - 1);
    }

    /* Trim leading whitespace */
    char *p = parsed_str;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;

    /* Trim trailing whitespace, quotes, semicolons */
    size_t plen = strlen(p);
    while (plen > 0 && (p[plen - 1] == ' ' || p[plen - 1] == '\t' || p[plen - 1] == ';' ||
                        p[plen - 1] == '\'' || p[plen - 1] == '"' || p[plen - 1] == '\r' || p[plen - 1] == '\n'))
    {
        p[--plen] = '\0';
    }

    if (plen == 0)
    {
        strcpy(out->title, "Live Stream");
        out->title_len = 11;
        return;
    }

    /* Check for " - " splitting artist and title */
    const char *dash = strstr(p, " - ");
    if (dash != NULL)
    {
        size_t a_len = (size_t)(dash - p);
        if (a_len >= sizeof(out->artist)) a_len = sizeof(out->artist) - 1;
        memcpy(out->artist, p, a_len);
        out->artist[a_len] = '\0';
        out->artist_len = strlen(out->artist);

        const char *t_start = dash + 3;
        while (*t_start == ' ') t_start++;
        strncpy(out->title, t_start, sizeof(out->title) - 1);
        out->title_len = strlen(out->title);
    }
    else
    {
        strncpy(out->title, p, sizeof(out->title) - 1);
        out->title_len = strlen(out->title);
    }

    if (out->title_len == 0)
    {
        strcpy(out->title, "Live Stream");
        out->title_len = 11;
    }
}

static void map_find_head_apic(
    const uint8_t *head_data,
    size_t head_size,
    const uint8_t **out_apic_ptr,
    size_t *out_apic_len)
{
    *out_apic_ptr = NULL;
    *out_apic_len = 0;

    if (head_data == NULL || head_size < 10)
        return;

    if (memcmp(head_data, "ID3", 3) != 0)
        return;

    uint8_t version_major = head_data[3];
    if (version_major != 3 && version_major != 4)
        return;

    uint32_t tag_payload_size =
        (((uint32_t)(head_data[6] & 0x7F)) << 21) |
        (((uint32_t)(head_data[7] & 0x7F)) << 14) |
        (((uint32_t)(head_data[8] & 0x7F)) << 7)  |
        ((uint32_t)(head_data[9] & 0x7F));

    size_t max_scan = 10 + (size_t)tag_payload_size;
    if (max_scan > head_size) max_scan = head_size;

    size_t p = 10;
    while (p + 10 <= max_scan)
    {
        if (head_data[p] == 0)
            break;

        uint32_t frame_size = 0;
        if (version_major == 4)
        {
            frame_size =
                (((uint32_t)(head_data[p + 4] & 0x7F)) << 21) |
                (((uint32_t)(head_data[p + 5] & 0x7F)) << 14) |
                (((uint32_t)(head_data[p + 6] & 0x7F)) << 7)  |
                ((uint32_t)(head_data[p + 7] & 0x7F));
        }
        else
        {
            frame_size =
                (((uint32_t)head_data[p + 4]) << 24) |
                (((uint32_t)head_data[p + 5]) << 16) |
                (((uint32_t)head_data[p + 6]) << 8)  |
                ((uint32_t)head_data[p + 7]);
        }

        size_t total_frame = 10 + (size_t)frame_size;
        if (p + total_frame > max_scan)
            break;

        if (memcmp(head_data + p, "APIC", 4) == 0)
        {
            *out_apic_ptr = head_data + p;
            *out_apic_len = total_frame;
            return;
        }

        p += total_frame;
    }
}

static size_t map_buffer_get_icy_meta_container_size(const map_buffer_t *mb)
{
    map_icy_parsed_t parsed;
    map_parse_icy_string(mb->icy_meta_data, mb->icy_meta_size, &parsed);

    const uint8_t *apic_ptr = NULL;
    size_t apic_len = 0;
    map_find_head_apic(mb->head_data, mb->head_size, &apic_ptr, &apic_len);

    size_t tit2_size = 10 + 1 + parsed.title_len;
    size_t tpe1_size = (parsed.artist_len > 0) ? (10 + 1 + parsed.artist_len) : 0;
    size_t id3_payload_size = tit2_size + tpe1_size + apic_len;

    return 10 + id3_payload_size + sizeof(s_silent_mp3_header) + 128;
}

static size_t map_buffer_copy_icy_meta_container(
    const map_buffer_t *mb,
    uint8_t *out_buffer,
    size_t max_len)
{
    if (out_buffer == NULL || max_len == 0)
        return 0;

    map_icy_parsed_t parsed;
    map_parse_icy_string(mb->icy_meta_data, mb->icy_meta_size, &parsed);

    const uint8_t *apic_ptr = NULL;
    size_t apic_len = 0;
    map_find_head_apic(mb->head_data, mb->head_size, &apic_ptr, &apic_len);

    size_t tit2_size = 10 + 1 + parsed.title_len;
    size_t tpe1_size = (parsed.artist_len > 0) ? (10 + 1 + parsed.artist_len) : 0;
    size_t id3_payload_size = tit2_size + tpe1_size + apic_len;

    size_t written = 0;

    /* 1. ID3v2.3 Header (10 bytes) */
    if (written + 10 <= max_len)
    {
        out_buffer[0] = 'I';
        out_buffer[1] = 'D';
        out_buffer[2] = '3';
        out_buffer[3] = 0x03; /* Version 2.3 */
        out_buffer[4] = 0x00; /* Revision 0 */
        out_buffer[5] = 0x00; /* Flags */
        /* Synchsafe size (28-bit) */
        uint32_t s = (uint32_t)id3_payload_size;
        out_buffer[6] = (uint8_t)((s >> 21) & 0x7F);
        out_buffer[7] = (uint8_t)((s >> 14) & 0x7F);
        out_buffer[8] = (uint8_t)((s >> 7) & 0x7F);
        out_buffer[9] = (uint8_t)(s & 0x7F);
        written += 10;
    }

    /* 2. TIT2 Frame */
    if (written + tit2_size <= max_len)
    {
        out_buffer[written + 0] = 'T';
        out_buffer[written + 1] = 'I';
        out_buffer[written + 2] = 'T';
        out_buffer[written + 3] = '2';
        uint32_t frame_body_size = (uint32_t)(1 + parsed.title_len);
        out_buffer[written + 4] = (uint8_t)((frame_body_size >> 24) & 0xFF);
        out_buffer[written + 5] = (uint8_t)((frame_body_size >> 16) & 0xFF);
        out_buffer[written + 6] = (uint8_t)((frame_body_size >> 8) & 0xFF);
        out_buffer[written + 7] = (uint8_t)(frame_body_size & 0xFF);
        out_buffer[written + 8] = 0x00;
        out_buffer[written + 9] = 0x00;
        out_buffer[written + 10] = 0x03; /* UTF-8 encoding */
        memcpy(out_buffer + written + 11, parsed.title, parsed.title_len);
        written += tit2_size;
    }

    /* 3. TPE1 Frame (if artist present) */
    if (tpe1_size > 0 && written + tpe1_size <= max_len)
    {
        out_buffer[written + 0] = 'T';
        out_buffer[written + 1] = 'P';
        out_buffer[written + 2] = 'E';
        out_buffer[written + 3] = '1';
        uint32_t frame_body_size = (uint32_t)(1 + parsed.artist_len);
        out_buffer[written + 4] = (uint8_t)((frame_body_size >> 24) & 0xFF);
        out_buffer[written + 5] = (uint8_t)((frame_body_size >> 16) & 0xFF);
        out_buffer[written + 6] = (uint8_t)((frame_body_size >> 8) & 0xFF);
        out_buffer[written + 7] = (uint8_t)(frame_body_size & 0xFF);
        out_buffer[written + 8] = 0x00;
        out_buffer[written + 9] = 0x00;
        out_buffer[written + 10] = 0x03; /* UTF-8 encoding */
        memcpy(out_buffer + written + 11, parsed.artist, parsed.artist_len);
        written += tpe1_size;
    }

    /* 4. Preserved APIC Frame */
    if (apic_len > 0 && written + apic_len <= max_len)
    {
        memcpy(out_buffer + written, apic_ptr, apic_len);
        written += apic_len;
    }

    /* 5. MPEG Silent Audio Frame Stub */
    if (written + sizeof(s_silent_mp3_header) <= max_len)
    {
        memcpy(out_buffer + written, s_silent_mp3_header, sizeof(s_silent_mp3_header));
        written += sizeof(s_silent_mp3_header);
    }

    /* 6. ID3v1 Tag Trailer (128 bytes) */
    if (written + 128 <= max_len)
    {
        uint8_t *id3v1 = out_buffer + written;
        memset(id3v1, 0, 128);
        id3v1[0] = 'T';
        id3v1[1] = 'A';
        id3v1[2] = 'G';
        /* Title (30 bytes) */
        size_t t_copy = (parsed.title_len < 30) ? parsed.title_len : 30;
        memcpy(id3v1 + 3, parsed.title, t_copy);
        /* Artist (30 bytes) */
        if (parsed.artist_len > 0)
        {
            size_t a_copy = (parsed.artist_len < 30) ? parsed.artist_len : 30;
            memcpy(id3v1 + 33, parsed.artist, a_copy);
        }
        /* Album (30 bytes) */
        const char *alb = "Live Stream";
        memcpy(id3v1 + 63, alb, strlen(alb));
        /* Comment (28 bytes) */
        const char *cmt = "miniaudio_player";
        memcpy(id3v1 + 97, cmt, strlen(cmt));
        /* Track 1 */
        id3v1[126] = 1;
        /* Genre: 255 (unknown) */
        id3v1[127] = 255;

        written += 128;
    }

    return written;
}

ma_result map_buffer_init(
    map_buffer_t *mb,
    size_t capacity_bytes,
    int64_t total_size,
    ma_bool32 is_live)
{
    if (mb == NULL)
        return MA_INVALID_ARGS;

    memset(mb, 0, sizeof(*mb));

    /* Minimum capacity: 256 KB, default 4MB if 0 passed */
    if (capacity_bytes < 256 * 1024)
    {
        capacity_bytes = 4 * 1024 * 1024;
    }

    mb->data = (uint8_t *)malloc(capacity_bytes);
    if (mb->data == NULL)
    {
        return MA_OUT_OF_MEMORY;
    }

    mb->capacity = capacity_bytes;
    mb->range_start = 0;
    mb->range_end = 0;
    mb->read_cursor = 0;
    mb->total_size = total_size;
    mb->is_live = is_live;
    mb->is_eof = MA_FALSE;
    mb->should_abort = MA_FALSE;
    mb->is_probing = MA_TRUE;
    mb->initial_bytes = 0;

    mb->head_data = NULL;
    mb->head_size = 0;
    mb->head_capacity = 0;

    mb->tail_data = NULL;
    mb->tail_size = 0;
    mb->tail_start = 0;
    mb->tail_capacity = 0;

    mb->audio_start = 0;
    mb->audio_end = (total_size > 0) ? total_size : -1;
    mb->head_locked = MA_FALSE;
    mb->tail_locked = MA_FALSE;
    mb->is_decoding_audio = MA_FALSE;
    mb->container_format = MAP_CONTAINER_UNKNOWN;

    mb->wav_data_size_field_offset = -1;
    mb->mp4_mdat_atom_offset = -1;
    mb->mp4_mdat_header_size = 0;
    mb->head_has_mpeg_frame = 0;

    mb->icy_meta_data = NULL;
    mb->icy_meta_size = 0;
    mb->meta_version = 0;

    if (ma_mutex_init(&mb->lock) != MA_SUCCESS)
    {
        free(mb->data);
        mb->data = NULL;
        return MA_ERROR;
    }

    if (ma_event_init(&mb->data_ready_event) != MA_SUCCESS)
    {
        ma_mutex_uninit(&mb->lock);
        free(mb->data);
        mb->data = NULL;
        return MA_ERROR;
    }

    mb->is_initialized = MA_TRUE;
    return MA_SUCCESS;
}

void map_buffer_uninit(map_buffer_t *mb)
{
    if (mb == NULL || !mb->is_initialized)
        return;

    map_buffer_abort(mb);

    ma_mutex_lock(&mb->lock);
    mb->is_initialized = MA_FALSE;

    if (mb->data != NULL)
    {
        free(mb->data);
        mb->data = NULL;
    }
    if (mb->head_data != NULL)
    {
        free(mb->head_data);
        mb->head_data = NULL;
        mb->head_size = 0;
        mb->head_capacity = 0;
    }
    if (mb->tail_data != NULL)
    {
        free(mb->tail_data);
        mb->tail_data = NULL;
        mb->tail_size = 0;
        mb->tail_start = 0;
        mb->tail_capacity = 0;
    }
    if (mb->icy_meta_data != NULL)
    {
        free(mb->icy_meta_data);
        mb->icy_meta_data = NULL;
        mb->icy_meta_size = 0;
    }
    ma_mutex_unlock(&mb->lock);

    ma_event_uninit(&mb->data_ready_event);
    ma_mutex_uninit(&mb->lock);
}

void map_buffer_abort(map_buffer_t *mb)
{
    if (mb == NULL || !mb->is_initialized)
        return;

    ma_mutex_lock(&mb->lock);
    mb->should_abort = MA_TRUE;
    ma_event_signal(&mb->data_ready_event);
    ma_mutex_unlock(&mb->lock);
}

void map_buffer_set_decoding_audio(map_buffer_t *mb, ma_bool32 decoding)
{
    if (mb == NULL || !mb->is_initialized)
        return;

    ma_mutex_lock(&mb->lock);
    mb->is_decoding_audio = decoding;
    ma_mutex_unlock(&mb->lock);
}

void map_buffer_set_audio_start(map_buffer_t *mb, int64_t audio_start)
{
    if (mb == NULL || !mb->is_initialized)
        return;

    ma_mutex_lock(&mb->lock);
    mb->audio_start = audio_start;
    mb->head_locked = MA_TRUE;
    mb->meta_version++;
    ma_mutex_unlock(&mb->lock);
}

ma_result map_buffer_set_icy_meta(map_buffer_t *mb, const uint8_t *data, size_t size)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);
    if (data != NULL && size > 0)
    {
        uint8_t *nb = (uint8_t *)realloc(mb->icy_meta_data, size + 1);
        if (nb != NULL)
        {
            mb->icy_meta_data = nb;
            memcpy(mb->icy_meta_data, data, size);
            mb->icy_meta_data[size] = '\0';
            mb->icy_meta_size = size;
            mb->meta_version++;
        }
    }
    else
    {
        if (mb->icy_meta_data != NULL)
        {
            free(mb->icy_meta_data);
            mb->icy_meta_data = NULL;
        }
        mb->icy_meta_size = 0;
    }
    ma_mutex_unlock(&mb->lock);
    return MA_SUCCESS;
}

uint32_t map_buffer_get_meta_version(const map_buffer_t *mb)
{
    if (mb == NULL || !mb->is_initialized)
        return 0;

    map_buffer_t *mut = (map_buffer_t *)mb;
    ma_mutex_lock(&mut->lock);
    uint32_t v = mb->meta_version;
    ma_mutex_unlock(&mut->lock);
    return v;
}

size_t map_buffer_get_meta_bytes_size(const map_buffer_t *mb)
{
    if (mb == NULL || !mb->is_initialized)
        return 0;

    map_buffer_t *mut = (map_buffer_t *)mb;
    ma_mutex_lock(&mut->lock);

    /* If livestream ICY metadata is active, synthesize a valid container matching the stream */
    if (mb->icy_meta_data != NULL && mb->icy_meta_size > 0)
    {
        size_t s = map_buffer_get_icy_meta_container_size(mb);
        ma_mutex_unlock(&mut->lock);
        return s;
    }

    if (!mb->head_locked && mb->head_size == 0)
    {
        ma_mutex_unlock(&mut->lock);
        return 0;
    }

    size_t head_len = mb->head_locked ? (size_t)mb->audio_start : mb->head_size;
    size_t tail_len = mb->tail_size;
    size_t total = 0;

    switch (mb->container_format)
    {
    case MAP_CONTAINER_MP3:
    case MAP_CONTAINER_ADTS:
        total = head_len + (mb->head_has_mpeg_frame ? 0 : sizeof(s_silent_mp3_header)) + tail_len;
        break;

    case MAP_CONTAINER_FLAC:
        total = head_len + tail_len;
        break;

    case MAP_CONTAINER_OGG_VORBIS:
    case MAP_CONTAINER_OGG_OPUS:
        total = head_len + sizeof(s_ogg_eos_page);
        break;

    case MAP_CONTAINER_WAV:
        total = head_len + tail_len;
        break;

    case MAP_CONTAINER_MP4:
    {
        size_t prefix = (mb->mp4_mdat_atom_offset >= 0 && mb->mp4_mdat_atom_offset <= (int64_t)head_len)
            ? (size_t)mb->mp4_mdat_atom_offset
            : head_len;
        total = prefix + sizeof(s_empty_mdat) + tail_len;
        break;
    }

    default:
        total = head_len + tail_len;
        break;
    }

    ma_mutex_unlock(&mut->lock);
    return total;
}

size_t map_buffer_copy_meta_bytes(
    const map_buffer_t *mb,
    uint8_t *out_buffer,
    size_t max_len)
{
    if (mb == NULL || !mb->is_initialized || out_buffer == NULL || max_len == 0)
        return 0;

    map_buffer_t *mut = (map_buffer_t *)mb;
    ma_mutex_lock(&mut->lock);

    /* If livestream ICY metadata is active, synthesize a valid container matching the stream */
    if (mb->icy_meta_data != NULL && mb->icy_meta_size > 0)
    {
        size_t copied = map_buffer_copy_icy_meta_container(mb, out_buffer, max_len);
        ma_mutex_unlock(&mut->lock);
        return copied;
    }

    if (!mb->head_locked && mb->head_size == 0)
    {
        ma_mutex_unlock(&mut->lock);
        return 0;
    }

    size_t head_len = mb->head_locked ? (size_t)mb->audio_start : mb->head_size;
    if (head_len > mb->head_size)
    {
        head_len = mb->head_size;
    }
    size_t written = 0;

    switch (mb->container_format)
    {
    case MAP_CONTAINER_MP3:
    case MAP_CONTAINER_ADTS:
    {
        /* 1. Head */
        size_t h_copy = (written + head_len <= max_len) ? head_len : (max_len - written);
        if (h_copy > 0 && mb->head_data != NULL)
        {
            memcpy(out_buffer + written, mb->head_data, h_copy);
            written += h_copy;
        }

        /* 2. MPEG frame stub if Xing/Info was not retained in Head */
        if (!mb->head_has_mpeg_frame && written + sizeof(s_silent_mp3_header) <= max_len)
        {
            memcpy(out_buffer + written, s_silent_mp3_header, sizeof(s_silent_mp3_header));
            written += sizeof(s_silent_mp3_header);
        }

        /* 3. Tail */
        if (mb->tail_data != NULL && mb->tail_size > 0 && written < max_len)
        {
            size_t t_copy = (written + mb->tail_size <= max_len) ? mb->tail_size : (max_len - written);
            memcpy(out_buffer + written, mb->tail_data, t_copy);
            written += t_copy;
        }
        break;
    }

    case MAP_CONTAINER_FLAC:
    {
        /* 1. Head */
        size_t h_copy = (written + head_len <= max_len) ? head_len : (max_len - written);
        if (h_copy > 0 && mb->head_data != NULL)
        {
            memcpy(out_buffer + written, mb->head_data, h_copy);
            written += h_copy;
        }

        /* 2. Tail */
        if (mb->tail_data != NULL && mb->tail_size > 0 && written < max_len)
        {
            size_t t_copy = (written + mb->tail_size <= max_len) ? mb->tail_size : (max_len - written);
            memcpy(out_buffer + written, mb->tail_data, t_copy);
            written += t_copy;
        }
        break;
    }

    case MAP_CONTAINER_OGG_VORBIS:
    case MAP_CONTAINER_OGG_OPUS:
    {
        /* 1. Head */
        size_t h_copy = (written + head_len <= max_len) ? head_len : (max_len - written);
        if (h_copy > 0 && mb->head_data != NULL)
        {
            memcpy(out_buffer + written, mb->head_data, h_copy);
            written += h_copy;
        }

        /* 2. Ogg EOS page */
        if (written + sizeof(s_ogg_eos_page) <= max_len)
        {
            memcpy(out_buffer + written, s_ogg_eos_page, sizeof(s_ogg_eos_page));
            /* Patch serial number from first page in Head if available */
            if (head_len >= 18 && mb->head_data != NULL)
            {
                memcpy(out_buffer + written + 14, mb->head_data + 14, 4);
            }
            written += sizeof(s_ogg_eos_page);
        }
        break;
    }

    case MAP_CONTAINER_WAV:
    {
        /* 1. Head */
        size_t h_copy = (written + head_len <= max_len) ? head_len : (max_len - written);
        if (h_copy > 0 && mb->head_data != NULL)
        {
            memcpy(out_buffer + written, mb->head_data, h_copy);
            written += h_copy;
        }

        /* 2. Tail */
        if (mb->tail_data != NULL && mb->tail_size > 0 && written < max_len)
        {
            size_t t_copy = (written + mb->tail_size <= max_len) ? mb->tail_size : (max_len - written);
            memcpy(out_buffer + written, mb->tail_data, t_copy);
            written += t_copy;
        }

        /* Patch data chunk size to 0 */
        if (mb->wav_data_size_field_offset >= 0 &&
            (size_t)(mb->wav_data_size_field_offset + 4) <= written)
        {
            memset(out_buffer + mb->wav_data_size_field_offset, 0, 4);
        }

        /* Patch overall RIFF size at offset 4 */
        if (written >= 8)
        {
            uint32_t riff_size = (uint32_t)(written - 8);
            out_buffer[4] = (uint8_t)(riff_size & 0xFF);
            out_buffer[5] = (uint8_t)((riff_size >> 8) & 0xFF);
            out_buffer[6] = (uint8_t)((riff_size >> 16) & 0xFF);
            out_buffer[7] = (uint8_t)((riff_size >> 24) & 0xFF);
        }
        break;
    }

    case MAP_CONTAINER_MP4:
    {
        /* 1. Head prefix before mdat */
        size_t prefix = (mb->mp4_mdat_atom_offset >= 0 && mb->mp4_mdat_atom_offset <= (int64_t)head_len)
            ? (size_t)mb->mp4_mdat_atom_offset
            : head_len;

        size_t p_copy = (written + prefix <= max_len) ? prefix : (max_len - written);
        if (p_copy > 0 && mb->head_data != NULL)
        {
            memcpy(out_buffer + written, mb->head_data, p_copy);
            written += p_copy;
        }

        /* 2. Empty mdat atom (8 bytes) */
        if (written + sizeof(s_empty_mdat) <= max_len)
        {
            memcpy(out_buffer + written, s_empty_mdat, sizeof(s_empty_mdat));
            written += sizeof(s_empty_mdat);
        }

        /* 3. Tail (moov / udta / ilst) */
        if (mb->tail_data != NULL && mb->tail_size > 0 && written < max_len)
        {
            size_t t_copy = (written + mb->tail_size <= max_len) ? mb->tail_size : (max_len - written);
            memcpy(out_buffer + written, mb->tail_data, t_copy);
            written += t_copy;
        }
        break;
    }

    default:
    {
        size_t h_copy = (written + head_len <= max_len) ? head_len : (max_len - written);
        if (h_copy > 0 && mb->head_data != NULL)
        {
            memcpy(out_buffer + written, mb->head_data, h_copy);
            written += h_copy;
        }
        if (mb->tail_data != NULL && mb->tail_size > 0 && written < max_len)
        {
            size_t t_copy = (written + mb->tail_size <= max_len) ? mb->tail_size : (max_len - written);
            memcpy(out_buffer + written, mb->tail_data, t_copy);
            written += t_copy;
        }
        break;
    }
    }

    ma_mutex_unlock(&mut->lock);
    return written;
}

static ma_result map_buffer_grow_head(map_buffer_t *mb, size_t needed)
{
    if (needed <= mb->head_capacity)
        return MA_SUCCESS;

    size_t new_cap = (mb->head_capacity == 0) ? (64 * 1024) : (mb->head_capacity * 2);
    while (new_cap < needed)
    {
        new_cap *= 2;
    }

    uint8_t *new_buf = (uint8_t *)realloc(mb->head_data, new_cap);
    if (new_buf == NULL)
        return MA_OUT_OF_MEMORY;

    mb->head_data = new_buf;
    mb->head_capacity = new_cap;
    return MA_SUCCESS;
}

static ma_result map_buffer_grow_tail(map_buffer_t *mb, size_t needed)
{
    if (needed <= mb->tail_capacity)
        return MA_SUCCESS;

    size_t new_cap = (mb->tail_capacity == 0) ? (64 * 1024) : (mb->tail_capacity * 2);
    while (new_cap < needed)
    {
        new_cap *= 2;
    }

    uint8_t *new_buf = (uint8_t *)realloc(mb->tail_data, new_cap);
    if (new_buf == NULL)
        return MA_OUT_OF_MEMORY;

    mb->tail_data = new_buf;
    mb->tail_capacity = new_cap;
    return MA_SUCCESS;
}

static void map_buffer_ring_write_internal(
    map_buffer_t *mb,
    int64_t abs_offset,
    const uint8_t *src,
    size_t len)
{
    if (len == 0 || src == NULL || mb->data == NULL)
        return;

    const uint8_t *cur_src = src;
    size_t to_write = len;
    int64_t start_off = abs_offset;

    if (to_write > mb->capacity)
    {
        size_t excess = to_write - mb->capacity;
        cur_src += excess;
        start_off += (int64_t)excess;
        to_write = mb->capacity;
    }

    int64_t rel_start = start_off - mb->audio_start;
    if (rel_start < 0)
    {
        rel_start = 0;
    }

    size_t start_idx = (size_t)(rel_start % (int64_t)mb->capacity);
    size_t chunk1 = mb->capacity - start_idx;
    if (chunk1 > to_write)
    {
        chunk1 = to_write;
    }
    memcpy(mb->data + start_idx, cur_src, chunk1);
    if (to_write > chunk1)
    {
        memcpy(mb->data, cur_src + chunk1, to_write - chunk1);
    }

    /* Update range boundaries */
    if (mb->range_start == mb->range_end)
    {
        mb->range_start = abs_offset;
        mb->range_end = abs_offset + (int64_t)len;
    }
    else
    {
        if (abs_offset + (int64_t)len > mb->range_end)
        {
            mb->range_end = abs_offset + (int64_t)len;
        }
        if (abs_offset < mb->range_start)
        {
            mb->range_start = abs_offset;
        }

        /* Enforce sliding window capacity constraint */
        if (mb->range_end - mb->range_start > (int64_t)mb->capacity)
        {
            int64_t new_start = mb->range_end - (int64_t)mb->capacity;
            if (!mb->is_live && new_start > mb->read_cursor && mb->read_cursor >= mb->audio_start)
            {
                new_start = mb->read_cursor;
            }
            mb->range_start = new_start;
        }
    }
}

ma_result map_buffer_set_head(
    map_buffer_t *mb,
    const uint8_t *head_data,
    size_t head_size)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    if (head_data != NULL && head_size > 0)
    {
        if (map_buffer_grow_head(mb, head_size) == MA_SUCCESS)
        {
            memcpy(mb->head_data, head_data, head_size);
            mb->head_size = head_size;

            /* Sniff boundaries */
            map_boundary_info_t binfo;
            map_boundary_info_reset(&binfo);
            if (map_sniffer_detect_head_boundary(mb->head_data, mb->head_size, mb->total_size, &binfo) == MAP_BOUNDARY_FOUND)
            {
                mb->head_locked = MA_TRUE;
                mb->container_format = binfo.container;
                mb->audio_start = binfo.audio_start;
                mb->audio_end = binfo.audio_end;
                mb->wav_data_size_field_offset = binfo.wav_data_size_field_offset;
                mb->mp4_mdat_atom_offset = binfo.mp4_mdat_atom_offset;
                mb->mp4_mdat_header_size = binfo.mp4_mdat_header_size;
                mb->head_has_mpeg_frame = binfo.head_has_mpeg_frame;
                if (binfo.audio_end > 0)
                {
                    mb->tail_locked = MA_TRUE;
                }
                mb->meta_version++;
            }
        }
    }

    ma_mutex_unlock(&mb->lock);
    return MA_SUCCESS;
}

ma_result map_buffer_set_tail(
    map_buffer_t *mb,
    const uint8_t *tail_data,
    size_t tail_size)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    if (tail_data != NULL && tail_size > 0 && mb->total_size > 0)
    {
        int64_t tail_offset = mb->total_size - (int64_t)tail_size;
        if (tail_offset < 0)
            tail_offset = 0;

        int64_t detected_audio_end = -1;
        map_boundary_status_t st = map_sniffer_detect_tail_boundary(
            mb->container_format,
            tail_data,
            tail_size,
            tail_offset,
            mb->total_size,
            mb->audio_start,
            &detected_audio_end);

        if (st == MAP_BOUNDARY_FOUND && detected_audio_end > 0)
        {
            if (mb->container_format == MAP_CONTAINER_MP4 && mb->audio_end > 0 && mb->audio_end < mb->total_size)
            {
                /* For MP4 non-fast-start, audio_end was already determined by mdat in head */
                detected_audio_end = mb->audio_end;
            }
            mb->audio_end = detected_audio_end;
            mb->tail_locked = MA_TRUE;
            int64_t tail_chunk_start = detected_audio_end - tail_offset;
            if (tail_chunk_start < 0)
            {
                tail_chunk_start = 0;
            }
            if ((size_t)tail_chunk_start < tail_size)
            {
                size_t actual_tail = tail_size - (size_t)tail_chunk_start;
                if (map_buffer_grow_tail(mb, actual_tail) == MA_SUCCESS)
                {
                    memcpy(mb->tail_data, tail_data + tail_chunk_start, actual_tail);
                    mb->tail_size = actual_tail;
                    mb->tail_start = (detected_audio_end > tail_offset) ? detected_audio_end : tail_offset;
                }
            }
            mb->meta_version++;
        }
        else
        {
            if (map_buffer_grow_tail(mb, tail_size) == MA_SUCCESS)
            {
                memcpy(mb->tail_data, tail_data, tail_size);
                mb->tail_size = tail_size;
                mb->tail_start = tail_offset;
            }
        }
    }

    ma_mutex_unlock(&mb->lock);
    return MA_SUCCESS;
}

ma_result map_buffer_probe_tail(
    map_buffer_t *mb,
    const uint8_t *tail_data,
    size_t tail_size,
    int64_t tail_offset)
{
    if (mb == NULL || !mb->is_initialized || tail_data == NULL || tail_size == 0)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    /* If tail is already locked and valid (e.g. MP4 moov loaded at init), do not overwrite with smaller probe */
    if (mb->tail_locked && (mb->container_format == MAP_CONTAINER_MP4 || (mb->tail_size > 0 && mb->tail_size >= tail_size)))
    {
        ma_event_signal(&mb->data_ready_event);
        ma_mutex_unlock(&mb->lock);
        return MA_SUCCESS;
    }

    if (mb->total_size > 0)
    {
        int64_t detected_audio_end = -1;
        map_boundary_status_t st = map_sniffer_detect_tail_boundary(
            mb->container_format,
            tail_data,
            tail_size,
            tail_offset,
            mb->total_size,
            mb->audio_start,
            &detected_audio_end);

        if (st == MAP_BOUNDARY_FOUND && detected_audio_end > 0)
        {
            if (mb->container_format == MAP_CONTAINER_MP4 && mb->audio_end > 0 && mb->audio_end < mb->total_size)
            {
                /* For MP4 non-fast-start, audio_end was already determined by mdat in head */
                detected_audio_end = mb->audio_end;
            }
            mb->audio_end = detected_audio_end;
            mb->tail_locked = MA_TRUE;

            int64_t tail_in_data = detected_audio_end - tail_offset;
            if (tail_in_data < 0)
            {
                tail_in_data = 0;
            }
            if ((size_t)tail_in_data < tail_size)
            {
                size_t actual_tail_bytes = tail_size - (size_t)tail_in_data;
                if (map_buffer_grow_tail(mb, actual_tail_bytes) == MA_SUCCESS)
                {
                    memcpy(mb->tail_data, tail_data + tail_in_data, actual_tail_bytes);
                    mb->tail_size = actual_tail_bytes;
                    mb->tail_start = (detected_audio_end > tail_offset) ? detected_audio_end : tail_offset;
                }
            }
            mb->meta_version++;
        }
    }

    ma_event_signal(&mb->data_ready_event);
    ma_mutex_unlock(&mb->lock);
    return MA_SUCCESS;
}

ma_result map_buffer_write(
    map_buffer_t *mb,
    int64_t offset,
    const uint8_t *pData,
    size_t size)
{
    if (mb == NULL || !mb->is_initialized || pData == NULL || size == 0)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    if (mb->should_abort)
    {
        ma_mutex_unlock(&mb->lock);
        return MA_INTERRUPT;
    }

    /* Backpressure protection: For progressive file streams, never allow writer to overrun read_cursor */
    if (!mb->is_probing && !mb->is_live)
    {
        if ((offset + (int64_t)size) - mb->read_cursor > (int64_t)mb->capacity)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_BUSY;
        }
    }

    /* Phase 1: If audio_start is not locked yet, accumulate prefix into Head and sniff boundaries */
    if (!mb->head_locked)
    {
        size_t needed = (size_t)(offset + (int64_t)size);
        if (map_buffer_grow_head(mb, needed) != MA_SUCCESS)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_OUT_OF_MEMORY;
        }

        memcpy(mb->head_data + offset, pData, size);
        if (needed > mb->head_size)
        {
            mb->head_size = needed;
        }

        map_boundary_info_t binfo;
        map_boundary_info_reset(&binfo);
        map_boundary_status_t status = map_sniffer_detect_head_boundary(
            mb->head_data,
            mb->head_size,
            mb->total_size,
            &binfo);

        if (status == MAP_BOUNDARY_FOUND)
        {
            mb->head_locked = MA_TRUE;
            mb->container_format = binfo.container;
            mb->audio_start = binfo.audio_start;
            mb->audio_end = binfo.audio_end;
            mb->wav_data_size_field_offset = binfo.wav_data_size_field_offset;
            mb->mp4_mdat_atom_offset = binfo.mp4_mdat_atom_offset;
            mb->mp4_mdat_header_size = binfo.mp4_mdat_header_size;
            mb->head_has_mpeg_frame = binfo.head_has_mpeg_frame;
            if (binfo.audio_end > 0)
            {
                mb->tail_locked = MA_TRUE;
            }
            mb->meta_version++;

            /* If head_data already ingested bytes past audio_start, move excess into audio ring */
            if (mb->head_size > (size_t)mb->audio_start)
            {
                size_t excess = mb->head_size - (size_t)mb->audio_start;
                map_buffer_ring_write_internal(mb, mb->audio_start, mb->head_data + mb->audio_start, excess);
                size_t max_pinned = (size_t)mb->audio_start + MAP_BUFFER_PINNED_HEAD_DEFAULT_CAPACITY;
                if (mb->head_size > max_pinned)
                {
                    mb->head_size = max_pinned;
                }
            }
        }
        else if (status == MAP_BOUNDARY_UNSUPPORTED &&
                 (mb->head_size >= MAP_BUFFER_PINNED_HEAD_DEFAULT_CAPACITY || mb->is_eof))
        {
            /* Generic/raw container fallback: lock at byte 0 and mirror into ring */
            mb->head_locked = MA_TRUE;
            mb->container_format = MAP_CONTAINER_UNKNOWN;
            mb->audio_start = 0;
            mb->audio_end = mb->total_size;
            mb->meta_version++;

            map_buffer_ring_write_internal(mb, 0, mb->head_data, mb->head_size);
            if (mb->head_size > MAP_BUFFER_PINNED_HEAD_DEFAULT_CAPACITY)
            {
                mb->head_size = MAP_BUFFER_PINNED_HEAD_DEFAULT_CAPACITY;
            }
        }
        else
        {
            if (mb->is_probing)
            {
                mb->initial_bytes = mb->head_size;
            }
            ma_event_signal(&mb->data_ready_event);
            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }
    }

    /* Phase 2: audio_start is locked. Route incoming bytes into Head, Pure Audio Ring, or Tail */
    int64_t cur_offset = offset;
    const uint8_t *cur_ptr = pData;
    size_t remaining = size;

    /* Zone 1: HEAD [0 .. audio_start) */
    if (cur_offset < mb->audio_start && remaining > 0)
    {
        size_t head_avail = (size_t)(mb->audio_start - cur_offset);
        size_t head_chunk = (remaining < head_avail) ? remaining : head_avail;
        if (map_buffer_grow_head(mb, (size_t)(cur_offset + (int64_t)head_chunk)) == MA_SUCCESS)
        {
            memcpy(mb->head_data + cur_offset, cur_ptr, head_chunk);
            if ((size_t)(cur_offset + (int64_t)head_chunk) > mb->head_size)
            {
                mb->head_size = (size_t)(cur_offset + (int64_t)head_chunk);
            }
        }
        cur_offset += (int64_t)head_chunk;
        cur_ptr += head_chunk;
        remaining -= head_chunk;
    }

    /* Zone 2: PURE AUDIO RING [audio_start .. audio_end) */
    if (cur_offset >= mb->audio_start && remaining > 0 &&
        (!mb->tail_locked || mb->audio_end <= 0 || cur_offset < mb->audio_end))
    {
        size_t audio_avail = (mb->tail_locked && mb->audio_end > 0)
            ? (size_t)(mb->audio_end - cur_offset)
            : remaining;
        size_t audio_chunk = (remaining < audio_avail) ? remaining : audio_avail;
        map_buffer_ring_write_internal(mb, cur_offset, cur_ptr, audio_chunk);

        /* Retain initial audio prefix in pinned head up to 256 KB for instant seek(0) cache hits */
        size_t pinned_target = (size_t)mb->audio_start + MAP_BUFFER_PINNED_HEAD_DEFAULT_CAPACITY;
        if ((size_t)cur_offset < pinned_target)
        {
            size_t pinned_avail = pinned_target - (size_t)cur_offset;
            size_t pinned_chunk = (audio_chunk < pinned_avail) ? audio_chunk : pinned_avail;
            if (map_buffer_grow_head(mb, (size_t)(cur_offset + (int64_t)pinned_chunk)) == MA_SUCCESS)
            {
                memcpy(mb->head_data + cur_offset, cur_ptr, pinned_chunk);
                if ((size_t)(cur_offset + (int64_t)pinned_chunk) > mb->head_size)
                {
                    mb->head_size = (size_t)(cur_offset + (int64_t)pinned_chunk);
                }
            }
        }

        cur_offset += (int64_t)audio_chunk;
        cur_ptr += audio_chunk;
        remaining -= audio_chunk;
    }

    /* Zone 3: TAIL [audio_end .. total_size) */
    if (mb->tail_locked && mb->audio_end > 0 && cur_offset >= mb->audio_end && remaining > 0)
    {
        size_t tail_rel = (size_t)(cur_offset - mb->audio_end);
        size_t needed = tail_rel + remaining;
        if (map_buffer_grow_tail(mb, needed) == MA_SUCCESS)
        {
            memcpy(mb->tail_data + tail_rel, cur_ptr, remaining);
            if (needed > mb->tail_size)
            {
                mb->tail_size = needed;
            }
            mb->tail_start = mb->audio_end;
        }
        remaining = 0;
    }

    if (mb->is_probing)
    {
        mb->initial_bytes = (size_t)(mb->range_end - mb->range_start);
    }

    ma_event_signal(&mb->data_ready_event);
    ma_mutex_unlock(&mb->lock);
    return MA_SUCCESS;
}

ma_result map_buffer_feed(
    map_buffer_t *mb,
    const uint8_t *pData,
    size_t size)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);
    int64_t off = mb->range_end;
    if (!mb->head_locked)
    {
        off = (int64_t)mb->head_size;
    }
    ma_mutex_unlock(&mb->lock);

    return map_buffer_write(mb, off, pData, size);
}

ma_result map_buffer_read(
    map_buffer_t *mb,
    int64_t offset,
    void *pBufferOut,
    size_t bytesToRead,
    size_t *pBytesRead)
{
    if (mb == NULL || !mb->is_initialized || pBufferOut == NULL)
        return MA_INVALID_ARGS;

    if (pBytesRead != NULL)
        *pBytesRead = 0;

    if (bytesToRead == 0)
        return MA_SUCCESS;

    uint8_t *out = (uint8_t *)pBufferOut;

    while (1)
    {
        ma_mutex_lock(&mb->lock);

        if (mb->should_abort)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_INTERRUPT;
        }

        int64_t req_offset = (offset >= 0) ? offset : mb->read_cursor;

        /* Finite file EOF check */
        if (mb->total_size > 0 && req_offset >= mb->total_size)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_AT_END;
        }

        /* ------------------------------------------------------------------ */
        /* TIER 1: Pinned Head [0 .. head_size)                               */
        /* ------------------------------------------------------------------ */
        if (mb->head_data != NULL && req_offset >= 0 && (size_t)req_offset < mb->head_size)
        {
            /* If actively decoding audio, don't read tail metadata if file <= head_size */
            if (mb->tail_locked && mb->audio_end > 0 && req_offset >= mb->audio_end &&
                mb->is_decoding_audio && mb->container_format != MAP_CONTAINER_MP4)
            {
                ma_mutex_unlock(&mb->lock);
                return MA_AT_END;
            }

            size_t avail = mb->head_size - (size_t)req_offset;
            if (mb->tail_locked && mb->audio_end > 0 && req_offset + (int64_t)avail > mb->audio_end &&
                mb->is_decoding_audio && mb->container_format != MAP_CONTAINER_MP4)
            {
                avail = (size_t)(mb->audio_end - req_offset);
            }

            size_t to_copy = (bytesToRead < avail) ? bytesToRead : avail;
            memcpy(out, mb->head_data + req_offset, to_copy);
            if (offset < 0)
            {
                mb->read_cursor += (int64_t)to_copy;
            }
            if (pBytesRead != NULL)
            {
                *pBytesRead = to_copy;
            }
            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }
        else if (req_offset < mb->audio_start)
        {
            if (mb->is_probing || mb->is_eof)
            {
                ma_mutex_unlock(&mb->lock);
                return MA_AT_END;
            }
            ma_mutex_unlock(&mb->lock);
            ma_event_wait(&mb->data_ready_event);
            continue;
        }

        /* ------------------------------------------------------------------ */
        /* TIER 2: EOF Protection / Tail Buffer [audio_end .. total_size)     */
        /* ------------------------------------------------------------------ */
        if (mb->tail_locked && mb->audio_end > 0 && req_offset >= mb->audio_end)
        {
            /* If actively decoding audio frames (MP3, AAC, FLAC, WAV, OGG),
             * return MA_AT_END immediately so tail metadata is NEVER read as audio. */
            if (mb->is_decoding_audio && mb->container_format != MAP_CONTAINER_MP4)
            {
                ma_mutex_unlock(&mb->lock);
                return MA_AT_END;
            }

            /* During ma_decoder_init or MP4 container index reads: serve from tail_data */
            int64_t tail_rel = req_offset - mb->audio_end;
            if (mb->tail_data != NULL && tail_rel >= 0 && (size_t)tail_rel < mb->tail_size)
            {
                size_t avail = mb->tail_size - (size_t)tail_rel;
                size_t to_copy = (bytesToRead < avail) ? bytesToRead : avail;

                memcpy(out, mb->tail_data + tail_rel, to_copy);

                if (offset < 0)
                {
                    mb->read_cursor += (int64_t)to_copy;
                }
                if (pBytesRead != NULL)
                {
                    *pBytesRead = to_copy;
                }

                ma_mutex_unlock(&mb->lock);
                return MA_SUCCESS;
            }

            ma_mutex_unlock(&mb->lock);
            return MA_AT_END;
        }

        /* ------------------------------------------------------------------ */
        /* TIER 3: Pure Audio Ring Buffer [audio_start .. audio_end)          */
        /* ------------------------------------------------------------------ */
        if (req_offset >= mb->range_start && req_offset < mb->range_end)
        {
            size_t available = (size_t)(mb->range_end - req_offset);
            if (mb->tail_locked && mb->audio_end > 0 && req_offset + (int64_t)available > mb->audio_end)
            {
                available = (size_t)(mb->audio_end - req_offset);
            }
            size_t to_copy = (bytesToRead < available) ? bytesToRead : available;

            int64_t rel_pos = req_offset - mb->audio_start;
            if (rel_pos < 0)
            {
                rel_pos = req_offset;
            }

            size_t start_idx = (size_t)(rel_pos % (int64_t)mb->capacity);
            size_t chunk1 = mb->capacity - start_idx;
            if (chunk1 > to_copy)
            {
                chunk1 = to_copy;
            }
            memcpy(out, mb->data + start_idx, chunk1);
            if (to_copy > chunk1)
            {
                memcpy(out + chunk1, mb->data, to_copy - chunk1);
            }

            if (offset < 0)
            {
                mb->read_cursor += (int64_t)to_copy;
            }
            if (pBytesRead != NULL)
            {
                *pBytesRead = to_copy;
            }

            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }

        /* Eviction check: if req_offset < mb->range_start and not in Head */
        if (req_offset < mb->range_start &&
            (req_offset < 0 || (size_t)req_offset >= mb->head_size))
        {
            ma_mutex_unlock(&mb->lock);
            return MA_NOT_IMPLEMENTED;
        }

        /* Format probing or EOF */
        if (mb->is_probing || mb->is_eof)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_AT_END;
        }

        /* Data not yet arrived (wait on event) */
        ma_mutex_unlock(&mb->lock);
        ma_event_wait(&mb->data_ready_event);
    }
}

ma_result map_buffer_seek(
    map_buffer_t *mb,
    int64_t target_offset)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    if (target_offset < 0)
        target_offset = 0;
    if (mb->total_size > 0 && target_offset > mb->total_size)
        target_offset = mb->total_size;

    mb->read_cursor = target_offset;
    if ((mb->total_size > 0 && target_offset < mb->total_size) || target_offset < mb->range_end)
    {
        mb->is_eof = MA_FALSE;
    }

    /* Cache hit: pinned head, sliding body, or pinned tail */
    if ((mb->head_data != NULL && target_offset >= 0 && (size_t)target_offset <= mb->head_size) ||
        (target_offset >= mb->range_start && target_offset <= mb->range_end) ||
        (mb->tail_data != NULL && target_offset >= mb->tail_start &&
         target_offset <= (mb->tail_start + (int64_t)mb->tail_size)))
    {
        ma_event_signal(&mb->data_ready_event);
        ma_mutex_unlock(&mb->lock);
        return MA_SUCCESS;
    }

    ma_mutex_unlock(&mb->lock);
    return MA_SUCCESS;
}

ma_result map_buffer_flush(
    map_buffer_t *mb,
    int64_t new_offset)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    if (new_offset < 0)
        new_offset = 0;

    mb->read_cursor = new_offset;
    mb->range_start = new_offset;
    mb->range_end = new_offset;
    mb->is_eof = MA_FALSE;
    mb->should_abort = MA_FALSE;

    ma_event_signal(&mb->data_ready_event);
    ma_mutex_unlock(&mb->lock);

    return MA_SUCCESS;
}

ma_result map_buffer_end(map_buffer_t *mb)
{
    if (mb == NULL || !mb->is_initialized)
        return MA_INVALID_ARGS;

    ma_mutex_lock(&mb->lock);

    /* If finite stream reaching EOF without tail locked, perform tail scan */
    if (!mb->tail_locked && mb->total_size > 0 && map_container_needs_tail_scan(mb->container_format))
    {
        /* Check if tail bytes reside in ring buffer at end */
        size_t scan_len = 64 * 1024;
        if ((int64_t)scan_len > mb->total_size)
        {
            scan_len = (size_t)mb->total_size;
        }
        int64_t scan_off = mb->total_size - (int64_t)scan_len;

        if (mb->range_end >= mb->total_size && scan_off >= mb->range_start)
        {
            uint8_t *tmp = (uint8_t *)malloc(scan_len);
            if (tmp != NULL)
            {
                /* Read scan_len from ring buffer */
                for (size_t i = 0; i < scan_len; i++)
                {
                    int64_t p = scan_off + (int64_t)i;
                    int64_t rel = p - mb->audio_start;
                    if (rel < 0) rel = p;
                    tmp[i] = mb->data[(size_t)(rel % (int64_t)mb->capacity)];
                }

                int64_t detected_audio_end = -1;
                map_boundary_status_t st = map_sniffer_detect_tail_boundary(
                    mb->container_format,
                    tmp,
                    scan_len,
                    scan_off,
                    mb->total_size,
                    mb->audio_start,
                    &detected_audio_end);

                if (st == MAP_BOUNDARY_FOUND && detected_audio_end > 0)
                {
                    mb->audio_end = detected_audio_end;
                    mb->tail_locked = MA_TRUE;

                    size_t tail_chunk_start = (size_t)(detected_audio_end - scan_off);
                    if (tail_chunk_start < scan_len)
                    {
                        size_t actual_tail = scan_len - tail_chunk_start;
                        if (map_buffer_grow_tail(mb, actual_tail) == MA_SUCCESS)
                        {
                            memcpy(mb->tail_data, tmp + tail_chunk_start, actual_tail);
                            mb->tail_size = actual_tail;
                            mb->tail_start = detected_audio_end;
                        }
                    }
                    if (mb->range_end > detected_audio_end)
                    {
                        mb->range_end = detected_audio_end;
                    }
                    mb->meta_version++;
                }
                free(tmp);
            }
        }
    }

    mb->is_eof = MA_TRUE;
    ma_event_signal(&mb->data_ready_event);
    ma_mutex_unlock(&mb->lock);

    return MA_SUCCESS;
}

ma_result map_buffer_get_range(
    const map_buffer_t *mb,
    map_buffer_range_t *out_range)
{
    if (mb == NULL || !mb->is_initialized || out_range == NULL)
        return MA_INVALID_ARGS;

    map_buffer_t *mut = (map_buffer_t *)mb;
    ma_mutex_lock(&mut->lock);

    out_range->start_byte = mb->range_start;
    out_range->end_byte = mb->range_end;
    out_range->total_bytes = mb->total_size;
    out_range->read_cursor_byte = mb->read_cursor;

    int64_t span = mb->range_end - mb->range_start;
    out_range->fill_percentage = (mb->capacity > 0) ? (float)((double)span / (double)mb->capacity) : 0.0f;
    if (out_range->fill_percentage > 1.0f)
        out_range->fill_percentage = 1.0f;

    int64_t a_start = (mb->audio_start > 0) ? mb->audio_start : 0;
    int64_t a_end = (mb->audio_end > a_start) ? mb->audio_end : mb->total_size;

    if (a_end > a_start)
    {
        int64_t pure_len = a_end - a_start;
        int64_t loaded = (mb->range_end > a_start) ? (mb->range_end - a_start) : 0;
        out_range->stream_percentage = (float)((double)loaded / (double)pure_len);
        if (out_range->stream_percentage > 1.0f)
            out_range->stream_percentage = 1.0f;
    }
    else if (mb->total_size > 0)
    {
        out_range->stream_percentage = (float)((double)mb->range_end / (double)mb->total_size);
        if (out_range->stream_percentage > 1.0f)
            out_range->stream_percentage = 1.0f;
    }
    else
    {
        out_range->stream_percentage = out_range->fill_percentage;
    }

    out_range->is_buffering = (mb->read_cursor >= mb->range_end && !mb->is_eof) ? 1 : 0;
    out_range->is_eof = mb->is_eof ? 1 : 0;

    ma_mutex_unlock(&mut->lock);
    return MA_SUCCESS;
}

ma_result map_buffer_decoder_read(
    ma_decoder *pDecoder,
    void *pBufferOut,
    size_t bytesToRead,
    size_t *pBytesRead)
{
    if (pDecoder == NULL || pDecoder->pUserData == NULL)
        return MA_INVALID_ARGS;

    map_buffer_t *mb = (map_buffer_t *)pDecoder->pUserData;
    return map_buffer_read(mb, -1, pBufferOut, bytesToRead, pBytesRead);
}

ma_result map_buffer_decoder_seek(
    ma_decoder *pDecoder,
    ma_int64 byteOffset,
    ma_seek_origin origin)
{
    if (pDecoder == NULL || pDecoder->pUserData == NULL)
        return MA_INVALID_ARGS;

    map_buffer_t *mb = (map_buffer_t *)pDecoder->pUserData;
    int64_t target = 0;

    ma_mutex_lock(&mb->lock);

    /* Format probing seek handling: initial_bytes / head are fully available */
    if (mb->is_probing)
    {
        int64_t targetOffset = -1;
        if (origin == ma_seek_origin_start)
        {
            targetOffset = byteOffset;
        }
        else if (origin == ma_seek_origin_current)
        {
            targetOffset = mb->read_cursor + byteOffset;
        }
        else if (origin == ma_seek_origin_end)
        {
            if (mb->total_size <= 0)
            {
                ma_mutex_unlock(&mb->lock);
                return MA_BAD_SEEK;
            }
            targetOffset = mb->total_size + byteOffset;
        }
        else
        {
            ma_mutex_unlock(&mb->lock);
            return MA_INVALID_ARGS;
        }

        if (targetOffset >= 0 && ((size_t)targetOffset <= mb->initial_bytes ||
                                  (mb->head_data != NULL && (size_t)targetOffset <= mb->head_size)))
        {
            mb->read_cursor = targetOffset;
            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }

        if (mb->tail_data != NULL && targetOffset >= mb->tail_start &&
            targetOffset <= (mb->tail_start + (int64_t)mb->tail_size))
        {
            mb->read_cursor = targetOffset;
            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }

        if (mb->total_size > 0 && targetOffset == mb->total_size)
        {
            mb->read_cursor = targetOffset;
            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }

        ma_mutex_unlock(&mb->lock);
        return MA_BAD_SEEK;
    }

    if (origin == ma_seek_origin_start)
    {
        target = (int64_t)byteOffset;
    }
    else if (origin == ma_seek_origin_current)
    {
        target = mb->read_cursor + (int64_t)byteOffset;
    }
    else if (origin == ma_seek_origin_end)
    {
        if (mb->total_size <= 0)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_BAD_SEEK;
        }
        target = mb->total_size + (int64_t)byteOffset;
    }
    else
    {
        ma_mutex_unlock(&mb->lock);
        return MA_INVALID_ARGS;
    }

    /* Relative seek within pinned head, sliding body, or pinned tail */
    if ((mb->head_data != NULL && target >= 0 && (size_t)target <= mb->head_size) ||
        (target >= mb->range_start && target <= mb->range_end) ||
        (mb->tail_data != NULL && target >= mb->tail_start &&
         target <= (mb->tail_start + (int64_t)mb->tail_size)))
    {
        mb->read_cursor = target;
        ma_mutex_unlock(&mb->lock);
        return MA_SUCCESS;
    }

    ma_mutex_unlock(&mb->lock);
    return MA_BAD_SEEK;
}

ma_result map_buffer_decoder_tell(
    ma_decoder *pDecoder,
    ma_int64 *pCursor)
{
    if (pDecoder == NULL || pDecoder->pUserData == NULL || pCursor == NULL)
        return MA_INVALID_ARGS;

    map_buffer_t *mb = (map_buffer_t *)pDecoder->pUserData;
    ma_mutex_lock(&mb->lock);
    *pCursor = (ma_int64)mb->read_cursor;
    ma_mutex_unlock(&mb->lock);

    return MA_SUCCESS;
}
