// ignore_for_file: avoid_print

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

  test('Livestream pause during long time then play reproduction test', () async {
    MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.verbose;

    final player = MiniaudioPlayer();
    try {
      final liveUrl = 'http://127.0.0.1:$serverPort/live/salida.mp3';
      print('=== OPENING LIVESTREAM ===');
      await player.action.open(AudioSource.uri(liveUrl, isLive: true));
      print('=== OPENED LIVESTREAM ===');

      print('=== PLAYING ===');
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      print('=== POSITION AFTER 1s: ${player.state.position} ===');

      print('=== PAUSING ===');
      await player.action.pause();
      expect(player.state.playing, isFalse);

      print('=== WAITING 6 SECONDS WHILE PAUSED (simulating long pause) ===');
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final status = player.backend.getStreamStatus();
        print('... paused second $i: readCursor=${status?.readCursorByte}, range=[${status?.rangeStart}..${status?.rangeEnd}], headroom=${status?.aheadHeadroomBytes}, isBuffering=${status?.isBuffering} ...');
      }

      print('=== RESUMING PLAYBACK (PLAY) ===');
      await player.action.play();
      expect(player.state.playing, isTrue);

      print('=== MONITORING POSITION FOR 6 SECONDS AFTER RESUME ===');
      int frozenCount = 0;
      Duration lastPos = player.state.position;
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final curPos = player.state.position;
        final status = player.backend.getStreamStatus();
        print('After resume second $i: pos=$curPos, readCursor=${status?.readCursorByte}, range=[${status?.rangeStart}..${status?.rangeEnd}], headroom=${status?.aheadHeadroomBytes}, playing=${player.state.playing}, buffering=${player.state.buffering}');
        if (curPos == lastPos) {
          frozenCount++;
        }
        lastPos = curPos;
      }
      print('Frozen count: $frozenCount');
      expect(frozenCount, equals(0), reason: 'Playback should not freeze after resuming a long pause in livestream');
    } finally {
      await player.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
