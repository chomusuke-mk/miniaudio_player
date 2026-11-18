import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

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
          await res.drain<void>();
        } catch (_) {}
      }
      serverProcess?.kill(ProcessSignal.sigkill);
      await serverProcess?.exitCode;
    });

    test(
        'auto-detects and plays HLS stream from arbitrary URL lacking any extension',
        () async {
      final streamUrl =
          'http://127.0.0.1:$serverPort/arbitrary-channel?token=secret123';
      final player = MiniaudioPlayer(queue: [AudioSource(streamUrl)]);
      try {
        await player.action.play();
        await awaitStateOrStream<bool>(
          stream: player.stream.isPlaying,
          current: () => player.state.isPlaying,
          predicate: (playing) => playing,
          reason: 'HLS stream should transition to isPlaying',
        );
        await waitForAudioProgress(
          player,
          minDelta: const Duration(milliseconds: 60),
        );

        expect(player.state.isPlaying, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
      }
    });

    test('plays multi-segment HLS playlist served locally from example/assets/music/hls',
        () async {
      final streamUrl = 'http://127.0.0.1:$serverPort/28_%D0%A0%D0%B0%D0%B7%D0%B2%D0%BE%D0%B4%D1%8F%D1%82_%D0%BC%D0%BE%D1%81%D1%82%D1%8B.m3u8';
      final player = MiniaudioPlayer(queue: [AudioSource(streamUrl)]);
      try {
        await player.action.play();
        await awaitStateOrStream<bool>(
          stream: player.stream.isPlaying,
          current: () => player.state.isPlaying,
          predicate: (playing) => playing,
          reason: 'Multi-segment HLS playlist should transition to isPlaying',
        );
        await waitForAudioProgress(
          player,
          minDelta: const Duration(milliseconds: 60),
        );
        expect(player.state.isPlaying, isTrue);

        await player.action.stop();
        expect(player.state.isPlaying, isFalse);
      } finally {
        await player.dispose();
      }
    });

    test('rejects encrypted AES-128-CBC HLS playlist cleanly without crashing engine',
        () async {
      final streamUrl = 'http://127.0.0.1:$serverPort/26_Where_Miracles_Start_aes.m3u8';
      final player = MiniaudioPlayer(queue: [AudioSource(streamUrl)]);
      try {
        await expectLater(
          player.action.play(),
          throwsA(isA<MiniaudioPlayerException>()),
        );
        expect(player.state.isPlaying, isFalse);
      } finally {
        await player.dispose();
      }
    });
  });
}
