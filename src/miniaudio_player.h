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
        float hz60;  /**< Low-shelf filter at 60 Hz  (-24.0 to +24.0 dB) */
        float hz170; /**< Peaking filter at 170 Hz   (-24.0 to +24.0 dB) */
        float hz310; /**< Peaking filter at 310 Hz   (-24.0 to +24.0 dB) */
        float hz600; /**< Peaking filter at 600 Hz   (-24.0 to +24.0 dB) */
        float hz1k;  /**< Peaking filter at 1.0 kHz  (-24.0 to +24.0 dB) */
        float hz3k;  /**< Peaking filter at 3.0 kHz  (-24.0 to +24.0 dB) */
        float hz6k;  /**< Peaking filter at 6.0 kHz  (-24.0 to +24.0 dB) */
        float hz12k; /**< Peaking filter at 12.0 kHz (-24.0 to +24.0 dB) */
        float hz14k; /**< Peaking filter at 14.0 kHz (-24.0 to +24.0 dB) */
        float hz16k; /**< High-shelf filter at 16.0 kHz (-24.0 to +24.0 dB) */
    } miniaudio_player_equalizer_params_t;

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
