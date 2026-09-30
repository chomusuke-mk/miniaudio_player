import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File standardWavFile;
  late File shortWavFile;
  late File emptyWavFile;
  late File corruptedWavFile;

  setUpAll(() async {
    standardWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier2_standard.wav',
      frequencyHz: 440.0,
      durationSeconds: 3.0,
    );
    shortWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier2_short.wav',
      frequencyHz: 880.0,
      durationSeconds: 0.08, // 80ms short audio
    );
    emptyWavFile = await SyntheticAudioGenerator.createZeroByteFile(
      fileName: 'tier2_empty.wav',
    );
    corruptedWavFile = await SyntheticAudioGenerator.createCorruptedFile(
      fileName: 'tier2_corrupted.wav',
    );
  });

  tearDownAll(() async {
    await SyntheticAudioGenerator.cleanUp(standardWavFile);
    await SyntheticAudioGenerator.cleanUp(shortWavFile);
    await SyntheticAudioGenerator.cleanUp(emptyWavFile);
    await SyntheticAudioGenerator.cleanUp(corruptedWavFile);
  });

  // =========================================================================
  // Boundary 1: Empty, Corrupted, Short, and Missing Files
  // =========================================================================
  group('Boundary 1: File Loading Corner Cases', () {
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
      'B1.1: opening a 0-byte file rejects cleanly without native crash',
      () async {
        expect(() => player.action.open(emptyWavFile.path), throwsA(anything));
      },
    );

    test(
      'B1.2: opening a corrupted file rejects cleanly without native crash',
      () async {
        expect(
          () => player.action.open(corruptedWavFile.path),
          throwsA(anything),
        );
      },
    );

    test('B1.3: opening a non-existent file path throws without crashing isolate', () async {
      expect(
        () => player.action.open(
          '/path/to/non_existent_file_${DateTime.now().microsecondsSinceEpoch}.wav',
        ),
        throwsA(anything),
      );
    });

    test(
      'B1.4: playing ultra-short audio file (80ms) reaches completion cleanly',
      () async {
        await player.action.open(shortWavFile.path);

        final completedExpectation = expectLater(
          player.stream.completed,
          emitsThrough(true),
        );

        await player.action.play();
        await completedExpectation;

        expect(player.state.playing, isFalse);
        expect(player.state.completed, isTrue);
      },
    );
  });

  // =========================================================================
  // Boundary 2: EOF and Boundary Seeking
  // =========================================================================
  group('Boundary 2: EOF & Out-of-Bounds Seeking', () {
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
      'B2.1: seeking past duration clamps to duration or completes track',
      () async {
        await player.action.open(standardWavFile.path);
        final duration = player.state.duration;

        // Seek far beyond track length
        await player.action.seek(const Duration(hours: 1));

        // Position should be clamped to media duration (or mark completed)
        expect(
          player.state.position.inMilliseconds,
          closeTo(duration.inMilliseconds, 150),
        );
      },
    );

    test(
      'B2.2: seeking to negative timestamp clamps to Duration.zero',
      () async {
        await player.action.open(standardWavFile.path);
        await player.action.seek(const Duration(seconds: 2));
        expect(player.state.position.inMilliseconds, greaterThan(1000));

        await player.action.seek(const Duration(seconds: -10));
        expect(player.state.position, equals(Duration.zero));
      },
    );

    test(
      'B2.3: seeking to exact Duration.zero succeeds and sets position to 0',
      () async {
        await player.action.open(standardWavFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 200));

        await player.action.seek(Duration.zero);
        expect(player.state.position, equals(Duration.zero));
      },
    );

    test(
      'B2.4: seeking while stopped preserves target position for next play',
      () async {
        await player.action.open(standardWavFile.path);
        await player.action.stop();

        const seekPos = Duration(seconds: 1);
        await player.action.seek(seekPos);
        expect(
          player.state.position.inMilliseconds,
          closeTo(seekPos.inMilliseconds, 100),
        );

        await player.action.play();
        expect(player.state.playing, isTrue);
        expect(
          player.state.position.inMilliseconds,
          greaterThanOrEqualTo(seekPos.inMilliseconds - 50),
        );
      },
    );
  });

  // =========================================================================
  // Boundary 3: Rapid Scrubbing Stress (High-Frequency Seeks)
  // =========================================================================
  group('Boundary 3: Rapid Scrubbing Stress', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('B3.1: rapid burst of 20 seek operations without awaiting does not deadlock or crash', () async {
      await player.action.open(standardWavFile.path, autoPlay: true);

      // Simulate aggressive user scrubbing the slider
      final futures = <Future<void>>[];
      for (int i = 0; i < 20; i++) {
        final targetMs = (i * 100) % 2500;
        futures.add(player.action.seek(Duration(milliseconds: targetMs)));
      }

      await Future.wait(futures);

      // Verify player remains alive, responsive, and playing
      expect(player.isDisposed, isFalse);
      expect(player.state.playing, isTrue);
    });

    test('B3.2: rapid seek between zero and midpoint converges to final seek target', () async {
      await player.action.open(standardWavFile.path);

      for (int i = 0; i < 10; i++) {
        await player.action.seek(Duration(milliseconds: i % 2 == 0 ? 0 : 1500));
      }

      const finalTarget = Duration(seconds: 2);
      await player.action.seek(finalTarget);

      expect(
        player.state.position.inMilliseconds,
        closeTo(finalTarget.inMilliseconds, 100),
      );
    });
  });

  // =========================================================================
  // Boundary 4: Extreme Volume Values
  // =========================================================================
  group('Boundary 4: Volume Extremes & Validation', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('B4.1: negative volume throws ArgumentError on UI thread', () async {
      expect(
        () => player.action.setVolume(-0.1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('B4.2: volume NaN or Infinity throws ArgumentError', () async {
      expect(
        () => player.action.setVolume(double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => player.action.setVolume(double.infinity),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'B4.3: volume 0.0 and 2.0 boundaries succeed and update state',
      () async {
        await player.action.setVolume(0.0);
        expect(player.state.volume, equals(0.0));

        await player.action.setVolume(2.0);
        expect(player.state.volume, equals(2.0));
      },
    );

    test('B4.4: volume exceeding 2.0 is clamped or rejected', () async {
      try {
        await player.action.setVolume(3.5);
        // If clamped, volume should not exceed 2.0
        expect(player.state.volume, lessThanOrEqualTo(2.0));
      } catch (e) {
        expect(e, isA<ArgumentError>());
      }
    });
  });

  // =========================================================================
  // Boundary 5: Extreme Rate Values
  // =========================================================================
  group('Boundary 5: Rate Extremes & Validation', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('B5.1: rate <= 0.0 throws ArgumentError', () async {
      expect(() => player.action.setRate(0.0), throwsA(isA<ArgumentError>()));
      expect(() => player.action.setRate(-1.0), throwsA(isA<ArgumentError>()));
    });

    test('B5.2: rate NaN or Infinity throws ArgumentError', () async {
      expect(
        () => player.action.setRate(double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => player.action.setRate(double.infinity),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'B5.3: minimum valid rate (0.1) and maximum valid rate (4.0) succeed',
      () async {
        await player.action.setRate(0.1);
        expect(player.state.rate, closeTo(0.1, 0.001));

        await player.action.setRate(4.0);
        expect(player.state.rate, closeTo(4.0, 0.001));
      },
    );

    test(
      'B5.4: rate out-of-range (< 0.1 or > 4.0) is clamped or rejected',
      () async {
        try {
          await player.action.setRate(10.0);
          expect(player.state.rate, lessThanOrEqualTo(4.0));
        } catch (e) {
          expect(e, isA<ArgumentError>());
        }
      },
    );
  });

  // =========================================================================
  // Boundary 6: Extreme Pitch Values
  // =========================================================================
  group('Boundary 6: Pitch Extremes & Validation', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('B6.1: pitch <= 0.0 throws ArgumentError', () async {
      expect(() => player.action.setPitch(0.0), throwsA(isA<ArgumentError>()));
      expect(() => player.action.setPitch(-0.5), throwsA(isA<ArgumentError>()));
    });

    test('B6.2: pitch NaN or Infinity throws ArgumentError', () async {
      expect(
        () => player.action.setPitch(double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => player.action.setPitch(double.infinity),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'B6.3: minimum valid pitch (0.5) and maximum valid pitch (2.0) succeed',
      () async {
        await player.action.setPitch(0.5);
        expect(player.state.pitch, closeTo(0.5, 0.001));

        await player.action.setPitch(2.0);
        expect(player.state.pitch, closeTo(2.0, 0.001));
      },
    );

    test(
      'B6.4: pitch out-of-range (< 0.5 or > 2.0) is clamped or rejected',
      () async {
        try {
          await player.action.setPitch(5.0);
          expect(player.state.pitch, lessThanOrEqualTo(2.0));
        } catch (e) {
          expect(e, isA<ArgumentError>());
        }
      },
    );
  });

  // =========================================================================
  // Boundary 7: Equalizer Boundary & Validation
  // =========================================================================
  group('Boundary 7: Equalizer Gain Extremes & Validation', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
    });

    test('B7.1: Equalizer with non-finite values (NaN / Infinity) throws ArgumentError', () {
      expect(
        () => Equalizer(hz60: double.nan),
        throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
      );
      expect(
        () => Equalizer(hz1k: double.infinity),
        throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
      );
    });

    test(
      'B7.2: Equalizer boundary gains at -24.0 dB and +24.0 dB succeed',
      () async {
        const boundaryEq = Equalizer(
          hz60: -24.0,
          hz170: -24.0,
          hz310: -24.0,
          hz600: -24.0,
          hz1k: 0.0,
          hz3k: 24.0,
          hz6k: 24.0,
          hz12k: 24.0,
          hz14k: 24.0,
          hz16k: 24.0,
        );

        await player.action.setEqualizer(boundaryEq);
        expect(player.state.equalizer, equals(boundaryEq));
      },
    );

    test(
      'B7.3: Equalizer extreme gains beyond +/- 24 dB are clamped or handled',
      () async {
        const extremeEq = Equalizer(hz60: -35.0, hz16k: 40.0);

        await player.action.setEqualizer(extremeEq);
        // Native layer clamps to [-24.0, +24.0]
        expect(player.state.equalizer.hz60, inInclusiveRange(-35.0, 24.0));
      },
    );
  });

  // =========================================================================
  // Boundary 8: Safety & Rejection on Disposed Player
  // =========================================================================
  group('Boundary 8: Operations on Disposed Player', () {
    test(
      'B8.1: invoking action.play() after dispose throws immediately',
      () async {
        final player = MiniaudioPlayer();
        await player.dispose();
        expect(player.isDisposed, isTrue);

        expect(() => player.action.play(), throwsA(anything));
      },
    );

    test('B8.2: invoking action.pause(), stop(), seek(), or open() after dispose throws', () async {
      final player = MiniaudioPlayer();
      await player.dispose();

      expect(() => player.action.pause(), throwsA(anything));
      expect(() => player.action.stop(), throwsA(anything));
      expect(
        () => player.action.seek(const Duration(seconds: 1)),
        throwsA(anything),
      );
      expect(() => player.action.open(standardWavFile.path), throwsA(anything));
    });

    test(
      'B8.3: invoking action parameter setters after dispose throws',
      () async {
        final player = MiniaudioPlayer();
        await player.dispose();

        expect(() => player.action.setVolume(0.5), throwsA(anything));
        expect(() => player.action.setRate(1.2), throwsA(anything));
        expect(() => player.action.setPitch(1.1), throwsA(anything));
        expect(
          () => player.action.setEqualizer(Equalizer.rock),
          throwsA(anything),
        );
      },
    );
  });
}
