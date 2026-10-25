import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/engine/internal_crossfade_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InternalCrossfadeController - Pure Math & Curve Evaluation', () {
    test('equalPower curve at p=0.0, p=0.5, p=1.0 with masterVolume=1.0', () {
      final (out0, in0) = InternalCrossfadeController.computeVolumes(
        0.0,
        CrossfadeCurve.equalPower,
        1.0,
      );
      expect(out0, closeTo(1.0, 1e-6));
      expect(in0, closeTo(0.0, 1e-6));

      final (outHalf, inHalf) = InternalCrossfadeController.computeVolumes(
        0.5,
        CrossfadeCurve.equalPower,
        1.0,
      );
      // cos(pi/4) == sin(pi/4) == sqrt(2)/2 ~= 0.70710678
      expect(outHalf, closeTo(0.70710678, 1e-4));
      expect(inHalf, closeTo(0.70710678, 1e-4));
      // Equal power invariant: out^2 + in^2 == 1.0
      expect((outHalf * outHalf) + (inHalf * inHalf), closeTo(1.0, 1e-4));

      final (out1, in1) = InternalCrossfadeController.computeVolumes(
        1.0,
        CrossfadeCurve.equalPower,
        1.0,
      );
      expect(out1, closeTo(0.0, 1e-6));
      expect(in1, closeTo(1.0, 1e-6));
    });

    test('linear curve at p=0.0, p=0.5, p=1.0 with masterVolume=1.0', () {
      final (out0, in0) = InternalCrossfadeController.computeVolumes(
        0.0,
        CrossfadeCurve.linear,
        1.0,
      );
      expect(out0, closeTo(1.0, 1e-6));
      expect(in0, closeTo(0.0, 1e-6));

      final (outHalf, inHalf) = InternalCrossfadeController.computeVolumes(
        0.5,
        CrossfadeCurve.linear,
        1.0,
      );
      expect(outHalf, closeTo(0.5, 1e-6));
      expect(inHalf, closeTo(0.5, 1e-6));
      expect(outHalf + inHalf, closeTo(1.0, 1e-6));

      final (out1, in1) = InternalCrossfadeController.computeVolumes(
        1.0,
        CrossfadeCurve.linear,
        1.0,
      );
      expect(out1, closeTo(0.0, 1e-6));
      expect(in1, closeTo(1.0, 1e-6));
    });

    test('masterVolume scaling on 0.0..2.0 scale', () {
      final (outLow, inLow) = InternalCrossfadeController.computeVolumes(
        0.5,
        CrossfadeCurve.equalPower,
        0.4,
      );
      expect(outLow, closeTo(0.4 * 0.70710678, 1e-4));
      expect(inLow, closeTo(0.4 * 0.70710678, 1e-4));

      final (outHigh, inHigh) = InternalCrossfadeController.computeVolumes(
        0.5,
        CrossfadeCurve.equalPower,
        1.8,
      );
      expect(outHigh, closeTo(1.8 * 0.70710678, 1e-4));
      expect(inHigh, closeTo(1.8 * 0.70710678, 1e-4));

      final (outZero, inZero) = InternalCrossfadeController.computeVolumes(
        0.5,
        CrossfadeCurve.equalPower,
        0.0,
      );
      expect(outZero, equals(0.0));
      expect(inZero, equals(0.0));
    });

    test('clamps progress below 0.0 and above 1.0', () {
      final (outNeg, inNeg) = InternalCrossfadeController.computeVolumes(
        -0.5,
        CrossfadeCurve.equalPower,
        1.0,
      );
      expect(outNeg, closeTo(1.0, 1e-6));
      expect(inNeg, closeTo(0.0, 1e-6));

      final (outOver, inOver) = InternalCrossfadeController.computeVolumes(
        1.5,
        CrossfadeCurve.equalPower,
        1.0,
      );
      expect(outOver, closeTo(0.0, 1e-6));
      expect(inOver, closeTo(1.0, 1e-6));
    });
  });

  group('InternalCrossfadeController - Lifecycle & Real Ticker Controls', () {
    late MiniaudioPlayer playerOut;
    late MiniaudioPlayer playerIn;
    late InternalCrossfadeController controller;

    setUp(() {
      playerOut = MiniaudioPlayer();
      playerIn = MiniaudioPlayer();
      controller = InternalCrossfadeController(
        tickerInterval: const Duration(milliseconds: 15),
      );
    });

    tearDown(() async {
      controller.dispose();
      await Future.wait([
        playerOut.dispose(),
        playerIn.dispose(),
      ]);
    });

    test('duration <= immediateCutThresholdMs completes synchronously', () async {
      var completed = false;
      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(milliseconds: 30),
        curve: CrossfadeCurve.equalPower,
        masterVolume: 0.8,
        onComplete: () {
          completed = true;
        },
      );

      expect(completed, isTrue);
      expect(controller.isActive, isFalse);
      expect(playerOut.state.volume, closeTo(0.0, 1e-4));
      expect(playerIn.state.volume, closeTo(0.8, 1e-4));
    });

    test('smooth progression from 0.0 to 1.0 with real ticker', () async {
      final completer = Completer<void>();
      final volumeHistoryOut = <double>[];
      final volumeHistoryIn = <double>[];

      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(milliseconds: 150),
        curve: CrossfadeCurve.linear,
        masterVolume: 1.0,
        onComplete: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      expect(controller.isActive, isTrue);
      expect(controller.progress, greaterThanOrEqualTo(0.0));

      final timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
        volumeHistoryOut.add(playerOut.state.volume);
        volumeHistoryIn.add(playerIn.state.volume);
      });

      await completer.future.timeout(const Duration(seconds: 2));
      timer.cancel();
      // Allow unawaited async volume setter from _completeNow to settle on the players
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(controller.isActive, isFalse);
      expect(playerOut.state.volume, closeTo(0.0, 1e-4));
      expect(playerIn.state.volume, closeTo(1.0, 1e-4));
      expect(volumeHistoryOut.isNotEmpty, isTrue);
      expect(volumeHistoryIn.isNotEmpty, isTrue);
    });

    test('pause and resume freezes and restarts ticker', () async {
      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(milliseconds: 400),
        curve: CrossfadeCurve.linear,
        masterVolume: 1.0,
        onComplete: () {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));
      controller.pause();
      expect(controller.isPaused, isTrue);
      final pausedProgress = controller.progress;
      expect(pausedProgress, greaterThan(0.0));

      // Wait a while while paused; progress should not change significantly
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(controller.progress, closeTo(pausedProgress, 0.05));

      controller.resume();
      expect(controller.isPaused, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(controller.progress, greaterThan(pausedProgress));
    });

    test('cancel stops ramp without firing onComplete', () async {
      var completed = false;
      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(milliseconds: 300),
        curve: CrossfadeCurve.linear,
        masterVolume: 1.0,
        onComplete: () {
          completed = true;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.isActive, isTrue);
      controller.cancel();
      expect(controller.isActive, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, isFalse);
    });

    test('setMasterVolume mid-crossfade updates deck volumes in real time', () async {
      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(milliseconds: 300),
        curve: CrossfadeCurve.linear,
        masterVolume: 1.0,
        onComplete: () {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      controller.setMasterVolume(0.5);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      // With linear curve and master volume = 0.5, sum of deck volumes should approximate 0.5
      final sum = playerOut.state.volume + playerIn.state.volume;
      expect(sum, closeTo(0.5, 0.1));
    });

    test('capRemainingDuration cuts long remaining fade to maxRemaining', () async {
      final completer = Completer<void>();
      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(seconds: 10),
        curve: CrossfadeCurve.linear,
        masterVolume: 1.0,
        onComplete: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.effectiveDuration.inSeconds, equals(10));

      // Cap remaining to 100ms
      controller.capRemainingDuration(const Duration(milliseconds: 100));
      expect(controller.effectiveDuration.inMilliseconds, lessThan(1000));

      // Should complete quickly within 400ms rather than waiting 10 seconds!
      await completer.future.timeout(const Duration(milliseconds: 600));
      expect(controller.isActive, isFalse);
    });

    test('updateOnComplete updates active completion callback', () async {
      var firstCalled = false;
      var secondCalled = false;
      final completer = Completer<void>();

      await controller.start(
        playerOut: playerOut,
        playerIn: playerIn,
        duration: const Duration(milliseconds: 80),
        curve: CrossfadeCurve.linear,
        masterVolume: 1.0,
        onComplete: () {
          firstCalled = true;
        },
      );

      controller.updateOnComplete(() {
        secondCalled = true;
        completer.complete();
      });

      await completer.future.timeout(const Duration(seconds: 1));
      expect(firstCalled, isFalse);
      expect(secondCalled, isTrue);
    });
  });
}
