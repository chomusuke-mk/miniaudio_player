#ifndef MINIAUDIO_DEVICE_BRIDGE_H
#define MINIAUDIO_DEVICE_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C"
{
#endif

    typedef struct map_device_context map_device_context_t;

    typedef struct
    {
        char id[516];           /**< Selector ID encoded as hex string, or "auto" for default */
        char effective_id[516]; /**< Physical OS hardware endpoint ID currently active */
        char name[256];         /**< Human-readable device name */
        int32_t is_default;     /**< 1 if system default playback device, 0 otherwise */
        int32_t is_auto;        /**< 1 if auto (system-managed) routing, 0 for pinned hardware device */
    } map_device_info_t;

    /* Callback exported by Rust to render interleaved f32 PCM audio frames */
    extern void rust_render_pcm_frames(void *user_data, float *output_frames, uint32_t frame_count);

    /* Callback exported by Rust to receive captured f32 PCM audio frames from microphone/line-in */
    extern void rust_capture_pcm_frames(void *user_data, const float *input_frames, uint32_t frame_count);

    /* Callback exported by Rust to receive hardware lifecycle notifications from the OS */
    extern void rust_on_device_notification(void *user_data, int32_t notification_type);

    /* Device control and lifecycle API implemented in C on top of miniaudio.h */

    /**
     * Initializes and opens an OS audio playback device using miniaudio.
     *
     * @param sample_rate Desired sample rate (Hz), or 0 for default 44100 Hz.
     * @param channels Desired channel count, or 0 for stereo (2).
     * @param period_size_in_frames Buffer period size in frames.
     * @param playback_device_id Target hardware endpoint hex ID, name, or "auto" for system default.
     * @param rust_user_data Opaque pointer passed back to Rust callbacks.
     * @param out_result Output error code (0 on success, negative on error).
     * @return Allocated device context, or NULL on failure.
     */
    map_device_context_t *map_device_create(
        uint32_t sample_rate,
        uint32_t channels,
        uint32_t period_size_in_frames,
        const char *playback_device_id,
        void *rust_user_data,
        int32_t *out_result);

    /**
     * Initializes and opens an OS audio capture (recording/microphone) device using miniaudio.
     *
     * @param sample_rate Desired sample rate (Hz), or 0 for default 44100 Hz.
     * @param channels Desired channel count, or 0 for mono (1).
     * @param period_size_in_frames Buffer period size in frames.
     * @param capture_device_id Target capture endpoint hex ID, name, or "auto" for system default.
     * @param rust_user_data Opaque pointer passed back to Rust callbacks.
     * @param out_result Output error code (0 on success, negative on error).
     * @return Allocated capture device context, or NULL on failure.
     */
    map_device_context_t *map_capture_device_create(
        uint32_t sample_rate,
        uint32_t channels,
        uint32_t period_size_in_frames,
        const char *capture_device_id,
        void *rust_user_data,
        int32_t *out_result);

    /**
     * Starts the audio device backend rendering/capture loop.
     */
    int32_t map_device_start(map_device_context_t *ctx);

    /**
     * Stops the audio device backend rendering/capture loop.
     */
    int32_t map_device_stop(map_device_context_t *ctx);

    /**
     * Uninitializes miniaudio hardware resources and frees the context memory.
     */
    int32_t map_device_destroy(map_device_context_t *ctx);

    /**
     * Returns the active hardware sample rate of the device context.
     */
    uint32_t map_device_get_sample_rate(const map_device_context_t *ctx);

    /**
     * Returns the active channel count of the device context.
     */
    uint32_t map_device_get_channels(const map_device_context_t *ctx);

    /**
     * Reconfigures the device context to route to a new target hardware device ID.
     */
    int32_t map_device_set_device(map_device_context_t *ctx, const char *device_id);

    /**
     * Copies current hardware device information into out_device.
     */
    int32_t map_device_get_current_device_info(const map_device_context_t *ctx, map_device_info_t *out_device);

    /**
     * Enumerates all physical audio playback devices available on the host system.
     */
    int32_t map_device_enumerate_devices(map_device_info_t **out_devices, uint32_t *out_count);

    /**
     * Enumerates all physical audio capture devices available on the host system.
     */
    int32_t map_device_enumerate_capture_devices(map_device_info_t **out_devices, uint32_t *out_count);

    /**
     * Deallocates the array of device info structures returned by enumeration functions.
     */
    void map_device_free_devices(map_device_info_t *devices);

    /**
     * Combined playback and capture hardware device enumeration result.
     */
    typedef struct
    {
        map_device_info_t *playback_devices;
        uint32_t playback_count;
        map_device_info_t *capture_devices;
        uint32_t capture_count;
    } map_all_devices_t;

    /**
     * Enumerates both playback and capture devices in a single call.
     */
    int32_t map_device_enumerate_all(map_all_devices_t *out_all);

    /**
     * Frees all arrays within the combined device enumeration structure.
     */
    void map_device_free_all(map_all_devices_t *all);

#ifdef __cplusplus
}
#endif

#endif /* MINIAUDIO_DEVICE_BRIDGE_H */
