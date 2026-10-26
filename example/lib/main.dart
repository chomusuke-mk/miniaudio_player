import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'app.dart';

export 'app.dart';
export 'models/audio_track.dart';
export 'widgets/painters/waveform_painter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MiniaudioPlayer.config(
    assetLoader: (key) async {
      try {
        final byteData = await rootBundle.load(key);
        return byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
      } catch (_) {
        final fallback = key.startsWith('assets/')
            ? key.substring('assets/'.length)
            : 'assets/$key';
        final byteData = await rootBundle.load(fallback);
        return byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
      }
    },
    defaultBufferSize: 0,
    logLevel: MiniaudioLogLevel.verbose,
    defaultAudioDevice: AudioDevice.auto,
  );
  runApp(const MiniaudioPlayerExampleApp());
}
