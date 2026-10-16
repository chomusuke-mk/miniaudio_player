/**
 * @file map_buffer.c
 * @brief Unified Two-Tier Audio Buffer: Bidirectional sliding window cache and
 *        decoder callbacks abstraction.
 */

#include "map_buffer.h"
#include <stdlib.h>
#include <string.h>

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

    /* High-performance vectorized copy into circular ring buffer */
    const uint8_t *src = pData;
    size_t to_write = size;
    int64_t start_off = offset;

    if (to_write > mb->capacity)
    {
        size_t excess = to_write - mb->capacity;
        src += excess;
        start_off += (int64_t)excess;
        to_write = mb->capacity;
    }

    size_t start_idx = (size_t)(start_off % (int64_t)mb->capacity);
    size_t chunk1 = mb->capacity - start_idx;
    if (chunk1 > to_write)
    {
        chunk1 = to_write;
    }
    memcpy(mb->data + start_idx, src, chunk1);
    if (to_write > chunk1)
    {
        memcpy(mb->data, src + chunk1, to_write - chunk1);
    }

    /* Update range boundaries */
    if (mb->range_start == mb->range_end)
    {
        mb->range_start = offset;
        mb->range_end = offset + (int64_t)size;
    }
    else
    {
        if (offset + (int64_t)size > mb->range_end)
        {
            mb->range_end = offset + (int64_t)size;
        }
        if (offset < mb->range_start)
        {
            mb->range_start = offset;
        }

        /* Enforce sliding window capacity constraint */
        if (mb->range_end - mb->range_start > (int64_t)mb->capacity)
        {
            mb->range_start = mb->range_end - (int64_t)mb->capacity;
        }
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

        /* Check for finite file EOF */
        if (mb->total_size > 0 && req_offset >= mb->total_size)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_AT_END;
        }
        if (mb->is_eof && req_offset >= mb->range_end)
        {
            ma_mutex_unlock(&mb->lock);
            return MA_AT_END;
        }

        /* Check if requested byte is contained within cached sliding window */
        if (req_offset >= mb->range_start && req_offset < mb->range_end)
        {
            size_t available = (size_t)(mb->range_end - req_offset);
            size_t to_copy = (bytesToRead < available) ? bytesToRead : available;

            size_t start_idx = (size_t)(req_offset % (int64_t)mb->capacity);
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

        /* Check if requested byte was evicted backwards (seeking outside retained window) */
        if (req_offset < mb->range_start)
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

        /* Data not yet arrived (forward edge stall / network buffering): wait on event */
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

    /* If target is within currently retained window, instant cache hit! */
    if (target_offset >= mb->range_start && target_offset <= mb->range_end)
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

    if (mb->total_size > 0)
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

    /* Format probing seek handling: initial_bytes are fully available in [0..initial_bytes] */
    if (mb->is_probing)
    {
        int64_t targetOffset = 0;
        if (origin == ma_seek_origin_start)
        {
            targetOffset = byteOffset;
        }
        else if (origin == ma_seek_origin_current)
        {
            targetOffset = mb->read_cursor + byteOffset;
        }
        else if (origin == ma_seek_origin_end && mb->total_size > 0)
        {
            targetOffset = mb->total_size + byteOffset;
        }

        if (targetOffset >= 0 && (size_t)targetOffset <= mb->initial_bytes)
        {
            mb->read_cursor = targetOffset;
            ma_mutex_unlock(&mb->lock);
            return MA_SUCCESS;
        }
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
            return MA_NOT_IMPLEMENTED;
        }
        target = mb->total_size + (int64_t)byteOffset;
    }

    /* Relative seek forward or backward within currently available buffer */
    if (target >= mb->range_start && target <= mb->range_end)
    {
        mb->read_cursor = target;
        ma_mutex_unlock(&mb->lock);
        return MA_SUCCESS;
    }

    ma_mutex_unlock(&mb->lock);
    return MA_NOT_IMPLEMENTED;
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
