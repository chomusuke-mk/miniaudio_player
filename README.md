<p align="center">
  <img src="https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/assets/banner_placeholder.png" alt="miniaudio_player banner" width="100%" />
</p>

# miniaudio_player

# NOT READY YET: This version is a pre-release alpha. Expect breaking changes, incomplete features, and bugs. Please report issues on GitHub

[![pub package](https://img.shields.io/pub/v/miniaudio_player.svg?logo=dart&color=blue)](https://pub.dev/packages/miniaudio_player)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![Platform](https://img.shields.io/badge/platform-android%20|%20ios%20|%20macos%20|%20windows%20|%20linux-blue.svg)](https://pub.dev/packages/miniaudio_player)
[![Dart FFI](https://img.shields.io/badge/Dart-FFI%20Native%20Assets-0175C2.svg?logo=dart)](https://dart.dev/interop/c-interop)
[![Tests](https://img.shields.io/badge/tests-131%20passing-brightgreen.svg)](#)

An **ultra-low-resource, high-performance cross-platform audio player** for Flutter and Dart. Powered by the industry-proven [miniaudio](https://miniaud.io/) C engine, [Sonic DSP](https://github.com/waywardgeek/sonic), and **Dart Native Assets** with 100% pure FFI bindings.

Engineered from the ground up for high fidelity, low latency, and zero UI stutter by delegating heavy decoding and audio processing to isolated background pipelines.

---

![Screenshot with arrows pointing to features](https://raw.githubusercontent.com/chomusuke-mk/miniaudio_player/main/assets/feature_screenshot.png)

---

## ✨ Features at a Glance

- ⚡ **Ultra-Low Memory & CPU Overhead**: Direct native C memory management and zero-copy streaming ensure minimal battery and hardware resource drain.
- 🔀 **100% Pure FFI & Isolate-Friendly**: No platform channels (`MethodChannel`) in the core audio pipeline. You can instantiate, run, and control `MiniaudioPlayer` directly inside **background Isolates**, worker threads, or headless background audio services.
- 🎛️ **10-Band Parametric Equalizer**: Native biquad filtering with low-shelf, peaking, and high-shelf bands. Includes instant acoustic presets (_Rock_, _Pop_, _Jazz_, _Classical_, _Bass Boost_, _Flat_).
- 🚀 **High-Definition Pitch & Speed (Sonic DSP)**: Real-time time-stretching and independent pitch shifting with exceptional clarity and no phase distortion.
- 🎧 **Dynamic Audio Device Routing**: Real-time switching between audio outputs (speakers, headphones, Bluetooth) with automatic, crash-free recovery fallbacks.
- 📦 **Extensive Audio Codec Support**: Built-in native decoding for MP3, WAV, FLAC, OGG, Opus, AAC, M4A (AAC & ALAC), AIFF, W64, and more without external system dependencies.
- 🔄 **Dual State Paradigm**: Access synchronous instant state snapshots (`player.state.*`) or listen to reactive broadcast streams (`player.stream.*`).

---

## 🚀 Performance & Architecture

Unlike traditional audio plugins that bridge through Java/Kotlin or Objective-C/Swift platform channels with thread hops and serialization overhead, `miniaudio_player` communicates directly with compiled C native code:

```text
┌────────────────────────────────────────────────────────┐
│                      Flutter UI                        │
│             (Smooth 60/120 FPS Rendering)              │
└───────────────────────────┬────────────────────────────┘
                            │ SendPort / ReceivePort
┌───────────────────────────▼────────────────────────────┐
│              Dedicated Background Isolate              │
│            MiniaudioPlayer Command Processor           │
└───────────────────────────┬────────────────────────────┘
                            │ Direct Dart:FFI Pointer Calls
┌───────────────────────────▼────────────────────────────┐
│               Native C Audio Core (miniaudio)          │
│   ┌──────────────────┐  ┌──────────────────────────┐   │
│   │ Sonic Time/Pitch │  │ 10-Band Biquad Equalizer │   │
│   └──────────────────┘  └──────────────────────────┘   │
│               Direct OS Audio Device Backend           │
│      (WASAPI / CoreAudio / AAudio / ALSA / Pulse)      │
└────────────────────────────────────────────────────────┘
```

1. **Zero UI Thread Blocking**: File reading, decoding, seeking, and parameter adjustments happen asynchronously off the main UI thread.
2. **Deterministic Latency**: Buffer sizes can be customized down to device hardware periods (`bufferSize`) for low-latency feedback.
3. **Resilient Error Recovery**: Native audio route disconnections (e.g. unplugging headphones or system device switches) recover automatically without crashing or stalling.

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
| **Built-in Device Enumeration**      |   ⚠️ _See note_    |    ✅     |    ✅     |          ✅          |        ✅         |
| **Dynamic Device Switching**         |         ✅         |    ✅     |    ✅     |          ✅          |        ✅         |

> [!IMPORTANT]
>
> ### 📱 Note on Android Audio Device Enumeration
>
> On desktop platforms and iOS/macOS, `miniaudio` directly queries the native audio system APIs to enumerate available output devices. However, on Android, native C/AAudio does not expose hardware output enumeration. Device discovery on Android strictly requires accessing Java/Kotlin Android SDK APIs (`android.media.AudioManager` and `AudioDeviceInfo`).
>
> To preserve `miniaudio_player` as a **100% pure Dart FFI package** that can run inside raw Dart Isolates, background services, and CLI tools without depending on a Flutter Activity or engine attachment, **Android device enumeration is intentionally left to the host application**.
>
> Switching audio devices via `player.action.setDevice(...)` **is fully supported on Android** once you pass the target device's integer ID string. See [Listing Devices on Android](#-listing-devices-on-android) below for a ready-to-use implementation.

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
  await player.action.open('/path/to/song.flac', autoplay: true);

  // Playback controls
  await player.action.pause();
  await player.action.play();
  await player.action.seek(const Duration(seconds: 45));
  await player.action.setVolume(0.85);

  // Clean up resources when finished
  await player.action.dispose();
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

### 3. Running Inside a Background Isolate

Because `miniaudio_player` has no platform channel dependencies, you can run an audio player entirely inside a standalone background Dart Isolate or headless background service (e.g. `audio_service`, `flutter_background_service`, or `Isolate.spawn`):

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
          await player.action.open(message['path'] as String, autoplay: true);
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
          await player.action.dispose();
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

### 6. Audio Output Device Selection

List and switch output devices at runtime:

```dart
// Enumerate system playback devices (macOS, Windows, Linux, iOS)
final devices = await MiniaudioPlayer.getAudioDevices();

for (final device in devices) {
  print('Device: ${device.name} (ID: ${device.id}, Default: ${device.isDefault})');
}

// Switch to a specific device
await player.action.setDevice(devices[1]);

// Return to automatic system default routing
await player.action.setDevice(AudioDevice.auto);
```

---

## 📱 Listing Devices on Android

Because Android device discovery requires the Android `AudioManager` Java/Kotlin SDK, you can quickly expose it to Flutter using a simple `MethodChannel` in your host application:

### Step 1: In your Kotlin `MainActivity.kt`

```kotlin
package com.example.yourapp

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.yourapp/devices"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getAudioDevices") {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    val resultList = mutableListOf<Map<String, Any>>()

                    for (device in devices) {
                        // Filter out non-media outputs (earpiece, telephony, screencast submix)
                        if (device.type == AudioDeviceInfo.TYPE_TELEPHONY ||
                            device.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE ||
                            device.type == AudioDeviceInfo.TYPE_REMOTE_SUBMIX) {
                            continue
                        }

                        resultList.add(mapOf(
                            "id" to device.id.toString(),
                            "name" to (device.productName?.toString() ?: "Audio Device"),
                            "type" to device.type
                        ))
                    }
                    result.success(resultList)
                } else {
                    result.notImplemented()
                }
            }
    }
}
```

### Step 2: In your Flutter code

```dart
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

const _deviceChannel = MethodChannel('com.example.yourapp/devices');

Future<List<AudioDevice>> fetchDevices() async {
  if (Platform.isAndroid) {
    final rawList = await _deviceChannel.invokeListMethod<Map>('getAudioDevices');
    final devices = <AudioDevice>[AudioDevice.auto];

    if (rawList != null) {
      for (final map in rawList) {
        devices.add(AudioDevice(
          id: map['id'].toString(),
          name: map['name'].toString(),
          isDefault: false,
          isAuto: false,
          type: map['type'] as int?,
        ));
      }
    }
    return devices;
  }

  // On desktop / iOS, use native built-in discovery:
  return MiniaudioPlayer.getAudioDevices();
}

// Switching works identically across all platforms!
void switchAudioDevice(AudioDevice device) async {
  await player.action.setDevice(device);
}
```

---

## 🤝 Contributing

Contributions, bug reports, and feature requests are very welcome!
Feel free to open an issue or submit a pull request on [GitHub](https://github.com/chomusuke-mk/miniaudio_player).

---

## 📄 License & Third-Party Acknowledgements

This project is licensed under the **GNU General Public License v3.0 (GPL-v3)** - see the [LICENSE](LICENSE) file for complete details.

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

### ⚖️ GPL-v3 Licensing Notes & Considerations

- **Inbound Compatibility**:
  - The permissive licenses (**MIT**, **MIT-0**, **Public Domain / CC0**, and **BSD 3-Clause**) are 100% compatible with GPL-v3 and can be combined into a GPL-v3 covered work.
  - **Apache 2.0** (Sonic DSP) is explicitly compatible with GPL-v3 according to the Free Software Foundation (FSF).
  - **Helix AAC** (RPSL): In accordance with Section 7 of the GNU GPL-v3 (_Additional Permissions_), this project includes a linking permission allowing the program to be compiled and linked with the Helix AAC decoder under the RPSL.
- **Copyleft (Outbound Usage in Flutter Apps)**:
  - Because `miniaudio_player` is distributed under GPL-v3, applications that bundle and distribute this package must also make their complete source code available under GPL-v3.
  - If your Flutter application is free and open-source (GPL-compatible), you can use and distribute `miniaudio_player` with no restrictions.
  - Proprietary or closed-source commercial applications that cannot open-source their codebase should take this copyleft requirement into consideration.
