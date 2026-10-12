/**
 * @file map_seqlock.h
 * @brief Lock-free reader/writer sequence lock with CPU hardware memory fences.
 */

#ifndef MAP_SEQLOCK_H
#define MAP_SEQLOCK_H

#include "miniaudio.h"
#include "map_common.h"

#if defined(__GNUC__) || defined(__clang__)
    #define MAP_SEQLOCK_FENCE_RELEASE() __atomic_thread_fence(__ATOMIC_RELEASE)
    #define MAP_SEQLOCK_FENCE_ACQUIRE() __atomic_thread_fence(__ATOMIC_ACQUIRE)
#elif defined(_MSC_VER)
    #if defined(_M_ARM) || defined(_M_ARM64)
        #include <intrin.h>
        #define MAP_SEQLOCK_FENCE_RELEASE() __dmb(_ARM64_BARRIER_ISH)
        #define MAP_SEQLOCK_FENCE_ACQUIRE() __dmb(_ARM64_BARRIER_ISHLD)
    #elif defined(_M_IX86) || defined(_M_X64)
        #include <intrin.h>
        #define MAP_SEQLOCK_FENCE_RELEASE() _ReadWriteBarrier()
        #define MAP_SEQLOCK_FENCE_ACQUIRE() _ReadWriteBarrier()
    #else
        #define MAP_SEQLOCK_FENCE_RELEASE() MemoryBarrier()
        #define MAP_SEQLOCK_FENCE_ACQUIRE() MemoryBarrier()
    #endif
#else
    #define MAP_SEQLOCK_FENCE_RELEASE() MAP_COMPILER_BARRIER()
    #define MAP_SEQLOCK_FENCE_ACQUIRE() MAP_COMPILER_BARRIER()
#endif

static MA_INLINE void map_seqlock_pause(void)
{
#if defined(__GNUC__) || defined(__clang__)
    #if defined(__x86_64__) || defined(__i386__)
        __builtin_ia32_pause();
    #elif defined(__aarch64__) || defined(__arm__)
        __asm__ __volatile__("isb; yield" ::: "memory");
    #else
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
    #endif
#elif defined(_MSC_VER)
    #if defined(_M_IX86) || defined(_M_X64)
        _mm_pause();
    #elif defined(_M_ARM) || defined(_M_ARM64)
        __isb(_ARM64_BARRIER_SY);
        __yield();
    #else
        MemoryBarrier();
    #endif
#else
    MAP_COMPILER_BARRIER();
#endif
}

typedef struct
{
    MAP_ALIGN_CACHE_LINE MA_ATOMIC(4, ma_uint32) sequence;
} map_seqlock_t;

static MA_INLINE void map_seqlock_init(map_seqlock_t *sl)
{
    if (sl != NULL)
    {
        ma_atomic_store_32(&sl->sequence, 0);
    }
}

static MA_INLINE void map_seqlock_write_begin(map_seqlock_t *sl)
{
    ma_atomic_fetch_add_32(&sl->sequence, 1);
    MAP_SEQLOCK_FENCE_RELEASE();
}

static MA_INLINE void map_seqlock_write_end(map_seqlock_t *sl)
{
    MAP_SEQLOCK_FENCE_RELEASE();
    ma_atomic_fetch_add_32(&sl->sequence, 1);
}

static MA_INLINE ma_uint32 map_seqlock_read_begin(const map_seqlock_t *sl)
{
    ma_uint32 seq;
    for (;;)
    {
        seq = ma_atomic_load_32(&sl->sequence);
        if ((seq & 1) == 0)
        {
            break;
        }
        map_seqlock_pause();
    }
    MAP_SEQLOCK_FENCE_ACQUIRE();
    return seq;
}

static MA_INLINE ma_bool32 map_seqlock_read_retry(const map_seqlock_t *sl, ma_uint32 start_seq)
{
    MAP_SEQLOCK_FENCE_ACQUIRE();
    ma_uint32 end_seq = ma_atomic_load_32(&sl->sequence);
    ma_bool32 retry = (start_seq != end_seq) || ((start_seq & 1) != 0);
    if (retry)
    {
        map_seqlock_pause();
    }
    return retry;
}

#endif /* MAP_SEQLOCK_H */
