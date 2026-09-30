/// Immutable 10-band parametric equalizer representation for miniaudio_player.
class Equalizer {
  /// Gain for 60 Hz band in dB (-24.0 to +24.0 dB, low-shelf).
  final double hz60;

  /// Gain for 170 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz170;

  /// Gain for 310 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz310;

  /// Gain for 600 Hz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz600;

  /// Gain for 1 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz1k;

  /// Gain for 3 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz3k;

  /// Gain for 6 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz6k;

  /// Gain for 12 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz12k;

  /// Gain for 14 kHz band in dB (-24.0 to +24.0 dB, peaking).
  final double hz14k;

  /// Gain for 16 kHz band in dB (-24.0 to +24.0 dB, high-shelf).
  final double hz16k;

  /// Creates an immutable [Equalizer] with optional band gains in dB (default 0.0 dB).
  const Equalizer({
    this.hz60 = 0.0,
    this.hz170 = 0.0,
    this.hz310 = 0.0,
    this.hz600 = 0.0,
    this.hz1k = 0.0,
    this.hz3k = 0.0,
    this.hz6k = 0.0,
    this.hz12k = 0.0,
    this.hz14k = 0.0,
    this.hz16k = 0.0,
  }) : assert(
         hz60 == hz60 && hz60 > -1e308 && hz60 < 1e308,
         'hz60 must be finite',
       ),
       assert(
         hz170 == hz170 && hz170 > -1e308 && hz170 < 1e308,
         'hz170 must be finite',
       ),
       assert(
         hz310 == hz310 && hz310 > -1e308 && hz310 < 1e308,
         'hz310 must be finite',
       ),
       assert(
         hz600 == hz600 && hz600 > -1e308 && hz600 < 1e308,
         'hz600 must be finite',
       ),
       assert(
         hz1k == hz1k && hz1k > -1e308 && hz1k < 1e308,
         'hz1k must be finite',
       ),
       assert(
         hz3k == hz3k && hz3k > -1e308 && hz3k < 1e308,
         'hz3k must be finite',
       ),
       assert(
         hz6k == hz6k && hz6k > -1e308 && hz6k < 1e308,
         'hz6k must be finite',
       ),
       assert(
         hz12k == hz12k && hz12k > -1e308 && hz12k < 1e308,
         'hz12k must be finite',
       ),
       assert(
         hz14k == hz14k && hz14k > -1e308 && hz14k < 1e308,
         'hz14k must be finite',
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
      hz60: gains[0],
      hz170: gains[1],
      hz310: gains[2],
      hz600: gains[3],
      hz1k: gains[4],
      hz3k: gains[5],
      hz6k: gains[6],
      hz12k: gains[7],
      hz14k: gains[8],
      hz16k: gains[9],
    );
  }

  /// Flat frequency response (all bands at 0.0 dB).
  static const Equalizer flat = Equalizer();

  /// Rock preset: boosted bass and treble with recessed mid-range.
  static const Equalizer rock = Equalizer(
    hz60: 4.5,
    hz170: 3.0,
    hz310: 1.0,
    hz600: -1.5,
    hz1k: -0.5,
    hz3k: 1.5,
    hz6k: 3.0,
    hz12k: 4.0,
    hz14k: 4.5,
    hz16k: 4.5,
  );

  /// Pop preset: enhanced mid-bass and vocal range.
  static const Equalizer pop = Equalizer(
    hz60: -1.0,
    hz170: 1.0,
    hz310: 2.5,
    hz600: 3.0,
    hz1k: 2.0,
    hz3k: 0.5,
    hz6k: -0.5,
    hz12k: -1.0,
    hz14k: -1.5,
    hz16k: -2.0,
  );

  /// Jazz preset: smooth warmth for acoustic instruments.
  static const Equalizer jazz = Equalizer(
    hz60: 3.0,
    hz170: 2.0,
    hz310: 1.0,
    hz600: 1.5,
    hz1k: -1.0,
    hz3k: -1.0,
    hz6k: 0.0,
    hz12k: 1.5,
    hz14k: 2.5,
    hz16k: 3.0,
  );

  /// Classical preset: dynamic balance with subdued harsh mids for orchestra.
  static const Equalizer classical = Equalizer(
    hz60: 4.0,
    hz170: 3.0,
    hz310: 2.0,
    hz600: 0.5,
    hz1k: -1.5,
    hz3k: -1.0,
    hz6k: 0.5,
    hz12k: 2.5,
    hz14k: 3.5,
    hz16k: 4.0,
  );

  /// Bass boost preset: elevated low-end frequencies.
  static const Equalizer bassBoost = Equalizer(
    hz60: 7.0,
    hz170: 6.0,
    hz310: 4.5,
    hz600: 0.0,
    hz1k: 0.0,
    hz3k: 0.0,
    hz6k: 0.0,
    hz12k: 0.0,
    hz14k: 0.0,
    hz16k: 0.0,
  );

  /// Returns a copy of this [Equalizer] with modified band values.
  Equalizer copyWith({
    double? hz60,
    double? hz170,
    double? hz310,
    double? hz600,
    double? hz1k,
    double? hz3k,
    double? hz6k,
    double? hz12k,
    double? hz14k,
    double? hz16k,
  }) {
    return Equalizer(
      hz60: hz60 ?? this.hz60,
      hz170: hz170 ?? this.hz170,
      hz310: hz310 ?? this.hz310,
      hz600: hz600 ?? this.hz600,
      hz1k: hz1k ?? this.hz1k,
      hz3k: hz3k ?? this.hz3k,
      hz6k: hz6k ?? this.hz6k,
      hz12k: hz12k ?? this.hz12k,
      hz14k: hz14k ?? this.hz14k,
      hz16k: hz16k ?? this.hz16k,
    );
  }

  /// Converts this [Equalizer] to an ordered 10-element list of band gains in dB.
  List<double> toList() {
    return [hz60, hz170, hz310, hz600, hz1k, hz3k, hz6k, hz12k, hz14k, hz16k];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Equalizer &&
          runtimeType == other.runtimeType &&
          hz60 == other.hz60 &&
          hz170 == other.hz170 &&
          hz310 == other.hz310 &&
          hz600 == other.hz600 &&
          hz1k == other.hz1k &&
          hz3k == other.hz3k &&
          hz6k == other.hz6k &&
          hz12k == other.hz12k &&
          hz14k == other.hz14k &&
          hz16k == other.hz16k;

  @override
  int get hashCode => Object.hash(
    hz60,
    hz170,
    hz310,
    hz600,
    hz1k,
    hz3k,
    hz6k,
    hz12k,
    hz14k,
    hz16k,
  );

  @override
  String toString() {
    return 'Equalizer(60Hz: ${hz60}dB, 170Hz: ${hz170}dB, 310Hz: ${hz310}dB, '
        '600Hz: ${hz600}dB, 1kHz: ${hz1k}dB, 3kHz: ${hz3k}dB, 6kHz: ${hz6k}dB, '
        '12kHz: ${hz12k}dB, 14kHz: ${hz14k}dB, 16kHz: ${hz16k}dB)';
  }
}
