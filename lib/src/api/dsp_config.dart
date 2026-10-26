/// Operational modes for Bauer stereophonic-to-binaural (bs2b) crossfeed.
enum CrossfeedMode {
  /// Crossfeed processing disabled.
  off,

  /// Default Moffat-Bauer standard crossfeed (700 Hz cut-off, 4.5 dB feed).
  moffatBauer,

  /// Suttle Chu Moy crossfeed curve (700 Hz cut-off, 6.0 dB feed).
  chuMoy,
}

/// Operational modes for ReplayGain / EBU R128 loudness processing in the engine.
enum ReplayGainMode {
  /// Volume normalization is disabled (unity gain 0.0 dB).
  disabled,

  /// Automatically applies per-track ReplayGain metadata from EngineItem,
  /// falling back to defaultReplayGain if not specified on the item.
  track,

  /// Forces a uniform global gain across all items, ignoring individual metadata.
  forced,
}

/// Immutable configuration of active ReplayGain / EBU R128 track normalization.
class ReplayGainConfig {
  /// Track gain in decibels relative to target LUFS (e.g. `-13.3`).
  final double gainDb;

  /// Peak amplitude of the track (where 1.0 = 0 dBFS).
  final double peak;

  /// Whether clipping defense is active (capping linear factor to `1.0 / peak`).
  final bool preventClipping;

  /// Whether ReplayGain is actively applied or bypassed.
  final bool enabled;

  const ReplayGainConfig({
    this.gainDb = 0.0,
    this.peak = 0.0,
    this.preventClipping = true,
    this.enabled = false,
  });

  /// Effective decibel gain applied if enabled (`gainDb` when active, `0.0` if bypassed).
  double get effectiveGainDb => enabled ? gainDb : 0.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReplayGainConfig &&
          runtimeType == other.runtimeType &&
          gainDb == other.gainDb &&
          peak == other.peak &&
          preventClipping == other.preventClipping &&
          enabled == other.enabled;

  @override
  int get hashCode => Object.hash(gainDb, peak, preventClipping, enabled);

  @override
  String toString() =>
      'ReplayGainConfig(enabled: $enabled, gainDb: $gainDb, peak: $peak, preventClipping: $preventClipping)';
}
