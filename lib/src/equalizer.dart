import 'api/logger.dart';

/// Immutable 10-band parametric equalizer representation for `miniaudio_player`.
///
/// Follows the ISO 266 standard preferred 1/1 octave band center frequencies:
/// `31` Hz, `63` Hz, `125` Hz, `250` Hz, `500` Hz, `1` kHz, `2` kHz, `4` kHz,
/// `8` kHz, and `16` kHz.
class Equalizer {
  /// Whether the equalizer DSP stage is actively applied.
  final bool enabled;

  /// The gain for the `31` Hz band in decibels (dB).
  final double hz31;

  /// The gain for the `63` Hz band in decibels (dB).
  final double hz63;

  /// The gain for the `125` Hz band in decibels (dB).
  final double hz125;

  /// The gain for the `250` Hz band in decibels (dB).
  final double hz250;

  /// The gain for the `500` Hz band in decibels (dB).
  final double hz500;

  /// The gain for the `1` kHz band in decibels (dB).
  final double hz1k;

  /// The gain for the `2` kHz band in decibels (dB).
  final double hz2k;

  /// The gain for the `4` kHz band in decibels (dB).
  final double hz4k;

  /// The gain for the `8` kHz band in decibels (dB).
  final double hz8k;

  /// The gain for the `16` kHz band in decibels (dB).
  final double hz16k;

  /// Creates an immutable [Equalizer] with optional band gains in decibels.
  ///
  /// Configures whether the stage is [enabled] and sets gains for [hz31],
  /// [hz63], [hz125], [hz250], [hz500], [hz1k], [hz2k], [hz4k], [hz8k], and
  /// [hz16k] (all defaulting to `0.0` dB).
  const Equalizer({
    this.enabled = true,
    this.hz31 = 0.0,
    this.hz63 = 0.0,
    this.hz125 = 0.0,
    this.hz250 = 0.0,
    this.hz500 = 0.0,
    this.hz1k = 0.0,
    this.hz2k = 0.0,
    this.hz4k = 0.0,
    this.hz8k = 0.0,
    this.hz16k = 0.0,
  })  : assert(
          hz31 == hz31 && hz31 > -1e308 && hz31 < 1e308,
          'hz31 must be finite',
        ),
        assert(
          hz63 == hz63 && hz63 > -1e308 && hz63 < 1e308,
          'hz63 must be finite',
        ),
        assert(
          hz125 == hz125 && hz125 > -1e308 && hz125 < 1e308,
          'hz125 must be finite',
        ),
        assert(
          hz250 == hz250 && hz250 > -1e308 && hz250 < 1e308,
          'hz250 must be finite',
        ),
        assert(
          hz500 == hz500 && hz500 > -1e308 && hz500 < 1e308,
          'hz500 must be finite',
        ),
        assert(
          hz1k == hz1k && hz1k > -1e308 && hz1k < 1e308,
          'hz1k must be finite',
        ),
        assert(
          hz2k == hz2k && hz2k > -1e308 && hz2k < 1e308,
          'hz2k must be finite',
        ),
        assert(
          hz4k == hz4k && hz4k > -1e308 && hz4k < 1e308,
          'hz4k must be finite',
        ),
        assert(
          hz8k == hz8k && hz8k > -1e308 && hz8k < 1e308,
          'hz8k must be finite',
        ),
        assert(
          hz16k == hz16k && hz16k > -1e308 && hz16k < 1e308,
          'hz16k must be finite',
        );

  /// Creates an [Equalizer] from an ordered 10-element [gains] list.
  ///
  /// Sets whether the equalizer is [enabled] and maps the first ten entries of
  /// [gains] to bands `31` Hz through `16` kHz. Throws an [ArgumentError] if
  /// [gains] contains fewer than `10` elements.
  factory Equalizer.fromList(List<double> gains, {bool enabled = true}) {
    if (gains.length < 10) {
      MapLogger.error(
        'Equalizer.fromList() requires 10 band gains, got ${gains.length}',
      );
      throw ArgumentError.value(
        gains.length,
        'gains.length',
        'Expected exactly 10 band gains',
      );
    }
    return Equalizer(
      enabled: enabled,
      hz31: gains[0],
      hz63: gains[1],
      hz125: gains[2],
      hz250: gains[3],
      hz500: gains[4],
      hz1k: gains[5],
      hz2k: gains[6],
      hz4k: gains[7],
      hz8k: gains[8],
      hz16k: gains[9],
    );
  }

  /// Completely disabled and bypassed equalizer stage.
  static const Equalizer off = Equalizer(enabled: false);

  /// Flat frequency response with all bands at `0.0` dB.
  static const Equalizer flat = Equalizer(enabled: true);

  /// Rock preset with boosted bass and treble and recessed mid-range.
  static const Equalizer rock = Equalizer(
    enabled: true,
    hz31: 4.5,
    hz63: 3.5,
    hz125: 2.0,
    hz250: 0.5,
    hz500: -1.0,
    hz1k: -0.5,
    hz2k: 1.5,
    hz4k: 3.0,
    hz8k: 4.0,
    hz16k: 4.5,
  );

  /// Pop preset with enhanced mid-bass and vocal presence.
  static const Equalizer pop = Equalizer(
    enabled: true,
    hz31: -1.5,
    hz63: -0.5,
    hz125: 1.5,
    hz250: 3.0,
    hz500: 3.5,
    hz1k: 2.5,
    hz2k: 0.5,
    hz4k: -1.0,
    hz8k: -1.5,
    hz16k: -2.0,
  );

  /// Jazz preset providing smooth warmth for acoustic instruments.
  static const Equalizer jazz = Equalizer(
    enabled: true,
    hz31: 3.5,
    hz63: 2.5,
    hz125: 1.0,
    hz250: 1.5,
    hz500: -1.0,
    hz1k: -1.0,
    hz2k: 0.5,
    hz4k: 1.5,
    hz8k: 2.5,
    hz16k: 3.5,
  );

  /// Classical preset offering dynamic balance with subdued harsh mids.
  static const Equalizer classical = Equalizer(
    enabled: true,
    hz31: 4.0,
    hz63: 3.0,
    hz125: 2.0,
    hz250: 1.5,
    hz500: -1.0,
    hz1k: -1.0,
    hz2k: 0.0,
    hz4k: -1.5,
    hz8k: -2.0,
    hz16k: -2.5,
  );

  /// Bass boost preset with elevated low-end frequencies.
  static const Equalizer bassBoost = Equalizer(
    enabled: true,
    hz31: 7.0,
    hz63: 6.0,
    hz125: 5.0,
    hz250: 3.0,
    hz500: 1.0,
    hz1k: 0.0,
    hz2k: 0.0,
    hz4k: 0.0,
    hz8k: 0.0,
    hz16k: 0.0,
  );

  /// Returns a copy of this [Equalizer] with modified band values.
  ///
  /// Replaces [enabled], [hz31], [hz63], [hz125], [hz250], [hz500], [hz1k],
  /// [hz2k], [hz4k], [hz8k], and [hz16k] when non-`null`.
  Equalizer copyWith({
    bool? enabled,
    double? hz31,
    double? hz63,
    double? hz125,
    double? hz250,
    double? hz500,
    double? hz1k,
    double? hz2k,
    double? hz4k,
    double? hz8k,
    double? hz16k,
  }) {
    return Equalizer(
      enabled: enabled ?? this.enabled,
      hz31: hz31 ?? this.hz31,
      hz63: hz63 ?? this.hz63,
      hz125: hz125 ?? this.hz125,
      hz250: hz250 ?? this.hz250,
      hz500: hz500 ?? this.hz500,
      hz1k: hz1k ?? this.hz1k,
      hz2k: hz2k ?? this.hz2k,
      hz4k: hz4k ?? this.hz4k,
      hz8k: hz8k ?? this.hz8k,
      hz16k: hz16k ?? this.hz16k,
    );
  }

  /// Minimum supported band gain in decibels (`-24.0` dB).
  static const double minGainDb = -24.0;

  /// Maximum supported band gain in decibels (`+24.0` dB).
  static const double maxGainDb = 24.0;

  /// Clamps [gainDb] to the supported range between [minGainDb] and [maxGainDb].
  static double clampGain(double gainDb) => gainDb.clamp(minGainDb, maxGainDb);

  /// Returns a new [Equalizer] with the band at [index] (`0..9`) updated to [gainDb].
  ///
  /// Clamps [gainDb] via [clampGain] and throws a [RangeError] if [index] is
  /// outside `0..9`.
  Equalizer withBand(int index, double gainDb) {
    if (index < 0 || index >= 10) {
      MapLogger.error(
        'Equalizer.withBand() index out of range: $index (expected 0..9)',
      );
      throw RangeError.range(index, 0, 9, 'index');
    }
    final bands = toList();
    bands[index] = clampGain(gainDb);
    return Equalizer.fromList(bands, enabled: enabled);
  }

  /// Converts this [Equalizer] to an ordered 10-element list of band gains in dB.
  List<double> toList() {
    return [hz31, hz63, hz125, hz250, hz500, hz1k, hz2k, hz4k, hz8k, hz16k];
  }

  /// Returns `true` if [other] is an [Equalizer] with identical band gains and
  /// enabled state.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Equalizer &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          hz31 == other.hz31 &&
          hz63 == other.hz63 &&
          hz125 == other.hz125 &&
          hz250 == other.hz250 &&
          hz500 == other.hz500 &&
          hz1k == other.hz1k &&
          hz2k == other.hz2k &&
          hz4k == other.hz4k &&
          hz8k == other.hz8k &&
          hz16k == other.hz16k;

  /// Returns a hash code derived from [enabled] and all ten frequency bands.
  @override
  int get hashCode => Object.hash(
        enabled,
        hz31,
        hz63,
        hz125,
        hz250,
        hz500,
        hz1k,
        hz2k,
        hz4k,
        hz8k,
        hz16k,
      );

  /// Returns a human-readable string representation of this [Equalizer].
  @override
  String toString() {
    return 'Equalizer(enabled: $enabled, 31Hz: ${hz31}dB, 63Hz: ${hz63}dB, 125Hz: ${hz125}dB, '
        '250Hz: ${hz250}dB, 500Hz: ${hz500}dB, 1kHz: ${hz1k}dB, 2kHz: ${hz2k}dB, '
        '4kHz: ${hz4k}dB, 8kHz: ${hz8k}dB, 16kHz: ${hz16k}dB)';
  }
}
