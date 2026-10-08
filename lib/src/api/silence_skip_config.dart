import '../../miniaudio_player_bindings_generated.dart' as native;

/// Operational modes for silence detection and skipping.
enum SilenceSkipMode {
  /// Silence skipping is disabled (standard playback).
  disabled(0),

  /// Trims lead-in silence (at track start) and lead-out silence (at track end).
  /// Middle pauses are preserved. Ideal for music.
  trimEdges(1),

  /// Dynamically truncates / skips continuous pauses anywhere in the track.
  /// Ideal for podcasts, audiobooks, and talk shows.
  continuous(2),

  /// Applies both: trims start/end edges and skips in-between pauses.
  all(3);

  final int value;
  const SilenceSkipMode(this.value);

  /// Converts a native integer mode to [SilenceSkipMode].
  static SilenceSkipMode fromValue(int value) => switch (value) {
        0 => SilenceSkipMode.disabled,
        1 => SilenceSkipMode.trimEdges,
        2 => SilenceSkipMode.continuous,
        3 => SilenceSkipMode.all,
        _ => SilenceSkipMode.disabled,
      };
}

/// Configuration settings for dynamic silence detection and skipping.
class SilenceSkipConfig {
  /// Operational mode of the silence detector.
  final SilenceSkipMode mode;

  /// Silence threshold in decibels full-scale (dBFS).
  ///
  /// Signals below this level are considered silence.
  /// Typical range is `-60.0` to `-30.0` dBFS (default: `-45.0`).
  final double thresholdDb;

  /// Minimum continuous silence duration required before triggering skipping.
  ///
  /// Natural pauses shorter than this are kept intact.
  /// Default: 300 ms.
  final Duration minSilenceDuration;

  /// Safety margin preserved before and after non-silent audio to prevent clipping word edges.
  ///
  /// Default: 50 ms.
  final Duration padding;

  const SilenceSkipConfig({
    this.mode = SilenceSkipMode.disabled,
    this.thresholdDb = -45.0,
    this.minSilenceDuration = const Duration(milliseconds: 300),
    this.padding = const Duration(milliseconds: 50),
  });

  /// Convenience constructor for edge trimming only (music / gapless).
  const SilenceSkipConfig.trimEdges({
    double thresholdDb = -45.0,
    Duration minSilenceDuration = const Duration(milliseconds: 300),
    Duration padding = const Duration(milliseconds: 50),
  }) : this(
          mode: SilenceSkipMode.trimEdges,
          thresholdDb: thresholdDb,
          minSilenceDuration: minSilenceDuration,
          padding: padding,
        );

  /// Convenience constructor for continuous silence skipping (podcast mode).
  const SilenceSkipConfig.continuous({
    double thresholdDb = -45.0,
    Duration minSilenceDuration = const Duration(milliseconds: 300),
    Duration padding = const Duration(milliseconds: 50),
  }) : this(
          mode: SilenceSkipMode.continuous,
          thresholdDb: thresholdDb,
          minSilenceDuration: minSilenceDuration,
          padding: padding,
        );

  /// Convenience constructor for enabling all silence skipping (edges + continuous).
  const SilenceSkipConfig.all({
    double thresholdDb = -45.0,
    Duration minSilenceDuration = const Duration(milliseconds: 300),
    Duration padding = const Duration(milliseconds: 50),
  }) : this(
          mode: SilenceSkipMode.all,
          thresholdDb: thresholdDb,
          minSilenceDuration: minSilenceDuration,
          padding: padding,
        );

  /// Creates a copy with the given fields replaced.
  SilenceSkipConfig copyWith({
    SilenceSkipMode? mode,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) {
    return SilenceSkipConfig(
      mode: mode ?? this.mode,
      thresholdDb: thresholdDb ?? this.thresholdDb,
      minSilenceDuration: minSilenceDuration ?? this.minSilenceDuration,
      padding: padding ?? this.padding,
    );
  }

  /// Creates a [SilenceSkipConfig] from native struct fields.
  factory SilenceSkipConfig.fromNative(
    native.miniaudio_player_silence_config_t nativeConfig,
  ) {
    return SilenceSkipConfig(
      mode: SilenceSkipMode.fromValue(nativeConfig.mode),
      thresholdDb: nativeConfig.threshold_db,
      minSilenceDuration: Duration(
        milliseconds: nativeConfig.min_silence_duration_ms,
      ),
      padding: Duration(milliseconds: nativeConfig.padding_ms),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SilenceSkipConfig &&
          runtimeType == other.runtimeType &&
          mode == other.mode &&
          thresholdDb == other.thresholdDb &&
          minSilenceDuration == other.minSilenceDuration &&
          padding == other.padding;

  @override
  int get hashCode =>
      Object.hash(mode, thresholdDb, minSilenceDuration, padding);

  @override
  String toString() =>
      'SilenceSkipConfig(mode: $mode, thresholdDb: ${thresholdDb}dB, minSilenceDuration: ${minSilenceDuration.inMilliseconds}ms, padding: ${padding.inMilliseconds}ms)';
}
