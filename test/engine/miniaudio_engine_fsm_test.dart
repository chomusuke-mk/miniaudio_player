import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/concurrency_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File track1File;
  late File track2File;
  late File track3File;
  late File track4File;
  late File track5File;
  late File track6File;

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
    // Use 10.0-second fixture files for reproducible FSM testing
    track1File = File('test/fixtures/test_24bit_stereo.wav');
    track2File = File('test/fixtures/cbr_noxing.mp3');
    track3File = File('test/fixtures/test_24bit_stereo.wav');
    track4File = File('test/fixtures/cbr_noxing.mp3');
    track5File = File('test/fixtures/test_24bit_stereo.wav');
    track6File = File('test/fixtures/cbr_noxing.mp3');
  });

  group('FSM Scenario 1: Rapid next() -> previous() during Manual Crossfade',
      () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(seconds: 2),
            manualDuration: const Duration(seconds: 2),
            curve: CrossfadeCurve.linear,
          ),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
      'next() -> previous() within 100ms cancels crossfade, steps back to track 1, and leaves exactly one active deck',
      () async {
        await engine.action.setQueue([
          AudioSource(track1File.path, data: 'Track 1'),
          AudioSource(track2File.path, data: 'Track 2'),
        ]);

        await engine.action.play();
        expect(engine.state.isPlaying, isTrue);
        expect(engine.state.currentIndex, equals(0));

        // Wait for Track 1 to make observable audio progress (> 1s).
        await waitForAudioProgress(
          engine,
          minDelta: const Duration(milliseconds: 1050),
        );
        expect(engine.state.position.inMilliseconds, greaterThan(1000));

        // 1. User calls next() -> starts manual crossfade to Track 2
        final nextFuture = engine.action.next();
        // Wait via stream until crossfade engages on Track 2.
        await awaitStateOrStream<bool>(
          stream: engine.stream.isCrossfading,
          current: () => engine.state.isCrossfading,
          predicate: (v) => v,
        );
        await awaitStateOrStream<int?>(
          stream: engine.stream.currentIndex,
          current: () => engine.state.currentIndex,
          predicate: (idx) => idx == 1,
        );
        expect(engine.state.isCrossfading, isTrue);
        expect(engine.state.currentIndex, equals(1));

        // 2. Immediately call previous() while on Track 2 (position < 3s threshold)
        final prevFuture = engine.action.previous();
        await Future.wait([nextFuture, prevFuture]);

        // After previous settles:
        expect(engine.state.currentIndex, equals(0));
        expect(engine.state.currentItem?.data, equals('Track 1'));
        expect(engine.state.isPlaying, isTrue);

        // Wait via stream for any active transition to finish settling.
        await awaitStateOrStream<bool>(
          stream: engine.stream.isCrossfading,
          current: () => engine.state.isCrossfading,
          predicate: (v) => !v,
        );

        // Final Invariant Validation:
        // - Exactly one deck active (state.isPlaying == true, volume == masterVolume)
        expect(engine.state.isPlaying, isTrue);
        expect(engine.state.volume, closeTo(1.0, 1e-4));
        expect(engine.state.playbackState, equals(PlaybackState.playing));
        expect(engine.state.isCrossfading, isFalse);
      },
    );
  });

  group(
      'FSM Scenario 2: Rapid Transitions during Automatic Crossfade (autoCrossfading)',
      () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(seconds: 2),
            manualDuration: const Duration(milliseconds: 500),
            curve: CrossfadeCurve.linear,
          ),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
      'Case A: previous() during autoCrossfading aborts tentative crossfade and seeks to 0:00 because pos > 3s',
      () async {
        await engine.action.setQueue([
          AudioSource(track1File.path, data: 'Track 1'),
          AudioSource(track2File.path, data: 'Track 2'),
        ]);

        await engine.action.play();
        await awaitStateOrStream<bool>(
          stream: engine.stream.isPlaying,
          current: () => engine.state.isPlaying,
          predicate: (v) => v,
        );
        await awaitStateOrStream<Duration?>(
          stream: engine.stream.duration,
          current: () => engine.state.duration,
          predicate: (d) => d != null && d > Duration.zero,
        );

        // Seek Track 1 near the end to enter the auto-crossfade window (duration is 10.0s, crossfade is 2.0s -> seek to 8.5s)
        await engine.action.seek(const Duration(milliseconds: 8500));
        await awaitStateOrStream<bool>(
          stream: engine.stream.isCrossfading,
          current: () => engine.state.isCrossfading,
          predicate: (v) => v,
        );

        // Engine should have entered crossfading
        expect(engine.state.isCrossfading, isTrue);
        expect(engine.state.currentIndex, equals(0)); // Queue still on Track 1!

        // User presses previous()
        await engine.action.previous();

        // Should revert tentative transition and restart Track 1 from 0:00 because pos was 8.5s > 3s
        expect(engine.state.currentIndex, equals(0));
        expect(engine.state.currentItem?.data, equals('Track 1'));
        expect(engine.state.playbackState, equals(PlaybackState.playing));
        expect(engine.state.isCrossfading, isFalse);
        expect(engine.state.position.inMilliseconds, lessThan(1000));
        expect(engine.state.volume, closeTo(1.0, 1e-4));
      },
    );

    test(
      'Case B: next() during autoCrossfading promotes tentative fade into manualCrossfading without reopening Track 2',
      () async {
        await engine.action.setQueue([
          AudioSource(track1File.path, data: 'Track 1'),
          AudioSource(track2File.path, data: 'Track 2'),
        ]);

        await engine.action.play();
        await awaitStateOrStream<bool>(
          stream: engine.stream.isPlaying,
          current: () => engine.state.isPlaying,
          predicate: (v) => v,
        );
        await awaitStateOrStream<Duration?>(
          stream: engine.stream.duration,
          current: () => engine.state.duration,
          predicate: (d) => d != null && d > Duration.zero,
        );
        // Seek into auto-crossfade window (duration is 10.0s, crossfade is 2.0s -> seek to 8.5s)
        await engine.action.seek(const Duration(milliseconds: 8500));
        await awaitStateOrStream<bool>(
          stream: engine.stream.isCrossfading,
          current: () => engine.state.isCrossfading,
          predicate: (v) => v,
        );

        expect(engine.state.isCrossfading, isTrue);
        expect(engine.state.currentIndex, equals(0));

        // User presses next() -> promotes auto to manual
        await engine.action.next();

        // Queue now committed to Track 2, still playing
        expect(engine.state.currentIndex, equals(1));
        expect(engine.state.currentItem?.data, equals('Track 2'));
        expect(engine.state.isPlaying, isTrue);

        // Wait for manualDuration (500ms) transition to complete via stream
        await awaitStateOrStream<bool>(
          stream: engine.stream.isCrossfading,
          current: () => engine.state.isCrossfading,
          predicate: (v) => !v,
        );

        expect(engine.state.playbackState, equals(PlaybackState.playing));
        expect(engine.state.isCrossfading, isFalse);
        expect(engine.state.currentIndex, equals(1));
        expect(engine.state.isPlaying, isTrue);
      },
    );
  });

  group('FSM Scenario 3: Concurrent Burst of 5 next() calls without await', () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(milliseconds: 50),
            manualDuration: const Duration(milliseconds: 50),
          ),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'burst of 5 un-awaited next() executes in FIFO order with zero zombie players',
        () async {
      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
        AudioSource(track2File.path, data: 'Track 2'),
        AudioSource(track3File.path, data: 'Track 3'),
        AudioSource(track4File.path, data: 'Track 4'),
        AudioSource(track5File.path, data: 'Track 5'),
        AudioSource(track6File.path, data: 'Track 6'),
      ]);

      await engine.action.play();
      expect(engine.state.currentIndex, equals(0));

      // Burst 5 next() calls concurrently
      await Future.wait([
        engine.action.next(),
        engine.action.next(),
        engine.action.next(),
        engine.action.next(),
        engine.action.next(),
      ]);

      // All 5 transitions serialized in strict order; cursor reaches index 5 (Track 6)
      expect(engine.state.currentIndex, equals(5));
      expect(engine.state.currentItem?.data, equals('Track 6'));

      // Wait via stream for final transition settlement
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (v) => !v,
      );

      expect(engine.state.isPlaying, isTrue);
      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.isCrossfading, isFalse);
      expect(engine.state.volume, closeTo(1.0, 1e-4));
    });
  });

  group('FSM Scenario 4: seek() during autoCrossfading vs manualCrossfading',
      () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(seconds: 2),
            manualDuration: const Duration(seconds: 2),
          ),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'seek() during autoCrossfading aborts auto crossfade and seeks on outgoing track',
        () async {
      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
        AudioSource(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();
      await awaitStateOrStream<bool>(
        stream: engine.stream.isPlaying,
        current: () => engine.state.isPlaying,
        predicate: (v) => v,
      );
      await awaitStateOrStream<Duration?>(
        stream: engine.stream.duration,
        current: () => engine.state.duration,
        predicate: (d) => d != null && d > Duration.zero,
      );
      // Enter auto crossfade window
      await engine.action.seek(const Duration(milliseconds: 8500));
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (v) => v,
      );

      expect(engine.state.isCrossfading, isTrue);

      // Seek back to 1.0 second on outgoing track
      await engine.action.seek(const Duration(seconds: 1));

      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.isCrossfading, isFalse);
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.position.inMilliseconds, closeTo(1000, 300));
      expect(engine.state.volume, closeTo(1.0, 1e-4));
    });

    test(
        'seek() during manualCrossfading settles on incoming track and seeks there',
        () async {
      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
        AudioSource(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();

      // Trigger manual crossfade
      final nextFut = engine.action.next();
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (v) => v,
      );
      await awaitStateOrStream<int?>(
        stream: engine.stream.currentIndex,
        current: () => engine.state.currentIndex,
        predicate: (idx) => idx == 1,
      );
      expect(engine.state.isCrossfading, isTrue);
      expect(engine.state.currentIndex,
          equals(1)); // Track 2 is incoming active deck

      // Seek to 3.0s during manual crossfade
      await engine.action.seek(const Duration(seconds: 3));
      await nextFut;

      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.isCrossfading, isFalse);
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.position.inMilliseconds, closeTo(3000, 400));
      expect(engine.state.volume, closeTo(1.0, 1e-4));
    });
  });

  group('FSM Scenario 5: End of Queue (completed) and Playback Restart', () {
    late MiniaudioPlayer<String> engine;

    setUp(() {
      engine = MiniaudioPlayer<String>(
        config: const PlayerConfig(
          crossfade: CrossfadeConfig.off(),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'reaches stopped on last track in LoopMode.off, and play() restarts from index 0',
        () async {
      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
      ]);

      await engine.action.play();
      await awaitStateOrStream<bool>(
        stream: engine.stream.isPlaying,
        current: () => engine.state.isPlaying,
        predicate: (v) => v,
      );
      await awaitStateOrStream<Duration?>(
        stream: engine.stream.duration,
        current: () => engine.state.duration,
        predicate: (d) => d != null && d > Duration.zero,
      );
      expect(engine.state.isPlaying, isTrue);

      // Seek near EOF to trigger natural track completion
      await engine.action.seek(const Duration(milliseconds: 9900));

      // Wait via stream for playback to hit EOF and reach stopped state (Case 2)
      await awaitStateOrStream<PlaybackState>(
        stream: engine.stream.playbackState,
        current: () => engine.state.playbackState,
        predicate: (s) => s.isStopped,
      );

      expect(engine.state.playbackState, equals(PlaybackState.stopped));
      expect(engine.state.isPlaying, isFalse);

      // Calling play() from stopped restarts queue from index 0
      await engine.action.play();
      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.isPlaying, isTrue);
      expect(engine.state.currentIndex, equals(0));
    });
  });

  group(
      'FSM Scenario 6: Seek and Crossfade Boundary Lifecycle & Zero-Crossfade Stability',
      () {
    late MiniaudioPlayer<String> engine;

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test(
        'seek to 2s with crossfade=0 maintains track 1 and does not switch prematurely',
        () async {
      engine = MiniaudioPlayer<String>(
        config: const PlayerConfig(
          crossfade: CrossfadeConfig.off(),
        ),
      );

      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
        AudioSource(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();
      // Go to track 2
      await engine.action.next();
      expect(engine.state.currentIndex, equals(1));

      // Go back to track 1
      await engine.action.previous();
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.isPlaying, isTrue);

      // Wait for observable audio progress then seek to 2 seconds
      await waitForAudioProgress(
        engine,
        minDelta: const Duration(milliseconds: 150),
      );
      await engine.action.seek(const Duration(seconds: 2));

      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.position.inMilliseconds, closeTo(2000, 350));
      expect(engine.state.volume, closeTo(1.0, 1e-4));

      // Let playback advance by >= 600ms; verify track 1 is still playing (no premature next())
      await waitForAudioProgress(
        engine,
        minDelta: const Duration(milliseconds: 600),
      );
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.isPlaying, isTrue);
      expect(engine.state.position.inMilliseconds, greaterThanOrEqualTo(2500));
    });

    test(
        'seeking back outside crossfade range aborts auto-crossfade and allows re-triggering',
        () async {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(seconds: 2),
            manualDuration: const Duration(seconds: 2),
          ),
        ),
      );

      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
        AudioSource(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();
      await awaitStateOrStream<bool>(
        stream: engine.stream.isPlaying,
        current: () => engine.state.isPlaying,
        predicate: (v) => v,
      );
      await awaitStateOrStream<Duration?>(
        stream: engine.stream.duration,
        current: () => engine.state.duration,
        predicate: (d) => d != null && d > Duration.zero,
      );

      // Seek into auto-crossfade zone (track is ~10s long)
      await engine.action.seek(const Duration(milliseconds: 8500));
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (v) => v,
      );

      expect(engine.state.isCrossfading, isTrue);
      expect(engine.state.currentIndex, equals(0));

      // Seek back outside the crossfade zone (to 1.5s)
      await engine.action.seek(const Duration(milliseconds: 1500));

      expect(engine.state.playbackState, equals(PlaybackState.playing));
      expect(engine.state.isCrossfading, isFalse);
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.position.inMilliseconds, closeTo(1500, 350));
      expect(engine.state.volume, closeTo(1.0, 1e-4));

      // Seek back into crossfade zone: it triggers again smoothly
      await engine.action.seek(const Duration(milliseconds: 8600));
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (v) => v,
      );

      expect(engine.state.isCrossfading, isTrue);
      expect(engine.state.currentIndex, equals(0));
    });

    test(
        'seeking within crossfade range preserves autoCrossfading phase and updates progress',
        () async {
      engine = MiniaudioPlayer<String>(
        config: PlayerConfig(
          crossfade: CrossfadeConfig(
            autoDuration: const Duration(seconds: 2),
            manualDuration: const Duration(seconds: 2),
          ),
        ),
      );

      await engine.action.setQueue([
        AudioSource(track1File.path, data: 'Track 1'),
        AudioSource(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();
      await awaitStateOrStream<bool>(
        stream: engine.stream.isPlaying,
        current: () => engine.state.isPlaying,
        predicate: (v) => v,
      );
      await awaitStateOrStream<Duration?>(
        stream: engine.stream.duration,
        current: () => engine.state.duration,
        predicate: (d) => d != null && d > Duration.zero,
      );

      // Seek into crossfade zone (8.2s out of ~10.0s)
      await engine.action.seek(const Duration(milliseconds: 8200));
      await awaitStateOrStream<bool>(
        stream: engine.stream.isCrossfading,
        current: () => engine.state.isCrossfading,
        predicate: (v) => v,
      );
      expect(engine.state.isCrossfading, isTrue);

      // Seek slightly further inside crossfade zone (9.0s)
      await engine.action.seek(const Duration(milliseconds: 9000));
      await drainBroadcastStreams();

      // Remains crossfading on outgoing track without error or premature skip
      expect(engine.state.isCrossfading, isTrue);
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.position.inMilliseconds, closeTo(9000, 350));
    });
  });
}
