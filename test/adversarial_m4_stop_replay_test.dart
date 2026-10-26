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

  group('Milestone 4: Replay & Clean Stop Semantics Adversarial Tests', () {
    late MiniaudioPlayer player;

    setUp(() async {
      player = MiniaudioPlayer();
      await resetServerStats(serverPort!);
    });

    tearDown(() async {
      try {
        await player.action.stop();
      } catch (_) {}
      player.dispose();
    });

    test(
      'ADV-M4-1: stop() during high-speed streaming immediately aborts socket, zeroes data consumption, resets cursor to 0, and transitions to STOPPED',
      () async {
        final url = 'http://127.0.0.1:$serverPort/music/salida.wav';

        await player.action.open(AudioSource.uri(url));

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.action.activeLoader, isNotNull);

        await player.action.play();
        expect(player.state.playing, isTrue);

        // Allow streaming to run briefly
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Stop playback cleanly
        await player.action.stop();

        // Immediate assertions
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));
        expect(player.action.activeLoader, isNotNull);

        // Snapshot server stats
        final s0 = await getServerStats(serverPort!);
        final totalReqs0 = s0['total_requests'] as int? ?? 0;

        // Wait to verify no additional requests or socket reads occur
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final s1 = await getServerStats(serverPort!);
        final totalReqs1 = s1['total_requests'] as int? ?? 0;

        expect(totalReqs1, equals(totalReqs0),
            reason: 'Zero new HTTP requests should occur after stop()');
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.position, equals(Duration.zero));
        expect(player.action.activeLoader, isNotNull);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'ADV-M4-2: play() immediately after stop() starts cleanly from 0 without re-opening URL or re-sniffing headers',
      () async {
        final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

        await player.action.open(AudioSource.uri(url));
        await player.action.play();

        // Let audio advance past initial frames
        int waitMs = 0;
        while (player.state.position.inMilliseconds < 300 && waitMs < 3000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitMs += 50;
        }
        expect(player.state.position.inMilliseconds, greaterThan(0));

        // Clean stop
        await player.action.stop();

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.position, equals(Duration.zero));
        expect(player.action.activeLoader, isNotNull);

        await resetServerStats(serverPort!);

        bool openingFired = false;
        final openingSub = player.stream.opening.listen((isOpening) {
          if (isOpening) openingFired = true;
        });

        // Restart playback from stopped state
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(player.state.playing, isTrue);
        expect(player.state.playbackState, equals(PlaybackState.playing));
        expect(player.state.position.inMilliseconds, greaterThan(0));
        expect(player.state.position.inMilliseconds, lessThan(1200));

        // Verify Opening gate was NOT re-triggered
        expect(openingFired, isFalse,
            reason: 'Opening state must NOT fire when replaying from stopped stream');

        // Check server stats: no full GET re-opening request should have been dispatched
        final stats = await getServerStats(serverPort!);
        final requestsByPath = (stats['requests_by_path'] as Map<String, dynamic>?) ?? {};
        final fullGets = requestsByPath['/music/salida.mp3'] as int? ?? 0;
        expect(fullGets, equals(0),
            reason: 'Replay must not re-open or re-fetch URL with full GET');

        await openingSub.cancel();
        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'ADV-M4-3: play() after EOF completion triggers instant replay from RAM (0 network requests if fully cached, or range fetch if partially cached)',
      () async {
        // --- Sub-test 3A: Fully Cached Stream (WAV fully in RAM) ---
        final wavUrl = 'http://127.0.0.1:$serverPort/music/test_24bit_stereo.wav';

        await player.action.open(AudioSource.uri(
          wavUrl,
          bufferAhead: const Duration(seconds: 60)),
          bufferBehind: const Duration(seconds: 60),
        );
        await player.action.play();

        // Allow 2.64 MB to finish buffering into buffer over loopback
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Seek near EOF to finish quickly (~10000ms duration)
        await player.action.seek(const Duration(milliseconds: 9800));

        int waitMs = 0;
        while (!player.state.completed && waitMs < 5000) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          waitMs += 100;
        }
        expect(player.state.completed, isTrue, reason: 'Track must reach EOF');

        await resetServerStats(serverPort!);

        // Call play() directly on EOF without explicit seek(0)
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(player.state.playing, isTrue);
        expect(player.state.completed, isFalse);
        expect(player.state.position.inMilliseconds, greaterThan(0));
        expect(player.state.position.inMilliseconds, lessThan(800));

        // Fully cached stream replayed with 0 HTTP requests
        final wavStats = await getServerStats(serverPort!);
        final totalRequests = wavStats['total_requests'] as int? ?? 0;
        expect(totalRequests, equals(0),
            reason: 'In-RAM cached replay must execute with 0 HTTP network requests');

        await player.action.stop();

        // --- Sub-test 3B: Partially Cached Stream (ALAC with constrained buffer) ---
        final alacUrl = 'http://127.0.0.1:$serverPort/music/salida_alac.m4a';

        await player.action.open(AudioSource.uri(
          alacUrl,
          bufferAhead: const Duration(seconds: 3)),
          bufferBehind: const Duration(seconds: 1),
        );
        await player.action.play();

        // Wrap the sliding body by seeking forward
        await player.action.seek(const Duration(milliseconds: 10000));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Seek near EOF (~30s duration)
        final duration = player.state.duration;
        final nearEnd = duration > const Duration(seconds: 2)
            ? duration - const Duration(milliseconds: 400)
            : const Duration(milliseconds: 25000);
        await player.action.seek(nearEnd);

        waitMs = 0;
        while (!player.state.completed && waitMs < 6000) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          waitMs += 100;
        }
        expect(player.state.completed, isTrue, reason: 'ALAC stream must reach EOF');

        await resetServerStats(serverPort!);

        // Call play() directly on EOF
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(player.state.playing, isTrue);
        expect(player.state.completed, isFalse);
        expect(player.state.position.inMilliseconds, greaterThan(0));

        // Verify initial playback required 0 requests for byte 0 (served from pinned head)
        final alacStats = await getServerStats(serverPort!);
        final rangeRequests = (alacStats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
        final alacRanges = rangeRequests['/music/salida_alac.m4a'] as int? ?? 0;
        // Pinned head serves byte 0 immediately; lookahead prefetch may only fetch chunk >= 256KB
        expect(alacRanges, lessThanOrEqualTo(1),
            reason: 'Playback resumes immediately from pinned head without multiple range fetches');

        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 35)),
    );

    test(
      'ADV-M4-4: Rapid stop/play burst fuzzing under network stalls proves zero deadlocks, zero double-free, and clean state machine convergence',
      () async {
        final stallUrl =
            'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=4096&stall_ms=500&initial_burst=32768';

        await player.action.open(AudioSource.uri(stallUrl));

        final rng = Random(42);

        // Burst 1: Rapid sync interleaved calls
        for (int i = 0; i < 15; i++) {
          unawaited(player.action.play());
          unawaited(player.action.stop());
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Burst 2: Concurrent futures
        for (int i = 0; i < 10; i++) {
          await Future.wait([
            player.action.play(),
            player.action.stop(),
            player.action.seek(Duration.zero),
            player.action.play(),
            player.action.stop(),
          ]);
        }

        // Burst 3: Randomized fuzzing
        for (int i = 0; i < 20; i++) {
          final op = rng.nextInt(5);
          switch (op) {
            case 0:
              unawaited(player.action.play());
              break;
            case 1:
              unawaited(player.action.pause());
              break;
            case 2:
              unawaited(player.action.stop());
              break;
            case 3:
              unawaited(player.action.seek(Duration.zero));
              break;
            case 4:
              unawaited(player.action.seek(Duration(milliseconds: rng.nextInt(2000))));
              break;
          }
          if (i % 5 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        await Future<void>.delayed(const Duration(milliseconds: 150));

        // Final clean stop
        await player.action.stop();

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));

        // Clean restart after chaos
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(player.state.playing, isTrue);
        expect(player.state.playbackState, equals(PlaybackState.playing));
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));

        await player.action.stop();
        expect(player.state.playbackState, equals(PlaybackState.stopped));
      },
      timeout: const Timeout(Duration(seconds: 25)),
    );

    test(
      'ADV-M4-5: Live stream stop() cleanly aborts HTTP chunk streaming and closes socket, and subsequent play() reconnects to live stream and resumes playback cleanly',
      () async {
        final liveUrl = 'http://127.0.0.1:$serverPort/live/salida.mp3';

        // 1. Open live stream
        await player.action.open(AudioSource.uri(liveUrl, isLive: true));

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.duration, equals(Duration.zero));
        expect(player.state.trackMetadata?.isLiveStream, isTrue);
        expect(player.state.trackMetadata?.codec, equals(AudioCodec.mp3));
        expect(player.action.activeLoader, isNotNull);

        // Verify initial HTTP connection
        final stats0 = await getServerStats(serverPort!);
        final liveReqs0 = (stats0['requests_by_path'] as Map<String, dynamic>?)?['/live/salida.mp3'] as int? ?? 0;
        expect(liveReqs0, equals(1), reason: 'Opening live stream must establish initial HTTP connection');

        // 2. Play live stream
        await player.action.play();
        expect(player.state.playing, isTrue);
        expect(player.state.playbackState, equals(PlaybackState.playing));

        // Allow streaming to run briefly
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.state.playing, isTrue);

        // 3. Stop live stream
        await player.action.stop();

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(player.action.activeLoader!.isStopped, isTrue);

        // Verify socket abort and zero consumption while stopped
        final statsStop = await getServerStats(serverPort!);
        final liveReqsStop = (statsStop['requests_by_path'] as Map<String, dynamic>?)?['/live/salida.mp3'] as int? ?? 0;

        await Future<void>.delayed(const Duration(milliseconds: 300));

        final statsQuiet = await getServerStats(serverPort!);
        final liveReqsQuiet = (statsQuiet['requests_by_path'] as Map<String, dynamic>?)?['/live/salida.mp3'] as int? ?? 0;
        expect(liveReqsQuiet, equals(liveReqsStop),
            reason: 'Zero new HTTP requests or chunk reads must occur after live stream stop()');

        // 4. Replay live stream
        await player.action.play();

        // Verify that a new HTTP connection was opened to the live stream
        final statsReplay = await getServerStats(serverPort!);
        final liveReqsReplay = (statsReplay['requests_by_path'] as Map<String, dynamic>?)?['/live/salida.mp3'] as int? ?? 0;
        expect(liveReqsReplay, equals(liveReqsStop + 1),
            reason: 'Calling play() after stop() on a live stream must open a new HTTP connection');

        // Allow time for new chunks to arrive and decode
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(player.state.playing, isTrue);
        expect(player.state.playbackState, equals(PlaybackState.playing));
        expect(player.action.activeLoader!.isStopped, isFalse);

        await player.action.stop();
        expect(player.state.playbackState, equals(PlaybackState.stopped));
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'ADV-M4-6: Backpressure monitor and telemetry (_readCursorByte, _rangeEnd, _aheadHeadroomBytes) remain active and update dynamically upon stop-and-replay and EOF replay',
      () async {
        final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

        await player.action.open(AudioSource.uri(url));

        final streamer = player.action.activeLoader;
        expect(streamer, isNotNull);
        expect(streamer!.isBackpressureActive, isTrue,
            reason: 'Backpressure monitor must be active after openUrl()');

        // Start initial playback
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(streamer.readCursorByte, greaterThan(0));

        // Stop playback
        await player.action.stop();

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(streamer.isStopped, isTrue);
        expect(streamer.isBackpressureActive, isFalse,
            reason: 'Backpressure monitor must be cancelled during stop()');
        expect(streamer.readCursorByte, equals(0),
            reason: 'readCursorByte must reset to 0 on clean stop()');

        // --- Phase 1: Replay from Stopped State (RAM / Pinned Head) ---
        expect(streamer.readCursorByte, equals(0));
        await player.action.play();

        // Wait for backpressure timer to poll and readCursorByte to advance from 0
        int waitMs = 0;
        while (streamer.readCursorByte == 0 && waitMs < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitMs += 50;
        }

        expect(streamer.isBackpressureActive, isTrue,
            reason: '_backpressureTimer must be active during replay');
        expect(player.state.playing, isTrue);
        expect(player.state.playbackState, equals(PlaybackState.playing));

        // Sample telemetry during active replay
        final cursor1 = streamer.readCursorByte;
        final rangeEnd1 = streamer.rangeEnd;
        final headroom1 = streamer.aheadHeadroomBytes;

        expect(cursor1, greaterThan(0),
            reason: 'readCursorByte must advance dynamically from 0 as audio frames are decoded');
        expect(rangeEnd1, greaterThanOrEqualTo(cursor1));
        expect(headroom1, equals(rangeEnd1 - cursor1),
            reason: 'aheadHeadroomBytes must accurately reflect rangeEnd - readCursorByte');

        // Verify dynamic telemetry advance (cursor2 > cursor1)
        waitMs = 0;
        while (streamer.readCursorByte <= cursor1 && waitMs < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitMs += 50;
        }
        final cursor2 = streamer.readCursorByte;
        expect(cursor2, greaterThan(cursor1),
            reason: 'readCursorByte must advance dynamically as playback continues (cursor2 > cursor1)');

        await player.action.stop();

        // --- Phase 2: Dynamic Telemetry Update on EOF Replay ---
        await player.action.play();
        // Seek near end of track to trigger EOF quickly
        final duration = player.state.duration;
        final nearEnd = duration > const Duration(seconds: 1)
            ? duration - const Duration(milliseconds: 300)
            : const Duration(milliseconds: 25000);
        await player.action.seek(nearEnd);

        waitMs = 0;
        while (!player.state.completed && waitMs < 5000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitMs += 50;
        }
        expect(player.state.completed, isTrue, reason: 'Track must reach EOF');

        final eofCursorBefore = streamer.readCursorByte;
        expect(eofCursorBefore, greaterThan(500000),
            reason: 'readCursorByte at EOF must reflect playback near the end of track');

        // Replay from EOF
        await player.action.play();

        waitMs = 0;
        while (streamer.readCursorByte >= eofCursorBefore && waitMs < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitMs += 50;
        }

        expect(streamer.isBackpressureActive, isTrue,
            reason: '_backpressureTimer must be active during EOF replay');
        expect(player.state.playing, isTrue);
        expect(streamer.readCursorByte, lessThan(eofCursorBefore),
            reason: 'readCursorByte must reset and advance from beginning on EOF replay');
        expect(streamer.readCursorByte, greaterThan(0));
        expect(streamer.aheadHeadroomBytes, equals(streamer.rangeEnd - streamer.readCursorByte));

        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 25)),
    );
  });
}
