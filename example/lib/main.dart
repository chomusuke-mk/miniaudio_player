import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'app.dart';

export 'app.dart';
export 'models/audio_track.dart';
export 'widgets/painters/waveform_painter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MiniaudioPlayer.config(
    defaultBufferSize: 0,
    logLevel: MiniaudioLogLevel.verbose,
    defaultAudioDevice: AudioDevice.auto,
  );
  runApp(const MiniaudioPlayerExampleApp());
}
