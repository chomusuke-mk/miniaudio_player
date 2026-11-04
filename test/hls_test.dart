import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Real-World Live HLS Playback', () {
    Process? serverProcess;
    int? serverPort;

    setUpAll(() async {
      await MiniaudioPlayer.ensureInitialized();
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
          await res.drain<void>();
        } catch (_) {}
      }
      serverProcess?.kill(ProcessSignal.sigkill);
      await serverProcess?.exitCode;
    });

    test('auto-detects and plays HLS stream from arbitrary URL lacking any extension', () async {
      final streamUrl = 'http://127.0.0.1:$serverPort/arbitrary-channel?token=secret123';
      final player = MiniaudioPlayer(source: [AudioSource(streamUrl)]);
      try {
        await player.action.waitUntilOpen();

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 600));

        expect(player.state.playing, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
      }
    });

    test('plays multi-segment HLS playlist served locally from test/fixtures', () async {
      final streamUrl = 'http://127.0.0.1:$serverPort/salida.m3u8';
      final player = MiniaudioPlayer(source: [AudioSource(streamUrl)]);
      try {
        await player.action.waitUntilOpen();
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(player.state.playing, isTrue);

        await player.action.stop();
        expect(player.state.playing, isFalse);
      } finally {
        await player.dispose();
      }
    });
  });
}
