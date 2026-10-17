// test/challenger_telemetry_network_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late File localWavFile;
  late Uint8List memoryWavBytes;
  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
    // 1. Create synthetic local test WAV file (10 seconds, 440 Hz)
    localWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'challenger_test_track.wav',
      frequencyHz: 440.0,
      durationSeconds: 10.0,
    );

    // 2. Create in-memory synthetic WAV bytes (5 seconds, 554 Hz)
    memoryWavBytes = SyntheticAudioGenerator.generateWavBytes(
      frequencyHz: 554.37,
      durationSeconds: 5.0,
    );

    // 3. Start local Python HTTP test server for network streaming
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
  // Challenge Section 1: Stream Telemetry Order & Invariant Integrity
  // =========================================================================
  group('Challenger: Stream Telemetry Order & Invariant Integrity', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('T1.1: Telemetry state invariants hold throughout the entire opening lifecycle', () async {
      final recordedStates = <PlaybackState>[];
      final recordedOpening = <bool>[];
      final recordedPositions = <Duration>[];

      final s1 = player.stream.playbackState.listen((s) {
        recordedStates.add(s);
        // INVARIANT: When playbackState == opening, opening MUST be true
        if (s == PlaybackState.opening) {
          expect(player.state.opening, isTrue);
          expect(player.state.playing, isFalse);
          expect(player.state.position, equals(Duration.zero));
        }
      });
      final s2 = player.stream.opening.listen(recordedOpening.add);
      final s3 = player.stream.position.listen(recordedPositions.add);

      // Open local file
      await player.action.open(localWavFile.path);
      await Future<void>.delayed(Duration.zero);

      expect(recordedOpening, containsAllInOrder([true, false]));
      expect(recordedStates, containsAllInOrder([PlaybackState.opening, PlaybackState.stopped]));
      expect(player.state.opening, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));
      expect(player.state.duration.inMilliseconds, greaterThanOrEqualTo(9000));

      await s1.cancel();
      await s2.cancel();
      await s3.cancel();
    });

    test('T1.2: Unawaited open + play emits clean transition: opening -> playing', () async {
      final stateTransitions = <PlaybackState>[];
      final sub = player.stream.playbackState.listen(stateTransitions.add);

      final openFuture = player.action.open(localWavFile.path);
      final playFuture = player.action.play();

      expect(player.state.playbackState, equals(PlaybackState.opening));

      await Future.wait([openFuture, playFuture]);

      // Allow audio loop to emit playing state
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);
      expect(player.state.playbackState, equals(PlaybackState.playing));

      await player.action.stop();
      await sub.cancel();

      // Opening must appear before playing in broadcast history
      final openingIndex = stateTransitions.indexOf(PlaybackState.opening);
      final playingIndex = stateTransitions.lastIndexOf(PlaybackState.playing);
      expect(openingIndex, isNonNegative);
      expect(playingIndex, greaterThan(openingIndex));
    });

    test('T1.3: Failed open (404 Not Found) state verification', () async {
      final badUrl = 'http://127.0.0.1:$serverPort/nonexistent_file_404.mp3';

      final openingEvents = <bool>[];
      final stateEvents = <PlaybackState>[];
      final sub1 = player.stream.opening.listen(openingEvents.add);
      final sub2 = player.stream.playbackState.listen(stateEvents.add);

      await expectLater(
        player.action.openUrl(badUrl),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      await Future<void>.delayed(Duration.zero);
      await sub1.cancel();
      await sub2.cancel();

      // Check whether opening is stuck at true and playbackState is stuck at opening
      // Expected by API design: opening should be false after failure
      // Actual bug observed: opening remains true and playbackState remains opening!
      expect(player.state.opening, isFalse, reason: 'BUG: Player is permanently trapped in opening == true after open failure');
      expect(player.state.playbackState, equals(PlaybackState.error), reason: 'BUG: PlaybackState is trapped in opening instead of error');
    });

    test('T1.4: Concurrent unawaited play() during failed open rejects or drops without freezing', () async {
      final badUrl = 'http://127.0.0.1:$serverPort/nonexistent_file_404.mp3';

      final openFuture = player.action.openUrl(badUrl);
      final playFuture = player.action.play();

      // openFuture should fail
      await expectLater(openFuture, throwsA(isA<MiniaudioPlayerException>()));

      // playFuture must resolve or reject, but NEVER hang indefinitely
      try {
        await playFuture.timeout(const Duration(seconds: 3));
      } catch (_) {}

      expect(player.state.opening, isFalse);
      expect(player.state.playing, isFalse);
    });

    test('T1.5: Dispose during active open() shuts down cleanly without throwing unhandled exceptions', () async {
      final slowUrl = 'http://127.0.0.1:$serverPort/stall/salida.mp3?chunk_size=1024&stall_ms=500';

      final playerToDispose = MiniaudioPlayer();
      unawaited(playerToDispose.action.openUrl(slowUrl).catchError((_) {}));

      expect(playerToDispose.state.opening, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await playerToDispose.dispose();

      expect(playerToDispose.isDisposed, isTrue);
    });
  });

  // =========================================================================
  // Challenge Section 2: Out-Of-Bounds Seeks (Negative, Massive, and In-Flight)
  // =========================================================================
  group('Challenger: Out-Of-Bounds Seeks Resilience', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('S2.1: Seeking to negative duration is clamped to Duration.zero across all states', () async {
      final observedPositions = <Duration>[];
      final sub = player.stream.position.listen(observedPositions.add);

      await player.action.open(localWavFile.path);

      // Seek to negative while stopped
      await player.action.seek(const Duration(seconds: -10));
      expect(player.state.position, equals(Duration.zero));

      // Play and seek to negative
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await player.action.seek(const Duration(seconds: -5));
      expect(player.state.position, equals(Duration.zero));

      await player.action.stop();
      await sub.cancel();

      // Verify that stream never emitted a negative duration
      for (final pos in observedPositions) {
        expect(pos.isNegative, isFalse, reason: 'Position stream emitted negative: $pos');
      }
    });

    test('S2.2: Seeking far beyond duration is clamped cleanly without crashing', () async {
      await player.action.open(localWavFile.path);
      final duration = player.state.duration;
      expect(duration.inSeconds, greaterThan(0));

      // Seek to 10 hours on a 10-second file
      await player.action.seek(const Duration(hours: 10));
      expect(player.state.position.inMilliseconds, lessThanOrEqualTo(duration.inMilliseconds));

      // Seek to 100 days
      await player.action.seek(const Duration(days: 100));
      expect(player.state.position.inMilliseconds, lessThanOrEqualTo(duration.inMilliseconds));

      await player.action.stop();
    });

    test('S2.3: Unawaited negative and huge seeks during Opening gate execute accurately after open', () async {
      // Negative seek during open
      final open1 = player.action.open(localWavFile.path);
      final seek1 = player.action.seek(const Duration(seconds: -30));
      await Future.wait([open1, seek1]);
      expect(player.state.position, equals(Duration.zero));

      // Beyond duration seek during open
      final open2 = player.action.open(memoryWavBytes);
      final seek2 = player.action.seek(const Duration(hours: 2));
      await Future.wait([open2, seek2]);
      expect(player.state.position.inMilliseconds, lessThanOrEqualTo(player.state.duration.inMilliseconds));
    });

    test('S2.4: Rapid alternating out-of-bounds seeks stress test', () async {
      await player.action.open(localWavFile.path);
      await player.action.play();

      final hostileDurations = [
        const Duration(seconds: -50),
        const Duration(hours: 5),
        const Duration(seconds: -1),
        const Duration(minutes: 30),
        Duration.zero,
        const Duration(seconds: 4),
        const Duration(days: 1),
        const Duration(seconds: -100),
      ];

      for (final target in hostileDurations) {
        await player.action.seek(target);
        expect(player.state.position.isNegative, isFalse);
        expect(player.state.position.inMilliseconds, lessThanOrEqualTo(player.state.duration.inMilliseconds));
      }

      await player.action.stop();
    });

    test('S2.5: Out-of-bounds seeks on active network HTTP stream clamp safely', () async {
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(netUrl);
      final duration = player.state.duration;

      // Negative seek on network stream
      await player.action.seek(const Duration(seconds: -10));
      expect(player.state.position, equals(Duration.zero));

      // Beyond track length seek on network stream
      await player.action.seek(const Duration(hours: 10));
      expect(player.state.position.inMilliseconds, lessThanOrEqualTo(duration.inMilliseconds));

      // Check state after seeking past duration
      // Note: when seeking past duration, completed is set to true

      // Now seek to 3 seconds
      await player.action.seek(const Duration(seconds: 3));
      final completedAfterSeek3s = player.state.completed;
      final stateAfterSeek3s = player.state.playbackState;

      // BUG: If stateAfterSeek3s is still completed or completedAfterSeek3s is true,
      // calling play() will mistakenly auto-rewind to 0!
      expect(completedAfterSeek3s, isFalse, reason: 'BUG: completed flag is still true after seeking to 3 seconds!');
      expect(stateAfterSeek3s, isNot(PlaybackState.completed), reason: 'BUG: PlaybackState is still completed after seeking to 3 seconds!');

      await player.action.stop();
    });
  });

  // =========================================================================
  // Challenge Section 3: Network Robustness & Connection Failures
  // =========================================================================
  group('Challenger: Network Robustness & Connection Edge Cases', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('N3.1: Connection refused (unbound port) throws MiniaudioPlayerException and resets state', () async {
      // Connect to unused port
      const unusedPort = 59871;
      final refusedUrl = 'http://127.0.0.1:$unusedPort/music/test.mp3';

      await expectLater(
        player.action.openUrl(refusedUrl),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      expect(player.state.opening, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));
    });

    test('N3.2: Corrupt headers endpoint (/corrupt/headers) fails safely without native segfault', () async {
      final corruptUrl = 'http://127.0.0.1:$serverPort/corrupt/headers';

      try {
        await player.action.openUrl(corruptUrl).timeout(const Duration(seconds: 4));
      } catch (e) {
        expect(e, isA<Exception>());
      }

      expect(player.state.opening, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));
    });

    test('N3.3: Rapid switching between network streams cancels superseded HTTP requests', () async {
      final url1 = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      final url2 = 'http://127.0.0.1:$serverPort/music/test_24bit_stereo.wav';

      // Launch first open, then immediately launch second open without awaiting
      unawaited(player.action.openUrl(url1).catchError((_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Second open is the winner
      await player.action.openUrl(url2);

      expect(player.state.opening, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));
      expect(player.state.duration.inMilliseconds, greaterThanOrEqualTo(9000));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('N3.4: Network stream seek(Duration.zero) immediately rewinds without crashing or stalling', () async {
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.openUrl(netUrl);
      await player.action.play();

      // Let it play forward
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.position.inMilliseconds, greaterThan(200));

      // Seek back to zero
      await player.action.seek(Duration.zero);
      expect(player.state.position.inMilliseconds, lessThan(200));

      // Verify it continues playing from the beginning
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });
  });
}
