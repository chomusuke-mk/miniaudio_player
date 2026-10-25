import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Process? serverProcess;
  int? serverPort;

  Future<void> resetServerStats(int port) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/reset_stats'));
      final res = await req.close();
      await res.drain<void>();
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> getServerStats(int port) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/stats'));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

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

  group('Milestone 2 (R2) Adversarial Stress Harness: Pinned Head & Cache Hits', () {
    late MiniaudioPlayer player;

    setUp(() {
      MiniaudioPlayer.config(
        bufferNetworkDuration: const Duration(seconds: 12),
        bufferBehindNetworkDuration: const Duration(seconds: 5),
      );
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      MiniaudioPlayer.config(
        bufferNetworkDuration: const Duration(seconds: 30),
        bufferBehindNetworkDuration: const Duration(seconds: 5),
      );
      await player.dispose();
    });

    test('Adv-1: Out-of-window jumps and seek(Duration.zero) resolve cleanly and resume playback', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.wav';
      await player.action.openUrl(url);
      expect(player.action.activeLoader, isNotNull);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Advance through stream in large jumps: 20s (~3.5MB), 40s (~7MB), 60s (~10.5MB)
      await player.action.seek(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 350));

      await player.action.seek(const Duration(seconds: 40));
      await Future<void>.delayed(const Duration(milliseconds: 350));

      await player.action.seek(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 350));

      await resetServerStats(serverPort!);

      // Seek back to Duration.zero: re-fetches audio_start cleanly while HEAD stays pinned in RAM
      await player.action.seek(Duration.zero);

      // Verify playback continues and position is advancing near 0
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, lessThan(3000));
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('Adv-2: Seek to Duration.zero after playback EOF / completion', () async {
      final url = 'http://127.0.0.1:$serverPort/music/test_24bit_stereo.wav';
      await player.action.openUrl(url);
      expect(player.action.activeLoader, isNotNull);

      await player.action.play();
      // Give loader a brief moment to ingest the 10s track into the 17s RING window
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Seek near end of 10s audio so it completes quickly
      await player.action.seek(const Duration(milliseconds: 9800));

      // Wait for completion (EOF)
      int waitMs = 0;
      while (!player.state.completed && waitMs < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }
      expect(player.state.completed, isTrue, reason: 'Track should reach completion');

      // Reset server stats
      await resetServerStats(serverPort!);

      // Seek to Duration.zero after completion: hits RING in RAM with 0 range requests
      await player.action.seek(Duration.zero);

      final stats = await getServerStats(serverPort!);
      final rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      final testRanges = rangeRequests['/music/test_24bit_stereo.wav'] as int? ?? 0;

      expect(testRanges, equals(0),
          reason: 'seek(Duration.zero) after EOF within RING window must incur 0 range requests');
      expect(player.state.completed, isFalse,
          reason: 'Seeking to 0 must reset completed state to false');

      // Restart playback from 0
      await player.action.play();
      int elapsed = 0;
      while (player.state.position.inMilliseconds == 0 && elapsed < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        elapsed += 50;
      }

      expect(player.state.playing, isTrue, reason: 'Playback must resume from 0');
      expect(player.state.completed, isFalse, reason: 'Completed must remain false while playing');
      expect(player.state.position.inMilliseconds, greaterThan(0), reason: 'Position must advance from 0');
      expect(player.state.position.inMilliseconds, lessThan(1200), reason: 'Position should be within initial frames');

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('Adv-3: Large stream ingestion (15.86 MB ALAC) preserves HEAD/TAIL and decodes cleanly', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida_alac.m4a';
      await player.action.openUrl(url);
      expect(player.action.activeLoader, isNotNull);

      await player.action.play();
      // Seek through ALAC stream
      await player.action.seek(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      await player.action.seek(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Seek back to Duration.zero
      await player.action.seek(Duration.zero);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, lessThan(3000));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('Adv-4: Small stream (< 256 KB) RING caching and seek(Duration.zero)', () async {
      // cbr_noxing.mp3 is 240,788 bytes
      final url = 'http://127.0.0.1:$serverPort/music/cbr_noxing.mp3';
      await player.action.openUrl(url);
      expect(player.action.activeLoader, isNotNull);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      await resetServerStats(serverPort!);

      // Seek to Duration.zero
      await player.action.seek(Duration.zero);

      final stats = await getServerStats(serverPort!);
      final rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      final mp3Ranges = rangeRequests['/music/cbr_noxing.mp3'] as int? ?? 0;

      expect(mp3Ranges, equals(0), reason: 'Zero range requests on small stream seek(0)');
      expect(player.state.playing, isTrue);

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('Adv-5: Rapid alternating seeks between remote offsets and Duration.zero resolve cleanly', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(url);
      expect(player.action.activeLoader, isNotNull);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      for (int i = 0; i < 4; i++) {
        final distantSeconds = 15 + i * 10;
        await player.action.seek(Duration(seconds: distantSeconds));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        await player.action.seek(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, lessThan(3000));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
