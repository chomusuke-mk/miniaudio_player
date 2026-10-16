// test/chaotic_concurrency_fuzz_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

Future<void> safeDispatch(Future<void> Function() action, List<Object> caughtErrors) {
  try {
    final future = action();
    return future.catchError((Object error, StackTrace stack) {
      if (error is MiniaudioPlayerException || error is StateError || error is ArgumentError) {
        caughtErrors.add(error);
      } else {
        // Unexpected system crash error rethrown
        throw error;
      }
    });
  } catch (syncError) {
    if (syncError is MiniaudioPlayerException || syncError is StateError || syncError is ArgumentError) {
      caughtErrors.add(syncError);
      return Future.value();
    }
    rethrow;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Chaotic Concurrency & Stress Fuzzing (R3)', () {
    late File shortWavFile;
    late File mediumWavFile;
    late Uint8List memoryWavBytes;

    setUpAll(() async {
      shortWavFile = await SyntheticAudioGenerator.createTempWavFile(
        fileName: 'fuzz_short.wav',
        frequencyHz: 440.0,
        durationSeconds: 1.5,
      );
      mediumWavFile = await SyntheticAudioGenerator.createTempWavFile(
        fileName: 'fuzz_medium.wav',
        frequencyHz: 880.0,
        durationSeconds: 5.0,
      );
      memoryWavBytes = SyntheticAudioGenerator.generateWavBytes(
        frequencyHz: 554.37,
        durationSeconds: 2.0,
      );
    });

    tearDownAll(() async {
      await SyntheticAudioGenerator.cleanUp(shortWavFile);
      await SyntheticAudioGenerator.cleanUp(mediumWavFile);
    });

    // =========================================================================
    // Test 1: Single-Player Chaotic Fuzzing (220+ Randomized Disordered Operations)
    // =========================================================================
    test(
      'F1: Single-player deterministic chaotic fuzzing across 220+ operations with un-awaited futures',
      () async {
        final rng = Random(42);
        final caughtErrors = <Object>[];
        var player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        final backgroundTasks = <Future<void>>[];

        for (int opIndex = 0; opIndex < 220; opIndex++) {
          final opType = rng.nextInt(13);

          // Micro-interval yield (0 to 400 microseconds)
          if (rng.nextBool()) {
            await Future<void>.delayed(Duration(microseconds: rng.nextInt(400)));
          }

          switch (opType) {
            case 0: // open
              final sourceSelect = rng.nextInt(3);
              final autoPlay = rng.nextBool();
              if (sourceSelect == 0) {
                backgroundTasks.add(
                  safeDispatch(() => player.action.open(shortWavFile.path, autoPlay: autoPlay), caughtErrors),
                );
              } else if (sourceSelect == 1) {
                backgroundTasks.add(
                  safeDispatch(() => player.action.open(mediumWavFile.path, autoPlay: autoPlay), caughtErrors),
                );
              } else {
                backgroundTasks.add(
                  safeDispatch(() => player.action.openMemory(memoryWavBytes, autoPlay: autoPlay), caughtErrors),
                );
              }
              break;

            case 1: // play
              backgroundTasks.add(safeDispatch(() => player.action.play(), caughtErrors));
              break;

            case 2: // pause
              backgroundTasks.add(safeDispatch(() => player.action.pause(), caughtErrors));
              break;

            case 3: // stop
              backgroundTasks.add(safeDispatch(() => player.action.stop(), caughtErrors));
              break;

            case 4: // seek
              final seekMs = rng.nextInt(10000) - 2000; // -2s to 8s
              backgroundTasks.add(
                safeDispatch(() => player.action.seek(Duration(milliseconds: seekMs)), caughtErrors),
              );
              break;

            case 5: // setVolume
              final volume = (rng.nextDouble() * 3.0) - 0.5; // -0.5 to 2.5
              backgroundTasks.add(safeDispatch(() => player.action.setVolume(volume), caughtErrors));
              break;

            case 6: // setRate
              final rate = 0.1 + rng.nextDouble() * 3.9; // 0.1 to 4.0
              backgroundTasks.add(safeDispatch(() => player.action.setRate(rate), caughtErrors));
              break;

            case 7: // setPitch
              final pitch = 0.5 + rng.nextDouble() * 1.5; // 0.5 to 2.0
              backgroundTasks.add(safeDispatch(() => player.action.setPitch(pitch), caughtErrors));
              break;

            case 8: // setEqualizer
              final eqChoice = rng.nextInt(6);
              final Equalizer eq;
              switch (eqChoice) {
                case 0: eq = Equalizer.flat; break;
                case 1: eq = Equalizer.rock; break;
                case 2: eq = Equalizer.jazz; break;
                case 3: eq = Equalizer.bassBoost; break;
                default:
                  eq = Equalizer(
                    hz31: (rng.nextDouble() * 48.0) - 24.0,
                    hz63: (rng.nextDouble() * 48.0) - 24.0,
                    hz125: (rng.nextDouble() * 48.0) - 24.0,
                    hz250: (rng.nextDouble() * 48.0) - 24.0,
                    hz500: (rng.nextDouble() * 48.0) - 24.0,
                    hz1k: (rng.nextDouble() * 48.0) - 24.0,
                    hz2k: (rng.nextDouble() * 48.0) - 24.0,
                    hz4k: (rng.nextDouble() * 48.0) - 24.0,
                    hz8k: (rng.nextDouble() * 48.0) - 24.0,
                    hz16k: (rng.nextDouble() * 48.0) - 24.0,
                  );
              }
              backgroundTasks.add(safeDispatch(() => player.action.setEqualizer(eq), caughtErrors));
              break;

            case 9: // setSkipSilence & config
              final enable = rng.nextBool();
              final mode = SilenceSkipMode.values[rng.nextInt(SilenceSkipMode.values.length)];
              final config = SilenceSkipConfig(
                mode: mode,
                thresholdDb: -60.0 + rng.nextDouble() * 50.0,
                minSilenceDuration: Duration(milliseconds: 100 + rng.nextInt(400)),
                padding: Duration(milliseconds: 10 + rng.nextInt(90)),
              );
              backgroundTasks.add(safeDispatch(() => player.action.setSkipSilence(enable), caughtErrors));
              backgroundTasks.add(safeDispatch(() => player.action.setSilenceConfig(config), caughtErrors));
              break;

            case 10: // setVisualizerEnabled
              final viz = rng.nextBool();
              backgroundTasks.add(safeDispatch(() => player.action.setVisualizerEnabled(viz), caughtErrors));
              break;

            case 11: // other DSP (limiter, crossfeed, balance)
              final limiter = rng.nextBool();
              final crossfeed = CrossfeedMode.values[rng.nextInt(CrossfeedMode.values.length)];
              final balance = (rng.nextDouble() * 2.0) - 1.0;
              backgroundTasks.add(safeDispatch(() => player.action.setLimiter(limiter), caughtErrors));
              backgroundTasks.add(safeDispatch(() => player.action.setCrossfeed(crossfeed), caughtErrors));
              backgroundTasks.add(safeDispatch(() => player.action.setBalance(balance), caughtErrors));
              break;

            case 12: // mid-fuzz dispose & recreation
              if (!player.isDisposed && rng.nextInt(10) == 0) {
                backgroundTasks.add(safeDispatch(() => player.dispose(), caughtErrors));
                // Immediately resurrect a new instance to continue fuzzing
                player = MiniaudioPlayer();
              }
              break;
          }
        }

        // Await all in-flight chaotic operations to ensure complete draining
        await Future.wait(backgroundTasks);

        // Verification invariants:
        expect(player.state.volume, greaterThanOrEqualTo(0.0));
        expect(player.state.volume, lessThanOrEqualTo(2.0));
        expect(player.state.position.inMilliseconds, greaterThanOrEqualTo(0));
        if (!player.isDisposed) {
          await player.dispose();
        }
        expect(player.isDisposed, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    // =========================================================================
    // Test 2: Multi-Player Chaotic Cross-Fire
    // =========================================================================
    test(
      'F2: Multi-player cross-fire across 4 concurrent players receiving unordered commands',
      () async {
        final rng = Random(42);
        final caughtErrors = <Object>[];
        final players = List.generate(4, (_) => MiniaudioPlayer());

        addTearDown(() async {
          for (final p in players) {
            if (!p.isDisposed) await p.dispose();
          }
        });

        // 4 concurrent async worker pipelines blasting commands simultaneously
        final workerFutures = <Future<void>>[];

        for (int pIdx = 0; pIdx < 4; pIdx++) {
          final p = players[pIdx];
          workerFutures.add(Future(() async {
            for (int i = 0; i < 60; i++) {
              final cmd = rng.nextInt(7);
              switch (cmd) {
                case 0:
                  await safeDispatch(() => p.action.open(shortWavFile.path, autoPlay: true), caughtErrors);
                  break;
                case 1:
                  await safeDispatch(() => p.action.pause(), caughtErrors);
                  break;
                case 2:
                  await safeDispatch(() => p.action.seek(Duration(milliseconds: rng.nextInt(3000))), caughtErrors);
                  break;
                case 3:
                  await safeDispatch(() => p.action.setVolume(rng.nextDouble()), caughtErrors);
                  break;
                case 4:
                  await safeDispatch(() => p.action.setRate(0.5 + rng.nextDouble()), caughtErrors);
                  break;
                case 5:
                  await safeDispatch(() => p.action.setEqualizer(Equalizer.rock), caughtErrors);
                  break;
                case 6:
                  await safeDispatch(() => p.action.stop(), caughtErrors);
                  break;
              }
              await Future<void>.delayed(Duration(microseconds: rng.nextInt(300)));
            }
          }));
        }

        await Future.wait(workerFutures);

        // Verify zero cross-talk & independent health
        for (final p in players) {
          expect(p.isDisposed, isFalse);
          expect(p.state.volume, inInclusiveRange(0.0, 1.0));
          await p.dispose();
          expect(p.isDisposed, isTrue);
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    // =========================================================================
    // Test 3: Rapid Instantiate / Open / Dispose Churn Fuzzing Across Micro-Intervals
    // =========================================================================
    test(
      'F3: Rapid lifecycle churn fuzzing across 35 instantiate/open/dispose micro-intervals',
      () async {
        final rng = Random(42);
        final caughtErrors = <Object>[];

        for (int i = 0; i < 35; i++) {
          final player = MiniaudioPlayer();
          final microDelay = rng.nextInt(3000); // 0 to 3ms

          if (i % 2 == 0) {
            unawaited(safeDispatch(() => player.action.open(shortWavFile.path, autoPlay: true), caughtErrors));
          } else {
            unawaited(safeDispatch(() => player.action.openMemory(memoryWavBytes, autoPlay: false), caughtErrors));
          }

          if (microDelay > 0) {
            await Future<void>.delayed(Duration(microseconds: microDelay));
          }

          // Random interleaved transport command
          if (rng.nextBool()) {
            unawaited(safeDispatch(() => player.action.play(), caughtErrors));
          } else {
            unawaited(safeDispatch(() => player.action.setVolume(0.75), caughtErrors));
          }

          await player.dispose();
          expect(player.isDisposed, isTrue);
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
