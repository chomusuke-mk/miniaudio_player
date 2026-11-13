import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  setUp(() {
    MiniaudioPlayer.resetGlobalConfig();
  });

  tearDown(() {
    MiniaudioPlayer.resetGlobalConfig();
  });

  group('Device and Action Diagnostic Logging Tests', () {
    final testWavFile = File('test/fixtures/salida.wav');

    test(
        'Verbose logging captures precise timing on pause, seek, and setOutputs',
        () async {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      final logs = <String>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, message) {
        logs.add('[$level] $message');
      };

      final player = MiniaudioPlayer(
        queue: [AudioSource(testWavFile.path)],
        config: const PlayerConfig(pauseOnDeviceChange: true),
      );

      try {
        await player.action.play();

        // Test seek diagnostics
        await player.action.seek(const Duration(milliseconds: 1000));
        expect(
          logs.any((l) => l.contains(
              '[ACTION:SEEK] native rust.seek() returned successfully in')),
          isTrue,
          reason: 'Should log exact seek duration in milliseconds',
        );

        // Test pause diagnostics
        await player.action.pause();
        expect(
          logs.any((l) => l.contains(
              '[ACTION:PAUSE] native rust.pause() returned successfully in')),
          isTrue,
          reason: 'Should log exact pause duration in milliseconds',
        );

        // Test setOutputs diagnostics
        await player.action.setOutputs({});
        expect(
          logs.any((l) => l.contains(
              '[ACTION:SET_OUTPUTS] native rust.setOutputs() returned successfully in')),
          isTrue,
          reason: 'Should log exact setOutputs duration in milliseconds',
        );

        // Restore output
        await player.action.setOutputs({const AudioOutput()});
        expect(
          logs.any((l) => l.contains(
              '[ACTION:SET_OUTPUTS] setOutputs() requested with 1 outputs')),
          isTrue,
        );
      } finally {
        await player.dispose();
      }
    });

    test('MiniaudioPlayer logs device change event dispatching', () async {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      final logs = <String>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, message) {
        logs.add('[$level] $message');
      };

      final player = MiniaudioPlayer(
        queue: [AudioSource(testWavFile.path)],
        config: const PlayerConfig(pauseOnDeviceChange: true),
      );

      try {
        // Toggle pauseOnDeviceChange and verify action log
        await player.action.setPauseOnDeviceChange(false);

        expect(
          logs.any((l) => l.contains(
              '[ACTION:SET_PAUSE_ON_DEVICE_CHANGE] setPauseOnDeviceChange(false) requested')),
          isTrue,
        );
      } finally {
        await player.dispose();
      }
    });
  });
}
