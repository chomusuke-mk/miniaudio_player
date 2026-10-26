import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late File localWavFile;
  late Uint8List memoryWavBytes1;
  late Uint8List memoryWavBytes2;
  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
    // 1. Generate local synthetic test WAV file (10 seconds)
    localWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'm1_stress_test_track.wav',
      frequencyHz: 440.0,
      durationSeconds: 10.0,
    );

    // 2. Generate memory WAV bytes
    memoryWavBytes1 = SyntheticAudioGenerator.generateWavBytes(
      frequencyHz: 523.25, // C5
      durationSeconds: 10.0,
    );
    memoryWavBytes2 = SyntheticAudioGenerator.generateWavBytes(
      frequencyHz: 659.25, // E5
      durationSeconds: 10.0,
    );

    // 3. Start local Python HTTP test server for remote streaming tests
    final completer = Completer<int>();
    serverProcess = await Process.start(
      'python3',
      [
        'test/helpers/test_http_server.py',
        '--port',
        '0',
        '--dir',
        'example/assets/music',
      ],
      environment: {'MAP_TEST_DEBUG': '1'},
    );

    serverProcess!.stderr.drain<void>();
    serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final match = RegExp(r'SERVER_STARTED_PORT:(\d+)').firstMatch(line);
      if (match != null && !completer.isCompleted) {
        completer.complete(int.parse(match.group(1)!));
      }
    });

    serverPort = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Failed to start test HTTP server'),
    );
  });

  tearDownAll(() async {
    await SyntheticAudioGenerator.cleanUp(localWavFile);
    if (serverPort != null) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/shutdown'));
        final res = await req.close();
        await res.drain<void>();
      } catch (_) {}
    }
    serverProcess?.kill();
    await serverProcess?.exitCode;
  });

  // =========================================================================
  // Group 1: Chaotic Permutations with Unawaited Calls and Mid-Flight Disposal
  // =========================================================================
  group('1. Chaotic Permutations with Unawaited Calls & Mid-Flight Disposal', () {
    test('1.1: 20 iterations of unawaited chaotic sequence: openUrl, play, seek, pause, stop, openMemory, play, dispose', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      final rng = Random(42);

      for (int i = 0; i < 20; i++) {
        final player = MiniaudioPlayer();

        // Chaotic permutation of actions without awaiting
        final actions = <Function>[
          () => player.action.open(AudioSource.uri(url)).catchError((_) {}),
          () => player.action.play().catchError((_) {}),
          () => player.action.seek(Duration(seconds: rng.nextInt(5))).catchError((_) {}),
          () => player.action.pause().catchError((_) {}),
          () => player.action.stop().catchError((_) {}),
          () => player.action.open(AudioSource.memory(memoryWavBytes1)).catchError((_) {}),
          () => player.action.play().catchError((_) {}),
        ];

        // Shuffle the actions
        actions.shuffle(rng);

        for (final act in actions) {
          act();
          if (rng.nextBool()) {
            await Future<void>.delayed(Duration(microseconds: rng.nextInt(500)));
          }
        }

        // Mid-flight or immediate unawaited disposal
        await player.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('1.2: Calling dispose() while openUrl() and play() are actively negotiating HTTP', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      for (int i = 0; i < 5; i++) {
        final player = MiniaudioPlayer();
        player.action.open(AudioSource.uri(url)).catchError((_) {});
        player.action.play().catchError((_) {});
        player.action.seek(const Duration(seconds: 3)).catchError((_) {});

        // Yield just 1-5 milliseconds into network connection
        await Future<void>.delayed(Duration(milliseconds: 1 + i * 2));

        // Dispose while in flight
        await player.dispose();
      }
    });

    test('1.3: Clean recovery after chaotic disposal — new player instance functions normally', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      // 1. Destroy a player chaotically
      final messyPlayer = MiniaudioPlayer();
      messyPlayer.action.open(AudioSource.uri(url)).catchError((_) {});
      messyPlayer.action.play().catchError((_) {});
      messyPlayer.action.seek(const Duration(seconds: 4)).catchError((_) {});
      messyPlayer.action.open(AudioSource.memory(memoryWavBytes2)).catchError((_) {});
      await messyPlayer.dispose();

      // 2. Fresh player instance must play without native thread deadlock
      final freshPlayer = MiniaudioPlayer();
      try {
        await freshPlayer.action.open(localWavFile.path);
        await freshPlayer.action.play();

        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(freshPlayer.state.playing, isTrue);
        expect(freshPlayer.state.position.inMilliseconds, greaterThan(150));
      } finally {
        await freshPlayer.dispose();
      }
    });
  });

  // =========================================================================
  // Group 2: Position Monotonicity and Non-Stalling under Unawaited Play
  // =========================================================================
  group('2. Position Monotonicity and Non-Stalling under Unawaited Play', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('2.1: Local file: openFile + unawaited play advances position monotonically with diff > 0', () async {
      player.action.open(AudioSource.file(localWavFile.path));
      final playFuture = player.action.play();

      await playFuture;
      expect(player.state.playing, isTrue);

      final positions = <int>[];
      for (int i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        positions.add(player.state.position.inMilliseconds);
      }

      // 1. Position must advance monotonically (never regress)
      for (int i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          greaterThanOrEqualTo(positions[i - 1]),
          reason: 'Position regressed from ${positions[i - 1]} to ${positions[i]}',
        );
      }

      // 2. Position must not stall (diff > 0)
      final totalDiff = positions.last - positions.first;
      expect(
        totalDiff,
        greaterThan(200),
        reason: 'Position stalled: totalDiff=$totalDiff ms across 400ms interval',
      );

      await player.action.stop();
    });

    test('2.2: Memory buffer: openMemory + unawaited play advances position monotonically with diff > 0', () async {
      player.action.open(AudioSource.memory(memoryWavBytes1));
      final playFuture = player.action.play();

      await playFuture;
      expect(player.state.playing, isTrue);

      final positions = <int>[];
      for (int i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        positions.add(player.state.position.inMilliseconds);
      }

      // Verify monotonicity
      for (int i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          greaterThanOrEqualTo(positions[i - 1]),
          reason: 'Memory buffer position regressed from ${positions[i - 1]} to ${positions[i]}',
        );
      }

      // Verify non-stalling
      final totalDiff = positions.last - positions.first;
      expect(
        totalDiff,
        greaterThan(200),
        reason: 'Memory buffer position stalled: totalDiff=$totalDiff ms',
      );

      await player.action.stop();
    });

    test('2.3: Remote HTTP stream: openUrl + unawaited play advances position monotonically with diff > 0', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      player.action.open(AudioSource.uri(url));
      final playFuture = player.action.play();

      await playFuture;
      expect(player.state.playing, isTrue);

      final positions = <int>[];
      for (int i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        positions.add(player.state.position.inMilliseconds);
      }

      // Verify monotonicity
      for (int i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          greaterThanOrEqualTo(positions[i - 1]),
          reason: 'HTTP stream position regressed from ${positions[i - 1]} to ${positions[i]}',
        );
      }

      // Verify non-stalling
      final totalDiff = positions.last - positions.first;
      expect(
        totalDiff,
        greaterThan(200),
        reason: 'HTTP stream position stalled: totalDiff=$totalDiff ms',
      );

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 3: Rapid Seek Storm during Opening Gate
  // =========================================================================
  group('3. Rapid Seek Storm during Opening Gate', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('3.1: Remote HTTP stream: 5 unawaited seeks during Opening gate resolve cleanly', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      player.action.open(AudioSource.uri(url));
      player.action.seek(const Duration(seconds: 1));
      player.action.seek(const Duration(seconds: 4));
      player.action.seek(const Duration(seconds: 2));
      player.action.seek(const Duration(seconds: 6));
      final lastSeek = player.action.seek(const Duration(seconds: 5));
      final playFuture = player.action.play();

      await Future.wait([lastSeek, playFuture]);

      expect(player.state.playing, isTrue);
      // Position should be around the final sought position (~5s)
      expect(player.state.position.inSeconds, closeTo(5, 2));

      // Allow playback to proceed and verify monotonicity
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.position.inMilliseconds, greaterThan(4500));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('3.2: Boundary seeks (negative, past duration, zero) during Opening gate', () async {
      player.action.open(localWavFile.path);
      player.action.seek(const Duration(seconds: -10)); // clamped to 0
      player.action.seek(const Duration(hours: 1));     // clamped to duration
      player.action.seek(const Duration(seconds: 2));
      final playFuture = player.action.play();

      await playFuture;

      expect(player.state.playing, isTrue);
      expect(player.state.position.inSeconds, closeTo(2, 1));

      await player.action.stop();
    });
  });

  // =========================================================================
  // Group 4: Failure Handling & Instant Recovery during Opening
  // =========================================================================
  group('4. Failure Handling & Instant Recovery during Opening', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('4.1: Unawaited open on invalid media followed by unawaited play/seek fails gracefully without uncaught zone exception', () async {
      // Intentionally invalid file path
      final invalidOpenFuture = player.action.open(AudioSource.file('/invalid/nonexistent/media.wav'));
      final playFuture = player.action.play();
      final seekFuture = player.action.seek(const Duration(seconds: 2));

      // Expect open to throw, while play and seek should complete gracefully or ignore without zone error
      expect(invalidOpenFuture, throwsA(isA<MiniaudioPlayerException>()));
      await playFuture;
      await seekFuture;

      expect(player.state.playing, isFalse);
    });

    test('4.2: Instant recovery: player resumes normal playback on next valid open after failed open', () async {
      // 1. Trigger failed open
      try {
        await player.action.open(AudioSource.memory(Uint8List(0))); // empty bytes throws
      } catch (_) {}

      // 2. Open valid memory buffer immediately on the SAME player instance
      await player.action.open(AudioSource.memory(memoryWavBytes1));
      await player.action.play();

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThan(100));

      await player.action.stop();
    });
  });

  // =========================================================================
  // Group 5: Concurrent Multi-Player Instance Chaos
  // =========================================================================
  group('5. Concurrent Multi-Player Instance Chaos', () {
    test('5.1: 6 concurrent MiniaudioPlayer instances performing interleaved unawaited operations', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      final players = List.generate(6, (_) => MiniaudioPlayer());

      try {
        final futures = <Future<void>>[];
        for (int p = 0; p < players.length; p++) {
          final player = players[p];
          futures.add(() async {
            final rng = Random(100 + p);
            for (int step = 0; step < 15; step++) {
              final op = rng.nextInt(6);
              switch (op) {
                case 0:
                  player.action.open(AudioSource.uri(url)).catchError((_) {});
                  break;
                case 1:
                  player.action.open(AudioSource.memory(memoryWavBytes1)).catchError((_) {});
                  break;
                case 2:
                  player.action.play().catchError((_) {});
                  break;
                case 3:
                  player.action.pause().catchError((_) {});
                  break;
                case 4:
                  player.action.seek(Duration(seconds: rng.nextInt(4))).catchError((_) {});
                  break;
                case 5:
                  player.action.stop().catchError((_) {});
                  break;
              }
              if (rng.nextBool()) {
                await Future<void>.delayed(Duration(microseconds: rng.nextInt(400)));
              }
            }
          }());
        }

        await Future.wait(futures);
      } finally {
        for (final p in players) {
          await p.dispose();
        }
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // =========================================================================
  // Group 6: Microsecond Jitter 100-Operation Stress Fuzzing
  // =========================================================================
  group('6. Microsecond Jitter 100-Operation Stress Fuzzing', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('6.1: 100 randomized unawaited operations with microsecond jitter, followed by clean playback', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      final rng = Random(999);

      for (int i = 0; i < 100; i++) {
        final op = rng.nextInt(8);
        switch (op) {
          case 0:
            player.action.open(AudioSource.uri(url)).catchError((_) {});
            break;
          case 1:
            player.action.open(AudioSource.memory(memoryWavBytes2)).catchError((_) {});
            break;
          case 2:
            player.action.open(AudioSource.file(localWavFile.path)).catchError((_) {});
            break;
          case 3:
            player.action.play().catchError((_) {});
            break;
          case 4:
            player.action.pause().catchError((_) {});
            break;
          case 5:
            player.action.seek(Duration(seconds: rng.nextInt(6))).catchError((_) {});
            break;
          case 6:
            player.action.setVolume(rng.nextDouble() * 1.5).catchError((_) {});
            break;
          case 7:
            player.action.stop().catchError((_) {});
            break;
        }

        if (rng.nextBool()) {
          await Future<void>.delayed(Duration(microseconds: rng.nextInt(250)));
        }
      }

      // Settle and verify engine health
      await player.action.open(localWavFile.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThan(150));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
