# Architecture & Technical Design Specification

> **Package**: `miniaudio_player` (v4.0.0)  
> **Status**: Production-Ready / Enterprise Grade  
> **Core Engine**: [miniaudio](https://miniaud.io/) (C99), [Sonic](https://github.com/waywardgeek/sonic) (DSP), [Dart Native Assets](https://dart.dev/interop/c-interop) (Pure FFI), [WebAssembly / AudioWorklet](https://developer.mozilla.org/en-US/docs/Web/API/AudioWorklet)  
> **Design Axioms**: Real-Time Audio Determinism ($\mathcal{O}(1)$), Zero Allocations in Real-Time Paths, Universal Tripartite Buffering, Platform Polymorphism, Lock-Free Concurrency, and Studio-Grade Acoustic Transparency.

---

## Table of Contents

- [Architecture \& Technical Design Specification](#architecture--technical-design-specification)
  - [Table of Contents](#table-of-contents)
  - [1. Executive Summary \& Core Architectural Principles](#1-executive-summary--core-architectural-principles)
  - [2. High-Level System Topology \& Domain Architecture](#2-high-level-system-topology--domain-architecture)
  - [3. Platform Abstraction Layer: Native FFI vs. WebAssembly AudioWorklet](#3-platform-abstraction-layer-native-ffi-vs-webassembly-audioworklet)
    - [3.1 Platform Abstraction Interface (`PlayerBackend` \& `PlatformService`)](#31-platform-abstraction-interface-playerbackend--platformservice)
    - [3.2 Native Platform Architecture (`NativePlayerBackend` \& Dart Native Assets)](#32-native-platform-architecture-nativeplayerbackend--dart-native-assets)
    - [3.3 Web Platform Architecture (`WebPlayerBackend`, Web Workers \& AudioWorklet)](#33-web-platform-architecture-webplayerbackend-web-workers--audioworklet)
  - [4. The Tripartite Facade Architecture (`.action`, `.state`, `.stream`)](#4-the-tripartite-facade-architecture-action-state-stream)
  - [5. Unified Ingest, AudioByteProviders \& Capability Promotion](#5-unified-ingest-audiobyteproviders--capability-promotion)
    - [5.1 The `AudioByteProvider` Hierarchy](#51-the-audiobyteprovider-hierarchy)
    - [5.2 The 5-Level Capability Promotion Pipeline](#52-the-5-level-capability-promotion-pipeline)
    - [5.3 Unified Audio Loader (`UnifiedAudioLoader`) \& Reactive Backpressure](#53-unified-audio-loader-unifiedaudioloader--reactive-backpressure)
    - [5.4 Container Boundary Probing \& Tail Probing (`probeTail`)](#54-container-boundary-probing--tail-probing-probetail)
  - [6. Native Tripartite Buffer Architecture (`map_buffer_t`)](#6-native-tripartite-buffer-architecture-map_buffer_t)
    - [6.1 Memory Layout: Pinned Head, Pure Audio Ring \& Tail Buffer](#61-memory-layout-pinned-head-pure-audio-ring--tail-buffer)
    - [6.2 Container Boundary Locking \& Header Synthesis](#62-container-boundary-locking--header-synthesis)
    - [6.3 Dynamic Metadata Synthesis (`.metaBytes`) \& Versioning](#63-dynamic-metadata-synthesis-metabytes--versioning)
    - [6.4 Real-Time Silence Synthesis on Starvation](#64-real-time-silence-synthesis-on-starvation)
  - [7. Comprehensive Finite State Machines (FSM) \& Lifecycle Synchronization](#7-comprehensive-finite-state-machines-fsm--lifecycle-synchronization)
    - [7.1 Dart Opening State Gate \& Generational Invalidation](#71-dart-opening-state-gate--generational-invalidation)
    - [7.2 High-Level Engine Phase State Machine (`EnginePhase`)](#72-high-level-engine-phase-state-machine-enginephase)
    - [7.3 Unified Loader State Machine (`UnifiedLoaderState`)](#73-unified-loader-state-machine-unifiedloaderstate)
    - [7.4 Native High-Level Buffer State Machine (`map_buffer_state_t`)](#74-native-high-level-buffer-state-machine-map_buffer_state_t)
    - [7.5 Native Data Source State Machine (`map_source_state_t`)](#75-native-data-source-state-machine-map_source_state_t)
    - [7.6 Native Silence Detection State Machine (`map_silence_state_t`)](#76-native-silence-detection-state-machine-map_silence_state_t)
  - [8. High-Level Dual-Deck Queue \& Crossfade Engine (`MiniaudioEngine<T>`)](#8-high-level-dual-deck-queue--crossfade-engine-miniaudioenginet)
    - [8.1 Dual-Deck Orchestration \& Single Ownership Invariant](#81-dual-deck-orchestration--single-ownership-invariant)
    - [8.2 Queue Lifecycle, Fisher-Yates Shuffle \& Exact Un-shuffle](#82-queue-lifecycle-fisher-yates-shuffle--exact-un-shuffle)
    - [8.3 Mathematical Crossfade Curves: Equal-Power vs. Linear](#83-mathematical-crossfade-curves-equal-power-vs-linear)
    - [8.4 Infinite Mix Proactive Prefetching Pipeline](#84-infinite-mix-proactive-prefetching-pipeline)
  - [9. Real-Time Audio DSP Processing Pipeline \& Effects Engine](#9-real-time-audio-dsp-processing-pipeline--effects-engine)
    - [9.1 The Master DSP Node Signal Chain](#91-the-master-dsp-node-signal-chain)
    - [9.2 ISO 266 10-Band Parametric Equalizer (DF2T Biquads)](#92-iso-266-10-band-parametric-equalizer-df2t-biquads)
    - [9.3 Studio-Grade Algorithmic Reverb (Freeverb Model)](#93-studio-grade-algorithmic-reverb-freeverb-model)
    - [9.4 Binaural Crossfeed (bs2b) \& Stereo Spatializer](#94-binaural-crossfeed-bs2b--stereo-spatializer)
    - [9.5 True-Peak Soft-Knee Brickwall Limiter](#95-true-peak-soft-knee-brickwall-limiter)
    - [9.6 Dynamic Silence Trimming \& Skipping](#96-dynamic-silence-trimming--skipping)
    - [9.7 Pitch \& Tempo Scaling (Sonic DSP)](#97-pitch--tempo-scaling-sonic-dsp)
  - [10. Threading Model, Lock-Free Concurrency \& Real-Time Safety](#10-threading-model-lock-free-concurrency--real-time-safety)
    - [10.1 Three Decoupled Execution Domains](#101-three-decoupled-execution-domains)
    - [10.2 Lock-Free SPSC PCM Ring Buffer (`ma_pcm_rb`)](#102-lock-free-spsc-pcm-ring-buffer-ma_pcm_rb)
    - [10.3 Cache-Line Aligned Atomic Sequence Lock (`map_seqlock_t`)](#103-cache-line-aligned-atomic-sequence-lock-map_seqlock_t)
    - [10.4 Priority Inversion Avoidance \& Mutex Trylocks](#104-priority-inversion-avoidance--mutex-trylocks)
  - [11. Native Reactive Event Dispatcher \& Telemetry Pipeline](#11-native-reactive-event-dispatcher--telemetry-pipeline)
    - [11.1 Double-Buffering \& Value Deduplication](#111-double-buffering--value-deduplication)
    - [11.2 Atomic 64-Bit Dirty Bitmask \& Throttled Telemetry](#112-atomic-64-bit-dirty-bitmask--throttled-telemetry)
    - [11.3 Dedicated Background Dispatcher Thread \& Native Event Ring](#113-dedicated-background-dispatcher-thread--native-event-ring)
  - [12. Offline Single-Pass Audio Analysis](#12-offline-single-pass-audio-analysis)
    - [12.1 ITU-R BS.1770-4 / EBU R128 Integrated Loudness (LUFS)](#121-itu-r-bs1770-4--ebu-r128-integrated-loudness-lufs)
    - [12.2 True-Peak Detection \& ReplayGain Calculation](#122-true-peak-detection--replaygain-calculation)
    - [12.3 Normalized Waveform Extraction](#123-normalized-waveform-extraction)
  - [13. Hardware Backends \& Cross-Platform Driver Optimizations](#13-hardware-backends--cross-platform-driver-optimizations)
    - [13.1 Linux: PulseAudio \& ALSA](#131-linux-pulseaudio--alsa)
    - [13.2 Android: AAudio, OpenSL ES \& 16 KB Memory Page Support](#132-android-aaudio-opensl-es--16-kb-memory-page-support)
    - [13.3 Windows: WASAPI Exclusive \& MMCSS 1 ms Scheduling](#133-windows-wasapi-exclusive--mmcss-1-ms-scheduling)
    - [13.4 Apple macOS / iOS: CoreAudio AudioUnit Graph](#134-apple-macos--ios-coreaudio-audiounit-graph)
    - [13.5 Universal Hardware Denormal Purging (FTZ \& DAZ)](#135-universal-hardware-denormal-purging-ftz--daz)
  - [14. Verification, Quality Assurance \& Acoustic Certification](#14-verification-quality-assurance--acoustic-certification)
  - [15. Repository Layout \& Code Navigation Map](#15-repository-layout--code-navigation-map)

---

## 1. Executive Summary & Core Architectural Principles

`miniaudio_player` is an ultra-low-resource, deterministic, zero-allocation cross-platform audio player and Digital Signal Processing (DSP) engine for Flutter, Dart, and Web. It solves the structural deficiencies historically plaguing mobile and desktop audio plugins—such as UI thread audio glitching, platform channel serialization latency, memory copying bloat, uncontrolled priority inversion, and buffer underrun panics—by pairing the `miniaudio` C99 library with pure Dart FFI Native Assets and WebAssembly AudioWorklet pipelines.

The v4.0.0 architecture adheres to six core axioms:

1. **Strict Real-Time Determinism ($\mathcal{O}(1)$)**: The native OS audio rendering callback and Web AudioWorklet processor operate in bounded $\mathcal{O}(1)$ time. They never call dynamic heap memory allocators (`malloc`, `free`, `realloc`, `new`), never block on unbounded mutexes, and never perform disk or network I/O.
2. **100% Pure FFI on Native & Direct AudioWorklet on Web**: On Android, iOS, macOS, Windows, and Linux, commands and telemetry dispatch directly through native pointers with sub-microsecond latency ($< 1\ \mu\text{s}$), completely bypassing Flutter message-passing platform channels (`MethodChannel`). On Web, an asynchronous Web Worker processes WebAssembly execution, piping zero-copy PCM frames to an `AudioWorkletNode`.
3. **Decoupled Tripartite Buffer & Universal Byte Providers**: Audio ingestion is fully separated from consumption. An abstract `AudioByteProvider` pipeline delivers raw stream data into a tripartite native memory buffer (`map_buffer_t`) composed of a pinned header, a circular sliding audio body, and a trailing metadata tail. The underlying decoders consume sequential byte streams without knowing whether the source is a POSIX file, an Android Scoped Storage file descriptor, RAM, or a chunked HTTP live stream.
4. **Platform Polymorphism**: The Dart API interacts with an abstract `PlayerBackend` and `PlatformService` interface. The implementation switches transparently between native FFI (`NativePlayerBackend`) and browser WebAssembly (`WebPlayerBackend`) without changing the application-facing API.
5. **Deterministic State Machines & Concurrency Gates**: Opaque FIFO command queues and race conditions are eliminated through explicit Finite State Machines (`EnginePhase`, `UnifiedLoaderState`, `map_buffer_state_t`, `map_source_state_t`, `map_silence_state_t`) and an asynchronous Opening Gate with generational invalidation counters (`_openGeneration`).
6. **Studio-Grade Electroacoustic Transparency**: Signal paths are verified to preserve maximum acoustic fidelity: $> 140\text{ dB}$ Signal-to-Noise Ratio (SNR), $0.00\text{ dB}$ analytical error against standard Robert Bristow-Johnson (RBJ) filter equations, and $0.00000\%$ Total Harmonic Distortion (THD) across the linear range ($|x| \le 0.95$ FS).

---

## 2. High-Level System Topology & Domain Architecture

The engine is partitioned into five distinct, decoupled architectural domains:

```mermaid
flowchart TB
    subgraph UI_Domain ["Domain 1: Flutter UI & Application Layer"]
        Widgets["Flutter Widgets / Business Logic"]
        StreamSub["StreamBuilder / Reactive Subscriptions"]
    end

    subgraph Ingest_Domain ["Domain 2: Unified Ingest & Byte Provider Layer (lib/src/loader/)"]
        AudioSourceAPI["AudioSource.uri(...) Polymorphic Factory"]
        UriPromotion["UriCapabilityResolver (5-Level Promotion)"]
        ByteProviders["AudioByteProviders (File, Memory, Asset, Network, Fd)"]
        UnifiedLoader["UnifiedAudioLoader (Backpressure & FSM)"]
    end

    subgraph Platform_Domain ["Domain 3: Platform Abstraction Layer (lib/src/platform/)"]
        BackendInterface["PlayerBackend & PlatformService"]
        NativeBackend["NativePlayerBackend (Dart FFI & NativeCallable)"]
        WebBackend["WebPlayerBackend (Web Worker + AudioWorklet)"]
    end

    subgraph Engine_Domain ["Domain 4: Native C Engine Core (src/)"]
        PlayerCoordinator["miniaudio_player.c (Master Coordinator)"]
        TripartiteBuffer["map_buffer.c (Pinned Head / Ring Body / Tail)"]
        FormatSniffers["map_sniffer.c (ID3v2, Xing, Ogg, MP4 Sniffers)"]
        DecoderWorker["Background Decoder Thread (ma_decoder + Sonic DSP)"]
        SPSC_Ring["Lock-Free SPSC PCM Ring Buffer (ma_pcm_rb)"]
        EventDispatcher["map_event_dispatcher.c (Double Buffer & Dirty Mask)"]
        MasterDSP["map_dsp.c (EQ, Reverb, Crossfeed, Limiter, Visualizer)"]
        Seqlock["map_seqlock.h (Cache-Line Aligned Atomic Lock)"]
    end

    subgraph Hardware_Domain ["Domain 5: OS Audio Drivers & Hardware DMA"]
        LinuxAudio["Linux: PulseAudio / ALSA"]
        AndroidAudio["Android: AAudio / OpenSL ES"]
        WindowsAudio["Windows: WASAPI (MMCSS 1ms)"]
        AppleAudio["macOS / iOS: CoreAudio AudioUnit"]
        WebAudioDAC["Web: Web Audio API AudioContext Destination"]
        PhysicalDAC["Hardware Audio DAC / DMA"]
    end

    %% Wiring
    Widgets -->|"Commands (play, seek, setEq)"| BackendInterface
    Widgets <---|"Broadcast Telemetry (position, state)"| StreamSub
    StreamSub <---|Reactive Streams| Platform_Domain

    AudioSourceAPI --> UriPromotion --> ByteProviders --> UnifiedLoader
    UnifiedLoader -->|"Progressive Ingest (openStreamEx, streamFeed)"| BackendInterface

    BackendInterface --> NativeBackend
    BackendInterface --> WebBackend

    NativeBackend -->|"Direct Pure FFI Calls (< 1 µs)"| PlayerCoordinator
    NativeBackend <---|FFI NativeCallable.listener Events| EventDispatcher

    WebBackend -->|"PostMessage Transfers"| PlayerCoordinator
    WebBackend -->|"AudioWorklet PCM Render"| WebAudioDAC

    PlayerCoordinator --> TripartiteBuffer
    FormatSniffers --> TripartiteBuffer
    TripartiteBuffer -->|"Zero-Copy Chunk Fetch"| DecoderWorker
    DecoderWorker -->|"Lock-Free Commit"| SPSC_Ring
    SPSC_Ring -->|"O(1) Pop"| MasterDSP

    MasterDSP -->|"Telemetry Seqlock Store"| Seqlock
    MasterDSP -->|"Post Events"| EventDispatcher
    Seqlock -.->|"Lock-Free Probe"| PlayerCoordinator

    MasterDSP --> LinuxAudio & AndroidAudio & WindowsAudio & AppleAudio --> PhysicalDAC
    WebAudioDAC --> PhysicalDAC
```

---

## 3. Platform Abstraction Layer: Native FFI vs. WebAssembly AudioWorklet

To guarantee first-class operation across mobile, desktop, and web environments, `miniaudio_player` separates platform-specific execution details behind a polymorphic backend bridge.

### 3.1 Platform Abstraction Interface (`PlayerBackend` & `PlatformService`)

The [`PlayerBackend`](../lib/src/platform/platform_backend.dart) abstract class defines the complete control surface required by the Dart facade:

```dart
abstract class PlayerBackend {
  dynamic get handle;
  int get sampleRate;
  int get channels;
  int get pinnedHeadSize;
  Uint8List? getMetaBytes();

  void setListener(PlayerBackendListener listener);
  void init({
    required int sampleRate,
    required int channels,
    required int periodSize,
    String? playbackDeviceId,
  });

  // Unified Stream Lifecycle
  Future<void> beginOpen();
  Future<int> openStreamEx({
    required Uint8List initialBytes,
    Uint8List? tailBytes,
    required int totalSize,
    required bool isLive,
    required int bufferCapacityBytes,
    int encodingFormat = 0,
  });
  int streamFeed(Uint8List chunk);
  int streamFlush(int newStreamOffset);
  int streamSeek(int positionMs, int newStreamOffset);
  int streamGetSeekByte(int positionMs);
  int getAudioDataOffset();
  int streamEnd();
  void notifyOpenError(int errorCode);
  BackendStreamStatus? getStreamStatus();

  // Transport & DSP Controls
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  void setVolume(double volume);
  void setRate(double rate);
  void setPitch(double pitch);
  void setPan(double pan);
  void setBufferSize(int frames);
  void setEqualizer(Equalizer params);
  void setReverb({ ... });
  void setCrossfeed(CrossfeedMode mode);
  void setLimiterEnabled(bool enabled);
  void setSilenceSkip(SilenceSkipConfig config);
  void setVisualizerEnabled(bool enabled);
  Future<void> setDevice(String deviceId);
  Future<void> dispose();
}
```

The sibling service, [`PlatformService`](../lib/src/platform/platform_backend.dart), provides synchronous and asynchronous audio device enumeration, single-pass audio analysis, and logging configuration.

### 3.2 Native Platform Architecture (`NativePlayerBackend` & Dart Native Assets)

On desktop and mobile operating systems, the native backend interacts directly with the compiled C engine:

- **Compilation (`hook/build.dart`)**: Handled by Dart Native Assets via `package:native_toolchain_c`. It compiles `src/miniaudio_player.c`, `src/map_*.c`, `src/sonic/sonic.c`, and bundled decoders into a dynamic library (`libminiaudio_player.so`, `.dylib`, or `.dll`) with aggressive compiler optimizations (`-O3`, `-fomit-frame-pointer`, `-ffp-contract=fast`).
- **Direct FFI Binding**: Generated by `ffigen`. Calls bypass the Flutter message loop, invoking C functions synchronously in under a microsecond.
- **Resource Protection (`NativeFinalizer`)**: A `NativeFinalizer` wraps the native pointer `miniaudio_player_destroy`. If a Dart `MiniaudioPlayer` or `NativePlayerBackend` object is garbage collected without an explicit `dispose()`, the finalizer guarantees that native threads, decoders, and buffers are uninitialized and freed without leaking native memory.
- **Asynchronous Event Pipe (`NativeCallable.listener`)**: Native events are dispatched from C background threads to Dart using `NativeCallable<native.miniaudio_player_event_cbFunction>.listener`. This invokes callbacks directly on the Dart isolate's event loop without blocking the native C threads.

### 3.3 Web Platform Architecture (`WebPlayerBackend`, Web Workers & AudioWorklet)

Web browsers present two fundamental challenges for low-level audio: JavaScript's single-threaded event loop and modern autoplay restrictions. `miniaudio_player` overcomes these using a tri-thread architecture:

```mermaid
sequenceDiagram
    autonumber
    participant UI as Dart Main Thread (UI)
    participant Worker as Engine Web Worker (WASM)
    participant Worklet as AudioWorklet Processor (Audio Thread)
    participant DAC as Web Audio Hardware Destination

    Note over UI,Worklet: Initialization & User Gesture Handshake
    UI->>Worklet: AudioContext.audioWorklet.addModule(blobUrl)
    UI->>Worker: new Worker(kEngineWorkerJs)
    UI->>Worker: postMessage({ type: "init", wasmUrl, sampleRate, ... })
    Worker->>Worker: WebAssembly.instantiate(miniaudio_player.wasm)
    UI->>Worklet: new AudioWorkletNode(ctx, "miniaudio-worklet-processor")
    UI->>Worker: postMessage({ type: "connectWorklet" }, [MessageChannel.port1])
    UI->>Worklet: workletNode.port.postMessage("connect", [MessageChannel.port2])
    Worker-->>UI: postMessage({ type: "initialized" })

    Note over UI,Worker: Progressive Stream Loading
    UI->>Worker: postMessage({ type: "openStreamEx", bytes: headBytes, ... })
    Worker->>Worker: map_wasm_open_stream_ex() -> Init Tripartite Buffer

    Note over Worker,DAC: Real-Time Audio Rendering & Buffer Recycling
    loop Audio Frame Pumping (2048 frames quantum)
        Worker->>Worker: map_wasm_render_pcm_frames() (SIMD Deinterleave)
        Worker->>Worklet: directPort.postMessage({ type: "chunk", buffer, frameCount }, [buffer])
        Worklet->>DAC: output[0].set(left), output[1].set(right)
        Worklet->>Worker: directPort.postMessage({ type: "recycle", buffer }, [buffer])
    end

    Note over Worker,UI: Telemetry Pipeline (~30 fps)
    loop Telemetry Polling (33 ms)
        Worker->>Worker: map_wasm_poll_telemetry()
        Worker-->>UI: postMessage({ type: "telemetry", position, visualizer, ... })
        UI->>UI: Dispatch to StreamControllers
    end
```

- **Dart Main Thread**: Manages the singleton reference-counted `_SharedWebAudioContext`, user gesture resumption (`ensureResumed()`), high-level HTTP ingestion, and reactive Flutter stream updates.
- **Dedicated Web Worker (`kEngineWorkerJs`)**: Runs the compiled WebAssembly binary (`assets/miniaudio_player.wasm`). It owns the native player instance, decodes audio containers, runs the full DSP effects pipeline, and produces interleaved 32-bit floating-point PCM audio frames.
- **Browser AudioWorklet (`MiniaudioWorkletProcessor`)**: Executes on the high-priority, real-time browser audio rendering thread. It maintains a FIFO chunk queue and copies samples into the hardware output buffers (`Float32Array`).
- **Zero-Copy Transferable Buffer Recycling**: Audio buffers are passed between the Web Worker and AudioWorklet via HTML5 Transferable Objects (`postMessage(data, [buffer])`). Once the AudioWorklet finishes rendering a chunk, it transfers the raw `ArrayBuffer` back to the Worker via a recycle message, avoiding garbage collection pauses.

---

## 4. The Tripartite Facade Architecture (`.action`, `.state`, `.stream`)

Both the single-track [`MiniaudioPlayer`](../lib/src/api/miniaudio_player.dart) and the dual-deck [`MiniaudioEngine<T>`](../lib/src/api/miniaudio_engine.dart) adopt a strict Tripartite Facade pattern, separating commands, synchronous state snapshots, and reactive streams:

```text
                           ┌──────────────────────────┐
                           │ MiniaudioPlayer / Engine │
                           └─────────────┬────────────┘
         ┌───────────────────────────────┼───────────────────────────────┐
         │                               │                               │
         ▼                               ▼                               ▼
 ┌───────────────┐               ┌───────────────┐               ┌───────────────┐
 │    .action    │               │    .state     │               │    .stream    │
 ├───────────────┤               ├───────────────┤               ├───────────────┤
 │ Imperative    │               │ Synchronous   │               │ Reactive      │
 │ Asynchronous  │               │ Instant       │               │ Broadcast     │
 │ Transport     │               │ Telemetry     │               │ Stream        │
 │ Commands      │               │ Snapshot      │               │ Controllers   │
 └───────────────┘               └───────────────┘               └───────────────┘
```

| Facade Domain | Component Type                                                                                            | Execution Timing               | Primary Responsibilities                                                                                                                                                                                   |
| :------------ | :-------------------------------------------------------------------------------------------------------- | :----------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`.action`** | [`PlayerAction`](../lib/src/api/player_action.dart) / [`EngineAction`](../lib/src/api/engine_action.dart) | Asynchronous (`Future<T>`)     | Transports commands (`open`, `play`, `pause`, `seek`, `stop`), DSP modifiers (`setEqualizer`, `setReverb`, `setVolume`), and queue transitions (`next`, `previous`, `shuffle`). Enforces the Opening Gate. |
| **`.state`**  | [`PlayerState`](../lib/src/api/player_state.dart) / [`EngineState`](../lib/src/api/engine_state.dart)     | Synchronous ($\mathcal{O}(1)$) | Immediate, zero-cost access to playback metrics: `position`, `duration`, `playbackState`, `volume`, `rate`, `pitch`, `equalizer`, `reverb`, `bufferedRange`, `visualizer`, and `currentItem`.              |
| **`.stream`** | [`PlayerStream`](../lib/src/api/player_stream.dart) / [`EngineStream`](../lib/src/api/engine_stream.dart) | Reactive (`Stream<T>`)         | Fine-grained broadcast streams for UI widgets (`StreamBuilder`). Delivers granular updates only when specific properties change.                                                                           |

---

## 5. Unified Ingest, AudioByteProviders & Capability Promotion

The v4.0.0 architecture removes legacy network-specific downloaders in favor of a universal data ingestion framework centered on [`AudioByteProvider`](../lib/src/loader/audio_byte_provider.dart) and [`UnifiedAudioLoader`](../lib/src/loader/unified_audio_loader.dart).

### 5.1 The `AudioByteProvider` Hierarchy

All audio sources—regardless of origin—are abstracted behind `AudioByteProvider`:

```mermaid
classDiagram
    class AudioByteProvider {
        <<abstract>>
        +String sourceId
        +Uri? uri
        +bool isLiveStream
        +bool isNetwork
        +open(offset, length) Future~AudioByteStreamResponse~
        +probeTail(tailOffset, length) Future~Uint8List?~
        +abortActiveStream() Future~void~
        +close() Future~void~
    }

    class MemoryByteProvider {
        -Uint8List _bytes
        +open(offset, length)
        +probeTail(tailOffset, length)
    }

    class FileByteProvider {
        +String filePath
        +open(offset, length)
        +probeTail(tailOffset, length)
    }

    class AssetByteProvider {
        +String assetKey
        -MemoryByteProvider? _cachedProvider
        +open(offset, length)
    }

    class NetworkByteProvider {
        +Uri uri
        +Map headers
        +int maxRetries
        +open(offset, length)
        +probeTail(tailOffset, length)
    }

    class LiveStreamByteProvider {
        +open(offset, length)
    }

    class FdByteProvider {
        +int fd
        +bool ownFd
        +open(offset, length)
        +probeTail(tailOffset, length)
    }

    class ResolvingByteProvider {
        +Uri uri
        +resolveProvider() Future~AudioByteProvider~
    }

    AudioByteProvider <|-- MemoryByteProvider
    AudioByteProvider <|-- FileByteProvider
    AudioByteProvider <|-- AssetByteProvider
    AudioByteProvider <|-- NetworkByteProvider
    NetworkByteProvider <|-- LiveStreamByteProvider
    AudioByteProvider <|-- FdByteProvider
    AudioByteProvider <|-- ResolvingByteProvider
```

- **`MemoryByteProvider`**: Wraps an in-memory `Uint8List`. Slices are created with zero-copy `Uint8List.sublistView()`.
- **`FileByteProvider`**: Uses platform-native asynchronous file streams (`openRead()`), automatically normalizing POSIX, Windows drive, and UNC paths.
- **`AssetByteProvider`**: Bridges Flutter asset bundles (`rootBundle`) directly into memory via `MiniaudioPlayerGlobalConfig.assetLoader`.
- **`NetworkByteProvider`**: Progressive HTTP/HTTPS byte-range client. Issues chunked requests (`Range: bytes=start-end`), decodes ICY shoutcast metadata frames on the fly, and applies exponential backoff for transient HTTP errors (429, 502, 503, 504).
- **`LiveStreamByteProvider`**: Subclass of `NetworkByteProvider` configured for unbounded streams. Marks stream length as unknown (`-1`) and activates sliding-window jitter buffering.
- **`FdByteProvider`**: Directly streams an open OS file descriptor (`int fd`) using POSIX `pread()` / Windows random access, bypassing file copy overhead under Android Scoped Storage.

### 5.2 The 5-Level Capability Promotion Pipeline

The [`UriCapabilityResolver`](../lib/src/loader/audio_byte_provider.dart) normalizes arbitrary inputs (`String`, `Uri`, `File`, `Uint8List`) into an optimized `AudioSource` through a 5-level promotion hierarchy:

```mermaid
flowchart TD
    Input["Input: String, Uri, File, or Uint8List"] --> CheckTraversal{"Check Path Traversal (../, null bytes)"}
    CheckTraversal -- "Detected" --> Reject["Reject: MAP_ERROR_ACCESS_DENIED"]
    CheckTraversal -- "Clean" --> SchemeCheck{"Inspect Path / Scheme"}

    SchemeCheck -- "POSIX / Windows Drive (C:\) / UNC" --> L1["Level 1: FileAudioSource (Direct OS Path)"]
    SchemeCheck -- "Uint8List Bytes" --> L2["Level 2: MemoryAudioSource (Zero-Copy RAM)"]
    SchemeCheck -- "asset:// or package:" --> L3["Level 3: AssetAudioSource (Bundle Ingestion)"]
    SchemeCheck -- "http:// or https://" --> CheckLive{"Detect Live vs VOD"}
    CheckLive -- "VOD / File" --> L4A["Level 4A: NetworkAudioSource (Byte-Range Seeking)"]
    CheckLive -- "Live Stream / icy://" --> L4B["Level 4B: LiveStreamAudioSource (Sliding Buffer)"]

    SchemeCheck -- "content://, fd://, or /proc/self/fd/" --> L5["Level 5: ResolvingAudioSource"]

    subgraph CapabilityPromotion ["Level 5 Promotion Evaluation"]
        L5 --> ProbeDirect{"Probe Canonical Filesystem Path"}
        ProbeDirect -- "Directly Readable" --> L1
        ProbeDirect -- "Inaccessible" --> DetachFD{"Acquire OS File Descriptor (detachFd)"}
        DetachFD -- "FD Acquired" --> CheckProc{"Probe /proc/self/fd/<fd> Symlink"}
        CheckProc -- "Direct Path Resolvable" --> L1
        CheckProc -- "Opaque Pipe / Scoped Storage" --> FdSource["FdByteProvider (Direct FD Reading)"]
        DetachFD -- "FD Unavailable" --> StreamProxy["Custom Stream Byte Provider"]
    end
```

1. **Security & Path Sanitization**: Inputs are scanned for null bytes and directory traversal attacks (`/../`, `\..\`). Suspicious paths are immediately rejected.
2. **Windows Disambiguation**: Windows drive letters (e.g. `C:\Audio\test.mp3`) and UNC network paths (`\\server\share`) are classified directly as `FileAudioSource` before URI scheme parsing to prevent drive letters from being misinterpreted as custom schemes.
3. **Android FUSE Mount Translation**: Paths referencing `/mnt/user/<uid>/emulated/<id>/...` or `/data/media/<id>/...` are translated into direct `/storage/emulated/<id>/...` paths.
4. **Scoped Storage Optimization**: For Android `content://` URIs, the engine inspects `/proc/self/fd/<fd>`. If the file resolves to a readable path in the app's directory, it is promoted to `FileAudioSource` and the descriptor is closed immediately. If not, it falls back to `FdByteProvider` without copying data to a temporary file.

### 5.3 Unified Audio Loader (`UnifiedAudioLoader`) & Reactive Backpressure

The [`UnifiedAudioLoader`](../lib/src/loader/unified_audio_loader.dart) coordinates between Dart stream providers and the native C buffer (`map_buffer_t`).

Unlike legacy streamers that rely on periodic timers, `UnifiedAudioLoader` uses **event-driven, reactive backpressure**:

- **Chunk Consumption**: As chunks arrive from `AudioByteProvider.open()`, the loader pushes them into `PlayerBackend.streamFeed(chunk)`.
- **Headroom Monitoring**: After feeding a chunk or receiving a native playback telemetry event, the loader calculates the native ahead headroom:
  $$\text{Headroom} = \text{rangeEnd} - \text{readCursorByte}$$
- **Backpressure Suspension**: When native headroom exceeds the target capacity (e.g. 30 seconds of audio), the loader pauses the stream subscription (`subscription.pause()`).
- **Reactive Resumption**: When native playback advances and headroom falls below the low-water mark (e.g. 15 seconds), the subscription resumes (`subscription.resume()`).
- **Zero Polling Overhead**: When the buffer is saturated, the Dart VM does not execute background timer ticks, reducing idle CPU usage to 0%.

### 5.4 Container Boundary Probing & Tail Probing (`probeTail`)

Many container formats place critical index metadata at the end of the file. `UnifiedAudioLoader` resolves this without downloading the entire file:

- **Dynamic ID3v2 Expansion**: Initial probes read 64 KB. If an ID3v2 header specifies an extended size, the probe dynamically expands up to 16 MB to capture all tags before starting decoding.
- **Non-Faststart MP4 Containers (`moov` at EOF)**: When decoding an MP4 container where the `moov` atom is at the end of the file, initial header probing fails with `MAP_ERROR_DECODE_FAILED`. The loader detects this condition, invokes `provider.probeTail()`, fetches the trailing 256 KB via an HTTP Range request, and passes it to `map_buffer_set_tail()`. The native engine then indexes the sample tables without downloading intermediate audio frames.
- **Ogg Vorbis / Opus Duration Sniffing**: The loader probes the final 64 KB of an Ogg container to extract the final page's `granule_pos`, calculating the exact track duration before playback begins.

---

## 6. Native Tripartite Buffer Architecture (`map_buffer_t`)

The native engine hosts a memory-efficient tripartite buffer ([`src/map_buffer.c`](../src/map_buffer.c)) designed specifically for audio decoding:

```text
 0                      audio_start                audio_end          total_size
 ┌──────────────────────────┬──────────────────────────┬──────────────────────┐
 │     1. Pinned Head       │  2. Pure Audio Ring      │     3. Tail Buffer   │
 │   Headers, ID3v2,        │   Sliding Audio Window   │   ID3v1, APEv2,      │
 │   Container Sample Table │   (Ring Memory Cache)    │   Trailing moov Box  │
 └──────────────────────────┴──────────────────────────┴──────────────────────┘
 ▲                          ▲                          ▲
 │                          │                          │
 └─ Dynamic RAM Buffer      └─ High-Speed Ring Buffer  └─ End-of-File RAM Cache
```

### 6.1 Memory Layout: Pinned Head, Pure Audio Ring & Tail Buffer

1. **Pinned Head (`[0 .. audio_start)`)**:
   Stores container headers (WAV headers, Ogg header pages, MP4 `ftyp`/`moov` boxes, FLAC `STREAMINFO`, ID3v2 tags). This memory is pinned in RAM and never overwritten, allowing decoders to reread header definitions during seeks.
2. **Pure Audio Ring (`[audio_start .. audio_end)`)**:
   A high-speed circular memory ring buffer containing active, undecoded audio bitstream frames. Offsets are mapped using modular arithmetic:
   $$\text{Ring Index} = (\text{byteOffset} - \text{audio\_start}) \pmod{\text{capacity}}$$
   The ring automatically discards data behind the low-water mark (`bufferBehind`) while caching data ahead of the reading cursor (`bufferAhead`).
3. **Tail Buffer (`[audio_end .. total_size)`)**:
   Retains trailing tags (ID3v1, APEv2, Lyrics3) or non-faststart MP4 `moov` atoms.

### 6.2 Container Boundary Locking & Header Synthesis

Audio decoders can crash or produce noise if non-audio metadata is fed into the bitstream parser. `map_buffer_t` prevents this via boundary locking:

- **Format Sniffing (`map_sniffer.c`)**: Sniffs byte markers to detect exact boundaries for `audio_start` and `audio_end`.
- **EOF Enforcement**: When `map_buffer_set_decoding_audio(mb, MA_TRUE)` is called, any read attempting to pass `audio_end` is truncated to `audio_end`, signaling EOF to the decoder before it reads trailing metadata tags.
- **RIFF WAV Synthesis**: For live or chunked WAV streams with unknown total length, the buffer synthesizes valid data-chunk size headers, allowing the standard miniaudio WAV decoder to parse the incoming stream.

### 6.3 Dynamic Metadata Synthesis (`.metaBytes`) & Versioning

To give Dart access to raw container metadata without parsing overhead, `map_buffer_t` maintains a metadata version counter (`meta_version`):

- When initial headers, ID3 tags, or ICY metadata updates are processed, `meta_version` increments.
- Dart tracks this version. When a change is detected, `PlayerBackend.getMetaBytes()` extracts a combined byte array of head, tail, and ICY data for asynchronous parsing by high-level Dart tag decoders.

### 6.4 Real-Time Silence Synthesis on Starvation

If network throughput drops and the decoder read cursor reaches `range_end` before new chunks arrive, `map_buffer_t` enters `MAP_BUFFER_STATE_BUFFERING`. Instead of hanging or generating loud buffer underrun clicks, the native data source ([`src/map_source.c`](../src/map_source.c)) outputs synthesized zero-value PCM silence frames while notifying the Dart facade via `MAP_EVENT_IS_BUFFERING`.

---

## 7. Comprehensive Finite State Machines (FSM) & Lifecycle Synchronization

The engine uses six distinct Finite State Machines across Dart and C layers to ensure deterministic operation:

### 7.1 Dart Opening State Gate & Generational Invalidation

In rapid UI environments, users may trigger multiple `open()` calls in quick succession. `PlayerAction` eliminates race conditions using an Opening State Gate:

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Opening: open(source) [Increment _openGeneration, notifyOpening()]
    Opening --> Opening: rapid open() [Increment _openGeneration, cancel prior loader]
    Opening --> Ready: Stream probed & decoder ready [Notify openCompleted]
    Opening --> Error: Decoder failed or network timeout [Notify openFailed]
    Ready --> Playing: play()
    Ready --> Idle: stop()
    Error --> Idle: stop() / open()
```

- **Generational Counter (`_openGeneration`)**: Every call to `open()` increments an integer generation ID. Any in-flight asynchronous operations (DNS lookups, tail probes, HTTP handshakes) verify that their local generation matches `_openGeneration` before mutating state.
- **Coordination Completer (`_openingCompleter`)**: Imperative commands like `play()` or `seek()` await `_openingCompleter.future` if an open operation is in progress, guaranteeing commands execute in the intended sequence without blocking the UI thread.

### 7.2 High-Level Engine Phase State Machine (`EnginePhase`)

[`MiniaudioEngine<T>`](../lib/src/api/miniaudio_engine.dart) is governed by [`EnginePhase`](../lib/src/api/engine_state.dart):

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> loading: open() / play()
    loading --> playing: Deck initialized & playback started
    loading --> error: All queue candidates failed
    playing --> paused: pause()
    paused --> playing: play()
    playing --> autoCrossfading: Pos within crossfadeDuration of track end
    autoCrossfading --> playing: Candidate deck faded in & swapped to active
    playing --> manualCrossfading: next() / previous() / skipToIndex()
    manualCrossfading --> playing: Standby deck faded in & swapped
    playing --> completed: Track end reached [LoopMode.off, no next item]
    playing --> idle: stop()
    paused --> idle: stop()
    idle --> disposed: dispose()
    error --> idle: open()
```

### 7.3 Unified Loader State Machine (`UnifiedLoaderState`)

[`UnifiedAudioLoader`](../lib/src/loader/unified_audio_loader.dart) manages network and buffer loading states:

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> probingHead: start() [Open byte provider at offset 0]
    probingHead --> streaming: Initial probe complete & decoder initialized
    streaming --> pausedByBackpressure: Headroom > bufferAhead [subscription.pause()]
    pausedByBackpressure --> streaming: Headroom < lowWaterMark [subscription.resume()]
    streaming --> seeking: seekByte() / seekTime() [Flush buffer & reset offset]
    seeking --> streaming: Seek response received & decoding resumes
    streaming --> completed: Provider reached EOF
    streaming --> error: Network failure / decode error
    streaming --> stopped: stop() [Pause subscription & reset offsets]
    stopped --> streaming: onPlayFromStopped()
```

### 7.4 Native High-Level Buffer State Machine (`map_buffer_state_t`)

The tripartite buffer ([`src/map_buffer.h`](../src/map_buffer.h)) executes this low-level lifecycle:

```mermaid
stateDiagram-v2
    [*] --> UNINITIALIZED
    UNINITIALIZED --> PROBING_HEAD: map_buffer_init()
    PROBING_HEAD --> READY: Initial head bytes set & audio_start locked
    READY --> BUFFERING: Read cursor reaches range_end (Buffer starvation)
    BUFFERING --> READY: streamFeed() delivers new data
    READY --> EOF: Provider signals stream end & cursor reaches audio_end
    READY --> ABORTED: map_buffer_abort() [Seek flush or player destroy]
    BUFFERING --> ABORTED: map_buffer_abort()
```

### 7.5 Native Data Source State Machine (`map_source_state_t`)

The decoder data source ([`src/map_source.h`](../src/map_source.h)) coordinates decoding and time-stretching:

```mermaid
stateDiagram-v2
    [*] --> UNINITIALIZED
    UNINITIALIZED --> IDLE: init_stream() / init_file()
    IDLE --> DECODING: Audio thread requests PCM frames
    DECODING --> BUFFERING: Underlying map_buffer_t is starving
    BUFFERING --> DECODING: Data arrives in buffer
    DECODING --> DRAINING: Decoder hits container EOF (draining Sonic & ring buffer)
    DRAINING --> EOF: All remaining PCM frames rendered
    DECODING --> ERROR: Unrecoverable decoding error
```

### 7.6 Native Silence Detection State Machine (`map_silence_state_t`)

The real-time silence detector ([`src/map_silence.h`](../src/map_silence.h)) manages voice and silence transitions:

```mermaid
stateDiagram-v2
    [*] --> VOICE: map_silence_detector_init()
    VOICE --> HOLDING: Frame amplitude falls below threshold
    HOLDING --> VOICE: Voice re-detected before min_silence_frames elapsed
    HOLDING --> SKIPPING: Silence duration > min_silence_frames [Apply 5ms fade-out]
    SKIPPING --> VOICE: Frame amplitude exceeds exit threshold [Apply 5ms fade-in]
```

---

## 8. High-Level Dual-Deck Queue & Crossfade Engine (`MiniaudioEngine<T>`)

[`MiniaudioEngine<T>`](../lib/src/api/miniaudio_engine.dart) provides dual-deck queue management, seamless crossfading, ReplayGain normalization, and Infinite Mix streaming.

### 8.1 Dual-Deck Orchestration & Single Ownership Invariant

The engine wraps two distinct `MiniaudioPlayer` instances (`_playerA` and `_playerB`), alternating their roles between **Active Deck** (currently outputting to the master mix) and **Standby Deck** (pre-buffering incoming tracks):

```text
       ┌────────────────────────────────────────────────────────┐
       │                 MiniaudioEngine<T>                     │
       └──────────────┬──────────────────────────┬──────────────┘
                      │                          │
                      ▼                          ▼
             ┌─────────────────┐        ┌─────────────────┐
             │  Deck A Player  │        │  Deck B Player  │
             │ (Active Deck)   │        │ (Standby Deck)  │
             └─────────────────┘        └─────────────────┘
```

- **Single Ownership Invariant**: External application code never interacts directly with underlying player instances. Deck lifecycle transitions (`open`, `play`, `pause`, `stop`, `seek`, volume fading) are driven exclusively through the engine's serialized FIFO command queue.
- **Clean Standby Invariant**: Before reusing the standby deck, any in-flight transitions are deterministically settled, and the deck is stopped and reset to `0.0` volume.

### 8.2 Queue Lifecycle, Fisher-Yates Shuffle & Exact Un-shuffle

The queue manager ([`src/engine/internal_queue_manager.dart`](../lib/src/engine/internal_queue_manager.dart)) supports non-destructive shuffling:

- **Original Queue Retention**: The engine preserves both `_originalQueue` and `_activeQueue`.
- **Fisher-Yates Shuffling**: Calling `setShuffle(true)` shuffles items uniformly in $\mathcal{O}(N)$ time while keeping the currently playing item pinned at index 0.
- **Exact Un-Shuffle Restoration**: Calling `setShuffle(false)` instantly restores the original queue sequence without interrupting playback of the current track.
- **Loop Modes**: Full support for `LoopMode.off` (halts at queue end), `LoopMode.one` (repeats current track), and `LoopMode.all` (loops queue continuously).

### 8.3 Mathematical Crossfade Curves: Equal-Power vs. Linear

The crossfade controller ([`src/engine/internal_crossfade_controller.dart`](../lib/src/engine/internal_crossfade_controller.dart)) supports two volume interpolation curves:

```mermaid
flowchart LR
    subgraph EqualPower ["Equal-Power Gain Curve (Default)"]
        direction TB
        EP_Out["G_out(p) = cos(p * π / 2)"]
        EP_In["G_in(p) = sin(p * π / 2)"]
        EP_Mid["Midpoint (p=0.5): ~0.707 (-3.01 dB)"]
    end

    subgraph LinearCurve ["Linear Gain Curve"]
        direction TB
        L_Out["G_out(p) = 1.0 - p"]
        L_In["G_in(p) = p"]
        L_Mid["Midpoint (p=0.5): 0.500 (-6.02 dB)"]
    end
```

- **Equal-Power (`CrossfadeCurve.equalPower`)**:
  Preserves constant perceived acoustic energy throughout the transition. At the midpoint ($p = 0.5$), both decks play at $\approx 70.7\%$ gain ($-3.01\text{ dB}$), eliminating the volume dip common in linear crossfades of uncorrelated audio tracks:
  $$G_{\text{out}}(p) = \cos\left(p \cdot \frac{\pi}{2}\right), \quad G_{\text{in}}(p) = \sin\left(p \cdot \frac{\pi}{2}\right)$$
- **Linear (`CrossfadeCurve.linear`)**:
  Applies direct proportional gain scaling. Suitable for correlated stems or voice tracks:
  $$G_{\text{out}}(p) = 1.0 - p, \quad G_{\text{in}}(p) = p$$

```mermaid
sequenceDiagram
    autonumber
    participant Engine as MiniaudioEngine
    participant DeckA as Deck A (Outgoing)
    participant DeckB as Deck B (Incoming)

    Note over DeckA: Position reaches Duration - crossfadeDuration
    Engine->>Engine: Enter EnginePhase.autoCrossfading
    Engine->>DeckB: open(nextItem) [Prepare at 0.0 volume]
    DeckB-->>Engine: Open Completed
    Engine->>DeckB: play()

    loop Every 25ms Crossfade Tick (p from 0.0 to 1.0)
        Engine->>DeckA: setVolume(master * cos(p * π / 2))
        Engine->>DeckB: setVolume(master * sin(p * π / 2))
    end

    Note over DeckA,DeckB: Crossfade Completes (p = 1.0)
    Engine->>DeckA: stop() [Reset to 0.0 volume]
    Engine->>Engine: Swap Roles (Deck B becomes Active, Deck A becomes Standby)
    Engine->>Engine: Enter EnginePhase.playing
```

### 8.4 Infinite Mix Proactive Prefetching Pipeline

When an `InfiniteMixProvider<T>` is attached to the queue manager, the engine automatically prefetches upcoming tracks:

- When queue playback approaches the final items, the manager requests new items from the provider asynchronously.
- New entries are appended to the queue seamlessly, preventing playback stops in radio-style or continuous mix applications.

---

## 9. Real-Time Audio DSP Processing Pipeline & Effects Engine

The native audio pipeline processes PCM audio frames inside `ma_equalizer_node_process_pcm_frames` ([`src/map_dsp.c`](../src/map_dsp.c)). The effects chain is ordered to maximize dynamic range, prevent clipping, and minimize phase distortion.

### 9.1 The Master DSP Node Signal Chain

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      Raw Decoded PCM Audio Frames In                   │
 └───────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
             ┌────────────────────────────────────────────────┐
             │ 1. Preamp & ReplayGain Volume Ramping          │
             │    - Target Gain Smoothing (Anti-Pop Ramping)  │
             │    - Peak-Aware Anti-Clipping Attenuation      │
             └───────────────────────┬────────────────────────┘
                                     │
                                     ▼
             ┌────────────────────────────────────────────────┐
             │ 2. ISO 266 10-Band Parametric Equalizer        │
             │    - SIMD Direct Form II Transposed Biquads    │
             │    - Analytical RBJ Peaking & Shelving Curves  │
             └───────────────────────┬────────────────────────┘
                                     │
                                     ▼
             ┌────────────────────────────────────────────────┐
             │ 3. Algorithmic Stereo Reverb (Freeverb Model)  │
             │    - 8 Parallel Lowpass Comb Filters / Channel │
             │    - 4 Cascaded Allpass Filters / Channel      │
             │    - Anti-Denormal Protection Registers        │
             └───────────────────────┬────────────────────────┘
                                     │
                                     ▼
             ┌────────────────────────────────────────────────┐
             │ 4. Binaural Headphone Crossfeed (Bauer bs2b)   │
             │    - Lowpass Cross-Feed Delay (700Hz, 4.5/6dB) │
             │    - Optional Stereo Spatializer / Widening    │
             └───────────────────────┬────────────────────────┘
                                     │
                                     ▼
             ┌────────────────────────────────────────────────┐
             │ 5. Downmixing & Stereo Panning                 │
             │    - Mono Downmix Matrix                       │
             │    - Linear Constant-Power Balance Panning     │
             └───────┬────────────────────────────────┬───────┘
                     │                                │
                     ▼                                ▼
  ┌───────────────────────────────────┐    ┌───────────────────────────┐
  │ 6. Visualizer Spectrum Tap        │    │ 7. Master Volume Fader    │
  │    - 10-Band BPF Filter Bank      │    │    - Steady-State Bypass  │
  │    - Peak / RMS Level Detection   │    └─────────────┬─────────────┘
  │    - Cache-Line Aligned Seqlock   │                  │
  └───────────────────────────────────┘                  ▼
                                           ┌───────────────────────────┐
                                           │ 8. True-Peak Limiter      │
                                           │    - Soft-Knee Brickwall  │
                                           │    - Branchless Clamp     │
                                           └─────────────┬─────────────┘
                                                         │
                                                         ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │                     Final PCM Output to Audio DMA                      │
 └────────────────────────────────────────────────────────────────────────┘
```

### 9.2 ISO 266 10-Band Parametric Equalizer (DF2T Biquads)

The equalizer implements ten cascaded biquad filters matching ISO 266 preferred frequencies:

$$\text{Frequencies: } [31\text{ Hz}, 63\text{ Hz}, 125\text{ Hz}, 250\text{ Hz}, 500\text{ Hz}, 1\text{ kHz}, 2\text{ kHz}, 4\text{ kHz}, 8\text{ kHz}, 16\text{ kHz}]$$

- **Filter Topologies**: Band 0 is a 2nd-order Low-Shelf filter; bands 1 through 8 are 2nd-order Peaking EQ filters ($Q = 1.414$ for 1-octave bandwidth); band 9 is a 2nd-order High-Shelf filter.
- **Direct Form II Transposed (DF2T)**: Minimizes numerical round-off noise and quantization errors in 32-bit floating-point execution:
  $$y[n] = b_0 x[n] + s_1[n-1]$$
  $$s_1[n] = b_1 x[n] - a_1 y[n] + s_2[n-1]$$
  $$s_2[n] = b_2 x[n] - a_2 y[n]$$
- **Hardware Anti-Denormal Protection**: State variables ($s_1, s_2$) are clamped to zero if $|s| < 10^{-20}\text{ f}$, preventing CPU performance drops from denormal floating-point numbers.

### 9.3 Studio-Grade Algorithmic Reverb (Freeverb Model)

[`src/map_reverb.c`](../src/map_reverb.c) provides stereophonic reverberation based on the classic Freeverb architecture:

- **Filter Bank**: 8 parallel Lowpass Feedback Comb Filters (LBCF) and 4 cascaded Allpass Filters (APF) per channel (24 filters total).
- **Stereo Decorrelation**: Comb filter delay line lengths are slightly offset between left and right channels, generating a wide stereo soundstage without mono phase cancellation.
- **Zero Real-Time Allocations**: Delay lines are pre-allocated during player initialization. Room size, damping, stereo width, and wet/dry mix are updated via pointer parameters without memory reallocations.

### 9.4 Binaural Crossfeed (bs2b) & Stereo Spatializer

- **Bauer bs2b Algorithm**: Reduces acoustic fatigue during headphone listening by emulating the natural acoustic crosstalk that occurs when listening to stereo loudspeakers in a physical room. Supports Moffat-Bauer ($700\text{ Hz}, 4.5\text{ dB}$) and Chu Moy ($700\text{ Hz}, 6.0\text{ dB}$) presets.
- **Stereo Spatializer**: Dynamically adjusts the stereo field width ($1.0$ to $2.0$) by isolating mid/side signal components and boosting the side (difference) signal.

### 9.5 True-Peak Soft-Knee Brickwall Limiter

Positioned at the final output stage before hardware handoff, the limiter prevents digital clipping while preserving transparency:

- **Linear Zone Transparency**: For signal levels $|x| \le 0.95$ FS ($-0.45\text{ dBFS}$), the transfer function is linear ($y = x$), yielding **$0.00000\%$ Total Harmonic Distortion** and **$141.4\text{ dB}$ SNR**.
- **Soft-Knee Compression Zone**: For digital overshoots above $0.95$ FS (e.g. from high EQ boosts), a branchless polynomial soft-knee curve smoothly compresses peaks:
  $$y = \text{sgn}(x) \cdot \left(0.95 + 0.046 \cdot \tanh\left(\frac{|x| - 0.95}{0.046}\right)\right)$$
- Digital overshoots up to $+3.5\text{ dBFS}$ are capped at $0.996$ FS, preventing harsh digital clipping distortion.

### 9.6 Dynamic Silence Trimming & Skipping

[`src/map_silence.c`](../src/map_silence.c) operates upstream of time-stretching and equalizers:

- **Lead-In / Lead-Out Trimming**: Strips leading and trailing silence from music tracks for gapless playback.
- **Conversational Silence Skipping**: Detects pauses in audiobooks and podcasts. When audio drops below the silence threshold (default: $-45\text{ dBFS}$) for longer than `min_silence_duration_ms`, frames are discarded.
- **Click-Free Transitions**: Smooths entry into and exit from silence using a 5ms linear crossfade ramp, preventing audible pops.
- **Cumulative Saved Time Tracking**: Telemetry records total skipped duration (`silence_saved_ms`) for display in UI statistics.

### 9.7 Pitch & Tempo Scaling (Sonic DSP)

Integrates [Sonic DSP](https://github.com/waywardgeek/sonic) for independent speed and pitch adjustments:

- **Playback Rate**: $0.25\times$ to $4.0\times$ speed with sample-accurate pitch preservation.
- **Pitch Multiplier**: $0.5\times$ to $2.0\times$ frequency shifting independent of playback tempo.

---

## 10. Threading Model, Lock-Free Concurrency & Real-Time Safety

`miniaudio_player` isolates operations across three asynchronous domains:

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                    1. Dart Main UI & Ingest Thread                     │
 │  - Flutter Widget rendering & user gesture dispatch                    │
 │  - HTTP Chunk download & backpressure coordination                     │
 │  - NativeCallable.listener reactive event consumption                  │
 └───────────────────────────────────┬────────────────────────────────────┘
                                     │
                  FFI Direct Invocation / Stream Feeding
                                     │
                                     ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │               2. Native Background Decoder Worker Thread               │
 │  - File / Memory / Buffer reading (map_buffer_t)                       │
 │  - Codec decompression (MP3, FLAC, Ogg, Opus, AAC, ALAC, WAV)          │
 │  - Sonic time-stretching & pitch-shifting                              │
 └───────────────────────────────────┬────────────────────────────────────┘
                                     │
                     ma_pcm_rb Lock-Free SPSC Commit
                                     │
                                     ▼
 ┌────────────────────────────────────────────────────────────────────────┐
 │               3. Dedicated Native OS Real-Time Audio Thread            │
 │  - High-priority OS callback (AAudio, CoreAudio, WASAPI, ALSA)         │
 │  - Strict O(1) determinism (0 dynamic allocations, 0 blocking mutexes) │
 │  - Real-Time DSP pipeline (EQ, Reverb, Crossfeed, Limiter, Visualizer) │
 └────────────────────────────────────────────────────────────────────────┘
```

### 10.1 Three Decoupled Execution Domains

1. **Dart UI / Ingest Thread**: Handles user commands, network fetching, and UI telemetry. Never directly touches PCM frame decoding.
2. **Native Decoder Worker Thread**: Pulls raw bytes from `map_buffer_t`, invokes `ma_decoder_read_pcm_frames()`, processes Sonic time-stretching, and pushes decoded PCM audio into an SPSC ring buffer.
3. **Native Real-Time Audio Thread**: Woken directly by the OS kernel audio scheduler. Executes the DSP pipeline and transfers samples to the DAC in bounded $\mathcal{O}(1)$ time.

### 10.2 Lock-Free SPSC PCM Ring Buffer (`ma_pcm_rb`)

Audio handoff between the Decoder Worker and the Real-Time Audio Thread uses a Single-Producer Single-Consumer (SPSC) lock-free ring buffer ([`src/map_source.c`](../src/map_source.c)):

- The decoder worker writes decoded audio frames to the buffer head.
- The real-time audio thread reads frames from the buffer tail.
- Memory fences and atomic head/tail pointers guarantee synchronization without thread locking or kernel context switches.

### 10.3 Cache-Line Aligned Atomic Sequence Lock (`map_seqlock_t`)

High-frequency telemetry data (such as visualizer spectrum bands and buffered ranges) is written by the real-time audio thread and read by Dart via a lock-free sequence lock ([`src/map_seqlock.h`](../src/map_seqlock.h)):

```c
typedef struct {
    MAP_ALIGN_CACHE_LINE MA_ATOMIC(4, ma_uint32) sequence;
} map_seqlock_t;
```

- **Cache-Line Alignment (`MAP_ALIGN_CACHE_LINE`)**: Structures are padded to 64-byte boundaries, preventing false sharing between audio processing threads and telemetry reading threads.
- **Lock-Free Read Protocol**: Readers verify that the sequence number is even before and after copying data. If a write occurred mid-read, the sequence increments and the read retries using a CPU pause instruction (`__builtin_ia32_pause()` or `yield`), guaranteeing thread safety without mutex locks.

### 10.4 Priority Inversion Avoidance & Mutex Trylocks

To prevent priority inversion—where a low-priority thread holding a lock blocks a high-priority real-time audio callback—the audio thread **never calls blocking mutex functions** (`ma_mutex_lock`). Where shared synchronization is unavoidable, `ma_mutex_trylock` or atomic operations are used. If a lock is contested, the audio thread falls back to cached state rather than blocking the hardware DMA stream.

---

## 11. Native Reactive Event Dispatcher & Telemetry Pipeline

The event dispatcher ([`src/map_event_dispatcher.c`](../src/map_event_dispatcher.c)) batches, deduplicates, and delivers native events to Dart.

```mermaid
flowchart TD
    subgraph Producers ["Lockless Producers (Audio Thread & C Engine)"]
        RT_State["post_state(...)"]
        RT_Pos["post_position(...)"]
        RT_Vis["post_visualizer(...)"]
        RT_Buf["post_buffered_range(...)"]
    end

    subgraph DispatcherCore ["map_event_dispatcher Engine"]
        DirtyMask["Atomic 64-Bit Dirty Mask (ma_atomic_fetch_or_64)"]
        DoubleBuf["Double-Buffered State (pending vs. last_emitted)"]
        Deduplicator{"Value Deduplication Engine"}
        ThrottleGate{"Telemetry Throttling Gate (~33 ms / 30 fps)"}
        EventRing["Pre-allocated Event Ring (128 elements)"]
        Wakeup["ma_event Wakeup Signal"]
    end

    subgraph DartBridge ["Dart FFI Receiver"]
        NativeCallable["NativeCallable.listener Callback"]
        StreamControllers["Dart StreamControllers & Listeners"]
    end

    Producers -->|"O(1) Atomic Store"| DoubleBuf
    Producers -->|"Atomic Bit Set"| DirtyMask
    Producers -->|"Trigger"| Wakeup

    Wakeup --> ThrottleGate
    DirtyMask --> Deduplicator
    DoubleBuf --> Deduplicator

    Deduplicator -- "Value Unchanged" --> Drop["Discard Duplicate"]
    Deduplicator -- "Value Changed" --> EventRing

    EventRing -->|"Dispatch via FFI"| NativeCallable
    NativeCallable --> StreamControllers
```

### 11.1 Double-Buffering & Value Deduplication

The dispatcher maintains two state structs: `pending` and `last_emitted`.

- Producers write incoming values into `pending` using atomic operations.
- The background dispatcher thread compares `pending` against `last_emitted`.
- If an incoming value is identical to the previously dispatched event (e.g. redundant playback state updates or unchanged bitrates), the event is dropped, preventing unnecessary Dart event loop wakeups.

### 11.2 Atomic 64-Bit Dirty Bitmask & Throttled Telemetry

Events are grouped into two categories via an atomic 64-bit bitmask:

```c
#define MAP_DIRTY_TELEMETRY_MASK ( \
    MAP_DIRTY_POSITION | \
    MAP_DIRTY_VISUALIZER | \
    MAP_DIRTY_BUFFERED_RANGE | \
    MAP_DIRTY_SILENCE_SAVED \
)
#define MAP_DIRTY_DISCRETE_MASK (~MAP_DIRTY_TELEMETRY_MASK)
```

- **Discrete Events (`MAP_DIRTY_DISCRETE_MASK`)**: Critical lifecycle events (state changes, play/pause, errors, track completion) trigger immediate dispatch with sub-millisecond response times.
- **Continuous Telemetry (`MAP_DIRTY_TELEMETRY_MASK`)**: High-frequency metrics (position updates, visualizer levels) are rate-limited to approximately 30 fps (33 ms intervals), preventing UI thread flooding while maintaining smooth animations.

### 11.3 Dedicated Background Dispatcher Thread & Native Event Ring

Events are buffered in a pre-allocated 128-slot ring buffer (`MAP_EVENT_RING_CAPACITY`) and delivered via `NativeCallable.listener`. Because delivery runs on a dedicated dispatcher thread, real-time audio threads never perform FFI transitions directly.

---

## 12. Offline Single-Pass Audio Analysis

`miniaudio_player` includes a high-performance offline audio analysis engine ([`src/map_analysis.c`](../src/map_analysis.c)) that processes audio files in a single pass on a native background thread.

```mermaid
flowchart LR
    SourceFile["Audio File / Memory Bytes"] --> StreamDecoder["Native Stream Decoder (ma_decoder)"]

    subgraph SinglePassAnalysis ["Single-Pass Analysis Pipeline (< 100 KB RAM)"]
        direction TB
        KFilter["K-Weighting Biquad Cascade (RLB + High Shelf)"] --> MeanSquare["Gated Mean-Square Energy Accumulator"]
        PeakTracker["True-Peak / Sample Peak Tracker"]
        WaveformGen["Downsampled Waveform Envelope Binning"]
    end

    StreamDecoder --> KFilter
    StreamDecoder --> PeakTracker
    StreamDecoder --> WaveformGen

    MeanSquare --> LUFS["Integrated Loudness (LUFS)"]
    LUFS --> ReplayGain["Recommended ReplayGain (dB)"]
    PeakTracker --> PeakVal["True Peak (dBFS)"]
    WaveformGen --> WaveformArray["Waveform Points (Float Array)"]

    ReplayGain & PeakVal & WaveformArray --> DartResult["Dart AudioAnalysisResult"]
```

### 12.1 ITU-R BS.1770-4 / EBU R128 Integrated Loudness (LUFS)

Loudness analysis applies the standard ITU-R BS.1770-4 K-weighting curve:

1. **Stage 1 (Head Filter)**: High-shelf filter boosting frequencies above $1.5\text{ kHz}$ to model acoustic head-shadow effects.
2. **Stage 2 (RLB Filter)**: High-pass filter attenuating low frequencies below $100\text{ Hz}$.
3. **Energy Gating**: Blocks with energy below the absolute threshold ($-70\text{ LUFS}$) and relative threshold ($-10\text{ dB}$ below un-gated mean) are discarded, matching industry-standard EBU R128 broadcast measurements.

### 12.2 True-Peak Detection & ReplayGain Calculation

- **True-Peak Measurement**: Analyzes sample peaks to calculate maximum signal excursions.
- **ReplayGain Calculation**: Computes the gain adjustment required to normalize the track to the configured target loudness (default: $-18.0\text{ LUFS}$):
  $$\text{Gain}_{\text{dB}} = \text{Target LUFS} - \text{Measured LUFS}$$
- **Anti-Clipping Protection**: If applying the recommended gain would cause peaks to exceed $0.0\text{ dBFS}$ ($1.0$), the engine automatically calculates a safe, peak-limited gain offset.

### 12.3 Normalized Waveform Extraction

During the same single decoding pass, the analyzer generates a downsampled array of normalized amplitude values (e.g. 100 points) representing the track's dynamic envelope. The Flutter UI can bind this array directly to custom seekbar painters without additional decoding or separate isolate workers.

---

## 13. Hardware Backends & Cross-Platform Driver Optimizations

`miniaudio_player` integrates with native OS audio subsystems through optimized driver paths:

### 13.1 Linux: PulseAudio & ALSA

- **Primary Driver**: Native PulseAudio client via asynchronous stream callbacks.
- **Fallback**: Direct ALSA hardware driver (`hw:X,Y` / `default`) with software mixing, optimized for embedded Linux and Raspberry Pi environments.

### 13.2 Android: AAudio, OpenSL ES & 16 KB Memory Page Support

- **AAudio Engine**: Uses low-latency AAudio streams (`AAUDIO_PERFORMANCE_MODE_LOW_LATENCY`) with direct memory-mapped (MMAP) hardware transfers on Android 8.1+ (API 27+).
- **OpenSL ES Fallback**: Automatically falls back to OpenSL ES on older Android versions.
- **Android 15 Page Alignment**: All native libraries are compiled with `-Wl,-z,max-page-size=16384`, ensuring full compatibility with 16 KB memory pages on Android 15 devices.

### 13.3 Windows: WASAPI Exclusive & MMCSS 1 ms Scheduling

- **WASAPI Audio Client**: Configured for low-latency shared or exclusive audio rendering.
- **MMCSS Registration**: Audio threads register with Windows Multimedia Class Scheduler Service (`AvSetMmThreadCharacteristicsW("Pro Audio", ...)`) to prioritize execution over standard desktop processes, guaranteeing 1 ms scheduling accuracy.

### 13.4 Apple macOS / iOS: CoreAudio AudioUnit Graph

- **CoreAudio HAL**: Interfaces with the system `AudioUnit` graph.
- **iOS Audio Session**: Compatible with `AVAudioSessionCategoryPlayback`, supporting lock-screen playback, Bluetooth accessories, and control-center routing.

### 13.5 Universal Hardware Denormal Purging (FTZ & DAZ)

Denormal floating-point numbers can cause significant CPU performance degradation on x86 and ARM processors. The engine configures hardware registers on audio threads to flush denormals immediately:

- **x86/x64**: Sets Flush-To-Zero (FTZ) and Denormals-Are-Zero (DAZ) bits in the MXCSR control register:

  ```c
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
  ```

- **ARM64 / ARMv7**: Enables FTZ by setting the FZ bit (bit 24) in the Floating-Point Status and Control Register (FPCR).

---

## 14. Verification, Quality Assurance & Acoustic Certification

The engine is backed by a comprehensive automated test suite spanning unit, integration, stress, and acoustic certification tests:

| Metric                          | Target Specification       | Measured Value                   | Verification Method                               |
| :------------------------------ | :------------------------- | :------------------------------- | :------------------------------------------------ |
| **Real-Time Allocations**       | 0 heap allocations         | **0 calls to malloc/free**       | Native address-sanitizer hook on render thread    |
| **Limiter THD**                 | $< 0.0001\%$ ($x\le 0.95$) | **$0.00000\%$**                  | Ultra-pure 1 kHz sine-wave FFT spectral analysis  |
| **Limiter SNR**                 | $> 130\text{ dB}$          | **$141.4\text{ dB}$**            | Full-scale 24-bit test signal evaluation          |
| **EQ Analytical Accuracy**      | $\pm 0.01\text{ dB}$       | **$0.00\text{ dB}$**             | Robert Bristow-Johnson (RBJ) reference comparison |
| **Command Latency**             | $< 10\ \mu\text{s}$        | **$< 1\ \mu\text{s}$**           | Direct FFI benchmark timing                       |
| **Idle CPU (Buffer Saturated)** | $< 1\%$                    | **$0.0\%$**                      | Reactive backpressure verification                |
| **Concurrency Fuzzing**         | 0 deadlocks                | **10,000+ chaotic calls passed** | Automated multi-threaded fuzz testing             |

---

## 15. Repository Layout & Code Navigation Map

```text
miniaudio_player/
├── assets/
│   └── miniaudio_player.wasm         # Pre-compiled WebAssembly engine binary for Web
├── docs/
│   └── ARCHITECTURE.md               # This architectural specification document
├── hook/
│   └── build.dart                    # Dart Native Assets compiler hook (native_toolchain_c)
├── lib/
│   ├── miniaudio_player.dart         # Public library barrel export
│   ├── miniaudio_player_bindings_generated.dart # FFI bindings generated by ffigen
│   └── src/
│       ├── api/                      # Application-facing API definitions
│       │   ├── audio_analysis_result.dart # Analysis data models (LUFS, Peak, Waveform)
│       │   ├── audio_device.dart     # Device enumeration and selection models
│       │   ├── audio_source.dart     # Polymorphic AudioSource hierarchy
│       │   ├── buffered_range.dart   # Buffering telemetry models
│       │   ├── crossfade_config.dart # Mathematical crossfade curve configurations
│       │   ├── dsp_config.dart       # ReplayGain, Spatializer, and Limiter models
│       │   ├── engine_action.dart    # High-level MiniaudioEngine action facade
│       │   ├── engine_item.dart      # Generic domain item wrapper EngineItem<T>
│       │   ├── engine_state.dart     # MiniaudioEngine synchronous state getters & FSM
│       │   ├── engine_stream.dart    # MiniaudioEngine reactive broadcast streams
│       │   ├── loop_mode.dart        # Queue loop modes (off, one, all)
│       │   ├── miniaudio_engine.dart # Master dual-deck queue & crossfade engine
│       │   ├── miniaudio_player.dart # Core single-track MiniaudioPlayer facade
│       │   ├── player_action.dart    # Player action facade (Opening Gate & transport)
│       │   ├── player_exception.dart # Typed exceptions & MapResult mappings
│       │   ├── player_state.dart     # PlayerState synchronous snapshot getters
│       │   ├── player_stream.dart    # PlayerStream reactive broadcast streams
│       │   ├── silence_skip_config.dart # Silence detector configuration models
│       │   ├── track_metadata.dart   # Audio container metadata and ICY station tags
│       │   └── visualizer_data.dart  # 10-Band visualizer & VU telemetry models
│       ├── engine/                   # Multi-track queue engine internals
│       │   ├── internal_crossfade_controller.dart # Crossfade volume ramp interpolation
│       │   └── internal_queue_manager.dart        # Queue state, shuffle, & Infinite Mix
│       ├── equalizer.dart            # ISO 266 10-band equalizer presets and parameters
│       ├── reverb.dart               # Algorithmic stereo reverb presets and parameters
│       ├── ffi/
│       │   └── native_types.dart     # FFI constants, enum mappings, and error codes
│       ├── loader/                   # Ingestion and stream buffering
│       │   ├── audio_byte_provider.dart # AudioByteProvider hierarchy & UriCapabilityResolver
│       │   └── unified_audio_loader.dart # Unified progressive loader & backpressure FSM
│       └── platform/                 # Polymorphic platform abstraction
│           ├── fs_helper.dart        # Cross-platform filesystem helpers
│           ├── http_helper.dart      # Cross-platform HTTP request abstraction
│           ├── platform_backend.dart # PlayerBackend and PlatformService interfaces
│           ├── platform_select.dart  # Conditional export resolver (Native vs. Web)
│           ├── native/               # Native FFI backend implementation
│           │   ├── fs_helper.dart    # POSIX/Windows filesystem operations
│           │   ├── http_helper.dart  # dart:io HttpClient implementation
│           │   └── native_backend.dart # NativePlayerBackend implementation
│           └── web/                  # WebAssembly AudioWorklet implementation
│               ├── fs_helper.dart    # Browser filesystem stubs
│               ├── http_helper.dart  # Browser fetch/XHR implementation
│               ├── wasm_loader.dart  # WebAssembly module loader
│               ├── web_backend.dart  # WebPlayerBackend implementation
│               ├── web_interop.dart  # JS interop bindings
│               └── web_worker_blob.dart # Web Worker & AudioWorklet JavaScript blobs
├── src/                              # Native C engine source code
│   ├── miniaudio.h                   # miniaudio core single-file audio library
│   ├── miniaudio_impl.c              # miniaudio compilation unit & custom backends
│   ├── miniaudio_player.h            # Native C engine public header & API definitions
│   ├── miniaudio_player.c            # Master native player coordinator & lifecycle
│   ├── map_common.h                  # Common macros, alignment, and atomic primitives
│   ├── map_seqlock.h                 # Cache-line aligned lock-free atomic sequence lock
│   ├── map_sniffer.h / .c            # Stream format, ID3v2, Xing, and Ogg sniffers
│   ├── map_buffer.h / .c             # Unified tripartite buffer (Head/Ring/Tail)
│   ├── map_source.h / .c             # SPSC ring buffer & Sonic decoding data source
│   ├── map_dsp.h / .c                # Master DSP node, EQ biquads, crossfeed, & limiter
│   ├── map_reverb.h / .c             # Freeverb algorithmic stereo reverb implementation
│   ├── map_silence.h / .c            # Real-time silence detection & edge trimming
│   ├── map_analysis.h / .c           # Offline single-pass ITU-R BS.1770 LUFS analyzer
│   ├── map_event_dispatcher.h / .c   # Double-buffered reactive event dispatcher
│   ├── map_device.h / .c             # Hardware audio device enumeration & routing
│   ├── map_wasm_bridge.h / .c        # WebAssembly bridge interface without int64 types
│   ├── decoders/                     # Bundled standalone audio decoders
│   │   ├── aac/                      # AAC decoder wrapper
│   │   ├── alac/                     # ALAC (Apple Lossless) decoder
│   │   ├── helix-aac/                # Helix AAC fixed-point decoder
│   │   ├── libogg/                   # Ogg bitstream encapsulation
│   │   ├── libopus/                  # Opus interactive speech & audio decoder
│   │   ├── libvorbis/                # Vorbis general-purpose audio decoder
│   │   ├── minimp4/                  # Lightweight MP4/M4A demuxer
│   │   └── stb_vorbis.c              # stb_vorbis single-file decoder
│   └── sonic/                        # Sonic time-stretching & pitch modification
│       ├── sonic.h
│       └── sonic.c
└── tools/
    └── build_wasm.dart               # Emscripten compilation script for WASM binary
```
