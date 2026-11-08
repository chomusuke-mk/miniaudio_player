import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUpAll(() async {
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

    test('AudioSource network URL with headers instantiates AudioSource correctly', () {
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
          queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('decodes and plays MP3 directly from memory buffer with accurate duration and frees Dart bytes', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      expect(mp3File.existsSync(), isTrue, reason: 'salida.mp3 must exist');
      final bytes = await mp3File.readAsBytes();
      final memSource = AudioSource(bytes);

      await player.action.setQueue([memSource]);
      expect(memSource.bytes, isNull, reason: 'Dart bytes must be cleared after transfer to Rust');
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.duration?.inSeconds, inInclusiveRange(65, 75));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.isPlaying, isTrue);

      await player.action.seek(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(player.state.position.inSeconds, inInclusiveRange(9, 12));

      await player.action.pause();
      expect(player.state.isPlaying, isFalse);

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('decodes and plays FLAC directly from memory buffer', () async {
      final flacFile = resolveAsset('test/fixtures/salida.flac');
      expect(flacFile.existsSync(), isTrue);
      final bytes = await flacFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('decodes and plays WAV directly from memory buffer', () async {
      final wavFile = resolveAsset('test/fixtures/salida.wav');
      expect(wavFile.existsSync(), isTrue);
      final bytes = await wavFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('decodes and plays OGG directly from memory buffer', () async {
      final oggFile = resolveAsset('test/fixtures/salida.ogg');
      expect(oggFile.existsSync(), isTrue);
      final bytes = await oggFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('decodes and plays OPUS directly from memory buffer', () async {
      final opusFile = resolveAsset('test/fixtures/salida.opus');
      expect(opusFile.existsSync(), isTrue);
      final bytes = await opusFile.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('adversarial: empty memory buffer throws MiniaudioPlayerException', () async {
      await player.action.setQueue([AudioSource(Uint8List(0))]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: corrupt random memory buffer throws MiniaudioPlayerException', () async {
      final rng = Random(42);
      final corruptBytes = Uint8List.fromList(List.generate(4096, (_) => rng.nextInt(256)));

      await player.action.setQueue([AudioSource(corruptBytes)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('stress: rapid repeated memory playback cycles without memory leaks', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      final bytes = await mp3File.readAsBytes();

      for (var i = 0; i < 20; i++) {
        await player.action.setQueue([AudioSource(bytes)]);
        await player.action.play();
        expect(player.state.duration?.inSeconds, greaterThan(0));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await player.action.stop();
      }
    });
  });

  group('Asset Playback (AudioSource)', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer(
          queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('resolves asset via bytes', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      final bytes = await mp3File.readAsBytes();

      await player.action.setQueue([AudioSource(bytes)]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('resolves local file candidate', () async {
      await player.action.setQueue([AudioSource('test/fixtures/salida.mp3')]);
      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('non-existent file throws MiniaudioPlayerException with errorFileNotFound', () async {
      await player.action.setQueue([AudioSource('non_existent_dir/no_audio_file.mp3')]);
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
      player = MiniaudioPlayer(
          queue: [AudioSource('test/fixtures/tripartite/eof_chirp.mp3')]);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('progressive HTTP playback with duration, play, pause and stop', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.setQueue([AudioSource(url)]);
      await player.action.play();

      expect(player.state.duration?.inSeconds, greaterThan(0));
      expect(player.state.duration?.inSeconds, inInclusiveRange(65, 75));

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(player.state.isPlaying, isTrue);

      await player.action.pause();
      expect(player.state.isPlaying, isFalse);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('progressive HTTP playback with arbitrary Byte-Range seeking', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
      await player.action.setQueue([AudioSource(Uri.parse(url))]);

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
      await player.action.setQueue([AudioSource(url)]);
      await player.action.play();

      // CBR sniffer should resolve duration to ~10 seconds instead of defaulting to 0
      expect(player.state.duration?.inSeconds, inInclusiveRange(9, 11));
      expect(player.state.audioBitrate, greaterThan(0));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.isPlaying, isTrue);

      // Seek to 5 seconds via Byte-Range request
      await player.action.seek(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(player.state.position.inSeconds, inInclusiveRange(4, 7));

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('progressive HTTP playback with custom request headers', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.wav';
      await player.action.setQueue([
        AudioSource(
          Uri.parse(url),
          headers: {'X-Custom-Auth': 'Bearer SecretToken123'},
        ),
      ]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('progressive HTTP playback of FLAC over network', () async {
      final url = 'http://127.0.0.1:$serverPort/music/salida.flac';
      await player.action.setQueue([AudioSource(url)]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('adversarial: HTTP 404 Not Found throws MiniaudioPlayerException with errorFileNotFound', () async {
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

    test('adversarial: HTTP 403 Forbidden throws MiniaudioPlayerException with errorAccessDenied', () async {
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

    test('adversarial: HTTP 500 Internal Server Error throws MiniaudioPlayerException', () async {
      final url = 'http://127.0.0.1:$serverPort/error/500';
      await player.action.setQueue([AudioSource(url)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: HTTP 302 Redirection is followed transparently', () async {
      final url = 'http://127.0.0.1:$serverPort/redirect/302?target=/music/salida.mp3';
      await player.action.setQueue([AudioSource(url)]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('adversarial: unreachable host/port throws MiniaudioPlayerException without hanging', () async {
      // Connect to unused local port 59991
      final unreachableUrl = 'http://127.0.0.1:59991/audio.mp3';
      await player.action.setQueue([AudioSource(unreachableUrl)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: corrupt HTTP response headers throws MiniaudioPlayerException', () async {
      final url = 'http://127.0.0.1:$serverPort/corrupt/headers';
      await player.action.setQueue([AudioSource(url)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: throttled slow network connection streams with buffering', () async {
      final slowUrl = 'http://127.0.0.1:$serverPort/slow/salida.mp3?delay=0.01&chunk=4096';
      await player.action.setQueue([AudioSource(slowUrl)]);

      await player.action.play();
      expect(player.state.duration?.inSeconds, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.state.isPlaying, isTrue);

      await player.action.stop();
    });

    test('adversarial: sudden socket closure during buffering throws cleanly', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=16384';
      await player.action.setQueue([AudioSource(dropUrl)]);
      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('adversarial: sudden socket closure / connection drop mid-stream does not crash audio thread', () async {
      final dropUrl = 'http://127.0.0.1:$serverPort/drop/salida.mp3?after=131072';
      await player.action.setQueue([AudioSource(dropUrl)]);

      await player.action.play();
      // Let it play until server drops connection abruptly
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Native audio engine must remain healthy and cleanly stop
      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('continuous live chunked stream plays without crashing and stops cleanly', () async {
      final liveUrl = 'http://127.0.0.1:$serverPort/live/salida.mp3';
      await player.action.setQueue([AudioSource(Uri.parse(liveUrl))]);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(player.state.isPlaying, isTrue);

      // Volume adjustments during live stream
      await player.action.setVolume(0.5);
      expect(player.state.volume, closeTo(0.5, 0.01));

      await player.action.stop();
      expect(player.state.isPlaying, isFalse);
    });

    test('rapid polymorphic setQueue switching between memory, network, and asset sources', () async {
      final mp3File = resolveAsset('test/fixtures/salida.mp3');
      final bytes = await mp3File.readAsBytes();
      final netUrl = 'http://127.0.0.1:$serverPort/music/salida.mp3';

      for (var i = 0; i < 5; i++) {
        // 1. Memory
        await player.action.setQueue([AudioSource(bytes)]);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // 2. Network
        await player.action.setQueue([AudioSource(Uri.parse(netUrl))]);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // 3. Asset
        await player.action.setQueue([AudioSource('test/fixtures/salida.mp3')]);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        await player.action.stop();
      }
    });
  });
}
