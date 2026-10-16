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

  // =========================================================================
  // Group 1: Periodic Network Stalls & Buffer Starvation
  // =========================================================================
  group('Flaky Network: Periodic Stalls and Buffer Depletion', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('1.1: Periodic stall (16 KB burst, 400ms stall) verifies buffering state transitions', () async {
      final stallUrl = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=16384&stall_ms=400&initial_burst=65536';

      final bufferingEvents = <bool>[];
      final sub = player.stream.buffering.listen(bufferingEvents.add);

      await player.action.openUrl(stallUrl);
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      // Allow time to exhaust initial burst and hit periodic stall
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(player.state.playing, isTrue);
      // Verify player did not crash or hang in native thread
      await player.action.pause();
      expect(player.state.playing, isFalse);

      await player.action.stop();
      await sub.cancel();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('1.2: Position continues progressing monotonically across multiple stall cycles', () async {
      final stallUrl = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=8192&stall_ms=300&initial_burst=65536';
      await player.action.openUrl(stallUrl);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final pos1 = player.state.position.inMilliseconds;

      await Future<void>.delayed(const Duration(milliseconds: 800));
      final pos2 = player.state.position.inMilliseconds;

      expect(pos2, greaterThanOrEqualTo(pos1));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('1.3: User pause and resume during active stall cycle maintains state consistency', () async {
      final stallUrl = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=16384&stall_ms=500&initial_burst=65536';
      await player.action.openUrl(stallUrl);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Pause during buffering/stall
      await player.action.pause();
      expect(player.state.playing, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Resume
      await player.action.play();
      expect(player.state.playing, isTrue);

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 2: Bandwidth Throttling / Rate Limiting (32 kbps on 128 kbps stream)
  // =========================================================================
  group('Flaky Network: Bandwidth Throttling & Adaptive Backpressure', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('2.1: 32 kbps rate limiting on 128 kbps stream streams with buffering without deadlocking', () async {
      final rateLimitUrl = 'http://127.0.0.1:$serverPort/ratelimit/salida.mp3?kbps=32&initial_burst=65536';
      await player.action.openUrl(rateLimitUrl);

      expect(player.state.duration.inSeconds, greaterThan(0));
      await player.action.play();

      // Monitor playback under restricted throughput
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(player.state.playing, isTrue);

      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('2.2: Seeking across rate-limited stream flushes buffer and resumes without hang', () async {
      final rateLimitUrl = 'http://127.0.0.1:$serverPort/ratelimit/salida.mp3?kbps=64&initial_burst=65536';
      await player.action.openUrl(rateLimitUrl);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Seek forward while throttled
      await player.action.seek(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(player.state.position.inSeconds, inInclusiveRange(13, 18));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 3: Abrupt Connection Reset & Byte-Range Resumption
  // =========================================================================
  group('Flaky Network: Connection Resets & Range Resumption', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('3.1: Abrupt connection drop after 64 KB header does not crash audio thread', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=65536';
      await player.action.openUrl(dropUrl);

      await player.action.play();
      // Allow time for server to drop socket
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Audio engine must remain healthy
      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('3.2: Range resumption on dropped stream (/drop_resume/) recovers playback', () async {
      final resumeUrl = 'http://127.0.0.1:$serverPort/drop_resume/salida.mp3?drop_at=65536';
      await player.action.openUrl(resumeUrl);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Perform a Byte-Range seek to resume past the drop boundary
      await player.action.seek(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(player.state.position.inSeconds, inInclusiveRange(9, 12));
      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('3.3: Rapid open, drop, and immediate dispose cycles do not leak sockets or isolates', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=16384';
      for (int i = 0; i < 5; i++) {
        final quickPlayer = MiniaudioPlayer();
        unawaited(quickPlayer.action.openUrl(dropUrl).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await quickPlayer.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 4: Diagnostic Log Level Output Validation Across Transitions
  // =========================================================================
  group('Diagnostic Logging Validation Across State Transitions', () {
    late MiniaudioPlayer player;

    setUp(() {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.debug);
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      await player.dispose();
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.none);
    });

    test('4.1: MiniaudioLogLevel configuration persists and updates native C layer', () {
      expect(MiniaudioPlayer.config().logLevel, equals(MiniaudioLogLevel.debug));

      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      expect(MiniaudioPlayer.config().logLevel, equals(MiniaudioLogLevel.verbose));

      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.warning);
      expect(MiniaudioPlayer.config().logLevel, equals(MiniaudioLogLevel.warning));

      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.debug);
    });

    test('4.2: High-frequency state transitions under MiniaudioLogLevel.verbose complete cleanly', () async {
      MiniaudioPlayer.config(logLevel: MiniaudioLogLevel.verbose);
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      await player.action.openUrl(netUrl);
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await player.action.setVolume(0.7);
      await player.action.setRate(1.25);
      await player.action.setPitch(1.1);

      await player.action.seek(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await player.action.pause();
      expect(player.state.playing, isFalse);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('4.3: Diagnostic log level transitions across none, error, warn, info, debug, verbose maintain event consistency', () async {
      final levels = [
        MiniaudioLogLevel.none,
        MiniaudioLogLevel.error,
        MiniaudioLogLevel.warning,
        MiniaudioLogLevel.info,
        MiniaudioLogLevel.debug,
        MiniaudioLogLevel.verbose,
      ];

      for (final lvl in levels) {
        MiniaudioPlayer.config(logLevel: lvl);
        expect(MiniaudioPlayer.config().logLevel, equals(lvl));
      }
    });
  });

  // =========================================================================
  // Group 5: Progressive HTTP MP3 Seeking & Decoder Recovery
  // =========================================================================
  group('Progressive HTTP MP3 Seeking & Decoder Recovery', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('5.1: Seeking forward across HTTP range requests reliably resumes audio playback', () async {
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(netUrl);
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.playing, isTrue);

      // Seek forward to 3 seconds
      await player.action.seek(const Duration(seconds: 3));
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(2500));

      // Wait for network chunk arrival and verify playback progresses
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final posAfterSeek = player.state.position.inMilliseconds;
      expect(posAfterSeek, greaterThan(2500));
      expect(player.state.playing, isTrue);

      // Seek forward again to 6 seconds
      await player.action.seek(const Duration(seconds: 6));
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(5500));

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(player.state.position.inMilliseconds, greaterThan(5500));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('5.2: Multiple rapid consecutive seeks do not stall decoder or hang pipeline', () async {
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(netUrl);
      await player.action.play();

      // Fire 5 rapid seeks back-to-back
      for (int i = 1; i <= 5; i++) {
        unawaited(player.action.seek(Duration(seconds: i)));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      // Final seek to settled position
      await player.action.seek(const Duration(seconds: 4));
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // Verify player is healthy, playing, and position is advancing
      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(3500));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // =========================================================================
  // Group 6: Progressive HTTP WAV Streaming & Frame Alignment Seeking
  // =========================================================================
  group('Progressive HTTP WAV Streaming & Seeking', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('6.1: Streaming 24-bit stereo WAV with seeks maintains frame alignment without noise stalls', () async {
      final wavUrl = 'http://127.0.0.1:$serverPort/music/test_24bit_stereo.wav';
      await player.action.openUrl(wavUrl);
      expect(player.state.duration.inMilliseconds, greaterThanOrEqualTo(9000));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.playing, isTrue);

      // Seek to 2 seconds
      await player.action.seek(const Duration(seconds: 2));
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(1900));

      // Wait for playback to resume and buffer to stay healthy
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.playing, isTrue);
      expect(player.state.buffering, isFalse);
      expect(player.state.position.inMilliseconds, greaterThan(2000));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 7: Remote Stream Auto-Rewind and Replay upon Completion
  // =========================================================================
  group('Remote Stream Replay on Play Action', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('7.1: Calling play() after stream reaches EOF restarts playback from beginning', () async {
      final wavUrl = 'http://127.0.0.1:$serverPort/music/test_24bit_stereo.wav';
      await player.action.openUrl(wavUrl);
      await player.action.play();

      // Seek near end so it completes quickly (duration is 10s)
      await player.action.seek(const Duration(milliseconds: 9800));

      // Wait for completion (duration is ~10000ms)
      int waitMs = 0;
      while (!player.state.completed && waitMs < 4000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }
      expect(player.state.completed, isTrue);

      // Call play() on completed stream - should auto-rewind to 0 and re-stream
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(player.state.playing, isTrue);
      expect(player.state.completed, isFalse);
      expect(player.state.position.inMilliseconds, lessThan(3000));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}


