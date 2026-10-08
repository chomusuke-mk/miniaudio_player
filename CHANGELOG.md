# Changelog

## 2.1.0

### 📊 ReplayGain & ITU-R BS.1770-4 Loudness Analysis

- **Native C Loudness & Peak Analysis**:
  - Implemented the full **ITU-R BS.1770-4 / EBU R128** standard in native C (`src/miniaudio_player.c`):
    - Cascaded **Direct Form II Transposed (DF2T)** biquad filtering: High-Shelf pre-filter (~1,682 Hz, +3.99 dB) and RLB High-Pass filter (~38 Hz) with dynamic coefficient computation for any sample rate.
    - True sample peak tracking (`fmaxf(abs(s), peak)`) across all channels.
    - Energy accumulation over 100 ms sub-intervals and 400 ms sliding gating blocks.
    - Dual gating algorithm: **Absolute Threshold** at -70 LUFS and **Relative Threshold** at -10 LUFS.
- **Zero-Isolate Non-Blocking C Thread Architecture**:
  - `MiniaudioPlayer.calculateReplayGain(path, {targetLufs = -18.0})`: executes on a dedicated OS background worker thread (`ma_thread` / `pthread` / `CreateThread`) and dispatches results to Dart via `NativeCallable.listener`.
  - Zero Dart VM Isolate startup overhead, zero GC pressure, and zero Flutter UI blocking (preserves 60/120 fps).
  - Synchronous version `MiniaudioPlayer.calculateReplayGainSync(...)` also available for synchronous script or batch pipelines.
- **Ultra-Low Constant RAM Usage (< 100 KB)**:
  - Streaming chunk decoder processes audio in 32 KB blocks residing entirely within CPU L1/L2 cache. Audio is never fully loaded into memory.
  - Sub-block statistical history array uses only ~12 KB for a typical 5-minute track.
- **`ReplayGainResult` Model & Volume Scaling**:
  - Exposes `gainDb`, `peak`, and `lufs`.
  - Includes `getRecommendedVolume({bool preventClipping = true})` to directly convert calculated decibels into a linear volume factor for `player.action.setVolume()`, with automatic anti-clipping protection against digital distortion.
- **Extensive Codec Support**:
  - Natively analyzes MP3, WAV, FLAC, OGG, Opus, AAC, M4A (AAC & ALAC), AIFF, and more.

## 2.0.0

### 🔊 Audio Device System Overhaul & DX Improvements

- **User-Friendly Presentation & Localization**:
  - Replaced ambiguous string formatting with a dedicated, human-readable `AudioDevice.displayName` getter designed directly for Flutter UI components (`DropdownButton`, `ListTile`, dialogs).
  - Added `defaultDeviceDisplayNameResolver` in `MiniaudioPlayerGlobalConfig` / `MiniaudioPlayer.config(...)`, allowing full customization and internationalization (i18n/l10n) of the system default device label (defaults to `"System Default ($resolvedName)"` or `"System Default"` if empty).
- **Clean Native C Architecture**:
  - Completely removed artificial `"Default -> %s"` prefix formatting in native C (`src/miniaudio_player.c`), now directly emitting pure hardware device names.
  - Eliminated string manipulation and parsing in Dart FFI interop (`native_types.dart`).
- **Streamlined `AudioDevice` Model**:
  - Clean field set: `id`, `name`, `resolvedName`, `isAuto`, and `type`.
  - Removed confusing `isDefault` field in favor of `isAuto` (system routing) and `resolvedName` (underlying hardware).
  - Strict ID-based equality (`operator ==`) prevents UI assertion errors and selection flickers in Flutter dropdowns when device metadata updates dynamically.
  - Removed `includeAuto` parameter from `MiniaudioPlayer.getAudioDevices()`: the automatic/system-managed device (`AudioDevice.auto`) is now a first-class citizen always provided at index 0.
- **Clean Separation Between Player Instance & Global Enumeration**:
  - **Player Instance (Singular Device Only)**:
    - `player.state.audioDevice` & `player.stream.audioDevice`: currently active output device for this player instance.
    - `player.getAudioDevice()`: queries and updates active hardware routing directly from the native engine.
    - Removed plural `audioDevices` from `player.state` and `player.stream` to eliminate ambiguity and unnecessary per-instance device polling.
  - **Global MiniaudioPlayer Class**:
    - `MiniaudioPlayer.getAudioDevices()`: directly invokes the native FFI enumeration method (returns `Future<List<AudioDevice>>`).
    - `MiniaudioPlayer.getAudioDevicesSync()`: provides synchronous FFI access to enumerated audio devices (`List<AudioDevice>`).
    - `MiniaudioPlayer.getAudioDevicesStream()`: broadcast stream (`Stream<List<AudioDevice>>`) hooked directly into native C device hotplug and routing notifications via `NativeCallable.listener`.

### 📱 Android Audio Device Discovery Updates

- **Telephony Filter Removed**:
  - Telephony audio devices (`TYPE_TELEPHONY`) are no longer excluded on Android, ensuring full device availability for VoIP, telecommunication, and specialized voice communication applications.

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
