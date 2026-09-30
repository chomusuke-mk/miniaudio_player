import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File track1;
  late File track2;
  late File track3;
  late File shortTrack;

  setUpAll(() async {
    track1 = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier4_track1.wav',
      frequencyHz: 330.0,
      durationSeconds: 2.5,
    );
    track2 = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier4_track2.wav',
      frequencyHz: 440.0,
      durationSeconds: 2.0,
    );
    track3 = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier4_track3.wav',
      frequencyHz: 550.0,
      durationSeconds: 2.0,
    );
    shortTrack = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier4_short.wav',
      frequencyHz: 660.0,
      durationSeconds: 0.15, // 150ms track for quick EOF completion testing
    );
  });

  tearDownAll(() async {
    await SyntheticAudioGenerator.cleanUp(track1);
    await SyntheticAudioGenerator.cleanUp(track2);
    await SyntheticAudioGenerator.cleanUp(track3);
    await SyntheticAudioGenerator.cleanUp(shortTrack);
  });

  // =========================================================================
  // Scenario 1: Playlist Sequencing (Sequential Track Playback)
  // =========================================================================
  group('Scenario 1: Playlist Sequencing', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('A1.1: track plays to completion and advances to next track on completion event', () async {
      final playlist = [shortTrack.path, track2.path];
      int currentTrackIndex = 0;
      final completer = Completer<void>();

      player.stream.completed.listen((completed) async {
        if (completed && currentTrackIndex < playlist.length - 1) {
          currentTrackIndex++;
          await player.action.open(playlist[currentTrackIndex], autoPlay: true);
          completer.complete();
        }
      });

      await player.action.open(playlist[0], autoPlay: true);
      await completer.future.timeout(const Duration(seconds: 3));

      expect(currentTrackIndex, equals(1));
      expect(player.state.playing, isTrue);
    });

    test(
      'A1.2: sequential playlist transitions through 3 tracks smoothly',
      () async {
        final playlist = [shortTrack.path, shortTrack.path, track3.path];
        int playCount = 0;

        for (final path in playlist) {
          await player.action.open(path, autoPlay: true);
          expect(player.state.playing, isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          playCount++;
        }

        expect(playCount, equals(3));
        expect(player.state.playing, isTrue);
      },
    );
  });

  // =========================================================================
  // Scenario 2: Mid-Playback Track Replacement ("Next Track" Interaction)
  // =========================================================================
  group('Scenario 2: Mid-Playback Track Replacement', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('A2.1: opening Track 2 while Track 1 is actively playing replaces track cleanly', () async {
      await player.action.open(track1.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThan(100));

      // User hits "Next Track": opens Track 2 without stopping first
      await player.action.open(track2.path, autoPlay: true);

      expect(player.state.playing, isTrue);
      // Position must have reset for the new track
      expect(player.state.position.inMilliseconds, lessThan(200));

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.state.position.inMilliseconds, greaterThan(100));
    });

    test(
      'A2.2: rapid track replacement across 4 files resolves to the last track',
      () async {
        await player.action.open(track1.path, autoPlay: true);

        // Fire successive open calls without awaiting in between
        unawaited(player.action.open(track2.path, autoPlay: true));
        unawaited(player.action.open(track3.path, autoPlay: true));
        await player.action.open(shortTrack.path, autoPlay: true);

        expect(player.state.playing, isTrue);
        expect(player.state.duration.inMilliseconds, closeTo(150, 50));
      },
    );
  });

  // =========================================================================
  // Scenario 3: Complete Audio Player Lifecycle State Machine
  // =========================================================================
  group('Scenario 3: Complete Lifecycle State Machine', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test(
      'A3.1: comprehensive lifecycle walkthrough through all states',
      () async {
        // 1. Initial State
        expect(player.isDisposed, isFalse);
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));
        expect(player.state.volume, equals(1.0));
        expect(player.state.rate, equals(1.0));
        expect(player.state.pitch, equals(1.0));
        expect(player.state.equalizer, equals(Equalizer.flat));

        // 2. Open Track
        await player.action.open(track1.path);
        expect(player.state.playing, isFalse);
        expect(player.state.duration.inMilliseconds, closeTo(2500, 100));

        // 3. Play
        await player.action.play();
        expect(player.state.playing, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(player.state.position.inMilliseconds, greaterThan(100));

        // 4. Pause
        await player.action.pause();
        expect(player.state.playing, isFalse);
        final pausedPos = player.state.position;
        expect(pausedPos.inMilliseconds, greaterThan(0));

        // 5. Seek while paused
        const targetPos = Duration(seconds: 1);
        await player.action.seek(targetPos);
        expect(player.state.playing, isFalse);
        expect(
          player.state.position.inMilliseconds,
          closeTo(targetPos.inMilliseconds, 100),
        );

        // 6. Resume playback from seek target
        await player.action.play();
        expect(player.state.playing, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          player.state.position.inMilliseconds,
          greaterThan(targetPos.inMilliseconds),
        );

        // 7. Adjust DSP properties
        await player.action.setVolume(0.7);
        await player.action.setRate(1.2);
        await player.action.setPitch(1.1);
        await player.action.setEqualizer(Equalizer.rock);

        expect(player.state.volume, closeTo(0.7, 0.001));
        expect(player.state.rate, closeTo(1.2, 0.001));
        expect(player.state.pitch, closeTo(1.1, 0.001));
        expect(player.state.equalizer, equals(Equalizer.rock));

        // 8. Stop playback
        await player.action.stop();
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));

        // 9. Re-open short track and play to completion
        await player.action.open(shortTrack.path);
        final completedExpectation = expectLater(
          player.stream.completed,
          emitsThrough(true),
        );
        await player.action.play();
        await completedExpectation;

        expect(player.state.completed, isTrue);
        expect(player.state.playing, isFalse);

        // 10. Clean disposal
        await player.dispose();
        expect(player.isDisposed, isTrue);
      },
    );
  });

  // =========================================================================
  // Scenario 4: Rapid User Interaction Stress (UI Button Mashing)
  // =========================================================================
  group('Scenario 4: Rapid User Interaction Stress', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('A4.1: rapid toggling of play/pause button 10 times in 150ms resolves cleanly', () async {
      await player.action.open(track1.path);

      for (int i = 0; i < 10; i++) {
        if (i % 2 == 0) {
          unawaited(player.action.play());
        } else {
          unawaited(player.action.pause());
        }
      }

      // End with a definitive play command
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.playing, isTrue);
      expect(player.isDisposed, isFalse);
    });

    test('A4.2: rapid volume and rate slider scrubbing executes without corruption', () async {
      await player.action.open(track1.path, autoPlay: true);

      final futures = <Future<void>>[];
      for (int i = 1; i <= 10; i++) {
        final vol = (i * 0.1).clamp(0.0, 1.0);
        final rate = 0.5 + (i * 0.15);
        futures.add(player.action.setVolume(vol));
        futures.add(player.action.setRate(rate));
      }

      await Future.wait(futures);

      expect(player.state.playing, isTrue);
      expect(player.state.volume, closeTo(1.0, 0.001));
      expect(player.state.rate, closeTo(2.0, 0.001));
    });
  });

  // =========================================================================
  // Scenario 5: Reactive Stream to State Snapshot Consistency
  // =========================================================================
  group('Scenario 5: Reactive Stream to State Consistency', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('A5.1: stream.volume, rate, pitch, and equalizer events strictly match player.state', () async {
      await player.action.open(track1.path);

      double? lastStreamVolume;
      double? lastStreamRate;
      double? lastStreamPitch;
      Equalizer? lastStreamEq;

      final subs = [
        player.stream.volume.listen((v) => lastStreamVolume = v),
        player.stream.rate.listen((r) => lastStreamRate = r),
        player.stream.pitch.listen((p) => lastStreamPitch = p),
        player.stream.equalizer.listen((e) => lastStreamEq = e),
      ];

      await player.action.setVolume(0.42);
      await player.action.setRate(1.35);
      await player.action.setPitch(0.92);
      await player.action.setEqualizer(Equalizer.classical);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(player.state.volume, equals(lastStreamVolume));
      expect(player.state.rate, equals(lastStreamRate));
      expect(player.state.pitch, equals(lastStreamPitch));
      expect(player.state.equalizer, equals(lastStreamEq));

      for (final s in subs) {
        await s.cancel();
      }
    });

    test(
      'A5.2: re-opening a file after stop restarts playback cleanly',
      () async {
        await player.action.open(track1.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await player.action.stop();

        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));

        await player.action.open(track1.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(player.state.playing, isTrue);
        expect(player.state.position.inMilliseconds, greaterThan(50));
      },
    );
  });
}
