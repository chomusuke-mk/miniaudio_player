import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUpAll(() async {
    MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
    await MiniaudioPlayer.ensureInitialized();
  });

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('AudioSource Model & Factory Tests', () {
    test('AudioSource String instantiates AudioSource correctly', () {
      final source = AudioSource('/path/to/song.mp3');
      expect(source, isA<AudioSource>());
      expect(source.uri, equals('/path/to/song.mp3'));
    });

    test('AudioSource Uint8List instantiates AudioSource correctly', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final source = AudioSource(bytes);
      expect(source, isA<AudioSource>());
      expect(source.bytes, equals(bytes));
    });

    test(
        'AudioSource network URL with headers instantiates AudioSource correctly',
        () {
      final uri = Uri.parse('https://example.com/audio.mp3');
      final source = AudioSource(uri, headers: {'Auth': 'Bearer token'});
      expect(source, isA<AudioSource>());
      expect(source.uri, equals('https://example.com/audio.mp3'));
      expect(source.headers?['Auth'], equals('Bearer token'));
    });

    test('AudioSource parses Uri schemes polymorphically', () {
      expect(
        AudioSource(Uri.parse('file:///path/to/song.mp3')),
        isA<AudioSource>(),
      );
      expect(
        AudioSource(Uri.parse('http://example.com/audio.mp3')),
        isA<AudioSource>(),
      );
      expect(
        AudioSource(Uri.parse('https://example.com/audio.mp3')),
        isA<AudioSource>(),
      );
    });
  });

  group('Direct Memory Playback (AudioSource<Uint8List>)', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer(
          queue: [AudioSource('example/assets/music/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test(
        'decodes and plays MP3 directly from memory buffer with accurate duration and frees Dart bytes',
        () async {
      final mp3File = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3File.existsSync(), isTrue, reason: '01_Apex_Momentum.mp3 must exist');
      final bytes = await mp3File.readAsBytes();
      final memSource = AudioSource(bytes);

      await player.action.setQueue([memSource]);
      expect(memSource.bytes, isNull,
          reason: 'Dart bytes must be cleared after transfer to Rust');
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.duration?.inSeconds, inInclusiveRange(170, 182));
      expect(player.state.isPlaying, isTrue);

      await player.action.seek(const Duration(seconds: 10));
      expect(player.state.position.inSeconds, inInclusiveRange(9, 12));

      await player.action.pause();
      expect(player.state.isPlaying, isFalse);

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('decodes and plays FLAC directly from memory buffer', () async {
      final flacFile = resolveAsset('example/assets/music/04_Belaya_Tishina.flac');
      expect(flacFile.existsSync(), isTrue);
      final bytes = await flacFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('decodes and plays WAV directly from memory buffer', () async {
      final wavFile = resolveAsset('example/assets/music/17_Running_To_Meet_The_Sun.wav');
      expect(wavFile.existsSync(), isTrue);
      final bytes = await wavFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('decodes and plays OGG directly from memory buffer', () async {
      final oggFile = resolveAsset('example/assets/music/05_Burning_in_the_Electric_Light.ogg');
      expect(oggFile.existsSync(), isTrue);
      final bytes = await oggFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('decodes and plays OPUS directly from memory buffer', () async {
      final opusFile = resolveAsset('example/assets/music/02_Bailando_con_tu_recuerdo.opus');
      expect(opusFile.existsSync(), isTrue);
      final bytes = await opusFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('adversarial: empty memory buffer throws MiniaudioPlayerException',
        () async {
      await player.action.setQueue([AudioSource(Uint8List(0))]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test(
        'adversarial: corrupt random memory buffer throws MiniaudioPlayerException',
        () async {
      final rng = Random(42);
      final corruptBytes =
          Uint8List.fromList(List.generate(4096, (_) => rng.nextInt(256)));

      await player.action.setQueue([AudioSource(corruptBytes)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('stress: rapid repeated memory playback cycles without memory leaks',
        () async {
      final mp3File = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      final bytes = await mp3File.readAsBytes();

      for (var i = 0; i < 20; i++) {
        await player.action.setQueue([AudioSource(bytes)]);
        await player.action.play();
        expect(player.state.duration?.inSeconds, greaterThan(0));
        expect(player.state.isPlaying, isTrue);
        await player.action.stop();
      }
    });
  });

  group('Asset Playback (AudioSource)', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer(
          queue: [AudioSource('example/assets/music/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('resolves asset via bytes', () async {
      final mp3File = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      final bytes = await mp3File.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('resolves local file candidate', () async {
      await player.action.setQueue([AudioSource('example/assets/music/01_Apex_Momentum.mp3')]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test(
        'non-existent file throws MiniaudioPlayerException with errorFileNotFound',
        () async {
      await player.action
          .setQueue([AudioSource('non_existent_dir/no_audio_file.mp3')]);
      expect(
        () => player.action.play(),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorFileNotFound),
          ),
        ),
      );
    });
  });

  group('Adversarial HTTP Network & Streaming Playback (Python HTTP Server)',
      () {
    Process? serverProcess;
    int? serverPort;
    late MiniaudioPlayer player;

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
        onTimeout: () =>
            throw TimeoutException('Failed to start python test HTTP server'),
      );
    });

    tearDownAll(() async {
      if (serverPort != null) {
        try {
          final client = HttpClient();
          final req = await client
              .getUrl(Uri.parse('http://127.0.0.1:$serverPort/shutdown'));
          final res = await req.close();
          await res.drain();
        } catch (_) {}
      }
      serverProcess?.kill();
      await serverProcess?.exitCode;
    });

    setUp(() {
      player = MiniaudioPlayer(
          queue: [AudioSource('example/assets/music/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('progressive HTTP playback with duration, play, pause and stop',
        () async {
      final url = 'http://127.0.0.1:$serverPort/music/01_Apex_Momentum.mp3';
      await player.action.setQueue([AudioSource(url)]);
      await player.action.play();

      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.duration?.inSeconds, inInclusiveRange(172, 182));

      expect(player.state.isPlaying, isTrue);

      await player.action.pause();
      expect(player.state.isPlaying, isFalse);

      await player.action.play();
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('progressive HTTP playback with arbitrary Byte-Range seeking',
        () async {
      final url = 'http://127.0.0.1:$serverPort/music/01_Apex_Momentum.mp3';
      await player.action.setQueue([AudioSource(Uri.parse(url))]);

      await player.action.play();
      expect(player.state.isPlaying, isTrue);

      // Seek to 30 seconds via HTTP Byte-Range request
      await player.action.seek(const Duration(seconds: 30));

      expect(player.state.position.inSeconds, inInclusiveRange(28, 33));

      await player.action.stop();
    });

    test(
        'progressive HTTP playback of CBR MP3 without Xing header correctly detects duration and supports seeking',
        () async {
      final url = 'http://127.0.0.1:$serverPort/music/03_Before_The_Dawn_cbr_noxing.mp3';
      await player.action.setQueue([AudioSource(url)]);
      await player.action.play();

      // CBR sniffer should resolve duration to ~180 seconds instead of defaulting to 0
      expect(player.state.duration?.inSeconds, inInclusiveRange(175, 185));
      expect(player.state.audioInfo?.bitrate, greaterThan(0));

      expect(player.state.isPlaying, isTrue);

      // Seek to 5 seconds via Byte-Range request
      await player.action.seek(const Duration(seconds: 5));

      expect(player.state.position.inSeconds, inInclusiveRange(4, 7));

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('progressive HTTP playback with custom request headers', () async {
      final url = 'http://127.0.0.1:$serverPort/music/17_Running_To_Meet_The_Sun.wav';
      await player.action.setQueue([
        AudioSource(
          Uri.parse(url),
          headers: {'X-Custom-Auth': 'Bearer SecretToken123'},
        ),
      ]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('progressive HTTP playback of FLAC over network', () async {
      final url = 'http://127.0.0.1:$serverPort/music/04_Belaya_Tishina.flac';
      await player.action.setQueue([AudioSource(url)]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('progressive HTTP playback of OGG with forward and backward seeking',
        () async {
      final url = 'http://127.0.0.1:$serverPort/music/05_Burning_in_the_Electric_Light.ogg';
      await player.action.setQueue([AudioSource(url)]);
      await player.action.play();

      expect(player.state.duration?.inSeconds, inInclusiveRange(172, 185));
      expect(player.state.isPlaying, isTrue);

      // 1. Seek forward near the end (55 seconds)
      await player.action.seek(const Duration(seconds: 55));
      expect(player.state.position.inSeconds, inInclusiveRange(53, 58));
      expect(player.state.isPlaying, isTrue);

      // 2. Seek backward to an earlier position (20 seconds)
      await player.action.seek(const Duration(seconds: 20));
      expect(player.state.position.inSeconds, inInclusiveRange(18, 23));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test(
        'adversarial: HTTP 404 Not Found throws MiniaudioPlayerException with errorFileNotFound',
        () async {
      final url = 'http://127.0.0.1:$serverPort/error/404';
      await player.action.setQueue([AudioSource(url)]);
      expect(
        () => player.action.play(),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorFileNotFound),
          ),
        ),
      );
    });

    test(
        'adversarial: HTTP 403 Forbidden throws MiniaudioPlayerException with errorAccessDenied',
        () async {
      final url = 'http://127.0.0.1:$serverPort/error/403';
      await player.action.setQueue([AudioSource(url)]);
      expect(
        () => player.action.play(),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorAccessDenied),
          ),
        ),
      );
    });

    test(
        'adversarial: HTTP 500 Internal Server Error throws MiniaudioPlayerException',
        () async {
      final url = 'http://127.0.0.1:$serverPort/error/500';
      await player.action.setQueue([AudioSource(url)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: HTTP 302 Redirection is followed transparently',
        () async {
      final url =
          'http://127.0.0.1:$serverPort/redirect/302?target=/music/01_Apex_Momentum.mp3';
      await player.action.setQueue([AudioSource(url)]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test(
        'adversarial: unreachable host/port throws MiniaudioPlayerException without hanging',
        () async {
      // Connect to unused local port 59991
      final unreachableUrl = 'http://127.0.0.1:59991/audio.mp3';
      await player.action.setQueue([AudioSource(unreachableUrl)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test(
        'adversarial: corrupt HTTP response headers throws MiniaudioPlayerException',
        () async {
      final url = 'http://127.0.0.1:$serverPort/corrupt/headers';
      await player.action.setQueue([AudioSource(url)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test(
        'adversarial: throttled slow network connection streams with buffering',
        () async {
      final slowUrl =
          'http://127.0.0.1:$serverPort/slow/01_Apex_Momentum.mp3?delay=0.01&chunk=4096';
      await player.action.setQueue([AudioSource(slowUrl)]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      await waitForAudioProgress(
        player,
        minDelta: const Duration(milliseconds: 50),
        timeout: const Duration(seconds: 3),
      );
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('adversarial: sudden socket closure during buffering throws cleanly',
        () async {
      final dropUrl =
          'http://127.0.0.1:$serverPort/drop/01_Apex_Momentum.mp3?after=16384';
      await player.action.setQueue([AudioSource(dropUrl)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test(
        'adversarial: sudden socket closure / connection drop mid-stream does not crash audio thread',
        () async {
      final dropUrl =
          'http://127.0.0.1:$serverPort/drop/01_Apex_Momentum.mp3?after=393216';
      await player.action.setQueue([AudioSource(dropUrl)]);

      await player.action.play();
      // Let it decode/render until frames advance or connection closes cleanly
      await waitForAudioProgress(
        player,
        minDelta: const Duration(milliseconds: 60),
        timeout: const Duration(seconds: 3),
      );

      // Native audio engine must remain healthy and cleanly stop
      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test(
        'continuous live chunked stream plays without crashing and stops cleanly',
        () async {
      final liveUrl = 'http://127.0.0.1:$serverPort/live/01_Apex_Momentum.mp3';
      await player.action.setQueue([AudioSource(Uri.parse(liveUrl))]);

      await player.action.play();
      await waitForAudioProgress(
        player,
        minDelta: const Duration(milliseconds: 60),
        timeout: const Duration(seconds: 3),
      );
      expect(player.state.isPlaying, isTrue);

      // Volume adjustments during live stream
      await player.action.setVolume(0.5);
      expect(player.state.volume, closeTo(0.5, 0.01));

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test(
        'rapid polymorphic setQueue switching between memory, network, and asset sources',
        () async {
      final mp3File = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      final bytes = await mp3File.readAsBytes();
      final netUrl = 'http://127.0.0.1:$serverPort/music/01_Apex_Momentum.mp3';

      for (var i = 0; i < 5; i++) {
        // 1. Memory
        await player.action.setQueue([AudioSource(bytes)]);
        await player.action.play();
        expect(player.state.isPlaying, isTrue);

        // 2. Network
        await player.action.setQueue([AudioSource(Uri.parse(netUrl))]);
        await player.action.play();
        expect(player.state.isPlaying, isTrue);

        // 3. Asset
        await player.action.setQueue([AudioSource('example/assets/music/01_Apex_Momentum.mp3')]);
        await player.action.play();
        expect(player.state.isPlaying, isTrue);

        await player.action.stop();
      }
    });

    test(
        'analyzeAudio on live stream resolves promptly with null duration, format info and skips waveform/replaygain/chromaprint',
        () async {
      final liveUrl = 'http://127.0.0.1:$serverPort/live/01_Apex_Momentum.mp3';

      final result = await MiniaudioPlayer.analyzeAudio(
        liveUrl,
        replayGain: true,
        waveform: true,
        chromaprint: true,
        metadata: true,
      ).timeout(const Duration(seconds: 4));

      // 1. Duration must be null for livestreams
      expect(result.audioInfo.duration, isNull);

      // 2. Format info is accurately extracted
      expect(result.audioInfo.sampleRate, equals(48000));
      expect(result.audioInfo.channels, equals(2));
      expect(result.audioInfo.codec, equals('MP3'));

      // 3. ReplayGain, Waveform, and Chromaprint must NOT be computed for livestreams
      expect(result.replayGain, isNull);
      expect(result.waveform, isNull);
      expect(result.chromaprint, isNull);
    });

    test(
        'analyzeAudio error handling on non-existent HTTP URL (404) throws MiniaudioPlayerException with errorFileNotFound',
        () async {
      final notFoundUrl = 'http://127.0.0.1:$serverPort/error/404';

      expect(
        () => MiniaudioPlayer.analyzeAudio(notFoundUrl),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorFileNotFound),
          ),
        ),
      );
    });

    test(
        'analyzeAudio error handling on unreachable host/port throws MiniaudioPlayerException without hanging',
        () async {
      final unreachableUrl = 'http://127.0.0.1:59991/audio.mp3';

      expect(
        () => MiniaudioPlayer.analyzeAudio(unreachableUrl)
            .timeout(const Duration(seconds: 4)),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorFileNotFound),
          ),
        ),
      );
    });

    test(
        'analyzeAudio error handling on non-existent local file throws MiniaudioPlayerException with errorFileNotFound',
        () async {
      const nonExistentFile = '/path/to/missing_local_file_analysis_12345.mp3';

      expect(
        () => MiniaudioPlayer.analyzeAudio(nonExistentFile),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorFileNotFound),
          ),
        ),
      );
    });

    test(
        'analyzeAudio error handling on HTTP 500 Internal Server Error throws MiniaudioPlayerException with errorDecodeFailed',
        () async {
      final serverErrorUrl = 'http://127.0.0.1:$serverPort/error/500';

      expect(
        () => MiniaudioPlayer.analyzeAudio(serverErrorUrl),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorDecodeFailed),
          ),
        ),
      );
    });
  });
}
