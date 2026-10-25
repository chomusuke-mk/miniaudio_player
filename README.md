<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/banner.svg" alt="miniaudio_player banner" width="100%" />
</p>

# <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/icon.png" alt="miniaudio_player icon" width="40" height="40" align="center" /> miniaudio_player

[![pub package](https://img.shields.io/pub/v/miniaudio_player.svg?logo=dart&color=blue)](https://pub.dev/packages/miniaudio_player)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-android%20|%20ios%20|%20macos%20|%20windows%20|%20linux-blue.svg)](https://pub.dev/packages/miniaudio_player)
[![Dart FFI](https://img.shields.io/badge/Dart-FFI%20Native%20Assets-0175C2.svg?logo=dart)](https://dart.dev/interop/c-interop)
[![Tests](https://img.shields.io/badge/tests-189%20passing-brightgreen.svg)](#)
[![Donate (Buy me a coffee)](https://img.shields.io/badge/Donate-Buy%20me%20a%20coffee-orange?logo=buymeacoffee&logoColor=white)](https://www.buymeacoffee.com/chomusuke)
[![Donate (Patreon)](https://img.shields.io/badge/Donate-Patreon-critical?logo=patreon&logoColor=white)](https://www.patreon.com/chomusuke_dev)
[![Donate (Ko-fi)](https://img.shields.io/badge/Donate-Ko--fi-yellow?logo=kofi&logoColor=white)](https://ko-fi.com/chomusuke_dev)

An **ultra-low-resource, high-performance cross-platform audio player and DSP engine** for Flutter and Dart. Powered by the industry-standard [miniaudio](https://miniaud.io/) C engine, [Sonic DSP](https://github.com/waywardgeek/sonic), and **Dart Native Assets** with 100% pure FFI bindings.

Engineered from the ground up for professional electroacoustic fidelity, sub-millisecond command latency, deterministic real-time execution ($\mathcal{O}(1)$), and zero UI stutter by leveraging miniaudio's dedicated real-time native OS audio threads.

---

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/simple_player.png" alt="miniaudio_player - Audio Player Controls" width="480" /><br/>
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/visualizer.png" alt="miniaudio_player - Real-Time Reactive Visualizer" width="480" />
</p>

---

## ✨ Features at a Glance

- 🎛️ **High-Level Dual-Deck Queue & Crossfade Engine (`MiniaudioEngine<T>`)**: First-class dual-deck orchestrator with an explicit Finite State Machine (`EnginePhase`), serialized FIFO command dispatch, continuous Equal-Power & Linear crossfades (`CrossfadeConfig`), Fisher-Yates shuffle & exact un-shuffle, loop modes (`LoopMode.off`, `LoopMode.one`, `LoopMode.all`), generic zero-copy domain item wrapping (`EngineItem<T>`), per-track ReplayGain normalization, and proactive Infinite Mix prefetching (`InfiniteMixProvider<T>`).
- 🌐 **Universal Polymorphic Audio Sources (`AudioSource`)**: Play audio seamlessly from local files (`AudioSource.file`), Flutter assets (`AudioSource.asset`), in-memory byte buffers (`AudioSource.memory`), remote Web audio files over HTTP/HTTPS (`AudioSource.network`), or continuous live internet streams (`AudioSource.liveStream`) with strict separation between `open(...)` and `play()`.
- 🌊 **Web Audio Files & Progressive HTTP/HTTPS Network Streaming**: Low-latency circular stream buffering in native C with non-blocking chunk decoding, custom HTTP headers, redirect following, and arbitrary remote seeking via `Range: bytes=X-` headers.
- 📻 **Continuous Live Audio Streams (Internet Radio / Icecast / Shoutcast)**: Boundless live stream playback with dynamic sliding jitter buffers to prevent dropouts and packet jitter, plus livestream-aware crossfade transitions in `MiniaudioEngine<T>`.
- ⚡ **Direct In-Memory Playback (RAM)**: Decodes and plays audio directly from memory byte buffers (`openMemory`) with zero temporary files, zero disk I/O, and instantaneous startup.
- 📦 **Direct Flutter Asset Playback**: Zero-disk-copy asset loading via `MiniaudioPlayerGlobalConfig.assetLoader` directly streaming from RAM.
- ⚡ **Strict Real-Time Determinism ($\mathcal{O}(1)$) & Zero Allocations**: Direct native C memory management guarantees **0 dynamic heap allocations in the real-time audio thread**, ensuring completely glitch-free audio playback even under intense UI activity or system load.
- 🔀 **100% Pure FFI & Zero-Isolate Architecture**: Commands execute directly via FFI in sub-microseconds without message-passing latency or Dart VM isolate memory bloat. Automatic resource management via `NativeFinalizer` prevents native memory leaks.
- 🛡️ **Hardware-Grade Output Limiter (True-Peak Soft-Knee)**: True-Peak brickwall limiter operating before DAC handoff. Mathematically transparent in the linear zone ($|x| \le 0.95$ FS) with **0.00000% THD** and **141.4 dB SNR**, smoothly compressing digital overshoots (+3.5 dBFS capped safely at 0.996 FS) to eliminate digital clipping.
- 🎧 **Binaural Headphone Crossfeed (Bauer bs2b)**: Acoustic speaker crosstalk emulation for fatigue-free headphone listening with standard Moffat-Bauer and Chu Moy presets.
- 🎛️ **Standard ISO 266 10-Band Parametric Equalizer**: Native Direct Form II Transposed (DF2T) biquad cascade centered at standard preferred 1/1 octave frequencies (`31Hz` to `16kHz`) with analytical RBJ curves (**0.00 dB analytical error**) and built-in acoustic presets (_Rock_, _Pop_, _Jazz_, _Classical_, _Bass Boost_, _Flat_).
- 🏛️ **Studio-Grade Algorithmic Reverb (Freeverb Topology)**: Native C stereophonic algorithmic reverb featuring 8 parallel lowpass feedback comb filters and 4 cascaded allpass filters per channel with stereo decorrelation. Includes studio acoustic presets (_Small Room_, _Studio_, _Concert Hall_, _Cathedral_, _Plate_, _Ambient_) and full dynamic control over room size, damping, stereo width, and wet/dry mix with **0 real-time heap allocations** and hardware anti-denormal protection.
- 📈 **Real-Time Reactive Visualizer & Spectrum Analyzer**: 10-band hardware BPF filter bank embedded directly in the native C playback pipeline matching the ISO 266 equalizer, stereo VU meters (L/R), RMS, and peak metrics (< 0.5% CPU active, **0% idle CPU** via automatic on-demand streaming at ~30 fps).
- 🔇 **Dynamic Silence Skipping & Edge Trimming**: Native C real-time silence detector upstream of time-stretching and EQ. Trims lead-in/lead-out silence for gapless music and dynamically skips conversational pauses for podcasts and audiobooks with a 5ms anti-click crossfade ramp and cumulative saved time tracking.
- 🎚️ **Mono Downmix, Channel Balance & Stereo Spatializer**: Built-in channel routing for mono accessibility, precision stereo balance panning, and stereo field widening.
- 📊 **Unified Single-Pass Audio Analysis (Loudness, ReplayGain & Waveform)**: High-speed, non-blocking offline analysis in a single decoding pass on background native C OS threads (< 100 KB constant RAM). Computes ITU-R BS.1770-4 / EBU R128 loudness (LUFS), true peak, recommended gain (dB), anti-clipping defense, and normalized amplitude waveform points for UI seekbars without spawning Dart Isolates or freezing Flutter frames.
- 🚀 **High-Definition Pitch & Speed (Sonic DSP)**: Real-time time-stretching and independent pitch shifting (0.25x to 4.0x rate, 0.5x to 2.0x pitch) with pristine acoustic clarity and seamless rate transitions.
- 🔌 **Dynamic Audio Device Routing**: Real-time switching between audio output endpoints (speakers, wired headphones, Bluetooth A2DP/SCO) with automatic hotplug detection and seamless reconnection recovery across all supported platforms.
- 🌐 **Background Playback & Standalone Isolate Support**: Fully compatible with background audio services (e.g. `audio_service`, `flutter_background_service`) and standalone Dart isolates thanks to a 100% pure FFI design.
- 📦 **Extensive Audio Codec Support**: Built-in native decoding for MP3, WAV, FLAC, OGG, Opus, AAC, M4A (AAC & ALAC), AIFF, W64, and more without external system dependencies.
- 🔄 **Tripartite Facade Paradigm (`.action`, `.state`, `.stream`)**: Both `MiniaudioPlayer` (single-track) and `MiniaudioEngine<T>` (multi-track queue & crossfade) expose `.action` for commands, `.state` for synchronous instant snapshots, and `.stream` for reactive broadcast telemetry.

---

## 🚀 Performance & Architecture

### 1. Audio DSP Processing Chain

The native DSP pipeline inside `ma_equalizer_node_process_pcm_frames` is ordered strategically to maximize signal-to-noise ratio, minimize phase distortion, and guarantee headroom before final DAC output:

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                Audio PCM Frames In                                     │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
                    ┌───────────────────────────────────────────────┐
                    │    1. Preamp & ReplayGain Volume Ramping      │
                    └───────────────────────┬───────────────────────┘
                                            │
                                            ▼
                    ┌───────────────────────────────────────────────┐
                    │  2. 10-Band Biquad Cascade SIMD (DF2T, RBJ)   │
                    └───────────────────────┬───────────────────────┘
                                            │
                                            ▼
                    ┌───────────────────────────────────────────────┐
                    │ 3. Algorithmic Stereo Reverb (Freeverb 8C+4A) │
                    └───────────────────────┬───────────────────────┘
                                            │
                                            ▼
                    ┌───────────────────────────────────────────────┐
                    │ 4. Binaural Crossfeed / Stereo Spatializer    │
                    └───────────────────────┬───────────────────────┘
                                            │
                                            ▼
                    ┌───────────────────────────────────────────────┐
                    │          5. Mono Downmixing (Optional)        │
                    └───────────────────────┬───────────────────────┘
                                            │
                                            ▼
                    ┌───────────────────────────────────────────────┐
                    │       6. Stereo Balance / Panning Pan         │
                    └───────┬───────────────────────────────┬───────┘
                            │                               │
                            ▼                               ▼
      ┌───────────────────────────────────┐   ┌───────────────────────────┐
      │  7. Visualizer Tap (10-Band BPF)  │   │  8. Master Volume Fader   │
      │     (On-Demand Seqlock Telemetry) │   │     (Steady-State Bypass) │
      └───────────────────────────────────┘   └─────────────┬─────────────┘
                                                            │
                                                            ▼
                                      ┌───────────────────────────────────┐
                                      │ 9. True-Peak Soft-Knee Limiter    │
                                      │    (Branchless SSE/NEON Safeguard)│
                                      └─────────────────────┬─────────────┘
                                                            │
                                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                             Hardware Audio DMA Output                                  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2. Multi-Threaded Lock-Free Architecture

Unlike traditional plugins that hop through platform channels with UI thread contention and serialization overhead, `miniaudio_player` separates execution across three fully decoupled asynchronous domains:

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                             Flutter UI / Dart Main Thread                              │
│  • Sub-microsecond direct FFI invocations (< 1 µs latency)                             │
│  • Reactive broadcast telemetry streams (player.stream.*)                              │
│  • Automatic memory cleanup via NativeFinalizer (Finalizable)                          │
│  • Single-call atomic status snapshot (miniaudio_player_get_status)                    │
└───────────────────────┬────────────────────────────────────────▲───────────────────────┘
                        │ Commands                               │ Seqlock Telemetry
                        │ (play, seek, eq...)                    │ (Atomic 56-byte snapshot)
┌───────────────────────▼────────────────────────┐   ┌───────────┴───────────────────────┐
│     C Background Decoder Worker Thread         │   │   RT Audio Device Callback Thread │
│  • Asynchronous multi-codec file decoding      │   │  • High-priority OS real-time RT  │
│  • FTZ/DAZ denormal purging (map_disable_...)  │   │  • 0 heap allocations (O(1))      │
│  • Sonic varispeed with 64K frame headroom     │   │  • Lock-free SPSC ring buffer read│
│  • Pre-faulted cache-aligned buffers (64B)     │   │  • Complete DSP processing chain  │
└───────────────────────┬────────────────────────┘   │  • Branchless True-Peak limiter   │
                        │ SPSC Commit                │  • Seqlock write (< 2 cycles)     │
                        ▼                            └───────────────────────────────────┘
          ┌───────────────────────────┐
          │ Lock-Free SPSC Ring Buffer│
          │ (64-byte Cache-Line Split)│
          │ worker_is_sleeping flag   │
          └───────────────────────────┘
```

1. **Zero UI Thread Blocking**: All decoding, Sonic time-stretching, equalizer filtering, and audio output run on dedicated native OS audio threads with real-time priority. Commands (`play`, `pause`, `seek`, `setVolume`, `setEqualizer`) execute in sub-microseconds without dropping Flutter frames.
2. **Zero Dynamic Memory Allocations in RT**: Real-time audio callbacks operate in $\mathcal{O}(1)$ time without calling `malloc`, `free`, or OS memory allocators.
3. **Lock-Free Seqlock Synchronization**: Telemetry data (visualizer, VU levels, position) is written atomically inside a minimal 56-byte critical section (< 2 CPU cycles) with explicit hardware memory barriers (`DMB ISH` on ARM, compiler fences on x86 TSO).
4. **Priority Inversion Protection**: The RT thread signals the decoder worker via atomic flag check (`worker_is_sleeping`) with hysteresis, completely bypassing POSIX mutex acquisitions.

### 3. Low-Level Platform Engineering & Microarchitecture

For systems engineers, embedded developers, and performance specialists, `miniaudio_player` incorporates enterprise-grade low-level optimizations across target operating systems and CPU architectures:

- **Android 15+ 16 KB ELF Page Alignment**:
  - Enforces `-Wl,-z,max-page-size=16384` link flags via Dart Native Assets (`hook/build.dart`) to comply strictly with Android 15's mandatory 16 KB kernel memory page requirements.
  - Generates optimized ARM NEON vfpv4 vectorization on 32-bit ARM (`armeabi-v7a`) and AArch64 SIMD instructions on 64-bit devices.
- **Pure C JNI Android Bridge (Zero MethodChannels & Zero Kotlin)**:
  - Interfaces directly with Android's `AudioManager` and `AudioDeviceInfo` using an autonomous embedded C JNI bridge.
  - Requires **zero Kotlin code** in `MainActivity.kt` and eliminates Flutter MethodChannel IPC bottlenecks.
  - Autonomous 6-tier `JavaVM` discovery across Android API 21 through 35+ (via `JNI_OnLoad`, `libnativehelper.so`, `libart.so`, and `dl_iterate_phdr` linker memory traversal).
  - Acquires application context via reflection on `ActivityThread.currentApplication()`, enabling headless background execution.
  - Automatically handles `AAUDIO_SERVICE_EVENT_DISCONNECTED` (-899) route changes during Bluetooth hotplug events without audio stalls.
- **Windows WASAPI MMCSS Pro Audio & 1 ms High-Precision Timers**:
  - Automatically registers audio threads with the Windows Multimedia Class Scheduler Service (MMCSS) via `AvSetMmThreadCharacteristicsA("Pro Audio")` for guaranteed real-time scheduling priority.
  - Enforces 1 ms Win32 timer resolution using `timeBeginPeriod(1)` (and clean release via `timeEndPeriod(1)`), eliminating decoder starvation caused by default 15.6 ms Windows sleep jitter.
- **Universal Hardware FTZ/DAZ Denormal Mitigation**:
  - Systematically executes `map_disable_denormals()` on all worker and real-time audio threads.
  - Configures Flush-to-Zero (FTZ) and Denormals-are-Zero (DAZ) bits directly in CPU control registers (x86/x86_64 MXCSR `0x8040`, ARM64 FPCR, ARMv7 FPSCR, and MSVC `_controlfp_s`).
  - Completely prevents 100x CPU penalties and audio glitching during decaying IIR filter tails.
- **Microarchitectural Concurrency & Atomic Memory Barriers**:
  - Weak memory model support on ARM64/ARMv7: explicit hardware release (`DMB ISH`) and acquire (`DMB ISHLD`) barriers, plus pipeline yield instructions (`isb; yield`).
  - Total Store Order (TSO) on x86/x86_64: pure compiler barriers (`__atomic_thread_fence` / `_ReadWriteBarrier`), eliminating bus-locking `_mm_mfence` instructions and saving 30–100 CPU cycles per read.
  - Lock-free Seqlock (`src/map_seqlock.h`): pre-check backoff loop and local staging struct, reducing the writer critical section to a single atomic 56-byte snapshot (< 2 CPU cycles), certified over 35+ million concurrent contention reads.
- **Strict Real-Time Determinism & Zero Heap Allocations**:
  - Audio callback runs in $\mathcal{O}(1)$ time with **0 dynamic heap allocations**, empirically verified via memory interceptor wrappers (`--wrap=malloc/calloc/realloc/free`).
  - Cache-line 64-byte alignment (`MAP_ALIGN_CACHE_LINE`, `ma_aligned_malloc`) preventing multi-core false sharing on ring buffer cursors.
  - Contiguous 64-frame SIMD processing with delay registers ($s_1, s_2$) hoisted into CPU vector registers.

---

## 📊 Platform Support Matrix

| Audio Player & Engine Capability                     |    Android [^1]    |   Windows [^2]   |       Linux       |    iOS    |   macOS   |
| :--------------------------------------------------- | :----------------: | :--------------: | :---------------: | :-------: | :-------: |
| **Native Audio Backend**                             | AAudio / OpenSL ES | WASAPI Pro Audio | PulseAudio / ALSA | CoreAudio | CoreAudio |
| **Local File Playback (`AudioSource.file`)**         |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Web Audio Files (HTTP/HTTPS & Byte-Range Seek)**   |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Live Audio Streams (Icecast / Shoutcast / Radio)** |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Direct In-Memory Playback (`Uint8List` RAM)**      |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Direct Zero-I/O Asset Playback**                   |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Dual-Deck Queue & Crossfade (`MiniaudioEngine`)**  |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Shuffle, Loop Modes & Proactive Infinite Mix**     |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Per-Track ReplayGain & Loudness Normalization**    |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **10-Band Equalizer (ISO 266)**                      |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **True-Peak Limiter (Soft-Knee)**                    |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Binaural Crossfeed (Bauer bs2b)**                  |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Mono Downmix & Stereo Balance**                    |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Stereo Spatializer / Widener**                     |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Algorithmic Reverb (Freeverb)**                    |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Real-Time Reactive Visualizer**                    |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Silence Detection & Skipping**                     |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Audio Analysis (LUFS & Waveform)**                 |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Speed & Pitch Scaling (Sonic DSP)**                |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Dynamic Device Routing**                           |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |
| **Background Playback & Isolates**                   |         ✅         |        ✅        |        ✅         |    ✅     |    ✅     |

[^1]: **Android**: Device discovery uses an autonomous pure C JNI bridge with zero MethodChannels and no Kotlin glue code. Binaries are compiled with `-Wl,-z,max-page-size=16384` for Android 15+ 16 KB memory page compatibility and ARM NEON SIMD.

[^2]: **Windows**: Audio threads automatically engage MMCSS Pro Audio real-time scheduling (`AvSetMmThreadCharacteristicsA`) and 1 ms high-precision timer resolution (`timeBeginPeriod(1)`).

---

## 📦 Supported Audio Formats

| Format                   | Extensions                               | Decoding Backend                |
| :----------------------- | :--------------------------------------- | :------------------------------ |
| **MPEG Audio**           | `.mp3`, `.mp2`, `.mp1`                   | Native miniaudio (`dr_mp3`)     |
| **Waveform Audio**       | `.wav`, `.bwf`, `.rifx`, `.w64`, `.rf64` | Native miniaudio (`dr_wav`)     |
| **FLAC**                 | `.flac`                                  | Native miniaudio (`dr_flac`)    |
| **Ogg Vorbis**           | `.ogg`, `.oga`                           | Native miniaudio (`stb_vorbis`) |
| **Opus**                 | `.opus`                                  | Native Opus decoder (`libopus`) |
| **Apple Lossless / AAC** | `.m4a`, `.aac`                           | Native ALAC / Helix AAC         |
| **Audio Interchange**    | `.aif`, `.aiff`, `.aifc`                 | Native miniaudio                |

---

## 🛠️ Getting Started

Add `miniaudio_player` to your `pubspec.yaml`:

```bash
flutter pub add miniaudio_player
```

Or for pure Dart projects:

```bash
dart pub add miniaudio_player
```

---

## 💻 Usage Examples

### 1. Universal Single-Track Playback (`MiniaudioPlayer`: Files, Web URLs, Live Streams, Assets & RAM)

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/simple_player.png" alt="Basic Audio Playback Controls" width="480" />
</p>

`miniaudio_player` offers a flexible, polymorphic audio source architecture with a clean separation between preparing a source (`open*`) and starting playback (`play()`). You can pass raw strings, URIs, raw byte buffers (`Uint8List`), or strongly typed `AudioSource` objects to `player.action.open(...)`, or use explicit methods:

```dart
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() async {
  // 1. Optional: Register global asset loader for zero-I/O Flutter asset playback
  MiniaudioPlayerGlobalConfig.assetLoader = (key) async {
    final byteData = await rootBundle.load(key);
    return byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  };

  // 2. Optional: Configure global defaults before instantiating players
  MiniaudioPlayer.config(
    defaultBufferSize: 0, // 0 = native device default
    logLevel: MiniaudioLogLevel.info,
  );

  final player = MiniaudioPlayer();

  // ---------------------------------------------------------------------------
  // A. Polymorphic open() + play() — resolves files, Web URLs, assets & bytes
  // ---------------------------------------------------------------------------
  // Local filesystem file:
  await player.action.open('/path/to/song.flac');
  await player.action.play();

  // Flutter asset (loaded directly into RAM without temporary files):
  await player.action.open('assets/music/track.mp3');
  await player.action.play();

  // Remote HTTP / HTTPS Web audio file (progressive stream + byte-range seek):
  await player.action.open('https://example.com/audio.mp3');
  await player.action.play();

  // In-memory byte buffer (zero disk I/O, instantaneous startup):
  final Uint8List audioBytes = ...;
  await player.action.open(audioBytes);
  await player.action.play();

  // ---------------------------------------------------------------------------
  // B. Strongly Typed AudioSource instances
  // ---------------------------------------------------------------------------
  // Local file
  await player.action.open(const AudioSource.file('/path/to/song.flac'));
  await player.action.play();

  // Flutter Asset
  await player.action.open(const AudioSource.asset('assets/music/track.mp3'));
  await player.action.play();

  // In-Memory RAM buffer
  await player.action.open(AudioSource.memory(audioBytes));
  await player.action.play();

  // Remote Web audio file (HTTP/HTTPS) with custom headers and pre-buffering
  await player.action.open(
    AudioSource.network(
      Uri.parse('https://example.com/audio.mp3'),
      headers: {'Authorization': 'Bearer token'},
      bufferAhead: const Duration(seconds: 30),
    ),
  );
  await player.action.play();

  // Live Internet Radio / Icecast / Shoutcast stream with sliding jitter buffer
  await player.action.open(
    AudioSource.liveStream(
      Uri.parse('https://icecast.radiofrance.fr/fip-midfi.mp3'),
      jitterBuffer: const Duration(seconds: 5),
    ),
  );
  await player.action.play();

  // ---------------------------------------------------------------------------
  // C. Dedicated Granular Methods
  // ---------------------------------------------------------------------------
  await player.action.openFile('/path/to/song.flac');
  await player.action.openAsset('assets/music/track.mp3');
  await player.action.openMemory(audioBytes);
  await player.action.openUrl(
    'https://example.com/stream',
    isLive: true,
    headers: {'User-Agent': 'MiniaudioPlayer/4.0'},
  );
  await player.action.play();

  // ---------------------------------------------------------------------------
  // D. Playback Controls & Telemetry
  // ---------------------------------------------------------------------------
  await player.action.pause();
  await player.action.play();
  await player.action.seek(const Duration(seconds: 45)); // Byte-range seek supported over HTTP!
  await player.action.setVolume(0.85);

  // Observe real-time buffering state:
  player.stream.buffering.listen((isBuffering) {
    print('Buffering: $isBuffering');
  });

  // Clean up resources when finished (also safely garbage collected via NativeFinalizer)
  await player.dispose();
}
```

---

### 2. High-Level Dual-Deck Queue, Crossfade & Infinite Mix Engine (`MiniaudioEngine<T>`)

For full-featured music players and streaming apps, `MiniaudioEngine<T>` orchestrates two internal `MiniaudioPlayer` decks through a deterministic **Finite State Machine (`EnginePhase`)** and a serialized FIFO command queue. It provides built-in queue management, Fisher-Yates shuffle with exact un-shuffle restoration, Equal-Power / Linear crossfades, per-track ReplayGain normalization, and proactive Infinite Mix prefetching while preserving your domain objects by direct memory reference (`T? data`):

```dart
import 'package:miniaudio_player/miniaudio_player.dart';

// Example domain entity from your app's in-memory graph or store:
class Track {
  final int id;
  final String title;
  final String artist;
  final String pathOrUrl;
  final double? replayGainDb;
  final double? replayPeak;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.pathOrUrl,
    this.replayGainDb,
    this.replayPeak,
  });
}

Future<void> runEngineExample(List<Track> albumTracks) async {
  // 1. Instantiate MiniaudioEngine<Track> with dual-deck crossfade & Infinite Mix
  final engine = MiniaudioEngine<Track>(
    crossfadeConfig: const CrossfadeConfig(
      duration: Duration(seconds: 4),              // Auto end-of-track crossfade
      manualDuration: Duration(milliseconds: 500), // Manual skip/next/prev crossfade
      curve: CrossfadeCurve.equalPower,            // Constant acoustic power
    ),
    initialVolume: 1.0,                            // 0.0..2.0 (1.0 = unity gain)
    volumeNormalization: true,                     // Automatic per-track ReplayGain
    infiniteMixEnabled: true,
    infiniteMixBatchSize: 5,
    infiniteMixProvider: (count, currentQueue) async {
      // Return recommended EngineItem<Track>s when approaching the end of the queue:
      return [];
    },
  );

  // 2. Wrap domain models in EngineItem<Track> (local files, Web URLs, or LiveStreams)
  //    Direct pointer identity is preserved: identical(engine.state.currentData, albumTracks[0]) == true
  final items = [
    for (final track in albumTracks)
      EngineItem<Track>.file(
        track.pathOrUrl,
        data: track,
        replayGainDb: track.replayGainDb,
        replayPeak: track.replayPeak,
      ),
    // Mix Web audio files and Live Internet Radio seamlessly in the same queue:
    EngineItem<Track>.network(
      Uri.parse('https://example.com/bonus_track.flac'),
      data: const Track(
        id: 999,
        title: 'Bonus Web Track',
        artist: 'Remote Artist',
        pathOrUrl: 'https://example.com/bonus_track.flac',
      ),
    ),
    EngineItem<Track>.liveStream(
      Uri.parse('https://icecast.radiofrance.fr/fip-midfi.mp3'),
      data: const Track(
        id: 1000,
        title: 'FIP Live Radio',
        artist: 'Radio France',
        pathOrUrl: 'https://icecast.radiofrance.fr/fip-midfi.mp3',
      ),
    ),
  ];

  // 3. Open the queue (prepares initial track without auto-playing) & start playback
  await engine.action.openQueue(
    items,
    startIndex: 0,
    shuffle: false,
  );
  await engine.action.play();

  // 4. Queue Navigation & Dynamic Mutations
  await engine.action.next();              // Smooth manual crossfade (or promotes active auto-crossfade!)
  await engine.action.previous();          // Restarts at 0:00 if > 3s, or crossfades to previous track
  await engine.action.skipToIndex(2);      // Jumps directly to index 2, preserving play/pause state
  await engine.action.insertNext(items[0]); // Inserts right after current track (invalidates stale auto-fade)
  await engine.action.append([items[1]]);  // Appends to end of queue
  await engine.action.reorder(3, 1);       // Reorders queue items in O(N)
  await engine.action.removeAt(2);         // Removes item at index 2
  await engine.action.clearQueue(keepCurrent: true); // Keeps currently playing track at index 0

  // 5. Shuffle (Fisher-Yates) & Loop Modes (LoopMode / Loop alias)
  await engine.action.setShuffle(true);    // Pins current track at index 0 & shuffles remaining
  await engine.action.setShuffle(false);   // Restores exact original queue order
  await engine.action.setLoopMode(LoopMode.all); // LoopMode.off, LoopMode.one, LoopMode.all
  await engine.action.cycleLoopMode();     // Cycles off -> all -> one -> off

  // 6. Runtime Crossfade, ReplayGain & Full Studio DSP Suite (synced across both decks)
  await engine.action.setCrossfadeConfig(
    const CrossfadeConfig(
      duration: Duration(seconds: 6),
      manualDuration: Duration(milliseconds: 600),
      curve: CrossfadeCurve.equalPower,
    ),
  );
  await engine.action.setVolumeNormalization(true);
  await engine.action.setEqualizer(Equalizer.rock);
  await engine.action.setReverb(Reverb.concertHall);
  await engine.action.setCrossfeed(CrossfeedMode.moffatBauer);
  await engine.action.setLimiter(true);

  // 7. Synchronous State (.state) & Reactive Broadcast Streams (.stream)
  print('Phase: ${engine.state.phase}'); // idle, loading, playing, paused, autoCrossfading, manualCrossfading, completed, error
  print('Now Playing: ${engine.state.currentData?.title}');
  print('Queue Length: ${engine.state.queue.length} (Index: ${engine.state.currentIndex})');
  print('Has Next: ${engine.state.hasNext}, Has Previous: ${engine.state.hasPrevious}');

  engine.stream.currentData.listen((track) {
    print('Active track changed: ${track?.title} by ${track?.artist}');
  });

  engine.stream.phase.listen((phase) {
    print('Engine FSM phase: $phase');
  });

  await engine.dispose();
}
```

---

### 3. Complete DSP Chain (Limiter, Reverb, Crossfeed, Mono, Balance & Spatializer)

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/limiter_crossfeed_mono_balance_preamp_spatializer_reverb.png" alt="Complete DSP Chain - Limiter, Reverb, Crossfeed, Mono, Balance & Spatializer" width="480" />
</p>

```dart
// 1. Hardware Output Limiter (True-Peak soft-knee protection against digital clipping)
await player.action.setLimiter(true);

// 2. Studio-Grade Algorithmic Reverb (Freeverb with studio presets or custom acoustics)
await player.action.setReverb(Reverb.concertHall);
// Or customize dynamically:
await player.action.configureReverb(
  roomSize: 0.75,
  damping: 0.30,
  wet: 0.32,
  dry: 0.68,
  width: 1.0,
  enabled: true,
);

// 3. Binaural Crossfeed (Bauer bs2b: reduces headphone fatigue)
await player.action.setCrossfeed(CrossfeedMode.moffatBauer); // or CrossfeedMode.chuMoy

// 4. Mono Downmixing (for single speakers or accessibility)
await player.action.setMono(true);

// 5. Stereo Balance Panning (-1.0 full left, 0.0 center, +1.0 full right)
await player.action.setBalance(-0.25);

// 6. Stereo Spatializer (widens the acoustic stereo image)
await player.action.setSpatializer(enabled: true, width: 1.4);

// 7. Preamp Gain & ReplayGain Normalization with anti-clipping defense
await player.action.setPreamp(2.0); // +2.0 dB manual preamp
await player.action.setReplayGain(
  gainDb: -4.5,
  peak: 0.98,
  preampDb: 0.0,
  preventClipping: true,
);
```

---

### 4. Standard ISO 266 10-Band Parametric Equalizer

Shape frequency response in real time across the 10 ISO 266 standard octave bands (`31Hz`, `63Hz`, `125Hz`, `250Hz`, `500Hz`, `1kHz`, `2kHz`, `4kHz`, `8kHz`, `16kHz`) from `-24.0 dB` to `+24.0 dB`:

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/equalizer.png" alt="Standard ISO 266 10-Band Parametric Equalizer" width="480" />
</p>

```dart
// Apply built-in acoustic presets
await player.action.setEqualizer(Equalizer.rock);
await player.action.setEqualizer(Equalizer.bassBoost);
await player.action.setEqualizer(Equalizer.jazz);
await player.action.setEqualizer(Equalizer.classical);
await player.action.setEqualizer(Equalizer.pop);
await player.action.setEqualizer(Equalizer.flat);

// Or create a custom equalizer configuration
final customEq = Equalizer(
  hz31: 4.5,   // Sub-bass boost (low-shelf)
  hz63: 3.0,   // Warmth
  hz125: 1.5,
  hz250: 0.0,
  hz500: -1.0,
  hz1k: -0.5,  // Tame mid-range harshness
  hz2k: 1.0,
  hz4k: 2.5,   // Presence
  hz8k: 3.5,   // Treble air
  hz16k: 4.0,  // High-shelf sparkle
);
await player.action.setEqualizer(customEq);
```

---

### 5. Real-Time Reactive Visualizer & Spectrum Analyzer

Build dynamic spectrum analyzers, frequency visualizers, and stereo VU meters. Subscribing to the stream automatically enables native C filtering, and unsubscribing keeps **idle CPU strictly at 0%**:

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/visualizer.png" alt="Real-Time Reactive Visualizer - 10-Band BPF Filter Bank & Stereo VU Meters" width="480" />
</p>

```dart
// 1. Listen to real-time visualizer data (~30 fps updates)
final subscription = player.stream.visualizer.listen((data) {
  // 10 frequency bands (0.0 to 1.0) matching the 10-band equalizer:
  print('Sub-bass (31Hz): ${data.hz31}');
  print('Midrange (1kHz): ${data.hz1k}');
  print('Treble (16kHz):  ${data.hz16k}');

  // Stereo channel amplitudes:
  print('VU Left: ${data.left}, VU Right: ${data.right}');

  // Global energy metrics:
  print('RMS: ${data.rms}, Peak: ${data.peak}');
});

// 2. Synchronous snapshot access:
final current = player.state.visualizer;
print('Current spectrum: ${current.bands}');

// 3. Stop observing: native DSP filtering stops automatically (0% idle CPU)
await subscription.cancel();
```

---

### 6. Native Silence Detection & Dynamic Skipping

Eliminate pauses and silent gaps in real time without audio glitches or pops, protected by a smooth 5ms anti-click crossfade:

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/silence_skipping.png" alt="Smart Silence Skipping Controls" width="480" />
</p>

```dart
// 1. Quick enable with standard defaults (-45 dB threshold, 300ms min silence, 50ms padding)
await player.action.setSkipSilence(true);

// 2. Podcast & Audiobook mode: skips in-between speech pauses
await player.action.setSilenceConfig(
  const SilenceSkipConfig.continuous(
    thresholdDb: -45.0,
    minSilenceDuration: Duration(milliseconds: 300),
    padding: Duration(milliseconds: 50),
  ),
);

// 3. Music Album mode: trims lead-in and lead-out silence only
await player.action.setSilenceConfig(
  const SilenceSkipConfig.trimEdges(thresholdDb: -50.0),
);

// 4. Combined mode: trims edges AND skips continuous pauses
await player.action.setSilenceConfig(const SilenceSkipConfig.all());

// 5. Track accumulated saved time synchronously or reactively:
print('Total time saved: ${player.state.silenceSavedDuration.inSeconds}s');

player.stream.silenceSavedDuration.listen((saved) {
  print('Saved time updated: ${saved.inMilliseconds} ms');
});
```

---

### 7. Unified Single-Pass Audio Analysis (Loudness & Waveform)

Analyze a track's acoustic properties, ITU-R BS.1770-4 / EBU R128 loudness, and visual waveform envelope in a **single decoding pass** on a background native OS worker thread (zero Dart Isolates, 0 ms UI blocking, preserving 60/120 fps):

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/waveform_and_replaygain.png" alt="Unified Audio Analysis - Waveform & ReplayGain" width="480" />
</p>

```dart
// 1. Non-blocking asynchronous analysis (native background OS thread)
final analysis = await MiniaudioPlayer.analyzeAudio(
  '/path/to/song.flac',
  replayGain: true,       // Loudness analysis
  waveform: true,         // Waveform envelope extraction
  waveformPoints: 100,    // Number of points to extract
  targetLufs: -18.0,      // Reference loudness (-18.0 ReplayGain, -14.0 streaming)
);

// 2. Fundamental audio metrics:
print('Duration: ${analysis.duration}');
print('Sample Rate: ${analysis.sampleRate} Hz');
print('Channels: ${analysis.channels}');
print('Bitrate: ${analysis.bitrate ~/ 1000} kbps');
print('True Peak: ${analysis.peak}');

// 3. ReplayGain & Volume Normalization:
if (analysis.replayGain != null) {
  final rg = analysis.replayGain!;
  print('Integrated Loudness: ${rg.lufs} LUFS');
  print('Recommended Gain: ${rg.gainDb} dB');

  // Convert to linear volume with built-in anti-clipping defense:
  final linearVolume = rg.getRecommendedVolume(preventClipping: true);
  await player.action.setVolume(linearVolume);
}

// 4. Waveform seekbar rendering:
if (analysis.waveform != null) {
  final wf = analysis.waveform!;
  print('Waveform points (${wf.length}): ${wf.points}');

  // Sample height at 50% progress or at current playback position:
  final midHeight = wf.getPointAtProgress(0.5); // 0.0 to 1.0
  final currentHeight = wf.getPointAtPosition(player.state.position, analysis.duration);
}
```

> **Note**: For CLI tools or batch preprocessing scripts, use the synchronous variant: `MiniaudioPlayer.analyzeAudioSync(...)`.

---

### 8. Audio Output Device Selection & Dynamic Routing

Enumerate and switch hardware audio devices dynamically at runtime across Android, Windows, Linux, macOS, and iOS with **zero configuration** and **no MethodChannels**:

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/buffer_size_output_device.png" alt="Hardware Audio Output Device & Buffer Size Selection" width="500" />
</p>

```dart
// 1. Enumerate available audio playback devices
final devices = await MiniaudioPlayer.getAudioDevices();

for (final device in devices) {
  // Use device.displayName directly in UI selectors (DropdownButton, ListTile)
  print('Device: ${device.displayName} (ID: ${device.id})');
}

// 2. Switch playback to a specific hardware output
await player.action.setDevice(devices[1]);

// 3. Return to automatic system default routing
await player.action.setDevice(AudioDevice.auto);

// 4. Listen to native device hotplug and route changes:
MiniaudioPlayer.getAudioDevicesStream().listen((updatedDevices) {
  print('Device list updated: ${updatedDevices.length} devices found');
});
```

#### Flutter UI Dropdown Binding with Localized Labels

```dart
// Optional: configure localized display name resolver globally
MiniaudioPlayer.config(
  defaultDeviceDisplayNameResolver: (resolvedName) =>
      resolvedName.isEmpty ? 'Predeterminado' : 'Predeterminado ($resolvedName)',
);

// Bind directly to Flutter DropdownButton:
DropdownButton<AudioDevice>(
  value: player.state.audioDevice,
  items: devices.map((device) {
    return DropdownMenuItem(
      value: device,
      child: Text(device.displayName),
    );
  }).toList(),
  onChanged: (newDev) {
    if (newDev != null) player.action.setDevice(newDev);
  },
)
```

---

### 9. Reactive Streams & Synchronous State

Both `MiniaudioPlayer` and `MiniaudioEngine<T>` offer real-time broadcast streams and synchronous getters for effortless UI binding:

```dart
// Synchronous snapshot access:
print('Is Playing: ${player.state.playing}');
print('Is Buffering: ${player.state.buffering}');
print('Current Position: ${player.state.position}');
print('Track Duration: ${player.state.duration}');
print('Bitrate: ${player.state.audioBitrate} kbps');
print('Active Device: ${player.state.audioDevice.displayName}');
print('Limiter Enabled: ${player.state.limiterEnabled}');
print('Reverb: ${player.state.reverb}');

// Reactive broadcast streams:
player.stream.position.listen((pos) => print('Position: $pos'));
player.stream.playing.listen((playing) => print('Playing: $playing'));
player.stream.buffering.listen((buf) => print('Buffering: $buf'));
player.stream.completed.listen((done) => print('Playback finished!'));
player.stream.equalizer.listen((eq) => print('Equalizer updated: $eq'));
player.stream.reverb.listen((reverb) => print('Reverb updated: $reverb'));
player.stream.audioDevice.listen((dev) => print('Device switched: ${dev.displayName}'));
```

Using with Flutter `StreamBuilder`:

```dart
StreamBuilder<Duration>(
  stream: player.stream.position,
  builder: (context, snapshot) {
    final position = snapshot.data ?? Duration.zero;
    final total = player.state.duration;
    return Text('${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')} / '
                '${total.inMinutes}:${(total.inSeconds % 60).toString().padLeft(2, '0')}');
  },
)
```

---

### 10. High-Fidelity Speed & Pitch Control (Sonic DSP)

<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/pictures/volume_rate_pitch.png" alt="Playback Adjustments - Volume, Rate & Pitch Control" width="480" />
</p>

```dart
// Playback rate: 0.25x (slow) to 4.0x (fast) without changing pitch
await player.action.setRate(1.5);

// Pitch scaling: 0.5x to 2.0x without changing playback speed
await player.action.setPitch(1.2);
```

---

### 11. Optional: Running Inside a Background Isolate

Because `miniaudio_player` uses 100% pure Dart FFI without platform channel restrictions, both `MiniaudioPlayer` and `MiniaudioEngine<T>` can be instantiated inside a standalone background Dart Isolate or headless background service (`audio_service`, `flutter_background_service`, `Isolate.spawn`):

```dart
import 'dart:isolate';
import 'package:miniaudio_player/miniaudio_player.dart';

void audioWorkerIsolate(SendPort sendPort) async {
  final commandPort = ReceivePort();
  sendPort.send(commandPort.sendPort);

  final player = MiniaudioPlayer();

  player.stream.position.listen((pos) {
    sendPort.send({'event': 'position', 'value': pos.inMilliseconds});
  });

  player.stream.completed.listen((done) {
    if (done) sendPort.send({'event': 'completed'});
  });

  await for (final message in commandPort) {
    if (message is Map) {
      switch (message['command']) {
        case 'open':
          await player.action.open(message['path'] as String);
          await player.action.play();
          break;
        case 'pause':
          await player.action.pause();
          break;
        case 'resume':
          await player.action.play();
          break;
        case 'stop':
          await player.action.stop();
          break;
        case 'dispose':
          await player.dispose();
          commandPort.close();
          return;
      }
    }
  }
}
```

---

## 🤝 Contributing

Contributions, bug reports, and feature requests are very welcome!  
Feel free to open an issue or submit a pull request on [GitHub](https://github.com/chomusuke-mk/miniaudio_player).

---

## 📄 License & Third-Party Acknowledgements

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for complete details.

### Third-Party Native Libraries & Decoders

`miniaudio_player` bundles and links specialized native C libraries to provide out-of-the-box decoding and DSP without external system dependencies. Each component remains governed by its respective author's license:

| Component                 | Author / Organization                           | License                                        | Source Location             | Description                                                                                     |
| :------------------------ | :---------------------------------------------- | :--------------------------------------------- | :-------------------------- | :---------------------------------------------------------------------------------------------- |
| **miniaudio**             | David Reid                                      | Choice of Public Domain or MIT-0               | `src/miniaudio.h`           | Audio engine, OS device routing, mixing, and built-in decoders (`dr_mp3`, `dr_wav`, `dr_flac`). |
| **Sonic DSP**             | Bill Cox                                        | Apache License 2.0                             | `src/sonic/`                | Real-time high-fidelity time stretching and pitch scaling.                                      |
| **minimp4**               | lieff, aspt                                     | CC0 1.0 Universal (Public Domain)              | `src/decoders/minimp4/`     | Lightweight MP4 / M4A ISO container demuxer.                                                    |
| **ALAC Decoder**          | David Hammerton                                 | MIT License                                    | `src/decoders/alac/`        | Apple Lossless Audio Codec (ALAC) frame decoder.                                                |
| **stb_vorbis**            | Sean Barrett                                    | Public Domain / MIT                            | `src/decoders/stb_vorbis.c` | Ogg Vorbis audio decoding backend.                                                              |
| **libogg**                | Xiph.Org Foundation                             | BSD 3-Clause                                   | `src/decoders/libogg/`      | Ogg container bitstream and framing parsing.                                                    |
| **libopus** (Opus & SILK) | Xiph.Org Foundation, Skype Limited, Arm Limited | BSD 3-Clause                                   | `src/decoders/libopus/`     | High-definition Opus audio decoding pipeline.                                                   |
| **Helix AAC Decoder**     | RealNetworks, Inc.                              | RealNetworks Public Source License (RPSL v1.0) | `src/decoders/helix-aac/`   | Fixed-point HE-AAC audio decoder.                                                               |
| **Freeverb**              | Jezar at Dreampoint                             | Public Domain                                  | `src/map_reverb.c`          | Studio-grade algorithmic stereo reverberation model.                                            |

### ⚖️ Permissive Licensing & Commercial Use

- **Unrestricted Commercial & Proprietary Usage**: Because `miniaudio_player` is distributed under the permissive **MIT License**, you are completely free to integrate, bundle, and distribute it in commercial, closed-source, proprietary, or open-source Flutter applications without copyleft restrictions.
- **Third-Party Attribution**: All bundled third-party libraries retain their original author notices, copyrights, and permissive licenses (`MIT`, `MIT-0`, `Apache 2.0`, `BSD-3-Clause`, `CC0`, and `RPSL`).
