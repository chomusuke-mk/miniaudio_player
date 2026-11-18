import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('Real-Time Audio Visualizer (10 Bands & Volume Metrics)', () {
    test('VisualizerData model correctly maps 10 bands and volume properties',
        () {
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

    final dummySource = AudioSource('example/assets/music/tripartite/eof_chirp.mp3');

    test(
        'Visualizer is inactive by default and can be manually enabled/disabled',
        () async {
      final player = MiniaudioPlayer(queue: [dummySource]);
      addTearDown(() => player.dispose());

      expect(player.state.visualizerEnabled, isFalse);
      expect(player.state.visualizer.rms, equals(0.0));

      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);
    });

    test(
        'Listening to player.stream.visualizer does NOT auto-enable visualizer; requires action.setVisualizerEnabled(true)',
        () async {
      final player = MiniaudioPlayer(queue: [dummySource]);
      addTearDown(() => player.dispose());

      expect(player.state.visualizerEnabled, isFalse);

      final sub = player.stream.visualizer.listen((_) {});
      expect(player.state.visualizerEnabled, isFalse);

      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      await sub.cancel();
      expect(player.state.visualizerEnabled, isTrue);

      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);
    });

    test(
        'Plays audio file and emits reactive visualizer data with active frequency bands',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue,
          reason: '01_Apex_Momentum.mp3 test asset must exist');

      final player = MiniaudioPlayer(queue: [AudioSource(mp3.path)]);
      addTearDown(() => player.dispose());

      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      final emittedData = <VisualizerData>[];
      final sub = player.stream.visualizer.listen((data) {
        emittedData.add(data);
      });
      addTearDown(() => sub.cancel());

      await player.action.play();

      // Wait until real FFT visualizer metrics arrive from live audio frames
      await awaitStateOrStream<VisualizerData>(
        stream: player.stream.visualizer,
        current: () => player.state.visualizer,
        predicate: (d) => d.rms > 0.001,
        timeout: const Duration(seconds: 3),
        reason: 'Visualizer failed to emit non-zero RMS metrics during playback',
      );

      expect(player.state.isPlaying, isTrue);
      expect(emittedData, isNotEmpty);

      // Check that during active music playback, RMS and bands are active
      final activeFrames = emittedData.where((d) => d.rms > 0.001).toList();
      expect(activeFrames, isNotEmpty,
          reason: 'Visualizer should produce non-zero energy during playback');

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
      await awaitStateOrStream<VisualizerData>(
        stream: player.stream.visualizer,
        current: () => player.state.visualizer,
        predicate: (d) => d.rms == 0.0,
        timeout: const Duration(seconds: 2),
        reason: 'Visualizer RMS should reset to 0.0 on stop',
      );
      expect(player.state.visualizer.rms, equals(0.0));
    });

    test(
        'setVisualizerEnabled controls visualizer DSP and emits empty visualizer when disabled',
        () async {
      final player = MiniaudioPlayer(queue: [dummySource]);
      addTearDown(() => player.dispose());

      expect(player.state.visualizerEnabled, isFalse);

      // 1. Enable via action
      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      // 2. Disable via action
      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);

      // 3. Verify visualizer state is empty and disabled
      expect(player.state.visualizer.rms, equals(0.0));
      expect(player.state.visualizer.bands.every((b) => b == 0.0), isTrue);

      // 4. Force-enable again
      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      // 5. Force-disable again
      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);
    });

    test('stream.visualizerEnabled emits boolean transitions on action calls',
        () async {
      final player = MiniaudioPlayer(queue: [dummySource]);
      addTearDown(() => player.dispose());

      final enabledStates = <bool>[];
      final sub = player.stream.visualizerEnabled.listen(enabledStates.add);
      addTearDown(() => sub.cancel());

      await player.action.setVisualizerEnabled(true);
      await player.action.setVisualizerEnabled(false);
      await player.action.setVisualizerEnabled(true);
      await player.action.setVisualizerEnabled(false);

      expect(enabledStates, equals([true, false, true, false]));
    });

    test(
        'Playback visualizer stream receives empty data when force-disabled mid-playback',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      final player = MiniaudioPlayer(queue: [AudioSource(mp3.path)]);
      addTearDown(() => player.dispose());

      await player.action.setVisualizerEnabled(true);

      final emitted = <VisualizerData>[];
      final sub = player.stream.visualizer.listen((data) {
        emitted.add(data);
      });
      addTearDown(() => sub.cancel());

      await player.action.play();
      await awaitStateOrStream<VisualizerData>(
        stream: player.stream.visualizer,
        current: () => player.state.visualizer,
        predicate: (d) => d.rms > 0.001,
        timeout: const Duration(seconds: 3),
        reason: 'Visualizer failed to emit non-zero RMS metrics',
      );

      expect(player.state.visualizerEnabled, isTrue);
      expect(emitted.any((d) => d.rms > 0.001), isTrue);

      // Force-disable mid-playback
      await player.action.setVisualizerEnabled(false);
      await awaitStateOrStream<VisualizerData>(
        stream: player.stream.visualizer,
        current: () => player.state.visualizer,
        predicate: (d) => d.rms == 0.0 && d.bands.every((b) => b == 0.0),
        timeout: const Duration(seconds: 2),
        reason: 'Disabling visualizer should emit empty visualizer snapshot',
      );
      await drainBroadcastStreams();

      expect(player.state.visualizerEnabled, isFalse);
      expect(player.state.visualizer.rms, equals(0.0));
      expect(emitted.last.rms, equals(0.0));
      expect(emitted.last.bands.every((b) => b == 0.0), isTrue);
    });

    test(
        'visualizerEnabled broadcast stream and state snapshot maintain parity',
        () async {
      final player = MiniaudioPlayer(queue: [dummySource]);
      addTearDown(() => player.dispose());

      final enabledStates = <bool>[];
      final subEnabled = player.stream.visualizerEnabled.listen((v) {
        enabledStates.add(v);
      });
      addTearDown(() => subEnabled.cancel());

      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);

      await player.action.setVisualizerEnabled(true);
      expect(player.state.visualizerEnabled, isTrue);

      await player.action.setVisualizerEnabled(false);
      expect(player.state.visualizerEnabled, isFalse);

      await drainBroadcastStreams(8);
      expect(enabledStates, equals([true, false, true, false]));
    });
  });
}
