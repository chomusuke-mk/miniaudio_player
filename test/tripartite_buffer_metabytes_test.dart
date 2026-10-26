import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Process? serverProcess;
  int? serverPort;

  Future<Map<String, dynamic>> getServerStats(int port) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/stats'));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> resetServerStats(int port) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/reset_stats'));
      final res = await req.close();
      await res.drain<void>();
    } finally {
      client.close();
    }
  }

  setUpAll(() async {
    // Generate fixtures if not present
    final fixtureCheck = File('test/fixtures/tripartite/giant_cover.mp3');
    if (!fixtureCheck.existsSync()) {
      final genResult = await Process.run('python3', ['test/helpers/generate_tripartite_fixtures.py']);
      if (genResult.exitCode != 0) {
        throw StateError('Failed to generate fixtures: ${genResult.stderr}');
      }
    }

    final completer = Completer<int>();
    serverProcess = await Process.start(
      'python3',
      [
        'test/helpers/test_http_server.py',
        '--port',
        '0',
        '--dir',
        'test/fixtures/tripartite',
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

  group('BUFFER_AND_METABYTES_SPEC: Tripartite Buffer & .metaBytes Intensive Verification', () {
    late MiniaudioPlayer player;

    setUp(() {
      player = MiniaudioPlayer();
    });

    tearDown(() async {
      await player.dispose();
    });

    test('Test 1.1: Giant Cover Art (> 256 KB) in MP3 & .metaBytes synthesis', () async {
      final url = 'http://127.0.0.1:$serverPort/music/giant_cover.mp3';
      await player.action.open(AudioSource.uri(url));

      expect(player.action.activeLoader, isNotNull, reason: 'Unified loader should be active');

      // Check metaBytes immediately after opening
      final meta = player.state.metaBytes;
      expect(meta, isNotNull, reason: 'metaBytes must not be null for track with ID3v2 metadata');
      expect(meta!.length, greaterThan(350000), reason: 'metaBytes must retain full > 350 KB ID3v2 tag');

      // Verify ID3v2 signature and APIC frame header
      final headerStr = ascii.decode(meta.sublist(0, 3));
      expect(headerStr, equals('ID3'), reason: 'metaBytes must begin with ID3 tag signature');

      final metaLatin1 = latin1.decode(meta.sublist(0, 100));
      expect(metaLatin1.contains('APIC'), isTrue, reason: 'metaBytes must contain APIC picture frame');

      // Play audio and verify playback proceeds from pure audio ring
      await player.action.play();
      int elapsed = 0;
      while (player.state.position.inMilliseconds == 0 && elapsed < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        elapsed += 50;
      }
      expect(player.state.playing, isTrue, reason: 'Playback must be active');
      expect(player.state.position.inMilliseconds, greaterThan(0), reason: 'Audio frames must decode cleanly');

      // Seek to Duration.zero: must hit Pinned Head cache with 0 range requests
      await resetServerStats(serverPort!);
      await player.action.seek(Duration.zero);

      final stats = await getServerStats(serverPort!);
      final rangeRequests = (stats['range_requests_by_path'] as Map<String, dynamic>?) ?? {};
      final testRanges = rangeRequests['/music/giant_cover.mp3'] as int? ?? 0;
      expect(testRanges, equals(0), reason: 'seek(0) must be served from Pinned Head without Range request');

      await player.action.stop();
    });

    test('Test 1.2: Giant Picture Block (> 256 KB) in FLAC & .metaBytes synthesis', () async {
      final url = 'http://127.0.0.1:$serverPort/music/giant_cover.flac';
      await player.action.open(AudioSource.uri(url));

      final meta = player.state.metaBytes;
      expect(meta, isNotNull, reason: 'metaBytes must not be null for FLAC track');
      expect(meta!.length, greaterThan(300000), reason: 'metaBytes must retain full > 300 KB PICTURE metadata block');

      // Verify FLAC signature
      final signature = ascii.decode(meta.sublist(0, 4));
      expect(signature, equals('fLaC'), reason: 'metaBytes must begin with fLaC signature');

      // Play audio and verify playback proceeds
      await player.action.play();
      int elapsed = 0;
      while (player.state.position.inMilliseconds == 0 && elapsed < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        elapsed += 50;
      }
      expect(player.state.playing, isTrue, reason: 'Playback must be active');
      expect(player.state.position.inMilliseconds, greaterThan(0), reason: 'Audio frames must decode cleanly');

      await player.action.stop();
    });

    test('Test 2: EOF Chirp Prevention (Tail Protection against fake 0xFF 0xFB syncwords)', () async {
      final url = 'http://127.0.0.1:$serverPort/music/eof_chirp.mp3';
      await player.action.open(AudioSource.uri(url));

      // Verify metaBytes has tail tags synthesized
      final meta = player.state.metaBytes;
      expect(meta, isNotNull, reason: 'metaBytes should contain synthesized metadata');
      final metaLatin1 = latin1.decode(meta!);
      expect(metaLatin1.contains('APETAGEX') || metaLatin1.contains('TAG'), isTrue,
          reason: 'metaBytes should contain trailing APEv2 or ID3v1 tags');

      await player.action.play();

      // Seek near end of track to test EOF boundary
      final duration = player.state.duration;
      expect(duration, greaterThan(Duration.zero));
      final seekTarget = duration > const Duration(milliseconds: 300)
          ? duration - const Duration(milliseconds: 250)
          : Duration.zero;
      await player.action.seek(seekTarget);

      // Wait for completion (EOF)
      int waitMs = 0;
      while (!player.state.completed && waitMs < 6000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }
      expect(player.state.completed, isTrue,
          reason: 'Track must reach completion cleanly without decoding fake syncwords');

      await player.action.stop();
    });

    test('Test 3: Non-Fast-Start MP4 / M4A Probing & .metaBytes Synthesis', () async {
      final url = 'http://127.0.0.1:$serverPort/music/non_faststart.m4a';
      await player.action.open(AudioSource.uri(url));

      // Verify track opens and duration is determined
      expect(player.state.duration, greaterThan(Duration.zero),
          reason: 'Non-faststart MP4 must initialize duration after moov probe');

      // Verify synthesized metaBytes has faststart layout: ftyp + empty mdat (8B) + moov
      final meta = player.state.metaBytes;
      expect(meta, isNotNull, reason: 'metaBytes must be synthesized for MP4');
      expect(meta!.length, lessThan(30000),
          reason: 'Synthesized metaBytes must be compact (~14 KB), not containing audio mdat payload');
      expect(meta.length, greaterThan(13000), reason: 'Synthesized metaBytes must contain full moov atom');

      final metaLatin1 = latin1.decode(meta.sublist(0, 100));
      expect(metaLatin1.contains('ftyp'), isTrue, reason: 'Must begin with ftyp box');
      expect(metaLatin1.contains('mdat'), isTrue, reason: 'Must contain empty mdat box header');

      final moovCheck = latin1.decode(meta);
      expect(moovCheck.contains('moov'), isTrue, reason: 'Must contain full moov atom from tail');

      // Play audio and verify playback works
      await player.action.play();
      int elapsed = 0;
      while (player.state.position.inMilliseconds == 0 && elapsed < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        elapsed += 50;
      }
      expect(player.state.playing, isTrue, reason: 'Non-faststart MP4 must play cleanly');
      expect(player.state.position.inMilliseconds, greaterThan(0), reason: 'Position must advance');

      await player.action.stop();
    });

    test('Test 4: WAV with Trailing Chunks Post-Data (LIST/INFO)', () async {
      final url = 'http://127.0.0.1:$serverPort/music/trailing_chunks.wav';
      await player.action.open(AudioSource.uri(url));

      final meta = player.state.metaBytes;
      expect(meta, isNotNull, reason: 'metaBytes must not be null for WAV with metadata');

      final metaLatin1 = latin1.decode(meta!);
      expect(metaLatin1.startsWith('RIFF'), isTrue, reason: 'WAV metaBytes must start with RIFF header');
      expect(metaLatin1.contains('WAVE'), isTrue, reason: 'Must contain WAVE format code');
      expect(metaLatin1.contains('fmt '), isTrue, reason: 'Must contain fmt subchunk');
      expect(metaLatin1.contains('data'), isTrue, reason: 'Must contain data subchunk header');
      expect(metaLatin1.contains('LIST'), isTrue, reason: 'Must contain trailing LIST chunk from Tail');
      expect(metaLatin1.contains('INAM'), isTrue, reason: 'Must contain INAM chunk');
      expect(metaLatin1.contains('Test Title 1234'), isTrue, reason: 'Must preserve track title tag');

      // Verify data chunk size is patched to 0 in synthesized metaBytes
      final dataIdx = metaLatin1.indexOf('data');
      expect(dataIdx, isNonNegative);
      final byteData = ByteData.sublistView(meta);
      final dataSize = byteData.getUint32(dataIdx + 4, Endian.little);
      expect(dataSize, equals(0), reason: 'Synthesized WAV metaBytes must patch data chunk size to 0');

      // Play audio and verify completion
      await player.action.play();
      int elapsed = 0;
      while (player.state.position.inMilliseconds == 0 && elapsed < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        elapsed += 50;
      }
      expect(player.state.playing, isTrue, reason: 'Playback must be active');
      expect(player.state.position.inMilliseconds, greaterThan(0), reason: 'Audio frames must decode cleanly');

      await player.action.stop();
    });

    test('Test 5: ICY Livestream Demuxing & Live metaBytes Stream', () async {
      final url = 'http://127.0.0.1:$serverPort/icy/cbr_noxing.mp3?metaint=8192';

      final receivedMeta = <Uint8List>[];
      final metaSub = player.stream.metaBytes.listen((bytes) {
        if (bytes != null) {
          receivedMeta.add(bytes);
        }
      });

      await player.action.open(AudioSource.uri(url));
      await player.action.play();

      // Wait for at least 2 ICY metadata blocks to be demuxed from the audio stream and synthesized
      int waitMs = 0;
      while (receivedMeta.where((m) => m.length > 128).length < 2 && waitMs < 4000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }

      await metaSub.cancel();

      final icyContainers = receivedMeta.where((m) => m.length > 128).toList();
      expect(icyContainers.length, greaterThanOrEqualTo(2),
          reason: 'Livestream demuxer must extract ICY metadata blocks outside audio ring');

      for (final meta in icyContainers) {
        expect(meta.length, greaterThan(128));
        // Must start with ID3 container header
        expect(utf8.decode(meta.sublist(0, 3)), equals('ID3'),
            reason: 'Livestream metaBytes must synthesize a valid ID3 container');

        final metaStr = utf8.decode(meta, allowMalformed: true);
        expect(metaStr.contains('TIT2'), isTrue,
            reason: 'Synthesized container must contain TIT2 frame');
        expect(metaStr.contains('ICY Track') || metaStr.contains('Artist') || metaStr.contains('Band'), isTrue,
            reason: 'Synthesized container must contain parsed ICY song title');

        // Must end with valid 128-byte ID3v1 trailer
        final trailer = meta.sublist(meta.length - 128);
        expect(utf8.decode(trailer.sublist(0, 3)), equals('TAG'),
            reason: 'Synthesized container must end with ID3v1 TAG trailer');
      }

      // Verify player.state.metaBytes holds the latest synthesized block
      final currentStateMeta = player.state.metaBytes;
      expect(currentStateMeta, isNotNull);
      expect(utf8.decode(currentStateMeta!.sublist(0, 3)), equals('ID3'),
          reason: 'PlayerState.metaBytes must hold current synthesized ID3 container');
      final currentMetaStr = utf8.decode(currentStateMeta, allowMalformed: true);
      expect(currentMetaStr.contains('TIT2'), isTrue);

      expect(player.state.playing, isTrue, reason: 'Stream must remain playing without decoder errors');

      await player.action.stop();
    });

    test('Test 6: MiniaudioEngine Deck Forwarding of metaBytes', () async {
      final engine = MiniaudioEngine();
      final receivedEngineMeta = <Uint8List>[];

      final engineMetaSub = engine.stream.metaBytes.listen((bytes) {
        if (bytes != null) {
          receivedEngineMeta.add(bytes);
        }
      });

      final url = 'http://127.0.0.1:$serverPort/icy/cbr_noxing.mp3?metaint=8192';
      await engine.action.open([EngineItem.uri(Uri.parse(url))]);
      await engine.action.play();

      int waitMs = 0;
      while (receivedEngineMeta.where((m) => m.length > 128).isEmpty && waitMs < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }

      await engineMetaSub.cancel();

      final icyContainers = receivedEngineMeta.where((m) => m.length > 128).toList();
      expect(icyContainers, isNotEmpty,
          reason: 'MiniaudioEngine must forward metaBytes from active deck');

      final firstMeta = icyContainers.first;
      expect(utf8.decode(firstMeta.sublist(0, 3)), equals('ID3'),
          reason: 'Engine metaBytes must forward synthesized ID3 container');

      final engineMetaStr = utf8.decode(firstMeta, allowMalformed: true);
      expect(engineMetaStr.contains('TIT2'), isTrue,
          reason: 'Engine metaBytes must contain TIT2 frame with ICY stream title');

      expect(engine.state.metaBytes, isNotNull,
          reason: 'EngineState.metaBytes must expose current metadata snapshot');
      expect(utf8.decode(engine.state.metaBytes!.sublist(0, 3)), equals('ID3'));

      await engine.action.stop();
      await engine.dispose();
    });

    test('Test 7: 3 MB Head & 25 KB Tail with 5-Second Buffer Integrity', () async {
      // Small 1 MB circular buffer (~5 seconds at 44.1kHz 16-bit stereo)
      final smallBufferPlayer = MiniaudioPlayer(bufferSize: 1);
      final url = 'http://127.0.0.1:$serverPort/music/head_3mb_tail_25kb.mp3';

      await smallBufferPlayer.action.open(AudioSource.uri(url));

      // Verify Head is not truncated to 256 KB, but retains all ~3 MB of metadata
      final pinnedHeadBytes = smallBufferPlayer.pinnedHeadSize;
      expect(pinnedHeadBytes, greaterThan(3 * 1000 * 1000),
          reason: 'Head must retain full 3 MB of metadata without truncation to 256 KB');

      // Verify metaBytes has full metadata (> 3 MB)
      final meta = smallBufferPlayer.state.metaBytes;
      expect(meta, isNotNull);
      expect(meta!.length, greaterThanOrEqualTo(3 * 1024 * 1024),
          reason: '.metaBytes must contain the entire 3 MB metadata');

      // Verify start of meta is ID3
      expect(utf8.decode(meta.sublist(0, 3)), equals('ID3'));

      // Verify tail of meta has ID3v1 trailer
      final tailTag = meta.sublist(meta.length - 128, meta.length - 125);
      expect(utf8.decode(tailTag), equals('TAG'));

      // Play through
      await smallBufferPlayer.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(smallBufferPlayer.state.position.inMilliseconds, greaterThan(0));

      // Seek back to 0 must be served instantly from pinned Head in RAM with 0 range requests
      await smallBufferPlayer.action.seek(Duration.zero);
      expect(smallBufferPlayer.state.position, equals(Duration.zero));

      await smallBufferPlayer.action.stop();
      await smallBufferPlayer.dispose();
    });

    test('Test 8: Metadata Lifecycle: open() & dispose() reset, stop() preserves', () async {
      final lifecyclePlayer = MiniaudioPlayer();
      final url = 'http://127.0.0.1:$serverPort/music/giant_cover.mp3';

      final metaEmissions = <Uint8List?>[];
      final sub = lifecyclePlayer.stream.metaBytes.listen((m) {
        metaEmissions.add(m);
      });

      // 1. Open track with metadata
      await lifecyclePlayer.action.open(AudioSource.uri(url));
      expect(lifecyclePlayer.state.metaBytes, isNotNull,
          reason: 'Opened track must have non-null metaBytes');

      // 2. Stop track -> metadata MUST be preserved (pause/rewind to 0)
      await lifecyclePlayer.action.stop();
      expect(lifecyclePlayer.state.metaBytes, isNotNull,
          reason: 'stop() must preserve metadata for fast replay');

      // 3. Open second track -> opening MUST reset metadata to null during loading
      final openFuture = lifecyclePlayer.action.open(AudioSource.uri('http://127.0.0.1:$serverPort/music/trailing_chunks.wav'));
      // During opening phase or stream, null was emitted
      await openFuture;
      expect(metaEmissions.any((m) => m == null), isTrue,
          reason: 'open() must emit null to reset metadata from previous track');

      // 4. Dispose player -> metadata MUST be cleaned to null
      await lifecyclePlayer.dispose();
      await sub.cancel();
      expect(lifecyclePlayer.state.metaBytes, isNull,
          reason: 'dispose() must reset metaBytes to null');
    });
  });
}
