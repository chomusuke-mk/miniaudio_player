/// Mathematical gain interpolation curves used during crossfades.
enum CrossfadeCurve {
  /// Constant-power sinusoidal and cosinusoidal curve (`cos(p * pi/2)` / `sin(p * pi/2)`).
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
/// in `MiniaudioPlayer`.
class CrossfadeConfig {
  /// The target overlap duration for automatic end-of-track transitions.
  ///
  /// Defaults to `5` seconds (`const Duration(seconds: 5)`).
  final Duration autoDuration;

  /// The target overlap duration for manual user-initiated transitions (`next`,
  /// `previous`, and `skipToIndex`) to eliminate digital clicks.
  ///
  /// Defaults to `500` milliseconds (`const Duration(milliseconds: 500)`).
  final Duration manualDuration;

  /// The gain interpolation curve applied to the outgoing and incoming decks.
  final CrossfadeCurve curve;

  /// Creates a [CrossfadeConfig] governing track crossfading transitions.
  ///
  /// Sets [autoDuration] for automatic track changes (defaults to `5` seconds),
  /// [manualDuration] for manual track changes (defaults to `500` milliseconds),
  /// and [curve] for gain curve interpolation (defaults to
  /// [CrossfadeCurve.equalPower]).
  const CrossfadeConfig({
    this.autoDuration = const Duration(seconds: 5),
    this.manualDuration = const Duration(milliseconds: 500),
    this.curve = CrossfadeCurve.equalPower,
  });

  /// Creates a disabled [CrossfadeConfig] with zero-overlap cuts.
  ///
  /// Retains the configured [curve] while setting both [autoDuration] and
  /// [manualDuration] to [Duration.zero].
  const CrossfadeConfig.off({
    this.curve = CrossfadeCurve.equalPower,
  })  : autoDuration = Duration.zero,
        manualDuration = Duration.zero;

  /// Returns a copy of this [CrossfadeConfig] with the given fields replaced.
  ///
  /// Overrides [autoDuration], [manualDuration], and [curve] when provided,
  /// preserving existing values otherwise.
  CrossfadeConfig copyWith({
    Duration? autoDuration,
    Duration? manualDuration,
    CrossfadeCurve? curve,
  }) {
    return CrossfadeConfig(
      autoDuration: autoDuration ?? this.autoDuration,
      manualDuration: manualDuration ?? this.manualDuration,
      curve: curve ?? this.curve,
    );
  }

  /// Returns `true` if [other] is a [CrossfadeConfig] with identical settings.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CrossfadeConfig &&
          runtimeType == other.runtimeType &&
          autoDuration == other.autoDuration &&
          manualDuration == other.manualDuration &&
          curve == other.curve;

  /// Returns a hash code derived from [autoDuration], [manualDuration], and
  /// [curve].
  @override
  int get hashCode => Object.hash(autoDuration, manualDuration, curve);

  /// Returns a human-readable string representation of this [CrossfadeConfig].
  @override
  String toString() =>
      'CrossfadeConfig(autoDuration: ${autoDuration.inMilliseconds}ms, '
      'manualDuration: ${manualDuration.inMilliseconds}ms, '
      'curve: ${curve.name})';
}
