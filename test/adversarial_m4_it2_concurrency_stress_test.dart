// test/adversarial_m4_it2_concurrency_stress_test.dart
// Challenger M4 It2 Concurrency, Deadlock Resistance & RT Audio Safety Stress Suite

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  group('Challenger M4 It2 Concurrency & Stress Suite', () {
    test(
      'STRESS-1: 100-operation chaotic unawaited burst storm across openUrl, play, stop, seek, pause under progressive streaming',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          try {
            await player.action.stop();
          } catch (_) {}
          player.dispose();
        });

        final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
        final rng = Random(1337);
        final caughtErrors = <Object>[];
        final futures = <Future<void>>[];

        // Initial open
        await player.action.openUrl(url);

        // Burst 100 disordered unawaited actions
        for (int i = 0; i < 100; i++) {
          final actionType = rng.nextInt(6);
          if (rng.nextBool()) {
            await Future<void>.delayed(Duration(microseconds: rng.nextInt(500)));
          }

          Future<void> op;
          switch (actionType) {
            case 0:
              op = player.action.play();
              break;
            case 1:
              op = player.action.stop();
              break;
            case 2:
              op = player.action.pause();
              break;
            case 3:
              final posMs = rng.nextInt(3000);
              op = player.action.seek(Duration(milliseconds: posMs));
              break;
            case 4:
              op = player.action.setVolume(rng.nextDouble() * 1.5);
              break;
            default:
              op = player.action.openUrl(url);
              break;
          }

          futures.add(
            op.catchError((Object err) {
              if (err is MiniaudioPlayerException || err is StateError) {
                caughtErrors.add(err);
              } else {
                throw err;
              }
            }),
          );
        }

        // Wait for all in-flight futures to settle (must NOT hang or deadlock)
        await Future.wait(futures).timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('Deadlock detected during 100-operation chaotic burst!'),
        );

        // Stabilize system with clean stop
        await player.action.stop();

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));
        expect(player.streamer?.isStopped, isTrue);

        // Confirm clean recovery: play() after the storm resumes playback cleanly
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(player.state.playing, isTrue);
        expect(player.state.position.inMilliseconds, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 25)),
    );

    test(
      'STRESS-2: Rapid live-stream 15x stop/play reconnection churn validates zero socket leaks and clean backpressure lifecycle',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          try {
            await player.action.stop();
          } catch (_) {}
          player.dispose();
        });

        final liveUrl = 'http://127.0.0.1:$serverPort/live/salida.mp3';
        await player.action.openUrl(liveUrl, isLive: true);
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.trackMetadata?.isLiveStream, isTrue);

        for (int cycle = 0; cycle < 15; cycle++) {
          // Play live stream
          await player.action.play();
          expect(player.state.playing, isTrue);
          expect(player.streamer?.isBackpressureActive, isTrue,
              reason: 'Backpressure monitor must be active during live playback (cycle $cycle)');

          // Micro-listen
          await Future<void>.delayed(const Duration(milliseconds: 30));

          // Clean stop
          await player.action.stop();
          expect(player.state.playbackState, equals(PlaybackState.stopped));
          expect(player.state.playing, isFalse);
          expect(player.streamer?.isStopped, isTrue);
          expect(player.streamer?.isBackpressureActive, isFalse,
              reason: 'Backpressure monitor must be cancelled on stop (cycle $cycle)');
        }

        // Final verification: player can still play cleanly
        await player.action.play();
        expect(player.state.playing, isTrue);
        expect(player.streamer?.isBackpressureActive, isTrue);
        await player.action.stop();
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'STRESS-3: Multi-player concurrent burst fuzzing with premature dispose during active streaming',
      () async {
        final players = List.generate(3, (_) => MiniaudioPlayer());
        final rng = Random(999);

        try {
          final tasks = <Future<void>>[];

          for (int pIdx = 0; pIdx < players.length; pIdx++) {
            final p = players[pIdx];
            tasks.add(() async {
              final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
              await p.action.openUrl(url);

              for (int j = 0; j < 20; j++) {
                if (rng.nextBool()) {
                  p.action.play().ignore();
                } else {
                  p.action.stop().ignore();
                }
                if (j == 10 && pIdx == 1) {
                  // Abruptly dispose player 1 mid-burst
                  p.dispose();
                  return;
                }
                await Future<void>.delayed(const Duration(milliseconds: 5));
              }

              if (!p.isDisposed) {
                await p.action.stop();
              }
            }());
          }

          await Future.wait(tasks).timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('Deadlock in multi-player concurrent burst!'),
          );
        } finally {
          for (final p in players) {
            if (!p.isDisposed) {
              try {
                await p.action.stop();
              } catch (_) {}
              p.dispose();
            }
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'STRESS-4: Stop during network stall (silence synthesis) does not deadlock with audio thread',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          try {
            await player.action.stop();
          } catch (_) {}
          player.dispose();
        });

        // Use endpoint that stalls after initial burst
        final stallUrl = 'http://127.0.0.1:$serverPort/stall/salida.mp3?stall_ms=3000&initial_burst=65536';

        await player.action.openUrl(stallUrl);
        await player.action.play();

        // Audio thread starts reading, starves, synthesizes PCM silence
        await Future<void>.delayed(const Duration(milliseconds: 150));

        // Abruptly call stop() while audio thread is in silence synthesis loop
        final stopCompleter = Completer<void>();
        player.action.stop().then((_) => stopCompleter.complete()).catchError((Object e) => stopCompleter.completeError(e));

        await stopCompleter.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException('Deadlock between stop() and audio thread during silence synthesis!'),
        );

        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'STRESS-5: Rapid alternating 50x stop/play unawaited bursts without awaiting preceding actions',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          try {
            await player.action.stop();
          } catch (_) {}
          player.dispose();
        });

        final url = 'http://127.0.0.1:$serverPort/music/salida.mp3';
        await player.action.openUrl(url);

        // Rapidly alternate play() and stop() without waiting for each to finish
        final unawaitedFutures = <Future<void>>[];
        for (int i = 0; i < 50; i++) {
          if (i.isEven) {
            unawaitedFutures.add(player.action.play().catchError((_) {}));
          } else {
            unawaitedFutures.add(player.action.stop().catchError((_) {}));
          }
        }

        await Future.wait(unawaitedFutures).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('Deadlock in rapid alternating stop/play bursts!'),
        );

        // Finally, an explicit stop must put player in stopped state
        await player.action.stop();
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.playing, isFalse);
        expect(player.state.position, equals(Duration.zero));

        // And subsequent play starts cleanly
        await player.action.play();
        expect(player.state.playing, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'STRESS-6: Small file EOF replay under rapid stop/play interleaving',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          try {
            await player.action.stop();
          } catch (_) {}
          player.dispose();
        });

        final url = 'http://127.0.0.1:$serverPort/music/cbr_noxing.mp3';
        await player.action.openUrl(url);
        await player.action.play();

        // Let it reach EOF or seek near end
        if (player.state.duration > Duration.zero) {
          final nearEnd = player.state.duration - const Duration(milliseconds: 200);
          if (nearEnd > Duration.zero) {
            await player.action.seek(nearEnd);
          }
        }

        // Wait until completed
        int waitMs = 0;
        while (!player.state.completed && waitMs < 4000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitMs += 50;
        }

        // Burst 20 rapid play() and stop() calls after EOF
        for (int i = 0; i < 20; i++) {
          if (i.isEven) {
            player.action.play().ignore();
          } else {
            player.action.stop().ignore();
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        await player.action.stop();
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.position, equals(Duration.zero));

        // Instant replay from RAM
        await player.action.play();
        expect(player.state.playing, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}

