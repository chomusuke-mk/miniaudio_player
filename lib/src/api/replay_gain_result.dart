import 'dart:math' as math;

/// Immutable representation of the calculated ReplayGain and Loudness
/// according to the ITU-R BS.1770-4 / EBU R128 international standard.
class ReplayGainResult {
  /// Recommended gain adjustment in decibels (dB) relative to the target LUFS.
  ///
  /// Positive values indicate the track is quieter than the target and should be boosted.
  /// Negative values indicate the track is louder than the target and should be attenuated.
  final double gainDb;

  /// Absolute peak sample amplitude (where `1.0` represents 0 dBFS / digital full scale).
  final double peak;

  /// Integrated perceived loudness of the audio track measured in LUFS (LKFS).
  final double lufs;

  const ReplayGainResult({
    required this.gainDb,
    required this.peak,
    required this.lufs,
  });

  /// Recommended linear volume multiplier ready to be passed to `player.action.setVolume()`.
  ///
  /// Converts [gainDb] from logarithmic decibels to linear amplitude scale: `10^(gainDb / 20)`.
  ///
  /// If [preventClipping] is `true` (the default), this scales down the gain to `1.0 / peak`
  /// if the boosted peak would otherwise exceed `1.0` (0 dBFS), preventing harsh digital clipping.
  double getRecommendedVolume({bool preventClipping = true}) {
    final rawFactor = math.pow(10.0, gainDb / 20.0).toDouble();
    if (preventClipping && peak > 0.0 && rawFactor * peak > 1.0) {
      return 1.0 / peak;
    }
    return rawFactor;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReplayGainResult &&
          runtimeType == other.runtimeType &&
          gainDb == other.gainDb &&
          peak == other.peak &&
          lufs == other.lufs;

  @override
  int get hashCode => Object.hash(gainDb, peak, lufs);

  @override
  String toString() =>
      'ReplayGainResult(gainDb: ${gainDb.toStringAsFixed(2)} dB, peak: ${peak.toStringAsFixed(4)}, lufs: ${lufs.toStringAsFixed(2)} LUFS)';
}
