import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/resolver/source_resolver.dart';
import 'package:miniaudio_player/src/resolver/source_resolver_io.dart'
    show
        openWritableAndroidContentFdForTest,
        resolveAndroidContentOrResourceForTest;
import 'package:miniaudio_player/src/resolver/ws_stream_provider_common.dart';

Uint8List _buildTestWavBytes({
  int sampleRate = 44100,
  int channels = 2,
  int durationMs = 600,
}) {
  final numFrames = (sampleRate * durationMs) ~/ 1000;
  final dataBytes = numFrames * channels * 2;
  final totalBytes = 44 + dataBytes;
  final bd = ByteData(totalBytes);

  // RIFF header
  bd.setUint8(0, 0x52); // R
  bd.setUint8(1, 0x49); // I
  bd.setUint8(2, 0x46); // F
  bd.setUint8(3, 0x46); // F
  bd.setUint32(4, totalBytes - 8, Endian.little);
  bd.setUint8(8, 0x57); // W
  bd.setUint8(9, 0x41); // A
  bd.setUint8(10, 0x56); // V
  bd.setUint8(11, 0x45); // E

  // fmt chunk
  bd.setUint8(12, 0x66); // f
  bd.setUint8(13, 0x6D); // m
  bd.setUint8(14, 0x74); // t
  bd.setUint8(15, 0x20); // ' '
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * 2, Endian.little);
  bd.setUint16(32, channels * 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);

  // data chunk
  bd.setUint8(36, 0x64); // d
  bd.setUint8(37, 0x61); // a
  bd.setUint8(38, 0x74); // t
  bd.setUint8(39, 0x61); // a
  bd.setUint32(40, dataBytes, Endian.little);

  var off = 44;
  for (var i = 0; i < numFrames; i++) {
    final s = (math.sin(2.0 * math.pi * 440.0 * i / sampleRate) * 12000).round();
    for (var ch = 0; ch < channels; ch++) {
      bd.setInt16(off, s, Endian.little);
      off += 2;
    }
  }
  return bd.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
    await MiniaudioPlayer.ensureInitialized();
  });

  group('URI Normalization & Scheme Dispatch Matrix', () {
    test('normalizes file:// URIs on POSIX and Windows including # and localhost', () {
      expect(
        normalizeAudioSourceUri(
          'file:///tmp/%23BrooklynBloodPop%21-SyKo.opus',
          isWeb: false,
          isWindows: false,
          isAndroid: false,
          isDebug: true,
        ).normalizedSource,
        equals('/tmp/#BrooklynBloodPop!-SyKo.opus'),
      );

      expect(
        normalizeAudioSourceUri(
          'file:///tmp/#literal_hash track.mp3',
          isWeb: false,
          isWindows: false,
          isAndroid: false,
          isDebug: true,
        ).normalizedSource,
        equals('/tmp/#literal_hash track.mp3'),
      );

      expect(
        normalizeAudioSourceUri(
          'file://localhost/var/audio/song.flac',
          isWeb: false,
          isWindows: false,
          isAndroid: false,
          isDebug: true,
        ).normalizedSource,
        equals('/var/audio/song.flac'),
      );

      expect(
        normalizeAudioSourceUri(
          'file:///C:/Music/%23track%201.mp3',
          isWeb: false,
          isWindows: true,
          isAndroid: false,
          isDebug: true,
        ).normalizedSource,
        equals(r'C:\Music\#track 1.mp3'),
      );

      expect(
        normalizeAudioSourceUri(
          'file://nas-box/share/music/song.mp3',
          isWeb: false,
          isWindows: true,
          isAndroid: false,
          isDebug: true,
        ).normalizedSource,
        equals(r'\\nas-box\share\music\song.mp3'),
      );

      final posixHostErr = normalizeAudioSourceUri(
        'file://relative/song.mp3',
        isWeb: false,
        isWindows: false,
        isAndroid: false,
        isDebug: true,
      );
      expect(posixHostErr.directErrorCode, equals(MapResult.errorUnsupported));

      final webFileErr = normalizeAudioSourceUri(
        'file:///tmp/song.mp3',
        isWeb: true,
        isWindows: false,
        isAndroid: false,
        isDebug: false,
      );
      expect(webFileErr.directErrorCode, equals(MapResult.errorUnsupported));
    });

    test('preserves Windows drive letters and plain local paths', () {
      final winDrive = normalizeAudioSourceUri(
        r'C:\Audio\#track 1.mp3',
        isWeb: false,
        isWindows: true,
        isAndroid: false,
        isDebug: true,
      );
      expect(winDrive.normalizedSource, equals(r'C:\Audio\#track 1.mp3'));
      expect(winDrive.resolveInDart, isFalse);
      expect(winDrive.hasError, isFalse);
    });

    test('normalizes Web asset:// URLs across release, profile, and debug without HEAD probes', () {
      final base = Uri.parse('https://user.github.io/miniaudio_player/index.html');
      final releaseHash = normalizeAudioSourceUri(
        'asset://assets/music/#BrooklynBloodPop!-SyKo.opus',
        isWeb: true,
        isWindows: false,
        isAndroid: false,
        isDebug: false,
        webBaseUri: base,
      );
      expect(releaseHash.resolveInDart, isFalse);
      expect(
        releaseHash.normalizedSource,
        equals(
          'https://user.github.io/miniaudio_player/assets/assets/music/%2523BrooklynBloodPop!-SyKo.opus',
        ),
      );

      final debugHash = normalizeAudioSourceUri(
        'asset://assets/music/#BrooklynBloodPop!-SyKo.opus',
        isWeb: true,
        isWindows: false,
        isAndroid: false,
        isDebug: true,
        webBaseUri: base,
      );
      expect(debugHash.resolveInDart, isFalse);
      expect(
        debugHash.normalizedSource,
        equals(
          'https://user.github.io/miniaudio_player/assets/assets/music/%2523BrooklynBloodPop!-SyKo.opus',
        ),
      );

      final debugSpaces = normalizeAudioSourceUri(
        'asset://assets/music/Down Under-Men At Work.m4a',
        isWeb: true,
        isWindows: false,
        isAndroid: false,
        isDebug: true,
        webBaseUri: Uri.parse('http://localhost:36739/'),
      );
      expect(debugSpaces.resolveInDart, isFalse);
      expect(
        debugSpaces.normalizedSource,
        equals(
          'http://localhost:36739/assets/assets/music/Down%2520Under-Men%2520At%2520Work.m4a',
        ),
      );

      final pkgRelease = normalizeAudioSourceUri(
        'package:my_pkg/assets/#track 1.ogg',
        isWeb: true,
        isWindows: false,
        isAndroid: false,
        isDebug: false,
        webBaseUri: Uri.parse('https://app.example.com/'),
      );
      expect(pkgRelease.resolveInDart, isFalse);
      expect(
        pkgRelease.normalizedSource,
        equals(
          'https://app.example.com/assets/packages/my_pkg/assets/%2523track%25201.ogg',
        ),
      );

      final relWeb = normalizeAudioSourceUri(
        'assets/audio/clip.mp3',
        isWeb: true,
        isWindows: false,
        isAndroid: false,
        isDebug: false,
        webBaseUri: base,
      );
      expect(relWeb.resolveInDart, isFalse);
      expect(
        relWeb.normalizedSource,
        equals('https://user.github.io/miniaudio_player/assets/audio/clip.mp3'),
      );
    });

    test('normalizes data://, data:, icy://, package:, and preserves AudioSource.uri', () {
      final wavBytes = _buildTestWavBytes(durationMs: 120);
      final b64 = base64Encode(wavBytes);
      final dataSlash = AudioSource('data://audio/wav;base64,$b64');
      expect(dataSlash.isMemory, isTrue);
      expect(dataSlash.bytes, equals(wavBytes));

      final pkgNative = normalizeAudioSourceUri(
        'package:my_pkg/assets/sfx.wav',
        isWeb: false,
        isWindows: false,
        isAndroid: false,
        isDebug: true,
      );
      expect(pkgNative.normalizedSource, equals('asset://packages/my_pkg/assets/sfx.wav'));
      expect(pkgNative.resolveInDart, isTrue);

      final icyNorm = normalizeAudioSourceUri(
        'icy://radio.example.com:8000/stream',
        isWeb: false,
        isWindows: false,
        isAndroid: false,
        isDebug: true,
      );
      expect(icyNorm.normalizedSource, equals('http://radio.example.com:8000/stream'));
      expect(icyNorm.resolveInDart, isFalse);

      final assetSrc = AudioSource('asset://assets/music/#BrooklynBloodPop!-SyKo.opus');
      expect(
        assetSrc.uri,
        equals('asset://assets/music/#BrooklynBloodPop!-SyKo.opus'),
      );
    });

    test('assigns descriptive errorUnsupported (-10) and errorInvalidArgs (-2) cleanly', () {
      for (final uri in [
        'ftp://files.example.com/song.mp3',
        'ftps://files.example.com/song.mp3',
        'sftp://host/song.mp3',
        'rtsp://cam.local/audio',
        'rtmp://live.example.com/app',
        'ipod-library://item/123',
        'phasset://abc',
        'blob:https://example.com/uuid',
      ]) {
        final res = normalizeAudioSourceUri(
          uri,
          isWeb: false,
          isWindows: false,
          isAndroid: false,
          isDebug: true,
        );
        expect(
          res.directErrorCode,
          equals(MapResult.errorUnsupported),
          reason: '$uri must be explicitly rejected with errorUnsupported',
        );
        expect(res.directErrorMessage, isNotEmpty);
      }

      for (final badUri in [
        '',
        '   ',
        'data:audio/wav;base64_no_comma',
        'package:no_slash_pkg',
        'ws:///no_host',
      ]) {
        final res = normalizeAudioSourceUri(
          badUri,
          isWeb: false,
          isWindows: false,
          isAndroid: false,
          isDebug: true,
        );
        expect(
          res.directErrorCode,
          equals(MapResult.errorInvalidArgs),
          reason: '"$badUri" must fail with errorInvalidArgs',
        );
      }

      final nonAndroidContent = normalizeAudioSourceUri(
        'content://media/external/audio/media/42',
        isWeb: false,
        isWindows: false,
        isAndroid: false,
        isDebug: true,
      );
      expect(nonAndroidContent.directErrorCode, equals(MapResult.errorUnsupported));

      final androidContent = normalizeAudioSourceUri(
        'content://media/external/audio/media/42',
        isWeb: false,
        isWindows: false,
        isAndroid: true,
        isDebug: true,
      );
      expect(androidContent.hasError, isFalse);
      expect(androidContent.resolveInDart, isTrue);
    });
  });

  group('End-to-End Resolution & Error Handling', () {
    test('unsupported and malformed sources fail cleanly on analyzeAudio, analyzeAudioSync, and player', () async {
      await expectLater(
        () => MiniaudioPlayer.analyzeAudio('ftp://example.com/track.mp3'),
        throwsA(
          isA<MiniaudioPlayerException>()
              .having((e) => e.errorCode, 'errorCode', MapResult.errorUnsupported),
        ),
      );

      expect(
        () => MiniaudioPlayer.analyzeAudioSync('rtsp://example.com/live'),
        throwsA(
          isA<MiniaudioPlayerException>()
              .having((e) => e.errorCode, 'errorCode', MapResult.errorUnsupported),
        ),
      );

      expect(
        () => MiniaudioPlayer.analyzeAudioSync('asset://assets/test_tone.wav'),
        throwsA(
          isA<MiniaudioPlayerException>()
              .having((e) => e.errorCode, 'errorCode', MapResult.errorUnsupported)
              .having((e) => e.message, 'message', contains('analyzeAudio()')),
        ),
      );

      final player = MiniaudioPlayer();
      try {
        await expectLater(
          () => player.action.setQueue([AudioSource('ftp://example.com/a.mp3')])
              .then((_) => player.action.play()),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      } finally {
        await player.dispose();
      }
    });

    test('file:// with # and spaces plays and analyzes cleanly', () async {
      final tmpDir = await Directory.systemTemp.createTemp('map_file_uri_');
      try {
        final audioFile = File('${tmpDir.path}/#Test Track #1.wav');
        await audioFile.writeAsBytes(_buildTestWavBytes(durationMs: 700));
        final fileUri = Uri.file(audioFile.path).toString();
        final rawConcatUri = 'file://${audioFile.path}';

        for (final uri in [fileUri, rawConcatUri]) {
          final analysis = await MiniaudioPlayer.analyzeAudio(uri);
          expect(analysis.audioInfo.duration?.inMilliseconds, greaterThan(500));

          final syncAnalysis = MiniaudioPlayer.analyzeAudioSync(uri);
          expect(syncAnalysis.audioInfo.duration?.inMilliseconds, greaterThan(500));

          final player = MiniaudioPlayer(queue: [AudioSource(uri)]);
          try {
            await player.action.play();
            expect(player.state.duration?.inMilliseconds, greaterThan(500));
            expect(player.state.isPlaying, isTrue);
            await player.action.pause();
          } finally {
            await player.dispose();
          }
        }
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('asset:// plays, pre-warms crossfade, analyzes, and decodes SFX via TestAssetBundle', () async {
      final wavBytes = _buildTestWavBytes(durationMs: 700);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      Future<ByteData?> assetHandler(ByteData? message) async {
        final key = utf8.decode(message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ));
        if (key == 'assets/test%20%231.wav' || key == 'assets/test #1.wav') {
          return ByteData.sublistView(wavBytes);
        }
        if (key == 'packages/sample_pkg/assets/bell.wav') {
          return ByteData.sublistView(wavBytes);
        }
        return null;
      }

      messenger.setMockMessageHandler('flutter/assets', assetHandler);
      addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));

      final analysis = await MiniaudioPlayer.analyzeAudio('asset://assets/test #1.wav');
      expect(analysis.audioInfo.duration?.inMilliseconds, greaterThan(500));

      final pkgAnalysis =
          await MiniaudioPlayer.analyzeAudio('package:sample_pkg/assets/bell.wav');
      expect(pkgAnalysis.audioInfo.duration?.inMilliseconds, greaterThan(500));

      await expectLater(
        () => MiniaudioPlayer.analyzeAudio('asset://assets/missing_audio.wav'),
        throwsA(
          isA<MiniaudioPlayerException>()
              .having((e) => e.errorCode, 'errorCode', MapResult.errorFileNotFound),
        ),
      );

      final player = MiniaudioPlayer(
        queue: [
          AudioSource('asset://assets/test #1.wav'),
          AudioSource('package:sample_pkg/assets/bell.wav'),
        ],
      );
      try {
        await player.action.play();
        expect(player.state.isPlaying, isTrue);
        expect(player.state.duration?.inMilliseconds, greaterThan(500));

        await player.action.setEffects([
          AudioEffect(
            id: 'sfx_asset',
            source: AudioSource('asset://assets/test #1.wav'),
          ),
        ]);
        final voice = await player.action.playEffect('sfx_asset');
        expect(voice.id, greaterThan(0));
        await player.action.stopAllEffects();
      } finally {
        await player.dispose();
      }
    });

    test('ws:// streams binary WAV from loopback WebSocket and cleans up on dispose', () async {
      final wavBytes = _buildTestWavBytes(durationMs: 2500);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final sub = server.listen((HttpRequest req) async {
        final socket = await WebSocketTransformer.upgrade(req);
        // Split header and PCM chunks to exercise multi-frame FIFO slicing.
        socket.add(wavBytes.sublist(0, 64));
        var offset = 64;
        while (offset < wavBytes.length) {
          final end = (offset + 4096).clamp(0, wavBytes.length);
          socket.add(wavBytes.sublist(offset, end));
          offset = end;
        }
        await socket.close();
      });
      addTearDown(sub.cancel);

      final wsUrl = 'ws://127.0.0.1:${server.port}/live.wav';
      final player = MiniaudioPlayer(queue: [AudioSource(wsUrl)]);
      try {
        await player.action.play();
        expect(player.state.isPlaying, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
      }

      // Unreachable WebSocket port must fail cleanly rather than hanging.
      final unreachablePlayer = MiniaudioPlayer();
      try {
        await expectLater(
          () => unreachablePlayer.action
              .setQueue([AudioSource('ws://127.0.0.1:${server.port + 1}/bad.wav')])
              .then((_) => unreachablePlayer.action.play()),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      } finally {
        await unreachablePlayer.dispose();
      }
    });

    test('WebSocketFifoBuffer preserves partial frame offsets and enforces backpressure bound', () async {
      final fifo = WebSocketFifoBuffer(maxBufferedBytes: 16);
      fifo.push(Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      fifo.push(Uint8List.fromList([7, 8, 9, 10]));

      final head = await fifo.readUpTo(4);
      expect(head, equals(Uint8List.fromList([1, 2, 3, 4])));

      final mid = await fifo.readUpTo(4);
      expect(mid, equals(Uint8List.fromList([5, 6, 7, 8])));

      // Push 15 bytes exceeding maxBufferedBytes (16): 2 + 15 = 17 > 16 -> evicts oldest [9, 10].
      fifo.push(Uint8List.fromList(List<int>.generate(15, (i) => 20 + i)));
      fifo.markClosed();

      final tail = await fifo.readUpTo(64);
      expect(tail, equals(Uint8List.fromList(List<int>.generate(15, (i) => 20 + i))));
      expect(await fifo.readUpTo(64), isEmpty);
    });

    test('data://, file://, and missing RootIsolateToken errors work cleanly inside Isolate.run', () async {
      final wavBytes = _buildTestWavBytes(durationMs: 400);
      final dataUri = 'data://audio/wav;base64,${base64Encode(wavBytes)}';
      final tmpDir = await Directory.systemTemp.createTemp('map_isolate_');
      try {
        final file = File('${tmpDir.path}/iso_tone.wav');
        await file.writeAsBytes(wavBytes);
        final fileUri = Uri.file(file.path).toString();
        final token = RootIsolateToken.instance;

        // 1. Isolate WITHOUT RootIsolateToken: data:// and file:// work; asset:// & content://
        //    must fail cleanly with errorInvalidState (-7) instructing to pass RootIsolateToken.
        final noTokenResult = await Isolate.run(() async {
          MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
          await MiniaudioPlayer.ensureInitialized();

          final dataRes = await MiniaudioPlayer.analyzeAudio(dataUri);
          final fileRes = MiniaudioPlayer.analyzeAudioSync(fileUri);

          var missingTokenCode = 0;
          var missingTokenMsg = '';
          try {
            await MiniaudioPlayer.analyzeAudio('asset://assets/iso_missing.wav');
          } on MiniaudioPlayerException catch (e) {
            missingTokenCode = e.errorCode ?? 0;
            missingTokenMsg = e.message;
          }

          return <Object?>[
            dataRes.audioInfo.duration?.inMilliseconds,
            fileRes.audioInfo.duration?.inMilliseconds,
            missingTokenCode,
            missingTokenMsg,
          ];
        });

        expect(noTokenResult[0] as int, greaterThan(300));
        expect(noTokenResult[1] as int, greaterThan(300));
        expect(noTokenResult[2], equals(MapResult.errorInvalidState));
        expect(noTokenResult[3] as String, contains('RootIsolateToken'));

        // 2. Isolate WITH RootIsolateToken: ensureInitialized accepts token cleanly.
        final withTokenResult = await Isolate.run(() async {
          MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
          await MiniaudioPlayer.ensureInitialized(rootIsolateToken: token);
          final dataRes = await MiniaudioPlayer.analyzeAudio(dataUri);
          final fileRes = MiniaudioPlayer.analyzeAudioSync(fileUri);
          return <Object?>[
            dataRes.audioInfo.duration?.inMilliseconds,
            fileRes.audioInfo.duration?.inMilliseconds,
          ];
        });

        expect(withTokenResult[0] as int, greaterThan(300));
        expect(withTokenResult[1] as int, greaterThan(300));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('extractExtensionHintFromSource preserves # in local paths and strips query/fragment on URLs', () {
      expect(
        extractExtensionHintFromSource('assets/music/#BrooklynBloodPop!-SyKo.opus'),
        equals('opus'),
      );
      expect(
        extractExtensionHintFromSource('/tmp/song#live.flac'),
        equals('flac'),
      );
      expect(
        extractExtensionHintFromSource('wss://audio.example.com/live.ogg?token=1#top'),
        equals('ogg'),
      );
      expect(
        extractExtensionHintFromSource('content://media/external/audio/media/42.mp3?foo=bar'),
        equals('mp3'),
      );
    });

    test('Android MethodChannel contract maps fd, bytes, and error codes deterministically', () async {
      const channel = MethodChannel('dev.chomusuke.miniaudio_player/source_resolver');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      // 1. MissingPluginException when Android plugin is not attached
      messenger.setMockMethodCallHandler(channel, null);
      final missingRes = await resolveAndroidContentOrResourceForTest(
        'content://media/external/audio/media/1',
      );
      expect(
        missingRes,
        isA<DartResolvedError>().having(
          (e) => e.code,
          'code',
          MapResult.errorUnsupported,
        ),
      );

      // 2. MethodChannel responses & error code mapping
      messenger.setMockMethodCallHandler(channel, (call) async {
        final uri = (call.arguments as Map)['uri'] as String;
        if (call.method == 'openWritableContentFd' && uri.endsWith('/ok_rw')) {
          return <String, dynamic>{'fd': 77, 'mode': 'rwt'};
        }
        if (call.method == 'openContentFd' && uri.endsWith('/ok_fd')) {
          return <String, dynamic>{
            'kind': 'fd',
            'fd': 42,
            'offset': 128,
            'length': 4096,
            'hintExt': 'mp3',
          };
        }
        if (call.method == 'openAndroidResource' && uri.endsWith('/ok_bytes')) {
          return <String, dynamic>{
            'kind': 'bytes',
            'bytes': Uint8List.fromList([1, 2, 3, 4]),
            'hintExt': 'ogg',
          };
        }
        if (uri.endsWith('/bad_fd')) {
          return <String, dynamic>{'kind': 'fd', 'fd': -1};
        }
        if (uri.endsWith('/denied')) {
          throw PlatformException(code: 'ACCESS_DENIED', message: 'Security denial');
        }
        if (uri.endsWith('/not_found')) {
          throw PlatformException(code: 'FILE_NOT_FOUND', message: 'Missing document');
        }
        if (uri.endsWith('/invalid')) {
          throw PlatformException(code: 'INVALID_URI', message: 'Bad URI');
        }
        if (uri.endsWith('/unsupported')) {
          throw PlatformException(code: 'UNSUPPORTED', message: 'Cannot stream pipe');
        }
        return null;
      });

      final fdRes = await resolveAndroidContentOrResourceForTest(
        'content://com.android.providers.media/audio/ok_fd',
      );
      expect(
        fdRes,
        isA<DartResolvedFd>()
            .having((r) => r.fd, 'fd', 42)
            .having((r) => r.offset, 'offset', 128)
            .having((r) => r.length, 'length', 4096)
            .having((r) => r.hintExt, 'hintExt', 'mp3'),
      );

      final resBytes = await resolveAndroidContentOrResourceForTest(
        'android.resource://dev.chomusuke.app/raw/ok_bytes',
      );
      expect(
        resBytes,
        isA<DartResolvedBytes>()
            .having((r) => r.bytes.length, 'bytes.length', 4)
            .having((r) => r.hintExt, 'hintExt', 'ogg'),
      );

      final badFdRes = await resolveAndroidContentOrResourceForTest(
        'content://com.android.providers.media/audio/bad_fd',
      );
      expect(
        badFdRes,
        isA<DartResolvedError>().having(
          (e) => e.code,
          'code',
          MapResult.errorFileNotFound,
        ),
      );

      final errorCases = <String, int>{
        'content://auth/denied': MapResult.errorAccessDenied,
        'content://auth/not_found': MapResult.errorFileNotFound,
        'content://auth/invalid': MapResult.errorInvalidArgs,
        'content://auth/unsupported': MapResult.errorUnsupported,
      };
      for (final entry in errorCases.entries) {
        final errRes = await resolveAndroidContentOrResourceForTest(entry.key);
        expect(
          errRes,
          isA<DartResolvedError>().having((e) => e.code, 'code', entry.value),
          reason: '${entry.key} must map to ${entry.value}',
        );
      }

      // Writable content:// fd contract & error mapping (Phase 4)
      final writableFd = await openWritableAndroidContentFdForTest(
        'content://com.android.providers.downloads/document/ok_rw',
      );
      expect(writableFd, equals(77));

      for (final entry in errorCases.entries) {
        await expectLater(
          () => openWritableAndroidContentFdForTest(entry.key),
          throwsA(
            isA<MiniaudioPlayerException>().having(
              (e) => e.errorCode,
              'errorCode',
              entry.value,
            ),
          ),
        );
      }
    });
  });
}
