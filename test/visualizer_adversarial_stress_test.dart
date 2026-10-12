import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/miniaudio_player_bindings_generated.dart' as native;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('Adversarial Visualizer Stress & Lifecycle Challenge', () {
    late File audioFile;

    setUpAll(() {
      audioFile = resolveAsset('example/assets/music/salida.mp3');
      expect(
        audioFile.existsSync(),
        isTrue,
        reason: 'salida.mp3 test asset must exist for real audio DSP verification',
      );
    });

    // =========================================================================
    // 1. Rapid Toggle Stress During Active Playback
    // =========================================================================
    test(
      'Rapid Toggle Stress: 120 rapid toggles mid-playback without crashes, locks, or corruption',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        final emittedData = <VisualizerData>[];
        final sub = player.stream.visualizer.listen((data) {
          emittedData.add(data);
        });
        addTearDown(() => sub.cancel());

        await player.action.open(audioFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.state.playing, isTrue);

        // Phase 1: 60 sequential toggles mid-playback with no delay
        for (int i = 0; i < 60; i++) {
          final targetState = i.isEven;
          await player.action.setVisualizerEnabled(targetState);

          expect(player.state.visualizerEnabled, equals(targetState));
          final nativeState =
              native.miniaudio_player_is_visualizer_enabled(player.handle);
          expect(nativeState, equals(targetState ? 1 : 0));

          if (!targetState) {
            expect(player.state.visualizer.rms, equals(0.0));
            expect(
              player.state.visualizer.bands.every((b) => b == 0.0),
              isTrue,
            );
          }
        }

        // Phase 2: 60 rapid toggles interleaved with micro-delays (1ms)
        for (int i = 0; i < 60; i++) {
          final targetState = (i % 2 == 1);
          await player.action.setVisualizerEnabled(targetState);
          await Future<void>.delayed(const Duration(milliseconds: 1));

          expect(player.state.visualizerEnabled, equals(targetState));
          final nativeState =
              native.miniaudio_player_is_visualizer_enabled(player.handle);
          expect(nativeState, equals(targetState ? 1 : 0));
        }

        // Allow position timer to tick after rapid toggling settles
        await Future<void>.delayed(const Duration(milliseconds: 60));

        // Playback must not have stalled or crashed
        expect(player.state.playing, isTrue);
        expect(player.state.position.inMilliseconds, greaterThan(0));

        // Final state: force-disable and ensure strict zeroing
        await player.action.setVisualizerEnabled(false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(player.state.visualizerEnabled, isFalse);
        expect(player.state.visualizer.rms, equals(0.0));
        expect(player.state.visualizer.bands.every((b) => b == 0.0), isTrue);
      },
    );

    // =========================================================================
    // 2. Multi-Subscriber Concurrency & Listener Thrashing
    // =========================================================================
    test(
      'Multi-Subscriber Concurrency: 15+ concurrent listeners with dynamic attach/detach and overrides',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        await player.action.open(audioFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        const subscriberCount = 16;
        final subscriptions = <StreamSubscription<VisualizerData>>[];
        final receivedPerSubscriber =
            List.generate(subscriberCount, (_) => <VisualizerData>[]);

        // 1. Attach 16 concurrent visualizer listeners
        for (int s = 0; s < subscriberCount; s++) {
          final index = s;
          subscriptions.add(
            player.stream.visualizer.listen((data) {
              // Strict invariant checks: zero data tearing
              expect(data.bands.length, equals(10));
              for (final band in data.bands) {
                expect(band.isNaN, isFalse);
                expect(band.isInfinite, isFalse);
                expect(band, greaterThanOrEqualTo(0.0));
              }
              expect(data.rms.isNaN, isFalse);
              expect(data.rms, greaterThanOrEqualTo(0.0));
              expect(data.peak.isNaN, isFalse);
              expect(data.peak, greaterThanOrEqualTo(0.0));
              receivedPerSubscriber[index].add(data);
            }),
          );
        }

        // Also attach 10 concurrent visualizerEnabled listeners
        final enabledEvents = <int, List<bool>>{};
        final enabledSubs = <StreamSubscription<bool>>[];
        for (int s = 0; s < 10; s++) {
          final idx = s;
          enabledEvents[idx] = [];
          enabledSubs.add(
            player.stream.visualizerEnabled.listen((v) {
              enabledEvents[idx]!.add(v);
            }),
          );
        }

        // 2. Execute concurrent thrashing: attach/detach dynamic listeners while toggling
        final futures = <Future<void>>[];

        // Worker A: Rapid toggling
        futures.add(
          Future<void>(() async {
            for (int i = 0; i < 30; i++) {
              await player.action.setVisualizerEnabled(i.isEven);
              await Future<void>.delayed(const Duration(milliseconds: 5));
              await player.action.clearVisualizerOverride();
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          }),
        );

        // Worker B: Dynamic transient listener churn
        futures.add(
          Future<void>(() async {
            for (int i = 0; i < 20; i++) {
              final transientSub = player.stream.visualizer.listen((_) {});
              await Future<void>.delayed(const Duration(milliseconds: 7));
              await transientSub.cancel();
            }
          }),
        );

        await Future.wait(futures);

        // 3. Clean up all persistent subscriptions
        for (final sub in subscriptions) {
          await sub.cancel();
        }
        for (final sub in enabledSubs) {
          await sub.cancel();
        }

        // Verify all subscribers captured data without any exceptions
        for (int s = 0; s < subscriberCount; s++) {
          expect(receivedPerSubscriber[s], isNotEmpty);
        }

        // Verify player is healthy
        expect(player.state.playing, isTrue);
      },
    );

    // =========================================================================
    // 3. Mid-Playback Disable Verification (Strict Zeroing & DSP Disabled)
    // =========================================================================
    test(
      'Mid-Playback Disable: Visualizer data strictly zeroed and native DSP disabled',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        final streamEmissions = <VisualizerData>[];
        final sub = player.stream.visualizer.listen((data) {
          streamEmissions.add(data);
        });
        addTearDown(() => sub.cancel());

        await player.action.open(audioFile.path, autoPlay: true);

        // Wait until real music produces significant energy
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.state.playing, isTrue);
        expect(player.state.visualizerEnabled, isTrue);
        expect(
          streamEmissions.any((d) => d.rms > 0.01),
          isTrue,
          reason: 'Active music must generate non-zero RMS',
        );

        // Explicitly force disable mid-playback
        await player.action.setVisualizerEnabled(false);

        // 1. Verify Dart PlayerState snapshot is strictly zeroed
        expect(player.state.visualizerEnabled, isFalse);
        final snapshot = player.state.visualizer;
        expect(snapshot.rms, equals(0.0));
        expect(snapshot.peak, equals(0.0));
        expect(snapshot.left, equals(0.0));
        expect(snapshot.right, equals(0.0));
        expect(snapshot.bands.length, equals(10));
        expect(snapshot.bands.every((b) => b == 0.0), isTrue);

        // 2. Verify native C engine status via FFI
        final nativeEnabled =
            native.miniaudio_player_is_visualizer_enabled(player.handle);
        expect(nativeEnabled, equals(0));

        // 3. Verify native visualizer data struct in C memory is strictly zeroed
        final visDataPtr =
            calloc<native.miniaudio_player_visualizer_data_t>();
        try {
          final res = native.miniaudio_player_get_visualizer_data(
            player.handle,
            visDataPtr,
          );
          expect(res, equals(0)); // MAP_SUCCESS
          expect(visDataPtr.ref.rms, equals(0.0));
          expect(visDataPtr.ref.peak, equals(0.0));
          expect(visDataPtr.ref.left, equals(0.0));
          expect(visDataPtr.ref.right, equals(0.0));
          for (int b = 0; b < 10; b++) {
            expect(visDataPtr.ref.bands[b], equals(0.0));
          }
        } finally {
          calloc.free(visDataPtr);
        }

        // 4. Continue playback for 200ms and verify no non-zero data frames are emitted
        final emissionsCountBefore = streamEmissions.length;
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Last emitted item must be strictly empty
        expect(streamEmissions.last.rms, equals(0.0));
        expect(
          streamEmissions.last.bands.every((b) => b == 0.0),
          isTrue,
        );

        // All emissions occurring after the disable command must be strictly zeroed
        final newEmissions = streamEmissions.sublist(emissionsCountBefore);
        for (final e in newEmissions) {
          expect(e.rms, equals(0.0));
          expect(e.bands.every((b) => b == 0.0), isTrue);
        }
      },
    );

    // =========================================================================
    // 4. Reversion via clearVisualizerOverride() Restoration Matrix
    // =========================================================================
    test(
      'clearVisualizerOverride: Complete lifecycle matrix and restoration under playback',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        await player.action.open(audioFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Case A: With active stream listener
        final sub = player.stream.visualizer.listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(player.state.visualizerEnabled, isTrue);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(1),
        );

        // Force disable
        await player.action.setVisualizerEnabled(false);
        expect(player.state.visualizerEnabled, isFalse);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(0),
        );

        // Revert via clearVisualizerOverride() -> should resume active state
        await player.action.clearVisualizerOverride();
        expect(player.state.visualizerEnabled, isTrue);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(1),
        );

        // Allow audio to process and verify non-zero visualizer data resumes
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.visualizer.rms, greaterThan(0.001));

        // Cancel the listener -> on demand deactivates visualizer
        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(player.state.visualizerEnabled, isFalse);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(0),
        );

        // Case B: With NO active stream listener
        // Force enable without listeners
        await player.action.setVisualizerEnabled(true);
        expect(player.state.visualizerEnabled, isTrue);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(1),
        );

        // Revert via clearVisualizerOverride() -> should deactivate because 0 listeners!
        await player.action.clearVisualizerOverride();
        expect(player.state.visualizerEnabled, isFalse);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(0),
        );

        // Force disable without listeners
        await player.action.setVisualizerEnabled(false);
        expect(player.state.visualizerEnabled, isFalse);
        // Clear override without listeners -> remains false
        await player.action.clearVisualizerOverride();
        expect(player.state.visualizerEnabled, isFalse);

        // Case C: Idempotence of clearVisualizerOverride
        await player.action.clearVisualizerOverride();
        await player.action.clearVisualizerOverride();
        expect(player.state.visualizerEnabled, isFalse);
      },
    );

    // =========================================================================
    // 5. Hostile Lifecycle Stress & Teardown
    // =========================================================================
    test(
      'Hostile Lifecycle: Repeated fast player re-instantiation and disposal under active visualizer',
      () async {
        for (int iteration = 0; iteration < 8; iteration++) {
          final p = MiniaudioPlayer();
          final sub = p.stream.visualizer.listen((_) {});
          await p.action.open(audioFile.path, autoPlay: true);

          // Fast toggle during initial buffer fill
          await p.action.setVisualizerEnabled(false);
          await p.action.setVisualizerEnabled(true);
          await p.action.clearVisualizerOverride();

          await sub.cancel();
          await p.dispose();
          expect(p.isDisposed, isTrue);
        }
      },
    );

    // =========================================================================
    // 6. Listener Attachment While Override is Forced False
    // =========================================================================
    test(
      'Listener Attachment While Override False: New subscriptions never trigger native DSP activation',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        await player.action.open(audioFile.path, autoPlay: true);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 1. Force visualizer disabled before any listeners exist
        await player.action.setVisualizerEnabled(false);
        expect(player.state.visualizerEnabled, isFalse);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(0),
        );

        // 2. Now attach 5 listeners while forced false is active
        final listeners = <StreamSubscription<VisualizerData>>[];
        final received = <VisualizerData>[];
        for (int i = 0; i < 5; i++) {
          listeners.add(
            player.stream.visualizer.listen((data) {
              received.add(data);
            }),
          );
        }

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Native DSP MUST REMAIN DISABLED
        expect(player.state.visualizerEnabled, isFalse);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(0),
        );
        expect(player.state.visualizer.rms, equals(0.0));
        expect(player.state.visualizer.bands.every((b) => b == 0.0), isTrue);

        // Any events emitted must be strictly zeroed
        for (final r in received) {
          expect(r.rms, equals(0.0));
          expect(r.bands.every((b) => b == 0.0), isTrue);
        }

        // 3. Detach all listeners while still forced false
        for (final l in listeners) {
          await l.cancel();
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(player.state.visualizerEnabled, isFalse);
        expect(
          native.miniaudio_player_is_visualizer_enabled(player.handle),
          equals(0),
        );
      },
    );

    // =========================================================================
    // 7. Concurrent Seeking, Pausing, and Visualizer Overrides
    // =========================================================================
    test(
      'Playback Control Concurrency: Seeks and pauses interleaved with visualizer overrides',
      () async {
        final player = MiniaudioPlayer();
        addTearDown(() async {
          if (!player.isDisposed) await player.dispose();
        });

        await player.action.open(audioFile.path, autoPlay: true);
        final sub = player.stream.visualizer.listen((_) {});
        addTearDown(() => sub.cancel());

        // Concurrently run seeks, pauses, plays, and visualizer overrides
        final tasks = <Future<void>>[
          Future<void>(() async {
            for (int i = 0; i < 20; i++) {
              await player.action.seek(Duration(milliseconds: i * 50));
              await Future<void>.delayed(const Duration(milliseconds: 3));
            }
          }),
          Future<void>(() async {
            for (int i = 0; i < 15; i++) {
              if (i.isEven) {
                await player.action.pause();
              } else {
                await player.action.play();
              }
              await Future<void>.delayed(const Duration(milliseconds: 4));
            }
          }),
          Future<void>(() async {
            for (int i = 0; i < 30; i++) {
              await player.action.setVisualizerEnabled(i.isEven);
              await Future<void>.delayed(const Duration(milliseconds: 2));
              await player.action.clearVisualizerOverride();
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
          }),
        ];

        await Future.wait(tasks);

        // Verify player is not corrupted, can stop cleanly
        await player.action.stop();
        expect(player.state.playing, isFalse);
        expect(player.state.visualizer.rms, equals(0.0));
      },
    );
  });
}

