import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'app/miniaudio_example_app.dart';

export 'app/miniaudio_example_app.dart';
export 'core/models/audio_track.dart';
export 'shared/painters/waveform_painter.dart';

/// Entrypoint initializing the native audio engine and launching
/// [MiniaudioPlayerExampleApp].
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MiniaudioPlayer.ensureInitialized();
  MiniaudioPlayer.config(
    defaultBufferSize: 0,
    logLevel: MiniaudioLogLevel.debug,
  );
  MapLogger.info('[MAIN] Launching MiniaudioPlayerExampleApp');

  runApp(const MiniaudioPlayerExampleApp());
}
