<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/assets/banner.svg" alt="miniaudio_player banner" width="100%" />
</p>

# miniaudio_player

[![pub package](https://img.shields.io/pub/v/miniaudio_player.svg?logo=dart&color=blue)](https://pub.dev/packages/miniaudio_player)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-android%20|%20ios%20|%20macos%20|%20windows%20|%20linux-blue.svg)](https://pub.dev/packages/miniaudio_player)
[![Dart FFI](https://img.shields.io/badge/Dart-FFI%20Native%20Assets-0175C2.svg?logo=dart)](https://dart.dev/interop/c-interop)
[![Tests](https://img.shields.io/badge/tests-131%20passing-brightgreen.svg)](#)

An **ultra-low-resource, high-performance cross-platform audio player** for Flutter and Dart. Powered by the industry-proven [miniaudio](https://miniaud.io/) C engine, [Sonic DSP](https://github.com/waywardgeek/sonic), and **Dart Native Assets** with 100% pure FFI bindings.

Engineered from the ground up for high fidelity, sub-millisecond command latency, and zero UI stutter by leveraging miniaudio's dedicated real-time native OS audio threads.

---

![Screenshot with arrows pointing to features](https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/assets/feature_screenshot.png)

---

## ✨ Features at a Glance

- ⚡ **Ultra-Low Memory & CPU Overhead**: Direct native C memory management and zero-copy streaming ensure minimal battery and hardware resource drain.
- 🔀 **100% Pure FFI & Zero-Isolate Architecture**: Commands execute directly via FFI in sub-microseconds without message-passing latency or Dart VM isolate memory bloat. Heavy audio decoding, DSP, and hardware streaming run concurrently on native OS audio threads.
- 🎛️ **10-Band Parametric Equalizer**: Native biquad filtering with low-shelf, peaking, and high-shelf bands. Includes instant acoustic presets (_Rock_, _Pop_, _Jazz_, _Classical_, _Bass Boost_, _Flat_).
- 🚀 **High-Definition Pitch & Speed (Sonic DSP)**: Real-time time-stretching and independent pitch shifting with exceptional clarity and no phase distortion.
- 🎧 **Dynamic Audio Device Routing**: Real-time switching between audio outputs (speakers, headphones, Bluetooth) with automatic, crash-free recovery fallbacks.
- 📦 **Extensive Audio Codec Support**: Built-in native decoding for MP3, WAV, FLAC, OGG, Opus, AAC, M4A (AAC & ALAC), AIFF, W64, and more without external system dependencies.
- 🔄 **Dual State Paradigm**: Access synchronous instant state snapshots (`player.state.*`) or listen to reactive broadcast streams (`player.stream.*`).

---

## 🚀 Performance & Architecture

Unlike traditional audio plugins that bridge through Java/Kotlin or Objective-C/Swift platform channels with thread hops, serialization overhead, or heavy Dart Isolates, `miniaudio_player` communicates directly with compiled C native code:

```text
┌────────────────────────────────────────────────────────┐
│             Flutter UI / Dart Main Thread              │
│   • Direct FFI calls (< 1 µs latency)                  │
│   • Reactive broadcast streams (player.stream.*)       │
│   • Zero Dart VM Isolate memory overhead (~0 MB extra) │
└───────────────────────────┬────────────────────────────┘
                            │ Direct Dart:FFI Pointer Calls (< 1 µs)
┌───────────────────────────▼────────────────────────────┐
│            Native C Audio Core (miniaudio_player)      │
│   ┌──────────────────┐  ┌──────────────────────────┐   │
│   │ Sonic Time/Pitch │  │ 10-Band Biquad Equalizer │   │
│   └──────────────────┘  └──────────────────────────┘   │
└───────────────────────────┬────────────────────────────┘
                            │ High-Priority Native OS Audio Thread
┌───────────────────────────▼────────────────────────────┐
│            Direct OS Audio Device Backend              │
│     (WASAPI / CoreAudio / AAudio / ALSA / PulseAudio)  │
│   • Real-time decoding, resampling & DSP streaming     │
│   • Thread-safe NativeCallable.listener completion     │
└────────────────────────────────────────────────────────┘
```

1. **Zero UI Thread Blocking**: All heavy decoding, Sonic time-stretching, equalizer filtering, and audio output run on dedicated native OS audio threads with real-time priority. Commands (`play`, `pause`, `seek`, `setVolume`) execute in sub-microseconds without freezing Flutter frames.
2. **Zero Dart Isolate Overhead**: No secondary Dart VM isolates, no port serialization latency, and no background isolate memory bloat (~0 MB overhead in Dart).
3. **Deterministic Low Latency**: Buffer sizes can be customized down to device hardware periods (`bufferSize`) for low-latency feedback.
4. **Resilient Error Recovery**: Native audio route disconnections (e.g. unplugging headphones or system device switches) recover automatically without crashing or stalling.
5. **Ultra-Responsive Reactive Pipeline**: Native engine events (such as track completion) are dispatched safely to Dart via `NativeCallable.listener`. Synchronous state getters (`player.state.*`) reflect atomic native values instantaneously, while broadcast streams (`player.stream.*`) provide fluid 60/120fps UI progress updates without isolate message-passing lag.

---

## 📊 Platform Support Matrix

| Feature                              |      Android       |    iOS    |   macOS   |       Windows        |       Linux       |
| :----------------------------------- | :----------------: | :-------: | :-------: | :------------------: | :---------------: |
| **Native Audio Backend**             | AAudio / OpenSL ES | CoreAudio | CoreAudio | WASAPI / DirectSound | ALSA / PulseAudio |
| **Playback & Streaming**             |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |
| **10-Band Equalizer**                |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |
| **Speed (Time Stretch)**             |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |
| **Pitch Scaling**                    |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |
| **Background Isolate Instantiation** |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |
| **Built-in Device Enumeration**      |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |
| **Dynamic Device Switching**         |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |

> [!NOTE]
>
> ### 📱 Android Audio Device Discovery (Built-in via C JNI)
>
> While AAudio in native C does not expose hardware output enumeration, `miniaudio_player` includes a built-in C JNI subsystem that automatically interacts with Android's `AudioManager` and `AudioDeviceInfo`. It works completely out-of-the-box with **zero configuration**, **no MethodChannels**, and **no custom Kotlin code in MainActivity**.

---

## 📦 Supported Audio Formats

| Format                   | Extensions                               | Decoding Backend                |
| :----------------------- | :--------------------------------------- | :------------------------------ |
| **MPEG Audio**           | `.mp3`, `.mp2`, `.mp1`                   | Native miniaudio (`dr_mp3`)     |
| **Waveform Audio**       | `.wav`, `.bwf`, `.rifx`, `.w64`, `.rf64` | Native miniaudio (`dr_wav`)     |
| **FLAC**                 | `.flac`                                  | Native miniaudio (`dr_flac`)    |
| **Ogg Vorbis**           | `.ogg`, `.oga`                           | Native miniaudio (`stb_vorbis`) |
| **Opus**                 | `.opus`                                  | Native Opus decoder             |
| **Apple Lossless / AAC** | `.m4a`, `.aac`                           | Native ALAC / AAC decoder       |
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

### 1. Basic Playback

```dart
import 'package:miniaudio_player/miniaudio_player.dart';

void main() async {
  // Optional: configure global defaults before instantiating players
  MiniaudioPlayer.config(
    defaultBufferSize: 0, // 0 = native device default
    logLevel: MiniaudioLogLevel.info,
  );

  final player = MiniaudioPlayer();

  // Open an audio file and start playback immediately
  await player.action.open('/path/to/song.flac', autoPlay: true);

  // Playback controls
  await player.action.pause();
  await player.action.play();
  await player.action.seek(const Duration(seconds: 45));
  await player.action.setVolume(0.85);

  // Clean up resources when finished
  await player.dispose();
}
```

---

### 2. Reactive Streams & Synchronous State

`miniaudio_player` offers both real-time broadcast streams and synchronous getters for effortless UI binding:

```dart
// Synchronous snapshot:
print('Is Playing: ${player.state.playing}');
print('Current Position: ${player.state.position}');
print('Track Duration: ${player.state.duration}');
print('Bitrate: ${player.state.audioBitrate} kbps');

// Reactive streams:
player.stream.position.listen((position) {
  print('Position: $position');
});

player.stream.playing.listen((isPlaying) {
  print('State changed: ${isPlaying ? "Playing" : "Paused"}');
});

player.stream.completed.listen((isCompleted) {
  if (isCompleted) {
    print('Track finished playing!');
  }
});
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

### 3. Optional: Running Inside a Background Isolate

Because `miniaudio_player` executes all audio streaming, decoding, and DSP on native background OS threads, running `MiniaudioPlayer` directly on your main Flutter UI thread will **never** cause UI stutter or dropped frames.

However, because it has zero platform channel dependencies and relies 100% on pure Dart FFI, you can also seamlessly instantiate and run an audio player inside a standalone background Dart Isolate or headless background service (e.g. `audio_service`, `flutter_background_service`, or `Isolate.spawn`):

```dart
import 'dart:isolate';
import 'package:miniaudio_player/miniaudio_player.dart';

/// Entrypoint for a dedicated worker isolate
void audioWorkerIsolate(SendPort sendPort) async {
  final commandPort = ReceivePort();
  sendPort.send(commandPort.sendPort);

  // MiniaudioPlayer initializes seamlessly in any background isolate!
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
          await player.action.open(message['path'] as String, autoPlay: true);
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

void startIsolatedPlayer() async {
  final receivePort = ReceivePort();
  await Isolate.spawn(audioWorkerIsolate, receivePort.sendPort);

  final sendPort = await receivePort.first as SendPort;

  // Send commands to your isolated player
  sendPort.send({'command': 'open', 'path': '/music/ambient.opus'});
}
```

---

### 4. 10-Band Parametric Equalizer

Shape the audio frequency response in real time across 10 precision bands (`60Hz`, `170Hz`, `310Hz`, `600Hz`, `1kHz`, `3kHz`, `6kHz`, `12kHz`, `14kHz`, `16kHz`) from `-24.0 dB` to `+24.0 dB`:

```dart
// Apply built-in acoustic presets
await player.action.setEqualizer(Equalizer.rock);
await player.action.setEqualizer(Equalizer.bassBoost);
await player.action.setEqualizer(Equalizer.jazz);
await player.action.setEqualizer(Equalizer.flat);

// Or create a custom equalizer configuration
final customEq = Equalizer(
  hz60: 4.0,   // Boost sub-bass
  hz170: 2.5,  // Warmth
  hz1k: -1.0,  // Tame mid harshness
  hz14k: 3.0,  // Treble air
  hz16k: 4.0,  // High-shelf sparkle
);
await player.action.setEqualizer(customEq);
```

---

### 5. High-Fidelity Speed & Pitch Control

Adjust playback rate and pitch independently with Sonic DSP:

```dart
// Playback rate: 0.25x (slow) to 4.0x (fast) without changing pitch
await player.action.setRate(1.5);

// Pitch scaling: 0.5x to 2.0x without changing playback speed
await player.action.setPitch(1.2);
```

---

---

### 6. Audio Output Device Selection

List and switch output devices dynamically at runtime across all supported platforms (Android, macOS, Windows, Linux, and iOS) with **zero configuration** and **no MethodChannels**:

```dart
// Enumerate system playback devices (Android, macOS, Windows, Linux, iOS)
final devices = await MiniaudioPlayer.getAudioDevices();

for (final device in devices) {
  print('Device: ${device.name} (ID: ${device.id}, Default: ${device.isDefault})');
}

// Switch playback to a specific hardware device
await player.action.setDevice(devices[1]);

// Return to automatic system default routing
await player.action.setDevice(AudioDevice.auto);
```

#### Automatic Android JNI Device Discovery & Hot-Switching

On Android, `MiniaudioPlayer.getAudioDevices()` interacts directly with Android's native `AudioManager` via an embedded C JNI engine:

- **Zero Configuration**: No `MethodChannel`, no `package:jni`, and no custom Kotlin code in `MainActivity.kt`.
- **Autonomous JavaVM Resolution**: Automatically discovers the running `JavaVM` across all Android versions (Android 5.0 through Android 15+) using a multi-tier fallback strategy (`libnativehelper.so`, runtime memory scanning, and `JNI_OnLoad`).
- **Headless & Background Compatible**: Acquires application context reflectively via `ActivityThread.currentApplication()`, functioning seamlessly in Flutter UI threads, background isolates, or headless background services (`audio_service`).
- **Smart Hardware Classification**: Accurately detects earpieces, built-in speakers, wired headphones/headsets, USB audio, and dynamic Bluetooth accessories (distinguishing between A2DP high-fidelity audio and SCO headsets). Accurately resolves system defaults using Android 12+ `AudioManager.getCommunicationDevice()` and audio route heuristics (`isBluetoothA2dpOn`, `isWiredHeadsetOn`).
- **Resilient AAudio Hardware Rerouting**: When switching outputs or when Bluetooth devices connect/disconnect in real time, AAudio disconnect events (`AAUDIO_SERVICE_EVENT_DISCONNECTED`) are automatically handled and recreated without audio engine stall or crash.
- **Zero Memory Leaks**: Strict JNI local reference management (`DeleteLocalRef`), UTF string release (`ReleaseStringUTFChars`), and clean thread detachment.

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

---

### ⚖️ Permissive Licensing & Commercial Use

- **Unrestricted Commercial & Proprietary Usage**: Because `miniaudio_player` is distributed under the permissive **MIT License**, you are completely free to integrate, bundle, and distribute it in commercial, closed-source, proprietary, or open-source Flutter applications without any copyleft restrictions.
- **Third-Party Attribution**: All bundled third-party libraries retain their original author notices, copyrights, and permissive licenses (`MIT`, `MIT-0`, `Apache 2.0`, `BSD-3-Clause`, `CC0`, and `RPSL`).
