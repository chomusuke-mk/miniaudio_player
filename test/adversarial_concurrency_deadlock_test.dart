import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
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
      onTimeout: () => throw TimeoutException('Failed to start python test HTTP server'),
    );
  });

  tearDownAll(() async {
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

  group('Adversarial Concurrency & Deadlock Verification', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      try {
        await player.dispose();
      } catch (_) {}
    });

    test('ADV-1: Rapid interleaved seek(0), seek(t), play, pause during active streaming', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.open(AudioSource.uri(url));
      expect(player.action.activeLoader, isNotNull);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Rapidly fire interleaved commands without awaiting each before starting next
      for (int cycle = 0; cycle < 10; cycle++) {
        final f1 = player.action.seek(Duration.zero);
        final f2 = player.action.play();
        final f3 = player.action.seek(Duration(milliseconds: 200 + cycle * 50));
        final f4 = player.action.pause();
        final f5 = player.action.seek(Duration.zero);
        final f6 = player.action.play();

        await Future.wait([f1, f2, f3, f4, f5, f6]);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.playing, isTrue);
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('ADV-2: Deadlock stress test under artificial network stall (decoder blocked on data_ready_event)', () async {
      // Stream stalls for 1000ms after initial 32 KB burst
      final stallUrl = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=4096&stall_ms=1000&initial_burst=32768';
      await player.action.open(AudioSource.uri(stallUrl));

      await player.action.play();
      // Allow playback to consume the burst and enter the 1000ms network stall
      // During this stall, the worker thread is blocked waiting in map_buffer_read on data_ready_event holding decoder_mutex.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      // Contention attack: Call seek(Duration.zero) which MUST abort map_buffer to acquire decoder_mutex without deadlock!
      for (int i = 0; i < 6; i++) {
        final seekFuture = player.action.seek(Duration.zero);
        final playFuture = player.action.play();
        final pauseFuture = player.action.pause();
        final resumeFuture = player.action.play();

        await Future.wait([seekFuture, playFuture, pauseFuture, resumeFuture]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // Check player did not hang or deadlock
      expect(player.state.playing, isTrue);
      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('ADV-3: High seek contention with interleaved cache hits and misses during dropped connection', () async {
      // Connection drops abruptly after 64 KB
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=65536';
      await player.action.open(AudioSource.uri(dropUrl));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Concurrently fire seek to 0 (cache HIT on pinned head) and seek to 10s (cache MISS)
      final rng = Random(42);
      final futures = <Future<void>>[];
      for (int i = 0; i < 20; i++) {
        if (i % 3 == 0) {
          futures.add(player.action.seek(Duration.zero));
        } else if (i % 3 == 1) {
          futures.add(player.action.seek(Duration(seconds: rng.nextInt(15) + 1)));
        } else {
          futures.add(rng.nextBool() ? player.action.play() : player.action.pause());
        }
      }

      await Future.wait(futures);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Final seek to zero must succeed cleanly
      await player.action.seek(Duration.zero);
      expect(player.action.activeLoader, isNotNull);
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('ADV-4: Burst fuzzing of 50 concurrent unawaited commands under flaky network', () async {
      final flakyUrl = 'http://127.0.0.1:$serverPort/flaky/music/salida.mp3';
      await player.action.open(AudioSource.uri(flakyUrl));

      final rng = Random(1337);
      final unawaitedFutures = <Future<void>>[];

      for (int i = 0; i < 50; i++) {
        final op = rng.nextInt(5);
        switch (op) {
          case 0:
            unawaitedFutures.add(player.action.seek(Duration.zero));
            break;
          case 1:
            unawaitedFutures.add(player.action.seek(Duration(milliseconds: rng.nextInt(5000))));
            break;
          case 2:
            unawaitedFutures.add(player.action.play());
            break;
          case 3:
            unawaitedFutures.add(player.action.pause());
            break;
          case 4:
            unawaitedFutures.add(player.action.setVolume(rng.nextDouble()));
            break;
        }
        if (i % 7 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      // Must all complete without hanging or crashing
      await Future.wait(unawaitedFutures);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('ADV-5: Concurrent multi-player seek contention under network stalls', () async {
      final player2 = MiniaudioPlayer();
      try {
        final stallUrl1 = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=8192&stall_ms=500&initial_burst=32768';
        final stallUrl2 = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=4096&stall_ms=800&initial_burst=32768';

        await Future.wait([
          player.action.open(AudioSource.uri(stallUrl1)),
          player2.action.open(AudioSource.uri(stallUrl2)),
        ]);

        await Future.wait([
          player.action.play(),
          player2.action.play(),
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 400));

        final concurrentOps = <Future<void>>[];
        for (int i = 0; i < 8; i++) {
          concurrentOps.add(player.action.seek(Duration.zero));
          concurrentOps.add(player2.action.seek(Duration.zero));
          concurrentOps.add(player.action.seek(Duration(milliseconds: i * 100)));
          concurrentOps.add(player2.action.seek(Duration(milliseconds: i * 150)));
          concurrentOps.add(player.action.pause());
          concurrentOps.add(player2.action.pause());
          concurrentOps.add(player.action.play());
          concurrentOps.add(player2.action.play());
        }

        await Future.wait(concurrentOps);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        await Future.wait([
          player.action.stop(),
          player2.action.stop(),
        ]);
      } finally {
        await player2.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
