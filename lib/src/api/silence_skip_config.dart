import 'logger.dart';

/// Operational modes for silence detection and skipping.
enum SilenceSkipMode {
  /// Silence skipping is disabled for standard playback.
  disabled(0),

  /// Trims lead-in silence at track start and lead-out silence at track end.
  ///
  /// Middle pauses are preserved, making this mode ideal for music.
  trimEdges(1),

  /// Dynamically truncates or skips continuous pauses anywhere in the track.
  ///
  /// Ideal for podcasts, audiobooks, and talk shows.
  continuous(2),

  /// Applies both edge trimming and continuous in-track pause skipping.
  all(3);

  /// The raw numeric integer mode passed across the native boundary.
  final int value;

  /// Creates a [SilenceSkipMode] backed by the native integer [value].
  const SilenceSkipMode(this.value);

  /// Converts a native integer [value] to its corresponding [SilenceSkipMode].
  ///
  /// Falls back to [SilenceSkipMode.disabled] and logs a warning if [value]
  /// does not match a known mode.
  static SilenceSkipMode fromValue(int value) => switch (value) {
        0 => SilenceSkipMode.disabled,
        1 => SilenceSkipMode.trimEdges,
        2 => SilenceSkipMode.continuous,
        3 => SilenceSkipMode.all,
        _ => () {
            MapLogger.warn(
              'Unknown SilenceSkipMode raw value $value; defaulting to disabled',
            );
            return SilenceSkipMode.disabled;
          }(),
      };
}

/// Configuration settings for dynamic silence detection and skipping.
class SilenceSkipConfig {
  /// Whether dynamic silence skipping is actively processing audio.
  final bool enabled;

  /// The operational mode of the silence detector.
  final SilenceSkipMode mode;

  /// The silence threshold in decibels full-scale (dBFS).
  ///
  /// Signals below this level are considered silence. Typical range is `-60.0`
  /// to `-30.0` dBFS (defaults to `-45.0`).
  final double thresholdDb;

  /// The minimum continuous silence duration required before skipping triggers.
  ///
  /// Natural pauses shorter than this duration are kept intact. Defaults to
  /// `300` milliseconds.
  final Duration minSilenceDuration;

  /// The safety margin preserved around non-silent audio to avoid clipping word edges.
  ///
  /// Defaults to `50` milliseconds.
  final Duration padding;

  /// Creates a [SilenceSkipConfig] with optional settings.
  ///
  /// Configures [enabled], [mode], [thresholdDb], [minSilenceDuration], and
  /// [padding].
  const SilenceSkipConfig({
    this.enabled = false,
    this.mode = SilenceSkipMode.disabled,
    this.thresholdDb = -45.0,
    this.minSilenceDuration = const Duration(milliseconds: 300),
    this.padding = const Duration(milliseconds: 50),
  });

  /// Creates a disabled [SilenceSkipConfig] with silence skipping turned off.
  const SilenceSkipConfig.off()
      : this(enabled: false, mode: SilenceSkipMode.disabled);

  /// Creates an edge-trimming [SilenceSkipConfig] suitable for music and gapless playback.
  ///
  /// Enables [SilenceSkipMode.trimEdges] using [thresholdDb],
  /// [minSilenceDuration], and [padding].
  const SilenceSkipConfig.trimEdges({
    double thresholdDb = -45.0,
    Duration minSilenceDuration = const Duration(milliseconds: 300),
    Duration padding = const Duration(milliseconds: 50),
  }) : this(
          enabled: true,
          mode: SilenceSkipMode.trimEdges,
          thresholdDb: thresholdDb,
          minSilenceDuration: minSilenceDuration,
          padding: padding,
        );

  /// Creates a continuous silence-skipping [SilenceSkipConfig] suitable for podcasts.
  ///
  /// Enables [SilenceSkipMode.continuous] using [thresholdDb],
  /// [minSilenceDuration], and [padding].
  const SilenceSkipConfig.continuous({
    double thresholdDb = -45.0,
    Duration minSilenceDuration = const Duration(milliseconds: 300),
    Duration padding = const Duration(milliseconds: 50),
  }) : this(
          enabled: true,
          mode: SilenceSkipMode.continuous,
          thresholdDb: thresholdDb,
          minSilenceDuration: minSilenceDuration,
          padding: padding,
        );

  /// Creates a [SilenceSkipConfig] enabling both edge trimming and continuous skipping.
  ///
  /// Enables [SilenceSkipMode.all] using [thresholdDb], [minSilenceDuration],
  /// and [padding].
  const SilenceSkipConfig.all({
    double thresholdDb = -45.0,
    Duration minSilenceDuration = const Duration(milliseconds: 300),
    Duration padding = const Duration(milliseconds: 50),
  }) : this(
          enabled: true,
          mode: SilenceSkipMode.all,
          thresholdDb: thresholdDb,
          minSilenceDuration: minSilenceDuration,
          padding: padding,
        );

  /// Returns a copy of this [SilenceSkipConfig] with the given fields replaced.
  ///
  /// Overrides [enabled], [mode], [thresholdDb], [minSilenceDuration], and
  /// [padding] when non-`null`.
  SilenceSkipConfig copyWith({
    bool? enabled,
    SilenceSkipMode? mode,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) {
    return SilenceSkipConfig(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      thresholdDb: thresholdDb ?? this.thresholdDb,
      minSilenceDuration: minSilenceDuration ?? this.minSilenceDuration,
      padding: padding ?? this.padding,
    );
  }

  /// Creates a [SilenceSkipConfig] from raw native field values.
  ///
  /// Converts [mode] via [SilenceSkipMode.fromValue], [minSilenceDurationMs]
  /// and [paddingMs] into [Duration] instances, and applies [enabled] and
  /// [thresholdDb].
  factory SilenceSkipConfig.fromRaw({
    bool enabled = true,
    required int mode,
    required double thresholdDb,
    required int minSilenceDurationMs,
    required int paddingMs,
  }) {
    return SilenceSkipConfig(
      enabled: enabled,
      mode: SilenceSkipMode.fromValue(mode),
      thresholdDb: thresholdDb,
      minSilenceDuration: Duration(milliseconds: minSilenceDurationMs),
      padding: Duration(milliseconds: paddingMs),
    );
  }

  /// Returns a deterministic [SilenceSkipConfig] with parameters clamped to
  /// valid DSP domain ranges.
  ///
  /// Clamps [thresholdDb] to `[-90.0, -10.0]`, [minSilenceDuration] to
  /// `[50 ms, 5000 ms]`, and [padding] to `[0 ms, minSilenceDuration / 2]`.
  SilenceSkipConfig validated() {
    final clampedThreshold = thresholdDb.clamp(-90.0, -10.0);
    final minMs = minSilenceDuration.inMilliseconds.clamp(50, 5000);
    final maxPad = minMs ~/ 2;
    final padMs = padding.inMilliseconds.clamp(0, maxPad);
    if (clampedThreshold != thresholdDb ||
        minMs != minSilenceDuration.inMilliseconds ||
        padMs != padding.inMilliseconds) {
      MapLogger.debug(
        'SilenceSkipConfig.validated() clamped parameters: '
        'thresholdDb=$thresholdDb->$clampedThreshold, '
        'minSilenceDurationMs=${minSilenceDuration.inMilliseconds}->$minMs, '
        'paddingMs=${padding.inMilliseconds}->$padMs',
      );
    }
    return SilenceSkipConfig(
      enabled: enabled,
      mode: mode,
      thresholdDb: clampedThreshold,
      minSilenceDuration: Duration(milliseconds: minMs),
      padding: Duration(milliseconds: padMs),
    );
  }

  /// Returns `true` if [other] is a [SilenceSkipConfig] with identical values.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SilenceSkipConfig &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          mode == other.mode &&
          thresholdDb == other.thresholdDb &&
          minSilenceDuration == other.minSilenceDuration &&
          padding == other.padding;

  /// Returns a hash code derived from [enabled], [mode], [thresholdDb],
  /// [minSilenceDuration], and [padding].
  @override
  int get hashCode =>
      Object.hash(enabled, mode, thresholdDb, minSilenceDuration, padding);

  /// Returns a human-readable string representation of this [SilenceSkipConfig].
  @override
  String toString() =>
      'SilenceSkipConfig(enabled: $enabled, mode: $mode, thresholdDb: ${thresholdDb}dB, minSilenceDuration: ${minSilenceDuration.inMilliseconds}ms, padding: ${padding.inMilliseconds}ms)';
}
