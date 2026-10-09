/// Immutable snapshot of real-time audio visualizer data and frequency spectrum.
///
/// Contains energy levels across the 10 frequency bands matching the 10-band equalizer,
/// along with overall RMS, peak, and stereo (left/right) amplitude metrics.
class VisualizerData {
  /// Array of 10 normalized frequency band levels, scaled between `0.0` (silent) and `1.0` (maximum).
  ///
  /// Index mapping (ISO 266 standard):
  /// - `0`: 31 Hz (Sub-bass)
  /// - `1`: 63 Hz (Sub-bass / Bass)
  /// - `2`: 125 Hz (Bass)
  /// - `3`: 250 Hz (Low-mids)
  /// - `4`: 500 Hz (Midrange)
  /// - `5`: 1 kHz (Center-mids)
  /// - `6`: 2 kHz (High-mids / vocals)
  /// - `7`: 4 kHz (Presence)
  /// - `8`: 8 kHz (Brilliance)
  /// - `9`: 16 kHz (Air / high-shelf)
  final List<double> bands;

  /// Global root-mean-square (RMS) energy level scaled between `0.0` and `1.0`.
  ///
  /// Ideal for drawing single pulsing meters, reactive glow effects, or beat tracking.
  final double rms;

  /// Instantaneous true peak sample amplitude scaled between `0.0` and `1.0`.
  final double peak;

  /// Left channel energy level scaled between `0.0` and `1.0`.
  final double left;

  /// Right channel energy level scaled between `0.0` and `1.0`.
  final double right;

  const VisualizerData({
    required this.bands,
    required this.rms,
    required this.peak,
    required this.left,
    required this.right,
  });

  /// Creates a silent / empty visualizer data instance with all bands and levels at `0.0`.
  factory VisualizerData.empty() => VisualizerData(
        bands: List<double>.filled(10, 0.0, growable: false),
        rms: 0.0,
        peak: 0.0,
        left: 0.0,
        right: 0.0,
      );

  /// 31 Hz band (Sub-bass) normalized intensity between `0.0` and `1.0`.
  double get hz31 => bands.isNotEmpty ? bands[0] : 0.0;

  /// 63 Hz band (Sub-bass / Bass) normalized intensity between `0.0` and `1.0`.
  double get hz63 => bands.length > 1 ? bands[1] : 0.0;

  /// 125 Hz band (Bass) normalized intensity between `0.0` and `1.0`.
  double get hz125 => bands.length > 2 ? bands[2] : 0.0;

  /// 250 Hz band (Low-mids) normalized intensity between `0.0` and `1.0`.
  double get hz250 => bands.length > 3 ? bands[3] : 0.0;

  /// 500 Hz band (Midrange) normalized intensity between `0.0` and `1.0`.
  double get hz500 => bands.length > 4 ? bands[4] : 0.0;

  /// 1 kHz band (Center-mids) normalized intensity between `0.0` and `1.0`.
  double get hz1k => bands.length > 5 ? bands[5] : 0.0;

  /// 2 kHz band (High-mids / vocals) normalized intensity between `0.0` and `1.0`.
  double get hz2k => bands.length > 6 ? bands[6] : 0.0;

  /// 4 kHz band (Presence) normalized intensity between `0.0` and `1.0`.
  double get hz4k => bands.length > 7 ? bands[7] : 0.0;

  /// 8 kHz band (Brilliance) normalized intensity between `0.0` and `1.0`.
  double get hz8k => bands.length > 8 ? bands[8] : 0.0;

  /// 16 kHz band (Air / high-shelf) normalized intensity between `0.0` and `1.0`.
  double get hz16k => bands.length > 9 ? bands[9] : 0.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisualizerData &&
          runtimeType == other.runtimeType &&
          rms == other.rms &&
          peak == other.peak &&
          left == other.left &&
          right == other.right &&
          _listEquals(bands, other.bands);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(bands),
        rms,
        peak,
        left,
        right,
      );

  @override
  String toString() =>
      'VisualizerData(rms: ${rms.toStringAsFixed(2)}, peak: ${peak.toStringAsFixed(2)}, '
      'left: ${left.toStringAsFixed(2)}, right: ${right.toStringAsFixed(2)}, '
      'bands: [${bands.map((b) => b.toStringAsFixed(2)).join(', ')}])';

  static bool _listEquals(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
