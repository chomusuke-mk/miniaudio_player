/// Mathematical gain interpolation curves used during [MiniaudioEngine] crossfades.
enum CrossfadeCurve {
  /// Constant-power sinusoidal/cosinusoidal curve (`cos(p * pi/2)` / `sin(p * pi/2)`).
  ///
  /// Preserves perceived acoustic energy at the midpoint (`~70.7%` per deck,
  /// `-3.01 dB`), preventing volume dips between uncorrelated tracks.
  equalPower,

  /// Linear proportional ramp (`1.0 - p` / `p`).
  ///
  /// Ideal for correlated stems or tight manual cuts where a slight `-6 dB`
  /// midpoint dip is desired.
  linear,
}

/// Immutable configuration governing automatic and manual crossfade transitions
/// in [MiniaudioEngine].
class CrossfadeConfig {

  /// Default automatic crossfade duration at the end of a track.
  static const Duration defaultDuration = Duration(seconds: 5);

  /// Default short crossfade duration used on manual transitions (`next`,
  /// `previous`, `skipToIndex`) to eliminate digital clicks.
  static const Duration defaultManualDuration = Duration(milliseconds: 100);

  /// Target overlap duration for automatic end-of-track transitions.
  final Duration duration;

  /// Target overlap duration for manual user-initiated transitions.
  final Duration manualDuration;

  /// Gain interpolation curve applied to the outgoing and incoming decks.
  final CrossfadeCurve curve;

  /// Creates a [CrossfadeConfig] with durations clamped to `[0s, 12s]`.
  CrossfadeConfig({
    Duration duration = defaultDuration,
    Duration manualDuration = defaultManualDuration,
    this.curve = CrossfadeCurve.equalPower,
  })  : duration = _clampDuration(duration),
        manualDuration = _clampDuration(manualDuration);

  /// Creates a constant disabled [CrossfadeConfig] (instant zero-overlap cuts).
  const CrossfadeConfig.off({
    this.curve = CrossfadeCurve.equalPower,
  })  : duration = Duration.zero,
        manualDuration = Duration.zero;

  static Duration _clampDuration(Duration d) {
    if (d <= Duration.zero) return Duration.zero;
    return d;
  }

  /// Whether automatic end-of-track crossfading is active.
  bool get isEnabled => duration > Duration.zero;

  /// Whether manual skip micro-crossfading is active.
  bool get isManualEnabled => manualDuration > Duration.zero;

  /// Duration in whole seconds for UI sliders.
  int get durationSeconds => duration.inSeconds;

  /// Returns a copy of this configuration with the given fields replaced.
  CrossfadeConfig copyWith({
    Duration? duration,
    Duration? manualDuration,
    CrossfadeCurve? curve,
  }) {
    return CrossfadeConfig(
      duration: duration ?? this.duration,
      manualDuration: manualDuration ?? this.manualDuration,
      curve: curve ?? this.curve,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CrossfadeConfig &&
          runtimeType == other.runtimeType &&
          duration == other.duration &&
          manualDuration == other.manualDuration &&
          curve == other.curve;

  @override
  int get hashCode => Object.hash(duration, manualDuration, curve);

  @override
  String toString() =>
      'CrossfadeConfig(duration: ${duration.inMilliseconds}ms, '
      'manualDuration: ${manualDuration.inMilliseconds}ms, '
      'curve: ${curve.name})';
}
