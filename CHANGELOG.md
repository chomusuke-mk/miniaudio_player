# Changelog

## 3.0.2

- **Auto-Crossfade & Seek FSM Synchronization**:
  - Guarded automatic crossfade lifecycle with `_autoCrossfadeTriggered` to prevent duplicate or out-of-order scheduling from high-frequency position ticks.
  - Seeking outside the auto-crossfade zone (`position < duration - crossfadeDuration`) now immediately aborts any in-flight or preparing auto-crossfade, restores active deck volume to 100%, resets the standby deck to standby, bumps epoch to cancel pending asynchronous preparation tasks, and allows re-triggering when the track naturally reaches the boundary again.
  - Position stream listener automatically detects if playback position falls outside the auto-crossfade window (with a 500 ms safety buffer tolerance against hardware timer jitter) and cancels active auto-crossfades safely.
  - Seeking inside the auto-crossfade zone preserves the running transition and synchronizes the gain envelope progress directly with the seeked position.
  - Preserved manual crossfade semantics during seeking on incoming tracks without unintended reverts to discarded tracks.
- **Libopus Decoder Stream Resynchronization & Premature EOF Fix**:
  - Fixed a critical bug in `ma_libopus_seek_to_pcm_frame` where seekable Ogg Opus files (especially tracks with embedded metadata such as PNG cover art in `OpusTags`) experienced premature EOF / track skipping after seeking.
  - When the underlying stream buffer was repositioned or flushed externally (e.g. `map_buffer_try_seek_cached` resetting `read_cursor`), `opusfile`'s internal file offset `_of->offset` became desynchronized from the actual buffer cursor by the exact size of the scanned metadata headers. As audio was decoded, `opusfile` prematurely triggered EOF once its desynchronized offset reached the file size limit, causing playback to end early (e.g. at ~16-17s in a 78s file).
  - Added stream offset resynchronization via `pOpus->onTell` inside `ma_libopus_seek_to_pcm_frame`, resetting `ogg_sync_reset(&of->oy)` and decoder state so `op_pcm_seek` always executes in lockstep with the buffer.
  - Accurately synchronized `pOpus->currentPCMFrame` with `op_pcm_tell` return value after seeking.
- **Verbose Diagnostic Logging for Engine & Crossfade**:
  - Added structured verbose logs in `MiniaudioEngine` and `InternalCrossfadeController` activated via `MiniaudioLogLevel.verbose` (`[miniaudio_player][VERBOSE][engine]` and `[miniaudio_player][VERBOSE][crossfade]`).
  - Displays real-time crossfade parameters, normalized gain curves (`p`, `volOut`, `volIn`), media elapsed time, deck positions, durations, completion flags, and state machine phase transitions.
- **Loader Backpressure & Decoder Seek Fixes**:
  - Fixed `UnifiedAudioLoader.seek` on cache hits where an active stream previously paused by backpressure remained frozen, causing audio buffer starvation after ~14s.
  - Fixed `map_decoder_reset_stream` for MP3 streams to preserve `audio_start` (ID3v2 offset) instead of resetting `streamStartOffset` to 0, preventing decoder seek failures that restarted sound from 0s.
  - Fixed `ma_libopus_reset_stream` decoder position synchronization.

## 3.0.1

Update description and links on `pubspec.yaml`.

## 3.0.0

This release marks the largest milestone in `miniaudio_player` history. The library evolves from a single-deck local file player (v2.1.0) into a **complete, studio-grade cross-platform audio engine and DSP workstation** for Flutter, Dart, and Web. It introduces full WebAssembly and AudioWorklet web support, an automated dual-deck queue engine with continuous mathematical crossfades, custom byte providers with on-the-fly decryption for DRM and protected audio, a native tripartite circular buffer, dynamic hardware routing with 0 ms acoustic leak prevention, and an uncompromising canonical API adhering to the _Zero-Alias Axiom_.

---

### 🚀 Breaking Changes & Canonical Zero-Alias Axiom

- **Single Canonical & Polymorphic `open()` Method**:
  - Deprecated and removed legacy single-file `open(path)` and individual loader methods (`openFile`, `openUrl`, `openAsset`, `openMemory`, `openFd`, `openQueue`, `openSources`).
  - All audio loading now routes through a single canonical method:
    - **`MiniaudioPlayer`**: `player.action.open(source, {Duration? bufferAhead, Duration? bufferBehind})`. Accepts strongly typed `AudioSource` instances, raw path strings, remote URLs, live streams, assets, in-memory `Uint8List` byte buffers, URIs (`http://`, `https://`, `icy://`, `asset://`, `file://`, `data:`), and custom `AudioByteProvider` implementations.
    - **`MiniaudioEngine<T>`**: `engine.action.open(items, {int? startIndex, bool shuffle = false})`. Accepts polymorphic lists of `EngineItem<T>`.
- **Removed `autoPlay` Parameter**:
  - Removed `autoPlay` from all `open` signatures across `MiniaudioPlayer` and `MiniaudioEngine<T>`.
  - Calling `open()` strictly prepares the underlying audio pipeline (`EnginePhase.paused` / `PlaybackState.paused`); playback begins only upon explicit invocation of `action.play()` (or is preserved across `next()`, `previous()`, and `skipToIndex()` when already playing). This guarantees 100% compliance with modern browser autoplay security policies.
- **Strict Canonical Transport Verbs**:
  - `player.action` and `engine.action` exclusively expose canonical transport methods: `play()`, `pause()`, `stop()`, and `seek()`.
  - Ambiguous or duplicate aliases such as `start()` or `resume()` have been completely eliminated.

---

### 🌐 Full Web Platform Support (WebAssembly & AudioWorklet)

- **First-Class Browser Execution**:
  - Cross-compiled the core miniaudio C99 engine and DSP pipelines to WebAssembly (`miniaudio_player.wasm`).
  - Implemented `WebPlayerBackend` operating inside a dedicated Web Worker to isolate audio stream decoding from the browser's UI thread, eliminating frame drops.
  - Rendered audio in real time using a custom `AudioWorkletNode` in the Web Audio API, delivering low-latency, glitch-free PCM playback in Flutter Web.
  - Full API and feature parity across Web, Android, iOS, Windows, macOS, and Linux.

---

### 🔐 Custom Audio Sources, DRM & On-The-Fly Decryption (`AudioByteProvider`)

- **Abstract `AudioByteProvider` Architecture**:
  - Introduced an extensible byte-stream abstraction allowing developers to inject custom streaming data sources into the native playback pipeline.
- **Zero-Disk-Write In-Memory Decryption (DRM & Protected Content)**:
  - Enables on-the-fly decryption (e.g. AES-128, ChaCha20, custom DRM algorithms, proprietary audiobook/game packages) via Dart `Stream<Uint8List>`.
  - **Zero Disk Footprint**: Decrypted audio streams exist exclusively in memory RAM and are piped directly to native C buffers (`map_buffer_t`) and the OS audio DAC, completely preventing decrypted files from ever leaking to temporary folders or disk caches.
  - **Reactive Backpressure**: Automatically throttles stream reading and decryption via `pause()` and `resume()` on the underlying stream subscription, decrypting only the exact buffer window needed.
  - **Random-Access Seeking**: Custom providers implement `open({int offset = 0, int? length})` to compute cipher block offsets (such as AES-CTR block counters) and resume streaming at any arbitrary byte offset.
- **Plug-and-Play Integration**:
  - Instantiated via `AudioSource.custom(provider)` or passed directly to `player.action.open(provider)` and `EngineItem(source: AudioSource.custom(provider))`.

---

### 🎛️ High-Level Dual-Deck Queue & Crossfade Engine (`MiniaudioEngine<T>`)

- **Tripartite Facade Architecture (`.action`, `.state`, `.stream`)**:
  - High-level multi-track orchestrator wrapping two underlying player instances (_Deck A_ and _Deck B_) that alternate between Active and Standby roles.
  - `engine.action`: Asynchronous transport commands, queue navigation, queue mutation, crossfade tuning, ReplayGain normalization, Infinite Mix, and master DSP controls.
  - `engine.state`: Synchronous $\mathcal{O}(1)$ snapshot getters for playback phase, active queue, current/next track item and user payload (`currentData`, `nextData`), crossfade status, and deck telemetry.
  - `engine.stream`: Fine-grained reactive broadcast streams multiplexed smoothly across active deck transitions without UI flicker.
- **Deterministic 8-State Finite State Machine (`EnginePhase`)**:
  - Lifecycle states: `idle`, `loading`, `playing`, `paused`, `autoCrossfading`, `manualCrossfading`, `completed`, and `error`.
  - Serialized FIFO asynchronous command queue (`_serialize`) eliminating race conditions, zombie background decks, and dirty states when rapidly skipping tracks.
- **Continuous 25 ms Dual-Deck Crossfade (`CrossfadeConfig` & `CrossfadeCurve`)**:
  - **Equal-Power (`CrossfadeCurve.equalPower`)**: Constant-power trigonometric curve ($\cos(\frac{\pi}{2}t)$ fade-out, $\sin(\frac{\pi}{2}t)$ fade-in, $-3.01\text{ dB}$ midpoint) that maintains perceived acoustic volume across uncorrelated tracks.
  - **Linear (`CrossfadeCurve.linear`)**: Linear gain ramp ($1 - t$ fade-out, $t$ fade-in) for correlated stems and voice tracks.
  - **Auto-to-Manual Promotion**: Invoking `engine.action.next()` while an automatic crossfade is active promotes the transition to a manual skip in-place, capping its remaining duration to `manualDuration` without restarting or reopening the incoming track.
  - **Reactive Invalidation**: Dynamic queue mutations (`insertNext`, `reorder`, `removeAt`, `setShuffle`, `setLoopMode`) abort stale tentative crossfades and restore unity master volume.
- **Non-Destructive Queue Management (`EngineItem<T>`, `LoopMode` & Infinite Mix)**:
  - Strongly typed `EngineItem<T>` container preserving exact references to domain models (`identical(item.data, model) == true`).
  - Fisher-Yates uniform shuffle (`setShuffle(true)`) pinning the active item at index 0, with exact non-destructive un-shuffle (`setShuffle(false)`) restoring the original playlist order.
  - Supported loop modes: `LoopMode.off`, `LoopMode.one` (repeats current track without crossfading), and `LoopMode.all` (continuous playlist loop).
  - Proactive `InfiniteMixProvider<T>`: Asynchronous callback triggered automatically as the queue reaches its final track to seamlessly append incoming tracks for non-stop playback.

---

### 🌊 Native Tripartite Memory Buffer (`map_buffer_t`) & Capability Promotion

- **Tripartite Memory Layout in C (`src/map_buffer.c`)**:
  - **Pinned Head**: Dedicated buffer segment preserving initial container headers (ID3v2, RIFF, FLAC streaminfo, Ogg headers) to ensure decoders never lose container context during stream recycling.
  - **Pure Audio Ring**: Lock-free circular sliding ring buffer ($\mathcal{O}(1)$) absorbing network jitter and thread latency without blocking the OS audio thread.
  - **Tail Buffer**: Dedicated segment for trailing container metadata and seek tables (ID3v1, APEv2, MP4 `moov` atoms).
- **5-Level Capability Promotion Pipeline (`AudioSource.uri(...)`)**:
  - **Level 1**: `FileAudioSource` (local filesystem, OS page cache DMA).
  - **Level 2**: `MemoryAudioSource` (in-memory `Uint8List`, zero-copy sublist views).
  - **Level 3**: `AssetAudioSource` (Flutter app bundle assets loaded directly into RAM via `MiniaudioPlayerGlobalConfig.assetLoader` without disk copies).
  - **Level 4A**: `NetworkAudioSource` (progressive HTTP/HTTPS streaming with byte-range `Range: bytes=X-` seeking).
  - **Level 4B**: `LiveStreamAudioSource` (unbounded Icecast/Shoutcast internet radio with sliding jitter buffers and on-the-fly ICY metadata demuxing).
  - **Level 5**: `FdByteProvider` / `ResolvingAudioSource` (Android Scoped Storage file descriptors).
- **Silence Synthesis on Network Starvation**:
  - Generates zero-filled PCM silence in real time when network streams experience transient packet loss, preventing harsh DAC clicks or audio glitching.

---

### 🔌 Dynamic Hardware Routing & Zero-Leak Transitions (`pauseOnDeviceChange`)

- **Physical Endpoint Resolution (`AudioDevice.auto` vs `effectiveId`)**:
  - Resolves system virtual default devices (`'default'`, `NULL`) to their true physical hardware identifiers (`effectiveId`) across PulseAudio, CoreAudio, AAudio, and WASAPI.
- **Zero-Leak Native C Pause Delegation (0 ms Acoustic Leakage)**:
  - Intercepts hardware route changes (e.g. unplugging wired headphones or disconnecting Bluetooth sinks) directly within the native C core before PCM frames are scheduled to the new destination.
  - Halts playback atomically with **0 ms of acoustic leakage**, guaranteeing that private audio will never inadvertently blast through built-in device speakers.
- **Dual-Deck Engine Delegation**:
  - Hardware device selections and pause-on-disconnect policies automatically synchronize across both active and standby decks in `MiniaudioEngine<T>`.

---

### 📊 Offline Single-Pass Audio Analysis (ITU-R BS.1770-4 / EBU R128)

- **High-Speed Background Decoding Pass**:
  - Analyzes complete audio files in a single pass on background native C OS threads using less than 100 KB of constant RAM, without creating heavy Dart Isolates or dropping Flutter UI frames.
  - Calculates Integrated Loudness (LUFS) using standard K-weighting filters, True-Peak maximum levels (dBTP), and Loudness Range (LU).
  - Computes recommended ReplayGain normalization values with built-in anti-clipping headroom defense ($-1.0\text{ dBFS}$ ceiling).
  - Extracts downsampled normalized amplitude waveform float arrays for instant, seamless binding to interactive Flutter seekbars.

---

### 🎨 Overhauled Digital Audio Workstation (DAW) Example App

- **Studio Master Console (`StudioConsoleView`)**:
  - Modular, studio-grade dark theme (`StudioColors`) featuring neon accents, interactive canvas painters, and responsive grid layouts.
  - Dedicated cards: _Playback Engine_ (waveform seekbar, floating slider popups for volume/rate/pitch, buffer size & output device selectors, zero-leak switch), _Playlist Queue_ (drag-and-drop reordering, source badges, crossfade curve chips, floating duration sliders), _Spectrum Visualizer_ (10-band BPF filter bank, stereo L/R VU meters, 0% idle CPU), _Audio Analyzer_ (4 KPI tiles, ReplayGain & Anti-Clipping controls), _ISO 266 Equalizer_ (draggable interactive biquad response curve, presets, preamp), _Algorithmic Reverb_ (5 rotary studio knobs, Freeverb presets), and _Spatial Limiter & Silence_ (crossfeed, soft-knee limiter, silence trimming).
- **Ingest & Buffer Matrix (`IngestMatrixView`)**:
  - Interactive technical visualization displaying the 5-level capability promotion hierarchy and the memory layout of the native C tripartite buffer (`map_buffer_t`).

---

---

## 2.1.0

### 🎵 Audio Engine Features & Public API

#### 🏛️ Studio-Grade Algorithmic Reverb (Freeverb Topology) & Acoustic Presets

- **Algorithmic Reverberation Engine**: Implemented a studio-grade stereophonic algorithmic reverb in native C (`src/map_reverb.c`, `src/map_reverb.h`) based on the classic Freeverb/Schroeder architecture:
  - 8 parallel Lowpass Feedback Comb Filters (LBCF) with tunable feedback and lowpass damping per channel.
  - 4 cascaded Allpass Filters (APF) per channel for high-density diffusion without metallic ringing.
  - Stereophonic decorrelation with a 23-sample spatial offset between left and right delay lines.
- **Strict Real-Time $\mathcal{O}(1)$ Determinism & Zero Allocations**:
  - Pre-allocated 163,840-sample static buffer (640 KB aligned to 64 bytes) during initialization.
  - Guarantees **0 dynamic heap allocations (`malloc`/`free`) in the real-time audio thread**, safely handling sample rates up to 192 kHz.
- **Hardware Anti-Denormal Guards (Flush-to-Zero)**:
  - Flush-to-zero thresholding (`fabsf(v) < 1e-20f ? 0.0f : v`) embedded inside all comb and allpass delay filter loops, completely preventing CPU microcode stalls when reverb tails decay into silence.
- **Anti-Zipper Parameter Smoothing**:
  - Sample-accurate linear interpolation across audio buffers for `roomSize`, `damping`, `width`, `wet`, and `dry` parameters, ensuring smooth, click-free parameter transitions.
- **Studio-Grade Acoustic Presets (`Reverb` factory presets & `Reverb.presets` map)**:
  - `Reverb.off`: Transparent bypass with zero processing overhead.
  - `Reverb.smallRoom`: Intimate, dry room with rapid early reflections (`roomSize: 0.35, damping: 0.60, wet: 0.18, dry: 0.82, width: 0.70`).
  - `Reverb.studio`: Controlled recording studio acoustics (`roomSize: 0.50, damping: 0.40, wet: 0.22, dry: 0.78, width: 0.85`).
  - `Reverb.concertHall`: Expansive, balanced symphonic hall (`roomSize: 0.75, damping: 0.30, wet: 0.32, dry: 0.68, width: 1.00`).
  - `Reverb.cathedral`: Monumental sanctuary with extended airy tail (`roomSize: 0.90, damping: 0.15, wet: 0.42, dry: 0.58, width: 1.00`).
  - `Reverb.plate`: Bright, dense electromechanical plate reverberator (`roomSize: 0.65, damping: 0.10, wet: 0.28, dry: 0.72, width: 0.90`).
  - `Reverb.ambient`: Atmospheric, enveloping diffuse sonic wash (`roomSize: 0.85, damping: 0.50, wet: 0.38, dry: 0.62, width: 1.00`).
- **Complete Dart API & Reactive Integration**:
  - Imperative action: `player.action.setReverb(Reverb)` and granular `player.action.configureReverb({roomSize, damping, wet, dry, width, enabled})`.
  - Synchronous state inspection: `player.state.reverb`.
  - Real-time broadcast telemetry stream: `player.stream.reverb`.
  - Immutable model: `Reverb` with `copyWith()`, `presetName`, and backwards-compatible alias `typedef ReverbConfig = Reverb`.

#### 🎚️ Optimized DSP Chain Acoustic Ordering

- Positioned the reverb engine at **Step 2.5** in `src/map_dsp.c` (Post-Equalizer, Pre-Spatializer/Crossfeed, Pre-Mono/Balance, Pre-Visualizer, Pre-Limiter):
  - **Post-EQ**: Prevents uncontrolled low-frequency mud or harsh resonance peaks from exciting the reverberation tank.
  - **Pre-Spatializer & Crossfeed**: Allows the natural diffuse reverberant soundstage to be shaped by binaural headphone crosstalk (`bs2b`) or stereophonic widening.
  - **Pre-Visualizer**: Ensures the real-time spectrum analyzer and VU meters capture physical acoustic room decay.
  - **Pre-Limiter**: Guarantees all energy accumulation from dense reflections and resonant feedback is safely caught by the True-Peak Soft-Knee Limiter, completely preventing digital clipping.

---

## 2.0.0

### 🎵 Audio Engine Features & Public API

#### 🛡️ Hardware-Grade Output Limiter (True-Peak Soft-Knee)

- True-Peak brickwall limiter operating directly before DAC handoff.
- Mathematically transparent in the linear zone ($|x| \le 0.95$ FS) with **0.00000% THD** and **141.4 dB SNR**.
- Smooth second-order parabolic compression across the soft-knee zone ($0.95 < |x| \le 1.0$), capping output safely at $0.996$ FS even under aggressive digital overshoot (+3.5 dBFS) to eliminate harsh digital clipping.
- Controlled via `player.action.setLimiter(bool)` with state observed via `player.stream.limiterEnabled` and `player.state.limiterEnabled`.

#### 🎧 Binaural Headphone Crossfeed (Bauer bs2b)

- Native stereophonic-to-binaural DSP filter modeling acoustic speaker crosstalk to eliminate headphone listening fatigue.
- Standard operational presets (`CrossfeedMode`):
  - `CrossfeedMode.moffatBauer`: Default Moffat-Bauer standard curve (700 Hz cut-off, 4.5 dB feed).
  - `CrossfeedMode.chuMoy`: Subtle Chu Moy curve (700 Hz cut-off, 6.0 dB feed).
  - `CrossfeedMode.off`: Bypasses crossfeed processing with zero overhead.
- Controlled via `player.action.setCrossfeed(CrossfeedMode)` and monitored via `player.stream.crossfeed` / `player.state.crossfeed`.

#### 🎛️ Standard ISO 266 10-Band Equalizer & Acoustic Presets

- Aligned native biquad filters to the international standard ISO 266 preferred 1/1 octave center frequencies:
  - `hz31`: 31 Hz (Low-Shelf, $Q = 0.7071$)
  - `hz63`: 63 Hz (Peaking, $Q = 1.15$)
  - `hz125`: 125 Hz (Peaking, $Q = 1.15$)
  - `hz250`: 250 Hz (Peaking, $Q = 1.15$)
  - `hz500`: 500 Hz (Peaking, $Q = 1.15$)
  - `hz1k`: 1.0 kHz (Peaking, $Q = 1.15$)
  - `hz2k`: 2.0 kHz (Peaking, $Q = 1.15$)
  - `hz4k`: 4.0 kHz (Peaking, $Q = 1.15$)
  - `hz8k`: 8.0 kHz (Peaking, $Q = 1.15$)
  - `hz16k`: 16.0 kHz (High-Shelf, $Q = 0.7071$)
- Gain range: `-24.0 dB` to `+24.0 dB` per band with analytical Robert Bristow-Johnson (RBJ) audio EQ curves (**0.00 dB analytical error**).
- Harmonized acoustic presets: `Equalizer.rock`, `Equalizer.pop`, `Equalizer.jazz`, `Equalizer.classical`, `Equalizer.bassBoost`, and `Equalizer.flat`.
- Immutable model with `copyWith()`, `toList()`, and `Equalizer.fromList()`.

#### 🎚️ Mono Downmixing, Channel Balance & Stereo Spatializer

- `player.action.setMono(bool)`: Downmixes stereo audio into mono for single-speaker setups, hardware accessibility, or specialized monitoring.
- `player.action.setBalance(double pan)`: Smooth stereo balance panning from `-1.0` (full left) through `0.0` (center) to `+1.0` (full right).
- `player.action.setSpatializer({required bool enabled, double width = 1.3})`: Stereo field expansion with adjustable width factor (`1.0` to `2.0`).

#### 🔊 ReplayGain & EBU R128 Loudness Normalization with Clipping Defense

- `player.action.setReplayGain({required double gainDb, double? peak, double preampDb, bool preventClipping})`: Applies track gain normalization with smooth anti-zipper volume ramping.
- Anti-clipping defense automatically caps gain factor so `(gainDb + preampDb) * peak <= 1.0`, preventing digital overs.
- `player.action.clearReplayGain()`: Resets normalization back to unity gain (0.0 dB).
- `player.action.setPreamp(double preampDb)`: Dedicated standalone manual preamp gain applied prior to equalizer filtering.

#### 📈 Real-Time Reactive Audio Visualizer & Spectrum Analyzer

- Native Direct Form II Transposed biquad bandpass filter bank embedded directly inside the native audio playback node in C (`src/map_dsp.c`).
- Centered at the exact 10 ISO 266 equalizer frequencies (`31 Hz` through `16 kHz`) for 1:1 visual correlation with EQ adjustments.
- Stereo VU meters (Left and Right channels), global RMS energy, and instantaneous peak sample tracking.
- Perceptual frequency compensation curve and smooth exponential decay (`0.82f`) for fluid 30-60 fps visual rendering.
- On-Demand Lifecycle: Subscribing to `player.stream.visualizer` activates DSP filtering on-demand (~30 fps telemetry); unsubscribing turns off processing and resets telemetry, keeping idle/background CPU usage strictly at 0%.
- API models and access: `VisualizerData` model, synchronous getter `player.state.visualizer`, and explicit manual override via `player.action.setVisualizerEnabled(bool)`.

#### 🔇 Native Real-Time Silence Detection & Dynamic Skipping

- In-pipeline streaming silence detector in native C (`src/map_silence.c`) positioned upstream of Sonic DSP and the equalizer cascade.
- Zero intermediate memory copies, zero buffer starvation, and smooth anti-click crossfading (linear ramp over 5ms) preventing audible pops.
- Modalities (`SilenceSkipMode`):
  - `SilenceSkipMode.trimEdges`: Trims lead-in silence on track start and truncates trailing lead-out silence at track end. Ideal for music playlists and gapless playback.
  - `SilenceSkipMode.continuous`: Dynamically skips in-between speech pauses down to configurable padding. Ideal for podcasts, audiobooks, lectures, and voice messages.
  - `SilenceSkipMode.all`: Simultaneously trims lead-in/lead-out track edges and truncates continuous pauses in between.
  - `SilenceSkipMode.disabled`: Bypasses silence detection completely with zero CPU overhead.
- Customizable parameters via `SilenceSkipConfig`: `thresholdDb` (default: `-45.0 dB` with 2 dB hysteresis), `minSilenceDuration` (default: `300 ms`), and `padding` (default: `50 ms`).
- Real-time tracking of cumulative skipped time: `player.stream.silenceSavedDuration` and `player.state.silenceSavedDuration`.

#### 📊 Unified Single-Pass Audio Analysis (Loudness, ReplayGain & Waveform)

- Unified loudness calculation and waveform envelope extraction into a single, highly optimized decoding pass in native C (`src/map_analysis.c`).
- Eliminates redundant file I/O and frame decoding, reducing CPU usage and analysis duration by ~50% compared to independent analysis runs.
- Streams audio in 32 KB blocks residing in CPU L1/L2 cache (< 100 KB constant RAM footprint).
- Asynchronous API (`MiniaudioPlayer.analyzeAudio`): executes on a dedicated native background thread with completion delivered via `NativeCallable.listener` (zero Dart Isolates, zero UI frame drops). Synchronous variant `MiniaudioPlayer.analyzeAudioSync(...)` available for CLI tools.
- Rich analysis models: `AudioAnalysisResult`, `ReplayGainResult` (ITU-R BS.1770-4 / EBU R128 LUFS), and `WaveformResult` with normalized amplitude points for UI seekbars.

#### 🔌 Audio Device Management & Dynamic Routing

- Clean `AudioDevice` architecture: dedicated model with `id`, `name`, `resolvedName`, `isAuto`, `type`, and human-friendly `displayName`.
- Global `defaultDeviceDisplayNameResolver` for custom internationalization/localization of system default routing labels.
- Strict ID-based equality (`operator ==`) preventing UI assertion errors and selection flickers in Flutter dropdown menus.
- Instance vs Global separation:
  - Per-player: `player.state.audioDevice`, `player.stream.audioDevice`, `player.action.setDevice(AudioDevice)`.
  - Global: `MiniaudioPlayer.getAudioDevices()`, `MiniaudioPlayer.getAudioDevicesSync()`, and `MiniaudioPlayer.getAudioDevicesStream()`.

#### 🔄 Dual State Paradigm & Safe Lifecycle

- Instant synchronous state getters (`player.state.*`) alongside reactive broadcast streams (`player.stream.*`).
- `MiniaudioPlayer` implements `Finalizable` with a low-level static `NativeFinalizer` bound to `miniaudio_player_destroy`, ensuring leak-free garbage collection if the instance is collected without explicit `dispose()`.

---

### ⚡ Low-Level Platform Engineering & Microarchitecture

#### 📱 Android 15+ 16 KB ELF Page Alignment & ARM NEON

- Enforced `-Wl,-z,max-page-size=16384` link flag in `hook/build.dart` for full compatibility with Android 15+ 16 KB memory page kernels.
- Enabled ARM NEON vfpv4 vectorization on 32-bit ARM (`armeabi-v7a`) and automatic AArch64 SIMD compilation.

#### 🤖 Autonomous Pure C JNI Android Bridge

- Standalone JNI bridge operating without MethodChannels, `package:jni`, or Kotlin code in `MainActivity.kt`.
- Multi-tier dynamic `JavaVM` discovery across Android API 21 through 35+ (via `JNI_OnLoad`, `libnativehelper.so`, `libart.so`, and `dl_iterate_phdr` memory scan).
- Reflective application context acquisition compatible with headless background services (`ActivityThread.currentApplication()`).
- Hardware route classification (earpieces, speakers, wired headphones, USB, Bluetooth A2DP vs SCO).
- Resilient AAudio route disconnection recovery (`AAUDIO_SERVICE_EVENT_DISCONNECTED`) without audio stalls.

#### 🪟 Windows WASAPI MMCSS Pro Audio & High-Precision Timers

- Configured `wasapi.usage = ma_wasapi_usage_pro_audio`, activating Windows MMCSS (`AvSetMmThreadCharacteristicsA("Pro Audio")`) for real-time scheduling priority.
- Enforced 1 ms Win32 timer resolution (`timeBeginPeriod(1)` and `timeEndPeriod(1)`), eliminating decoder starvation caused by Windows default 15.6 ms sleep granularity.

#### 🔬 Universal Hardware FTZ/DAZ Denormal Mitigation

- `map_disable_denormals()` sets Flush-to-Zero (FTZ) and Denormals-are-Zero (DAZ) bits directly in CPU control registers (x86 MXCSR `0x8040`, ARM64 FPCR, ARMv7 FPSCR, Windows `_controlfp_s`). Prevents 100x CPU cycle penalties on decaying IIR filter tails.

#### ⚡ Microarchitectural Atomic Synchronization & Memory Barriers

- Weak memory model support for ARM64/ARMv7: explicit hardware memory barriers (`DMB ISH` for Release, `DMB ISHLD` for Acquire) and pipeline yield instructions (`isb; yield`).
- Total Store Order (TSO) optimization on x86/x86_64: pure compiler barriers (`__atomic_thread_fence` / `_ReadWriteBarrier`) completely eliminating heavy bus-locking instructions (`MemoryBarrier()` / `_mm_mfence()`), saving 30–100 CPU cycles per read.
- Seqlock synchronization (`src/map_seqlock.h`): pre-check backoff loop (`while ((seq & 1) != 0)`) and local structure staging (`local_vis`), reducing the writer critical section to a single atomic 56-byte copy (< 2 CPU cycles). Certified across **35+ million concurrent contention reads without data tearing**.

#### 🏎️ SIMD Vectorization & Vector Register Hoisting

- Direct Form II Transposed (DF2T) biquad cascade processed in 64-frame contiguous SIMD blocks with hardware FMA instruction chaining (`vmlaq`/`vmlsq`).
- Hoisted delay registers ($s_1, s_2$) and bs2b filter states directly into CPU vector registers during block processing without stack spilling.

#### 🔒 Lock-Free SPSC Ring Buffer Signaling & Hysteresis

- Atomic `worker_is_sleeping` flag in `map_time_stretch_ds`: RT audio callback signals the background decoder via `ma_event_signal` only when the buffer falls below 50% capacity and the worker is asleep. Completely eliminates POSIX `pthread_mutex` lock contention and prevents priority inversion glitches.

#### ⏱️ Strict Real-Time Determinism ($\mathcal{O}(1)$) & Zero Heap Allocations

- **Zero dynamic heap allocations in RT thread**: validated empirically via memory interceptor wrappers (`--wrap=malloc/calloc/realloc/free`) during live playback and dynamic parameter mutations.
- Cache-line 64-byte alignment (`MAP_ALIGN_CACHE_LINE`, `ma_aligned_malloc`) on `miniaudio_player_t` and ring buffer cursors to prevent false sharing across CPU cores.
- Pre-allocated 64K frame capacity (`SONIC_MIN_STREAM_BUFFER_CAPACITY`) in Sonic varispeed and pre-faulting (`memset`) of working scratch buffers at initialization.

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
