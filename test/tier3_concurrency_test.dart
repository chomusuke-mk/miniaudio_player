import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File fileA;
  late File fileB;
  late File fileC;
  late File fileD;

  setUpAll(() async {
    fileA = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier3_track_a.wav',
      frequencyHz: 440.0,
      durationSeconds: 5.0,
    );
    fileB = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier3_track_b.wav',
      frequencyHz: 880.0,
      durationSeconds: 5.0,
    );
    fileC = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier3_track_c.wav',
      frequencyHz: 220.0,
      durationSeconds: 5.0,
    );
    fileD = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'tier3_track_d.wav',
      frequencyHz: 1760.0,
      durationSeconds: 5.0,
    );
  });

  tearDownAll(() async {
    await SyntheticAudioGenerator.cleanUp(fileA);
    await SyntheticAudioGenerator.cleanUp(fileB);
    await SyntheticAudioGenerator.cleanUp(fileC);
    await SyntheticAudioGenerator.cleanUp(fileD);
  });

  // =========================================================================
  // Concurrency 1: Simultaneous Dual-Player Playback
  // =========================================================================
  group('Concurrency 1: Simultaneous Dual-Player Playback', () {
    late MiniaudioPlayer playerA;
    late MiniaudioPlayer playerB;

    setUp(() {
      playerA = MiniaudioPlayer();
      playerB = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!playerA.isDisposed) await playerA.dispose();
      if (!playerB.isDisposed) await playerB.dispose();
    });

    test('C1.1: two players run simultaneously in parallel without contention', () async {
      await playerA.action.open(fileA.path);
      await playerB.action.open(fileB.path);

      await Future.wait([playerA.action.play(), playerB.action.play()]);

      expect(playerA.state.playing, isTrue);
      expect(playerB.state.playing, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(playerA.state.position.inMilliseconds, greaterThan(100));
      expect(playerB.state.position.inMilliseconds, greaterThan(100));
    });

    test('C1.2: independent playback positions advance in parallel', () async {
      await playerA.action.open(fileA.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Start playerB later
      await playerB.action.open(fileB.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // playerA should be ahead of playerB
      expect(
        playerA.state.position.inMilliseconds,
        greaterThan(playerB.state.position.inMilliseconds),
      );
    });
  });

  // =========================================================================
  // Concurrency 2: Parameter Isolation (Zero Cross-Talk)
  // =========================================================================
  group('Concurrency 2: Parameter Isolation (Zero Cross-Talk)', () {
    late MiniaudioPlayer playerA;
    late MiniaudioPlayer playerB;

    setUp(() {
      playerA = MiniaudioPlayer();
      playerB = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!playerA.isDisposed) await playerA.dispose();
      if (!playerB.isDisposed) await playerB.dispose();
    });

    test(
      'C2.1: volume adjustments on Player A do not affect Player B',
      () async {
        await playerA.action.open(fileA.path);
        await playerB.action.open(fileB.path);

        await playerA.action.setVolume(0.35);
        await playerB.action.setVolume(0.95);

        expect(playerA.state.volume, closeTo(0.35, 0.001));
        expect(playerB.state.volume, closeTo(0.95, 0.001));

        // Mutate A again
        await playerA.action.setVolume(0.1);
        expect(playerA.state.volume, closeTo(0.1, 0.001));
        expect(playerB.state.volume, closeTo(0.95, 0.001));
      },
    );

    test(
      'C2.2: rate and pitch adjustments are completely isolated per instance',
      () async {
        await playerA.action.open(fileA.path);
        await playerB.action.open(fileB.path);

        await playerA.action.setRate(1.75);
        await playerB.action.setRate(0.5);

        await playerA.action.setPitch(1.3);
        await playerB.action.setPitch(0.7);

        expect(playerA.state.rate, closeTo(1.75, 0.001));
        expect(playerB.state.rate, closeTo(0.5, 0.001));
        expect(playerA.state.pitch, closeTo(1.3, 0.001));
        expect(playerB.state.pitch, closeTo(0.7, 0.001));
      },
    );

    test(
      'C2.3: equalizer adjustments are completely isolated per instance',
      () async {
        await playerA.action.open(fileA.path);
        await playerB.action.open(fileB.path);

        await playerA.action.setEqualizer(Equalizer.rock);
        await playerB.action.setEqualizer(Equalizer.jazz);

        expect(playerA.state.equalizer, equals(Equalizer.rock));
        expect(playerB.state.equalizer, equals(Equalizer.jazz));

        await playerA.action.setEqualizer(Equalizer.bassBoost);
        expect(playerA.state.equalizer, equals(Equalizer.bassBoost));
        expect(playerB.state.equalizer, equals(Equalizer.jazz));
      },
    );
  });

  // =========================================================================
  // Concurrency 3: Independent Transport Operations
  // =========================================================================
  group('Concurrency 3: Independent Transport Controls', () {
    late MiniaudioPlayer playerA;
    late MiniaudioPlayer playerB;

    setUp(() {
      playerA = MiniaudioPlayer();
      playerB = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!playerA.isDisposed) await playerA.dispose();
      if (!playerB.isDisposed) await playerB.dispose();
    });

    test(
      'C3.1: pausing Player A does not interrupt Player B playback',
      () async {
        await playerA.action.open(fileA.path, autoPlay: true);
        await playerB.action.open(fileB.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 200));

        await playerA.action.pause();

        expect(playerA.state.playing, isFalse);
        expect(playerB.state.playing, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(playerB.state.position.inMilliseconds, greaterThan(250));
      },
    );

    test('C3.2: stopping Player A rewinds only Player A to zero', () async {
      await playerA.action.open(fileA.path, autoPlay: true);
      await playerB.action.open(fileB.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await playerA.action.stop();

      expect(playerA.state.playing, isFalse);
      expect(playerA.state.position, equals(Duration.zero));
      expect(playerB.state.playing, isTrue);
      expect(playerB.state.position.inMilliseconds, greaterThan(150));
    });

    test('C3.3: seeking Player A does not shift Player B position', () async {
      await playerA.action.open(fileA.path, autoPlay: true);
      await playerB.action.open(fileB.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      const seekTarget = Duration(seconds: 4);
      await playerA.action.seek(seekTarget);

      expect(
        playerA.state.position.inMilliseconds,
        closeTo(seekTarget.inMilliseconds, 100),
      );
      expect(playerB.state.position.inMilliseconds, lessThan(1000));
    });
  });

  // =========================================================================
  // Concurrency 4: Peer Disposal Resilience
  // =========================================================================
  group('Concurrency 4: Peer Disposal Resilience', () {
    late MiniaudioPlayer playerA;
    late MiniaudioPlayer playerB;

    setUp(() {
      playerA = MiniaudioPlayer();
      playerB = MiniaudioPlayer();
    });

    tearDown(() async {
      if (!playerA.isDisposed) await playerA.dispose();
      if (!playerB.isDisposed) await playerB.dispose();
    });

    test('C4.1: disposing Player A mid-playback leaves Player B running uninterrupted', () async {
      await playerA.action.open(fileA.path, autoPlay: true);
      await playerB.action.open(fileB.path, autoPlay: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(playerA.state.playing, isTrue);
      expect(playerB.state.playing, isTrue);

      // Dispose Player A while active
      await playerA.dispose();
      expect(playerA.isDisposed, isTrue);

      // Player B must remain playing smoothly
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(playerB.isDisposed, isFalse);
      expect(playerB.state.playing, isTrue);
      expect(playerB.state.position.inMilliseconds, greaterThan(300));
    });
  });

  // =========================================================================
  // Concurrency 5: Multi-Instance Scaling (4 Concurrent Instances)
  // =========================================================================
  group('Concurrency 5: Multi-Instance Scaling (4 Concurrent Instances)', () {
    final List<MiniaudioPlayer> players = [];

    tearDown(() async {
      for (final p in players) {
        if (!p.isDisposed) {
          await p.dispose();
        }
      }
      players.clear();
    });

    test('C5.1: 4 concurrent players run simultaneously with zero crosstalk', () async {
      final p1 = MiniaudioPlayer();
      final p2 = MiniaudioPlayer();
      final p3 = MiniaudioPlayer();
      final p4 = MiniaudioPlayer();
      players.addAll([p1, p2, p3, p4]);

      await Future.wait([
        p1.action.open(fileA.path, autoPlay: true),
        p2.action.open(fileB.path, autoPlay: true),
        p3.action.open(fileC.path, autoPlay: true),
        p4.action.open(fileD.path, autoPlay: true),
      ]);

      expect(p1.state.playing, isTrue);
      expect(p2.state.playing, isTrue);
      expect(p3.state.playing, isTrue);
      expect(p4.state.playing, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(p1.state.position.inMilliseconds, greaterThan(100));
      expect(p2.state.position.inMilliseconds, greaterThan(100));
      expect(p3.state.position.inMilliseconds, greaterThan(100));
      expect(p4.state.position.inMilliseconds, greaterThan(100));

      // Teardown all 4 concurrently
      await Future.wait([
        p1.dispose(),
        p2.dispose(),
        p3.dispose(),
        p4.dispose(),
      ]);

      expect(players.every((p) => p.isDisposed), isTrue);
    });

    test('C5.2: interleaved rapid commands across multiple instances execute safely', () async {
      final p1 = MiniaudioPlayer();
      final p2 = MiniaudioPlayer();
      players.addAll([p1, p2]);

      await p1.action.open(fileA.path);
      await p2.action.open(fileB.path);

      // Execute interleaved operations concurrently
      await Future.wait([
        p1.action.play(),
        p2.action.setVolume(0.5),
        p1.action.setRate(1.2),
        p2.action.play(),
        p1.action.setEqualizer(Equalizer.pop),
        p2.action.seek(const Duration(seconds: 1)),
      ]);

      expect(p1.state.playing, isTrue);
      expect(p2.state.playing, isTrue);
      expect(p1.state.rate, closeTo(1.2, 0.001));
      expect(p2.state.volume, closeTo(0.5, 0.001));
      expect(p1.state.equalizer, equals(Equalizer.pop));
    });
  });
}
