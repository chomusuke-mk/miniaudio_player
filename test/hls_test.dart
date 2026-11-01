import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('Real-World Live HLS Playback', () {
    test('auto-detects and plays HLS stream from arbitrary URL lacking any extension', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;

      final fixtureBytes =
          await File('test/fixtures/tripartite/eof_chirp.mp3').readAsBytes();

      server.listen((HttpRequest req) {
        if (req.uri.path == '/arbitrary-channel') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('text', 'plain') // Note: Not even an mpegurl MIME!
            ..write('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXTINF:2.0,title="Arbitrary Stream Title"
http://127.0.0.1:$port/audio_chunk
#EXT-X-ENDLIST
''')
            ..close();
        } else if (req.uri.path == '/audio_chunk') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('application', 'octet-stream')
            ..add(fixtureBytes)
            ..close();
        }
      });

      final streamUrl = 'http://127.0.0.1:$port/arbitrary-channel?token=secret123';
      final player = MiniaudioPlayer(AudioSource(streamUrl));
      try {
        await player.waitUntilOpen;

        expect(player.state.trackMetadata?.codec, equals(AudioCodec.mp3));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 600));

        expect(player.state.playing, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
        await server.close(force: true);
      }
    });

    test('plays live HLS stream from mdstrm.com seamlessly', () async {
      const streamUrl =
          'https://mdstrm.com/audio/5fab0687bcd6c2389ee9480c/live.m3u8';
      final player = MiniaudioPlayer(AudioSource(streamUrl));
      try {
        await player.waitUntilOpen;

        expect(player.state.trackMetadata?.codec, anyOf(equals(AudioCodec.aac), equals(AudioCodec.unknown)));

        // 2. Start playback
        await player.action.play();

        // Let audio stream and buffer for 3 seconds
        await Future<void>.delayed(const Duration(seconds: 3));

        expect(player.state.playing, isTrue);

        // 3. Stop playback
        await player.action.stop();
        expect(player.state.playing, isFalse);
      } finally {
        await player.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
