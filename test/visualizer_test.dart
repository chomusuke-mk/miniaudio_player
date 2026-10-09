import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('Real-Time Audio Visualizer (10 Bands & Volume Metrics)', () {
    test('VisualizerData model correctly maps 10 bands and volume properties', () {
      final data = VisualizerData(
        bands: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0],
        rms: 0.55,
        peak: 0.95,
        left: 0.50,
        right: 0.60,
      );

      expect(data.hz31, closeTo(0.1, 1e-4));
      expect(data.hz63, closeTo(0.2, 1e-4));
      expect(data.hz125, closeTo(0.3, 1e-4));
      expect(data.hz250, closeTo(0.4, 1e-4));
      expect(data.hz500, closeTo(0.5, 1e-4));
      expect(data.hz1k, closeTo(0.6, 1e-4));
      expect(data.hz2k, closeTo(0.7, 1e-4));
      expect(data.hz4k, closeTo(0.8, 1e-4));
      expect(data.hz8k, closeTo(0.9, 1e-4));
      expect(data.hz16k, closeTo(1.0, 1e-4));
      expect(data.rms, equals(0.55));
      expect(data.peak, equals(0.95));
      expect(data.left, equals(0.50));
      expect(data.right, equals(0.60));

      final empty = VisualizerData.empty();
      expect(empty.bands.length, equals(10));
      expect(empty.bands.every((b) => b == 0.0), isTrue);
      expect(empty.rms, equals(0.0));
      expect(empty.peak, equals(0.0));
    });

    test('Visualizer is inactive by default and can be manually enabled/disabled', () async {
      final player = MiniaudioPlayer();
      addTearDown(() => player.dispose());

      expect(player.state.visualizerEnabled, isFalse);
      expect(player.state.visualizer.rms, equals(0.0));

      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);
    });

    test('Listening to player.stream.visualizer automatically activates visualizer on-demand', () async {
      final player = MiniaudioPlayer();
      addTearDown(() => player.dispose());

      expect(player.state.visualizerEnabled, isFalse);

      final sub = player.stream.visualizer.listen((_) {});
      // Waiting brief moment for onListen callback
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.state.visualizerEnabled, isTrue);

      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.state.visualizerEnabled, isFalse);
    });

    test('Plays audio file and emits reactive visualizer data with active frequency bands', () async {
      final mp3 = resolveAsset('example/assets/music/salida.mp3');
      expect(mp3.existsSync(), isTrue, reason: 'salida.mp3 test asset must exist');

      final player = MiniaudioPlayer();
      addTearDown(() => player.dispose());

      final emittedData = <VisualizerData>[];
      final sub = player.stream.visualizer.listen((data) {
        emittedData.add(data);
      });
      addTearDown(() => sub.cancel());

      await player.action.open(mp3.path, autoPlay: true);

      // Allow audio to stream and compute multiple buffer frames
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(player.state.playing, isTrue);
      expect(emittedData, isNotEmpty);

      // Check that during active music playback, RMS and bands are active
      final activeFrames = emittedData.where((d) => d.rms > 0.001).toList();
      expect(activeFrames, isNotEmpty, reason: 'Visualizer should produce non-zero energy during playback');

      final latest = activeFrames.last;
      expect(latest.peak, greaterThan(0.0));
      expect(latest.left, greaterThan(0.0));
      expect(latest.right, greaterThan(0.0));
      expect(latest.bands.length, equals(10));

      // Synchronous state getter should also reflect active values
      final stateVis = player.state.visualizer;
      expect(stateVis.bands.length, equals(10));

      // Pause or stop should reset or zero visualizer
      await player.action.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(player.state.visualizer.rms, equals(0.0));
    });
  });
}
