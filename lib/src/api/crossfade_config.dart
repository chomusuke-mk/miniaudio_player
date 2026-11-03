/// Mathematical gain interpolation curves used during crossfades.
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
/// in [MiniaudioPlayer].
class CrossfadeConfig {
  /// Target overlap duration for automatic end-of-track transitions.
  ///
  /// Defaults to 5 seconds (`const Duration(seconds: 5)`).
  final Duration autoDuration;

  /// Target overlap duration for manual user-initiated transitions (`next`,
  /// `previous`, `skipToIndex`) to eliminate digital clicks.
  ///
  /// Defaults to 500 milliseconds (`const Duration(milliseconds: 500)`).
  final Duration manualDuration;

  /// Gain interpolation curve applied to the outgoing and incoming decks.
  final CrossfadeCurve curve;

  /// Creates a [CrossfadeConfig] governing track crossfading transitions.
  ///
  /// - [autoDuration]: overlap duration for automatic track changes (default: 5 seconds).
  /// - [manualDuration]: overlap duration for manual track changes (default: 500 milliseconds).
  /// - [curve]: gain curve interpolation (default: [CrossfadeCurve.equalPower]).
  const CrossfadeConfig({
    this.autoDuration = const Duration(seconds: 5),
    this.manualDuration = const Duration(milliseconds: 500),
    this.curve = CrossfadeCurve.equalPower,
  });

  /// Creates a disabled [CrossfadeConfig] (instant zero-overlap cuts).
  const CrossfadeConfig.off({
    this.curve = CrossfadeCurve.equalPower,
  })  : autoDuration = Duration.zero,
        manualDuration = Duration.zero;

  /// Returns a copy of this configuration with the given fields replaced.
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CrossfadeConfig &&
          runtimeType == other.runtimeType &&
          autoDuration == other.autoDuration &&
          manualDuration == other.manualDuration &&
          curve == other.curve;

  @override
  int get hashCode => Object.hash(autoDuration, manualDuration, curve);

  @override
  String toString() =>
      'CrossfadeConfig(autoDuration: ${autoDuration.inMilliseconds}ms, '
      'manualDuration: ${manualDuration.inMilliseconds}ms, '
      'curve: ${curve.name})';
}
