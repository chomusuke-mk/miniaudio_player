/// Immutable Bauer Stereophonic-to-Binaural (BS2B) crossfeed filter configuration.
///
/// Reduces headphone listening fatigue by simulating the natural cross-acoustic
/// blending of left and right stereo channels as experienced in physical loudspeaker spaces.
class Crossfeed {
  /// Whether crossfeed processing is actively applied.
  final bool enabled;

  /// Lowpass cutoff frequency in Hertz (typically `300.0` Hz to `2000.0` Hz).
  final double cutoffHz;

  /// Crossfeed feed level in decibels (typically `1.0` dB to `15.0` dB).
  final double feedDb;

  /// Creates an immutable [Crossfeed] configuration.
  ///
  /// Configures whether processing is [enabled], the lowpass [cutoffHz]
  /// (`300.0` to `2000.0` Hz), and the crossfeed [feedDb] (`1.0` to `15.0` dB).
  const Crossfeed({
    this.enabled = false,
    this.cutoffHz = 700.0,
    this.feedDb = 4.5,
  })  : assert(cutoffHz >= 300.0 && cutoffHz <= 2000.0,
            'cutoffHz must be between 300.0 and 2000.0'),
        assert(feedDb >= 1.0 && feedDb <= 15.0,
            'feedDb must be between 1.0 and 15.0');

  /// Completely disabled and bypassed crossfeed effect.
  static const Crossfeed off = Crossfeed(
    enabled: false,
    cutoffHz: 700.0,
    feedDb: 4.5,
  );

  /// Moffat-Bauer standard crossfeed curve (`700` Hz cutoff, `4.5` dB feed).
  ///
  /// Provides the standard BS2B curve for natural stereo blending during
  /// general headphone listening.
  static const Crossfeed moffatBauer = Crossfeed(
    enabled: true,
    cutoffHz: 700.0,
    feedDb: 4.5,
  );

  /// Chu Moy classic headphone crossfeed curve (`700` Hz cutoff, `6.0` dB feed).
  ///
  /// Provides a slightly stronger crossfeed effect popular in DIY headphone
  /// amplifiers.
  static const Crossfeed chuMoy = Crossfeed(
    enabled: true,
    cutoffHz: 700.0,
    feedDb: 6.0,
  );

  /// Returns a copy of this [Crossfeed] with modified parameters.
  ///
  /// Replaces [enabled], [cutoffHz], and [feedDb] when non-`null`.
  Crossfeed copyWith({
    bool? enabled,
    double? cutoffHz,
    double? feedDb,
  }) {
    return Crossfeed(
      enabled: enabled ?? this.enabled,
      cutoffHz: cutoffHz ?? this.cutoffHz,
      feedDb: feedDb ?? this.feedDb,
    );
  }

  /// Returns `true` if [other] is a [Crossfeed] with identical settings.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Crossfeed &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          cutoffHz == other.cutoffHz &&
          feedDb == other.feedDb;

  /// Returns a hash code derived from [enabled], [cutoffHz], and [feedDb].
  @override
  int get hashCode => Object.hash(enabled, cutoffHz, feedDb);

  /// Returns a human-readable string representation of this [Crossfeed].
  @override
  String toString() =>
      'Crossfeed(enabled: $enabled, cutoffHz: $cutoffHz, feedDb: $feedDb)';
}
