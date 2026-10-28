import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File track1File;
  late File track2File;
  late File track3File;
  late File track4File;
  late File track5File;
  late File track6File;

  setUpAll(() async {
    // Generate synthetic audio files for reproducible FSM testing
    track1File = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'fsm_track1.wav',
      frequencyHz: 440.0,
      durationSeconds: 6.0,
    );
    track2File = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'fsm_track2.wav',
      frequencyHz: 554.37,
      durationSeconds: 6.0,
    );
    track3File = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'fsm_track3.wav',
      frequencyHz: 659.25,
      durationSeconds: 6.0,
    );
    track4File = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'fsm_track4.wav',
      frequencyHz: 880.0,
      durationSeconds: 6.0,
    );
    track5File = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'fsm_track5.wav',
      frequencyHz: 987.77,
      durationSeconds: 6.0,
    );
    track6File = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'fsm_track6.wav',
      frequencyHz: 1174.66,
      durationSeconds: 6.0,
    );
  });

  tearDownAll(() async {
    await Future.wait([
      SyntheticAudioGenerator.cleanUp(track1File),
      SyntheticAudioGenerator.cleanUp(track2File),
      SyntheticAudioGenerator.cleanUp(track3File),
      SyntheticAudioGenerator.cleanUp(track4File),
      SyntheticAudioGenerator.cleanUp(track5File),
      SyntheticAudioGenerator.cleanUp(track6File),
    ]);
  });

  group('FSM Scenario 1: Rapid next() -> previous() during Manual Crossfade', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(seconds: 2),
          manualDuration: const Duration(seconds: 2),
          curve: CrossfadeCurve.linear,
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
        await engine.action.open([
          EngineItem.file(track1File.path, data: 'Track 1'),
          EngineItem.file(track2File.path, data: 'Track 2'),
        ]);

        await engine.action.play();
        expect(engine.state.playing, isTrue);
        expect(engine.state.currentIndex, equals(0));

        // Let track 1 play for 1.5 seconds
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(engine.state.position.inMilliseconds, greaterThan(1000));

        // 1. User calls next() -> starts manual crossfade to Track 2
        final nextFuture = engine.action.next();
        // Allow crossfade to begin and enter manualCrossfading phase
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(engine.state.phase, equals(EnginePhase.manualCrossfading));
        expect(engine.state.currentIndex, equals(1));

        // 2. < 100ms later, user calls previous() while on Track 2 (position < 3s threshold)
        final prevFuture = engine.action.previous();
        await Future.wait([nextFuture, prevFuture]);

        // After previous settles:
        expect(engine.state.currentIndex, equals(0));
        expect(engine.state.currentItem?.data, equals('Track 1'));
        expect(engine.state.playing, isTrue);

        // Allow any active transition to fully settle
        await Future<void>.delayed(const Duration(milliseconds: 2200));

        // Final Invariant Validation:
        // - Exactly one deck active (state.playing == true, volume == masterVolume)
        expect(engine.state.playing, isTrue);
        expect(engine.state.volume, closeTo(1.0, 1e-4));
        expect(engine.state.phase, equals(EnginePhase.playing));
      },
    );
  });

  group('FSM Scenario 2: Rapid Transitions during Automatic Crossfade (autoCrossfading)', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(seconds: 2),
          manualDuration: const Duration(milliseconds: 500),
          curve: CrossfadeCurve.linear,
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
        await engine.action.open([
          EngineItem.file(track1File.path, data: 'Track 1'),
          EngineItem.file(track2File.path, data: 'Track 2'),
        ]);

        await engine.action.play();

        // Seek Track 1 near the end to enter the auto-crossfade window (duration is 6.0s, crossfade is 2.0s -> seek to 4.5s)
        await engine.action.seek(const Duration(milliseconds: 4500));
        await Future<void>.delayed(const Duration(milliseconds: 250));

        // Engine should have entered autoCrossfading
        expect(engine.state.phase, equals(EnginePhase.autoCrossfading));
        expect(engine.state.currentIndex, equals(0)); // Queue still on Track 1!

        // User presses previous()
        await engine.action.previous();

        // Should revert tentative transition and restart Track 1 from 0:00 because pos was 4.5s > 3s
        expect(engine.state.currentIndex, equals(0));
        expect(engine.state.currentItem?.data, equals('Track 1'));
        expect(engine.state.phase, equals(EnginePhase.playing));
        expect(engine.state.position.inMilliseconds, lessThan(1000));
        expect(engine.state.volume, closeTo(1.0, 1e-4));
      },
    );

    test(
      'Case B: next() during autoCrossfading promotes tentative fade into manualCrossfading without reopening Track 2',
      () async {
        await engine.action.open([
          EngineItem.file(track1File.path, data: 'Track 1'),
          EngineItem.file(track2File.path, data: 'Track 2'),
        ]);

        await engine.action.play();
        // Seek into auto-crossfade window
        await engine.action.seek(const Duration(milliseconds: 4500));
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(engine.state.phase, equals(EnginePhase.autoCrossfading));
        expect(engine.state.currentIndex, equals(0));

        // User presses next() -> promotes auto to manual
        await engine.action.next();

        // Queue now committed to Track 2, phase is manualCrossfading
        expect(engine.state.currentIndex, equals(1));
        expect(engine.state.currentItem?.data, equals('Track 2'));
        expect(
          engine.state.phase == EnginePhase.manualCrossfading ||
              engine.state.phase == EnginePhase.playing,
          isTrue,
        );

        // Wait for manualDuration (500ms) to complete
        await Future<void>.delayed(const Duration(milliseconds: 700));

        expect(engine.state.phase, equals(EnginePhase.playing));
        expect(engine.state.currentIndex, equals(1));
        expect(engine.state.playing, isTrue);
      },
    );
  });

  group('FSM Scenario 3: Concurrent Burst of 5 next() calls without await', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(milliseconds: 50),
          manualDuration: const Duration(milliseconds: 50),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('burst of 5 un-awaited next() executes in FIFO order with zero zombie players', () async {
      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
        EngineItem.file(track2File.path, data: 'Track 2'),
        EngineItem.file(track3File.path, data: 'Track 3'),
        EngineItem.file(track4File.path, data: 'Track 4'),
        EngineItem.file(track5File.path, data: 'Track 5'),
        EngineItem.file(track6File.path, data: 'Track 6'),
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

      // Wait a moment for final transition settlement
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(engine.state.playing, isTrue);
      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.volume, closeTo(1.0, 1e-4));
    });
  });

  group('FSM Scenario 4: seek() during autoCrossfading vs manualCrossfading', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(seconds: 2),
          manualDuration: const Duration(seconds: 2),
        ),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('seek() during autoCrossfading aborts auto crossfade and seeks on outgoing track', () async {
      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
        EngineItem.file(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();
      // Enter auto crossfade window
      await engine.action.seek(const Duration(milliseconds: 4500));
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(engine.state.phase, equals(EnginePhase.autoCrossfading));

      // Seek back to 1.0 second on outgoing track
      await engine.action.seek(const Duration(seconds: 1));

      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.position.inMilliseconds, closeTo(1000, 300));
      expect(engine.state.volume, closeTo(1.0, 1e-4));
    });

    test('seek() during manualCrossfading settles on incoming track and seeks there', () async {
      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
        EngineItem.file(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();

      // Trigger manual crossfade
      final nextFut = engine.action.next();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(engine.state.phase, equals(EnginePhase.manualCrossfading));
      expect(engine.state.currentIndex, equals(1)); // Track 2 is incoming active deck

      // Seek to 3.0s during manual crossfade
      await engine.action.seek(const Duration(seconds: 3));
      await nextFut;

      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.currentIndex, equals(1));
      expect(engine.state.position.inMilliseconds, closeTo(3000, 400));
      expect(engine.state.volume, closeTo(1.0, 1e-4));
    });
  });

  group('FSM Scenario 5: End of Queue (completed) and Playback Restart', () {
    late MiniaudioEngine<String> engine;

    setUp(() {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: const CrossfadeConfig.off(),
      );
    });

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('reaches completed on last track in LoopMode.off, and play() restarts from index 0', () async {
      final completedEvents = <bool>[];
      engine.stream.completed.listen(completedEvents.add);

      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
      ]);

      await engine.action.play();
      expect(engine.state.playing, isTrue);

      // Seek near EOF to trigger natural track completion
      await engine.action.seek(const Duration(milliseconds: 5900));

      // Wait for playback to hit EOF
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(engine.state.phase, equals(EnginePhase.completed));
      expect(engine.state.completed, isTrue);
      expect(engine.state.playing, isFalse);
      expect(completedEvents.contains(true), isTrue);

      // Calling play() from completed restarts queue from index 0
      await engine.action.play();
      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.playing, isTrue);
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.completed, isFalse);
    });
  });

  group('FSM Scenario 6: Seek and Crossfade Boundary Lifecycle & Zero-Crossfade Stability', () {
    late MiniaudioEngine<String> engine;

    tearDown(() async {
      if (!engine.isDisposed) {
        await engine.dispose();
      }
    });

    test('seek to 2s with crossfade=0 maintains track 1 and does not switch prematurely', () async {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: const CrossfadeConfig.off(),
      );

      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
        EngineItem.file(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();
      // Go to track 2
      await engine.action.next();
      expect(engine.state.currentIndex, equals(1));

      // Go back to track 1
      await engine.action.previous();
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.playing, isTrue);

      // Let track play for ~500ms then seek to 2 seconds
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await engine.action.seek(const Duration(seconds: 2));

      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.position.inMilliseconds, closeTo(2000, 350));
      expect(engine.state.volume, closeTo(1.0, 1e-4));

      // Let playback run for 1 second; verify track 1 is still playing (no premature next())
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.playing, isTrue);
      expect(engine.state.position.inMilliseconds, greaterThanOrEqualTo(2500));
    });

    test('seeking back outside crossfade range aborts auto-crossfade and allows re-triggering', () async {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(seconds: 2),
          manualDuration: const Duration(seconds: 2),
        ),
      );

      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
        EngineItem.file(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();

      // Seek into auto-crossfade zone (track is ~6s long)
      await engine.action.seek(const Duration(milliseconds: 4500));
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(engine.state.phase, equals(EnginePhase.autoCrossfading));
      expect(engine.state.currentIndex, equals(0));

      // Seek back outside the crossfade zone (to 1.5s)
      await engine.action.seek(const Duration(milliseconds: 1500));

      expect(engine.state.phase, equals(EnginePhase.playing));
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.position.inMilliseconds, closeTo(1500, 350));
      expect(engine.state.volume, closeTo(1.0, 1e-4));

      // Seek back into crossfade zone: it triggers again smoothly
      await engine.action.seek(const Duration(milliseconds: 4600));
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(engine.state.phase, equals(EnginePhase.autoCrossfading));
      expect(engine.state.currentIndex, equals(0));
    });

    test('seeking within crossfade range preserves autoCrossfading phase and updates progress', () async {
      engine = MiniaudioEngine<String>(
        crossfadeConfig: CrossfadeConfig(
          duration: const Duration(seconds: 2),
          manualDuration: const Duration(seconds: 2),
        ),
      );

      await engine.action.open([
        EngineItem.file(track1File.path, data: 'Track 1'),
        EngineItem.file(track2File.path, data: 'Track 2'),
      ]);

      await engine.action.play();

      // Seek into crossfade zone (4.2s out of ~6.0s)
      await engine.action.seek(const Duration(milliseconds: 4200));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(engine.state.phase, equals(EnginePhase.autoCrossfading));

      // Seek slightly further inside crossfade zone (5.0s)
      await engine.action.seek(const Duration(milliseconds: 5000));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Phase remains autoCrossfading on outgoing track without error or premature skip
      expect(engine.state.phase, equals(EnginePhase.autoCrossfading));
      expect(engine.state.currentIndex, equals(0));
      expect(engine.state.position.inMilliseconds, closeTo(5000, 350));
    });
  });
}
