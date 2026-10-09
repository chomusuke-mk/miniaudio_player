/// Immutable 10-band parametric equalizer representation for miniaudio_player.
/// Follows the ISO 266 standard preferred 1/1 octave band center frequencies:
/// 31 Hz, 63 Hz, 125 Hz, 250 Hz, 500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz, 16 kHz.
class Equalizer {
  /// Gain for 31 Hz band in dB (-24.0 to +24.0 dB, low-shelf).
  final double hz31;

  /// Gain for 63 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz63;

  /// Gain for 125 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz125;

  /// Gain for 250 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz250;

  /// Gain for 500 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz500;

  /// Gain for 1 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz1k;

  /// Gain for 2 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz2k;

  /// Gain for 4 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz4k;

  /// Gain for 8 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz8k;

  /// Gain for 16 kHz band in dB (-24.0 to +24.0 dB, high-shelf).
  final double hz16k;

  /// Creates an immutable [Equalizer] with optional band gains in dB (default 0.0 dB).
  const Equalizer({
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

  /// Factory constructor to create an [Equalizer] from an ordered 10-element list.
  factory Equalizer.fromList(List<double> gains) {
    if (gains.length < 10) {
      throw ArgumentError.value(
        gains.length,
        'gains.length',
        'Expected exactly 10 band gains',
      );
    }
    return Equalizer(
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

  /// Flat frequency response (all bands at 0.0 dB).
  static const Equalizer flat = Equalizer();

  /// Rock preset: boosted bass and treble with recessed mid-range.
  static const Equalizer rock = Equalizer(
    hz31: 5.4,
    hz63: 4.5,
    hz125: -3.6,
    hz250: -6.6,
    hz500: -2.7,
    hz1k: 2.1,
    hz2k: 6.0,
    hz4k: 7.5,
    hz8k: 7.8,
    hz16k: 8.1,
  );

  /// Pop preset: enhanced mid-bass and vocal range.
  static const Equalizer pop = Equalizer(
    hz31: -1.6,
    hz63: 0.6,
    hz125: 5.4,
    hz250: 4.5,
    hz500: 0.9,
    hz1k: -1.5,
    hz2k: -1.8,
    hz4k: -2.1,
    hz8k: -2.1,
    hz16k: -0.3,
  );

  /// Jazz preset: smooth warmth for acoustic instruments.
  static const Equalizer jazz = Equalizer(
    hz31: 3.0,
    hz63: 6.3,
    hz125: 3.6,
    hz250: -3.9,
    hz500: -5.1,
    hz1k: 1.2,
    hz2k: 9.0,
    hz4k: -1.8,
    hz8k: -2.4,
    hz16k: 2.5,
  );

  /// Classical preset: dynamic balance with subdued harsh mids for orchestra.
  static const Equalizer classical = Equalizer(
    hz31: 0.0,
    hz63: 0.0,
    hz125: 0.0,
    hz250: 0.0,
    hz500: 0.0,
    hz1k: 0.0,
    hz2k: 0.0,
    hz4k: -2.9,
    hz8k: -5.8,
    hz16k: -8.1,
  );

  /// Bass boost preset: elevated low-end frequencies.
  static const Equalizer bassBoost = Equalizer(
    hz31: 7.4,
    hz63: 7.2,
    hz125: 7.2,
    hz250: 4.2,
    hz500: -0.3,
    hz1k: -3.0,
    hz2k: -4.5,
    hz4k: -6.0,
    hz8k: -7.2,
    hz16k: -9.0,
  );

  /// Returns a copy of this [Equalizer] with modified band values.
  Equalizer copyWith({
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

  /// Converts this [Equalizer] to an ordered 10-element list of band gains in dB.
  List<double> toList() {
    return [hz31, hz63, hz125, hz250, hz500, hz1k, hz2k, hz4k, hz8k, hz16k];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Equalizer &&
          runtimeType == other.runtimeType &&
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

  @override
  int get hashCode => Object.hash(
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

  @override
  String toString() {
    return 'Equalizer(31Hz: ${hz31}dB, 63Hz: ${hz63}dB, 125Hz: ${hz125}dB, '
        '250Hz: ${hz250}dB, 500Hz: ${hz500}dB, 1kHz: ${hz1k}dB, 2kHz: ${hz2k}dB, '
        '4kHz: ${hz4k}dB, 8kHz: ${hz8k}dB, 16kHz: ${hz16k}dB)';
  }
}
