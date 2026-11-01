import '../rust/api/types.dart' as rust_types;

/// Output PCM encoding format for live recording and offline bouncing.
enum WavFormat {
  /// 16-bit signed integer linear PCM (standard CD quality / high compatibility).
  pcm16,

  /// 32-bit floating point linear PCM (high dynamic range / broadcast standard).
  float32;

  rust_types.RustWavFormat toRust() {
    switch (this) {
      case WavFormat.pcm16:
        return rust_types.RustWavFormat.pcm16;
      case WavFormat.float32:
        return rust_types.RustWavFormat.float32;
    }
  }

  static WavFormat fromRust(rust_types.RustWavFormat rust) {
    switch (rust) {
      case rust_types.RustWavFormat.pcm16:
        return WavFormat.pcm16;
      case rust_types.RustWavFormat.float32:
        return WavFormat.float32;
    }
  }
}

/// Source routing mode for the secondary DJ Cue / headphone pre-listening device.
enum CueMode {
  /// Route Deck A audio directly to Cue output.
  deckA(0),

  /// Route Deck B audio directly to Cue output.
  deckB(1),

  /// Route composite Master mix to Cue output.
  master(2);

  final int value;
  const CueMode(this.value);

  static CueMode fromValue(int value) {
    switch (value) {
      case 0:
        return CueMode.deckA;
      case 1:
        return CueMode.deckB;
      case 2:
      default:
        return CueMode.master;
    }
  }
}

/// Configuration for microphone auto-ducking / sidechain compression.
class DuckingConfig {
  /// Whether auto-ducking is enabled when voice activity is detected.
  final bool enabled;

  /// Target attenuation in decibels applied to the music master bus (e.g. -14.0 dB).
  final double duckingDb;

  /// Detection threshold in decibels above which ducking triggers (e.g. -30.0 dB).
  final double thresholdDb;

  /// Attack time in milliseconds to ramp down the music volume (e.g. 30.0 ms).
  final double attackMs;

  /// Hold time in milliseconds after silence before releasing the duck (e.g. 250.0 ms).
  final double holdMs;

  /// Release time in milliseconds to smoothly restore full music volume (e.g. 400.0 ms).
  final double releaseMs;

  const DuckingConfig({
    this.enabled = true,
    this.duckingDb = -14.0,
    this.thresholdDb = -30.0,
    this.attackMs = 30.0,
    this.holdMs = 250.0,
    this.releaseMs = 400.0,
  });

  rust_types.RustDuckingConfig toRust() => rust_types.RustDuckingConfig(
        enabled: enabled,
        duckingDb: duckingDb,
        thresholdDb: thresholdDb,
        attackMs: attackMs,
        holdMs: holdMs,
        releaseMs: releaseMs,
      );

  static DuckingConfig fromRust(rust_types.RustDuckingConfig rust) => DuckingConfig(
        enabled: rust.enabled,
        duckingDb: rust.duckingDb,
        thresholdDb: rust.thresholdDb,
        attackMs: rust.attackMs,
        holdMs: rust.holdMs,
        releaseMs: rust.releaseMs,
      );

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

  @override
  int get hashCode =>
      enabled.hashCode ^
      duckingDb.hashCode ^
      thresholdDb.hashCode ^
      attackMs.hashCode ^
      holdMs.hashCode ^
      releaseMs.hashCode;
}

/// Configuration for the secondary DJ cue / headphone pre-listening output device.
class CueConfig {
  /// Whether cue output is currently active.
  final bool enabled;

  /// Optional hardware device ID (null for default device).
  final String? deviceId;

  /// Cue headphone monitor volume (0.0 to 2.0).
  final double volume;

  /// Source routing mode (Deck A, Deck B, or Master).
  final CueMode mode;

  const CueConfig({
    this.enabled = false,
    this.deviceId,
    this.volume = 1.0,
    this.mode = CueMode.deckA,
  });

  rust_types.RustCueConfig toRust() => rust_types.RustCueConfig(
        enabled: enabled,
        deviceId: deviceId,
        volume: volume,
        mode: mode.value,
      );

  static CueConfig fromRust(rust_types.RustCueConfig rust) => CueConfig(
        enabled: rust.enabled,
        deviceId: rust.deviceId,
        volume: rust.volume,
        mode: CueMode.fromValue(rust.mode),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CueConfig &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          deviceId == other.deviceId &&
          volume == other.volume &&
          mode == other.mode;

  @override
  int get hashCode =>
      enabled.hashCode ^ deviceId.hashCode ^ volume.hashCode ^ mode.hashCode;
}
