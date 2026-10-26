/**
 * @file map_common.h
 * @brief Common definitions, vector math, logging, and utility helpers.
 */

#ifndef MAP_COMMON_H
#define MAP_COMMON_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <stdio.h>
#include <stdarg.h>

#include "miniaudio.h"
#include "miniaudio_player.h"

#if defined(_WIN32)
#include <windows.h>
#endif

#if defined(__ANDROID__)
#include <android/log.h>
#include <jni.h>
#include <dlfcn.h>
#include <strings.h>
#include <link.h>
#include <elf.h>
#endif

#if defined(__wasm_simd128__)
#include <wasm_simd128.h>
#define MAP_HAS_WASM_SIMD 1
#elif defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define MAP_HAS_NEON 1
#elif defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#include <xmmintrin.h>
#if defined(__SSE4_1__)
#include <smmintrin.h>
#endif
#define MAP_HAS_SSE2 1
#define MAP_HAS_SSE  1
#ifndef __SSE2__
#define __SSE2__ 1
#endif
#ifndef __SSE__
#define __SSE__ 1
#endif
#elif defined(__SSE__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 1)
#include <xmmintrin.h>
#define MAP_HAS_SSE  1
#ifndef __SSE__
#define __SSE__ 1
#endif
#endif

/* Cache-line alignment macro */
#ifndef MAP_CACHE_LINE_SIZE
#define MAP_CACHE_LINE_SIZE 64
#endif

#if defined(_MSC_VER)
#define MAP_ALIGN_CACHE_LINE __declspec(align(64))
#elif defined(__GNUC__) || defined(__clang__)
#define MAP_ALIGN_CACHE_LINE __attribute__((aligned(64)))
#else
#define MAP_ALIGN_CACHE_LINE
#endif

/* Memory / compiler barrier macros */
#ifndef MAP_COMPILER_BARRIER
#if defined(__GNUC__) || defined(__clang__)
#define MAP_COMPILER_BARRIER() __asm__ __volatile__("" ::: "memory")
#elif defined(_MSC_VER)
#define MAP_COMPILER_BARRIER() _ReadWriteBarrier()
#else
#define MAP_COMPILER_BARRIER()
#endif
#endif

/* Mathematical constants */
#ifndef MA_PI_D
#define MA_PI_D 3.14159265358979323846264
#endif
#ifndef MA_PI_F
#define MA_PI_F 3.14159265358979323846264f
#endif
#ifndef MA_SEEK_TARGET_NONE
#define MA_SEEK_TARGET_NONE         (~(ma_uint64)0)
#endif

/* Portable atomic helper operations across translation units */
#if defined(__GNUC__) || defined(__clang__)
#ifndef ma_atomic_load_32
#define ma_atomic_load_32(ptr)           __atomic_load_n((const ma_uint32 *)(ptr), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_store_32
#define ma_atomic_store_32(ptr, val)     __atomic_store_n((ma_uint32 *)(ptr), (ma_uint32)(val), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_load_64
#define ma_atomic_load_64(ptr)           __atomic_load_n((const ma_uint64 *)(ptr), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_store_64
#define ma_atomic_store_64(ptr, val)     __atomic_store_n((ma_uint64 *)(ptr), (ma_uint64)(val), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_fetch_add_32
#define ma_atomic_fetch_add_32(ptr, val) __atomic_fetch_add((ma_uint32 *)(ptr), (ma_uint32)(val), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_exchange_32
#define ma_atomic_exchange_32(ptr, val)  __atomic_exchange_n((ma_uint32 *)(ptr), (ma_uint32)(val), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_exchange_64
#define ma_atomic_exchange_64(ptr, val)  __atomic_exchange_n((ma_uint64 *)(ptr), (ma_uint64)(val), __ATOMIC_SEQ_CST)
#endif
#ifndef ma_atomic_bool32_set
#define ma_atomic_bool32_set(ptr, val)   __atomic_store_n((ma_bool32 *)(ptr), (ma_bool32)(val), __ATOMIC_SEQ_CST)
#endif
#elif defined(_MSC_VER)
#include <intrin.h>
#ifndef ma_atomic_load_32
#define ma_atomic_load_32(ptr)           (*(volatile const ma_uint32 *)(ptr))
#endif
#ifndef ma_atomic_store_32
#define ma_atomic_store_32(ptr, val)     _InterlockedExchange((volatile long *)(ptr), (long)(val))
#endif
#ifndef ma_atomic_load_64
#define ma_atomic_load_64(ptr)           (*(volatile const ma_uint64 *)(ptr))
#endif
#ifndef ma_atomic_store_64
#define ma_atomic_store_64(ptr, val)     _InterlockedExchange64((volatile __int64 *)(ptr), (__int64)(val))
#endif
#ifndef ma_atomic_fetch_add_32
#define ma_atomic_fetch_add_32(ptr, val) _InterlockedExchangeAdd((volatile long *)(ptr), (long)(val))
#endif
#ifndef ma_atomic_exchange_32
#define ma_atomic_exchange_32(ptr, val)  _InterlockedExchange((volatile long *)(ptr), (long)(val))
#endif
#ifndef ma_atomic_exchange_64
#define ma_atomic_exchange_64(ptr, val)  _InterlockedExchange64((volatile __int64 *)(ptr), (__int64)(val))
#endif
#ifndef ma_atomic_bool32_set
#define ma_atomic_bool32_set(ptr, val)   _InterlockedExchange((volatile long *)(ptr), (long)(val))
#endif
#endif

/* Threading declarations and wrappers */
#ifndef MA_THREADCALL
#if defined(_WIN32)
#define MA_THREADCALL WINAPI
typedef unsigned long ma_thread_result;
#else
#define MA_THREADCALL
typedef void* ma_thread_result;
#endif
#endif
typedef ma_thread_result (MA_THREADCALL * map_thread_entry_proc)(void* pData);

#if !defined(MA_NO_THREADING)
ma_result map_thread_create(ma_thread *pThread, map_thread_entry_proc entryProc, void *pData);
void map_thread_wait(ma_thread *pThread);
#endif

#if !defined(MINIAUDIO_IMPLEMENTATION)
#if !defined(MA_NO_THREADING)
#ifndef ma_thread_create
#define ma_thread_create(pThread, priority, stackSize, entryProc, pData, pAlloc) map_thread_create(pThread, entryProc, pData)
#endif
#ifndef ma_thread_wait
#define ma_thread_wait(pThread) map_thread_wait(pThread)
#endif
#endif

#if defined(_WIN32)
static MA_INLINE void ma_sleep(ma_uint32 milliseconds)
{
    Sleep(milliseconds);
}
#else
#include <time.h>
extern int nanosleep(const struct timespec *req, struct timespec *rem);
static MA_INLINE void ma_sleep(ma_uint32 milliseconds)
{
    struct timespec ts;
    ts.tv_sec = (time_t)(milliseconds / 1000);
    ts.tv_nsec = (long)((milliseconds % 1000) * 1000000L);
    nanosleep(&ts, NULL);
}
#endif
#endif

/* Systematic Subnormal (Denormal) Hardware and Software Flushing */
static MA_INLINE float map_flush_denormal_f32(float x)
{
    union { float f; uint32_t u; } v;
    v.f = x;
    /* If absolute exponent is below ~1.08e-19 (0x20000000), force to 0.0f without branching */
    uint32_t is_normal = ((v.u & 0x7FFFFFFFU) >= 0x20000000U);
    v.u &= (0U - is_normal);
    return v.f;
}

#if defined(MAP_HAS_WASM_SIMD)
static MA_INLINE v128_t map_wasm_flush_denormal_v128(v128_t v, v128_t v_thresh)
{
    v128_t mask = wasm_f32x4_ge(wasm_f32x4_abs(v), v_thresh);
    return wasm_v128_and(v, mask);
}
#endif

static MA_INLINE unsigned int map_disable_denormals(void)
{
    unsigned int prevState = 0;
#if defined(_MSC_VER) && (defined(_M_IX86) || defined(_M_X64))
    _controlfp_s(&prevState, 0, 0);
    unsigned int unused;
    _controlfp_s(&unused, prevState | _DN_FLUSH, _MCW_DN);
#elif defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#if defined(MAP_HAS_SSE)
    prevState = _mm_getcsr();
    _mm_setcsr(prevState | 0x8040); /* Bit 15: FTZ, Bit 6: DAZ */
#endif
#elif defined(__aarch64__)
    uint64_t fpcr;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    prevState = (unsigned int)fpcr;
    __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr | (1ULL << 24) | (1ULL << 25)));
#elif defined(__arm__) || defined(__ARM_NEON)
    uint32_t fpscr;
    __asm__ __volatile__("vmrs %0, fpscr" : "=r"(fpscr));
    prevState = fpscr;
    __asm__ __volatile__("vmsr fpscr, %0" : : "r"(fpscr | (1U << 24) | (1U << 25)));
#endif
    return prevState;
}

/* Global log level and logging functions (defined in miniaudio_player.c) */
extern int32_t g_map_log_level;
void map_log_print(int32_t level, const char *tag, const char *fmt, ...);
void map_miniaudio_log_callback(void *pUserData, ma_uint32 level, const char *pMessage);

/* EQ band constants and frequencies */
#define MAP_EQ_BAND_COUNT 10
#define MAP_EQ_Q 1.15f
#define MAP_EQ_SHELF_SLOPE 0.7071067811865475

extern const double g_map_eq_frequencies[MAP_EQ_BAND_COUNT];

/* Custom decoders */
extern ma_decoding_backend_vtable *g_map_custom_decoders[4];
ma_uint32 map_get_custom_decoder_count(void);

/* Portable string duplication helper */
static MA_INLINE char *map_strdup(const char *s)
{
    size_t len;
    char *copy;
    if (s == NULL)
        return NULL;
    len = strlen(s);
    copy = (char *)malloc(len + 1);
    if (copy != NULL)
    {
        memcpy(copy, s, len + 1);
    }
    return copy;
}

#if defined(_WIN32)
static MA_INLINE wchar_t *map_utf8_to_wchar(const char *str)
{
    int len;
    wchar_t *wstr;
    if (str == NULL)
        return NULL;
    len = MultiByteToWideChar(CP_UTF8, 0, str, -1, NULL, 0);
    if (len <= 0)
        return NULL;
    wstr = (wchar_t *)malloc((size_t)len * sizeof(wchar_t));
    if (wstr == NULL)
        return NULL;
    MultiByteToWideChar(CP_UTF8, 0, str, -1, wstr, len);
    return wstr;
}
#endif

/* Computes absolute peak amplitude across all channels in a single frame.
   Vectorized via ARM NEON and x86 SSE with branchless reductions and unrolled paths (NP3-06). */
static MA_INLINE float map_frame_peak(const float *frame, ma_uint32 channels)
{
    if (channels == 1)
    {
        return fabsf(frame[0]);
    }
    else if (channels == 2)
    {
        float v0 = fabsf(frame[0]);
        float v1 = fabsf(frame[1]);
        return (v0 > v1) ? v0 : v1;
    }
#if defined(MAP_HAS_NEON)
    else if (channels == 4)
    {
        float32x4_t v = vabsq_f32(vld1q_f32(frame));
#if defined(__aarch64__)
        return vmaxvq_f32(v);
#else
        float32x2_t max2 = vpmax_f32(vget_low_f32(v), vget_high_f32(v));
        max2 = vpmax_f32(max2, max2);
        return vget_lane_f32(max2, 0);
#endif
    }
    else if (channels == 6) /* 5.1 Surround */
    {
        float32x4_t v0 = vabsq_f32(vld1q_f32(frame));
        float s4 = fabsf(frame[4]);
        float s5 = fabsf(frame[5]);
        float tail = (s4 > s5) ? s4 : s5;
#if defined(__aarch64__)
        float m0 = vmaxvq_f32(v0);
        return (m0 > tail) ? m0 : tail;
#else
        float32x2_t max2 = vpmax_f32(vget_low_f32(v0), vget_high_f32(v0));
        max2 = vpmax_f32(max2, max2);
        float m0 = vget_lane_f32(max2, 0);
        return (m0 > tail) ? m0 : tail;
#endif
    }
    else if (channels == 8) /* 7.1 Surround */
    {
        float32x4_t v0 = vabsq_f32(vld1q_f32(frame));
        float32x4_t v1 = vabsq_f32(vld1q_f32(frame + 4));
        float32x4_t v = vmaxq_f32(v0, v1);
#if defined(__aarch64__)
        return vmaxvq_f32(v);
#else
        float32x2_t max2 = vpmax_f32(vget_low_f32(v), vget_high_f32(v));
        max2 = vpmax_f32(max2, max2);
        return vget_lane_f32(max2, 0);
#endif
    }
#elif defined(MAP_HAS_WASM_SIMD)
    else if (channels == 4)
    {
        v128_t v = wasm_f32x4_abs(wasm_v128_load(frame));
        v = wasm_f32x4_pmax(v, wasm_i32x4_shuffle(v, v, 2, 3, 0, 1));
        v = wasm_f32x4_pmax(v, wasm_i32x4_shuffle(v, v, 1, 0, 3, 2));
        return wasm_f32x4_extract_lane(v, 0);
    }
    else if (channels == 6) /* 5.1 Surround */
    {
        v128_t v = wasm_f32x4_abs(wasm_v128_load(frame));
        v = wasm_f32x4_pmax(v, wasm_i32x4_shuffle(v, v, 2, 3, 0, 1));
        v = wasm_f32x4_pmax(v, wasm_i32x4_shuffle(v, v, 1, 0, 3, 2));
        float m0 = wasm_f32x4_extract_lane(v, 0);
        float s4 = fabsf(frame[4]);
        float s5 = fabsf(frame[5]);
        float tail = (s4 > s5) ? s4 : s5;
        return (m0 > tail) ? m0 : tail;
    }
    else if (channels == 8) /* 7.1 Surround */
    {
        v128_t v0 = wasm_f32x4_abs(wasm_v128_load(frame));
        v128_t v1 = wasm_f32x4_abs(wasm_v128_load(frame + 4));
        v128_t v = wasm_f32x4_pmax(v0, v1);
        v = wasm_f32x4_pmax(v, wasm_i32x4_shuffle(v, v, 2, 3, 0, 1));
        v = wasm_f32x4_pmax(v, wasm_i32x4_shuffle(v, v, 1, 0, 3, 2));
        return wasm_f32x4_extract_lane(v, 0);
    }
#elif defined(MAP_HAS_SSE)
    else if (channels == 4)
    {
        __m128 v = _mm_loadu_ps(frame);
        __m128 sign_mask = _mm_castsi128_ps(_mm_set1_epi32(0x7fffffff));
        v = _mm_and_ps(v, sign_mask);
        v = _mm_max_ps(v, _mm_shuffle_ps(v, v, _MM_SHUFFLE(1, 0, 3, 2)));
        v = _mm_max_ps(v, _mm_shuffle_ps(v, v, _MM_SHUFFLE(2, 3, 0, 1)));
        return _mm_cvtss_f32(v);
    }
    else if (channels == 6) /* 5.1 Surround */
    {
        __m128 sign_mask = _mm_castsi128_ps(_mm_set1_epi32(0x7fffffff));
        __m128 v = _mm_and_ps(_mm_loadu_ps(frame), sign_mask);
        v = _mm_max_ps(v, _mm_shuffle_ps(v, v, _MM_SHUFFLE(1, 0, 3, 2)));
        v = _mm_max_ps(v, _mm_shuffle_ps(v, v, _MM_SHUFFLE(2, 3, 0, 1)));
        float m0 = _mm_cvtss_f32(v);
        float s4 = fabsf(frame[4]);
        float s5 = fabsf(frame[5]);
        float tail = (s4 > s5) ? s4 : s5;
        return (m0 > tail) ? m0 : tail;
    }
    else if (channels == 8) /* 7.1 Surround */
    {
        __m128 sign_mask = _mm_castsi128_ps(_mm_set1_epi32(0x7fffffff));
        __m128 v0 = _mm_and_ps(_mm_loadu_ps(frame), sign_mask);
        __m128 v1 = _mm_and_ps(_mm_loadu_ps(frame + 4), sign_mask);
        __m128 v = _mm_max_ps(v0, v1);
        v = _mm_max_ps(v, _mm_shuffle_ps(v, v, _MM_SHUFFLE(1, 0, 3, 2)));
        v = _mm_max_ps(v, _mm_shuffle_ps(v, v, _MM_SHUFFLE(2, 3, 0, 1)));
        return _mm_cvtss_f32(v);
    }
#endif
    else
    {
        float peak = 0.0f;
        ma_uint32 c = 0;
        for (; c + 3 < channels; c += 4)
        {
            float v0 = fabsf(frame[c]);
            float v1 = fabsf(frame[c + 1]);
            float v2 = fabsf(frame[c + 2]);
            float v3 = fabsf(frame[c + 3]);
            float m0 = (v0 > v1) ? v0 : v1;
            float m1 = (v2 > v3) ? v2 : v3;
            float m = (m0 > m1) ? m0 : m1;
            if (m > peak) peak = m;
        }
        for (; c < channels; c++)
        {
            float v = fabsf(frame[c]);
            if (v > peak) peak = v;
        }
        return peak;
    }
}

/* Clamps frequency safely below the Nyquist limit and above sub-audio 10 Hz lower bound */
static MA_INLINE double map_clamp_frequency(double freq, ma_uint32 sampleRate)
{
    double nyquist = (double)sampleRate * 0.499;
    if (freq > nyquist)
        return nyquist;
    if (freq < 10.0)
        return 10.0;
    return freq;
}

/* Clamps gain in dB to [-24.0, +24.0] */
static MA_INLINE float map_clamp_gain_db(float gainDB)
{
    if (gainDB < -24.0f)
        return -24.0f;
    if (gainDB > 24.0f)
        return 24.0f;
    return gainDB;
}

/* Resets the underlying decoding backend and converter for streaming byte-range seeks */
ma_result map_decoder_reset_stream(ma_decoder *pDecoder, int64_t newStreamOffset, ma_uint64 targetFrame);

/* Unlatches EOF state in backend decoders (e.g. dr_mp3) when new stream bytes arrive */
ma_result map_decoder_unlatch_stream_eof(ma_decoder *pDecoder);

/* Returns the uncompressed bytes per PCM frame for container-based streams (e.g. WAV), or 1 if compressed/unknown */
ma_uint32 map_decoder_get_raw_bytes_per_frame(ma_decoder *pDecoder);

/* Computes container byte offset for seeking stream (e.g. WAV dataChunkDataPos + frame * bpf), or -1 if not container */
int64_t map_decoder_get_stream_seek_byte(ma_decoder *pDecoder, ma_uint64 targetFrame);

/* Returns the byte offset of the first audio sample/frame within the container/stream (skipping ID3v2, RIFF chunks, etc.) */
int64_t map_decoder_get_audio_data_offset(ma_decoder *pDecoder);

/* Initializes decoder with custom tell callback support */
ma_result map_decoder_init_ex(
    ma_decoder_read_proc onRead,
    ma_decoder_seek_proc onSeek,
    ma_decoder_tell_proc onTell,
    void *pUserData,
    const ma_decoder_config *pConfig,
    ma_decoder *pDecoder);

#endif /* MAP_COMMON_H */
