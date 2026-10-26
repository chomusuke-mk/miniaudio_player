/**
 * @file map_event_dispatcher.c
 * @brief Native reactive event dispatcher engine implementation for miniaudio_player.
 */

#include "map_event_dispatcher.h"

static ma_uint64 map_get_monotonic_time_ns(void)
{
#if defined(_WIN32)
    static LARGE_INTEGER freq;
    static int init = 0;
    if (!init)
    {
        QueryPerformanceFrequency(&freq);
        init = 1;
    }
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return (ma_uint64)((counter.QuadPart * 1000000000ULL) / freq.QuadPart);
#elif defined(CLOCK_MONOTONIC)
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (ma_uint64)ts.tv_sec * 1000000000ULL + (ma_uint64)ts.tv_nsec;
#else
    return (ma_uint64)time(NULL) * 1000000000ULL;
#endif
}

static MA_INLINE void map_atomic_store_float(float *ptr, float val)
{
#if defined(__GNUC__) || defined(__clang__)
    uint32_t u;
    memcpy(&u, &val, sizeof(u));
    __atomic_store_n((uint32_t *)ptr, u, __ATOMIC_RELEASE);
#elif defined(_MSC_VER)
    uint32_t u;
    memcpy(&u, &val, sizeof(u));
    _InterlockedExchange((volatile long *)ptr, (long)u);
#else
    *ptr = val;
#endif
}

static MA_INLINE float map_atomic_load_float(const float *ptr)
{
#if defined(__GNUC__) || defined(__clang__)
    uint32_t u = __atomic_load_n((const uint32_t *)ptr, __ATOMIC_ACQUIRE);
    float val;
    memcpy(&val, &u, sizeof(val));
    return val;
#elif defined(_MSC_VER)
    long u = *(volatile const long *)ptr;
    float val;
    memcpy(&val, &u, sizeof(val));
    return val;
#else
    return *ptr;
#endif
}

static MA_INLINE void map_atomic_store_i64(int64_t *ptr, int64_t val)
{
#if defined(__GNUC__) || defined(__clang__)
    __atomic_store_n(ptr, val, __ATOMIC_RELEASE);
#elif defined(_MSC_VER)
    _InterlockedExchange64((volatile __int64 *)ptr, (__int64)val);
#else
    *ptr = val;
#endif
}

static MA_INLINE int64_t map_atomic_load_i64(const int64_t *ptr)
{
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
#elif defined(_MSC_VER)
    return *(volatile const __int64 *)ptr;
#else
    return *ptr;
#endif
}

static MA_INLINE void map_atomic_store_i32(int32_t *ptr, int32_t val)
{
#if defined(__GNUC__) || defined(__clang__)
    __atomic_store_n(ptr, val, __ATOMIC_RELEASE);
#elif defined(_MSC_VER)
    _InterlockedExchange((volatile long *)ptr, (long)val);
#else
    *ptr = val;
#endif
}

static MA_INLINE int32_t map_atomic_load_i32(const int32_t *ptr)
{
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
#elif defined(_MSC_VER)
    return *(volatile const long *)ptr;
#else
    return *ptr;
#endif
}

static MA_INLINE void map_atomic_store_u32(uint32_t *ptr, uint32_t val)
{
#if defined(__GNUC__) || defined(__clang__)
    __atomic_store_n(ptr, val, __ATOMIC_RELEASE);
#elif defined(_MSC_VER)
    _InterlockedExchange((volatile long *)ptr, (long)val);
#else
    *ptr = val;
#endif
}

static MA_INLINE uint32_t map_atomic_load_u32(const uint32_t *ptr)
{
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
#elif defined(_MSC_VER)
    return *(volatile const unsigned long *)ptr;
#else
    return *ptr;
#endif
}

static MA_INLINE void map_atomic_store_ptr(void * volatile *ptr, void *val)
{
#if defined(__GNUC__) || defined(__clang__)
    __atomic_store_n(ptr, val, __ATOMIC_RELEASE);
#elif defined(_MSC_VER)
    _InterlockedExchangePointer(ptr, val);
#else
    *ptr = val;
#endif
}

static MA_INLINE void *map_atomic_load_ptr(void * const volatile *ptr)
{
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
#elif defined(_MSC_VER)
    return *ptr;
#else
    return *ptr;
#endif
}

static void map_event_dispatcher_emit(
    map_event_dispatcher_t *disp,
    int32_t type,
    const void *pData,
    size_t size)
{
    if (disp == NULL)
        return;

    miniaudio_player_event_cb cb = (miniaudio_player_event_cb)map_atomic_load_ptr((void * const volatile *)&disp->callback);
    if (cb == NULL)
        return;

    uint32_t slot = ma_atomic_fetch_add_32(&disp->ring_head, 1) % MAP_EVENT_RING_CAPACITY;
    map_event_t *ev = &disp->event_ring[slot];
    memset(ev, 0, sizeof(*ev));
    ev->type = type;
    ev->padding = 0;
    ev->timestamp_ns = (int64_t)map_get_monotonic_time_ns();

    if (pData != NULL && size > 0)
    {
        if (size > sizeof(ev->data))
            size = sizeof(ev->data);
        memcpy(&ev->data, pData, size);
    }

    void *ud = map_atomic_load_ptr((void * const volatile *)&disp->user_data);
    cb(ud, ev);
}

void map_event_dispatcher_process_events(map_event_dispatcher_t *disp)
{
    if (disp == NULL)
        return;

    ma_mutex_lock(&disp->emit_lock);

    miniaudio_player_event_cb cb = (miniaudio_player_event_cb)map_atomic_load_ptr((void * const volatile *)&disp->callback);
    if (cb == NULL)
    {
        ma_mutex_unlock(&disp->emit_lock);
        return;
    }

    uint64_t dirty = ma_atomic_exchange_64(&disp->dirty_mask, 0);
    if (dirty == 0)
    {
        ma_mutex_unlock(&disp->emit_lock);
        return;
    }

    /* 1. STATE */
    if (dirty & MAP_DIRTY_STATE)
    {
        miniaudio_player_playback_state_t val = (miniaudio_player_playback_state_t)map_atomic_load_i32((const int32_t *)&disp->pending.state);
        if (val != disp->last_emitted.state)
        {
            disp->last_emitted.state = val;
            int32_t st = (int32_t)val;
            map_event_dispatcher_emit(disp, MAP_EVENT_STATE, &st, sizeof(st));
        }
    }

    /* 2. POSITION */
    if (dirty & MAP_DIRTY_POSITION)
    {
        int64_t pos = map_atomic_load_i64(&disp->pending.position_ms);
        if (pos != disp->last_emitted.position_ms)
        {
            disp->last_emitted.position_ms = pos;
            map_event_dispatcher_emit(disp, MAP_EVENT_POSITION, &pos, sizeof(pos));
        }
    }

    /* 3. DURATION */
    if (dirty & MAP_DIRTY_DURATION)
    {
        int64_t dur = map_atomic_load_i64(&disp->pending.duration_ms);
        if (dur != disp->last_emitted.duration_ms)
        {
            disp->last_emitted.duration_ms = dur;
            map_event_dispatcher_emit(disp, MAP_EVENT_DURATION, &dur, sizeof(dur));
        }
    }

    /* 4. IS_PLAYING */
    if (dirty & MAP_DIRTY_IS_PLAYING)
    {
        int32_t p = map_atomic_load_i32(&disp->pending.is_playing);
        if (p != disp->last_emitted.is_playing)
        {
            disp->last_emitted.is_playing = p;
            map_event_dispatcher_emit(disp, MAP_EVENT_IS_PLAYING, &p, sizeof(p));
        }
    }

    /* 5. IS_BUFFERING */
    if (dirty & MAP_DIRTY_IS_BUFFERING)
    {
        int32_t b = map_atomic_load_i32(&disp->pending.is_buffering);
        if (b != disp->last_emitted.is_buffering)
        {
            disp->last_emitted.is_buffering = b;
            map_event_dispatcher_emit(disp, MAP_EVENT_IS_BUFFERING, &b, sizeof(b));
        }
    }

    /* 6. IS_COMPLETED */
    if (dirty & MAP_DIRTY_IS_COMPLETED)
    {
        int32_t c = map_atomic_load_i32(&disp->pending.is_completed);
        if (c != disp->last_emitted.is_completed)
        {
            disp->last_emitted.is_completed = c;
            map_event_dispatcher_emit(disp, MAP_EVENT_IS_COMPLETED, &c, sizeof(c));
        }
    }

    /* 7. VOLUME */
    if (dirty & MAP_DIRTY_VOLUME)
    {
        float v = map_atomic_load_float(&disp->pending.volume);
        if (fabsf(v - disp->last_emitted.volume) >= 1e-4f)
        {
            disp->last_emitted.volume = v;
            map_event_dispatcher_emit(disp, MAP_EVENT_VOLUME, &v, sizeof(v));
        }
    }

    /* 8. RATE */
    if (dirty & MAP_DIRTY_RATE)
    {
        float r = map_atomic_load_float(&disp->pending.rate);
        if (fabsf(r - disp->last_emitted.rate) >= 1e-4f)
        {
            disp->last_emitted.rate = r;
            map_event_dispatcher_emit(disp, MAP_EVENT_RATE, &r, sizeof(r));
        }
    }

    /* 9. PITCH */
    if (dirty & MAP_DIRTY_PITCH)
    {
        float p = map_atomic_load_float(&disp->pending.pitch);
        if (fabsf(p - disp->last_emitted.pitch) >= 1e-4f)
        {
            disp->last_emitted.pitch = p;
            map_event_dispatcher_emit(disp, MAP_EVENT_PITCH, &p, sizeof(p));
        }
    }

    /* 10. BITRATE */
    if (dirty & MAP_DIRTY_BITRATE)
    {
        uint32_t br = map_atomic_load_u32(&disp->pending.bitrate);
        if (br != disp->last_emitted.bitrate)
        {
            disp->last_emitted.bitrate = br;
            map_event_dispatcher_emit(disp, MAP_EVENT_BITRATE, &br, sizeof(br));
        }
    }

    /* 11. BUFFER_SIZE */
    if (dirty & MAP_DIRTY_BUFFER_SIZE)
    {
        uint32_t bs = map_atomic_load_u32(&disp->pending.buffer_size);
        if (bs != disp->last_emitted.buffer_size)
        {
            disp->last_emitted.buffer_size = bs;
            map_event_dispatcher_emit(disp, MAP_EVENT_BUFFER_SIZE, &bs, sizeof(bs));
        }
    }

    /* 12. DEVICE */
    if (dirty & MAP_DIRTY_DEVICE)
    {
        miniaudio_device_info_t dev;
        ma_mutex_lock(&disp->compound_lock);
        dev = disp->pending.device;
        ma_mutex_unlock(&disp->compound_lock);

        if (strcmp(dev.id, disp->last_emitted.device.id) != 0 ||
            strcmp(dev.name, disp->last_emitted.device.name) != 0 ||
            dev.is_default != disp->last_emitted.device.is_default ||
            dev.is_auto != disp->last_emitted.device.is_auto)
        {
            disp->last_emitted.device = dev;
            map_event_dispatcher_emit(disp, MAP_EVENT_DEVICE, &dev, sizeof(dev));
        }
    }

    /* 13. VISUALIZER */
    if (dirty & MAP_DIRTY_VISUALIZER)
    {
        miniaudio_player_visualizer_data_t vis;
        ma_mutex_lock(&disp->vis_lock);
        vis = disp->pending.visualizer;
        ma_mutex_unlock(&disp->vis_lock);

        bool changed = (fabsf(vis.rms - disp->last_emitted.visualizer.rms) >= 1e-3f) ||
                       (fabsf(vis.peak - disp->last_emitted.visualizer.peak) >= 1e-3f) ||
                       (fabsf(vis.left - disp->last_emitted.visualizer.left) >= 1e-3f) ||
                       (fabsf(vis.right - disp->last_emitted.visualizer.right) >= 1e-3f);
        if (!changed)
        {
            for (int i = 0; i < 10; i++)
            {
                if (fabsf(vis.bands[i] - disp->last_emitted.visualizer.bands[i]) >= 1e-3f)
                {
                    changed = true;
                    break;
                }
            }
        }

        if (changed)
        {
            disp->last_emitted.visualizer = vis;
            map_event_dispatcher_emit(disp, MAP_EVENT_VISUALIZER, &vis, sizeof(vis));
        }
    }

    /* 14. VISUALIZER_ENABLED */
    if (dirty & MAP_DIRTY_VISUALIZER_ENABLED)
    {
        int32_t ve = map_atomic_load_i32(&disp->pending.visualizer_enabled);
        if (ve != disp->last_emitted.visualizer_enabled)
        {
            disp->last_emitted.visualizer_enabled = ve;
            map_event_dispatcher_emit(disp, MAP_EVENT_VISUALIZER_ENABLED, &ve, sizeof(ve));
        }
    }

    /* 15. BUFFERED_RANGE */
    if (dirty & MAP_DIRTY_BUFFERED_RANGE)
    {
        miniaudio_buffered_range_t range;
        ma_mutex_lock(&disp->compound_lock);
        range = disp->pending.buffered_range;
        ma_mutex_unlock(&disp->compound_lock);

        if (range.start_ms != disp->last_emitted.buffered_range.start_ms ||
            range.end_ms != disp->last_emitted.buffered_range.end_ms ||
            range.is_buffering != disp->last_emitted.buffered_range.is_buffering ||
            range.is_eof != disp->last_emitted.buffered_range.is_eof ||
            fabsf(range.fill_percentage - disp->last_emitted.buffered_range.fill_percentage) >= 1e-3f)
        {
            disp->last_emitted.buffered_range = range;
            map_event_dispatcher_emit(disp, MAP_EVENT_BUFFERED_RANGE, &range, sizeof(range));
        }
    }

    /* 16. SILENCE_CONFIG */
    if (dirty & MAP_DIRTY_SILENCE_CONFIG)
    {
        miniaudio_player_silence_config_t sc;
        ma_mutex_lock(&disp->compound_lock);
        sc = disp->pending.silence_config;
        ma_mutex_unlock(&disp->compound_lock);

        if (sc.mode != disp->last_emitted.silence_config.mode ||
            fabsf(sc.threshold_db - disp->last_emitted.silence_config.threshold_db) >= 1e-2f ||
            sc.min_silence_duration_ms != disp->last_emitted.silence_config.min_silence_duration_ms ||
            sc.padding_ms != disp->last_emitted.silence_config.padding_ms)
        {
            disp->last_emitted.silence_config = sc;
            map_event_dispatcher_emit(disp, MAP_EVENT_SILENCE_CONFIG, &sc, sizeof(sc));
        }
    }

    /* 17. SILENCE_SAVED */
    if (dirty & MAP_DIRTY_SILENCE_SAVED)
    {
        int64_t ss = map_atomic_load_i64(&disp->pending.silence_saved_ms);
        if (ss != disp->last_emitted.silence_saved_ms)
        {
            disp->last_emitted.silence_saved_ms = ss;
            map_event_dispatcher_emit(disp, MAP_EVENT_SILENCE_SAVED, &ss, sizeof(ss));
        }
    }

    /* 18. EQUALIZER */
    if (dirty & MAP_DIRTY_EQUALIZER)
    {
        miniaudio_player_equalizer_params_t eq;
        ma_mutex_lock(&disp->compound_lock);
        eq = disp->pending.equalizer;
        ma_mutex_unlock(&disp->compound_lock);

        bool eq_changed = false;
        const float *p_new = (const float *)&eq;
        const float *p_old = (const float *)&disp->last_emitted.equalizer;
        for (int i = 0; i < 10; i++)
        {
            if (fabsf(p_new[i] - p_old[i]) >= 1e-3f)
            {
                eq_changed = true;
                break;
            }
        }
        if (eq_changed)
        {
            disp->last_emitted.equalizer = eq;
            map_event_dispatcher_emit(disp, MAP_EVENT_EQUALIZER, &eq, sizeof(eq));
        }
    }

    /* 19. PREAMP */
    if (dirty & MAP_DIRTY_PREAMP)
    {
        float pa = map_atomic_load_float(&disp->pending.preamp_db);
        if (fabsf(pa - disp->last_emitted.preamp_db) >= 1e-3f)
        {
            disp->last_emitted.preamp_db = pa;
            map_event_dispatcher_emit(disp, MAP_EVENT_PREAMP, &pa, sizeof(pa));
        }
    }

    /* 20. REPLAY_GAIN */
    if (dirty & MAP_DIRTY_REPLAY_GAIN)
    {
        miniaudio_player_replay_gain_config_t rg;
        ma_mutex_lock(&disp->compound_lock);
        rg = disp->pending.replay_gain;
        ma_mutex_unlock(&disp->compound_lock);

        if (rg.enabled != disp->last_emitted.replay_gain.enabled ||
            fabsf(rg.gain_db - disp->last_emitted.replay_gain.gain_db) >= 1e-3f ||
            fabsf(rg.peak - disp->last_emitted.replay_gain.peak) >= 1e-4f ||
            rg.prevent_clipping != disp->last_emitted.replay_gain.prevent_clipping)
        {
            disp->last_emitted.replay_gain = rg;
            map_event_dispatcher_emit(disp, MAP_EVENT_REPLAY_GAIN, &rg, sizeof(rg));
        }
    }

    /* 21. BALANCE */
    if (dirty & MAP_DIRTY_BALANCE)
    {
        float bal = map_atomic_load_float(&disp->pending.balance);
        if (fabsf(bal - disp->last_emitted.balance) >= 1e-3f)
        {
            disp->last_emitted.balance = bal;
            map_event_dispatcher_emit(disp, MAP_EVENT_BALANCE, &bal, sizeof(bal));
        }
    }

    /* 22. MONO */
    if (dirty & MAP_DIRTY_MONO)
    {
        int32_t mn = map_atomic_load_i32(&disp->pending.mono_enabled);
        if (mn != disp->last_emitted.mono_enabled)
        {
            disp->last_emitted.mono_enabled = mn;
            map_event_dispatcher_emit(disp, MAP_EVENT_MONO, &mn, sizeof(mn));
        }
    }

    /* 23. CROSSFEED */
    if (dirty & MAP_DIRTY_CROSSFEED)
    {
        int32_t cf = map_atomic_load_i32(&disp->pending.crossfeed_mode);
        if (cf != disp->last_emitted.crossfeed_mode)
        {
            disp->last_emitted.crossfeed_mode = cf;
            map_event_dispatcher_emit(disp, MAP_EVENT_CROSSFEED, &cf, sizeof(cf));
        }
    }

    /* 24. SPATIALIZER */
    if (dirty & MAP_DIRTY_SPATIALIZER)
    {
        map_event_spatializer_t sp;
        ma_mutex_lock(&disp->compound_lock);
        sp = disp->pending.spatializer;
        ma_mutex_unlock(&disp->compound_lock);

        if (sp.enabled != disp->last_emitted.spatializer.enabled ||
            fabsf(sp.width - disp->last_emitted.spatializer.width) >= 1e-3f)
        {
            disp->last_emitted.spatializer = sp;
            map_event_dispatcher_emit(disp, MAP_EVENT_SPATIALIZER, &sp, sizeof(sp));
        }
    }

    /* 25. REVERB */
    if (dirty & MAP_DIRTY_REVERB)
    {
        miniaudio_player_reverb_config_t rv;
        ma_mutex_lock(&disp->compound_lock);
        rv = disp->pending.reverb;
        ma_mutex_unlock(&disp->compound_lock);

        if (rv.enabled != disp->last_emitted.reverb.enabled ||
            fabsf(rv.room_size - disp->last_emitted.reverb.room_size) >= 1e-3f ||
            fabsf(rv.damping - disp->last_emitted.reverb.damping) >= 1e-3f ||
            fabsf(rv.width - disp->last_emitted.reverb.width) >= 1e-3f ||
            fabsf(rv.wet - disp->last_emitted.reverb.wet) >= 1e-3f ||
            fabsf(rv.dry - disp->last_emitted.reverb.dry) >= 1e-3f)
        {
            disp->last_emitted.reverb = rv;
            map_event_dispatcher_emit(disp, MAP_EVENT_REVERB, &rv, sizeof(rv));
        }
    }

    /* 26. LIMITER */
    if (dirty & MAP_DIRTY_LIMITER)
    {
        int32_t lm = map_atomic_load_i32(&disp->pending.limiter_enabled);
        if (lm != disp->last_emitted.limiter_enabled)
        {
            disp->last_emitted.limiter_enabled = lm;
            map_event_dispatcher_emit(disp, MAP_EVENT_LIMITER, &lm, sizeof(lm));
        }
    }

    /* 27. ERROR */
    if (dirty & MAP_DIRTY_ERROR)
    {
        int32_t err = map_atomic_load_i32(&disp->pending.error_code);
        disp->last_emitted.error_code = err;
        map_event_dispatcher_emit(disp, MAP_EVENT_ERROR, &err, sizeof(err));
    }

    ma_mutex_unlock(&disp->emit_lock);
}

void map_event_dispatcher_flush(map_event_dispatcher_t *disp)
{
    if (disp == NULL)
        return;
    map_event_dispatcher_process_events(disp);
}

static ma_thread_result MA_THREADCALL map_event_dispatcher_worker(void *pData)
{
    map_event_dispatcher_t *disp = (map_event_dispatcher_t *)pData;
    if (disp == NULL)
        return (ma_thread_result)0;

    map_disable_denormals();

    while (ma_atomic_load_32(&disp->is_running))
    {
        map_event_dispatcher_process_events(disp);

        if (!ma_atomic_load_32(&disp->is_running))
            break;

        ma_uint32 is_active = ma_atomic_load_32(&disp->is_active_playback);
        uint64_t dirty = ma_atomic_load_64(&disp->dirty_mask);

        if (!is_active && ((dirty & MAP_DIRTY_DISCRETE_MASK) == 0))
        {
            /* Stopped or paused with no discrete events: sleep at 0% CPU until signaled */
            ma_event_wait(&disp->wakeup_event);
        }
        else
        {
            /* Active playback or pending telemetry: sleep for throttled interval (e.g. 16-33ms) */
            ma_uint32 interval = ma_atomic_load_32(&disp->telemetry_interval_ms);
            if (interval == 0)
                interval = MAP_DEFAULT_TELEMETRY_INTERVAL_MS;
            ma_sleep(interval);
        }
    }

    return (ma_thread_result)0;
}

ma_result map_event_dispatcher_init(
    map_event_dispatcher_t *disp,
    struct miniaudio_player *player,
    miniaudio_player_event_cb callback,
    void *user_data)
{
    if (disp == NULL)
        return MA_INVALID_ARGS;

    memset(disp, 0, sizeof(*disp));
    disp->player = player;
    disp->callback = callback;
    disp->user_data = user_data;
    ma_atomic_store_32(&disp->telemetry_interval_ms, MAP_DEFAULT_TELEMETRY_INTERVAL_MS);

    /* Initialize sentinels in last_emitted to guarantee initial emissions */
    disp->last_emitted.state = (miniaudio_player_playback_state_t)-1;
    disp->last_emitted.position_ms = -1;
    disp->last_emitted.duration_ms = -1;
    disp->last_emitted.is_playing = -1;
    disp->last_emitted.is_buffering = -1;
    disp->last_emitted.is_completed = -1;
    disp->last_emitted.volume = -1.0f;
    disp->last_emitted.rate = -1.0f;
    disp->last_emitted.pitch = -1.0f;
    disp->last_emitted.bitrate = (uint32_t)-1;
    disp->last_emitted.buffer_size = (uint32_t)-1;
    disp->last_emitted.preamp_db = -999.0f;
    disp->last_emitted.balance = -999.0f;
    disp->last_emitted.mono_enabled = -1;
    disp->last_emitted.crossfeed_mode = -1;
    disp->last_emitted.spatializer.enabled = -1;
    disp->last_emitted.spatializer.width = -1.0f;
    disp->last_emitted.limiter_enabled = -1;
    disp->last_emitted.visualizer_enabled = -1;
    disp->last_emitted.reverb.enabled = -1;
    disp->last_emitted.silence_config.mode = -1;
    disp->last_emitted.replay_gain.enabled = -1;
    disp->last_emitted.error_code = -1;

    map_seqlock_init(&disp->vis_seqlock);
    map_seqlock_init(&disp->buffer_seqlock);

    ma_result res = ma_event_init(&disp->wakeup_event);
    if (res != MA_SUCCESS)
        return res;

    res = ma_mutex_init(&disp->emit_lock);
    if (res != MA_SUCCESS)
    {
        ma_event_uninit(&disp->wakeup_event);
        return res;
    }

    res = ma_mutex_init(&disp->compound_lock);
    if (res != MA_SUCCESS)
    {
        ma_mutex_uninit(&disp->emit_lock);
        ma_event_uninit(&disp->wakeup_event);
        return res;
    }

    res = ma_mutex_init(&disp->vis_lock);
    if (res != MA_SUCCESS)
    {
        ma_mutex_uninit(&disp->compound_lock);
        ma_mutex_uninit(&disp->emit_lock);
        ma_event_uninit(&disp->wakeup_event);
        return res;
    }

    ma_atomic_store_32(&disp->is_running, 1);
    ma_atomic_store_32(&disp->is_active_playback, 0);

#if !defined(__EMSCRIPTEN__)
    res = map_thread_create(&disp->thread, map_event_dispatcher_worker, disp);
    if (res != MA_SUCCESS)
    {
        ma_atomic_store_32(&disp->is_running, 0);
        ma_mutex_uninit(&disp->vis_lock);
        ma_mutex_uninit(&disp->compound_lock);
        ma_mutex_uninit(&disp->emit_lock);
        ma_event_uninit(&disp->wakeup_event);
        return res;
    }
#endif

    return MA_SUCCESS;
}

void map_event_dispatcher_uninit(map_event_dispatcher_t *disp)
{
    if (disp == NULL)
        return;

#if !defined(__EMSCRIPTEN__)
    if (ma_atomic_load_32(&disp->is_running))
    {
        ma_atomic_store_32(&disp->is_running, 0);
        ma_event_signal(&disp->wakeup_event);
        map_thread_wait(&disp->thread);
    }
#endif

    ma_event_uninit(&disp->wakeup_event);
    ma_mutex_uninit(&disp->emit_lock);
    ma_mutex_uninit(&disp->compound_lock);
    ma_mutex_uninit(&disp->vis_lock);
}

void map_event_dispatcher_set_callback(
    map_event_dispatcher_t *disp,
    miniaudio_player_event_cb callback,
    void *user_data)
{
    if (disp == NULL)
        return;

    ma_mutex_lock(&disp->emit_lock);
    map_atomic_store_ptr((void * volatile *)&disp->callback, (void *)callback);
    map_atomic_store_ptr((void * volatile *)&disp->user_data, (void *)user_data);
    ma_mutex_unlock(&disp->emit_lock);

    if (callback != NULL)
    {
        map_event_dispatcher_flush(disp);
    }
}

void map_event_dispatcher_set_interval(
    map_event_dispatcher_t *disp,
    uint32_t interval_ms)
{
    if (disp == NULL)
        return;
    if (interval_ms < 5)
        interval_ms = 5;
    if (interval_ms > 500)
        interval_ms = 500;
    ma_atomic_store_32(&disp->telemetry_interval_ms, interval_ms);
}

/* ========================================================================= */
/* Lockless Producer Methods                                                 */
/* ========================================================================= */

void map_event_dispatcher_post_state(map_event_dispatcher_t *disp, miniaudio_player_playback_state_t state)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32((int32_t *)&disp->pending.state, (int32_t)state);
    if (state == MAP_PLAYBACK_STATE_PLAYING)
    {
        ma_atomic_store_32(&disp->is_active_playback, 1);
    }
    else
    {
        ma_atomic_store_32(&disp->is_active_playback, 0);
    }
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_STATE);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_position(map_event_dispatcher_t *disp, int64_t position_ms)
{
    if (disp == NULL)
        return;
    map_atomic_store_i64(&disp->pending.position_ms, position_ms);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_POSITION);
}

void map_event_dispatcher_post_duration(map_event_dispatcher_t *disp, int64_t duration_ms)
{
    if (disp == NULL)
        return;
    map_atomic_store_i64(&disp->pending.duration_ms, duration_ms);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_DURATION);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_playing(map_event_dispatcher_t *disp, int32_t is_playing)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.is_playing, is_playing);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_IS_PLAYING);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_buffering(map_event_dispatcher_t *disp, int32_t is_buffering)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.is_buffering, is_buffering);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_IS_BUFFERING);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_completed(map_event_dispatcher_t *disp, int32_t is_completed)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.is_completed, is_completed);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_IS_COMPLETED);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_visualizer(map_event_dispatcher_t *disp, const miniaudio_player_visualizer_data_t *vis)
{
    if (disp == NULL || vis == NULL)
        return;
    ma_mutex_lock(&disp->vis_lock);
    disp->pending.visualizer = *vis;
    ma_mutex_unlock(&disp->vis_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_VISUALIZER);
}

void map_event_dispatcher_post_buffered_range(map_event_dispatcher_t *disp, const miniaudio_buffered_range_t *range)
{
    if (disp == NULL || range == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.buffered_range = *range;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_BUFFERED_RANGE);
}

void map_event_dispatcher_post_silence_saved(map_event_dispatcher_t *disp, int64_t saved_ms)
{
    if (disp == NULL)
        return;
    map_atomic_store_i64(&disp->pending.silence_saved_ms, saved_ms);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_SILENCE_SAVED);
}

void map_event_dispatcher_post_volume(map_event_dispatcher_t *disp, float volume)
{
    if (disp == NULL)
        return;
    map_atomic_store_float(&disp->pending.volume, volume);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_VOLUME);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_rate(map_event_dispatcher_t *disp, float rate)
{
    if (disp == NULL)
        return;
    map_atomic_store_float(&disp->pending.rate, rate);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_RATE);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_pitch(map_event_dispatcher_t *disp, float pitch)
{
    if (disp == NULL)
        return;
    map_atomic_store_float(&disp->pending.pitch, pitch);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_PITCH);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_bitrate(map_event_dispatcher_t *disp, uint32_t bitrate)
{
    if (disp == NULL)
        return;
    map_atomic_store_u32(&disp->pending.bitrate, bitrate);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_BITRATE);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_buffer_size(map_event_dispatcher_t *disp, uint32_t buffer_size)
{
    if (disp == NULL)
        return;
    map_atomic_store_u32(&disp->pending.buffer_size, buffer_size);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_BUFFER_SIZE);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_device(map_event_dispatcher_t *disp, const miniaudio_device_info_t *device)
{
    if (disp == NULL || device == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.device = *device;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_DEVICE);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_equalizer(map_event_dispatcher_t *disp, const miniaudio_player_equalizer_params_t *eq)
{
    if (disp == NULL || eq == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.equalizer = *eq;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_EQUALIZER);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_silence_config(map_event_dispatcher_t *disp, const miniaudio_player_silence_config_t *silence)
{
    if (disp == NULL || silence == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.silence_config = *silence;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_SILENCE_CONFIG);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_preamp(map_event_dispatcher_t *disp, float preamp_db)
{
    if (disp == NULL)
        return;
    map_atomic_store_float(&disp->pending.preamp_db, preamp_db);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_PREAMP);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_replay_gain(map_event_dispatcher_t *disp, const miniaudio_player_replay_gain_config_t *rg)
{
    if (disp == NULL || rg == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.replay_gain = *rg;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_REPLAY_GAIN);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_balance(map_event_dispatcher_t *disp, float balance)
{
    if (disp == NULL)
        return;
    map_atomic_store_float(&disp->pending.balance, balance);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_BALANCE);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_mono(map_event_dispatcher_t *disp, int32_t mono_enabled)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.mono_enabled, mono_enabled);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_MONO);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_crossfeed(map_event_dispatcher_t *disp, int32_t crossfeed_mode)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.crossfeed_mode, crossfeed_mode);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_CROSSFEED);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_spatializer(map_event_dispatcher_t *disp, int32_t enabled, float width)
{
    if (disp == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.spatializer.enabled = enabled;
    disp->pending.spatializer.width = width;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_SPATIALIZER);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_reverb(map_event_dispatcher_t *disp, const miniaudio_player_reverb_config_t *reverb)
{
    if (disp == NULL || reverb == NULL)
        return;
    ma_mutex_lock(&disp->compound_lock);
    disp->pending.reverb = *reverb;
    ma_mutex_unlock(&disp->compound_lock);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_REVERB);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_limiter(map_event_dispatcher_t *disp, int32_t limiter_enabled)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.limiter_enabled, limiter_enabled);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_LIMITER);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_visualizer_enabled(map_event_dispatcher_t *disp, int32_t visualizer_enabled)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.visualizer_enabled, visualizer_enabled);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_VISUALIZER_ENABLED);
    ma_event_signal(&disp->wakeup_event);
}

void map_event_dispatcher_post_error(map_event_dispatcher_t *disp, int32_t error_code)
{
    if (disp == NULL)
        return;
    map_atomic_store_i32(&disp->pending.error_code, error_code);
    ma_atomic_fetch_or_64(&disp->dirty_mask, MAP_DIRTY_ERROR);
    ma_event_signal(&disp->wakeup_event);
}
