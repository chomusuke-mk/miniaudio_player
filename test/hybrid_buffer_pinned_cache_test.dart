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

  group('Milestone 2: High-Level Hybrid Buffer with Pinned Head/Tail', () {
    late MiniaudioPlayer player;

    setUp(() {
      MiniaudioPlayer.globalConfig.bufferSizeNetworkMB = 1;
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      MiniaudioPlayer.globalConfig.bufferSizeNetworkMB = 8;
      await player.dispose();
    });

    test('2.1: Initial stream open populates Pinned Head and exposes hasPinnedHead == true', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(url);

      expect(player.action.hasPinnedHead, isTrue);
      expect(player.state.duration.inMilliseconds, greaterThan(0));
      await player.action.stop();
    });

    test('2.2: Streaming past buffer capacity retains Pinned Head; seek(Duration.zero) incurs 0 HTTP range requests', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.wav';
      await player.action.openUrl(url);
      expect(player.action.hasPinnedHead, isTrue);

      await player.action.play();
      // Allow audio streamer to fetch chunks past the 1 MB buffer capacity
      // salida.wav is 13 MB, so the sliding window quickly advances past 0
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // Reset server stats to start counting from zero
      await resetServerStats(serverPort!);

      // Seek to Duration.zero: must hit Pinned Head in RAM cache
      await player.action.seek(Duration.zero);

      final stats = await getServerStats(serverPort!);
      final rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      final salidaRanges = rangeRequests['/music/salida.wav'] as int? ?? 0;

      expect(salidaRanges, equals(0), reason: 'seek(Duration.zero) should hit Pinned Head with 0 HTTP range requests');
      expect(player.state.playing, isTrue);

      // Verify playback continues progressing
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.position.inMilliseconds, lessThan(3000));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('2.3: Multiple sequential seeks to Duration.zero and within head retain 0 HTTP range requests', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(url);
      expect(player.action.hasPinnedHead, isTrue);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      await resetServerStats(serverPort!);

      // Seek 1: to zero
      await player.action.seek(Duration.zero);
      // Seek 2: to 100ms (within pinned head)
      await player.action.seek(const Duration(milliseconds: 100));
      // Seek 3: back to zero
      await player.action.seek(Duration.zero);

      final stats = await getServerStats(serverPort!);
      final rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      final salidaRanges = rangeRequests['/music/salida.mp3'] as int? ?? 0;

      expect(salidaRanges, equals(0), reason: 'All seeks within pinned head must hit RAM cache with 0 range requests');
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('2.4: Out-of-window seek triggers Byte-Range, but subsequent seek(Duration.zero) hits Pinned Head with 0 new range requests', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.wav';
      await player.action.openUrl(url);
      expect(player.action.hasPinnedHead, isTrue);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      await resetServerStats(serverPort!);

      // Seek out of window into the future (55 seconds into 13 MB WAV)
      await player.action.seek(const Duration(seconds: 55));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      var stats = await getServerStats(serverPort!);
      var rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      var salidaRanges = rangeRequests['/music/salida.wav'] as int? ?? 0;
      expect(salidaRanges, greaterThan(0), reason: 'Out of window seek must issue a Range request');

      // Now reset stats and seek back to Duration.zero
      await resetServerStats(serverPort!);
      await player.action.seek(Duration.zero);

      stats = await getServerStats(serverPort!);
      rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      salidaRanges = rangeRequests['/music/salida.wav'] as int? ?? 0;
      expect(salidaRanges, equals(0), reason: 'Seeking back to Duration.zero must hit Pinned Head without new range requests');

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('2.5: Rapid consecutive seeks to Duration.zero and within pinned head resolve without deadlock', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(url);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Rapidly seek between Duration.zero and small head offsets back-to-back
      for (int i = 0; i < 8; i++) {
        await player.action.seek(Duration(milliseconds: (i % 2 == 0) ? 0 : 250));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, lessThan(3000));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 25)));
  });
}
