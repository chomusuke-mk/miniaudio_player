import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

/// Synthesizes a valid uncompressed 16-bit PCM WAV buffer in memory.
Uint8List _buildPcm16WavBytes(
  int frameCount, {
  int sampleRate = 48000,
  int channels = 2,
  double freqHz = 440.0,
}) {
  final dataBytes = frameCount * channels * 2;
  final bytes = Uint8List(44 + dataBytes);
  final view = ByteData.view(bytes.buffer);

  // RIFF chunk header
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  view.setUint32(4, 36 + dataBytes, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);

  // fmt subchunk
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * channels * 2, Endian.little);
  view.setUint16(32, channels * 2, Endian.little);
  view.setUint16(34, 16, Endian.little);

  // data subchunk
  bytes.setRange(36, 40, 'data'.codeUnits);
  view.setUint32(40, dataBytes, Endian.little);

  for (var f = 0; f < frameCount; f++) {
    final t = f / sampleRate;
    final sample = (sin(2.0 * pi * freqHz * t) * 12000.0).round().clamp(-32768, 32767);
    for (var ch = 0; ch < channels; ch++) {
      view.setInt16(44 + (f * channels + ch) * 2, sample, Endian.little);
    }
  }
  return bytes;
}

enum _CustomProviderMode {
  valid,
  throwsOnRead,
  stallAtInitial,
  stallWhenArmed,
}

/// Configurable [CustomByteProvider] supporting valid reads, exceptions, and
/// deterministic `Completer`-based stalls without any blind `Future.delayed`.
class _ChaosCustomByteProvider implements CustomByteProvider {
  @override
  final int streamId;
  final Uint8List _bytes;
  final _CustomProviderMode mode;

  final Completer<void> firstReadStarted = Completer<void>();
  final Completer<void> stallEntered = Completer<void>();
  final Completer<void> _releaseStall = Completer<void>();

  bool _stallArmed = false;
  bool _closed = false;
  int closeCount = 0;

  _ChaosCustomByteProvider({
    required this.streamId,
    required Uint8List bytes,
    this.mode = _CustomProviderMode.valid,
  }) : _bytes = bytes;

  void armStall() {
    _stallArmed = true;
  }

  @override
  int? get totalBytes => _bytes.length;

  @override
  bool get isSeekable => true;

  @override
  Future<Uint8List> readBytes(int offset, int length) async {
    if (!firstReadStarted.isCompleted) {
      firstReadStarted.complete();
    }

    if (mode == _CustomProviderMode.throwsOnRead) {
      throw StateError('Simulated CustomByteProvider read failure');
    }

    final shouldStall =
        (mode == _CustomProviderMode.stallAtInitial) ||
        (mode == _CustomProviderMode.stallWhenArmed && _stallArmed);

    if (shouldStall && !_closed) {
      if (!stallEntered.isCompleted) {
        stallEntered.complete();
      }
      await _releaseStall.future;
      return Uint8List(0);
    }

    if (_closed || offset >= _bytes.length) {
      return Uint8List(0);
    }
    final cappedLength =
        mode == _CustomProviderMode.stallWhenArmed ? min(length, 32768) : length;
    final end = min(offset + cappedLength, _bytes.length);
    return _bytes.sublist(offset, end);
  }

  @override
  Future<void> close() async {
    closeCount++;
    _closed = true;
    if (!_releaseStall.isCompleted) {
      _releaseStall.complete();
    }
  }
}

/// Ephemeral loopback HTTP server for serving valid WAVs, HTTP 404/500 errors,
/// truncated bodies, and event-driven tarpit sockets without `Future.delayed`.
class _ChaosDartHttpServer {
  final HttpServer _server;
  final Uint8List _validWav;
  final Set<HttpRequest> _tarpitRequests = {};
  Completer<void> tarpitHit = Completer<void>();

  _ChaosDartHttpServer._(this._server, this._validWav) {
    _server.listen(_handleRequest);
  }

  static Future<_ChaosDartHttpServer> start(Uint8List validWav) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ChaosDartHttpServer._(server, validWav);
  }

  int get port => _server.port;

  String url(String path) => 'http://127.0.0.1:$port$path';

  void resetTarpitSignal() {
    tarpitHit = Completer<void>();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/valid.wav') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.contentLength = _validWav.length;
        request.response.add(_validWav);
        await request.response.close();
        return;
      }

      if (path == '/http404') {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Not Found');
        await request.response.close();
        return;
      }

      if (path == '/http500') {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('Internal Error');
        await request.response.close();
        return;
      }

      if (path == '/truncated.wav') {
        final partial = min(256, _validWav.length);
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.add(
          'HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: 524288\r\nConnection: close\r\n\r\n'
              .codeUnits,
        );
        socket.add(_validWav.sublist(0, partial));
        await socket.flush();
        await socket.close();
        return;
      }

      // /tarpit.wav: retain request open until canceled/closed.
      _tarpitRequests.add(request);
      if (!tarpitHit.isCompleted) {
        tarpitHit.complete();
      }
      unawaited(
        request.response.done
            .then((_) => _tarpitRequests.remove(request))
            .catchError((Object _) => _tarpitRequests.remove(request)),
      );
    } on Object catch (_) {}
  }

  Future<void> releaseTarpits() async {
    final pending = _tarpitRequests.toList();
    _tarpitRequests.clear();
    for (final req in pending) {
      try {
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    await releaseTarpits();
    await _server.close(force: true);
  }
}

/// Ensures player invariants hold strictly and checks state/stream consistency.
void _verifyConsistency(MiniaudioPlayer<String> player, {String? context}) {
  assertPlayerInvariants(player);
  expect(
    player.state.playbackState.isPlaying,
    equals(player.state.isPlaying),
    reason: context ?? 'PlaybackState.isPlaying must match state.isPlaying atomically',
  );
  expect(
    player.state.isPaused,
    equals(player.state.playbackState == PlaybackState.paused),
    reason: context ?? 'state.isPaused must match PlaybackState.paused',
  );
}

void main() {
  late Uint8List syntheticWav;
  late Uint8List longSyntheticWav;
  late _ChaosDartHttpServer httpServer;

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
    syntheticWav = _buildPcm16WavBytes(144000, freqHz: 330.0); // 3s @ 48kHz stereo
    longSyntheticWav = _buildPcm16WavBytes(48000 * 30, freqHz: 220.0); // 30s @ 48kHz stereo
    httpServer = await _ChaosDartHttpServer.start(syntheticWav);
  });

  tearDownAll(() async {
    await httpServer.close();
  });

  test(
    'Matrix 1: Multi-format instant post-await state consistency and clean failure handling',
    () async {
      final player = MiniaudioPlayer<String>(
        config: const PlayerConfig(sampleRate: 48000, bufferSizeFrames: 512),
      );
      final recordedErrors = <MiniaudioPlayerException>[];
      final errSub = player.stream.errors.listen(recordedErrors.add);

      try {
        final sources = <(String label, AudioSource<String> Function() makeSource)>[
          ('WAV fixture', () => AudioSource('test/fixtures/salida.wav', data: 'wav')),
          ('MP3 fixture', () => AudioSource('test/fixtures/salida.mp3', data: 'mp3')),
          ('FLAC fixture', () => AudioSource('test/fixtures/salida.flac', data: 'flac')),
          ('Opus fixture', () => AudioSource('test/fixtures/salida.opus', data: 'opus')),
          ('AAC fixture', () => AudioSource('test/fixtures/salida_aac.m4a', data: 'aac')),
          ('Memory WAV', () => AudioSource(Uint8List.fromList(syntheticWav), data: 'mem')),
          ('HTTP WAV', () => AudioSource(httpServer.url('/valid.wav'), data: 'http')),
          (
            'CustomByteProvider WAV',
            () => AudioSource(
                  _ChaosCustomByteProvider(
                    streamId: 1001,
                    bytes: syntheticWav,
                    mode: _CustomProviderMode.valid,
                  ),
                  data: 'custom',
                ),
          ),
        ];

        for (final (label, makeSource) in sources) {
          await player.action.setQueue([makeSource()]);
          _verifyConsistency(player, context: '$label post setQueue');
          expect(player.state.queue.length, 1, reason: '$label queue length');
          expect(player.state.currentIndex, isNull, reason: '$label pre-play index');

          await player.action.play(position: 0);
          _verifyConsistency(player, context: '$label immediately post play');
          expect(player.state.playbackState, PlaybackState.playing, reason: '$label playing state');
          expect(player.state.isPlaying, isTrue, reason: '$label isPlaying');
          expect(player.state.currentIndex, 0, reason: '$label currentIndex');

          await waitForAudioProgress(
            player,
            minDelta: const Duration(milliseconds: 40),
          );
          _verifyConsistency(player, context: '$label during audio progress');

          await player.action.pause();
          _verifyConsistency(player, context: '$label immediately post pause');
          expect(player.state.playbackState, PlaybackState.paused, reason: '$label paused');
          expect(player.state.isPlaying, isFalse, reason: '$label !isPlaying on pause');

          await player.action.stop();
          _verifyConsistency(player, context: '$label immediately post stop');
          expect(player.state.playbackState, PlaybackState.stopped, reason: '$label stopped');
          expect(player.state.isPlaying, isFalse, reason: '$label !isPlaying on stop');
        }

        // Verify clean error reporting and unbroken FSM state on invalid/error sources.
        final brokenSources = <(String label, AudioSource<String> Function() makeSource)>[
          ('Missing file', () => AudioSource('test/fixtures/does_not_exist_12345.wav')),
          ('HTTP 404', () => AudioSource(httpServer.url('/http404'))),
          ('HTTP 500', () => AudioSource(httpServer.url('/http500'))),
          (
            'Throwing CustomByteProvider',
            () => AudioSource(
                  _ChaosCustomByteProvider(
                    streamId: 1002,
                    bytes: syntheticWav,
                    mode: _CustomProviderMode.throwsOnRead,
                  ),
                ),
          ),
        ];

        for (final (label, makeSource) in brokenSources) {
          final errCountBefore = recordedErrors.length;
          await player.action.setQueue([makeSource()]);
          Object? thrown;
          try {
            await player.action.play(position: 0);
          } catch (e) {
            thrown = e;
          }
          await drainBroadcastStreams();
          expect(
            thrown != null || recordedErrors.length > errCountBefore,
            isTrue,
            reason: '$label must surface failure either via exception or errors stream',
          );
          await player.action.stop();
          _verifyConsistency(player, context: '$label recovery post stop');
          expect(player.state.isPlaying, isFalse);
        }
      } finally {
        await errSub.cancel();
        await player.dispose();
      }
    },
  );

  test(
    'Matrix 2: Multi-lane Future.wait storm across queue, DSP, SFX, and live observers',
    () async {
      final player = MiniaudioPlayer<String>(
        config: const PlayerConfig(
          sampleRate: 48000,
          bufferSizeFrames: 512,
          maxVoices: 64,
        ),
      );
      final sfxWav = _buildPcm16WavBytes(12000, freqHz: 880.0);
      final subs = <StreamSubscription<dynamic>>[];

      try {
        subs.add(player.stream.position.listen((_) => _verifyConsistency(player, context: 'position listener')));
        subs.add(
          player.stream.playbackState.listen((_) => _verifyConsistency(player, context: 'playbackState listener')),
        );
        subs.add(player.stream.isPlaying.listen((_) => _verifyConsistency(player, context: 'isPlaying listener')));
        subs.add(player.stream.queue.listen((_) => _verifyConsistency(player, context: 'queue listener')));
        subs.add(player.stream.errors.listen((_) {}));

        await player.action.setEffects([
          AudioEffect(id: 'ping', source: AudioSource(Uint8List.fromList(sfxWav)), maxPolyphony: 16, pinned: true),
          AudioEffect(id: 'boom', source: AudioSource('test/fixtures/salida.wav'), maxPolyphony: 8),
        ]);

        await player.action.setQueue([
          AudioSource('test/fixtures/salida.wav', data: 't0'),
          AudioSource('test/fixtures/salida.mp3', data: 't1'),
          AudioSource(Uint8List.fromList(syntheticWav), data: 't2'),
          AudioSource(httpServer.url('/valid.wav'), data: 't3'),
        ]);
        await player.action.play(position: 0);

        for (var round = 0; round < 5; round++) {
          await Future.wait<void>([
            // Serialized Lane 1 queue + transport navigation
            player.action.append([
              AudioSource(Uint8List.fromList(syntheticWav), data: 'app_$round'),
            ]),
            player.action.insertNext(
              AudioSource('test/fixtures/salida.wav', data: 'ins_$round'),
            ),
            player.action.setShuffle(round.isEven),
            player.action.setLoopMode(LoopMode.values[round % LoopMode.values.length]),
            player.action.next(crossfadeDuration: const Duration(milliseconds: 60)),

            // Immediate RT DSP storm running concurrently with Lane 1
            player.action.setVolume(0.5 + (round % 4) * 0.1),
            player.action.setRate(0.9 + (round % 3) * 0.15),
            player.action.setPitch(0.95 + (round % 2) * 0.1),
            player.action.setBalance((round.isEven ? -0.4 : 0.4)),
            player.action.setMono(round.isOdd),
            player.action.setEqualizer(Equalizer(enabled: round.isEven, hz1k: 3.0, hz8k: -2.0)),
            player.action.setReverb(Reverb(enabled: round.isEven, wet: 0.25)),
            player.action.setCrossfeed(round.isEven ? Crossfeed.moffatBauer : Crossfeed.off),
            player.action.setSpatializer(enabled: round.isEven, width: 1.25),
            player.action.setLimiter(true),
            player.action.setCrossfade(const CrossfadeConfig(
              autoDuration: Duration(milliseconds: 150),
              manualDuration: Duration(milliseconds: 60),
            )),
            player.action.setSilenceConfig(SilenceSkipConfig(
              enabled: round.isEven,
              mode: round.isEven ? SilenceSkipMode.trimEdges : SilenceSkipMode.disabled,
            )),
            player.action.setReplayGainMode(ReplayGainMode.values[round % ReplayGainMode.values.length]),

            // Concurrent polyphonic SFX plane
            player.action.playEffect('ping', config: const EffectConfig(volume: 0.4)).then((_) {}),
            player.action.playEffect('boom', config: const EffectConfig(volume: 0.35)).then((_) {}),
          ]);

          _verifyConsistency(player, context: 'Matrix 2 round $round post Future.wait');
          expect(player.state.activeVoicesCount, lessThanOrEqualTo(64));

          if (player.state.queue.length > 5) {
            await player.action.removeAt(player.state.queue.length - 1);
            await player.action.reorder(0, min(1, player.state.queue.length - 1));
          }
          await player.action.stopAllEffects(fadeOut: Duration.zero);
        }

        // Clean end-state recovery check.
        await player.action.setQueue([AudioSource('test/fixtures/salida.wav', data: 'final')]);
        await player.action.play(position: 0);
        await waitForAudioProgress(player, minDelta: const Duration(milliseconds: 50));
        await player.action.stop();
        _verifyConsistency(player, context: 'Matrix 2 clean stop');
      } finally {
        for (final s in subs) {
          await s.cancel();
        }
        await player.dispose();
      }
    },
  );

  test(
    'Matrix 3: Adversarial cancellation, error-injection, and recovery across triggers',
    () async {
      final player = MiniaudioPlayer<String>(
        config: const PlayerConfig(sampleRate: 48000, bufferSizeFrames: 512),
      );
      final errSub = player.stream.errors.listen((_) {});

      try {
        // Part A: Mid-open stalls (HTTP tarpit & CustomByteProvider stalled at byte 0) preempted via Immediate RT lane.
        for (final trigger in ['pause', 'stop']) {
          httpServer.resetTarpitSignal();
          await player.action.setQueue([AudioSource(httpServer.url('/tarpit.wav'), data: 'tarpit')]);
          final openFuture = player.action.play(position: 0).then<Object?>((_) => null).catchError((Object e) => e);
          await httpServer.tarpitHit.future.timeout(const Duration(seconds: 3));

          final sw = Stopwatch()..start();
          if (trigger == 'pause') {
            await player.action.pause();
          } else {
            await player.action.stop();
          }
          await openFuture.timeout(const Duration(seconds: 2));
          sw.stop();

          expect(
            sw.elapsedMilliseconds,
            lessThan(2000),
            reason: 'HTTP tarpit cancellation via $trigger took too long (${sw.elapsedMilliseconds}ms)',
          );
          await httpServer.releaseTarpits();
          _verifyConsistency(player, context: 'HTTP tarpit cancel via $trigger');
        }

        for (final trigger in ['pause', 'stop']) {
          final stalledProvider = _ChaosCustomByteProvider(
            streamId: 3100 + (trigger == 'stop' ? 1 : 0),
            bytes: syntheticWav,
            mode: _CustomProviderMode.stallAtInitial,
          );
          await player.action.setQueue([AudioSource(stalledProvider, data: 'custom_stall_open')]);
          final openFuture = player.action.play(position: 0).then<Object?>((_) => null).catchError((Object e) => e);
          await stalledProvider.stallEntered.future.timeout(const Duration(seconds: 3));

          final sw = Stopwatch()..start();
          if (trigger == 'pause') {
            await player.action.pause();
          } else {
            await player.action.stop();
          }
          await openFuture.timeout(const Duration(seconds: 2));
          await stalledProvider.close();
          sw.stop();

          expect(
            sw.elapsedMilliseconds,
            lessThan(2000),
            reason: 'Initial CustomByteProvider cancel via $trigger took ${sw.elapsedMilliseconds}ms',
          );
          _verifyConsistency(player, context: 'Custom stall open cancel via $trigger');
        }

        // Part B: Mid-stream CustomByteProvider stall (opens header immediately, stalls on background fill)
        // canceled by EVERY trigger: pause, stop, setQueue, next, removeAt, clearQueue.
        final triggers = ['pause', 'stop', 'setQueue', 'next', 'removeAt', 'clearQueue'];
        for (var i = 0; i < triggers.length; i++) {
          final trigger = triggers[i];
          final midStall = _ChaosCustomByteProvider(
            streamId: 3200 + i,
            bytes: longSyntheticWav,
            mode: _CustomProviderMode.stallWhenArmed,
          );
          await player.action.setQueue([
            AudioSource(midStall, data: 'mid_stall_$trigger'),
            AudioSource('test/fixtures/salida.wav', data: 'fallback_$trigger'),
          ]);
          await player.action.play(position: 0);
          midStall.armStall();
          await midStall.stallEntered.future.timeout(const Duration(seconds: 3));

          final sw = Stopwatch()..start();
          switch (trigger) {
            case 'pause':
              await player.action.pause();
            case 'stop':
              await player.action.stop();
            case 'setQueue':
              await player.action.setQueue([AudioSource('test/fixtures/salida.wav', data: 'replaced')]);
            case 'next':
              await player.action.next();
            case 'removeAt':
              await player.action.removeAt(0);
            case 'clearQueue':
              await player.action.clearQueue(keepCurrent: false);
          }
          sw.stop();
          await midStall.close();

          expect(
            sw.elapsedMilliseconds,
            lessThan(2000),
            reason: 'Mid-stream stall cancel via $trigger took ${sw.elapsedMilliseconds}ms',
          );
          _verifyConsistency(player, context: 'Mid-stream cancel via $trigger');

          // Recover onto valid playback after every adversarial cancellation.
          await player.action.setQueue([AudioSource('test/fixtures/salida.wav', data: 'recover_$trigger')]);
          await player.action.play(position: 0);
          await waitForAudioProgress(player, minDelta: const Duration(milliseconds: 30));
          await player.action.stop();
        }

        // Part C: Truncated HTTP body + HTTP 404/500 followed by immediate clean recovery.
        await player.action.setQueue([
          AudioSource(httpServer.url('/truncated.wav'), data: 'trunc'),
          AudioSource(httpServer.url('/http500'), data: 'err500'),
          AudioSource('test/fixtures/salida.wav', data: 'good'),
        ]);
        await player.action.play(position: 0).then<Object?>((_) => null).catchError((Object e) => e);
        await player.action.play(position: 2);
        await waitForAudioProgress(player, minDelta: const Duration(milliseconds: 40));
        await player.action.stop();
      } finally {
        await errSub.cancel();
        await player.dispose();
      }
    },
  );

  test(
    'Matrix 4: Seeded 250-step chaotic Markov fuzz matrix with continuous invariants',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('map_markov_fuzz_');
      final player = MiniaudioPlayer<String>(
        config: const PlayerConfig(sampleRate: 48000, bufferSizeFrames: 512, maxVoices: 64),
      );
      final errSub = player.stream.errors.listen((_) {});
      final rng = Random(0xC0DEC405);
      final sfxWav = _buildPcm16WavBytes(8000, freqHz: 660.0);
      var recCounter = 0;

      AudioSource<String> randomSource(int idHint) {
        switch (rng.nextInt(6)) {
          case 0:
            return AudioSource('test/fixtures/salida.wav', data: 'wav_$idHint');
          case 1:
            return AudioSource('test/fixtures/salida.mp3', data: 'mp3_$idHint');
          case 2:
            return AudioSource('test/fixtures/salida.flac', data: 'flac_$idHint');
          case 3:
            return AudioSource(Uint8List.fromList(syntheticWav), data: 'mem_$idHint');
          case 4:
            return AudioSource(httpServer.url('/valid.wav'), data: 'http_$idHint');
          default:
            return AudioSource(httpServer.url('/http404'), data: 'err_$idHint');
        }
      }

      try {
        await player.action.setEffects([
          AudioEffect(id: 'fx_a', source: AudioSource(Uint8List.fromList(sfxWav)), maxPolyphony: 16, pinned: true),
          AudioEffect(id: 'fx_b', source: AudioSource('test/fixtures/salida.wav'), maxPolyphony: 8),
        ]);
        await player.action.setQueue([randomSource(0), randomSource(1), randomSource(2)]);

        for (var step = 0; step < 250; step++) {
          Future<void> ignoreExpectedFailure(Future<dynamic> f) async {
            try {
              await f;
            } catch (_) {}
          }

          final op = rng.nextInt(18);
          switch (op) {
            case 0:
            case 1:
              await ignoreExpectedFailure(
                player.action.play(
                  position: player.state.queue.isEmpty ? null : rng.nextInt(player.state.queue.length),
                  shuffled: rng.nextBool() ? rng.nextBool() : null,
                  seek: Duration(milliseconds: rng.nextInt(300)),
                ),
              );
            case 2:
              await ignoreExpectedFailure(player.action.pause());
            case 3:
              await ignoreExpectedFailure(player.action.stop());
            case 4:
              await ignoreExpectedFailure(
                player.action.seek(Duration(milliseconds: rng.nextInt(1200))),
              );
            case 5:
              await ignoreExpectedFailure(
                player.action.next(crossfadeDuration: Duration(milliseconds: rng.nextInt(120))),
              );
            case 6:
              await ignoreExpectedFailure(player.action.previous());
            case 7:
              await ignoreExpectedFailure(
                player.action.setQueue(
                  List.generate(1 + rng.nextInt(4), (idx) => randomSource(step * 10 + idx)),
                ),
              );
            case 8:
              await ignoreExpectedFailure(player.action.append([randomSource(step)]));
            case 9:
              await ignoreExpectedFailure(player.action.insertNext(randomSource(step)));
            case 10:
              if (player.state.queue.length > 1) {
                await ignoreExpectedFailure(
                  player.action.removeAt(rng.nextInt(player.state.queue.length)),
                );
              }
            case 11:
              if (player.state.queue.length > 1) {
                await ignoreExpectedFailure(
                  player.action.reorder(
                    rng.nextInt(player.state.queue.length),
                    rng.nextInt(player.state.queue.length),
                  ),
                );
              }
            case 12:
              await ignoreExpectedFailure(player.action.clearQueue(keepCurrent: rng.nextBool()));
            case 13:
              await player.action.setShuffle(rng.nextBool());
              await player.action.setLoopMode(LoopMode.values[rng.nextInt(LoopMode.values.length)]);
            case 14:
              await player.action.setVolume(0.2 + rng.nextDouble() * 0.9);
              await player.action.setRate(0.75 + rng.nextDouble() * 0.75);
              await player.action.setPitch(0.75 + rng.nextDouble() * 0.6);
              await player.action.setBalance(-1.0 + rng.nextDouble() * 2.0);
              await player.action.setMono(rng.nextBool());
            case 15:
              await player.action.setEqualizer(Equalizer(enabled: rng.nextBool(), hz1k: -4.0 + rng.nextDouble() * 8.0));
              await player.action.setReverb(Reverb(enabled: rng.nextBool(), wet: 0.2));
              await player.action.setCrossfeed(rng.nextBool() ? Crossfeed.moffatBauer : Crossfeed.off);
              await player.action.setSpatializer(enabled: rng.nextBool(), width: 1.1);
              await player.action.setLimiter(rng.nextBool());
            case 16:
              await ignoreExpectedFailure(
                player.action.playEffect(rng.nextBool() ? 'fx_a' : 'fx_b', config: const EffectConfig(volume: 0.3)),
              );
              if (step % 5 == 0) {
                await player.action.stopAllEffects(fadeOut: Duration.zero);
              }
            default:
              // Periodic WAV recording capture + verification.
              final recPath = '${tempDir.path}/fuzz_rec_${recCounter++}.wav';
              await player.action.setQueue([AudioSource('test/fixtures/salida.wav', data: 'rec_wav')]);
              await player.action.play(position: 0);
              await player.action.startRecording(recPath, format: AudioFileFormat.wav, source: AudioOutputSource.all);
              await waitForAudioProgress(player, minDelta: const Duration(milliseconds: 30));
              await waitForRecordingProgress(player, minRecorded: const Duration(milliseconds: 30));
              final result = await player.action.stopRecording();
              expect(result.bytesWritten, greaterThan(44));
              expect(result.sampleCount, greaterThan(0));
              expect(File(recPath).existsSync(), isTrue);
          }

          await drainBroadcastStreams(1);
          _verifyConsistency(player, context: 'Markov fuzz step $step (op=$op)');
        }

        // Final deterministic recovery verification.
        await player.action.stopAllEffects(fadeOut: Duration.zero);
        await player.action.setQueue([AudioSource('test/fixtures/salida.wav', data: 'final')]);
        await player.action.play(position: 0);
        await waitForAudioProgress(player, minDelta: const Duration(milliseconds: 50));
        await player.action.stop();
        _verifyConsistency(player, context: 'Markov fuzz final recovery');
      } finally {
        await errSub.cancel();
        await player.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    },
  );

  test(
    'Matrix 5: Concurrent dispose() under active multi-lane load, HTTP tarpits, and recording',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('map_dispose_storm_');
      try {
        for (var cycle = 0; cycle < 5; cycle++) {
          final player = MiniaudioPlayer<String>(
            config: const PlayerConfig(sampleRate: 48000, bufferSizeFrames: 512),
          );
          final errSub = player.stream.errors.listen((_) {});
          final recPath = '${tempDir.path}/dispose_rec_$cycle.wav';

          await player.action.setEffects([
            AudioEffect(
              id: 'loop_ping',
              source: AudioSource(Uint8List.fromList(_buildPcm16WavBytes(12000))),
              maxPolyphony: 8,
              pinned: true,
            ),
          ]);
          await player.action.playEffect(
            'loop_ping',
            config: const EffectConfig(looping: true, volume: 0.25),
          );

          final useCustomStall = cycle.isOdd;
          _ChaosCustomByteProvider? customStall;
          Future<Object?>? stalledPlay;

          if (useCustomStall) {
            customStall = _ChaosCustomByteProvider(
              streamId: 5000 + cycle,
              bytes: syntheticWav,
              mode: _CustomProviderMode.stallAtInitial,
            );
            await player.action.setQueue([AudioSource(customStall, data: 'stall_$cycle')]);
            await player.action.startRecording(recPath, format: AudioFileFormat.wav);
            stalledPlay = player.action.play(position: 0).then<Object?>((_) => null).catchError((Object e) => e);
            await customStall.stallEntered.future.timeout(const Duration(seconds: 3));
          } else {
            httpServer.resetTarpitSignal();
            await player.action.setQueue([AudioSource(httpServer.url('/tarpit.wav'), data: 'tarpit_$cycle')]);
            await player.action.startRecording(recPath, format: AudioFileFormat.wav);
            stalledPlay = player.action.play(position: 0).then<Object?>((_) => null).catchError((Object e) => e);
            await httpServer.tarpitHit.future.timeout(const Duration(seconds: 3));
          }

          // Issue RT DSP updates immediately prior to concurrent dispose().
          final sw = Stopwatch()..start();
          await Future.wait<void>([
            player.action.setVolume(0.6).catchError((_) {}),
            player.action.setRate(1.1).catchError((_) {}),
            player.dispose(),
          ]);
          sw.stop();

          if (useCustomStall) {
            expect(customStall!.closeCount, greaterThanOrEqualTo(1));
          } else {
            await httpServer.releaseTarpits();
          }
          await stalledPlay.timeout(const Duration(seconds: 2));
          await errSub.cancel();

          expect(player.isDisposed, isTrue);
          expect(
            sw.elapsedMilliseconds,
            lessThan(2000),
            reason: 'Cycle $cycle dispose() under load exceeded budget (${sw.elapsedMilliseconds}ms)',
          );
        }
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    },
  );
}
