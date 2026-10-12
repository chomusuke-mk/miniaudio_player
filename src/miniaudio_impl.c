/**
 * @file miniaudio_impl.c
 * @brief Dedicated translation unit for Miniaudio engine implementation.
 */

#define STB_VORBIS_HEADER_ONLY
#include "decoders/stb_vorbis.c"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-compare"
#endif

#undef STB_VORBIS_HEADER_ONLY
#include "decoders/stb_vorbis.c"

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#include "map_common.h"

ma_result map_thread_create(ma_thread *pThread, map_thread_entry_proc entryProc, void *pData)
{
    return ma_thread_create(pThread, ma_thread_priority_normal, 0, (ma_thread_entry_proc)entryProc, pData, NULL);
}

void map_thread_wait(ma_thread *pThread)
{
    ma_thread_wait(pThread);
}
