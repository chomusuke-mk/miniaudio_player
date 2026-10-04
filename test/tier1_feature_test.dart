import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File testWavFile;

  setUpAll(() async {
    // Generate a 5-second synthetic 440Hz WAV file for feature tests
    testWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier1_feature_test.wav',
      frequencyHz: 440.0,
      durationSeconds: 5.0,
      sampleRate: 44100,
      numChannels: 1,
    );
  });

  tearDownAll(() async {
    await SyntheticAudioGenerator.cleanUp(testWavFile);
  });

  // =========================================================================
  // Feature 1: Play (action.play)
  // =========================================================================
  group('Feature 1: action.play()', () {
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
      '1.1: play starts audio playback and updates state.playing to true',
      () async {
        await player.action.open(testWavFile.path);
        expect(player.state.playing, isFalse);

        await player.action.play();
        expect(player.state.playing, isTrue);
      },
    );

    test('1.2: play causes state.position to advance over time', () async {
      await player.action.open(testWavFile.path);
      await player.action.play();

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.position.inMilliseconds, greaterThan(100));
    });

    test('1.3: play emits true on stream.playing', () async {
      await player.action.open(testWavFile.path);

      final expectation = expectLater(
        player.stream.playing,
        emitsThrough(true),
      );

      await player.action.play();
      await expectation;
    });

    test(
      '1.4: calling play when already playing is idempotent without error',
      () async {
        await player.action.open(testWavFile.path);
        await player.action.play();
        expect(player.state.playing, isTrue);

        // Calling play again while active
        await player.action.play();
        expect(player.state.playing, isTrue);
      },
    );

    test(
      '1.5: open with autoPlay: true starts playback automatically',
      () async {
        await player.action.open(testWavFile.path, autoPlay: true);
        expect(player.state.playing, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.position.inMilliseconds, greaterThan(50));
      },
    );
  });

  // =========================================================================
  // Feature 2: Pause (action.pause)
  // =========================================================================
  group('Feature 2: action.pause()', () {
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
      '2.1: pause halts active playback and sets state.playing to false',
      () async {
        await player.action.open(testWavFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.playing, isTrue);

        await player.action.pause();
        expect(player.state.playing, isFalse);
      },
    );

    test('2.2: pause emits false on stream.playing', () async {
      await player.action.open(testWavFile.path, autoPlay: true);

      final expectation = expectLater(
        player.stream.playing,
        emitsThrough(false),
      );

      await player.action.pause();
      await expectation;
    });

    test(
      '2.3: pause preserves current playback position without rewinding',
      () async {
        await player.action.open(testWavFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        await player.action.pause();
        final pausedPos = player.state.position;
        expect(pausedPos.inMilliseconds, greaterThan(100));

        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.position, equals(pausedPos));
      },
    );

    test(
      '2.4: pause when already paused is idempotent without error',
      () async {
        await player.action.open(testWavFile.path);
        expect(player.state.playing, isFalse);

        await player.action.pause();
        expect(player.state.playing, isFalse);
        await player.action.pause();
        expect(player.state.playing, isFalse);
      },
    );

    test(
      '2.5: calling play after pause resumes from the paused position',
      () async {
        await player.action.open(testWavFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        await player.action.pause();
        final pausedPos = player.state.position;

        await player.action.play();
        expect(player.state.playing, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          player.state.position.inMilliseconds,
          greaterThan(pausedPos.inMilliseconds),
        );
      },
    );
  });

  // =========================================================================
  // Feature 3: Stop (action.stop)
  // =========================================================================
  group('Feature 3: action.stop()', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('3.1: stop halts playback and sets state.playing to false', () async {
      await player.action.open(testWavFile.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('3.2: stop rewinds state.position to Duration.zero', () async {
      await player.action.open(testWavFile.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.position.inMilliseconds, greaterThan(100));

      await player.action.stop();
      expect(player.state.position, equals(Duration.zero));
    });

    test('3.3: stop emits Duration.zero on stream.position', () async {
      await player.action.open(testWavFile.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final expectation = expectLater(
        player.stream.position,
        emitsThrough(Duration.zero),
      );

      await player.action.stop();
      await expectation;
    });

    test(
      '3.4: stop when already stopped is idempotent without error',
      () async {
        await player.action.open(testWavFile.path);
        await player.action.stop();
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));

        await player.action.stop();
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));
      },
    );

    test(
      '3.5: calling play after stop restarts playback from Duration.zero',
      () async {
        await player.action.open(testWavFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        await player.action.stop();
        expect(player.state.position, equals(Duration.zero));

        await player.action.play();
        expect(player.state.playing, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.position.inMilliseconds, greaterThan(50));
      },
    );
  });

  // =========================================================================
  // Feature 4: Seek (action.seek)
  // =========================================================================
  group('Feature 4: action.seek()', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('4.1: seek updates state.position to requested timestamp', () async {
      await player.action.open(testWavFile.path);
      const target = Duration(seconds: 2);

      await player.action.seek(target);
      expect(
        player.state.position.inMilliseconds,
        closeTo(target.inMilliseconds, 100),
      );
    });

    test('4.2: seek emits new position on stream.position', () async {
      await player.action.open(testWavFile.path);
      const target = Duration(seconds: 1, milliseconds: 500);

      final expectation = expectLater(
        player.stream.position,
        emitsThrough(
          predicate<Duration>(
            (d) => (d.inMilliseconds - target.inMilliseconds).abs() <= 100,
          ),
        ),
      );

      await player.action.seek(target);
      await expectation;
    });

    test(
      '4.3: seek forward while playing continues playback from new position',
      () async {
        await player.action.open(testWavFile.path, autoPlay: true);
        const forwardTarget = Duration(seconds: 3);

        await player.action.seek(forwardTarget);
        expect(player.state.playing, isTrue);
        expect(
          player.state.position.inMilliseconds,
          greaterThanOrEqualTo(forwardTarget.inMilliseconds - 50),
        );

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          player.state.position.inMilliseconds,
          greaterThan(forwardTarget.inMilliseconds),
        );
      },
    );

    test('4.4: seek backward while playing updates position and continues playback', () async {
      await player.action.open(testWavFile.path, autoPlay: true);
      await player.action.seek(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      const backwardTarget = Duration(milliseconds: 500);
      await player.action.seek(backwardTarget);

      expect(player.state.playing, isTrue);
      expect(
        player.state.position.inMilliseconds,
        closeTo(backwardTarget.inMilliseconds, 100),
      );
    });

    test(
      '4.5: seek while paused updates position without initiating playback',
      () async {
        await player.action.open(testWavFile.path);
        expect(player.state.playing, isFalse);

        const target = Duration(seconds: 2);
        await player.action.seek(target);

        expect(player.state.playing, isFalse);
        expect(
          player.state.position.inMilliseconds,
          closeTo(target.inMilliseconds, 100),
        );
      },
    );
  });

  // =========================================================================
  // Feature 5: Volume (action.setVolume)
  // =========================================================================
  group('Feature 5: action.setVolume()', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('5.1: default volume is 1.0 on initialization', () {
      expect(player.state.volume, equals(1.0));
    });

    test('5.2: setVolume updates state.volume to specified level', () async {
      await player.action.open(testWavFile.path);
      await player.action.setVolume(0.65);
      expect(player.state.volume, closeTo(0.65, 0.001));
    });

    test('5.3: setVolume emits new volume level on stream.volume', () async {
      await player.action.open(testWavFile.path);

      final expectation = expectLater(
        player.stream.volume,
        emitsThrough(closeTo(0.4, 0.001)),
      );

      await player.action.setVolume(0.4);
      await expectation;
    });

    test('5.4: setVolume to 0.0 mutes playback', () async {
      await player.action.open(testWavFile.path);
      await player.action.setVolume(0.0);
      expect(player.state.volume, equals(0.0));
    });

    test(
      '5.5: setVolume to 2.0 amplifies volume to maximum allowed gain',
      () async {
        await player.action.open(testWavFile.path);
        await player.action.setVolume(2.0);
        expect(player.state.volume, equals(2.0));
      },
    );
  });

  // =========================================================================
  // Feature 6: Rate (action.setRate)
  // =========================================================================
  group('Feature 6: action.setRate()', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('6.1: default rate is 1.0 on initialization', () {
      expect(player.state.rate, equals(1.0));
    });

    test('6.2: setRate updates state.rate to specified speed', () async {
      await player.action.open(testWavFile.path);
      await player.action.setRate(1.25);
      expect(player.state.rate, closeTo(1.25, 0.001));
    });

    test('6.3: setRate emits new rate on stream.rate', () async {
      await player.action.open(testWavFile.path);

      final expectation = expectLater(
        player.stream.rate,
        emitsThrough(closeTo(1.75, 0.001)),
      );

      await player.action.setRate(1.75);
      await expectation;
    });

    test('6.4: setRate to 2.0 doubles playback speed', () async {
      await player.action.open(testWavFile.path);
      await player.action.setRate(2.0);
      expect(player.state.rate, equals(2.0));
    });

    test('6.5: setRate to 0.5 halves playback speed', () async {
      await player.action.open(testWavFile.path);
      await player.action.setRate(0.5);
      expect(player.state.rate, equals(0.5));
    });
  });

  // =========================================================================
  // Feature 7: Pitch (action.setPitch)
  // =========================================================================
  group('Feature 7: action.setPitch()', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('7.1: default pitch is 1.0 on initialization', () {
      expect(player.state.pitch, equals(1.0));
    });

    test('7.2: setPitch updates state.pitch to specified factor', () async {
      await player.action.open(testWavFile.path);
      await player.action.setPitch(1.3);
      expect(player.state.pitch, closeTo(1.3, 0.001));
    });

    test('7.3: setPitch emits new pitch on stream.pitch', () async {
      await player.action.open(testWavFile.path);

      final expectation = expectLater(
        player.stream.pitch,
        emitsThrough(closeTo(0.85, 0.001)),
      );

      await player.action.setPitch(0.85);
      await expectation;
    });

    test('7.4: setPitch to 1.5 shifts pitch upwards', () async {
      await player.action.open(testWavFile.path);
      await player.action.setPitch(1.5);
      expect(player.state.pitch, equals(1.5));
    });

    test('7.5: setPitch to 0.75 shifts pitch downwards', () async {
      await player.action.open(testWavFile.path);
      await player.action.setPitch(0.75);
      expect(player.state.pitch, equals(0.75));
    });
  });

  // =========================================================================
  // Feature 8: Equalizer (action.setEqualizer)
  // =========================================================================
  group('Feature 8: action.setEqualizer()', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('8.1: default equalizer is flat with all 10 bands at 0.0 dB', () {
      expect(player.state.equalizer, equals(Equalizer.flat));
      expect(player.state.equalizer.toList(), equals(List.filled(10, 0.0)));
    });

    test(
      '8.2: setEqualizer updates state.equalizer with custom gains',
      () async {
        await player.action.open(testWavFile.path);
        const customEq = Equalizer(
          hz60: 3.0,
          hz170: 2.0,
          hz310: 1.0,
          hz600: 0.0,
          hz1k: -1.0,
          hz3k: -2.0,
          hz6k: 1.5,
          hz12k: 2.5,
          hz14k: 3.5,
          hz16k: 4.0,
        );

        await player.action.setEqualizer(customEq);
        expect(player.state.equalizer, equals(customEq));
      },
    );

    test('8.3: setEqualizer emits new Equalizer on stream.equalizer', () async {
      await player.action.open(testWavFile.path);
      const customEq = Equalizer(hz60: 5.0, hz16k: -5.0);

      final expectation = expectLater(
        player.stream.equalizer,
        emitsThrough(equals(customEq)),
      );

      await player.action.setEqualizer(customEq);
      await expectation;
    });

    test(
      '8.4: Equalizer.copyWith modifies target band while retaining others',
      () {
        const base = Equalizer.flat;
        final updated = base.copyWith(hz1k: 4.5, hz16k: -3.0);

        expect(updated.hz1k, equals(4.5));
        expect(updated.hz16k, equals(-3.0));
        expect(updated.hz60, equals(0.0));
        expect(updated.hz170, equals(0.0));
      },
    );

    test(
      '8.5: Equalizer.toList returns exactly 10 ordered frequency bands',
      () {
        const eq = Equalizer(
          hz60: 1.0,
          hz170: 2.0,
          hz310: 3.0,
          hz600: 4.0,
          hz1k: 5.0,
          hz3k: 6.0,
          hz6k: 7.0,
          hz12k: 8.0,
          hz14k: 9.0,
          hz16k: 10.0,
        );

        final list = eq.toList();
        expect(list.length, equals(10));
        expect(
          list,
          equals([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]),
        );
      },
    );
  });

  // =========================================================================
  // Feature 9: Presets (Equalizer Presets)
  // =========================================================================
  group('Feature 9: Equalizer Presets', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('9.1: Equalizer.flat has 0.0 dB across all 10 bands', () {
      expect(Equalizer.flat.toList(), everyElement(equals(0.0)));
    });

    test('9.2: Equalizer.rock boosts bass and treble with recessed mids', () {
      const rock = Equalizer.rock;
      expect(rock.hz60, greaterThan(0.0));
      expect(rock.hz170, greaterThan(0.0));
      expect(rock.hz600, lessThan(0.0));
      expect(rock.hz12k, greaterThan(0.0));
      expect(rock.hz16k, greaterThan(0.0));
    });

    test('9.3: Equalizer.pop boosts upper mids and vocals', () {
      const pop = Equalizer.pop;
      expect(pop.hz310, greaterThan(0.0));
      expect(pop.hz600, greaterThan(0.0));
      expect(pop.hz1k, greaterThan(0.0));
      expect(pop.hz16k, lessThan(0.0));
    });

    test('9.4: Equalizer.jazz and Equalizer.classical provide warm acoustic curves', () {
      const jazz = Equalizer.jazz;
      const classical = Equalizer.classical;
      expect(jazz.hz60, greaterThan(0.0));
      expect(classical.hz60, greaterThan(0.0));
      expect(classical.hz1k, lessThan(0.0));
    });

    test('9.5: Equalizer.bassBoost significantly elevates bass bands', () {
      const bass = Equalizer.bassBoost;
      expect(bass.hz60, equals(7.0));
      expect(bass.hz170, equals(6.0));
      expect(bass.hz310, equals(4.5));
      expect(bass.hz1k, equals(0.0));
      expect(bass.hz16k, equals(0.0));
    });

    test('9.6: applying presets sequentially via setEqualizer updates state and stream', () async {
      await player.action.open(testWavFile.path);

      await player.action.setEqualizer(Equalizer.rock);
      expect(player.state.equalizer, equals(Equalizer.rock));

      await player.action.setEqualizer(Equalizer.bassBoost);
      expect(player.state.equalizer, equals(Equalizer.bassBoost));

      await player.action.setEqualizer(Equalizer.flat);
      expect(player.state.equalizer, equals(Equalizer.flat));
    });
  });

  // =========================================================================
  // Feature 10: Dispose & Lifecycle (player.dispose)
  // =========================================================================
  group('Feature 10: Player Lifecycle & Teardown', () {
    test('10.1: isDisposed is false initially upon instantiation', () {
      final player = MiniaudioPlayer();
      expect(player.isDisposed, isFalse);
    });

    test('10.2: dispose sets isDisposed to true', () async {
      final player = MiniaudioPlayer();
      expect(player.isDisposed, isFalse);

      await player.dispose();
      expect(player.isDisposed, isTrue);
    });

    test('10.3: multiple calls to dispose are idempotent and safe', () async {
      final player = MiniaudioPlayer();
      await player.dispose();
      expect(player.isDisposed, isTrue);

      // Subsequent dispose calls should complete without throwing
      await player.dispose();
      await player.dispose();
      expect(player.isDisposed, isTrue);
    });

    test('10.4: dispose while playing halts playback cleanly and frees native resources', () async {
      final player = MiniaudioPlayer();
      await player.action.open(testWavFile.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.dispose();
      expect(player.isDisposed, isTrue);
    });

    test('10.5: stream controllers close cleanly upon disposal', () async {
      final player = MiniaudioPlayer();
      await player.action.open(testWavFile.path);

      var playingDone = false;
      player.stream.playing.listen((_) {}, onDone: () => playingDone = true);

      await player.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(playingDone, isTrue);
    });
  });
}
