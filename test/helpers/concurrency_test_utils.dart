import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

/// Deterministic, sleep-free concurrency and stream synchronization helpers for tests.
///
/// These utilities replace blind `Future.delayed(...)` polling loops and post-action
/// sleeps with reactive broadcast stream listeners combined with immediate synchronous
/// snapshot checks so race conditions in Rust/Dart state synchronization are surfaced
/// rather than hidden.

/// Returns as soon as [predicate] holds for either the current snapshot [current]
/// or a subsequent event emitted by [stream].
///
/// Subscribes to [stream] before re-checking [current] to avoid missed-event races
/// between state inspection and listener registration.
Future<S> awaitStateOrStream<S>({
  required Stream<S> stream,
  required S Function() current,
  required bool Function(S value) predicate,
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final initial = current();
  if (predicate(initial)) {
    return initial;
  }

  final completer = Completer<S>();
  late final StreamSubscription<S> sub;
  sub = stream.listen(
    (value) {
      if (!completer.isCompleted && predicate(value)) {
        completer.complete(value);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
  );

  // Re-evaluate synchronous snapshot after subscribing in case an event arrived
  // concurrently before subscription completed.
  final postSubscribe = current();
  if (!completer.isCompleted && predicate(postSubscribe)) {
    completer.complete(postSubscribe);
  }

  try {
    return await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        reason ??
            'Timed out after ${timeout.inMilliseconds}ms waiting for condition '
                '(last snapshot: ${current()})',
        timeout,
      ),
    );
  } finally {
    await sub.cancel();
  }
}

/// Subscribes to [stream], runs [action], and waits until [stream] emits an event
/// matching [predicate].
///
/// Use this to assert that an action causes a genuine reactive broadcast event even
/// when the event is emitted synchronously during [action].
Future<(R, S)> performAndAwaitStream<R, S>({
  required Future<R> Function() action,
  required Stream<S> stream,
  required bool Function(S value) predicate,
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final completer = Completer<S>();
  final sub = stream.listen(
    (value) {
      if (!completer.isCompleted && predicate(value)) {
        completer.complete(value);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
  );

  try {
    final result = await action();
    final matched = await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        reason ??
            'Timed out after ${timeout.inMilliseconds}ms waiting for stream event after action',
        timeout,
      ),
    );
    return (result, matched);
  } finally {
    await sub.cancel();
  }
}

/// Waits until playback position advances by at least [minDelta] from the current
/// [MiniaudioPlayer.state.position], driven purely by [PlayerStream.position].
Future<Duration> waitForAudioProgress<T>(
  MiniaudioPlayer<T> player, {
  Duration minDelta = const Duration(milliseconds: 60),
  Duration timeout = const Duration(seconds: 5),
}) {
  final target = player.state.position + minDelta;
  return awaitStateOrStream<Duration>(
    stream: player.stream.position,
    current: () => player.state.position,
    predicate: (pos) => pos >= target,
    timeout: timeout,
    reason: 'Timed out waiting for playback position >= $target '
        '(current: ${player.state.position}, isPlaying: ${player.state.isPlaying})',
  );
}

/// Waits until active live WAV recording accumulates at least [minRecorded] of PCM audio,
/// driven purely by [PlayerStream.recordedDuration].
Future<Duration> waitForRecordingProgress<T>(
  MiniaudioPlayer<T> player, {
  Duration minRecorded = const Duration(milliseconds: 80),
  Duration timeout = const Duration(seconds: 5),
}) {
  return awaitStateOrStream<Duration>(
    stream: player.stream.recordedDuration,
    current: () => player.state.recordedDuration,
    predicate: (dur) => dur >= minRecorded,
    timeout: timeout,
    reason: 'Timed out waiting for recordedDuration >= $minRecorded '
        '(current: ${player.state.recordedDuration}, isRecording: ${player.state.isRecording})',
  );
}

/// Flushes pending Dart event-loop / microtask turns so already-dispatched
/// `StreamController.broadcast` events reach listeners without wall-clock sleeps.
Future<void> drainBroadcastStreams([int times = 4]) =>
    pumpEventQueue(times: times);

/// Verifies structural invariants across [player.state] fields.
///
/// Throws a [TestFailure] if any cross-field invariant is violated.
void assertPlayerInvariants<T>(MiniaudioPlayer<T> player) {
  final state = player.state;
  final queue = state.queue;
  final idx = state.currentIndex;

  if (idx != null) {
    expect(idx, inInclusiveRange(0, queue.length - 1),
        reason: 'currentIndex ($idx) out of bounds for queue length ${queue.length}');
    expect(state.currentItem, isNotNull,
        reason: 'currentItem must be non-null when currentIndex ($idx) is set');
    expect(state.currentItem!.id, equals(queue[idx].id),
        reason: 'currentItem.id mismatch with queue[$idx].id');
  } else {
    expect(state.currentItem, isNull,
        reason: 'currentItem must be null when currentIndex is null');
  }

  expect(state.position, greaterThanOrEqualTo(Duration.zero));
  expect(state.recordedDuration, greaterThanOrEqualTo(Duration.zero));
  expect(state.silenceSavedDuration, greaterThanOrEqualTo(Duration.zero));
  expect(state.activeVoicesCount, greaterThanOrEqualTo(0));
  expect(state.allocatedRamBytes, greaterThanOrEqualTo(0));
  expect(state.volume.isFinite && state.volume >= 0.0, isTrue,
      reason: 'Invalid volume: ${state.volume}');
  expect(state.rate.isFinite && state.rate > 0.0, isTrue,
      reason: 'Invalid rate: ${state.rate}');
  expect(state.pitch.isFinite && state.pitch > 0.0, isTrue,
      reason: 'Invalid pitch: ${state.pitch}');
  expect(state.balance.isFinite, isTrue,
      reason: 'Invalid balance: ${state.balance}');
  expect(state.micRmsLevel.isFinite, isTrue,
      reason: 'Invalid micRmsLevel: ${state.micRmsLevel}');
}
