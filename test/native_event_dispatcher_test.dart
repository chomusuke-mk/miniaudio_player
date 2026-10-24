import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

// =============================================================================
// ZoneSpecification Periodic Timer Tracking Harness
// =============================================================================

/// Wraps a [Timer] to track active liveness and cancellation.
class TrackedPeriodicTimer implements Timer {
  final Timer _inner;
  final Duration period;
  final StackTrace stackTrace;
  bool _isCancelled = false;

  TrackedPeriodicTimer(this._inner, this.period, this.stackTrace);

  @override
  void cancel() {
    _isCancelled = true;
    _inner.cancel();
  }

  @override
  bool get isActive => !_isCancelled && _inner.isActive;

  @override
  int get tick => _inner.tick;
}

/// Tracks all periodic timer creations within an intercepted [Zone].
class ZoneTimerTracker {
  final List<TrackedPeriodicTimer> _periodicTimers = [];

  int get totalPeriodicCreated => _periodicTimers.length;
  int get activePeriodicCount =>
      _periodicTimers.where((t) => t.isActive).length;
  List<TrackedPeriodicTimer> get periodicTimers =>
      List.unmodifiable(_periodicTimers);

  void assertZeroPeriodicTimers({String? context}) {
    if (_periodicTimers.isNotEmpty) {
      final details = _periodicTimers
          .map(
            (t) =>
                '- Period: ${t.period}, Active: ${t.isActive}\n  Stack:\n${t.stackTrace}',
          )
          .join('\n');
      fail(
        'Periodic timer detected${context != null ? ' during $context' : ''}!\n'
        'Native reactive event dispatcher must not spawn periodic timers.\n$details',
      );
    }
  }

  ZoneSpecification get zoneSpecification {
    return ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        final tracked = TrackedPeriodicTimer(
          parent.createPeriodicTimer(zone, period, callback),
          period,
          StackTrace.current,
        );
        _periodicTimers.add(tracked);
        return tracked;
      },
    );
  }
}

/// Executes [block] inside an intercepted Zone, asserting that 0 periodic timers
/// are instantiated or active throughout the operation.
Future<R> runWithZeroPeriodicTimerProof<R>(
  Future<R> Function(ZoneTimerTracker tracker) block, {
  String? description,
}) async {
  final tracker = ZoneTimerTracker();
  final result = await runZoned(
    () => block(tracker),
    zoneSpecification: tracker.zoneSpecification,
  );
  tracker.assertZeroPeriodicTimers(context: description);
  return result;
}

// =============================================================================
// Main Test Entrypoint
// =============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File sampleWavFile;
  late File shortWavFile;
  late Uint8List memoryWavBytes;
  late File emptyWavFile;
  late File corruptJunkFile;
  late File truncatedHeaderFile;

  setUpAll(() async {
    sampleWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'm3_dispatcher_sample.wav',
      frequencyHz: 440.0,
      durationSeconds: 3.0,
      sampleRate: 44100,
      numChannels: 2,
    );
    shortWavFile = await SyntheticAudioGenerator.createTempWavFile(
      fileName: 'm3_dispatcher_short.wav',
      frequencyHz: 880.0,
      durationSeconds: 0.5,
      sampleRate: 44100,
      numChannels: 1,
    );
    memoryWavBytes = SyntheticAudioGenerator.generateWavBytes(
      frequencyHz: 554.37,
      durationSeconds: 0.6,
      sampleRate: 44100,
      numChannels: 1,
    );

    final tempDir = await Directory.systemTemp.createTemp(
      'miniaudio_m3_test_assets_',
    );
    emptyWavFile = File('${tempDir.path}/empty.wav');
    await emptyWavFile.writeAsBytes(const []);

    corruptJunkFile = File('${tempDir.path}/corrupt_junk.wav');
    await corruptJunkFile.writeAsBytes(List<int>.filled(256, 0xFF));

    truncatedHeaderFile = File('${tempDir.path}/truncated_header.wav');
    await truncatedHeaderFile.writeAsBytes(
      [0x52, 0x49, 0x46, 0x46, 0x24, 0x00],
    ); // partial RIFF
  });

  tearDownAll(() async {
    await SyntheticAudioGenerator.cleanUp(sampleWavFile);
    await SyntheticAudioGenerator.cleanUp(shortWavFile);
    if (emptyWavFile.existsSync()) await emptyWavFile.delete();
    if (corruptJunkFile.existsSync()) await corruptJunkFile.delete();
    if (truncatedHeaderFile.existsSync()) await truncatedHeaderFile.delete();
  });

  // ===========================================================================
  // GROUP 1: Empirical ZoneSpecification Timer Elimination Proof
  // ===========================================================================
  group('Group 1: Empirical ZoneSpecification Timer Elimination Proof', () {
    test(
      '1.1: Complete playback lifecycle creates 0 periodic timers',
      () async {
        await runWithZeroPeriodicTimerProof((tracker) async {
          final player = MiniaudioPlayer();
          try {
            expect(tracker.totalPeriodicCreated, equals(0));
            await player.action.openFile(sampleWavFile.path);
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.play();
            expect(player.state.playing, isTrue);

            // Active playback for 600ms
            await Future<void>.delayed(const Duration(milliseconds: 600));
            expect(player.state.position.inMilliseconds, greaterThan(150));
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.pause();
            expect(player.state.playing, isFalse);
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.seek(const Duration(milliseconds: 1200));
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.play();
            await Future<void>.delayed(const Duration(milliseconds: 300));
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.stop();
            expect(tracker.totalPeriodicCreated, equals(0));
          } finally {
            await player.dispose();
          }
          expect(tracker.totalPeriodicCreated, equals(0));
          expect(tracker.activePeriodicCount, equals(0));
        }, description: 'complete playback lifecycle');
      },
    );

    test(
      '1.2: Active visualizer listening with live FFT telemetry creates 0 periodic timers',
      () async {
        await runWithZeroPeriodicTimerProof((tracker) async {
          final player = MiniaudioPlayer();
          final visEvents = <VisualizerData>[];
          StreamSubscription<VisualizerData>? sub;

          try {
            sub = player.stream.visualizer.listen(visEvents.add);
            await player.action.setVisualizerEnabled(true);
            await player.action.openFile(sampleWavFile.path);
            await player.action.play();

            // Allow 600ms for native FFT telemetry to arrive
            await Future<void>.delayed(const Duration(milliseconds: 600));

            expect(tracker.totalPeriodicCreated, equals(0));
            expect(tracker.activePeriodicCount, equals(0));
            expect(
              visEvents,
              isNotEmpty,
              reason: 'Visualizer data must be pushed natively from C',
            );
          } finally {
            await sub?.cancel();
            await player.action.setVisualizerEnabled(false);
            await player.dispose();
          }
          expect(tracker.totalPeriodicCreated, equals(0));
        }, description: 'active visualizer listening');
      },
    );

    test(
      '1.3: In-memory audio playback (openMemory) creates 0 periodic timers',
      () async {
        await runWithZeroPeriodicTimerProof((tracker) async {
          final player = MiniaudioPlayer();
          try {
            await player.action.openMemory(memoryWavBytes);
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.play();
            expect(player.state.playing, isTrue);

            await Future<void>.delayed(const Duration(milliseconds: 300));
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.pause();
            expect(tracker.totalPeriodicCreated, equals(0));

            await player.action.stop();
            expect(tracker.totalPeriodicCreated, equals(0));
          } finally {
            await player.dispose();
          }
          expect(tracker.totalPeriodicCreated, equals(0));
        }, description: 'in-memory playback');
      },
    );

    test(
      '1.4: Rapid DSP parameter mutation bursts create 0 periodic timers',
      () async {
        await runWithZeroPeriodicTimerProof((tracker) async {
          final player = MiniaudioPlayer();
          try {
            await player.action.openFile(sampleWavFile.path);
            await player.action.play();

            // Rapid burst of 50 mixed DSP setters
            for (int i = 0; i < 50; i++) {
              await player.action.setVolume(0.5 + (i % 10) * 0.05);
              await player.action.setRate(0.8 + (i % 10) * 0.05);
              await player.action.setPitch(0.9 + (i % 10) * 0.05);
              await player.action.setBalance(((i % 10) - 5) / 10.0);
              await player.action.setPreamp((i % 5).toDouble());
            }

            expect(tracker.totalPeriodicCreated, equals(0));
            await player.action.stop();
          } finally {
            await player.dispose();
          }
          expect(tracker.totalPeriodicCreated, equals(0));
        }, description: 'rapid DSP bursts');
      },
    );

    test('1.5: Audio device switching creates 0 periodic timers', () async {
      await runWithZeroPeriodicTimerProof((tracker) async {
        final player = MiniaudioPlayer();
        try {
          await player.action.openFile(sampleWavFile.path);

          // Switch to Auto
          await player.action.setDevice(AudioDevice.auto);
          expect(tracker.totalPeriodicCreated, equals(0));

          // Switch to available physical devices if present
          final devices = await MiniaudioPlayer.getAudioDevices();
          for (final dev in devices) {
            await player.action.setDevice(dev);
            expect(tracker.totalPeriodicCreated, equals(0));
          }

          // Switch back to Auto
          await player.action.setDevice(AudioDevice.auto);
          expect(tracker.totalPeriodicCreated, equals(0));
        } finally {
          await player.dispose();
        }
        expect(tracker.totalPeriodicCreated, equals(0));
      }, description: 'device switching');
    });

    test(
      '1.6: Natural track completion to EOF creates 0 periodic timers',
      () async {
        await runWithZeroPeriodicTimerProof((tracker) async {
          final player = MiniaudioPlayer();
          try {
            await player.action.openFile(shortWavFile.path); // 500ms duration
            await player.action.play();

            int elapsed = 0;
            while (!player.state.completed && elapsed < 1500) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              elapsed += 50;
            }

            expect(player.state.completed, isTrue);
            expect(player.state.playbackState, equals(PlaybackState.completed));
            expect(tracker.totalPeriodicCreated, equals(0));
          } finally {
            await player.dispose();
          }
          expect(tracker.totalPeriodicCreated, equals(0));
        }, description: 'natural track completion to EOF');
      },
    );

    test(
      '1.7: Positive control: ZoneTimerTracker catches Timer.periodic if introduced',
      () async {
        final tracker = ZoneTimerTracker();
        Timer? periodicTimer;

        runZoned(() {
          periodicTimer = Timer.periodic(
            const Duration(milliseconds: 50),
            (_) {},
          );
        }, zoneSpecification: tracker.zoneSpecification);

        expect(tracker.totalPeriodicCreated, equals(1));
        expect(tracker.activePeriodicCount, equals(1));
        periodicTimer?.cancel();
        expect(tracker.activePeriodicCount, equals(0));
      },
    );
  });

  // ===========================================================================
  // GROUP 2: State Lifecycle Transitions & Stream Integrity
  // ===========================================================================
  group('Group 2: State Lifecycle Transitions & Stream Integrity', () {
    test(
      '2.1: Exhaustive state transition matrix across all PlaybackStates',
      () async {
        final player = MiniaudioPlayer();
        final observedStates = <PlaybackState>[];
        final sub = player.stream.playbackState.listen(observedStates.add);

        try {
          // 1. Initial idle/stopped baseline
          expect(player.state.playbackState, equals(PlaybackState.stopped));
          expect(player.state.playing, isFalse);
          expect(player.state.opening, isFalse);
          expect(player.state.completed, isFalse);

          // 2. stopped -> opening -> stopped
          final openFut = player.action.openFile(sampleWavFile.path);
          expect(player.state.opening, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.opening));
          await openFut;
          expect(player.state.opening, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.stopped));

          // 3. stopped -> playing
          await player.action.play();
          expect(player.state.playing, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.playing));

          // 4. playing -> paused
          await player.action.pause();
          expect(player.state.playing, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.paused));

          // 5. paused -> playing
          await player.action.play();
          expect(player.state.playing, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.playing));

          // 6. playing -> completed (via seek to duration)
          await player.action.seek(player.state.duration);
          expect(player.state.completed, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.completed));

          // 7. completed -> stopped
          await player.action.stop();
          expect(player.state.completed, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.stopped));
          expect(player.state.position, equals(Duration.zero));

          // 8. stopped -> opening -> error
          expect(
            () => player.action.openFile('/tmp/invalid_ghost_file_987654.wav'),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.playbackState, equals(PlaybackState.error));

          // Check stream sequence contains expected transitions
          expect(observedStates, contains(PlaybackState.opening));
          expect(observedStates, contains(PlaybackState.stopped));
          expect(observedStates, contains(PlaybackState.playing));
          expect(observedStates, contains(PlaybackState.paused));
          expect(observedStates, contains(PlaybackState.completed));
          expect(observedStates, contains(PlaybackState.error));
        } finally {
          await sub.cancel();
          await player.dispose();
        }
      },
    );

    test(
      '2.2: Rapid sequential lifecycle loop (open -> play -> pause -> seek -> stop -> open -> dispose) x 25',
      () async {
        for (int i = 0; i < 25; i++) {
          final player = MiniaudioPlayer();
          try {
            await player.action.openFile(sampleWavFile.path);
            expect(player.state.playbackState, equals(PlaybackState.stopped));

            await player.action.play();
            expect(player.state.playing, isTrue);

            await player.action.pause();
            expect(player.state.playing, isFalse);

            await player.action.seek(const Duration(milliseconds: 300));
            expect(player.state.position.inMilliseconds, equals(300));

            await player.action.stop();
            expect(player.state.playbackState, equals(PlaybackState.stopped));
            expect(player.state.position, equals(Duration.zero));

            // Re-open different file
            await player.action.openFile(shortWavFile.path);
            expect(player.state.playbackState, equals(PlaybackState.stopped));
          } finally {
            await player.dispose();
            expect(player.isDisposed, isTrue);
          }
        }
      },
    );

    test(
      '2.3: Natural EOF completion triggers MAP_EVENT_IS_COMPLETED & MAP_EVENT_STATE without polling',
      () async {
        final player = MiniaudioPlayer();
        final states = <PlaybackState>[];
        final completes = <bool>[];
        final playings = <bool>[];

        final s1 = player.stream.playbackState.listen(states.add);
        final s2 = player.stream.completed.listen(completes.add);
        final s3 = player.stream.playing.listen(playings.add);

        try {
          await player.action.openFile(shortWavFile.path); // 500ms duration
          await player.action.play();

          // Wait for natural EOF (up to 1500ms)
          int elapsed = 0;
          while (!player.state.completed && elapsed < 1500) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            elapsed += 50;
          }

          expect(player.state.completed, isTrue);
          expect(player.state.playing, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.completed));
          expect(
            player.state.position.inMilliseconds,
            equals(player.state.duration.inMilliseconds),
          );

          expect(completes, contains(true));
          expect(states, contains(PlaybackState.completed));
          expect(playings.last, isFalse);
        } finally {
          await s1.cancel();
          await s2.cancel();
          await s3.cancel();
          await player.dispose();
        }
      },
    );

    test(
      '2.4: Seek-induced completion and reversible transition from completed to paused',
      () async {
        final player = MiniaudioPlayer();
        final states = <PlaybackState>[];
        final completes = <bool>[];
        final sub1 = player.stream.playbackState.listen(states.add);
        final sub2 = player.stream.completed.listen(completes.add);

        try {
          await player.action.openFile(sampleWavFile.path); // 3.0s duration
          final duration = player.state.duration;

          // Seek to exact duration -> completion
          await player.action.seek(duration);
          expect(player.state.completed, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.completed));
          expect(completes.last, isTrue);

          // Seek backward into audio body -> reversibly transitions to paused
          await player.action.seek(const Duration(milliseconds: 1500));
          expect(player.state.completed, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.paused));
          expect(player.state.position.inMilliseconds, equals(1500));
          expect(completes.last, isFalse);

          // Resume from paused
          await player.action.play();
          expect(player.state.playing, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.playing));
        } finally {
          await sub1.cancel();
          await sub2.cancel();
          await player.dispose();
        }
      },
    );

    test(
      '2.5: Re-entrant unawaited lifecycle dispatches resolve cleanly',
      () async {
        final player = MiniaudioPlayer();
        try {
          final openFut = player.action.openFile(sampleWavFile.path);
          // Concurrently fire transport commands without awaiting
          final playFut = player.action.play();
          final seekFut = player.action.seek(
            const Duration(milliseconds: 500),
          );
          final pauseFut = player.action.pause();

          await Future.wait([openFut, playFut, seekFut, pauseFut]);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          // pause() issued while opening cancels the deferred play() intent
          // (last intent wins). A source that was opened but never started
          // reports `stopped`, and the queued seek is still applied.
          expect(player.state.playing, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.stopped));
          expect(player.state.position.inMilliseconds, equals(500));
        } finally {
          await player.dispose();
        }
      },
    );

    test('2.6: Zero stale events delivered after stop and dispose', () async {
      final player = MiniaudioPlayer();
      final stateEvents = <PlaybackState>[];
      final positionEvents = <Duration>[];
      final subState = player.stream.playbackState.listen(stateEvents.add);
      final subPos = player.stream.position.listen(positionEvents.add);

      try {
        await player.action.openFile(sampleWavFile.path);
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        await player.action.stop();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final stateCountAtStop = stateEvents.length;
        final posCountAtStop = positionEvents.length;

        await player.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(stateEvents.length, equals(stateCountAtStop));
        expect(positionEvents.length, equals(posCountAtStop));
      } finally {
        await subState.cancel();
        await subPos.cancel();
      }
    });
  });

  // ===========================================================================
  // GROUP 3: State Recovery, Error Handling & Replay
  // ===========================================================================
  group('Group 3: State Recovery, Error Handling & Replay', () {
    test(
      '3.1: Non-existent file error and recovery via valid file open',
      () async {
        final player = MiniaudioPlayer();
        try {
          expect(
            () => player.action.openFile('/non_existent_audio_path_xyz_123.wav'),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(player.state.playbackState, equals(PlaybackState.error));

          // Recovery: open valid file
          await player.action.openFile(sampleWavFile.path);
          expect(player.state.playbackState, equals(PlaybackState.stopped));
          expect(player.state.duration.inMilliseconds, greaterThan(0));

          // Verify normal playback resumes
          await player.action.play();
          expect(player.state.playbackState, equals(PlaybackState.playing));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.position.inMilliseconds, greaterThan(0));

          await player.action.stop();
          expect(player.state.playbackState, equals(PlaybackState.stopped));
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      '3.2: Corrupted audio file recovery (0-byte file, truncated header, random junk)',
      () async {
        final player = MiniaudioPlayer();
        try {
          // 1. Zero-byte file
          expect(
            () => player.action.openFile(emptyWavFile.path),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(player.state.playbackState, equals(PlaybackState.error));

          // Recovery via openMemory
          await player.action.openMemory(memoryWavBytes);
          expect(player.state.playbackState, equals(PlaybackState.stopped));

          // 2. Truncated header file
          expect(
            () => player.action.openFile(truncatedHeaderFile.path),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(player.state.playbackState, equals(PlaybackState.error));

          // Recovery via openFile
          await player.action.openFile(sampleWavFile.path);
          expect(player.state.playbackState, equals(PlaybackState.stopped));

          // 3. Random junk file
          expect(
            () => player.action.openFile(corruptJunkFile.path),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(player.state.playbackState, equals(PlaybackState.error));

          // Recovery via valid file
          await player.action.openFile(sampleWavFile.path);
          expect(player.state.playbackState, equals(PlaybackState.stopped));

          // Play recovered track
          await player.action.play();
          expect(player.state.playing, isTrue);
          await player.action.stop();
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      '3.3: Boundary rejection and error safety (empty path, uninitialized seek)',
      () async {
        final player = MiniaudioPlayer();
        try {
          // Empty path fast rejection
          expect(
            () => player.action.openFile(''),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          expect(player.state.playbackState, equals(PlaybackState.stopped));

          // Seek on uninitialized player
          expect(
            () => player.action.seek(const Duration(seconds: 1)),
            throwsA(isA<MiniaudioPlayerException>()),
          );
          expect(player.state.playbackState, equals(PlaybackState.stopped));

          // Open valid file
          await player.action.openFile(sampleWavFile.path);
          expect(player.state.playbackState, equals(PlaybackState.stopped));
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      '3.4: Cascading sequential errors and repeated recovery loop (5 cycles)',
      () async {
        final player = MiniaudioPlayer();
        try {
          for (int i = 0; i < 5; i++) {
            // Trigger error
            await expectLater(
              player.action.openFile('/tmp/ghost_file_$i.wav'),
              throwsA(isA<MiniaudioPlayerException>()),
            );
            expect(player.state.playbackState, equals(PlaybackState.error));

            // Recover
            await player.action.openMemory(memoryWavBytes);
            expect(player.state.playbackState, equals(PlaybackState.stopped));

            // Short play & stop
            await player.action.play();
            expect(player.state.playing, isTrue);
            await player.action.stop();
            expect(player.state.playbackState, equals(PlaybackState.stopped));
          }
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      '3.5: Replay after EOF from in-memory audio (openMemory -> EOF -> play())',
      () async {
        final player = MiniaudioPlayer();
        try {
          await player.action.openMemory(memoryWavBytes); // 600ms duration
          await player.action.play();

          int elapsed = 0;
          while (!player.state.completed && elapsed < 1500) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            elapsed += 50;
          }
          expect(player.state.completed, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.completed));

          // Instant replay
          await player.action.play();
          expect(player.state.completed, isFalse);
          expect(player.state.playing, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.playing));

          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.position.inMilliseconds, greaterThan(0));
          expect(player.state.position.inMilliseconds, lessThan(500));

          await player.action.stop();
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      '3.6: Replay after EOF from local file (openFile -> EOF -> play())',
      () async {
        final player = MiniaudioPlayer();
        try {
          await player.action.openFile(sampleWavFile.path); // 3.0s duration
          // Seek near end to trigger EOF quickly
          await player.action.seek(const Duration(milliseconds: 2950));
          await player.action.play();

          int elapsed = 0;
          while (!player.state.completed && elapsed < 1200) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            elapsed += 50;
          }
          expect(player.state.completed, isTrue);

          // Replay
          await player.action.play();
          expect(player.state.completed, isFalse);
          expect(player.state.playing, isTrue);
          expect(player.state.playbackState, equals(PlaybackState.playing));

          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.position.inMilliseconds, lessThan(400));

          await player.action.stop();
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      '3.7: Track substitution after EOF (open Track A -> EOF -> open Track B -> play)',
      () async {
        final player = MiniaudioPlayer();
        try {
          await player.action.openMemory(memoryWavBytes);
          await player.action.seek(player.state.duration);
          expect(player.state.completed, isTrue);

          // Open new file instead of replaying
          await player.action.openFile(sampleWavFile.path);
          expect(player.state.completed, isFalse);
          expect(player.state.playbackState, equals(PlaybackState.stopped));
          expect(player.state.position, equals(Duration.zero));
          expect(player.state.duration.inMilliseconds, closeTo(3000, 200));

          await player.action.play();
          expect(player.state.playing, isTrue);
          await player.action.stop();
        } finally {
          await player.dispose();
        }
      },
    );
  });

  // ===========================================================================
  // GROUP 4: Empirical Value Deduplication & Redundancy Elimination
  // ===========================================================================
  group('Group 4: Empirical Value Deduplication & Redundancy Elimination', () {
    late MiniaudioPlayer player;

    setUp(() async {
      player = MiniaudioPlayer();
      await player.action.openFile(sampleWavFile.path);
    });

    tearDown(() async {
      await player.dispose();
    });

    test(
      '4.1: Scalar setters deduplication (volume, rate, pitch, balance, preamp, buffer size)',
      () async {
        // --- Volume ---
        final volEvents = <double>[];
        final volSub = player.stream.volume.listen(volEvents.add);
        for (int i = 0; i < 8; i++) {
          await player.action.setVolume(0.72);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          volEvents.length,
          equals(1),
          reason: 'Volume stream must emit exactly 1 event for identical calls',
        );
        expect(volEvents.first, closeTo(0.72, 0.001));
        expect(player.state.volume, closeTo(0.72, 0.001));
        await volSub.cancel();

        // --- Rate ---
        final rateEvents = <double>[];
        final rateSub = player.stream.rate.listen(rateEvents.add);
        for (int i = 0; i < 8; i++) {
          await player.action.setRate(1.35);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(rateEvents.length, equals(1));
        expect(rateEvents.first, closeTo(1.35, 0.001));
        expect(player.state.rate, closeTo(1.35, 0.001));
        await rateSub.cancel();

        // --- Pitch ---
        final pitchEvents = <double>[];
        final pitchSub = player.stream.pitch.listen(pitchEvents.add);
        for (int i = 0; i < 8; i++) {
          await player.action.setPitch(0.85);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(pitchEvents.length, equals(1));
        expect(pitchEvents.first, closeTo(0.85, 0.001));
        expect(player.state.pitch, closeTo(0.85, 0.001));
        await pitchSub.cancel();

        // --- Balance ---
        final balEvents = <double>[];
        final balSub = player.stream.balance.listen(balEvents.add);
        for (int i = 0; i < 8; i++) {
          await player.action.setBalance(-0.45);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(balEvents.length, equals(1));
        expect(balEvents.first, closeTo(-0.45, 0.001));
        expect(player.state.balance, closeTo(-0.45, 0.001));
        await balSub.cancel();

        // --- Preamp ---
        final preampEvents = <double>[];
        final preampSub = player.stream.preamp.listen(preampEvents.add);
        for (int i = 0; i < 8; i++) {
          await player.action.setPreamp(2.5);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(preampEvents.length, equals(1));
        expect(preampEvents.first, closeTo(2.5, 0.001));
        expect(player.state.preamp, closeTo(2.5, 0.001));
        await preampSub.cancel();

        // --- Buffer Size ---
        final bufEvents = <int>[];
        final bufSub = player.stream.bufferSize.listen(bufEvents.add);
        for (int i = 0; i < 8; i++) {
          await player.action.setBufferSize(512);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bufEvents.length, equals(1));
        expect(bufEvents.first, equals(512));
        expect(player.state.bufferSize, equals(512));
        await bufSub.cancel();
      },
    );

    test(
      '4.2: Compound structures deduplication (equalizer, device, silenceConfig)',
      () async {
        // --- Equalizer ---
        final eqEvents = <Equalizer>[];
        final eqSub = player.stream.equalizer.listen(eqEvents.add);
        const customEq = Equalizer(
          hz31: 2.0,
          hz63: 1.5,
          hz125: 1.0,
          hz250: 0.5,
          hz500: 0.0,
          hz1k: -0.5,
          hz2k: -1.0,
          hz4k: -1.5,
          hz8k: -2.0,
          hz16k: -2.5,
        );

        for (int i = 0; i < 8; i++) {
          await player.action.setEqualizer(customEq);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          eqEvents.length,
          equals(1),
          reason: 'Equalizer must emit exactly 1 event for identical settings',
        );
        expect(eqEvents.first.hz31, closeTo(2.0, 0.01));
        expect(eqEvents.first.hz16k, closeTo(-2.5, 0.01));
        await eqSub.cancel();

        // --- AudioDevice ---
        expect(player.state.audioDevice.isAuto, isTrue,
            reason: 'Player starts on the auto device');
        final devEvents = <AudioDevice>[];
        final devSub = player.stream.audioDevice.listen(devEvents.add);

        for (int i = 0; i < 8; i++) {
          await player.action.setDevice(AudioDevice.auto);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          devEvents.length,
          lessThanOrEqualTo(1),
          reason:
              'Repeated setDevice(AudioDevice.auto) on an already-auto player '
              'must not flood the stream (at most one resolution update)',
        );
        expect(player.state.audioDevice.isAuto, isTrue);
        await devSub.cancel();

        // --- SilenceConfig ---
        final scEvents = <SilenceSkipConfig>[];
        final scSub = player.stream.silenceConfig.listen(scEvents.add);
        const testConfig = SilenceSkipConfig(
          mode: SilenceSkipMode.continuous,
          thresholdDb: -38.0,
          minSilenceDuration: Duration(milliseconds: 400),
          padding: Duration(milliseconds: 60),
        );

        for (int i = 0; i < 8; i++) {
          await player.action.setSilenceConfig(testConfig);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          scEvents.length,
          equals(1),
          reason:
              'SilenceSkipConfig must emit exactly 1 event for identical configurations',
        );
        expect(scEvents.first.thresholdDb, closeTo(-38.0, 0.1));
        await scSub.cancel();
      },
    );

    test(
      '4.3: Sub-threshold epsilon noise rejection (< 1e-4) vs supra-threshold updates (>= 1e-4)',
      () async {
        final volumeEvents = <double>[];
        final volSub = player.stream.volume.listen(volumeEvents.add);

        // Base value
        await player.action.setVolume(0.500000);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(volumeEvents.length, equals(1));

        // Jitter delta < 1e-4 (e.g. 0.00003 difference): C fabsf(delta) < 1e-4 -> REJECTED
        await player.action.setVolume(0.500030);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          volumeEvents.length,
          equals(1),
          reason:
              'Sub-threshold noise delta (< 1e-4) must be deduplicated in C',
        );

        // Meaningful delta >= 1e-4 (e.g. 0.005 difference): C fabsf(delta) >= 1e-4 -> EMITTED
        await player.action.setVolume(0.505000);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          volumeEvents.length,
          equals(2),
          reason:
              'Supra-threshold delta (>= 1e-4) must trigger event confirmation',
        );
        expect(volumeEvents.last, closeTo(0.505, 0.0001));
        await volSub.cancel();
      },
    );

    test(
      '4.4: Alternating sequence deduplication (A -> B -> A -> B -> B -> B)',
      () async {
        final monoEvents = <bool>[];
        final monoSub = player.stream.mono.listen(monoEvents.add);

        // Sequence: true, false, true, false, false, false
        await player.action.setMono(true); // Event 1
        await player.action.setMono(false); // Event 2
        await player.action.setMono(true); // Event 3
        await player.action.setMono(false); // Event 4
        await player.action.setMono(false); // Deduplicated (0)
        await player.action.setMono(false); // Deduplicated (0)

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          monoEvents,
          equals([true, false, true, false]),
          reason:
              'Stream must receive exactly 4 transitions and suppress redundant calls',
        );
        expect(player.state.mono, isFalse);
        await monoSub.cancel();
      },
    );
  });

  // ===========================================================================
  // GROUP 5: Telemetry Rate Limiting & FFI Bridge Flood Prevention
  // ===========================================================================
  group('Group 5: Telemetry Rate Limiting & FFI Bridge Flood Prevention', () {
    late MiniaudioPlayer player;

    setUp(() async {
      player = MiniaudioPlayer();
      await player.action.openFile(sampleWavFile.path);
    });

    tearDown(() async {
      await player.dispose();
    });

    test(
      '5.1: Position telemetry rate limiting (~30 Hz during 1.0s active playback, <= 42 events)',
      () async {
        final positionEvents = <Duration>[];
        final arrivalTimestamps = <DateTime>[];
        final posSub = player.stream.position.listen((pos) {
          positionEvents.add(pos);
          arrivalTimestamps.add(DateTime.now());
        });

        await player.action.play();
        // Allow playback to proceed for exactly 1000 milliseconds
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        await player.action.pause();

        expect(
          positionEvents,
          isNotEmpty,
          reason: 'Position telemetry must be active during playback',
        );

        // With ~33ms interval, theoretical count over 1000ms is ~30 events.
        // Expected throttled range: 20 to 42 events.
        expect(
          positionEvents.length,
          inInclusiveRange(20, 42),
          reason:
              'Position events must be throttled to ~30 Hz (actual: ${positionEvents.length})',
        );

        // Verify Monotonic Advancement:
        for (int i = 1; i < positionEvents.length; i++) {
          expect(
            positionEvents[i].inMilliseconds,
            greaterThanOrEqualTo(positionEvents[i - 1].inMilliseconds),
            reason: 'Position events must advance monotonically',
          );
        }

        // Inter-event arrival intervals (Delta t):
        final deltasMs = <int>[];
        for (int i = 1; i < arrivalTimestamps.length; i++) {
          deltasMs.add(
            arrivalTimestamps[i]
                .difference(arrivalTimestamps[i - 1])
                .inMilliseconds,
          );
        }
        final avgDeltaMs = deltasMs.reduce((a, b) => a + b) / deltasMs.length;
        expect(
          avgDeltaMs,
          inInclusiveRange(20.0, 50.0),
          reason:
              'Average telemetry arrival interval must center near ~33ms (actual: ${avgDeltaMs.toStringAsFixed(1)}ms)',
        );

        await posSub.cancel();
      },
    );

    test(
      '5.2: Visualizer telemetry rate limiting (~30 Hz, valid FFT data)',
      () async {
        final visualizerEvents = <VisualizerData>[];
        final visSub = player.stream.visualizer.listen(visualizerEvents.add);

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        await player.action.pause();

        expect(visualizerEvents, isNotEmpty);
        expect(
          visualizerEvents.length,
          inInclusiveRange(20, 42),
          reason:
              'Visualizer events must be throttled to ~30 FPS without flooding the bridge',
        );

        for (final frame in visualizerEvents) {
          expect(frame.bands.length, equals(10));
          expect(frame.rms.isFinite, isTrue);
          expect(frame.peak.isFinite, isTrue);
        }

        await visSub.cancel();
      },
    );

    test(
      '5.3: Compound telemetry flood prevention (position + visualizer simultaneous <= 85 total events)',
      () async {
        int totalTelemetryEvents = 0;
        final s1 = player.stream.position.listen(
          (_) => totalTelemetryEvents++,
        );
        final s2 = player.stream.visualizer.listen(
          (_) => totalTelemetryEvents++,
        );

        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        await player.action.pause();

        // If unthrottled, position (~150) + visualizer (~150) = 300+ events.
        // Throttled: ~30 position + ~30 visualizer = ~60 events.
        expect(
          totalTelemetryEvents,
          lessThanOrEqualTo(85),
          reason:
              'Total combined telemetry events must be strictly capped by rate limiting',
        );
        expect(totalTelemetryEvents, greaterThanOrEqualTo(40));

        await s1.cancel();
        await s2.cancel();
      },
    );

    test(
      '5.4: Telemetry inactivity suppression (paused and stopped emit 0 events, 0% CPU)',
      () async {
        int eventsWhilePaused = 0;
        final s1 = player.stream.position.listen(
          (_) => eventsWhilePaused++,
        );
        final s2 = player.stream.visualizer.listen(
          (_) => eventsWhilePaused++,
        );

        // Play briefly to start, then pause
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await player.action.pause();

        // Reset counter after settling
        await Future<void>.delayed(const Duration(milliseconds: 60));
        eventsWhilePaused = 0;

        // Wait 600ms while paused
        await Future<void>.delayed(const Duration(milliseconds: 600));

        expect(
          eventsWhilePaused,
          equals(0),
          reason:
              'Paused state must emit zero telemetry events; worker must sleep at 0% CPU',
        );

        // Stop player and verify stopped inactivity suppression
        await player.action.stop();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        int eventsWhileStopped = 0;
        final s3 = player.stream.position.listen(
          (_) => eventsWhileStopped++,
        );
        final s4 = player.stream.visualizer.listen(
          (_) => eventsWhileStopped++,
        );

        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          eventsWhileStopped,
          equals(0),
          reason: 'Stopped state must emit zero telemetry events',
        );

        await s1.cancel();
        await s2.cancel();
        await s3.cancel();
        await s4.cancel();
      },
    );
  });

  // ===========================================================================
  // GROUP 6: High-Frequency Parameter Mutations & Concurrency Stress
  // ===========================================================================
  group(
    'Group 6: High-Frequency Parameter Mutations & Concurrency Stress',
    () {
      late MiniaudioPlayer player;

      setUp(() async {
        player = MiniaudioPlayer();
        await player.action.openFile(sampleWavFile.path);
      });

      tearDown(() async {
        await player.dispose();
      });

      test(
        '6.1: 500 rapid sequential setter mutations in loop (no dropped final state, < 3s)',
        () async {
          await player.action.play();

          final volumeEvents = <double>[];
          final volSub = player.stream.volume.listen(volumeEvents.add);

          final stopwatch = Stopwatch()..start();

          // Execute 500 sequential mutations across a gradient of values
          for (int i = 1; i <= 500; i++) {
            final v =
                (i % 50) /
                25.0; // Cycles from 0.04 to 1.96, ending at 500 % 50 = 0 -> 0.0
            await player.action.setVolume(v);
          }

          stopwatch.stop();

          // Assert execution time is bounded (< 3.0 seconds for 500 FFI dispatches)
          expect(
            stopwatch.elapsedMilliseconds,
            lessThan(3000),
            reason:
                '500 sequential FFI mutations must execute quickly without lock contention',
          );

          // Allow isolate event loop to flush any final pending microtasks
          await Future<void>.delayed(const Duration(milliseconds: 60));

          // Verify Final State Convergence:
          expect(
            player.state.volume,
            equals(0.0),
            reason:
                'player.state.volume must strictly converge to the 500th mutation value',
          );
          expect(
            volumeEvents.last,
            equals(0.0),
            reason:
                'The last stream event emitted must match the final mutation value',
          );

          await player.action.stop();
          await volSub.cancel();
        },
        timeout: const Timeout(Duration(seconds: 10)),
      );

      test(
        '6.2: 500 concurrent unawaited setter mutations via Future.wait (no deadlocks, no NaN corruption)',
        () async {
          final futures = <Future<void>>[];
          for (int i = 1; i <= 500; i++) {
            final targetPitch = 0.5 + ((i % 30) * 0.05); // Range [0.5, 1.95]
            futures.add(player.action.setPitch(targetPitch));
          }

          // All 500 enter the C layer concurrently
          await Future.wait(futures);
          await Future<void>.delayed(const Duration(milliseconds: 80));

          // Assert memory integrity: no NaNs, no infinities, valid range
          expect(player.state.pitch.isNaN, isFalse);
          expect(player.state.pitch.isInfinite, isFalse);
          expect(player.state.pitch, inInclusiveRange(0.5, 2.0));
        },
        timeout: const Timeout(Duration(seconds: 10)),
      );

      test(
        '6.3: 500 heterogeneous mixed parameter mutations mid-playback while audio thread renders',
        () async {
          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(player.state.playing, isTrue);

          final futures = <Future<void>>[];

          // 100 Volume mutations
          for (int i = 1; i <= 100; i++) {
            futures.add(player.action.setVolume(0.5 + (i % 20) * 0.05));
          }
          // 100 Rate mutations
          for (int i = 1; i <= 100; i++) {
            futures.add(player.action.setRate(0.8 + (i % 15) * 0.08));
          }
          // 100 Pitch mutations
          for (int i = 1; i <= 100; i++) {
            futures.add(player.action.setPitch(0.7 + (i % 15) * 0.08));
          }
          // 100 Balance mutations
          for (int i = 1; i <= 100; i++) {
            futures.add(player.action.setBalance(((i % 20) - 10) / 10.0));
          }
          // 100 Preamp mutations
          for (int i = 1; i <= 100; i++) {
            futures.add(player.action.setPreamp((i % 10).toDouble()));
          }

          // Dispatch all 500 mutations concurrently while audio thread is actively pulling frames
          await Future.wait(futures);
          await Future<void>.delayed(const Duration(milliseconds: 150));

          // Invariant verification:
          expect(
            player.state.playing,
            isTrue,
            reason:
                'Audio thread must not crash or stall during intense DSP mutation stress',
          );
          expect(player.state.volume.isFinite, isTrue);
          expect(player.state.rate.isFinite, isTrue);
          expect(player.state.pitch.isFinite, isTrue);
          expect(player.state.balance.isFinite, isTrue);
          expect(player.state.preamp.isFinite, isTrue);

          await player.action.stop();
          expect(player.state.playing, isFalse);
        },
        timeout: const Timeout(Duration(seconds: 12)),
      );

      test(
        '6.4: 128-slot ring buffer circular wrap-around resilience (> 3.9x capacity, 500 events, 0 corruption)',
        () async {
          final receivedVolumeEvents = <double>[];
          final volSub = player.stream.volume.listen(
            receivedVolumeEvents.add,
          );

          // Submit 500 distinct sequential volume values (exceeds MAP_EVENT_RING_CAPACITY = 128)
          for (int i = 1; i <= 500; i++) {
            final distinctVol = i / 1000.0;
            await player.action.setVolume(distinctVol);
          }

          await Future<void>.delayed(const Duration(milliseconds: 100));

          expect(
            receivedVolumeEvents.length,
            equals(500),
            reason:
                'All 500 distinct events must be received across circular ring buffer wrap-around cycles',
          );
          expect(receivedVolumeEvents.last, closeTo(0.500, 0.0001));
          expect(player.state.volume, closeTo(0.500, 0.0001));
          await volSub.cancel();
        },
        timeout: const Timeout(Duration(seconds: 10)),
      );
    },
  );

  // ===========================================================================
  // GROUP 7: 100% Backward Compatibility & Contract Verification
  // ===========================================================================
  group('Group 7: 100% Backward Compatibility & Contract Verification', () {
    late MiniaudioPlayer player;

    setUp(() => player = MiniaudioPlayer());
    tearDown(() async => await player.dispose());

    test('7.1: All 33 streams on PlayerStream are broadcast streams', () {
      final streams = <String, Stream<dynamic>>{
        'position': player.stream.position,
        'duration': player.stream.duration,
        'playing': player.stream.playing,
        'buffering': player.stream.buffering,
        'completed': player.stream.completed,
        'opening': player.stream.opening,
        'playbackState': player.stream.playbackState,
        'bufferedPosition': player.stream.bufferedPosition,
        'bufferedPercentage': player.stream.bufferedPercentage,
        'bufferedRange': player.stream.bufferedRange,
        'trackMetadata': player.stream.trackMetadata,
        'volume': player.stream.volume,
        'rate': player.stream.rate,
        'pitch': player.stream.pitch,
        'bufferSize': player.stream.bufferSize,
        'audioBitrate': player.stream.audioBitrate,
        'bitrate': player.stream.bitrate,
        'equalizer': player.stream.equalizer,
        'audioDevice': player.stream.audioDevice,
        'skipSilence': player.stream.skipSilence,
        'silenceConfig': player.stream.silenceConfig,
        'silenceSavedDuration': player.stream.silenceSavedDuration,
        'visualizer': player.stream.visualizer,
        'visualizerEnabled': player.stream.visualizerEnabled,
        'preamp': player.stream.preamp,
        'replayGain': player.stream.replayGain,
        'balance': player.stream.balance,
        'mono': player.stream.mono,
        'crossfeed': player.stream.crossfeed,
        'spatializerEnabled': player.stream.spatializerEnabled,
        'spatializerWidth': player.stream.spatializerWidth,
        'reverb': player.stream.reverb,
        'limiterEnabled': player.stream.limiterEnabled,
      };

      expect(streams.length, equals(33));

      for (final entry in streams.entries) {
        expect(
          entry.value.isBroadcast,
          isTrue,
          reason: 'player.stream.${entry.key} must be a broadcast stream',
        );
        // Verify multiple simultaneous subscribers
        final sub1 = entry.value.listen((_) {});
        final sub2 = entry.value.listen((_) {});
        sub1.cancel();
        sub2.cancel();
      }
    });

    test(
      '7.2: All 36 getters on PlayerState return valid default snapshots',
      () {
        expect(player.state.position, equals(Duration.zero));
        expect(player.state.duration, equals(Duration.zero));
        expect(player.state.playing, isFalse);
        expect(player.state.buffering, isFalse);
        expect(player.state.completed, isFalse);
        expect(player.state.opening, isFalse);
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.bufferedPosition, equals(Duration.zero));
        expect(player.state.bufferedPercentage, equals(0.0));
        expect(player.state.bufferedRange, equals(const BufferedRange()));
        expect(player.state.trackMetadata, isNull);
        expect(player.state.volume, equals(1.0));
        expect(player.state.rate, equals(1.0));
        expect(player.state.pitch, equals(1.0));
        expect(player.state.bufferSize, isZero);
        expect(player.state.audioBitrate, isZero);
        expect(player.state.bitrate, isZero);
        expect(player.state.equalizer, equals(Equalizer.flat));
        expect(player.state.audioDevice.isAuto, isTrue);
        expect(player.state.skipSilence, isFalse);
        expect(player.state.isSkipSilenceEnabled, isFalse);
        expect(
          player.state.silenceSkipMode,
          equals(SilenceSkipMode.disabled),
        );
        expect(
          player.state.silenceConfig,
          equals(const SilenceSkipConfig()),
        );
        expect(player.state.silenceSavedDuration, equals(Duration.zero));
        expect(player.state.visualizer, equals(VisualizerData.empty()));
        expect(player.state.visualizerEnabled, isFalse);
        expect(player.state.preamp, equals(0.0));
        expect(player.state.preampDb, equals(0.0));
        expect(
          player.state.replayGain,
          equals(const ReplayGainConfig()),
        );
        expect(player.state.balance, equals(0.0));
        expect(player.state.mono, isFalse);
        expect(player.state.crossfeed, equals(CrossfeedMode.off));
        expect(player.state.spatializerEnabled, isFalse);
        expect(player.state.spatializerWidth, equals(1.0));
        expect(player.state.reverb, equals(Reverb.off));
        expect(player.state.limiterEnabled, isTrue);
      },
    );

    test(
      '7.3: All convenience aliases maintain identical values to canonical counterparts',
      () {
        expect(player.state.bitrate, equals(player.state.audioBitrate));
        expect(
          player.state.isSkipSilenceEnabled,
          equals(player.state.skipSilence),
        );
        expect(
          player.state.silenceSkipMode,
          equals(player.state.silenceConfig.mode),
        );
        expect(player.state.preampDb, equals(player.state.preamp));
      },
    );

    test(
      '7.4: Post-disposal synchronous access to all 36 state getters is memory-safe',
      () async {
        final tempPlayer = MiniaudioPlayer();
        await tempPlayer.action.openFile(sampleWavFile.path);
        await tempPlayer.dispose();
        expect(tempPlayer.isDisposed, isTrue);

        // Accessing all 36 state properties on disposed player must be completely safe
        expect(tempPlayer.state.position, isNotNull);
        expect(tempPlayer.state.duration, isNotNull);
        expect(tempPlayer.state.playing, isFalse);
        expect(tempPlayer.state.buffering, isFalse);
        expect(tempPlayer.state.completed, isNotNull);
        expect(tempPlayer.state.opening, isFalse);
        expect(tempPlayer.state.playbackState, isNotNull);
        expect(tempPlayer.state.bufferedPosition, isNotNull);
        expect(tempPlayer.state.bufferedPercentage, isNotNull);
        expect(tempPlayer.state.bufferedRange, isNotNull);
        expect(() => tempPlayer.state.trackMetadata, returnsNormally);
        expect(tempPlayer.state.volume, isNotNull);
        expect(tempPlayer.state.rate, isNotNull);
        expect(tempPlayer.state.pitch, isNotNull);
        expect(tempPlayer.state.bufferSize, isNotNull);
        expect(tempPlayer.state.audioBitrate, isNotNull);
        expect(tempPlayer.state.bitrate, isNotNull);
        expect(tempPlayer.state.equalizer, isNotNull);
        expect(tempPlayer.state.audioDevice, isNotNull);
        expect(tempPlayer.state.skipSilence, isNotNull);
        expect(tempPlayer.state.isSkipSilenceEnabled, isNotNull);
        expect(tempPlayer.state.silenceSkipMode, isNotNull);
        expect(tempPlayer.state.silenceConfig, isNotNull);
        expect(tempPlayer.state.silenceSavedDuration, isNotNull);
        expect(tempPlayer.state.visualizer, isNotNull);
        expect(tempPlayer.state.visualizerEnabled, isNotNull);
        expect(tempPlayer.state.preamp, isNotNull);
        expect(tempPlayer.state.preampDb, isNotNull);
        expect(tempPlayer.state.replayGain, isNotNull);
        expect(tempPlayer.state.balance, isNotNull);
        expect(tempPlayer.state.mono, isNotNull);
        expect(tempPlayer.state.crossfeed, isNotNull);
        expect(tempPlayer.state.spatializerEnabled, isNotNull);
        expect(tempPlayer.state.spatializerWidth, isNotNull);
        expect(tempPlayer.state.reverb, isNotNull);
        expect(tempPlayer.state.limiterEnabled, isNotNull);
      },
    );

    test(
      '7.5: setDevice returns Future<void> statically and at runtime, and updates stream/state upon C event',
      () async {
        // 1. Static compile-time type verification: assignable to Future<void>
        final Future<void> actionFuture = player.action.setDevice(
          AudioDevice.auto,
        );
        expect(actionFuture, isA<Future<void>>());
        await actionFuture;

        // 2. MiniaudioPlayer forwarder also returns Future<void>
        final Future<void> forwarderFuture = player.setDevice(AudioDevice.auto);
        expect(forwarderFuture, isA<Future<void>>());
        await forwarderFuture;

        // 3. Updates stream and state
        final devices = await MiniaudioPlayer.getAudioDevices();
        expect(devices, isNotEmpty);

        final receivedEvents = <AudioDevice>[];
        final sub = player.stream.audioDevice.listen(receivedEvents.add);

        // Ensure auto
        await player.action.setDevice(AudioDevice.auto);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(player.state.audioDevice.isAuto, isTrue);

        // Switch to physical hardware device if available
        final physicalDevices = devices.where((d) => !d.isAuto).toList();
        if (physicalDevices.isNotEmpty) {
          final target = physicalDevices.first;
          await player.action.setDevice(target);
          await Future<void>.delayed(const Duration(milliseconds: 30));

          expect(player.state.audioDevice.isAuto, isFalse);
          expect(player.state.audioDevice.name, isNotEmpty);
          expect(receivedEvents.any((d) => !d.isAuto), isTrue);

          // Revert to auto
          await player.action.setDevice(AudioDevice.auto);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(player.state.audioDevice.isAuto, isTrue);
        }

        // Safe fallback on ghost device
        const invalidDevice = AudioDevice(
          id: 'invalid-ghost-device-xyz-999',
          name: 'Nonexistent Audio Device',
          isAuto: false,
        );
        await player.action.setDevice(invalidDevice);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(player.state.audioDevice.isAuto, isTrue);

        await sub.cancel();
      },
    );

    test(
      '7.6: Purely reactive telemetry updates without polling or periodic timers',
      () async {
        final activePlayer = MiniaudioPlayer();
        try {
          await runWithZeroPeriodicTimerProof((tracker) async {
            await activePlayer.action.openFile(sampleWavFile.path);
            expect(activePlayer.state.duration, greaterThan(Duration.zero));

            await activePlayer.action.play();
            await Future<void>.delayed(const Duration(milliseconds: 150));

            expect(activePlayer.state.position, greaterThan(Duration.zero));
            expect(activePlayer.state.playing, isTrue);

            await activePlayer.action.stop();
            expect(tracker.totalPeriodicCreated, equals(0));
          }, description: 'pure reactive telemetry timer proof');
        } finally {
          await activePlayer.dispose();
        }
      },
    );
  });
}
