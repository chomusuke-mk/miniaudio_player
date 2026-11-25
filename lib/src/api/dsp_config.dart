/// Operational modes for ReplayGain and EBU R128 loudness processing in the engine.
enum ReplayGainMode {
  /// Disables volume normalization and applies unity gain (`0.0` dB).
  disabled,

  /// Automatically applies per-track ReplayGain metadata from the audio source.
  ///
  /// Falls back to the player's default ReplayGain when no per-track metadata
  /// is specified on the item.
  track,

  /// Forces a uniform global gain across all items, ignoring per-track metadata.
  forced,
}

/// Immutable configuration of track ReplayGain and EBU R128 loudness normalization metadata.
class ReplayGainConfig {
  /// The track gain in decibels relative to the target LUFS (for example, `-6.5`).
  final double gainDb;

  /// The peak amplitude of the track, where `1.0` represents `0` dBFS.
  final double peak;

  /// Creates an immutable [ReplayGainConfig] with gain adjustment and peak amplitude.
  ///
  /// Uses [gainDb] (defaults to `0.0` dB) and [peak] (defaults to `1.0`).
  const ReplayGainConfig({
    this.gainDb = 0.0,
    this.peak = 1.0,
  });

  /// Default unity gain configuration (`0.0` dB gain and `1.0` peak).
  static const ReplayGainConfig unity =
      ReplayGainConfig(gainDb: 0.0, peak: 1.0);

  /// Returns `true` if [other] is a [ReplayGainConfig] with identical [gainDb]
  /// and [peak] values.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReplayGainConfig &&
          runtimeType == other.runtimeType &&
          gainDb == other.gainDb &&
          peak == other.peak;

  /// Returns a hash code derived from [gainDb] and [peak].
  @override
  int get hashCode => Object.hash(gainDb, peak);

  /// Returns a human-readable string representation of this [ReplayGainConfig].
  @override
  String toString() => 'ReplayGainConfig(gainDb: ${gainDb}dB, peak: $peak)';
}
