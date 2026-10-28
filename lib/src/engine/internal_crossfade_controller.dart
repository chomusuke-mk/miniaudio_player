import 'dart:async';
import 'dart:math' as math;

import '../api/crossfade_config.dart';
import '../api/miniaudio_player.dart';

/// Internal gain-envelope interpolator owned exclusively by `MiniaudioEngine`.
///
/// Unlike legacy crossfade managers that directly invoked `seek()`, `play()`,
/// or `stop()` on players inside timer callbacks (causing race conditions and
/// dirty states when skipping forward and backward rapidly),
/// [InternalCrossfadeController] is **strictly a pure gain-ramp ticker**:
/// - It never opens, seeks, starts, pauses, or stops either deck.
/// - Deck lifecycle and transport states (`open`, `play`, `pause`, `stop`) are
///   governed 100% by `MiniaudioEngine`'s Finite State Machine.
/// - Its sole responsibility is computing `(gainOut, gainIn)` at each tick and
///   applying `setVolume` to the outgoing and incoming decks until `progress`
///   reaches `1.0` (or the outgoing deck signals EOF).
class InternalCrossfadeController {
  /// Duration threshold (`<= 40ms`) below which a crossfade is treated as an
  /// immediate completion.
  static const int immediateCutThresholdMs = 40;

  /// Interval between gain envelope interpolation updates (default: `25ms` / `40 Hz`).
  final Duration tickerInterval;

  Timer? _ticker;
  int _operationId = 0;

  bool _isActive = false;
  bool _isPaused = false;
  double _masterVolume = 1.0;
  double _playbackRate = 1.0;
  CrossfadeCurve _curve = CrossfadeCurve.equalPower;

  Duration _effectiveDuration = Duration.zero;
  DateTime? _lastTickWallTime;
  double _accumulatedMediaMs = 0.0;
  Duration? _playerOutStartPos;
  double _mediaOffsetMs = 0.0;

  MiniaudioPlayer? _playerOut;
  MiniaudioPlayer? _playerIn;
  void Function()? _onComplete;

  InternalCrossfadeController({
    this.tickerInterval = const Duration(milliseconds: 25),
  });

  /// Whether a gain-ramp interpolation is currently running.
  bool get isActive => _isActive;

  /// Whether the active gain ramp is currently paused.
  bool get isPaused => _isPaused;

  /// Current effective target duration of the active ramp.
  Duration get effectiveDuration => _effectiveDuration;

  /// Current normalized progress (`0.0` to `1.0`) of the active ramp.
  double get progress {
    if (!_isActive) return 0.0;
    final totalMs = _effectiveDuration.inMilliseconds;
    if (totalMs <= 0) return 1.0;
    return (_currentElapsedMediaMs() / totalMs).clamp(0.0, 1.0);
  }

  double _currentElapsedMediaMs() {
    var wallMediaMs = _accumulatedMediaMs;
    if (!_isPaused && _lastTickWallTime != null) {
      final deltaWallMs =
          DateTime.now().difference(_lastTickWallTime!).inMicroseconds / 1000.0;
      if (deltaWallMs > 0) {
        wallMediaMs += deltaWallMs * _playbackRate;
      }
    }

    var playerMediaMs = 0.0;
    final out = _playerOut;
    final startPos = _playerOutStartPos;
    if (out != null && startPos != null) {
      final posDelta = (out.state.position - startPos).inMilliseconds.toDouble();
      if (posDelta > 0) {
        playerMediaMs = posDelta;
      }
    }

    final rawMediaMs = math.max(wallMediaMs, playerMediaMs);
    return math.max(0.0, rawMediaMs + _mediaOffsetMs);
  }

  void _log(String message) {
    if (MiniaudioPlayer.globalConfig.logLevel.value >=
        MiniaudioLogLevel.verbose.value) {
      // ignore: avoid_print
      print('[miniaudio_player][VERBOSE][crossfade] $message');
    }
  }

  /// Starts interpolating volume from [playerOut] (`masterVolume -> 0.0`) to
  /// [playerIn] (`0.0 -> masterVolume`) over [duration].
  ///
  /// Preconditions guaranteed by `MiniaudioEngine`'s state machine:
  /// - [playerIn] is already opened at frame `0` and playing (or paused if the
  ///   engine is paused).
  /// - If [duration] is `<= immediateCutThresholdMs`, [onComplete] is invoked
  ///   synchronously after applying end-state volumes.
  Future<void> start({
    required MiniaudioPlayer playerOut,
    required MiniaudioPlayer playerIn,
    required Duration duration,
    required CrossfadeCurve curve,
    required double masterVolume,
    double playbackRate = 1.0,
    bool initiallyPaused = false,
    required void Function() onComplete,
  }) async {
    cancel();
    final opId = ++_operationId;

    _masterVolume = masterVolume.clamp(0.0, 2.0);
    _playbackRate = playbackRate.clamp(0.1, 4.0);
    _curve = curve;
    _effectiveDuration = duration;

    _log(
      'start: duration=${duration.inMilliseconds}ms, curve=${curve.name}, '
      'masterVolume=${_masterVolume.toStringAsFixed(2)}, rate=$_playbackRate, '
      'playerOut pos=${playerOut.state.position.inMilliseconds}ms/${playerOut.state.duration.inMilliseconds}ms, '
      'playerIn pos=${playerIn.state.position.inMilliseconds}ms/${playerIn.state.duration.inMilliseconds}ms',
    );

    if (duration.inMilliseconds <= immediateCutThresholdMs) {
      _log('start: duration <= ${immediateCutThresholdMs}ms, executing immediate cut');
      await _applyVolumes(playerOut, playerIn, 0.0, _masterVolume);
      if (opId == _operationId) {
        onComplete();
      }
      return;
    }

    _playerOut = playerOut;
    _playerIn = playerIn;
    _onComplete = onComplete;
    _isActive = true;
    _isPaused = initiallyPaused;
    _accumulatedMediaMs = 0.0;
    _mediaOffsetMs = 0.0;
    _lastTickWallTime = initiallyPaused ? null : DateTime.now();
    _playerOutStartPos = playerOut.state.position;

    final (volOut, volIn) = computeVolumes(0.0, _curve, _masterVolume);
    await _applyVolumes(playerOut, playerIn, volOut, volIn);
    if (opId != _operationId || !_isActive) return;

    if (!initiallyPaused) {
      _startTicker(opId);
    }
  }

  void _startTicker(int opId) {
    _ticker?.cancel();
    _ticker = Timer.periodic(tickerInterval, (_) => _tick(opId));
  }

  void _tick(int opId) {
    if (opId != _operationId || !_isActive || _isPaused) return;

    final out = _playerOut;
    final inn = _playerIn;
    if (out == null || inn == null) {
      cancel();
      return;
    }

    final now = DateTime.now();
    if (_lastTickWallTime != null) {
      final deltaWallMs =
          now.difference(_lastTickWallTime!).inMicroseconds / 1000.0;
      if (deltaWallMs > 0) {
        _accumulatedMediaMs += deltaWallMs * _playbackRate;
      }
    }
    _lastTickWallTime = now;

    if (out.state.completed) {
      _log('tick: playerOut signaled completed -> completing crossfade early');
      _completeNow(opId);
      return;
    }

    final totalMs = _effectiveDuration.inMilliseconds;
    final p = totalMs > 0
        ? (_currentElapsedMediaMs() / totalMs).clamp(0.0, 1.0)
        : 1.0;

    final (volOut, volIn) = computeVolumes(p, _curve, _masterVolume);
    _log(
      'tick: p=${p.toStringAsFixed(3)}, volOut=${volOut.toStringAsFixed(3)}, volIn=${volIn.toStringAsFixed(3)}, '
      'elapsedMedia=${_currentElapsedMediaMs().toStringAsFixed(1)}ms/${totalMs}ms, '
      'outPos=${out.state.position.inMilliseconds}ms, inPos=${inn.state.position.inMilliseconds}ms',
    );

    if (p >= 1.0) {
      _completeNow(opId);
      return;
    }

    _applyVolumesUnawaited(out, inn, volOut, volIn);
  }

  void _completeNow(int opId) {
    if (opId != _operationId || !_isActive) return;
    final out = _playerOut;
    final inn = _playerIn;
    final callback = _onComplete;

    _log(
      '_completeNow: opId=$opId, effectiveDuration=${_effectiveDuration.inMilliseconds}ms, '
      'outPos=${out?.state.position.inMilliseconds}ms, inPos=${inn?.state.position.inMilliseconds}ms',
    );

    cancel();

    if (out != null && inn != null) {
      _applyVolumesUnawaited(out, inn, 0.0, _masterVolume);
    }
    callback?.call();
  }

  /// Synchronizes the active crossfade gain envelope with the actual media
  /// playback position of the outgoing player, allowing seeking inside the
  /// crossfade zone to update the volume curves seamlessly.
  void syncProgress(double normalizedProgress) {
    if (!_isActive) return;
    final p = normalizedProgress.clamp(0.0, 1.0);
    final totalMs = _effectiveDuration.inMilliseconds.toDouble();
    if (totalMs > 0) {
      final desiredMediaMs = p * totalMs;
      final rawMediaMs = _currentElapsedMediaMs() - _mediaOffsetMs;
      _mediaOffsetMs = desiredMediaMs - rawMediaMs;
    }
    final out = _playerOut;
    final inn = _playerIn;
    if (out != null && inn != null) {
      final (volOut, volIn) = computeVolumes(p, _curve, _masterVolume);
      _log(
        'syncProgress: inputProgress=${normalizedProgress.toStringAsFixed(3)}, clampedP=${p.toStringAsFixed(3)}, '
        'volOut=${volOut.toStringAsFixed(3)}, volIn=${volIn.toStringAsFixed(3)}, '
        'effectiveDuration=${_effectiveDuration.inMilliseconds}ms',
      );
      _applyVolumesUnawaited(out, inn, volOut, volIn);
    }
    if (p >= 1.0) {
      _completeNow(_operationId);
    }
  }

  /// Dynamically updates the master volume (`0.0..2.0`) during an active ramp.
  void setMasterVolume(double volume) {
    _masterVolume = volume.clamp(0.0, 2.0);
    if (!_isActive) return;
    final out = _playerOut;
    final inn = _playerIn;
    if (out == null || inn == null) return;
    final (volOut, volIn) = computeVolumes(progress, _curve, _masterVolume);
    _applyVolumesUnawaited(out, inn, volOut, volIn);
  }

  /// Dynamically updates the playback speed multiplier (`0.1..4.0`) during an
  /// active ramp.
  void setPlaybackRate(double rate) {
    final newRate = rate.clamp(0.1, 4.0);
    if (_isActive && !_isPaused && _lastTickWallTime != null) {
      final now = DateTime.now();
      final deltaWallMs =
          now.difference(_lastTickWallTime!).inMicroseconds / 1000.0;
      if (deltaWallMs > 0) {
        _accumulatedMediaMs += deltaWallMs * _playbackRate;
      }
      _lastTickWallTime = now;
    }
    _playbackRate = newRate;
  }

  /// Caps the remaining duration of an in-flight ramp to at most [maxRemaining]
  /// without causing a discontinuity in current progress or deck volumes.
  ///
  /// Used when promoting an in-flight `autoCrossfading` transition into a
  /// `manualCrossfading` transition on user `next()`.
  void capRemainingDuration(Duration maxRemaining) {
    if (!_isActive) return;
    final p = progress;
    _log('capRemainingDuration: maxRemaining=${maxRemaining.inMilliseconds}ms, currentP=${p.toStringAsFixed(3)}');
    if (p >= 1.0 || maxRemaining <= Duration.zero) {
      _completeNow(_operationId);
      return;
    }

    final totalMs = _effectiveDuration.inMilliseconds.toDouble();
    final elapsedMediaMs = _currentElapsedMediaMs();
    final remainingMediaMs = totalMs - elapsedMediaMs;
    final maxRemainingMediaMs = maxRemaining.inMilliseconds * _playbackRate;

    if (remainingMediaMs <= maxRemainingMediaMs) return;

    final newTotalMs = maxRemainingMediaMs / (1.0 - p);
    final rawMediaMs = elapsedMediaMs - _mediaOffsetMs;
    _mediaOffsetMs = (p * newTotalMs) - rawMediaMs;
    _effectiveDuration = Duration(milliseconds: newTotalMs.round());
  }

  /// Freezes the gain envelope ticker at its current progress.
  void pause() {
    if (!_isActive || _isPaused) return;
    _log('pause: progress=${progress.toStringAsFixed(3)}');
    if (_lastTickWallTime != null) {
      final deltaWallMs =
          DateTime.now().difference(_lastTickWallTime!).inMicroseconds / 1000.0;
      if (deltaWallMs > 0) {
        _accumulatedMediaMs += deltaWallMs * _playbackRate;
      }
      _lastTickWallTime = null;
    }
    _isPaused = true;
    _ticker?.cancel();
    _ticker = null;
  }

  /// Resumes the gain envelope ticker from its paused progress.
  void resume() {
    if (!_isActive || !_isPaused) return;
    _log('resume: progress=${progress.toStringAsFixed(3)}');
    _isPaused = false;
    _lastTickWallTime = DateTime.now();
    _startTicker(_operationId);
  }

  /// Updates the completion callback for the active gain ramp.
  void updateOnComplete(void Function() onComplete) {
    _onComplete = onComplete;
  }

  /// Synchronously stops the gain envelope ticker without firing `_onComplete`.
  void cancel() {
    if (_isActive) {
      _log('cancel: operationId=$_operationId');
    }
    _operationId++;
    _ticker?.cancel();
    _ticker = null;
    _isActive = false;
    _isPaused = false;
    _effectiveDuration = Duration.zero;
    _lastTickWallTime = null;
    _accumulatedMediaMs = 0.0;
    _mediaOffsetMs = 0.0;
    _playerOutStartPos = null;
    _playerOut = null;
    _playerIn = null;
    _onComplete = null;
  }

  /// Disposes the controller and cancels any active timer.
  void dispose() {
    cancel();
  }

  /// Pure mathematical volume curve evaluation for normalized progress [p]
  /// (`0.0` to `1.0`) and [masterVolume] (`0.0` to `2.0`).
  static (double volOut, double volIn) computeVolumes(
    double p,
    CrossfadeCurve curve,
    double masterVolume,
  ) {
    final clampedP = p.clamp(0.0, 1.0);
    double gainOut;
    double gainIn;

    switch (curve) {
      case CrossfadeCurve.equalPower:
        final angle = clampedP * (math.pi / 2.0);
        gainOut = math.cos(angle);
        gainIn = math.sin(angle);
      case CrossfadeCurve.linear:
        gainOut = 1.0 - clampedP;
        gainIn = clampedP;
    }

    final volOut = (gainOut * masterVolume).clamp(0.0, 2.0);
    final volIn = (gainIn * masterVolume).clamp(0.0, 2.0);
    return (volOut, volIn);
  }

  static Future<void> _applyVolumes(
    MiniaudioPlayer out,
    MiniaudioPlayer inn,
    double volOut,
    double volIn,
  ) async {
    try {
      if (!out.isDisposed) await out.action.setVolume(volOut);
      if (!inn.isDisposed) await inn.action.setVolume(volIn);
    } catch (_) {}
  }

  static void _applyVolumesUnawaited(
    MiniaudioPlayer out,
    MiniaudioPlayer inn,
    double volOut,
    double volIn,
  ) {
    if (!out.isDisposed) {
      out.action.setVolume(volOut).ignore();
    }
    if (!inn.isDisposed) {
      inn.action.setVolume(volIn).ignore();
    }
  }
}
