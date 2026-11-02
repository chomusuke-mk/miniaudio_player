import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/api/player_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('AudioSource Model & Factory Tests', () {
    test('AudioSource String instantiates UriAudioSource correctly', () {
      final source = AudioSource('/path/to/song.mp3');
      expect(source, isA<UriAudioSource>());
      expect((source as UriAudioSource).sourceString, equals('/path/to/song.mp3'));
    });

    test('AudioSource Uint8List instantiates MemoryAudioSource correctly', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final source = AudioSource(bytes);
      expect(source, isA<MemoryAudioSource>());
      expect((source as MemoryAudioSource).bytes, equals(bytes));
    });

    test('AudioSource network URL with headers instantiates UriAudioSource correctly', () {
      final uri = Uri.parse('https://example.com/audio.mp3');
      final source = AudioSource(uri, headers: {'Auth': 'Bearer token'});
      expect(source, isA<UriAudioSource>());
      final netSource = source as UriAudioSource;
      expect(netSource.sourceString, equals('https://example.com/audio.mp3'));
      expect(netSource.headers?['Auth'], equals('Bearer token'));
    });

    test('AudioSource parses Uri schemes polymorphically', () {
      expect(
        AudioSource(Uri.parse('file:///path/to/song.mp3')),
        isA<UriAudioSource>(),
      );
      expect(
        AudioSource(Uri.parse('http://example.com/audio.mp3')),
        isA<UriAudioSource>(),
      );
      expect(
        AudioSource(Uri.parse('https://example.com/audio.mp3')),
        isA<UriAudioSource>(),
      );
    });
  });

  group('Direct Memory Playback (openMemory & MemoryAudioSource)', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer(AudioSource('test/fixtures/tripartite/eof_chirp.mp3'));
    });

    tearDown(() async {
      await player.dispose();
    });

    test('decodes and plays MP3 directly from memory buffer with accurate duration', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3File.existsSync(), isTrue, reason: 'salida.mp3 must exist');
      final bytes = await mp3File.readAsBytes();

      await player.action.open(AudioSource(bytes));
      expect(player.state.duration.inSeconds, greaterThan(0));
      expect(player.state.duration.inSeconds, inInclusiveRange(65, 75));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.seek(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(player.state.position.inSeconds, inInclusiveRange(9, 12));

      await player.action.pause();
      expect(player.state.playing, isFalse);

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('decodes and plays FLAC directly from memory buffer', () async {
      final flacFile = resolveAsset('test/fixtures/salida.flac');
      expect(flacFile.existsSync(), isTrue);
      final bytes = await flacFile.readAsBytes();

      await player.action.open(AudioSource(bytes));
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('decodes and plays WAV directly from memory buffer', () async {
      final wavFile = resolveAsset('test/fixtures/salida.wav');
      expect(wavFile.existsSync(), isTrue);
      final bytes = await wavFile.readAsBytes();

      await player.action.open(AudioSource(bytes));
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('decodes and plays OGG directly from memory buffer', () async {
      final oggFile = resolveAsset('test/fixtures/salida.ogg');
      expect(oggFile.existsSync(), isTrue);
      final bytes = await oggFile.readAsBytes();

      await player.action.open(AudioSource(bytes));
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('decodes and plays OPUS directly from memory buffer', () async {
      final opusFile = resolveAsset('test/fixtures/salida.opus');
      expect(opusFile.existsSync(), isTrue);
      final bytes = await opusFile.readAsBytes();

      await player.action.open(AudioSource(bytes));
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('adversarial: empty memory buffer throws MiniaudioPlayerException', () async {
      expect(
        () => player.action.open(AudioSource(Uint8List(0))),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: corrupt random memory buffer throws MiniaudioPlayerException', () async {
      final rng = Random(42);
      final corruptBytes = Uint8List.fromList(List.generate(4096, (_) => rng.nextInt(256)));

      expect(
        () => player.action.open(AudioSource(corruptBytes)),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('stress: rapid repeated openMemory cycles without memory leaks', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      final bytes = await mp3File.readAsBytes();

      for (var i = 0; i < 20; i++) {
        await player.action.open(AudioSource(bytes));
        expect(player.state.duration.inSeconds, greaterThan(0));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await player.action.stop();
      }
    });
  });

  group('Asset Playback (openAsset & AssetAudioSource)', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer(AudioSource('test/fixtures/tripartite/eof_chirp.mp3'));
    });

    tearDown(() async {
      MiniaudioPlayerGlobalConfig.assetLoader = null;
      await player.dispose();
    });

    test('resolves asset via bytes', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      final bytes = await mp3File.readAsBytes();

      await player.action.open(AudioSource(bytes));
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('resolves local file candidate', () async {
      await player.action.open(AudioSource('test/fixtures/salida.mp3'));
      expect(player.state.duration.inSeconds, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('non-existent file throws MiniaudioPlayerException with errorFileNotFound', () async {
      expect(
        () => player.action.open(AudioSource('non_existent_dir/no_audio_file.mp3')),
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

  group('Adversarial HTTP Network & Streaming Playback (Python HTTP Server)', () {
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
          'test/fixtures',
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
          await res.drain();
        } catch (_) {}
      }
      serverProcess?.kill();
      await serverProcess?.exitCode;
    });

    setUp(() {
      player = MiniaudioPlayer(AudioSource('test/fixtures/tripartite/eof_chirp.mp3'));
    });

    tearDown(() async {
      await player.dispose();
    });

    test('progressive HTTP playback with duration, play, pause and stop', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.open(AudioSource(url));

      expect(player.state.duration.inSeconds, greaterThan(0));
      expect(player.state.duration.inSeconds, inInclusiveRange(65, 75));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.playing, isTrue);

      await player.action.pause();
      expect(player.state.playing, isFalse);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('progressive HTTP playback with arbitrary Byte-Range seeking', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.open(AudioSource(Uri.parse(url)));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Seek to 30 seconds via HTTP Byte-Range request
      await player.action.seek(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.position.inSeconds, inInclusiveRange(28, 33));

      await player.action.stop();
    });

    test('progressive HTTP playback of CBR MP3 without Xing header correctly detects duration and supports seeking', () async {
      final url = 'http://127.0.0.1:$serverPort/music/cbr_noxing.mp3';
      await player.action.open(AudioSource(url));

      // CBR sniffer should resolve duration to ~10 seconds instead of defaulting to 0
      expect(player.state.duration.inSeconds, inInclusiveRange(9, 11));
      expect(player.state.bitrate, greaterThan(0));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      // Seek to 5 seconds via Byte-Range request
      await player.action.seek(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.position.inSeconds, inInclusiveRange(4, 7));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('progressive HTTP playback with custom request headers', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.wav';
      await player.action.open(
        AudioSource(
          Uri.parse(url),
          headers: {'X-Custom-Auth': 'Bearer SecretToken123'},
        ),
      );

      expect(player.state.duration.inSeconds, greaterThan(0));
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('progressive HTTP playback of FLAC over network', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.flac';
      await player.action.open(AudioSource(url));

      expect(player.state.duration.inSeconds, greaterThan(0));
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('adversarial: HTTP 404 Not Found throws MiniaudioPlayerException with errorFileNotFound', () async {
      final url = 'http://127.0.0.1:$serverPort/error/404';
      expect(
        () => player.action.open(AudioSource(url)),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorFileNotFound),
          ),
        ),
      );
    });

    test('adversarial: HTTP 403 Forbidden throws MiniaudioPlayerException with errorAccessDenied', () async {
      final url = 'http://127.0.0.1:$serverPort/error/403';
      expect(
        () => player.action.open(AudioSource(url)),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorAccessDenied),
          ),
        ),
      );
    });

    test('adversarial: HTTP 500 Internal Server Error throws MiniaudioPlayerException', () async {
      final url = 'http://127.0.0.1:$serverPort/error/500';
      expect(
        () => player.action.open(AudioSource(url)),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: HTTP 302 Redirection is followed transparently', () async {
      final url = 'http://127.0.0.1:$serverPort/redirect/302?target=/music/salida.mp3';
      await player.action.open(AudioSource(url));

      expect(player.state.duration.inSeconds, greaterThan(0));
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('adversarial: unreachable host/port throws MiniaudioPlayerException without hanging', () async {
      // Connect to unused local port 59991
      final unreachableUrl = 'http://127.0.0.1:59991/audio.mp3';
      expect(
        () => player.action.open(AudioSource(unreachableUrl)),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: corrupt HTTP response headers throws MiniaudioPlayerException', () async {
      final url = 'http://127.0.0.1:$serverPort/corrupt/headers';
      expect(
        () => player.action.open(AudioSource(url)),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: throttled slow network connection streams with buffering', () async {
      final slowUrl = 'http://127.0.0.1:$serverPort/slow/salida.mp3?delay=0.01&chunk=4096';
      await player.action.open(AudioSource(slowUrl));

      expect(player.state.duration.inSeconds, greaterThan(0));
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.state.playing, isTrue);

      await player.action.stop();
    });

    test('adversarial: sudden socket closure during buffering throws cleanly', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=16384';
      expect(
        () => player.action.open(AudioSource(dropUrl)),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: sudden socket closure / connection drop mid-stream does not crash audio thread', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=131072';
      await player.action.open(AudioSource(dropUrl));

      await player.action.play();
      // Let it play until server drops connection abruptly
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Native audio engine must remain healthy and cleanly stop
      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('continuous live chunked stream plays without crashing and stops cleanly', () async {
      final liveUrl = 'http://127.0.0.1:$serverPort/live/salida.mp3';
      await player.action.open(AudioSource(Uri.parse(liveUrl)));

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.playing, isTrue);

      // Volume adjustments during live stream
      await player.action.setVolume(0.5);
      expect(player.state.volume, closeTo(0.5, 0.01));

      await player.action.stop();
      expect(player.state.playing, isFalse);
    });

    test('rapid polymorphic open switching between memory, network, and asset sources', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      final bytes = await mp3File.readAsBytes();
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      for (var i = 0; i < 5; i++) {
        // 1. Memory
        await player.action.open(AudioSource(bytes));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // 2. Network
        await player.action.open(AudioSource(Uri.parse(netUrl)));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // 3. Asset
        await player.action.open(AudioSource('test/fixtures/salida.mp3'));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        await player.action.stop();
      }
    });
  });
}
