/**
 * @file map_event_dispatcher.h
 * @brief Thread-safe native reactive event dispatcher for miniaudio_player.
 *
 * Implements double-buffering, lockless O(1) audio thread producers, atomic dirty bitmask,
 * value deduplication, and a pre-allocated event ring buffer for Dart FFI delivery.
 */

#ifndef MAP_EVENT_DISPATCHER_H
#define MAP_EVENT_DISPATCHER_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

#include "miniaudio.h"
#include "miniaudio_player.h"
#include "map_common.h"
#include "map_seqlock.h"

#ifdef __cplusplus
extern "C"
{
#endif

#define MAP_EVENT_RING_CAPACITY 128
#define MAP_DEFAULT_TELEMETRY_INTERVAL_MS 33

    /* Portable 64-bit atomic fetch-or helper */
#ifndef ma_atomic_fetch_or_64
#if defined(__GNUC__) || defined(__clang__)
#define ma_atomic_fetch_or_64(ptr, val) __atomic_fetch_or((ma_uint64 *)(ptr), (ma_uint64)(val), __ATOMIC_SEQ_CST)
#elif defined(_MSC_VER)
#define ma_atomic_fetch_or_64(ptr, val) _InterlockedOr64((volatile __int64 *)(ptr), (__int64)(val))
#else
#define ma_atomic_fetch_or_64(ptr, val) (*(ptr) |= (val))
#endif
#endif

    /* ========================================================================= */
    /* Event Types Enumeration                                                   */
    /* ========================================================================= */

    typedef enum
    {
        MAP_EVENT_NONE               = 0,
        MAP_EVENT_STATE              = 1,
        MAP_EVENT_POSITION           = 2,
        MAP_EVENT_DURATION           = 3,
        MAP_EVENT_IS_PLAYING         = 4,
        MAP_EVENT_IS_BUFFERING       = 5,
        MAP_EVENT_IS_COMPLETED       = 6,
        MAP_EVENT_VOLUME             = 7,
        MAP_EVENT_RATE               = 8,
        MAP_EVENT_PITCH              = 9,
        MAP_EVENT_BITRATE            = 10,
        MAP_EVENT_BUFFER_SIZE        = 11,
        MAP_EVENT_DEVICE             = 12,
        MAP_EVENT_VISUALIZER         = 13,
        MAP_EVENT_VISUALIZER_ENABLED = 14,
        MAP_EVENT_BUFFERED_RANGE     = 15,
        MAP_EVENT_SILENCE_CONFIG     = 16,
        MAP_EVENT_SILENCE_SAVED      = 17,
        MAP_EVENT_EQUALIZER          = 18,
        MAP_EVENT_PREAMP             = 19,
        MAP_EVENT_REPLAY_GAIN        = 20,
        MAP_EVENT_BALANCE            = 21,
        MAP_EVENT_MONO               = 22,
        MAP_EVENT_CROSSFEED          = 23,
        MAP_EVENT_SPATIALIZER        = 24,
        MAP_EVENT_REVERB             = 25,
        MAP_EVENT_LIMITER            = 26,
        MAP_EVENT_ERROR              = 27
    } map_event_type_t;

    /* ========================================================================= */
    /* 64-bit Dirty Flags Bitmask                                                */
    /* ========================================================================= */

    typedef enum
    {
        MAP_DIRTY_NONE               = 0,
        MAP_DIRTY_STATE              = (1ULL << 0),
        MAP_DIRTY_POSITION           = (1ULL << 1),
        MAP_DIRTY_DURATION           = (1ULL << 2),
        MAP_DIRTY_IS_PLAYING         = (1ULL << 3),
        MAP_DIRTY_IS_BUFFERING       = (1ULL << 4),
        MAP_DIRTY_IS_COMPLETED       = (1ULL << 5),
        MAP_DIRTY_VOLUME             = (1ULL << 6),
        MAP_DIRTY_RATE               = (1ULL << 7),
        MAP_DIRTY_PITCH              = (1ULL << 8),
        MAP_DIRTY_BITRATE            = (1ULL << 9),
        MAP_DIRTY_BUFFER_SIZE        = (1ULL << 10),
        MAP_DIRTY_DEVICE             = (1ULL << 11),
        MAP_DIRTY_VISUALIZER         = (1ULL << 12),
        MAP_DIRTY_VISUALIZER_ENABLED = (1ULL << 13),
        MAP_DIRTY_BUFFERED_RANGE     = (1ULL << 14),
        MAP_DIRTY_SILENCE_CONFIG     = (1ULL << 15),
        MAP_DIRTY_SILENCE_SAVED      = (1ULL << 16),
        MAP_DIRTY_EQUALIZER          = (1ULL << 17),
        MAP_DIRTY_PREAMP             = (1ULL << 18),
        MAP_DIRTY_REPLAY_GAIN        = (1ULL << 19),
        MAP_DIRTY_BALANCE            = (1ULL << 20),
        MAP_DIRTY_MONO               = (1ULL << 21),
        MAP_DIRTY_CROSSFEED          = (1ULL << 22),
        MAP_DIRTY_SPATIALIZER        = (1ULL << 23),
        MAP_DIRTY_REVERB             = (1ULL << 24),
        MAP_DIRTY_LIMITER            = (1ULL << 25),
        MAP_DIRTY_ERROR              = (1ULL << 26)
    } map_dirty_flags_t;

#define MAP_DIRTY_TELEMETRY_MASK ( \
    (uint64_t)MAP_DIRTY_POSITION | \
    (uint64_t)MAP_DIRTY_VISUALIZER | \
    (uint64_t)MAP_DIRTY_BUFFERED_RANGE | \
    (uint64_t)MAP_DIRTY_SILENCE_SAVED \
)

#define MAP_DIRTY_DISCRETE_MASK (~MAP_DIRTY_TELEMETRY_MASK)

    /* ========================================================================= */
    /* Event Structures & Callbacks                                              */
    /* ========================================================================= */

    typedef struct map_event_spatializer
    {
        int32_t enabled;
        float width;
    } map_event_spatializer_t;

    /**
     * @brief Concrete event packet pushed over FFI to Dart NativeCallable.listener.
     */
    typedef struct map_event
    {
        int32_t type;            /**< map_event_type_t */
        int32_t padding;
        int64_t timestamp_ns;    /**< Monotonic timestamp in nanoseconds */
        union {
            int32_t state;       /**< miniaudio_player_playback_state_t */
            int64_t position_ms;
            int64_t duration_ms;
            int32_t is_playing;
            int32_t is_buffering;
            int32_t is_completed;
            float volume;
            float rate;
            float pitch;
            uint32_t bitrate;
            uint32_t buffer_size;
            miniaudio_device_info_t device;
            miniaudio_player_visualizer_data_t visualizer;
            int32_t visualizer_enabled;
            miniaudio_buffered_range_t buffered_range;
            miniaudio_player_silence_config_t silence_config;
            int64_t silence_saved_ms;
            miniaudio_player_equalizer_params_t equalizer;
            float preamp_db;
            miniaudio_player_replay_gain_config_t replay_gain;
            float balance;
            int32_t mono_enabled;
            int32_t crossfeed_mode;
            map_event_spatializer_t spatializer;
            miniaudio_player_reverb_config_t reverb;
            int32_t limiter_enabled;
            int32_t error_code;
        } data;
    } map_event_t;

    /* ========================================================================= */
    /* State Snapshot for Double-Buffering & Deduplication                       */
    /* ========================================================================= */

    typedef struct map_event_state
    {
        miniaudio_player_playback_state_t state;
        int64_t position_ms;
        int64_t duration_ms;
        int32_t is_playing;
        int32_t is_buffering;
        int32_t is_completed;
        float volume;
        float rate;
        float pitch;
        uint32_t bitrate;
        uint32_t buffer_size;
        miniaudio_device_info_t device;
        miniaudio_player_visualizer_data_t visualizer;
        int32_t visualizer_enabled;
        miniaudio_buffered_range_t buffered_range;
        miniaudio_player_silence_config_t silence_config;
        int64_t silence_saved_ms;
        miniaudio_player_equalizer_params_t equalizer;
        float preamp_db;
        miniaudio_player_replay_gain_config_t replay_gain;
        float balance;
        int32_t mono_enabled;
        int32_t crossfeed_mode;
        map_event_spatializer_t spatializer;
        miniaudio_player_reverb_config_t reverb;
        int32_t limiter_enabled;
        int32_t error_code;
    } map_event_state_t;

    /* ========================================================================= */
    /* Event Dispatcher Engine Handle                                            */
    /* ========================================================================= */

    typedef struct map_event_dispatcher
    {
        /* Double buffers */
        map_event_state_t pending;
        map_event_state_t last_emitted;

        /* Atomic Seqlocks for compound structs on pending */
        map_seqlock_t vis_seqlock;
        map_seqlock_t buffer_seqlock;

        /* Mutex for compound non-RT structs */
        ma_mutex compound_lock;
        ma_mutex vis_lock;

        /* Atomic 64-bit dirty bitmask */
        MA_ATOMIC(8, ma_uint64) dirty_mask;

        /* Callback configuration */
        miniaudio_player_event_cb callback;
        void *user_data;
        void (*maintenance_cb)(struct miniaudio_player *player);

        /* Rate limiting and timing */
        MA_ATOMIC(4, ma_uint32) telemetry_interval_ms;

        /* Dispatcher thread synchronization */
        ma_thread thread;
        ma_event wakeup_event;
        ma_mutex emit_lock;
        MA_ATOMIC(4, ma_uint32) is_running;
        MA_ATOMIC(4, ma_uint32) is_active_playback;

        /* Ring buffer for asynchronous Dart NativeCallable delivery */
        map_event_t event_ring[MAP_EVENT_RING_CAPACITY];
        MA_ATOMIC(4, ma_uint32) ring_head;

        /* Reference to player instance */
        struct miniaudio_player *player;
    } map_event_dispatcher_t;

    /* ========================================================================= */
    /* Dispatcher Engine Lifecycle & Management APIs                             */
    /* ========================================================================= */

    ma_result map_event_dispatcher_init(
        map_event_dispatcher_t *disp,
        struct miniaudio_player *player,
        miniaudio_player_event_cb callback,
        void *user_data);

    void map_event_dispatcher_uninit(map_event_dispatcher_t *disp);

    void map_event_dispatcher_set_callback(
        map_event_dispatcher_t *disp,
        miniaudio_player_event_cb callback,
        void *user_data);

    void map_event_dispatcher_set_interval(
        map_event_dispatcher_t *disp,
        uint32_t interval_ms);

    /* ========================================================================= */
    /* Lockless O(1) Producer Methods (Called from RT audio thread & API callers) */
    /* ========================================================================= */

    void map_event_dispatcher_post_state(map_event_dispatcher_t *disp, miniaudio_player_playback_state_t state);
    void map_event_dispatcher_post_position(map_event_dispatcher_t *disp, int64_t position_ms);
    void map_event_dispatcher_post_duration(map_event_dispatcher_t *disp, int64_t duration_ms);
    void map_event_dispatcher_post_playing(map_event_dispatcher_t *disp, int32_t is_playing);
    void map_event_dispatcher_post_buffering(map_event_dispatcher_t *disp, int32_t is_buffering);
    void map_event_dispatcher_post_completed(map_event_dispatcher_t *disp, int32_t is_completed);
    void map_event_dispatcher_post_visualizer(map_event_dispatcher_t *disp, const miniaudio_player_visualizer_data_t *vis);
    void map_event_dispatcher_post_buffered_range(map_event_dispatcher_t *disp, const miniaudio_buffered_range_t *range);
    void map_event_dispatcher_post_silence_saved(map_event_dispatcher_t *disp, int64_t saved_ms);
    void map_event_dispatcher_post_volume(map_event_dispatcher_t *disp, float volume);
    void map_event_dispatcher_post_rate(map_event_dispatcher_t *disp, float rate);
    void map_event_dispatcher_post_pitch(map_event_dispatcher_t *disp, float pitch);
    void map_event_dispatcher_post_bitrate(map_event_dispatcher_t *disp, uint32_t bitrate);
    void map_event_dispatcher_post_buffer_size(map_event_dispatcher_t *disp, uint32_t buffer_size);
    void map_event_dispatcher_post_device(map_event_dispatcher_t *disp, const miniaudio_device_info_t *device);
    void map_event_dispatcher_post_equalizer(map_event_dispatcher_t *disp, const miniaudio_player_equalizer_params_t *eq);
    void map_event_dispatcher_post_silence_config(map_event_dispatcher_t *disp, const miniaudio_player_silence_config_t *silence);
    void map_event_dispatcher_post_preamp(map_event_dispatcher_t *disp, float preamp_db);
    void map_event_dispatcher_post_replay_gain(map_event_dispatcher_t *disp, const miniaudio_player_replay_gain_config_t *rg);
    void map_event_dispatcher_post_balance(map_event_dispatcher_t *disp, float balance);
    void map_event_dispatcher_post_mono(map_event_dispatcher_t *disp, int32_t mono_enabled);
    void map_event_dispatcher_post_crossfeed(map_event_dispatcher_t *disp, int32_t crossfeed_mode);
    void map_event_dispatcher_post_spatializer(map_event_dispatcher_t *disp, int32_t enabled, float width);
    void map_event_dispatcher_post_reverb(map_event_dispatcher_t *disp, const miniaudio_player_reverb_config_t *reverb);
    void map_event_dispatcher_post_limiter(map_event_dispatcher_t *disp, int32_t limiter_enabled);
    void map_event_dispatcher_post_visualizer_enabled(map_event_dispatcher_t *disp, int32_t visualizer_enabled);
    void map_event_dispatcher_post_error(map_event_dispatcher_t *disp, int32_t error_code);

    /* ========================================================================= */
    /* Event Processing and Flush                                                */
    /* ========================================================================= */

    void map_event_dispatcher_process_events(map_event_dispatcher_t *disp);
    void map_event_dispatcher_flush(map_event_dispatcher_t *disp);

#ifdef __cplusplus
}
#endif

#endif /* MAP_EVENT_DISPATCHER_H */
