/**
 * @file miniaudio_player.h
 * @brief Thread-safe, reentrant native audio engine for Flutter miniaudio_player plugin.
 *
 * Provides local file decoding (MP3, WAV, FLAC, Vorbis), 10-band parametric EQ,
 * rate and pitch shifting, and sample-accurate playback status queries for Dart FFI.
 */

#ifndef MINIAUDIO_PLAYER_H
#define MINIAUDIO_PLAYER_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#if defined(MINIAUDIO_PLAYER_EXPORTS) || defined(MINIAUDIO_PLAYER_BUILD_SHARED)
#define MAP_API __declspec(dllexport)
#else
#define MAP_API __declspec(dllimport)
#endif
#else
#if defined(__GNUC__) && __GNUC__ >= 4
#define MAP_API __attribute__((visibility("default")))
#else
#define MAP_API
#endif
#endif

#ifdef __cplusplus
extern "C"
{
#endif

    /* ========================================================================= */
    /* Error and Status Codes                                                    */
    /* ========================================================================= */

    typedef enum
    {
        MAP_SUCCESS = 0,
        MAP_ERROR_GENERIC = -1,
        MAP_ERROR_INVALID_ARGS = -2,
        MAP_ERROR_OUT_OF_MEMORY = -3,
        MAP_ERROR_ENGINE_INIT = -4,
        MAP_ERROR_FILE_NOT_FOUND = -5,
        MAP_ERROR_DECODE_FAILED = -6,
        MAP_ERROR_INVALID_STATE = -7,
        MAP_ERROR_SEEK_FAILED = -8,
        MAP_ERROR_NODE_FAILED = -9,
        MAP_ERROR_UNSUPPORTED = -10
    } miniaudio_player_result_t;

    typedef enum
    {
        MAP_PLAYBACK_STATE_STOPPED = 0,
        MAP_PLAYBACK_STATE_PLAYING = 1,
        MAP_PLAYBACK_STATE_PAUSED = 2,
        MAP_PLAYBACK_STATE_COMPLETED = 3,
        MAP_PLAYBACK_STATE_BUFFERING = 4,
        MAP_PLAYBACK_STATE_ERROR = 5
    } miniaudio_player_playback_state_t;

    /* ========================================================================= */
    /* Equalizer Parameters (10 Bands in dB: -24.0 to +24.0)                     */
    /* ========================================================================= */

    typedef struct
    {
        float hz31;  /**< Low-shelf filter at 31 Hz   (-24.0 to +24.0 dB) */
        float hz63;  /**< Peaking filter at 63 Hz     (-24.0 to +24.0 dB) */
        float hz125; /**< Peaking filter at 125 Hz    (-24.0 to +24.0 dB) */
        float hz250; /**< Peaking filter at 250 Hz    (-24.0 to +24.0 dB) */
        float hz500; /**< Peaking filter at 500 Hz    (-24.0 to +24.0 dB) */
        float hz1k;  /**< Peaking filter at 1.0 kHz   (-24.0 to +24.0 dB) */
        float hz2k;  /**< Peaking filter at 2.0 kHz   (-24.0 to +24.0 dB) */
        float hz4k;  /**< Peaking filter at 4.0 kHz   (-24.0 to +24.0 dB) */
        float hz8k;  /**< Peaking filter at 8.0 kHz   (-24.0 to +24.0 dB) */
        float hz16k; /**< High-shelf filter at 16.0 kHz (-24.0 to +24.0 dB) */
    } miniaudio_player_equalizer_params_t;

    /* ========================================================================= */
    /* Silence Detection & Skipping Parameters                                   */
    /* ========================================================================= */

    typedef enum
    {
        MAP_SILENCE_MODE_DISABLED = 0,
        MAP_SILENCE_MODE_TRIM_EDGES = 1,
        MAP_SILENCE_MODE_CONTINUOUS = 2,
        MAP_SILENCE_MODE_ALL = 3
    } miniaudio_player_silence_mode_t;

    typedef struct
    {
        int32_t mode;                    /**< miniaudio_player_silence_mode_t */
        float threshold_db;              /**< Silence threshold in dBFS (default: -45.0f, range: -90.0 to -10.0) */
        uint32_t min_silence_duration_ms;/**< Minimum silence duration before skipping (default: 300ms) */
        uint32_t padding_ms;             /**< Safety margin before and after voice (default: 50ms) */
    } miniaudio_player_silence_config_t;

    /* ========================================================================= */
    /* Player Status Snapshot (Single-Call FFI Marshalling)                      */
    /* ========================================================================= */

    typedef struct
    {
        char id[516];       /**< Unique device ID encoded as hex string, or empty for default */
        char name[256];     /**< Human-readable device name */
        int32_t is_default; /**< 1 if system default playback device, 0 otherwise */
        int32_t is_auto;    /**< 1 if auto (system-managed) routing, 0 for pinned hardware device */
    } miniaudio_device_info_t;

    typedef struct
    {
        float bands[10]; /**< 10 normalized frequency bands (0.0 to 1.0) matching EQ bands */
        float rms;       /**< Global RMS energy (0.0 to 1.0) */
        float peak;      /**< Peak amplitude (0.0 to 1.0) */
        float left;      /**< Left channel level (0.0 to 1.0) */
        float right;     /**< Right channel level (0.0 to 1.0) */
    } miniaudio_player_visualizer_data_t;

    /* ========================================================================= */
    /* DSP Effects & Normalization Structures                                    */
    /* ========================================================================= */

    typedef struct
    {
        float gain_db;            /**< Track gain in dB */
        float peak;               /**< Track peak (1.0 = 0 dBFS), 0.0 if unknown */
        float preamp_db;          /**< Additional preamp gain in dB */
        int32_t prevent_clipping; /**< 1 to cap gain if boosted peak > 1.0 */
        int32_t enabled;          /**< 1 if ReplayGain is active, 0 for bypass */
    } miniaudio_player_replay_gain_config_t;

    typedef enum
    {
        MAP_CROSSFEED_OFF          = 0,
        MAP_CROSSFEED_MOFFAT_BAUER = 1,
        MAP_CROSSFEED_CHU_MOY      = 2
    } miniaudio_player_crossfeed_mode_t;

    typedef struct
    {
        int32_t enabled;   /**< 1 if reverb is enabled, 0 for bypass */
        float room_size;   /**< Room size (0.0 to 1.0, controls decay time) */
        float damping;     /**< High frequency damping (0.0 to 1.0) */
        float width;       /**< Stereo width of reflections (0.0 to 1.0) */
        float wet;         /**< Wet signal level (0.0 to 2.0) */
        float dry;         /**< Dry signal level (0.0 to 2.0) */
    } miniaudio_player_reverb_config_t;

    typedef struct
    {
        int64_t position_ms;                           /**< Current position in milliseconds */
        int64_t duration_ms;                           /**< Total duration in milliseconds */
        int32_t is_playing;                            /**< 1 if actively playing, 0 if paused/stopped */
        int32_t is_buffering;                          /**< 1 if buffering, 0 otherwise */
        int32_t is_completed;                          /**< 1 if track completed, 0 otherwise */
        int32_t state;                                 /**< miniaudio_player_playback_state_t */
        float volume;                                  /**< Current volume (0.0 to 1.0+) */
        float rate;                                    /**< Playback speed multiplier (0.1 to 4.0+) */
        float pitch;                                   /**< Pitch multiplier (0.1 to 4.0+) */
        uint32_t bitrate;                              /**< Audio bitrate in bits per second (bps) */
        miniaudio_player_equalizer_params_t equalizer; /**< Current 10-band equalizer settings */
        miniaudio_device_info_t device;                /**< Currently active audio output device */
        miniaudio_player_silence_config_t silence;     /**< Currently active silence skipping settings */
        int64_t silence_saved_ms;                      /**< Cumulative duration of skipped silence in ms */
        int32_t visualizer_enabled;                     /**< 1 if real-time visualizer enabled, 0 otherwise */
        miniaudio_player_visualizer_data_t visualizer;  /**< Real-time 10-band visualizer data */
        float preamp_db;                               /**< Standalone preamp in dB */
        miniaudio_player_replay_gain_config_t replay_gain; /**< ReplayGain active configuration */
        float balance;                                 /**< Stereo balance / pan (-1.0 to +1.0) */
        int32_t mono_enabled;                          /**< 1 if mono downmix enabled, 0 otherwise */
        int32_t crossfeed_mode;                        /**< miniaudio_player_crossfeed_mode_t */
        int32_t spatializer_enabled;                   /**< 1 if stereo widener enabled, 0 otherwise */
        float spatializer_width;                       /**< Stereo widener width factor (1.0 to 2.0) */
        miniaudio_player_reverb_config_t reverb;       /**< Reverb active configuration */
        int32_t limiter_enabled;                       /**< 1 if True-Peak limiter enabled, 0 otherwise */
    } miniaudio_player_status_t;

    /* ========================================================================= */
    /* Player Configuration & Callbacks                                          */
    /* ========================================================================= */

    typedef void (*miniaudio_player_completed_cb)(void *user_data);

    typedef struct
    {
        uint32_t sample_rate;                       /**< Sample rate (0 = device native default) */
        uint32_t channels;                          /**< Channels (0 = stereo default 2) */
        uint32_t period_size_in_frames;             /**< Buffer period size (0 = default) */
        const char *playback_device_id;             /**< Optional target device ID (NULL or empty for auto) */
        miniaudio_player_completed_cb on_completed; /**< Optional completion callback */
        void *user_data;                            /**< Context passed to completion callback */
    } miniaudio_player_config_t;

    /* Opaque player handle */
    typedef struct miniaudio_player miniaudio_player_t;

    /* ========================================================================= */
    /* Lifecycle Management                                                      */
    /* ========================================================================= */

    /**
     * @brief Creates and initializes an isolated native audio player instance.
     * @param config Optional player configuration (NULL for defaults).
     * @param[out] out_result Result status code.
     * @return Pointer to player handle, or NULL on error.
     */
    MAP_API miniaudio_player_t *miniaudio_player_create(
        const miniaudio_player_config_t *config,
        int32_t *out_result);

    /**
     * @brief Uninitializes all nodes, frees audio resources, and destroys the player handle.
     * @param player Player instance handle.
     * @return MAP_SUCCESS on clean termination.
     */
    MAP_API int32_t miniaudio_player_destroy(miniaudio_player_t *player);

    /* ========================================================================= */
    /* Media Loading                                                             */
    /* ========================================================================= */

    /**
     * @brief Opens and prepares a local audio file for playback.
     * @param player Player instance handle.
     * @param file_path UTF-8 null-terminated file path.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_open_file(
        miniaudio_player_t *player,
        const char *file_path);

    /**
     * @brief Opens and prepares an audio source directly from an in-memory byte buffer.
     * @param player Player instance handle.
     * @param data Pointer to encoded audio bytes in memory.
     * @param size Size of the byte buffer in bytes.
     * @param take_ownership 1 if native engine should free(data) on close, 0 if caller retains ownership.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_open_memory(
        miniaudio_player_t *player,
        const void *data,
        size_t size,
        int32_t take_ownership);

    /**
     * @brief Opens and prepares a streaming audio source fed chunk-by-chunk.
     * @param player Player instance handle.
     * @param initial_data Pointer to initial pre-buffered encoded audio chunk.
     * @param initial_data_size Size of the initial chunk in bytes.
     * @param total_size Total file size in bytes (-1 if unknown / live stream).
     * @param is_live 1 for continuous live stream, 0 for finite remote file.
     * @param buffer_capacity_bytes Capacity of the internal ring buffer in bytes (e.g. 2MB - 4MB).
     * @param encoding_format Encoding format hint (0 for auto-sniffing).
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_open_stream(
        miniaudio_player_t *player,
        const uint8_t *initial_data,
        size_t initial_data_size,
        int64_t total_size,
        int32_t is_live,
        uint32_t buffer_capacity_bytes,
        int32_t encoding_format);

    /**
     * @brief Feeds encoded audio chunks into an active stream data source.
     * @param player Player instance handle.
     * @param data Pointer to encoded audio chunk.
     * @param size Number of bytes in chunk.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_stream_feed(
        miniaudio_player_t *player,
        const uint8_t *data,
        size_t size);

    /**
     * @brief Flushes the stream buffer (used on remote seek).
     * @param player Player instance handle.
     * @param new_stream_offset New byte offset in the remote file.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_stream_flush(
        miniaudio_player_t *player,
        int64_t new_stream_offset);

    /**
     * @brief Signals that the stream has reached EOF (no more bytes will be fed).
     * @param player Player instance handle.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_stream_end(
        miniaudio_player_t *player);

    typedef struct miniaudio_stream_status
    {
        size_t buffer_capacity;
        size_t buffer_fill;
        float fill_percentage;
        int32_t is_buffering;
        int32_t is_eof;
    } miniaudio_stream_status_t;

    /**
     * @brief Queries status of the streaming buffer.
     * @param player Player instance handle.
     * @param out_status Output pointer for stream status.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_stream_get_status(
        miniaudio_player_t *player,
        miniaudio_stream_status_t *out_status);

    /* ========================================================================= */
    /* Playback Controls                                                         */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_play(miniaudio_player_t *player);
    MAP_API int32_t miniaudio_player_pause(miniaudio_player_t *player);
    MAP_API int32_t miniaudio_player_stop(miniaudio_player_t *player);
    MAP_API int32_t miniaudio_player_seek(miniaudio_player_t *player, int64_t position_ms);

    /* ========================================================================= */
    /* Volume, Rate & Pitch Adjustments                                          */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_set_volume(miniaudio_player_t *player, float volume);
    MAP_API int32_t miniaudio_player_set_rate(miniaudio_player_t *player, float rate);
    MAP_API int32_t miniaudio_player_set_pitch(miniaudio_player_t *player, float pitch);

    /* ========================================================================= */
    /* Buffer Size Configuration                                                 */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_set_buffer_size(miniaudio_player_t *player, uint32_t buffer_size_in_frames);
    MAP_API uint32_t miniaudio_player_get_buffer_size(const miniaudio_player_t *player);

    /* ========================================================================= */
    /* Audio Device Management                                                   */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_get_devices(
        miniaudio_device_info_t **out_devices,
        uint32_t *out_count);

    MAP_API void miniaudio_player_free_devices(
        miniaudio_device_info_t *devices,
        uint32_t count);

    MAP_API int32_t miniaudio_player_set_device(
        miniaudio_player_t *player,
        const char *device_id);

    MAP_API int32_t miniaudio_player_get_current_device(
        const miniaudio_player_t *player,
        miniaudio_device_info_t *out_device);

    typedef void (*miniaudio_player_device_notification_cb)(void *user_data);

    MAP_API void miniaudio_player_set_device_notification_callback(
        miniaudio_player_device_notification_cb on_device_notification,
        void *user_data);

#if defined(__ANDROID__)
    /**
     * @brief Optionally sets the JavaVM instance for Android JNI operations.
     * If not called, the engine automatically resolves the running JavaVM via JNI_GetCreatedJavaVMs.
     */
    MAP_API void miniaudio_player_set_jvm(void *jvm);
#endif

    /* ========================================================================= */
    /* Equalizer Controls                                                        */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_set_equalizer(
        miniaudio_player_t *player,
        const miniaudio_player_equalizer_params_t *equalizer);

    MAP_API int32_t miniaudio_player_set_equalizer_band(
        miniaudio_player_t *player,
        uint32_t band_index,
        float gain_db);

    /* ========================================================================= */
    /* Advanced DSP Controls (ReplayGain, Preamp, Spatial, Balance, Limiter)     */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_set_replay_gain(
        miniaudio_player_t *player,
        float gain_db,
        float peak,
        float preamp_db,
        int32_t prevent_clipping);

    MAP_API int32_t miniaudio_player_clear_replay_gain(
        miniaudio_player_t *player);

    MAP_API int32_t miniaudio_player_set_preamp(
        miniaudio_player_t *player,
        float preamp_db);

    MAP_API int32_t miniaudio_player_set_balance(
        miniaudio_player_t *player,
        float pan);

    MAP_API int32_t miniaudio_player_set_mono(
        miniaudio_player_t *player,
        int32_t enabled);

    MAP_API int32_t miniaudio_player_set_crossfeed(
        miniaudio_player_t *player,
        int32_t mode);

    MAP_API int32_t miniaudio_player_set_spatializer(
        miniaudio_player_t *player,
        int32_t enabled,
        float width);

    MAP_API int32_t miniaudio_player_set_reverb(
        miniaudio_player_t *player,
        int32_t enabled,
        float room_size,
        float damping,
        float width,
        float wet,
        float dry);

    MAP_API int32_t miniaudio_player_set_limiter(
        miniaudio_player_t *player,
        int32_t enabled);

    /* ========================================================================= */
    /* Silence Detection & Skipping Controls                                     */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_set_silence_config(
        miniaudio_player_t *player,
        const miniaudio_player_silence_config_t *config);

    MAP_API int32_t miniaudio_player_get_silence_config(
        const miniaudio_player_t *player,
        miniaudio_player_silence_config_t *out_config);

    MAP_API int64_t miniaudio_player_get_silence_saved_ms(const miniaudio_player_t *player);

    /* ========================================================================= */
    /* Real-Time Audio Visualizer Controls                                       */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_set_visualizer_enabled(
        miniaudio_player_t *player,
        int32_t enabled);

    MAP_API int32_t miniaudio_player_is_visualizer_enabled(
        const miniaudio_player_t *player);

    MAP_API int32_t miniaudio_player_get_visualizer_data(
        const miniaudio_player_t *player,
        miniaudio_player_visualizer_data_t *out_data);

    /* ========================================================================= */
    /* Status & Query Inspection                                                 */
    /* ========================================================================= */

    MAP_API int32_t miniaudio_player_get_status(
        const miniaudio_player_t *player,
        miniaudio_player_status_t *out_status);

    MAP_API int64_t miniaudio_player_get_position_ms(const miniaudio_player_t *player);
    MAP_API int64_t miniaudio_player_get_duration_ms(const miniaudio_player_t *player);
    MAP_API int32_t miniaudio_player_is_playing(const miniaudio_player_t *player);
    MAP_API int32_t miniaudio_player_is_completed(const miniaudio_player_t *player);
    MAP_API float miniaudio_player_get_volume(const miniaudio_player_t *player);
    MAP_API float miniaudio_player_get_rate(const miniaudio_player_t *player);
    MAP_API float miniaudio_player_get_pitch(const miniaudio_player_t *player);
    MAP_API uint32_t miniaudio_player_get_bitrate(const miniaudio_player_t *player);
    MAP_API int32_t miniaudio_player_get_equalizer(
        const miniaudio_player_t *player,
        miniaudio_player_equalizer_params_t *out_equalizer);

    /* ========================================================================= */
    /* Unified Audio Analysis (ReplayGain, Loudness & Waveform)                  */
    /* ========================================================================= */

    typedef enum
    {
        MAP_ANALYSIS_FLAG_REPLAY_GAIN = 1 << 0,
        MAP_ANALYSIS_FLAG_WAVEFORM    = 1 << 1
    } miniaudio_analysis_flags_t;

    typedef struct
    {
        uint32_t flags;            /**< Bitmask of miniaudio_analysis_flags_t */
        float target_lufs;         /**< Target LUFS for ReplayGain (default: -18.0) */
        uint32_t waveform_points;  /**< Number of points for waveform (default: 100) */
    } miniaudio_audio_analysis_config_t;

    typedef struct
    {
        float gain_db;   /**< Recommended ReplayGain in dB relative to target LUFS */
        float peak;      /**< Peak sample value (1.0 = 0 dBFS) */
        float lufs;      /**< Integrated perceived loudness in LUFS */
    } miniaudio_replay_gain_data_t;

    typedef struct
    {
        uint32_t point_count; /**< Number of points in the array */
        float *points;        /**< Dynamically allocated array of normalized points (0.0 to 1.0) */
    } miniaudio_waveform_data_t;

    typedef struct
    {
        int32_t status;            /**< MAP_SUCCESS or error code */
        int64_t duration_ms;       /**< Track duration in milliseconds */
        uint32_t sample_rate;      /**< Native sample rate in Hz */
        uint32_t channels;         /**< Channel count */
        uint32_t bitrate;          /**< Average nominal bitrate in bps */
        float peak;                /**< True sample peak (1.0 = 0 dBFS) */

        int32_t has_replay_gain;   /**< 1 if ReplayGain was calculated, 0 otherwise */
        miniaudio_replay_gain_data_t replay_gain;

        int32_t has_waveform;      /**< 1 if Waveform was calculated, 0 otherwise */
        miniaudio_waveform_data_t waveform;
    } miniaudio_audio_analysis_result_t;

    typedef void (*miniaudio_audio_analysis_completed_cb)(
        const miniaudio_audio_analysis_result_t *result,
        void *user_data);

    /**
     * @brief Synchronously analyzes an audio file for ReplayGain and/or Waveform in a single decoding pass.
     * @param file_path Local audio file path.
     * @param config Analysis configuration flags and parameters.
     * @param[out] out_result Result structure pointer.
     * @return MAP_SUCCESS or error code.
     */
    MAP_API int32_t miniaudio_player_analyze_audio(
        const char *file_path,
        const miniaudio_audio_analysis_config_t *config,
        miniaudio_audio_analysis_result_t *out_result);

    /**
     * @brief Asynchronously analyzes an audio file on a dedicated non-blocking C OS worker thread.
     * Invokes callback when analysis completes. Thread-safe with zero Dart Isolate overhead.
     * @param file_path Local audio file path.
     * @param config Analysis configuration flags and parameters.
     * @param on_completed Completion callback.
     * @param user_data User pointer passed to callback.
     * @return MAP_SUCCESS if task was queued, error code otherwise.
     */
    MAP_API int32_t miniaudio_player_analyze_audio_async(
        const char *file_path,
        const miniaudio_audio_analysis_config_t *config,
        miniaudio_audio_analysis_completed_cb on_completed,
        void *user_data);

    /**
     * @brief Frees dynamically allocated memory in an audio analysis result.
     * @param result Result structure pointer.
     * @param free_struct If non-zero, also frees the result pointer itself (used for async heap result).
     */
    MAP_API void miniaudio_player_free_audio_analysis(
        miniaudio_audio_analysis_result_t *result,
        int32_t free_struct);

    /* ========================================================================= */
    /* Logging Configuration                                                     */
    /* ========================================================================= */

    typedef enum
    {
        MAP_LOG_LEVEL_NONE = 0,
        MAP_LOG_LEVEL_ERROR = 1,
        MAP_LOG_LEVEL_WARNING = 2,
        MAP_LOG_LEVEL_INFO = 3,
        MAP_LOG_LEVEL_DEBUG = 4,
        MAP_LOG_LEVEL_VERBOSE = 5
    } miniaudio_player_log_level_t;

    MAP_API void miniaudio_player_set_log_level(int32_t level);
    MAP_API int32_t miniaudio_player_get_log_level(void);

#ifdef __cplusplus
}
#endif

#endif /* MINIAUDIO_PLAYER_H */
