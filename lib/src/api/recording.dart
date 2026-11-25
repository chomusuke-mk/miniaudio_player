import '../rust/api/types.dart' as rust_types;

/// Output PCM encoding format for live recording and offline bouncing.
enum WavFormat {
  /// 16-bit signed integer linear PCM (standard CD quality / high compatibility).
  pcm16,

  /// 32-bit floating point linear PCM (high dynamic range / broadcast standard).
  float32;

  /// Converts this [WavFormat] to its corresponding native [rust_types.RustWavFormat].
  rust_types.RustWavFormat toRust() {
    switch (this) {
      case WavFormat.pcm16:
        return rust_types.RustWavFormat.pcm16;
      case WavFormat.float32:
        return rust_types.RustWavFormat.float32;
    }
  }

  /// Resolves a [WavFormat] from a native [rust_types.RustWavFormat].
  static WavFormat fromRust(rust_types.RustWavFormat rust) {
    switch (rust) {
      case rust_types.RustWavFormat.pcm16:
        return WavFormat.pcm16;
      case rust_types.RustWavFormat.float32:
        return WavFormat.float32;
    }
  }
}

/// Configuration for microphone auto-ducking / sidechain compression.
class DuckingConfig {
  /// Whether auto-ducking is enabled when voice activity is detected.
  final bool enabled;

  /// The target attenuation in decibels applied to the music master bus (e.g. -14.0 dB).
  final double duckingDb;

  /// The detection threshold in decibels above which ducking triggers (e.g. -30.0 dB).
  final double thresholdDb;

  /// The attack time in milliseconds to ramp down the music volume (e.g. 30.0 ms).
  final double attackMs;

  /// The hold time in milliseconds after silence before releasing the duck (e.g. 250.0 ms).
  final double holdMs;

  /// The release time in milliseconds to smoothly restore full music volume (e.g. 400.0 ms).
  final double releaseMs;

  /// Creates a [DuckingConfig] with sidechain compression parameters.
  ///
  /// Configures [enabled], attenuation [duckingDb], trigger [thresholdDb],
  /// [attackMs] ramp-down, [holdMs] sustain, and [releaseMs] recovery times.
  const DuckingConfig({
    this.enabled = true,
    this.duckingDb = -14.0,
    this.thresholdDb = -30.0,
    this.attackMs = 30.0,
    this.holdMs = 250.0,
    this.releaseMs = 400.0,
  });

  /// Converts this configuration to its native [rust_types.RustDuckingConfig] representation.
  rust_types.RustDuckingConfig toRust() => rust_types.RustDuckingConfig(
        enabled: enabled,
        duckingDb: duckingDb,
        thresholdDb: thresholdDb,
        attackMs: attackMs,
        holdMs: holdMs,
        releaseMs: releaseMs,
      );

  /// Resolves a [DuckingConfig] from its native [rust_types.RustDuckingConfig].
  static DuckingConfig fromRust(rust_types.RustDuckingConfig rust) =>
      DuckingConfig(
        enabled: rust.enabled,
        duckingDb: rust.duckingDb,
        thresholdDb: rust.thresholdDb,
        attackMs: rust.attackMs,
        holdMs: rust.holdMs,
        releaseMs: rust.releaseMs,
      );

  /// Returns `true` when [other] is a [DuckingConfig] with identical parameters.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DuckingConfig &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          duckingDb == other.duckingDb &&
          thresholdDb == other.thresholdDb &&
          attackMs == other.attackMs &&
          holdMs == other.holdMs &&
          releaseMs == other.releaseMs;

  /// Returns a hash code combining all sidechain compression parameters.
  @override
  int get hashCode =>
      enabled.hashCode ^
      duckingDb.hashCode ^
      thresholdDb.hashCode ^
      attackMs.hashCode ^
      holdMs.hashCode ^
      releaseMs.hashCode;
}
