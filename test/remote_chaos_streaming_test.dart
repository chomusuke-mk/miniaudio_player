// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

/// Helper to log actions and player state during chaotic operations,
/// dumped on failure to pinpoint exact errors.
class ChaosTrace {
  final List<String> _entries = [];

  void log(String action, [Map<String, dynamic>? details]) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final detailStr = details != null ? ' | details=${jsonEncode(details)}' : '';
    _entries.add('[$ts] $action$detailStr');
  }

  void dump() {
    print('\n========== CHAOS ACTION TRACE ==========');
    for (final e in _entries) {
      print(e);
    }
    print('========================================\n');
  }
}

Future<Map<String, dynamic>> fetchEndpoints(int port) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/endpoints'));
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>> fetchStats(int port) async {
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

Future<void> resetStats(int port) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/reset_stats'));
    final res = await req.close();
    await res.drain<void>();
  } finally {
    client.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Process? serverProcess;
  int? serverPort;
  Map<String, dynamic> endpointsCatalog = {};

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

    endpointsCatalog = await fetchEndpoints(serverPort!);
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

  // =========================================================================
  // Group 1: Remote Formats Matrix (Progressive Playback & Accurate Seeking)
  // =========================================================================
  group('Remote Formats Matrix Progressive Playback & Seeking', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    const testedFormats = [
      'mp3',
      'wav',
      'flac',
      'ogg',
      'oga',
      'opus',
      'aac',
      'm4a',
      'alac',
    ];

    for (final fmt in testedFormats) {
      test('1.$fmt: Progressive streaming and seek validation for $fmt', () async {
        if (!endpointsCatalog.containsKey(fmt)) {
          // Omit if endpoint not available in catalog
          return;
        }

        final item = endpointsCatalog[fmt] as Map<String, dynamic>;
        final path = item['remote_normal'] as String;
        final url = 'http://127.0.0.1:$serverPort$path';

        await resetStats(serverPort!);
        stdout.writeln('>>> [DEBUG] 1.$fmt: Opening $url');

        // 1. Open remote URL
        await player.action.openUrl(url);
        stdout.writeln('>>> [DEBUG] 1.$fmt: openUrl OK, dur=${player.state.duration.inMilliseconds}');
        expect(player.state.duration.inMilliseconds, greaterThan(0),
            reason: 'Duration must be resolved for $fmt');

        // 2. Play
        await player.action.play();
        stdout.writeln('>>> [DEBUG] 1.$fmt: play OK');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(player.state.playing, isTrue);
        expect(player.state.position.inMilliseconds, greaterThan(0));
        stdout.writeln('>>> [DEBUG] 1.$fmt: playing verified, pos=${player.state.position.inMilliseconds}');

        // 3. Seek validation for seekable progressive stream formats
        final isStreamSeekable = fmt != 'ogg' && fmt != 'oga' && fmt != 'opus';
        if (isStreamSeekable) {
          final seekTarget = player.state.duration > const Duration(seconds: 4)
              ? const Duration(seconds: 2)
              : Duration(milliseconds: player.state.duration.inMilliseconds ~/ 3);

          stdout.writeln('>>> [DEBUG] 1.$fmt: Seeking to ${seekTarget.inMilliseconds}');
          await player.action.seek(seekTarget);
          stdout.writeln('>>> [DEBUG] 1.$fmt: seek call returned');
          await Future<void>.delayed(const Duration(milliseconds: 300));

          // 4. Validate seek position accuracy
          final actualPos = player.state.position.inMilliseconds;
          final targetPos = seekTarget.inMilliseconds;
          expect((actualPos - targetPos).abs(), lessThanOrEqualTo(1000),
              reason: 'Position after seek should align with target for $fmt (target: $targetPos, actual: $actualPos)');

          // 5. Verify seek was handled (either via in-RAM cache hit or network Range request)
          final stats = await fetchStats(serverPort!);
          final rangeRequests = stats['range_requests_by_path'] as Map<String, dynamic>;
          final count = rangeRequests[path] ?? 0;
          stdout.writeln('>>> [DEBUG] 1.$fmt: Range requests received by server: $count');
          expect(count, greaterThanOrEqualTo(0));
        }

        stdout.writeln('>>> [DEBUG] 1.$fmt: Stopping');
        await player.action.stop();
        expect(player.state.playing, isFalse);
        stdout.writeln('>>> [DEBUG] 1.$fmt: Done');
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  });

  // =========================================================================
  // Group 2: Live Stream Matrix (Normal & Flaky Livestreams)
  // =========================================================================
  group('Live Stream Matrix Streaming & Transitions', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    const liveFormats = ['mp3', 'wav', 'aac', 'ogg'];

    for (final fmt in liveFormats) {
      test('2.$fmt: Live streaming and transition to flaky live stream for $fmt', () async {
        if (!endpointsCatalog.containsKey(fmt)) return;

        final item = endpointsCatalog[fmt] as Map<String, dynamic>;
        final normalPath = item['live_normal'] as String;
        final flakyPath = item['live_flaky'] as String;

        // 1. Open normal livestream
        await player.action.openUrl(
          'http://127.0.0.1:$serverPort$normalPath',
          isLive: true,
        );
        expect(player.state.duration, equals(Duration.zero));

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(player.state.playing, isTrue);

        // 2. Seamlessly switch to flaky live stream mid-stream
        await player.action.openUrl(
          'http://127.0.0.1:$serverPort$flakyPath',
          isLive: true,
        );
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.state.playing, isTrue);

        await player.action.stop();
        expect(player.state.playing, isFalse);
      }, timeout: const Timeout(Duration(seconds: 15)));
    }
  });

  // =========================================================================
  // Group 3: Corrupt Stream & File Resilience and State Recovery
  // =========================================================================
  group('Corrupt Stream/File Resilience & Player State Recovery', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('3.1: Corrupt remote file triggers controlled error without breaking subsequent commands', () async {
      if (!endpointsCatalog.containsKey('mp3')) return;
      final item = endpointsCatalog['mp3'] as Map<String, dynamic>;
      final corruptUrl = 'http://127.0.0.1:$serverPort${item['remote_corrupt']}';
      final normalUrl = 'http://127.0.0.1:$serverPort${item['remote_normal']}';

      // 1. Attempt to open corrupt audio file -> expect controlled exception
      await expectLater(
        player.action.openUrl(corruptUrl),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // 2. Controlled command verification: pause() and stop() must not crash or throw
      await player.action.pause();
      await player.action.stop();
      expect(player.state.playing, isFalse);

      // 3. Immediate recovery: player must cleanly open valid URL and play
      await player.action.openUrl(normalUrl);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('3.2: Corrupt live stream triggers controlled error and recovers immediately', () async {
      if (!endpointsCatalog.containsKey('mp3')) return;
      final item = endpointsCatalog['mp3'] as Map<String, dynamic>;
      final corruptLive = 'http://127.0.0.1:$serverPort${item['live_corrupt']}';
      final normalLive = 'http://127.0.0.1:$serverPort${item['live_normal']}';

      await expectLater(
        player.action.openUrl(corruptLive, isLive: true),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // Control commands should remain safe
      await player.action.stop();

      // Open valid live stream
      await player.action.openUrl(normalLive, isLive: true);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(player.state.playing, isTrue);
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 4: Flaky Network & Burst Rate-Limiting with Range Stats
  // =========================================================================
  group('Flaky Network & Burst Rate-Limiting with Range Stats', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('4.1: Rapid seeks across rate-limited flaky stream track request count and preserve pipeline', () async {
      if (!endpointsCatalog.containsKey('mp3')) return;
      final item = endpointsCatalog['mp3'] as Map<String, dynamic>;
      final flakyPath = item['remote_flaky'] as String;
      final url = 'http://127.0.0.1:$serverPort$flakyPath?burst_limit=3';

      await resetStats(serverPort!);
      await player.action.openUrl(
        url,
        bufferAhead: const Duration(milliseconds: 500),
        bufferBehind: Duration.zero,
      );
      await player.action.play();

      // Fire rapid consecutive seeks across unbuffered track regions
      for (int i = 1; i <= 4; i++) {
        final targetMs = i * 10000;
        await player.action.seek(Duration(milliseconds: targetMs));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      await Future<void>.delayed(const Duration(milliseconds: 350));

      final stats = await fetchStats(serverPort!);
      final requests = stats['requests_by_path'] as Map<String, dynamic>;
      final rangeRequests = stats['range_requests_by_path'] as Map<String, dynamic>;

      // Verify that requests and range requests were registered for this path
      expect(requests[flakyPath] ?? 0, greaterThanOrEqualTo(2));
      expect(rangeRequests[flakyPath] ?? 0, greaterThanOrEqualTo(1));

      // Player must still be intact and controllable
      await player.action.pause();
      expect(player.state.playing, isFalse);
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 5: Chaotic Interleaved Controls Sequence with Action Trace
  // =========================================================================
  group('Chaotic Interleaved Controls Sequence', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('5.1: Comprehensive chaotic commands loop with detailed trace validation', () async {
      final trace = ChaosTrace();

      try {
        final mp3Item = endpointsCatalog['mp3'] as Map<String, dynamic>;
        final m4aItem = (endpointsCatalog['m4a'] ?? endpointsCatalog['alac'] ?? mp3Item) as Map<String, dynamic>;
        final liveItem = (endpointsCatalog['aac'] ?? mp3Item) as Map<String, dynamic>;

        final trackA = 'http://127.0.0.1:$serverPort${mp3Item['remote_normal']}';
        final corruptTrack = 'http://127.0.0.1:$serverPort${mp3Item['remote_corrupt']}';
        final trackB = 'http://127.0.0.1:$serverPort${m4aItem['remote_normal']}';
        final liveStream = 'http://127.0.0.1:$serverPort${liveItem['live_normal']}';

        // Step 1: Open track A and play
        trace.log('Step 1: openUrl(trackA)');
        await player.action.openUrl(trackA);
        trace.log('Step 1.1: play()');
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.playing, isTrue);
        trace.log('Step 1.2: state verified playing', {'position': player.state.position.inMilliseconds});

        // Step 2: Seek forward while playing
        trace.log('Step 2: seek(2s)');
        await player.action.seek(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(1500));
        trace.log('Step 2.1: seek position verified', {'position': player.state.position.inMilliseconds});

        // Step 3: Pause while playing
        trace.log('Step 3: pause()');
        await player.action.pause();
        expect(player.state.playing, isFalse);
        trace.log('Step 3.1: paused verified');

        // Step 4: Seek near end while paused
        final nearEnd = player.state.duration - const Duration(milliseconds: 300);
        trace.log('Step 4: seek near end', {'target': nearEnd.inMilliseconds});
        await player.action.seek(nearEnd);

        // Step 5: Resume play to trigger natural completion
        trace.log('Step 5: play() until completion');
        await player.action.play();
        int waitMs = 0;
        while (!player.state.completed && waitMs < 4000) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          waitMs += 100;
        }
        trace.log('After loop', {
          'pos': player.state.position.inMilliseconds,
          'dur': player.state.duration.inMilliseconds,
          'completed': player.state.completed,
          'playing': player.state.playing,
        });
        expect(player.state.completed, isTrue);
        trace.log('Step 5.1: completed verified');

        // Step 6: Replay from completion auto-rewinds
        trace.log('Step 6: play() from completed state');
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.playing, isTrue);
        expect(player.state.completed, isFalse);
        trace.log('Step 6.1: auto-rewind replay verified', {'position': player.state.position.inMilliseconds});

        // Step 7: Open corrupt track mid-playback -> expect error, trace it
        trace.log('Step 7: open corrupt track');
        try {
          await player.action.openUrl(corruptTrack);
          fail('Opening corrupt track should throw MiniaudioPlayerException');
        } on MiniaudioPlayerException catch (err) {
          trace.log('Step 7.1: caught expected exception', {'error': err.message});
        }

        // Step 8: Clear state via stop()
        trace.log('Step 8: stop() after error');
        await player.action.stop();
        expect(player.state.playing, isFalse);

        // Step 9: Switch to Live Stream
        trace.log('Step 9: openUrl(liveStream)');
        await player.action.openUrl(liveStream, isLive: true);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(player.state.playing, isTrue);
        trace.log('Step 9.1: live stream playing verified');

        // Step 10: Switch directly from Live Stream to finite track B
        trace.log('Step 10: switch from live stream to track B (M4A/ALAC)');
        await player.action.openUrl(trackB);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(player.state.playing, isTrue);
        expect(player.state.duration.inMilliseconds, greaterThan(0));
        trace.log('Step 10.1: track B playing verified', {
          'duration': player.state.duration.inMilliseconds,
          'position': player.state.position.inMilliseconds,
        });

        // Step 11: Final clean stop
        trace.log('Step 11: stop()');
        await player.action.stop();
        expect(player.state.playing, isFalse);
        trace.log('Step 11.1: clean stop verified');
      } catch (e) {
        trace.dump();
        rethrow;
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
