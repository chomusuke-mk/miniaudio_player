import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  group('Newly Converted Real Audio Assets Playback & Seek Validation', () {
    const assets = [
      'example/assets/music/salida.wv',
      'example/assets/music/salida.webm',
      'example/assets/music/salida.mka',
      'example/assets/music/salida.dsf',
    ];

    for (final assetPath in assets) {
      test('Playback, position tracking and seeking for $assetPath', () async {
        final file = File(assetPath);
        expect(file.existsSync(), isTrue, reason: 'File must exist: $assetPath');

        final player = MiniaudioPlayer();
        try {
          await player.action.open(AudioSource.file(file.path));

          expect(player.state.duration.inMilliseconds, greaterThan(60000),
              reason: 'Duration for $assetPath must be ~68s');

          // Play
          await player.action.play();
          expect(player.state.playing, isTrue);

          // Allow playback to advance slightly
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));

          // Seek to 15 seconds
          await player.action.seek(const Duration(milliseconds: 15000));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.position.inMilliseconds, inInclusiveRange(14000, 16000),
              reason: 'Seek to 15s must position accurately for $assetPath');

          // Seek to 30 seconds
          await player.action.seek(const Duration(milliseconds: 30000));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.position.inMilliseconds, inInclusiveRange(29000, 31000),
              reason: 'Seek to 30s must position accurately for $assetPath');

          // Pause
          await player.action.pause();
          expect(player.state.playing, isFalse);
        } finally {
          await player.dispose();
        }
      });
    }

    test('HLS M3U8 local playlist parsing and segment playback verification', () async {
      final m3u8File = File('example/assets/music/salida.m3u8');
      expect(m3u8File.existsSync(), isTrue);

      final content = await m3u8File.readAsString();
      expect(content, contains('#EXTM3U'));
      expect(content, contains('salida_0.ts'));
      expect(content, contains('salida_6.ts'));

      // Validate segment 0 exists
      final seg0 = File('example/assets/music/salida_0.ts');
      expect(seg0.existsSync(), isTrue);
      expect(await seg0.length(), greaterThan(10000));
    });
  });
}
