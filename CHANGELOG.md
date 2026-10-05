# Changelog

## 1.0.1

### 🐛 Bug Fixes & Playback Lifecycle

- **Stop & Completed State Separation**:
  - Fixed an issue where calling `stop()` after natural completion caused `miniaudio_player_get_status()` to override the `STOPPED` state back to `COMPLETED` due to unconditioned `ma_sound_at_end()` evaluations.
  - In native C, `ma_sound_at_end()` evaluation is now strictly conditioned on `MAP_PLAYBACK_STATE_PLAYING`. Stopped state is strictly preserved with `is_completed = 0` and `atEnd` flag reset.
  - In Dart, modeled `stream.completed` as an edge-triggered transition (`false -> true`) during active playback, preventing redundant completion events.
  - Decoupled `pollAndEmit(force: true)` from re-emitting terminal completion events.
  - Added synchronous state cleanup (`notifyStopped()`) on `player.action.stop()` to ensure position resets to zero and `completed` is immediately reset for subsequent playback.
- **OGG/OGA/OPUS Seek-to-End Background Audio Leak**:
  - Fixed a bug where seeking to or past track duration while playing `.ogg`, `.oga`, or `.opus` files caused audio to continue playing in the background despite the UI reporting stopped/completed.
  - Resolved root cause in underlying decoders (`stb_vorbis` and `opusfile`), which return seek errors (`VORBIS_seek_failed` / `OP_EINVAL`) when attempting to seek at or beyond `total_frames`.
  - Implemented EOF clamping (to `total_frames - 1`) and EOF flag tracking in `map_time_stretch_ds_seek` and `ma_libopus_seek_to_pcm_frame`.
  - Explicitly stopped the native sound (`ma_sound_stop`) when seeking to or past track duration to cleanly halt audio output.

### 🧪 Tests

- Added tests verifying edge-triggered completion transitions, post-completion stop state integrity, and immunity to `force: true` polling (`test/tier2_boundary_test.dart`).
- Added tests verifying clean audio termination when seeking to or past track duration across OGG, OGA, and Opus codecs (`test/tier1_codecs_test.dart`).

## 1.0.0

### 📄 Relicensed to MIT

- **Permissive MIT License**: The package has transitioned from GPL-v3 to the **MIT License**, removing all copyleft restrictions and allowing free integration into commercial, closed-source, proprietary, and open-source applications alike.

### 🚀 Direct FFI & Zero-Isolate Architecture

- **Eliminated Secondary Dart Isolates**: Removed the internal isolate worker layer (`lib/src/isolate/`). All player commands (`player.action.*`) are now invoked directly through Dart FFI in sub-microseconds with zero message-passing latency and zero isolate memory footprint (~0 MB Dart overhead).
- **Native OS Audio Threads**: Audio decoding, Sonic DSP (pitch & speed), 10-band biquad EQ, and hardware output streaming run concurrently on native OS audio threads (CoreAudio, AAudio, WASAPI, PulseAudio/ALSA) with real-time priority, guaranteeing zero UI frame drops or stutter on the Flutter main thread.
- **Ultra-Responsive Reactive Engine**:
  - Events originating from native audio threads (such as track completion) are dispatched safely to Dart streams using `NativeCallable.listener` without polling.
  - Position and progress reporting is driven by a lightweight internal timer, providing fluid 60/120fps UI updates without port serialization thrashing.
  - Synchronous getters (`player.state.*`) provide instantaneous access to atomically cached native playback values.
- **Seamless Background Isolate Support**: `MiniaudioPlayer` can still be optionally instantiated directly inside standalone worker isolates or background services (`audio_service`, `flutter_background_service`) without any architectural friction.

### 📱 Native Android Audio Device Discovery (Pure C JNI)

- **Zero-Configuration Device Enumeration**: `MiniaudioPlayer.getAudioDevices()` on Android now queries Android's `AudioManager` and `AudioDeviceInfo` directly through an embedded native C JNI bridge.
- **No MethodChannels or Kotlin Required**: Completely eliminated the need for `package:jni`, platform channels, and manual Kotlin implementations in the host app's `MainActivity.kt`.
- **Autonomous Multi-Tier JavaVM Resolution**: Automatically acquires the running `JavaVM` across all Android versions (API 21 to API 35+) using a 6-stage fallback strategy (`JNI_OnLoad`, `libnativehelper.so`, `libart.so`, and dynamic linker memory scanning via `dl_iterate_phdr` to bypass bionic linker namespace restrictions).
- **Headless & Background Compatible**: Acquires application context via reflection on `ActivityThread.currentApplication()`, enabling audio device queries in headless background services without an attached Flutter Activity.
- **Smart Routing & Classification**:
  - Identifies earpieces, built-in speakers, wired headphones, USB audio, and Bluetooth accessories.
  - Distinguishes high-fidelity Bluetooth A2DP audio from SCO telephony headsets.
  - Correctly marks active system default outputs using Android 12+ `AudioManager.getCommunicationDevice()` and fallback routing heuristics (`isBluetoothA2dpOn`, `isWiredHeadsetOn`).
  - Safely ignores internal telephony and modem devices.
- **Hot-Plug & AAudio Rerouting Resiliency**: Intercepts Android AAudio route-change disconnect events (`AAUDIO_SERVICE_EVENT_DISCONNECTED` / error `-899`) during Bluetooth connection/disconnection and seamlessly recreates the audio stream on the new hardware output without audio stalls or crashes.
- **Zero Memory Leaks**: Rigorous JNI local reference management (`DeleteLocalRef`), UTF string release (`ReleaseStringUTFChars`), and clean thread detachment.
- **Cleaned Log Levels**: Internal operational traces changed to `ANDROID_LOG_DEBUG` to keep standard Android logcat output clean and production-ready.

### 🧪 Quality & Tests

- Updated and verified 100% test suite compatibility (131/131 tests passing across native codecs, parametric EQ, pitch/speed, and device routing).

## 0.1.0

- Initial release of `miniaudio_player`.
- Ultra-low-resource cross-platform audio player powered by miniaudio and Sonic DSP.
- 100% pure Dart FFI with Native Assets (isolate-friendly, zero platform channel overhead in core).
- Built-in 10-band parametric equalizer with presets (_Rock_, _Pop_, _Jazz_, _Classical_, _Bass Boost_, _Flat_).
- Real-time independent pitch scaling and playback rate (time-stretching).
- Dynamic runtime audio device selection with automatic fallback and recovery.
- Multi-codec decoding support (MP3, WAV, FLAC, OGG, Opus, AAC, M4A, ALAC, AIFF, W64).
- Dual state API with synchronous getters and real-time reactive broadcast streams.
