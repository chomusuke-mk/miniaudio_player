import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../helpers/concurrency_test_utils.dart';

class _TarpitHttpServer {
  final ServerSocket _server;
  final Uint8List _fastWavBytes;
  final List<Socket> _tarpitSockets = [];
  Completer<void> firstTarpitHit = Completer<void>();

  _TarpitHttpServer._(this._server, this._fastWavBytes) {
    _server.listen(_onSocket, onError: (_) {});
  }

  int get port => _server.port;

  static Future<_TarpitHttpServer> start(Uint8List fastWavBytes) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _TarpitHttpServer._(server, fastWavBytes);
  }

  void _onSocket(Socket socket) {
    socket.done.catchError((_) {});
    final buffer = <int>[];
    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        final headerText = String.fromCharCodes(buffer);
        if (!headerText.contains('\r\n\r\n')) return;
        sub.pause();

        if (headerText.contains('/fast.wav')) {
          final headers = 'HTTP/1.1 200 OK\r\n'
              'Content-Type: audio/wav\r\n'
              'Content-Length: ${_fastWavBytes.length}\r\n'
              'Connection: close\r\n\r\n';
          try {
            socket.add(headers.codeUnits);
            socket.add(_fastWavBytes);
            socket.close().catchError((_) {});
          } catch (_) {
            socket.destroy();
          }
        } else {
          _tarpitSockets.add(socket);
          if (!firstTarpitHit.isCompleted) {
            firstTarpitHit.complete();
          }
        }
      },
      onError: (_) {
        socket.destroy();
      },
      cancelOnError: true,
    );
  }

  void releaseAllTarpits() {
    for (final s in _tarpitSockets) {
      s.destroy();
    }
    _tarpitSockets.clear();
  }

  Future<void> close() async {
    releaseAllTarpits();
    await _server.close();
  }
}

class _BlockingCustomProvider implements CustomByteProvider {
  final Uint8List? _bytes;
  @override
  final int streamId;
  final Completer<void> readArrived = Completer<void>();

  _BlockingCustomProvider(this._bytes, {required this.streamId});

  @override
  int? get totalBytes => _bytes?.length ?? 8192;

  @override
  bool get isSeekable => true;

  @override
  Future<Uint8List> readBytes(int offset, int length) async {
    if (!readArrived.isCompleted) {
      readArrived.complete();
    }
    final data = _bytes;
    if (data == null) {
      // Simulate stalled provider waiting on slow upstream until Rust aborts.
      await Future<void>.delayed(const Duration(seconds: 6));
      return Uint8List(0);
    }
    if (offset >= data.length) return Uint8List(0);
    final end = min(offset + length, data.length);
    return data.sublist(offset, end);
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Uint8List wavBytes;
  late Uint8List smallWavBytes;

  setUpAll(() async {
    MiniaudioPlayer.globalConfig.logLevel = MiniaudioLogLevel.none;
    await MiniaudioPlayer.ensureInitialized();
    wavBytes = await File('test/fixtures/salida.wav').readAsBytes();
    smallWavBytes =
        await File('test/fixtures/tripartite/trailing_chunks.wav').readAsBytes();
  });

  group('Tri-Plane Dart <-> Rust Isolation & Multi-Lane Stress Tests', () {
    test(
        'Scenario 1: HTTP tarpit in Queue lane never blocks pause/stop/seek/SFX/ReplayGain or UI getters',
        () async {
      final server = await _TarpitHttpServer.start(wavBytes);
      final player = MiniaudioPlayer<String>();
      try {
        await player.action.setEffects([
          AudioEffect(
            id: 'burst',
            source: AudioSource(Uint8List.fromList(wavBytes)),
            maxPolyphony: 32,
          ),
        ]);

        await player.action.setQueue([
          AudioSource('http://127.0.0.1:${server.port}/tarpit/hang.wav',
              data: 'Stalled'),
          AudioSource('http://127.0.0.1:${server.port}/fast.wav', data: 'Fast'),
        ]);

        // Launch slow tarpit open on Lane 1 without awaiting it.
        final stalledPlayFuture = player.action.play(position: 0);
        await server.firstTarpitHit.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException('Step1: tarpit hit'),
        );

        // 1. High-frequency UI snapshot getters while HTTP tarpit is hung.
        final getterSw = Stopwatch()..start();
        for (var i = 0; i < 1000; i++) {
          player.state.isPlaying;
          player.state.playbackState;
          player.state.position;
          player.state.activeVoicesCount;
          player.state.allocatedRamBytes;
        }
        getterSw.stop();
        expect(getterSw.elapsedMilliseconds, lessThan(50));

        // 2. Concurrent SFX triggers (30 voices) bypass queue lane completely.
        final sfxSw = Stopwatch()..start();
        for (var i = 0; i < 30; i++) {
          await player.action.playEffect(
            'burst',
            config: const EffectConfig(volume: 0.4, looping: true),
          );
        }
        sfxSw.stop();
        expect(player.state.activeVoicesCount, greaterThan(0));
        expect(sfxSw.elapsedMilliseconds, lessThan(500));

        // 3. Immediate RT lane (setVolume, setReplayGain, pause, stop) MUST NOT
        // suffer head-of-line blocking behind stalledPlayFuture.
        final rtSw = Stopwatch()..start();
        await player.action.setVolume(0.8);
        await player.action.setReplayGain(
          const ReplayGainConfig(gainDb: -2.0, peak: 0.9),
          position: 1,
        );
        await player.action.pause();
        rtSw.stop();
        expect(
          rtSw.elapsedMilliseconds,
          lessThan(150),
          reason: 'Immediate RT controls must complete < 150ms even while HTTP tarpit is hung',
        );

        // Stalled open waiter must wake cleanly from Rust cancellation and free Queue lane.
        await stalledPlayFuture.timeout(const Duration(milliseconds: 500));

        await player.action.stop();
        await player.action.stopAllEffects(fadeOut: Duration.zero);

        // 4. Subsequent fast play + immediate seek after cancellation must succeed.
        await player.action.play(position: 1);
        final seekSw = Stopwatch()..start();
        await player.action.seek(const Duration(milliseconds: 250));
        seekSw.stop();
        expect(seekSw.elapsedMilliseconds, lessThan(100));
        expect(player.state.isPlaying, isTrue);
        expect(player.state.currentIndex, equals(1));
      } finally {
        await player.dispose();
        await server.close();
      }
    });

    test(
        'Queue & Navigation lane keeps setQueue + append + removeAt + play FIFO ordered',
        () async {
      final player = MiniaudioPlayer<String>();
      try {
        // Dispatch FIFO mutations without external awaits between them.
        await Future.wait([
          player.action.setQueue([
            AudioSource('test/fixtures/salida.wav', data: 'Track 0'),
          ]),
          player.action.append([
            AudioSource('test/fixtures/salida.wav', data: 'Track 1'),
            AudioSource('test/fixtures/salida.wav', data: 'Track 2'),
          ]),
          player.action.removeAt(1),
          player.action.play(position: 1),
        ]);

        expect(player.state.queue.length, equals(2));
        expect(player.state.queue[1].data, equals('Track 2'));
        expect(player.state.currentIndex, equals(1));
        expect(player.state.isPlaying, isTrue);
      } finally {
        await player.dispose();
      }
    });

    test(
        'Scenarios 4, 5 & 6: SFX catalog hot-swap, recording flush, and CustomByteProvider abort',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('map_tri_plane_');
      final recFile = File('${tempDir.path}/stress_rec.wav');
      final player = MiniaudioPlayer<String>();

      try {
        // Setup active polyphonic SFX storm + hot-swap catalog.
        await player.action.setEffects([
          AudioEffect(
            id: 'fx_a',
            source: AudioSource(Uint8List.fromList(wavBytes)),
            maxPolyphony: 16,
          ),
        ]);
        for (var i = 0; i < 8; i++) {
          await player.action.playEffect(
            'fx_a',
            config: const EffectConfig(volume: 0.3, looping: true),
          );
        }
        expect(player.state.activeVoicesCount, equals(8));

        // Hot-swap catalog while active voices play.
        await player.action.setEffects([
          AudioEffect(
            id: 'fx_b',
            source: AudioSource(Uint8List.fromList(wavBytes)),
            maxPolyphony: 16,
          ),
        ]);
        await player.action.stopAllEffects(fadeOut: Duration.zero);
        expect(player.state.activeVoicesCount, equals(0));

        // Start WAV recording & playback simultaneously.
        final stalledProvider = _BlockingCustomProvider(null, streamId: 7001);
        final fastProvider =
            _BlockingCustomProvider(smallWavBytes, streamId: 7002);

        await player.action.setQueue([
          AudioSource(stalledProvider, data: 'StalledCustom'),
          AudioSource(fastProvider, data: 'FastCustom'),
        ]);
        await player.action.startRecording(
          recFile.path,
          format: AudioFileFormat.wav,
        );

        // Start stalled custom source open, then abort cleanly via setQueue to fast custom source.
        final customPlay = player.action
            .play(position: 0)
            .catchError((_) {}); // Expect clean abort / failure on setQueue override
        await stalledProvider.readArrived.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException('Test3: stalledProvider.readArrived'),
        );

        final abortSw = Stopwatch()..start();
        await player.action.stop().timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException('Test3: action.stop'),
        );
        await player.action
            .setQueue([AudioSource(fastProvider, data: 'FastCustomOnly')])
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () => throw TimeoutException('Test3: action.setQueue(fast)'),
            );
        abortSw.stop();
        await customPlay.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException('Test3: customPlay resolve'),
        );

        expect(
          abortSw.elapsedMilliseconds,
          lessThan(500),
          reason: 'CustomByteProvider must abort immediately rather than waiting 6s provider delay',
        );

        await player.action.play(position: 0).timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Test3: action.play(fast)'),
        );
        await waitForRecordingProgress(
          player,
          minRecorded: const Duration(milliseconds: 80),
        );

        final recResult = await player.action.stopRecording().timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Test3: action.stopRecording'),
        );
        expect(recResult.bytesWritten, greaterThan(44));
        expect(recFile.existsSync(), isTrue);
        final diskBytes = await recFile.readAsBytes();
        expect(String.fromCharCodes(diskBytes.sublist(0, 4)), equals('RIFF'));
        expect(String.fromCharCodes(diskBytes.sublist(8, 12)), equals('WAVE'));
      } finally {
        await player.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
