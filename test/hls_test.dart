import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('HlsSniffer', () {
    test('sniffs standard #EXTM3U magic bytes', () {
      final bytes = utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n');
      expect(HlsSniffer.isHlsBytes(bytes), isTrue);
    });

    test('sniffs #EXTM3U with UTF-8 BOM', () {
      final bytes = [
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('#EXTM3U\n#EXT-X-TARGETDURATION:6\n')
      ];
      expect(HlsSniffer.isHlsBytes(bytes), isTrue);
    });

    test('sniffs #EXTM3U with leading whitespace and newlines', () {
      final bytes = utf8.encode('  \r\n\n  #EXTM3U\n');
      expect(HlsSniffer.isHlsBytes(bytes), isTrue);
    });

    test('rejects non-HLS binary and text payloads', () {
      expect(HlsSniffer.isHlsBytes(utf8.encode('RIFF....WAVE')), isFalse);
      expect(HlsSniffer.isHlsBytes(utf8.encode('fLaC....')), isFalse);
      expect(HlsSniffer.isHlsBytes(utf8.encode('OggS....')), isFalse);
      expect(HlsSniffer.isHlsBytes([0xFF, 0xFB, 0x90, 0x44]), isFalse); // MP3
      expect(HlsSniffer.isHlsBytes([0xFF, 0xF1, 0x50, 0x80]), isFalse); // AAC
      expect(HlsSniffer.isHlsBytes(utf8.encode('Hello World')), isFalse);
      expect(HlsSniffer.isHlsBytes([]), isFalse);
    });

    test('identifies HLS MIME types case-insensitively with parameters', () {
      expect(HlsSniffer.isHlsMime('application/vnd.apple.mpegurl'), isTrue);
      expect(HlsSniffer.isHlsMime('application/x-mpegURL; charset=utf-8'), isTrue);
      expect(HlsSniffer.isHlsMime('audio/x-mpegurl'), isTrue);
      expect(HlsSniffer.isHlsMime('audio/mpegurl'), isTrue);
      expect(HlsSniffer.isHlsMime('application/mpegurl'), isTrue);
      expect(HlsSniffer.isHlsMime('audio/mpeg'), isFalse);
      expect(HlsSniffer.isHlsMime('audio/aac'), isFalse);
      expect(HlsSniffer.isHlsMime(null), isFalse);
    });

    test('sniffs URL hints with query parameters', () {
      expect(HlsSniffer.isHlsUrl(Uri.parse('https://example.com/live.m3u8')), isTrue);
      expect(HlsSniffer.isHlsUrl(Uri.parse('https://example.com/playlist.m3u8?token=xyz&session=123')), isTrue);
      expect(HlsSniffer.isHlsUrl(Uri.parse('https://example.com/stream.m3u')), isTrue);
      expect(HlsSniffer.isHlsUrl(Uri.parse('https://example.com/track.mp3')), isFalse);
    });
  });

  group('HlsPlaylistParser', () {
    test('parses master multivariant playlist and selects highest bandwidth audio variant', () {
      const masterContent = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
low/playlist.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
mid/playlist.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=256000,CODECS="mp4a.40.2"
high/playlist.m3u8
''';
      final baseUri = Uri.parse('https://cdn.example.com/live/master.m3u8');
      final playlist = HlsPlaylistParser.parse(masterContent, baseUri);

      expect(playlist.isMaster, isTrue);
      expect(playlist.variants.length, equals(3));
      expect(playlist.variants[0].uri, equals(Uri.parse('https://cdn.example.com/live/low/playlist.m3u8')));
      expect(playlist.variants[2].uri, equals(Uri.parse('https://cdn.example.com/live/high/playlist.m3u8')));

      final bestUri = playlist.selectBestVariantUri();
      expect(bestUri, equals(Uri.parse('https://cdn.example.com/live/high/playlist.m3u8')));
    });

    test('parses media playlist with target duration, sequence, and titles', () {
      const mediaContent = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:5.015,title="Station - Track A"
segment_100.aac
#EXTINF:4.992,title="Station - Track B"
segment_101.aac
''';
      final baseUri = Uri.parse('https://cdn.example.com/audio/playlist.m3u8');
      final playlist = HlsPlaylistParser.parse(mediaContent, baseUri);

      expect(playlist.isMaster, isFalse);
      expect(playlist.isLive, isTrue); // No #EXT-X-ENDLIST -> live
      expect(playlist.targetDuration, equals(6.0));
      expect(playlist.mediaSequence, equals(100));
      expect(playlist.segments.length, equals(2));

      expect(playlist.segments[0].duration, equals(5.015));
      expect(playlist.segments[0].title, equals('Station - Track A'));
      expect(playlist.segments[0].sequenceNumber, equals(100));
      expect(playlist.segments[0].uri, equals(Uri.parse('https://cdn.example.com/audio/segment_100.aac')));

      expect(playlist.segments[1].duration, equals(4.992));
      expect(playlist.segments[1].title, equals('Station - Track B'));
      expect(playlist.segments[1].sequenceNumber, equals(101));
    });

    test('detects VOD playlist when #EXT-X-ENDLIST is present', () {
      const vodContent = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg1.aac
#EXTINF:10.0,
seg2.aac
#EXT-X-ENDLIST
''';
      final playlist = HlsPlaylistParser.parse(vodContent, Uri.parse('https://cdn.com/vod.m3u8'));
      expect(playlist.isLive, isFalse);
    });
  });

  group('HlsSegmentDemuxer', () {
    test('strips ID3v2 header from AAC segment and extracts title metadata', () {
      // Synthesize ID3v2.4 tag with TIT2 frame "Live Radio"
      final titleBytes = utf8.encode('Live Radio');
      final frameSize = 1 + titleBytes.length; // 1 encoding byte + text
      final tit2Header = [
        0x54, 0x49, 0x54, 0x32, // 'TIT2'
        0x00, 0x00, 0x00, frameSize, // size
        0x00, 0x00, // flags
        0x03, // UTF-8 encoding
        ...titleBytes,
      ];

      final id3TagBodySize = tit2Header.length;
      final id3Header = [
        0x49, 0x44, 0x33, // 'ID3'
        0x04, 0x00, // version 2.4
        0x00, // flags
        (id3TagBodySize >> 21) & 0x7F,
        (id3TagBodySize >> 14) & 0x7F,
        (id3TagBodySize >> 7) & 0x7F,
        id3TagBodySize & 0x7F,
      ];

      // Simulated ADTS AAC frames starting with 0xFFF1
      final adtsFrames = [
        0xFF, 0xF1, 0x50, 0x80, 0x33, 0x1F, 0xFC, // ADTS header
        0x11, 0x22, 0x33, 0x44,
      ];

      final rawSegment = Uint8List.fromList([
        ...id3Header,
        ...tit2Header,
        ...adtsFrames,
      ]);

      final result = HlsSegmentDemuxer.demuxSegment(rawSegment);

      expect(result.codec, equals(AudioCodec.aac));
      expect(result.title, equals('Live Radio'));
      // The output audioBytes should have stripped ID3 and start directly with ADTS syncword 0xFF 0xF1
      expect(result.audioBytes[0], equals(0xFF));
      expect(result.audioBytes[1], equals(0xF1));
      expect(result.audioBytes.length, equals(adtsFrames.length));
    });

    test('handles clean ADTS AAC frames without ID3', () {
      final adtsFrames = Uint8List.fromList([
        0xFF, 0xF1, 0x50, 0x80, 0x33, 0x1F, 0xFC,
        0xAA, 0xBB, 0xCC,
      ]);

      final result = HlsSegmentDemuxer.demuxSegment(adtsFrames);
      expect(result.codec, equals(AudioCodec.aac));
      expect(result.audioBytes, equals(adtsFrames));
    });
  });

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

      final player = MiniaudioPlayer();
      try {
        final streamUrl = 'http://127.0.0.1:$port/arbitrary-channel?token=secret123';
        // Note: URL has NO .m3u8 extension, and content-type is text/plain.
        // It must be identified purely through in-band #EXTM3U sniffing!
        await player.action.open(AudioSource.uri(streamUrl));

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
      final player = MiniaudioPlayer();
      try {
        const streamUrl =
            'https://mdstrm.com/audio/5fab0687bcd6c2389ee9480c/live.m3u8';

        // 1. Open live stream via AudioSource.uri()
        await player.action.open(AudioSource.uri(streamUrl));

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
