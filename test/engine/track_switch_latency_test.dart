import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/concurrency_test_utils.dart';

enum _NetProfile {
  local,
  remoteFull,
  remoteLimited,
  remoteUltraSlow,
}

extension on _NetProfile {
  String get label => switch (this) {
        _NetProfile.local => 'Local',
        _NetProfile.remoteFull => 'Remoto Full',
        _NetProfile.remoteLimited => 'Remoto Limitado',
        _NetProfile.remoteUltraSlow => 'Remoto Ultra Lento',
      };
}

class _LatencyRow {
  final String profile;
  final String scenario;
  final int markMs;
  final int audioMs;

  _LatencyRow({
    required this.profile,
    required this.scenario,
    required this.markMs,
    required this.audioMs,
  });
}

class _MixedFormatSpec {
  final String route;
  final String relFile;
  final String formatLabel;
  final int extraOpenDelayMs;

  const _MixedFormatSpec({
    required this.route,
    required this.relFile,
    required this.formatLabel,
    this.extraOpenDelayMs = 0,
  });
}

const List<_MixedFormatSpec> _mixedWebCatalog15 = [
  _MixedFormatSpec(route: '01_mp3_vbr.mp3', relFile: '01_Apex_Momentum.mp3', formatLabel: 'MP3_VBR'),
  _MixedFormatSpec(route: '02_opus.opus', relFile: '02_Bailando_con_tu_recuerdo.opus', formatLabel: 'OPUS', extraOpenDelayMs: 600),
  _MixedFormatSpec(route: '03_mp3_cbr.mp3', relFile: '03_Before_The_Dawn_cbr_noxing.mp3', formatLabel: 'MP3_CBR'),
  _MixedFormatSpec(route: '04_flac.flac', relFile: '04_Belaya_Tishina.flac', formatLabel: 'FLAC', extraOpenDelayMs: 700),
  _MixedFormatSpec(route: '05_ogg.ogg', relFile: '05_Burning_in_the_Electric_Light.ogg', formatLabel: 'OGG_VORBIS'),
  _MixedFormatSpec(route: '06_aac.m4a', relFile: '06_Calculated_Motion_aac.m4a', formatLabel: 'M4A_AAC'),
  _MixedFormatSpec(route: '07_alac.m4a', relFile: '07_Fevered_Strings_alac.m4a', formatLabel: 'M4A_ALAC', extraOpenDelayMs: 700),
  _MixedFormatSpec(route: '09_wv.wv', relFile: '09_Flesh_and_Chrome.wv', formatLabel: 'WAVPACK'),
  _MixedFormatSpec(route: '10_adts.aac', relFile: '10_La_cicatriz_del_andén.aac', formatLabel: 'AAC_ADTS'),
  _MixedFormatSpec(route: '11_mka.mka', relFile: '11_Mar_de_cristal.mka', formatLabel: 'MKA_FLAC', extraOpenDelayMs: 700),
  _MixedFormatSpec(route: '13_webm.webm', relFile: '13_Overture_for_the_Floor.webm', formatLabel: 'WEBM_OPUS'),
  _MixedFormatSpec(route: '14_mkv.mkv', relFile: '14_Painting_the_Sky.mkv', formatLabel: 'MKV_OPUS'),
  _MixedFormatSpec(route: '15_mp2.mp2', relFile: '15_Resting_At_Your_Feet.mp2', formatLabel: 'MP2'),
  _MixedFormatSpec(route: '16_oga.oga', relFile: '16_Ribbons_on_Anchors.oga', formatLabel: 'OGA_VORBIS'),
  _MixedFormatSpec(route: '17_wav.wav', relFile: '17_Running_To_Meet_The_Sun.wav', formatLabel: 'WAV_16B', extraOpenDelayMs: 650),
];

class _ThrottledRangeHttpServer {
  final ServerSocket _server;
  final Map<String, Uint8List> _files;
  final Map<String, ({File file, int length})> _diskRoutes;
  final Set<Socket> _activeSockets = {};
  bool _closed = false;

  int openDelayMs = 0;
  int rttMs = 0;
  int bytesPerSec = 0;
  int burstFreeBytes = 1 << 30;
  final Map<String, int> perPathExtraOpenDelayMs = {};

  _ThrottledRangeHttpServer._(this._server, this._files, this._diskRoutes) {
    _server.listen(_onSocket, onError: (_) {});
  }

  int get port => _server.port;

  static Future<_ThrottledRangeHttpServer> start(
    Map<String, Uint8List> files, {
    Map<String, File> diskFiles = const {},
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final diskRoutes = <String, ({File file, int length})>{};
    for (final entry in diskFiles.entries) {
      diskRoutes[entry.key] = (file: entry.value, length: await entry.value.length());
    }
    return _ThrottledRangeHttpServer._(server, files, diskRoutes);
  }

  void configureCustom({
    required int openDelayMs,
    required int rttMs,
    required int bytesPerSec,
    required int burstFreeBytes,
  }) {
    perPathExtraOpenDelayMs.clear();
    this.openDelayMs = openDelayMs;
    this.rttMs = rttMs;
    this.bytesPerSec = bytesPerSec;
    this.burstFreeBytes = burstFreeBytes;
  }

  void configureProfile(_NetProfile profile) {
    perPathExtraOpenDelayMs.clear();
    switch (profile) {
      case _NetProfile.local:
      case _NetProfile.remoteFull:
        openDelayMs = 0;
        rttMs = 0;
        bytesPerSec = 0;
        burstFreeBytes = 1 << 30;
      case _NetProfile.remoteLimited:
        openDelayMs = 40;
        rttMs = 40;
        bytesPerSec = 160 * 1024;
        burstFreeBytes = 32 * 1024;
      case _NetProfile.remoteUltraSlow:
        openDelayMs = 600;
        rttMs = 250;
        bytesPerSec = 24 * 1024;
        burstFreeBytes = 0;
    }
  }

  void _onSocket(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    _activeSockets.add(socket);
    socket.done.catchError((_) {}).whenComplete(() => _activeSockets.remove(socket));

    final reqBuf = <int>[];
    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) async {
        reqBuf.addAll(chunk);
        final text = String.fromCharCodes(reqBuf);
        final headerEnd = text.indexOf('\r\n\r\n');
        if (headerEnd < 0) return;
        await sub.cancel();
        unawaited(_handleRequest(socket, text.substring(0, headerEnd)));
      },
      onError: (_) => socket.destroy(),
      cancelOnError: true,
    );
  }

  Future<void> _handleRequest(Socket socket, String rawHeaders) async {
    final lines = rawHeaders.split('\r\n');
    if (lines.isEmpty) {
      socket.destroy();
      return;
    }
    final reqParts = lines.first.split(' ');
    final method = reqParts.isNotEmpty ? reqParts[0].toUpperCase() : 'GET';
    var rawPath = reqParts.length > 1 ? reqParts[1] : '/';
    final qIdx = rawPath.indexOf('?');
    if (qIdx >= 0) rawPath = rawPath.substring(0, qIdx);
    if (rawPath.startsWith('/')) rawPath = rawPath.substring(1);

    String? rangeVal;
    for (final line in lines.skip(1)) {
      final low = line.toLowerCase();
      if (low.startsWith('range:')) {
        rangeVal = low.substring('range:'.length).trim();
      }
    }

    final isOpenProbe = method == 'HEAD' ||
        rangeVal == null ||
        rangeVal.startsWith('bytes=0-');
    final extraPathDelay = perPathExtraOpenDelayMs[rawPath] ?? 0;
    final totalDelayMs =
        rttMs + (isOpenProbe ? (openDelayMs + extraPathDelay) : 0);
    if (totalDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: totalDelayMs));
    }
    if (_closed) {
      socket.destroy();
      return;
    }

    final data = _files[rawPath];
    final disk = _diskRoutes[rawPath];
    if (data == null && disk == null) {
      try {
        socket.add(
          'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
              .codeUnits,
        );
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
      return;
    }

    final totalLength = data?.length ?? disk!.length;

    if (method == 'HEAD') {
      try {
        socket.add(
          'HTTP/1.1 200 OK\r\n'
                  'Accept-Ranges: bytes\r\n'
                  'Content-Length: $totalLength\r\n'
                  'Connection: close\r\n\r\n'
              .codeUnits,
        );
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
      return;
    }

    var start = 0;
    var end = totalLength - 1;
    var isPartial = false;
    if (rangeVal != null && rangeVal.startsWith('bytes=')) {
      final spec = rangeVal.substring('bytes='.length);
      final dash = spec.split('-');
      start = int.tryParse(dash[0]) ?? 0;
      if (dash.length > 1 && dash[1].isNotEmpty) {
        end = min(int.tryParse(dash[1]) ?? end, totalLength - 1);
      }
      isPartial = true;
    }

    if (start > end || start >= totalLength) {
      socket.destroy();
      return;
    }

    final sliceLen = end - start + 1;
    final header = isPartial
        ? 'HTTP/1.1 206 Partial Content\r\n'
            'Accept-Ranges: bytes\r\n'
            'Content-Length: $sliceLen\r\n'
            'Content-Range: bytes $start-$end/$totalLength\r\n'
            'Connection: close\r\n\r\n'
        : 'HTTP/1.1 200 OK\r\n'
            'Accept-Ranges: bytes\r\n'
            'Content-Length: $sliceLen\r\n'
            'Connection: close\r\n\r\n';

    try {
      socket.add(header.codeUnits);
      if (data != null) {
        await _writeThrottled(socket, data, start, end + 1);
      } else {
        await _writeFileThrottled(socket, disk!.file, start, end + 1);
      }
      await socket.close();
    } catch (_) {
      socket.destroy();
    }
  }

  Future<void> _writeFileThrottled(
    Socket socket,
    File file,
    int from,
    int to,
  ) async {
    final raf = await file.open();
    try {
      await raf.setPosition(from);
      var remaining = to - from;
      if (bytesPerSec <= 0) {
        while (remaining > 0 && !_closed) {
          final chunk = await raf.read(min(remaining, 64 * 1024));
          if (chunk.isEmpty) break;
          socket.add(chunk);
          remaining -= chunk.length;
        }
        return;
      }
      const chunkSz = 8 * 1024;
      final sleepUs = max(1000, (chunkSz * 1000000) ~/ bytesPerSec);
      var sent = 0;
      while (remaining > 0 && !_closed) {
        final chunk = await raf.read(min(remaining, chunkSz));
        if (chunk.isEmpty) break;
        socket.add(chunk);
        remaining -= chunk.length;
        sent += chunk.length;
        if (remaining > 0 && sent > burstFreeBytes) {
          await Future<void>.delayed(Duration(microseconds: sleepUs));
        }
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> _writeThrottled(
    Socket socket,
    Uint8List data,
    int from,
    int to,
  ) async {
    if (bytesPerSec <= 0) {
      socket.add(Uint8List.sublistView(data, from, to));
      return;
    }
    const chunkSz = 8 * 1024;
    final sleepUs = max(1000, (chunkSz * 1000000) ~/ bytesPerSec);
    var offset = from;
    var sent = 0;
    while (offset < to && !_closed) {
      final nextEnd = min(offset + chunkSz, to);
      socket.add(Uint8List.sublistView(data, offset, nextEnd));
      sent += nextEnd - offset;
      offset = nextEnd;
      if (offset < to && sent > burstFreeBytes) {
        await Future<void>.delayed(Duration(microseconds: sleepUs));
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final s in _activeSockets.toList()) {
      s.destroy();
    }
    _activeSockets.clear();
    await _server.close();
  }
}

Uint8List _generatePcm16MonoWav(int durationSec, int sampleRate) {
  final numFrames = durationSec * sampleRate;
  final dataSize = numFrames * 2;
  final byteData = ByteData(44 + dataSize);
  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      byteData.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  byteData.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  byteData.setUint32(16, 16, Endian.little);
  byteData.setUint16(20, 1, Endian.little);
  byteData.setUint16(22, 1, Endian.little);
  byteData.setUint32(24, sampleRate, Endian.little);
  byteData.setUint32(28, sampleRate * 2, Endian.little);
  byteData.setUint16(32, 2, Endian.little);
  byteData.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  byteData.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < numFrames; i++) {
    final s = (sin(2 * pi * 440.0 * i / sampleRate) * 14000).round();
    byteData.setInt16(44 + i * 2, s, Endian.little);
  }
  return byteData.buffer.asUint8List();
}

Future<int> _measureIndexSwitch({
  required MiniaudioPlayer<String> engine,
  required int expectedIndex,
  required Future<void> Function() trigger,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final sw = Stopwatch()..start();
  final actionFuture = trigger();
  await awaitStateOrStream<int?>(
    stream: engine.stream.currentIndex,
    current: () => engine.state.currentIndex,
    predicate: (idx) => idx == expectedIndex,
    timeout: timeout,
    reason: 'Timed out waiting for stream/state currentIndex == $expectedIndex',
  );
  final markMs = sw.elapsedMilliseconds;
  await actionFuture.timeout(timeout);
  return markMs;
}

Future<void> _waitAudioReady(
  MiniaudioPlayer<String> engine,
  int expectedIndex, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  await awaitStateOrStream<int?>(
    stream: engine.stream.currentIndex,
    current: () => engine.state.currentIndex,
    predicate: (idx) => idx == expectedIndex,
    timeout: timeout,
  );
  await awaitStateOrStream<bool>(
    stream: engine.stream.isPlaying,
    current: () => engine.state.isPlaying,
    predicate: (v) => v,
    timeout: timeout,
  );
  await awaitStateOrStream<Duration?>(
    stream: engine.stream.duration,
    current: () => engine.state.duration,
    predicate: (d) => d != null && d > Duration.zero,
    timeout: timeout,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const trackRels = [
    '02_Bailando_con_tu_recuerdo.opus',
    '05_Burning_in_the_Electric_Light.ogg',
    '01_Apex_Momentum.mp3',
    '06_Calculated_Motion_aac.m4a',
  ];

  late _ThrottledRangeHttpServer server;

  setUpAll(() async {
    MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
    await MiniaudioPlayer.ensureInitialized();
    final files = <String, Uint8List>{};
    for (final rel in trackRels) {
      files[rel] = await File('example/assets/music/$rel').readAsBytes();
    }
    files['cold_a.wav'] = _generatePcm16MonoWav(10, 22050);
    files['cold_b.wav'] = _generatePcm16MonoWav(10, 22050);
    final diskFiles = <String, File>{
      for (final spec in _mixedWebCatalog15)
        spec.route: File('example/assets/music/${spec.relFile}'),
    };
    server = await _ThrottledRangeHttpServer.start(files, diskFiles: diskFiles);
  });

  tearDownAll(() async {
    await server.close();
  });

  List<AudioSource<String>> buildQueue(_NetProfile profile) {
    return List.generate(trackRels.length, (i) {
      final rel = trackRels[i];
      final pathOrUrl = profile == _NetProfile.local
          ? 'example/assets/music/$rel'
          : 'http://127.0.0.1:${server.port}/$rel';
      return AudioSource<String>(pathOrUrl, data: 'Track $i');
    });
  }

  const dartBudgetMs = 80;

  group('Track-Switch Queue-Selection Latency Matrix (Dart End-to-End)', () {
    test(
      'S1/S3/S4/S2 across [Local, RemotoFull, RemotoLimitado, RemotoUltraLento] + S5 chained rapid clicks',
      () async {
        final rows = <_LatencyRow>[];

        // 1. S1 (initial play), S3 (manual next), S4 (play different track)
        for (final profile in _NetProfile.values) {
          server.configureProfile(profile);
          final engine = MiniaudioPlayer<String>(
            config: const PlayerConfig(crossfade: CrossfadeConfig.off()),
          );
          try {
            await engine.action.setQueue(buildQueue(profile));

            // S1: initial play()
            final s1Sw = Stopwatch()..start();
            final s1Mark = await _measureIndexSwitch(
              engine: engine,
              expectedIndex: 0,
              trigger: () => engine.action.play(position: 0),
            );
            await _waitAudioReady(engine, 0);
            final s1Aud = s1Sw.elapsedMilliseconds;
            expect(s1Mark, lessThan(dartBudgetMs),
                reason: '${profile.label} S1 exceeded $dartBudgetMs ms');
            rows.add(_LatencyRow(
              profile: profile.label,
              scenario: 'S1: play() inicial (-1 -> 0)',
              markMs: s1Mark,
              audioMs: s1Aud,
            ));

            // S3: manual next()
            final s3Sw = Stopwatch()..start();
            final s3Mark = await _measureIndexSwitch(
              engine: engine,
              expectedIndex: 1,
              trigger: () => engine.action.next(),
            );
            await _waitAudioReady(engine, 1);
            final s3Aud = s3Sw.elapsedMilliseconds;
            expect(s3Mark, lessThan(dartBudgetMs),
                reason: '${profile.label} S3 exceeded $dartBudgetMs ms');
            rows.add(_LatencyRow(
              profile: profile.label,
              scenario: 'S3: next() manual (0 -> 1)',
              markMs: s3Mark,
              audioMs: s3Aud,
            ));

            // S4: play(position: 3) targeting track different from next (index 2)
            await Future<void>.delayed(const Duration(milliseconds: 50));
            final s4Sw = Stopwatch()..start();
            final s4Mark = await _measureIndexSwitch(
              engine: engine,
              expectedIndex: 3,
              trigger: () => engine.action.play(position: 3),
            );
            await _waitAudioReady(engine, 3);
            final s4Aud = s4Sw.elapsedMilliseconds;
            expect(s4Mark, lessThan(dartBudgetMs),
                reason: '${profile.label} S4 exceeded $dartBudgetMs ms');
            rows.add(_LatencyRow(
              profile: profile.label,
              scenario: 'S4: play(otra_pista) (1 -> 3)',
              markMs: s4Mark,
              audioMs: s4Aud,
            ));
          } finally {
            await engine.dispose();
          }
        }

        // 2. S2: Track playing -> seek(95%) -> natural EOF -> next track marked in queue
        for (final profile in _NetProfile.values) {
          server.configureProfile(profile);
          final engine = MiniaudioPlayer<String>(
            config: const PlayerConfig(crossfade: CrossfadeConfig.off()),
          );
          try {
            await engine.action.setQueue(buildQueue(profile));
            await engine.action.play(position: 0);
            await _waitAudioReady(engine, 0);

            final dur = engine.state.duration!;
            final target95 = Duration(milliseconds: (dur.inMilliseconds * 95) ~/ 100);
            await engine.action.seek(target95);
            await awaitStateOrStream<Duration>(
              stream: engine.stream.position,
              current: () => engine.state.position,
              predicate: (p) =>
                  p >= target95 - const Duration(milliseconds: 1500),
              timeout: const Duration(seconds: 15),
            );

            DateTime? eofAt;
            DateTime? markAt;
            final eofDone = Completer<void>();

            final posSub = engine.stream.position.listen((pos) {
              if (eofAt == null &&
                  engine.state.currentIndex == 0 &&
                  pos >= dur) {
                eofAt = DateTime.now();
              }
            });
            final idxSub = engine.stream.currentIndex.listen((idx) {
              if (idx == 1) {
                final now = DateTime.now();
                eofAt ??= now;
                markAt ??= now;
                if (!eofDone.isCompleted) eofDone.complete();
              }
            });

            if (engine.state.currentIndex == 1) {
              final now = DateTime.now();
              eofAt ??= now;
              markAt ??= now;
              eofDone.complete();
            }

            await eofDone.future.timeout(
              const Duration(seconds: 30),
              onTimeout: () => throw TimeoutException(
                '${profile.label} S2 timed out waiting for track 0 EOF (pos=${engine.state.position}, dur=$dur)',
              ),
            );
            await posSub.cancel();
            await idxSub.cancel();

            final markMs = markAt!.difference(eofAt!).inMilliseconds;
            await _waitAudioReady(engine, 1);
            final audioMs = DateTime.now().difference(eofAt!).inMilliseconds;
            expect(markMs, lessThan(dartBudgetMs),
                reason: '${profile.label} S2 exceeded $dartBudgetMs ms');
            rows.add(_LatencyRow(
              profile: profile.label,
              scenario: 'S2: 95% -> EOF (0 -> 1)',
              markMs: markMs,
              audioMs: audioMs,
            ));
          } finally {
            await engine.dispose();
          }
        }

        // 3. S2 Cold-Standby under Remoto Ultra Lento (Track 0 ends before Track 1 opens)
        {
          server.configureProfile(_NetProfile.remoteLimited);
          server.perPathExtraOpenDelayMs['cold_b.wav'] = 2500;
          final engine = MiniaudioPlayer<String>(
            config: const PlayerConfig(crossfade: CrossfadeConfig.off()),
          );
          try {
            await engine.action.setQueue([
              AudioSource<String>(
                'http://127.0.0.1:${server.port}/cold_a.wav',
                data: 'Cold A',
              ),
              AudioSource<String>(
                'http://127.0.0.1:${server.port}/cold_b.wav',
                data: 'Cold B',
              ),
            ]);
            await engine.action.play(position: 0);
            await _waitAudioReady(engine, 0);

            // Switch server to ultra slow AND seek straight to 95% (500ms left on 10s WAV),
            // so cold_b.wav is guaranteed still opening when cold_a.wav reaches EOF.
            server.configureProfile(_NetProfile.remoteUltraSlow);
            server.perPathExtraOpenDelayMs['cold_b.wav'] = 2200;
            final dur = engine.state.duration!;
            final target95 =
                Duration(milliseconds: (dur.inMilliseconds * 95) ~/ 100);
            await engine.action.seek(target95);

            DateTime? eofAt;
            DateTime? markAt;
            final eofDone = Completer<void>();
            final posSub = engine.stream.position.listen((pos) {
              if (eofAt == null &&
                  engine.state.currentIndex == 0 &&
                  pos >= dur) {
                eofAt = DateTime.now();
              }
            });
            final idxSub = engine.stream.currentIndex.listen((idx) {
              if (idx == 1) {
                final now = DateTime.now();
                eofAt ??= now;
                markAt ??= now;
                if (!eofDone.isCompleted) eofDone.complete();
              }
            });

            await eofDone.future.timeout(const Duration(seconds: 20));
            await posSub.cancel();
            await idxSub.cancel();

            final markMs = markAt!.difference(eofAt!).inMilliseconds;
            await _waitAudioReady(engine, 1);
            final audioMs = DateTime.now().difference(eofAt!).inMilliseconds;
            expect(markMs, lessThan(dartBudgetMs));
            rows.add(_LatencyRow(
              profile: 'Remoto Ultra Lento (Cold)',
              scenario: 'S2: EOF sin standby (0 -> 1)',
              markMs: markMs,
              audioMs: audioMs,
            ));
          } finally {
            await engine.dispose();
          }
        }

        // 4. S5: Chained rapid clicks in Dart (next() -> 50ms -> play(position: 3)) on Remoto Ultra Lento
        {
          server.configureProfile(_NetProfile.remoteUltraSlow);
          server.perPathExtraOpenDelayMs[trackRels[1]] = 1000;
          server.perPathExtraOpenDelayMs[trackRels[3]] = 1000;
          final engine = MiniaudioPlayer<String>(
            config: const PlayerConfig(crossfade: CrossfadeConfig.off()),
          );
          try {
            await engine.action.setQueue(buildQueue(_NetProfile.remoteUltraSlow));
            await engine.action.play(position: 0);
            await _waitAudioReady(engine, 0);

            final sw1 = Stopwatch()..start();
            final f1 = engine.action.next().catchError((_) {});
            await awaitStateOrStream<int?>(
              stream: engine.stream.currentIndex,
              current: () => engine.state.currentIndex,
              predicate: (idx) => idx == 1,
              timeout: const Duration(seconds: 5),
            );
            final c1Mark = sw1.elapsedMilliseconds;
            expect(c1Mark, lessThan(dartBudgetMs),
                reason: 'S5a click 1 next() blocked in Dart');
            rows.add(_LatencyRow(
              profile: 'Remoto Ultra Lento',
              scenario: 'S5a: clic 1 next() antes del 2do clic',
              markMs: c1Mark,
              audioMs: 0,
            ));

            await Future<void>.delayed(const Duration(milliseconds: 50));

            final sw2 = Stopwatch()..start();
            final f2 = engine.action.play(position: 3);
            await awaitStateOrStream<int?>(
              stream: engine.stream.currentIndex,
              current: () => engine.state.currentIndex,
              predicate: (idx) => idx == 3,
              timeout: const Duration(seconds: 5),
            );
            final c2Mark = sw2.elapsedMilliseconds;
            await f1.timeout(const Duration(seconds: 15));
            await f2.timeout(const Duration(seconds: 25));
            await _waitAudioReady(engine, 3);
            final c2Audio = sw2.elapsedMilliseconds;
            expect(c2Mark, lessThan(dartBudgetMs),
                reason: 'S5b click 2 play(Track 3) blocked behind click 1 HTTP open');
            rows.add(_LatencyRow(
              profile: 'Remoto Ultra Lento',
              scenario: 'S5b: clic 2 play(Track 3) tras 50ms',
              markMs: c2Mark,
              audioMs: c2Audio,
            ));
          } finally {
            await engine.dispose();
          }
        }

        // Print summary table
        // ignore: avoid_print
        print('\n=== DART E2E TRACK-SWITCH LATENCY SUMMARY ===');
        // ignore: avoid_print
        print('${'Perfil'.padRight(26)} | ${'Escenario'.padRight(38)} | t_mark(ms) | t_audio(ms)');
        // ignore: avoid_print
        print('-' * 92);
        for (final r in rows) {
          // ignore: avoid_print
          print(
            '${r.profile.padRight(26)} | ${r.scenario.padRight(38)} | ${r.markMs.toString().padLeft(10)} | ${r.audioMs.toString().padLeft(11)}',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'Rust-authoritative queue mutations (setQueue/append/insertNext/reorder/removeAt active/clearQueue)',
      () async {
        server.configureCustom(
          openDelayMs: 140,
          rttMs: 45,
          bytesPerSec: 160 * 1024,
          burstFreeBytes: 32 * 1024,
        );
        for (final spec in _mixedWebCatalog15) {
          if (spec.extraOpenDelayMs > 0) {
            server.perPathExtraOpenDelayMs[spec.route] = spec.extraOpenDelayMs;
          }
        }

        final engine = MiniaudioPlayer<String>(
          config: const PlayerConfig(crossfade: CrossfadeConfig.off()),
        );
        try {
          await engine.action.setQueue([
            for (var i = 0; i < 4; i++)
              AudioSource<String>(
                'http://127.0.0.1:${server.port}/${_mixedWebCatalog15[i].route}',
                data: _mixedWebCatalog15[i].formatLabel,
              ),
          ]);
          expect(engine.state.queue.map((e) => e.data).toList(),
              equals(['MP3_VBR', 'OPUS', 'MP3_CBR', 'FLAC']));
          expect(engine.state.currentIndex, isNull);

          final p0 = await _measureIndexSwitch(
            engine: engine,
            expectedIndex: 0,
            trigger: () => engine.action.play(position: 0),
          );
          expect(p0, lessThan(dartBudgetMs));
          await _waitAudioReady(engine, 0);

          await engine.action.insertNext(
            AudioSource<String>(
              'http://127.0.0.1:${server.port}/${_mixedWebCatalog15[4].route}',
              data: _mixedWebCatalog15[4].formatLabel,
            ),
          );
          expect(engine.state.queue.map((e) => e.data).toList(),
              equals(['MP3_VBR', 'OGG_VORBIS', 'OPUS', 'MP3_CBR', 'FLAC']));

          await engine.action.append([
            AudioSource<String>(
              'http://127.0.0.1:${server.port}/${_mixedWebCatalog15[5].route}',
              data: _mixedWebCatalog15[5].formatLabel,
            ),
          ]);
          expect(engine.state.queue.length, equals(6));

          // Reorder executes cleanly inside Rust (_rust.reorder)
          await engine.action.reorder(1, 4);
          expect(engine.state.queue.map((e) => e.data).toList(),
              equals(['MP3_VBR', 'OPUS', 'MP3_CBR', 'FLAC', 'OGG_VORBIS', 'M4A_AAC']));
          expect(engine.state.currentIndex, equals(0));

          // Switch to index 1 (OPUS +600ms delay) then removeAt(1):
          // Rust must emit updated Queue + replacement index immediately (< 80 ms)
          // even when replacement track (MP3_CBR) is opening over throttled HTTP!
          final p1 = await _measureIndexSwitch(
            engine: engine,
            expectedIndex: 1,
            trigger: () => engine.action.play(position: 1),
          );
          expect(p1, lessThan(dartBudgetMs));

          final swRem = Stopwatch()..start();
          final remDone = Completer<void>();
          late StreamSubscription<List<AudioSource<String>>> qSub;
          qSub = engine.stream.queue.listen((q) {
            if (q.length == 5 &&
                q[1].data == 'MP3_CBR' &&
                engine.state.currentIndex == 1 &&
                !remDone.isCompleted) {
              remDone.complete();
            }
          });
          final remFuture = engine.action.removeAt(1);
          await remDone.future.timeout(const Duration(seconds: 5));
          final remMarkMs = swRem.elapsedMilliseconds;
          await qSub.cancel();
          await remFuture.timeout(const Duration(seconds: 20));
          expect(remMarkMs, lessThan(dartBudgetMs),
              reason: 'removeAt(currentIndex) Queue+Index emit took $remMarkMs ms');

          // reorderByIds via Rust
          final reversedIds =
              engine.state.queue.reversed.map((e) => e.id!).toList();
          await engine.action.reorderByIds(reversedIds);
          expect(engine.state.queue.first.id, equals(reversedIds.first));
          expect(engine.state.currentItem?.data, equals('MP3_CBR'));

          // clearQueue keepCurrent -> false
          await engine.action.clearQueue(keepCurrent: true);
          expect(engine.state.queue.length, equals(1));
          expect(engine.state.currentIndex, equals(0));

          await engine.action.clearQueue(keepCurrent: false);
          expect(engine.state.queue, isEmpty);
          expect(engine.state.currentIndex, isNull);
        } finally {
          await engine.dispose();
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      '108 mixed play/next/autoplay succession over throttled web queue across 15 formats',
      () async {
        server.configureCustom(
          openDelayMs: 140,
          rttMs: 45,
          bytesPerSec: 160 * 1024,
          burstFreeBytes: 32 * 1024,
        );
        for (final spec in _mixedWebCatalog15) {
          if (spec.extraOpenDelayMs > 0) {
            server.perPathExtraOpenDelayMs[spec.route] = spec.extraOpenDelayMs;
          }
        }

        final schedule = _buildMixed108Schedule(_mixedWebCatalog15.length);
        expect(schedule.length, greaterThanOrEqualTo(100));

        final engine = MiniaudioPlayer<String>(
          config: const PlayerConfig(crossfade: CrossfadeConfig.off()),
        );
        final inFlightActions = <Future<void>>[];

        try {
          await engine.action.setLoopMode(LoopMode.all);
          await engine.action.setQueue([
            for (final spec in _mixedWebCatalog15)
              AudioSource<String>(
                'http://127.0.0.1:${server.port}/${spec.route}',
                data: spec.formatLabel,
              ),
          ]);
          final queueIds = engine.state.queue.map((e) => e.id!).toList();
          final records = <_DartSuccessionRecord>[];
          var curIdx = -1;

          for (var i = 0; i < schedule.length; i++) {
            final stepNum = i + 1;
            final step = schedule[i];

            switch (step.op) {
              case _MixedOp.playPos:
              case _MixedOp.playId:
              case _MixedOp.next:
                if (step.settleFirst && curIdx >= 0) {
                  await _waitAudioReady(engine, curIdx);
                }
                final targetIdx = switch (step.op) {
                  _MixedOp.next => (max(0, curIdx) + 1) % _mixedWebCatalog15.length,
                  _ => step.target!,
                };
                expect(targetIdx, isNot(equals(curIdx)));
                final fromFmt =
                    curIdx >= 0 ? _mixedWebCatalog15[curIdx].formatLabel : 'STOPPED';
                final stepDone = Completer<DateTime>();
                late StreamSubscription<int?> idxSub;
                idxSub = engine.stream.currentIndex.listen((idx) {
                  if (idx == targetIdx && !stepDone.isCompleted) {
                    stepDone.complete(DateTime.now());
                  }
                });

                final sw = Stopwatch()..start();
                final Future<void> fut = switch (step.op) {
                  _MixedOp.playPos => engine.action.play(position: targetIdx),
                  _MixedOp.playId => engine.action.play(id: queueIds[targetIdx]),
                  _MixedOp.next => engine.action.next(),
                  _ => Future.value(),
                };
                inFlightActions.add(fut.catchError((_) {}));

                if (engine.state.currentIndex == targetIdx &&
                    !stepDone.isCompleted) {
                  stepDone.complete(DateTime.now());
                }
                await stepDone.future.timeout(
                  const Duration(seconds: 5),
                  onTimeout: () => throw TimeoutException(
                    'Dart step $stepNum (${step.op.name} $curIdx->$targetIdx) timed out waiting for currentIndex',
                  ),
                );
                final elapsedUs = sw.elapsedMicroseconds;
                final elapsedMs = sw.elapsedMilliseconds;
                await idxSub.cancel();

                expect(
                  elapsedMs,
                  lessThan(dartBudgetMs),
                  reason:
                      'Dart step $stepNum (${step.op.name} $curIdx->$targetIdx) took $elapsedMs ms (budget < $dartBudgetMs ms)',
                );
                records.add(_DartSuccessionRecord(
                  step: stepNum,
                  opLabel: switch (step.op) {
                    _MixedOp.playPos => 'play_pos',
                    _MixedOp.playId => 'play_id',
                    _MixedOp.next => 'next',
                    _MixedOp.autoplay => 'autoplay',
                  },
                  fromIdx: curIdx,
                  toIdx: targetIdx,
                  fromFmt: fromFmt,
                  toFmt: _mixedWebCatalog15[targetIdx].formatLabel,
                  settledBefore: step.settleFirst,
                  latencyUs: elapsedUs,
                ));
                curIdx = targetIdx;

              case _MixedOp.autoplay:
                await _waitAudioReady(engine, curIdx);
                final dur = engine.state.duration!;
                final targetIdx = (curIdx + 1) % _mixedWebCatalog15.length;
                final fromFmt = _mixedWebCatalog15[curIdx].formatLabel;
                final seekTailMs = max(
                  0,
                  min((dur.inMilliseconds * 99) ~/ 100, dur.inMilliseconds - 1800),
                );
                final targetTail = Duration(milliseconds: seekTailMs);
                await engine.action.seek(targetTail);
                await awaitStateOrStream<Duration>(
                  stream: engine.stream.position,
                  current: () => engine.state.position,
                  predicate: (p) =>
                      p >= Duration(milliseconds: max(0, seekTailMs - 1500)),
                  timeout: const Duration(seconds: 15),
                );

                DateTime? eofAt;
                DateTime? lastTailPosAt;
                DateTime? markAt;
                final eofDone = Completer<void>();

                final posSub = engine.stream.position.listen((pos) {
                  if (engine.state.currentIndex == curIdx) {
                    if (eofAt == null && pos >= dur) {
                      eofAt = DateTime.now();
                    } else if (pos >=
                        Duration(milliseconds: max(0, seekTailMs - 500))) {
                      lastTailPosAt = DateTime.now();
                    }
                  }
                });
                final idxSub = engine.stream.currentIndex.listen((idx) {
                  if (idx == targetIdx && !eofDone.isCompleted) {
                    markAt = DateTime.now();
                    eofDone.complete();
                  }
                });

                if (engine.state.currentIndex == targetIdx && !eofDone.isCompleted) {
                  markAt = DateTime.now();
                  eofDone.complete();
                }

                await eofDone.future.timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => throw TimeoutException(
                    'Dart step $stepNum autoplay ($curIdx->$targetIdx) timed out waiting for EOF (pos=${engine.state.position}, dur=$dur)',
                  ),
                );
                await posSub.cancel();
                await idxSub.cancel();

                final refAt = eofAt ?? lastTailPosAt ?? markAt!;
                final elapsedUs = max(0, markAt!.difference(refAt).inMicroseconds);
                final elapsedMs = elapsedUs / 1000.0;
                expect(
                  elapsedMs,
                  lessThan(dartBudgetMs),
                  reason:
                      'Dart step $stepNum autoplay($curIdx->$targetIdx) took ${elapsedMs.toStringAsFixed(2)} ms (budget < $dartBudgetMs ms)',
                );
                records.add(_DartSuccessionRecord(
                  step: stepNum,
                  opLabel: 'autoplay',
                  fromIdx: curIdx,
                  toIdx: targetIdx,
                  fromFmt: fromFmt,
                  toFmt: _mixedWebCatalog15[targetIdx].formatLabel,
                  settledBefore: true,
                  latencyUs: elapsedUs,
                ));
                curIdx = targetIdx;
            }
          }

          await Future.wait(inFlightActions).timeout(const Duration(seconds: 25));

          final allUs = records.map((r) => r.latencyUs).toList()..sort();
          final stats = _summarizeDartUs(allUs);
          // ignore: avoid_print
          print('\n=== DART >=100-STEP MIXED THROTTLED WEB SUCCESSION BENCHMARK (N=${records.length}) ===');
          // ignore: avoid_print
          print(
            'Global: min=${stats.minMs.toStringAsFixed(3)} ms | avg(promedio)=${stats.avgMs.toStringAsFixed(3)} ms | p50=${stats.p50Ms.toStringAsFixed(3)} ms | p95=${stats.p95Ms.toStringAsFixed(3)} ms | p99=${stats.p99Ms.toStringAsFixed(3)} ms | max=${stats.maxMs.toStringAsFixed(3)} ms',
          );
          for (final op in ['play_pos', 'play_id', 'next', 'autoplay']) {
            final opUs = records
                .where((r) => r.opLabel == op)
                .map((r) => r.latencyUs)
                .toList()
              ..sort();
            final os = _summarizeDartUs(opUs);
            // ignore: avoid_print
            print(
              '  Op ${op.padRight(8)} (n=${opUs.length.toString().padLeft(2)}): min=${os.minMs.toStringAsFixed(3)} ms | avg=${os.avgMs.toStringAsFixed(3)} ms | p50=${os.p50Ms.toStringAsFixed(3)} ms | p95=${os.p95Ms.toStringAsFixed(3)} ms | p99=${os.p99Ms.toStringAsFixed(3)} ms | max=${os.maxMs.toStringAsFixed(3)} ms',
            );
          }

          // ignore: avoid_print
          print('  Unique Autoplay format transitions:');
          for (final r in records.where((r) => r.opLabel == 'autoplay')) {
            // ignore: avoid_print
            print(
              '    step ${r.step.toString().padLeft(3)} | autoplay | ${r.fromIdx.toString().padLeft(2)}(${r.fromFmt.padRight(10)}) -> ${r.toIdx.toString().padLeft(2)}(${r.toFmt.padRight(10)}) | ${(r.latencyUs / 1000.0).toStringAsFixed(3).padLeft(7)} ms',
            );
          }

          final ranked = List<_DartSuccessionRecord>.from(records)
            ..sort((a, b) => b.latencyUs.compareTo(a.latencyUs));
          // ignore: avoid_print
          print('  Top 15 slowest unique cases:');
          for (final r in ranked.take(15)) {
            // ignore: avoid_print
            print(
              '    step ${r.step.toString().padLeft(3)} | ${r.opLabel.padRight(8)} | ${r.fromIdx.toString().padLeft(2)}(${r.fromFmt.padRight(10)}) -> ${r.toIdx.toString().padLeft(2)}(${r.toFmt.padRight(10)}) | settled=${r.settledBefore} | ${(r.latencyUs / 1000.0).toStringAsFixed(3).padLeft(7)} ms',
            );
          }

          expect(
            stats.avgMs,
            lessThan(15.0),
            reason: 'Dart 108-step average latency too high: ${stats.avgMs.toStringAsFixed(3)} ms',
          );
        } finally {
          await engine.dispose();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

enum _MixedOp { playPos, playId, next, autoplay }

class _MixedStepSpec {
  final _MixedOp op;
  final int? target;
  final bool settleFirst;

  const _MixedStepSpec(this.op, {this.target, this.settleFirst = false});
}

class _DartSuccessionRecord {
  final int step;
  final String opLabel;
  final int fromIdx;
  final int toIdx;
  final String fromFmt;
  final String toFmt;
  final bool settledBefore;
  final int latencyUs;

  const _DartSuccessionRecord({
    required this.step,
    required this.opLabel,
    required this.fromIdx,
    required this.toIdx,
    required this.fromFmt,
    required this.toFmt,
    required this.settledBefore,
    required this.latencyUs,
  });
}

List<_MixedStepSpec> _buildMixed108Schedule(int queueLen) {
  final steps = <_MixedStepSpec>[
    const _MixedStepSpec(_MixedOp.playPos, target: 0),
  ];
  var cur = 0;

  const autoplaySources = [0, 1, 2, 4, 5, 9, 10, 12, 13, 14];
  const jumpOffsets = [3, 7, 11, 5, 13, 2, 8];

  for (var round = 0; round < autoplaySources.length; round++) {
    final apFrom = autoplaySources[round];
    final preCount = round < 7 ? 8 : 7;
    for (var i = 0; i < preCount; i++) {
      final settle = i == 3;
      switch ((round + i) % 3) {
        case 0:
          cur = (cur + 1) % queueLen;
          steps.add(_MixedStepSpec(_MixedOp.next, settleFirst: settle));
        case 1:
          var target = (cur + jumpOffsets[(round + i) % jumpOffsets.length]) % queueLen;
          if (target == cur) target = (cur + 1) % queueLen;
          cur = target;
          steps.add(_MixedStepSpec(_MixedOp.playPos, target: target, settleFirst: settle));
        default:
          var target = (cur + queueLen - (jumpOffsets[(round * 2 + i) % jumpOffsets.length] % queueLen)) % queueLen;
          if (target == cur) target = (cur + 2) % queueLen;
          cur = target;
          steps.add(_MixedStepSpec(_MixedOp.playId, target: target, settleFirst: settle));
      }
    }

    if (cur != apFrom) {
      cur = apFrom;
      steps.add(_MixedStepSpec(_MixedOp.playId, target: apFrom));
    } else {
      cur = (apFrom + 1) % queueLen;
      steps.add(const _MixedStepSpec(_MixedOp.next));
      cur = apFrom;
      steps.add(_MixedStepSpec(_MixedOp.playPos, target: apFrom));
    }

    steps.add(const _MixedStepSpec(_MixedOp.autoplay, settleFirst: true));
    cur = (apFrom + 1) % queueLen;

    if (round.isEven) {
      cur = (cur + 1) % queueLen;
      steps.add(const _MixedStepSpec(_MixedOp.next));
    } else {
      var target = (cur + 4) % queueLen;
      if (target == cur) target = (cur + 1) % queueLen;
      cur = target;
      steps.add(_MixedStepSpec(_MixedOp.playPos, target: target));
    }
  }

  var padI = 0;
  while (steps.length < 108) {
    if (padI.isEven) {
      cur = (cur + 1) % queueLen;
      steps.add(const _MixedStepSpec(_MixedOp.next));
    } else {
      var target = (cur + 6) % queueLen;
      if (target == cur) target = (cur + 1) % queueLen;
      cur = target;
      steps.add(_MixedStepSpec(_MixedOp.playId, target: target));
    }
    padI++;
  }
  return steps;
}

({double minMs, double avgMs, double p50Ms, double p95Ms, double p99Ms, double maxMs})
    _summarizeDartUs(List<int> sortedUs) {
  if (sortedUs.isEmpty) {
    return (minMs: 0, avgMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, maxMs: 0);
  }
  final n = sortedUs.length;
  final sum = sortedUs.fold<int>(0, (a, b) => a + b);
  double pct(int p) => sortedUs[((n - 1) * p) ~/ 100] / 1000.0;
  return (
    minMs: sortedUs.first / 1000.0,
    avgMs: (sum / n) / 1000.0,
    p50Ms: pct(50),
    p95Ms: pct(95),
    p99Ms: pct(99),
    maxMs: sortedUs.last / 1000.0,
  );
}
