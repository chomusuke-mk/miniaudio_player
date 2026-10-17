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
  late Uint8List memoryWavBytes;
  Process? serverProcess;
  int? serverPort;

  setUpAll(() async {
    // 1. Create synthetic local test WAV file (10 seconds)
    localWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'm1_test_track.wav',
      frequencyHz: 440.0,
      durationSeconds: 10.0,
    );

    // 2. Create in-memory synthetic WAV bytes (10 seconds)
    memoryWavBytes = SyntheticAudioGenerator.generateWavBytes(
      frequencyHz: 554.37,
      durationSeconds: 10.0,
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
  // Group 1: State Machine & Stream Telemetry for Opening State
  // =========================================================================
  group('1. State Machine & Stream Telemetry for Opening State', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('1.1: Initial player state is stopped and opening is false', () {
      expect(player.state.opening, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));
      expect(player.state.playbackState.isStopped, isTrue);
      expect(player.state.playbackState.isOpening, isFalse);
    });

    test('1.2: stream.opening and stream.playbackState broadcast during open()', () async {
      final openingEvents = <bool>[];
      final stateEvents = <PlaybackState>[];

      final sub1 = player.stream.opening.listen(openingEvents.add);
      final sub2 = player.stream.playbackState.listen(stateEvents.add);

      // Also verify MiniaudioPlayer direct getters
      final directOpeningEvents = <bool>[];
      final sub3 = player.opening.listen(directOpeningEvents.add);

      final openFuture = player.action.open(localWavFile.path);

      // Verify that opening is true immediately while open is in flight
      expect(player.state.opening, isTrue);
      expect(player.state.playbackState, equals(PlaybackState.opening));

      await openFuture;

      expect(player.state.opening, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));

      await Future<void>.delayed(Duration.zero);
      await sub1.cancel();
      await sub2.cancel();
      await sub3.cancel();

      expect(openingEvents, containsAllInOrder([true, false]));
      expect(directOpeningEvents, containsAllInOrder([true, false]));
      expect(stateEvents, containsAllInOrder([PlaybackState.opening, PlaybackState.stopped]));
    });

    test('1.3: Stale playback telemetry is flushed immediately upon opening', () async {
      // First play local file to advance position and telemetry
      await player.action.open(localWavFile.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.position.inMilliseconds, greaterThan(100));
      expect(player.state.playing, isTrue);

      // Open new source - telemetry must reset immediately synchronously
      player.action.open(memoryWavBytes);

      expect(player.state.opening, isTrue);
      expect(player.state.playing, isFalse);
      expect(player.state.position, equals(Duration.zero));
      expect(player.state.duration, equals(Duration.zero));
      expect(player.state.playbackState, equals(PlaybackState.opening));
    });
  });

  // =========================================================================
  // Group 2: Unawaited play() immediately after open()
  // =========================================================================
  group('2. Unawaited play() immediately after open()', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('2.1: Local file: play() immediately after open() without await starts cleanly', () async {
      // Critical test: DO NOT AWAIT open()!
      player.action.open(localWavFile.path);
      final playFuture = player.action.play();

      await playFuture;

      expect(player.state.playing, isTrue);
      expect(player.state.playbackState, equals(PlaybackState.playing));

      // Verify audio position advances without stalling (diff > 0)
      final initialPos = player.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final advancedPos = player.state.position;

      expect(advancedPos.inMilliseconds, greaterThan(initialPos.inMilliseconds));
      expect(advancedPos.inMilliseconds - initialPos.inMilliseconds, greaterThan(150));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('2.2: Memory buffer: play() immediately after openMemory() without await starts cleanly', () async {
      player.action.openMemory(memoryWavBytes);
      final playFuture = player.action.play();

      await playFuture;

      expect(player.state.playing, isTrue);
      expect(player.state.playbackState, equals(PlaybackState.playing));

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.position.inMilliseconds, greaterThan(100));

      await player.action.stop();
    });

    test('2.3: Remote HTTP stream: play() immediately after openUrl() without await starts cleanly', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      // DO NOT AWAIT openUrl!
      player.action.openUrl(url);
      final playFuture = player.action.play();

      await playFuture;

      expect(player.state.playing, isTrue);
      expect(player.state.playbackState, equals(PlaybackState.playing));

      // Wait for position to advance
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.position.inMilliseconds, greaterThan(150));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 3: Unawaited seek() immediately after open()
  // =========================================================================
  group('3. Unawaited seek() immediately after open()', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('3.1: seek() immediately after open() without await seeks accurately', () async {
      const targetSeek = Duration(seconds: 4);

      player.action.open(localWavFile.path);
      final seekFuture = player.action.seek(targetSeek);
      final playFuture = player.action.play();

      await Future.wait([seekFuture, playFuture]);

      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(3800));

      // Allow position to continue advancing from seek target
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.position.inMilliseconds, greaterThan(4000));

      await player.action.stop();
    });

    test('3.2: Remote stream: seek() immediately after openUrl() without await seeks accurately', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      const targetSeek = Duration(seconds: 5);

      player.action.openUrl(url);
      final seekFuture = player.action.seek(targetSeek);
      final playFuture = player.action.play();

      await Future.wait([seekFuture, playFuture]);

      expect(player.state.playing, isTrue);
      expect(player.state.position.inSeconds, closeTo(5, 2));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // =========================================================================
  // Group 4: Rapid Interleaved Transport Calls & Stress Interleaving
  // =========================================================================
  group('4. Rapid Interleaved Transport Calls & Stress Interleaving', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async {
      if (!player.isDisposed) await player.dispose();
    });

    test('4.1: Rapid track switching with unawaited play/seek cancels stale tasks cleanly', () async {
      final url1 = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      final url2 = 'http://127.0.0.1:$serverPort/music/salida.ogg';

      // Interleave open/play/open/seek rapidly
      player.action.openUrl(url1);
      player.action.play(); // Queued for url1
      player.action.seek(const Duration(seconds: 2));

      // Immediately switch track to url2 before url1 finishes opening
      player.action.openUrl(url2);
      player.action.seek(const Duration(seconds: 1));
      final finalPlayFuture = player.action.play(); // Queued for url2

      await finalPlayFuture;

      expect(player.state.playing, isTrue);
      // Wait for playback to confirm it is url2 advancing
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.state.position.inMilliseconds, greaterThan(800));

      await player.action.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('4.2: pause() during opening cancels pending unawaited play()', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      player.action.openUrl(url);
      player.action.play(); // Queued
      player.action.pause(); // Should cancel queued play!

      // Wait a short time for open to finish in background
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // Player must be stopped/paused, NOT playing
      expect(player.state.playing, isFalse);
      expect(player.state.playbackState, isIn([PlaybackState.stopped, PlaybackState.paused]));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('4.3: stop() during opening aborts and resets state to stopped', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      player.action.openUrl(url);
      player.action.play();
      player.action.seek(const Duration(seconds: 5));
      player.action.stop(); // Cancels opening and queued commands

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(player.state.opening, isFalse);
      expect(player.state.playing, isFalse);
      expect(player.state.playbackState, equals(PlaybackState.stopped));
      expect(player.state.position, equals(Duration.zero));
    });

    test('4.4: 50-iteration rapid chaotic interleaving across mixed sources', () async {
      final rng = Random(1234);
      final sources = [
        localWavFile.path,
        'http://127.0.0.1:$serverPort/music/salida.mp3',
        'http://127.0.0.1:$serverPort/music/salida.ogg',
      ];

      for (int i = 0; i < 50; i++) {
        final op = rng.nextInt(5);
        switch (op) {
          case 0:
            final src = sources[rng.nextInt(sources.length)];
            player.action.open(src).catchError((_) {});
            break;
          case 1:
            player.action.play().catchError((_) {});
            break;
          case 2:
            player.action.pause().catchError((_) {});
            break;
          case 3:
            player.action.seek(Duration(seconds: rng.nextInt(5))).catchError((_) {});
            break;
          case 4:
            player.action.stop().catchError((_) {});
            break;
        }
        if (rng.nextBool()) {
          await Future<void>.delayed(Duration(microseconds: rng.nextInt(300)));
        }
      }

      // After chaotic burst, verify the engine recovers and plays normally
      await player.action.open(localWavFile.path);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(player.state.playing, isTrue);
      expect(player.state.position.inMilliseconds, greaterThan(100));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
