// test/adversarial_network_concurrency_stress_test.dart
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
      onTimeout: () => throw TimeoutException('Failed to start test HTTP server'),
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

  group('Adversarial M3 Network Drop & Concurrency Stress Harness', () {
    test('CHALLENGE-1: Hostile transport command bombardment during reconnection backoff timer', () async {
      final player = MiniaudioPlayer();
      addTearDown(() async {
        if (!player.isDisposed) await player.dispose();
      });

      // Endpoint drops connection after 70 KB (probe is 64 KB, so drop occurs during playback)
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=71680';
      await player.action.open(AudioSource.uri(dropUrl));
      await player.action.play();

      // Wait until initial chunk is consumed and connection drops
      await Future<void>.delayed(const Duration(milliseconds: 350));

      // Bombard with 30 rapid interleaved commands while reconnect timer is active
      final rng = Random(999);
      final futures = <Future<void>>[];
      for (int i = 0; i < 30; i++) {
        final action = rng.nextInt(5);
        switch (action) {
          case 0:
            futures.add(player.action.seek(Duration.zero));
            break;
          case 1:
            futures.add(player.action.seek(Duration(milliseconds: rng.nextInt(3000))));
            break;
          case 2:
            futures.add(player.action.pause());
            break;
          case 3:
            futures.add(player.action.play());
            break;
          case 4:
            futures.add(player.action.setVolume(rng.nextDouble()));
            break;
        }
        if (i % 6 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      }

      await Future.wait(futures);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Player must be alive and responsive
      expect(player.isDisposed, isFalse);
      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('CHALLENGE-2: Rapid disposal stress test while reconnect timer is pending', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=71680';

      for (int i = 0; i < 8; i++) {
        final player = MiniaudioPlayer();
        await player.action.open(AudioSource.uri(dropUrl));
        await player.action.play();

        // Delay into the exact window where connection drops and reconnectTimer is scheduled
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Abrupt dispose while network streamer is in reconnection backoff
        await player.dispose();
        expect(player.isDisposed, isTrue);
      }
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('CHALLENGE-3: Headroom telemetry and silence synthesis under severe network starvation', () async {
      final player = MiniaudioPlayer();
      addTearDown(() async {
        if (!player.isDisposed) await player.dispose();
      });

      // 1500ms stall after 32 KB initial burst
      final stallUrl = 'http://127.0.0.1:$serverPort/stall/salida.wav?chunk_size=16384&stall_ms=1500&initial_burst=32768';
      await player.action.open(AudioSource.uri(stallUrl));
      await player.action.play();

      // Verify initial streaming state
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.state.playing, isTrue);

      // Wait into the 1500ms stall: audio thread must be synthesizing silence without deadlocking
      await Future<void>.delayed(const Duration(milliseconds: 700));

      // Verify clock is held during silence synthesis
      final heldPos1 = player.state.position.inMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final heldPos2 = player.state.position.inMilliseconds;
      expect(heldPos2, equals(heldPos1), reason: 'Clock must freeze during starvation silence synthesis');

      // Command dispatch during active silence synthesis must remain lock-free and responsive
      await player.action.setVolume(0.5);
      expect(player.state.volume, closeTo(0.5, 0.01));

      // Wait for stall to resolve and next chunk to resume clock
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      final resumedPos = player.state.position.inMilliseconds;
      expect(resumedPos, greaterThan(heldPos2), reason: 'Clock resumes advancement after network data arrives');

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('CHALLENGE-4: 2-Player simultaneous chaotic cross-fire on dropped/recovering streams', () async {
      final player1 = MiniaudioPlayer();
      final player2 = MiniaudioPlayer();

      addTearDown(() async {
        if (!player1.isDisposed) await player1.dispose();
        if (!player2.isDisposed) await player2.dispose();
      });

      final resumeUrl1 = 'http://127.0.0.1:$serverPort/drop_resume/salida.mp3?drop_at=65536';
      final stallUrl2 = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=8192&stall_ms=600&initial_burst=32768';

      await Future.wait([
        player1.action.open(AudioSource.uri(resumeUrl1)),
        player2.action.open(AudioSource.uri(stallUrl2)),
      ]);

      await Future.wait([
        player1.action.play(),
        player2.action.play(),
      ]);

      final rng = Random(777);
      final futures = <Future<void>>[];

      for (int i = 0; i < 40; i++) {
        final p = (i % 2 == 0) ? player1 : player2;
        final op = rng.nextInt(6);
        switch (op) {
          case 0:
            futures.add(p.action.seek(Duration.zero));
            break;
          case 1:
            futures.add(p.action.seek(Duration(milliseconds: rng.nextInt(4000))));
            break;
          case 2:
            futures.add(p.action.pause());
            break;
          case 3:
            futures.add(p.action.play());
            break;
          case 4:
            futures.add(p.action.setVolume(0.2 + rng.nextDouble() * 0.8));
            break;
          case 5:
            futures.add(p.action.setRate(0.8 + rng.nextDouble() * 0.4));
            break;
        }
        if (i % 8 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      await Future.wait(futures);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(player1.isDisposed, isFalse);
      expect(player2.isDisposed, isFalse);

      await Future.wait([
        player1.action.stop(),
        player2.action.stop(),
      ]);
    }, timeout: const Timeout(Duration(seconds: 25)));
  });
}
