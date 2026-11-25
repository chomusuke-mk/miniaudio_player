/// Immutable configuration for continuous auto-refill Infinite Mix queue replenishment.
class InfiniteMixConfig {
  /// Whether continuous auto-refill infinite mix mode is enabled.
  final bool enabled;

  /// Threshold of remaining tracks ahead in the playlist queue before replenishment triggers.
  final int remainingTracksThreshold;

  /// Creates an immutable [InfiniteMixConfig].
  ///
  /// Controls whether auto-refill is [enabled] and sets the non-negative
  /// [remainingTracksThreshold] (defaults to `2`).
  const InfiniteMixConfig({
    this.enabled = false,
    this.remainingTracksThreshold = 2,
  }) : assert(
          remainingTracksThreshold >= 0,
          'remainingTracksThreshold must be non-negative',
        );

  /// Completely disabled infinite mix mode.
  static const InfiniteMixConfig off = InfiniteMixConfig(
    enabled: false,
    remainingTracksThreshold: 2,
  );

  /// Returns a copy of this [InfiniteMixConfig] with modified parameters.
  ///
  /// Overrides [enabled] and [remainingTracksThreshold] when non-`null`.
  InfiniteMixConfig copyWith({
    bool? enabled,
    int? remainingTracksThreshold,
  }) {
    return InfiniteMixConfig(
      enabled: enabled ?? this.enabled,
      remainingTracksThreshold:
          remainingTracksThreshold ?? this.remainingTracksThreshold,
    );
  }

  /// Returns `true` if [other] is an [InfiniteMixConfig] with identical settings.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InfiniteMixConfig &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          remainingTracksThreshold == other.remainingTracksThreshold;

  /// Returns a hash code derived from [enabled] and [remainingTracksThreshold].
  @override
  int get hashCode => Object.hash(enabled, remainingTracksThreshold);

  /// Returns a human-readable string representation of this [InfiniteMixConfig].
  @override
  String toString() =>
      'InfiniteMixConfig(enabled: $enabled, remainingTracksThreshold: $remainingTracksThreshold)';
}
