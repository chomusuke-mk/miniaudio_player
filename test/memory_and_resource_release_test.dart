import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

class _LoopbackAudioServer {
  final HttpServer server;
  final Map<String, ({String mime, Uint8List bytes})> _fixtures;

  _LoopbackAudioServer._(this.server, this._fixtures);

  int get port => server.port;

  String rangeUrl(String filename) =>
      'http://127.0.0.1:$port/range/$filename';

  String nonRangeUrl(String filename) =>
      'http://127.0.0.1:$port/norange/$filename';

  static File _resolveFixture(String filename) {
    final direct = File('example/assets/music/$filename');
    if (direct.existsSync()) return direct;
    final parent = File('../example/assets/music/$filename');
    if (parent.existsSync()) return parent;
    throw StateError('Missing test fixture example/assets/music/$filename');
  }

  static Future<_LoopbackAudioServer> start() async {
    const specs = <(String, String)>[
      ('01_Apex_Momentum.mp3', 'audio/mpeg'),
      ('04_Belaya_Tishina.flac', 'audio/flac'),
      ('05_Burning_in_the_Electric_Light.ogg', 'audio/ogg'),
      ('17_Running_To_Meet_The_Sun.wav', 'audio/wav'),
    ];
    final map = <String, ({String mime, Uint8List bytes})>{};
    for (final (name, mime) in specs) {
      map[name] = (mime: mime, bytes: _resolveFixture(name).readAsBytesSync());
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _LoopbackAudioServer._(server, map);
    unawaited(server.forEach(instance._handleRequest));
    return instance;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;
    final bool allowRange;
    final String filename;
    if (path.startsWith('/range/')) {
      allowRange = true;
      filename = path.substring('/range/'.length);
    } else if (path.startsWith('/norange/')) {
      allowRange = false;
      filename = path.substring('/norange/'.length);
    } else {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final entry = _fixtures[filename];
    if (entry == null) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    final bytes = entry.bytes;
    final total = bytes.length;
    req.response.headers.set(HttpHeaders.contentTypeHeader, entry.mime);
    req.response.headers.set(HttpHeaders.connectionHeader, 'close');

    if (allowRange) {
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final rangeHdr = req.headers.value(HttpHeaders.rangeHeader);
      if (rangeHdr != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHdr.trim());
        if (match != null) {
          final start =
              match.group(1)!.isEmpty ? 0 : int.parse(match.group(1)!);
          final rawEnd = match.group(2)!.isEmpty
              ? total - 1
              : int.parse(match.group(2)!);
          final end = rawEnd >= total ? total - 1 : rawEnd;
          if (start >= 0 && start <= end && start < total) {
            final len = end - start + 1;
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers
                .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
            req.response.contentLength = len;
            try {
              req.response.add(Uint8List.sublistView(bytes, start, end + 1));
              await req.response.close();
            } catch (_) {}
            return;
          }
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await req.response.close();
          return;
        }
      }
    } else {
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    }

    req.response.statusCode = HttpStatus.ok;
    req.response.contentLength = total;
    try {
      req.response.add(bytes);
      await req.response.close();
    } catch (_) {}
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

String _resolveLocalPath(String relPath) {
  final f = File(relPath);
  if (f.existsSync()) return f.path;
  final parent = File('../$relPath');
  if (parent.existsSync()) return parent.path;
  return relPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late _LoopbackAudioServer server;

  setUpAll(() async {
    MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
    await MiniaudioPlayer.ensureInitialized();
    server = await _LoopbackAudioServer.start();
  });

  tearDownAll(() async {
    await server.close();
  });

  group('Native Memory & Resource Release', () {
    test(
      'RSS stabilizes across repeated HTTP/local track switches and HTTP analyzeAudio passes',
      () async {
        final player = MiniaudioPlayer(
          outputs: const {},
          queue: [
            AudioSource(server.rangeUrl('01_Apex_Momentum.mp3')),
            AudioSource(server.rangeUrl('04_Belaya_Tishina.flac')),
            AudioSource(
              server.nonRangeUrl('05_Burning_in_the_Electric_Light.ogg'),
            ),
            AudioSource(
              _resolveLocalPath('example/assets/music/17_Running_To_Meet_The_Sun.wav'),
            ),
          ],
        );

        try {
          await player.action.setMetadataEnabled(true);

          final analysisUrls = <String>[
            server.rangeUrl('01_Apex_Momentum.mp3'),
            server.rangeUrl('04_Belaya_Tishina.flac'),
          ];

          // Warmup 4 switches + 2 HTTP analyses so pools and allocators settle.
          for (var i = 0; i < 4; i++) {
            await player.action.play(position: i % 4);
            await player.action.seek(const Duration(milliseconds: 1200));
            await player.action.stop();
            if (i < 2) {
              await MiniaudioPlayer.analyzeAudio(
                analysisUrls[i % analysisUrls.length],
                replayGain: true,
                waveform: true,
                metadata: true,
                waveformPoints: 64,
                maxAnalysisDuration: const Duration(milliseconds: 1500),
              );
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final baselineRss = ProcessInfo.currentRss;

          // Repeated 16 track switches + 8 HTTP analyses.
          for (var i = 0; i < 16; i++) {
            await player.action.play(position: i % 4);
            if (i.isEven) {
              await player.action.seek(const Duration(milliseconds: 1500));
            }
            await player.action.stop();
            if (i.isEven) {
              final res = await MiniaudioPlayer.analyzeAudio(
                analysisUrls[(i ~/ 2) % analysisUrls.length],
                replayGain: true,
                waveform: true,
                metadata: true,
                waveformPoints: 64,
                maxAnalysisDuration: const Duration(milliseconds: 1500),
              );
              expect(res.audioInfo.sampleRate, greaterThan(0));
            }
          }

          await player.action.stop();
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final finalRss = ProcessInfo.currentRss;
          final rssDelta = finalRss - baselineRss;

          expect(
            rssDelta,
            lessThan(80 * 1024 * 1024),
            reason:
                'Native RSS grew monotonically across 16 HTTP/local switches + 8 analyses '
                '(baseline=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)} MiB, '
                'final=${(finalRss / (1024 * 1024)).toStringAsFixed(1)} MiB)',
          );
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      'Repeated MiniaudioPlayer create/play/dispose cycles release native resources cleanly',
      () async {
        final rangeMp3 = server.rangeUrl('01_Apex_Momentum.mp3');
        final localWav =
            _resolveLocalPath('example/assets/music/17_Running_To_Meet_The_Sun.wav');

        Future<void> runLifecycle() async {
          final p = MiniaudioPlayer(
            outputs: const {},
            queue: [
              AudioSource(rangeMp3),
              AudioSource(localWav),
            ],
          );
          await p.action.play(position: 0);
          await p.action.seek(const Duration(milliseconds: 800));
          await p.action.play(position: 1);
          await p.action.stop();
          await p.dispose();
          expect(p.isDisposed, isTrue);
          await expectLater(p.action.play(), throwsStateError);
        }

        // Warmup 2 full lifecycles.
        await runLifecycle();
        await runLifecycle();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final baselineRss = ProcessInfo.currentRss;

        for (var i = 0; i < 6; i++) {
          await runLifecycle();
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final finalRss = ProcessInfo.currentRss;
        final rssDelta = finalRss - baselineRss;

        expect(
          rssDelta,
          lessThan(64 * 1024 * 1024),
          reason:
              'Native RSS grew across 6 MiniaudioPlayer create/dispose cycles '
              '(baseline=${(baselineRss / (1024 * 1024)).toStringAsFixed(1)} MiB, '
              'final=${(finalRss / (1024 * 1024)).toStringAsFixed(1)} MiB)',
        );
      },
    );

    test(
      'AudioSource<Uint8List> transfers ownership, clears Dart bytes, and stabilizes RSS across queue reloads',
      () async {
        final mp3Bytes = File(
          _resolveLocalPath('example/assets/music/01_Apex_Momentum.mp3'),
        ).readAsBytesSync();
        final player = MiniaudioPlayer(outputs: const {});

        try {
          for (var i = 0; i < 2; i++) {
            final src = AudioSource(Uint8List.fromList(mp3Bytes));
            await player.action.setQueue([src]);
            expect(src.bytes, isNull);
            await player.action.play();
            await player.action.stop();
            await player.action.clearQueue(keepCurrent: false);
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
          final baselineRss = ProcessInfo.currentRss;

          for (var i = 0; i < 8; i++) {
            final src = AudioSource(Uint8List.fromList(mp3Bytes));
            await player.action.setQueue([src]);
            expect(
              src.bytes,
              isNull,
              reason: 'Dart byte buffer must be cleared after FFI transfer',
            );
            await player.action.play();
            await player.action.stop();
            await player.action.clearQueue(keepCurrent: false);
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final finalRss = ProcessInfo.currentRss;
          final rssDelta = finalRss - baselineRss;

          expect(
            rssDelta,
            lessThan(64 * 1024 * 1024),
            reason:
                'Memory-buffer queue reload cycles retained excessive memory '
                '(delta=${(rssDelta / (1024 * 1024)).toStringAsFixed(1)} MiB)',
          );
        } finally {
          await player.dispose();
        }
      },
    );
  });
}
