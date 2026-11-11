/// Operational modes for ReplayGain / EBU R128 loudness processing in the engine.
enum ReplayGainMode {
  /// Volume normalization is disabled (unity gain 0.0 dB).
  disabled,

  /// Automatically applies per-track ReplayGain metadata from AudioSource,
  /// falling back to defaultReplayGain if not specified on the item.
  track,

  /// Forces a uniform global gain across all items, ignoring individual metadata.
  forced,
}

/// Immutable configuration of track ReplayGain / EBU R128 loudness normalization metadata.
class ReplayGainConfig {
  /// The track gain in decibels relative to target LUFS (e.g. `-6.5`).
  final double gainDb;

  /// The peak amplitude of the track (where `1.0` represents 0 dBFS).
  final double peak;

  /// Creates an immutable [ReplayGainConfig] with gain adjustment and peak amplitude.
  const ReplayGainConfig({
    this.gainDb = 0.0,
    this.peak = 1.0,
  });

  /// Default unity gain config (0.0 dB, 1.0 peak).
  static const ReplayGainConfig unity =
      ReplayGainConfig(gainDb: 0.0, peak: 1.0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReplayGainConfig &&
          runtimeType == other.runtimeType &&
          gainDb == other.gainDb &&
          peak == other.peak;

  @override
  int get hashCode => Object.hash(gainDb, peak);

  @override
  String toString() => 'ReplayGainConfig(gainDb: ${gainDb}dB, peak: $peak)';
}
