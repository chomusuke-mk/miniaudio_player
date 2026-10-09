/// Operational modes for Bauer stereophonic-to-binaural (bs2b) crossfeed.
enum CrossfeedMode {
  /// Crossfeed processing disabled.
  off,

  /// Default Moffat-Bauer standard crossfeed (700 Hz cut-off, 4.5 dB feed).
  moffatBauer,

  /// Suttle Chu Moy crossfeed curve (700 Hz cut-off, 6.0 dB feed).
  chuMoy,
}

/// Immutable configuration of active ReplayGain / EBU R128 track normalization.
class ReplayGainConfig {
  /// Track gain in decibels relative to target LUFS (e.g. `-13.3`).
  final double gainDb;

  /// Peak amplitude of the track (where 1.0 = 0 dBFS).
  final double peak;

  /// Additional user preamp adjustment in decibels.
  final double preampDb;

  /// Whether clipping defense is active (capping linear factor to `1.0 / peak`).
  final bool preventClipping;

  /// Whether ReplayGain is actively applied or bypassed.
  final bool enabled;

  const ReplayGainConfig({
    this.gainDb = 0.0,
    this.peak = 0.0,
    this.preampDb = 0.0,
    this.preventClipping = true,
    this.enabled = false,
  });

  /// Total combined decibel target (gainDb + preampDb).
  double get totalGainDb => enabled ? (gainDb + preampDb) : preampDb;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReplayGainConfig &&
          runtimeType == other.runtimeType &&
          gainDb == other.gainDb &&
          peak == other.peak &&
          preampDb == other.preampDb &&
          preventClipping == other.preventClipping &&
          enabled == other.enabled;

  @override
  int get hashCode => Object.hash(gainDb, peak, preampDb, preventClipping, enabled);

  @override
  String toString() =>
      'ReplayGainConfig(enabled: $enabled, gainDb: $gainDb, peak: $peak, preampDb: $preampDb, preventClipping: $preventClipping)';
}
