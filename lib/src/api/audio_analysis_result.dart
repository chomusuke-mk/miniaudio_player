import 'dart:math' as math;

import 'audio_info.dart';
import 'audio_metadata.dart';

export 'audio_info.dart';
export 'audio_metadata.dart';

/// Complete result of analyzing an audio track's acoustic, format, and DSP properties.
///
/// Contains fundamental format and stream information in [audioInfo] (duration, sample rate,
/// raw sample rate, channels, bit depth, bitrate, format, codec, container format, lossless,
/// bitrate mode, and file size) as well as optional specialized modules:
/// - [replayGain]: ITU-R BS.1770-4 / EBU R128 loudness metrics and peak (or `null` if disabled).
/// - [waveform]: Normalized amplitude envelope points (or `null` if disabled).
/// - [metadata]: Parsed metadata container (or `null` if disabled).
class AudioAnalysisResult {
  /// Core technical audio properties (sample rate, channels, bitrate, duration, format,
  /// codec, container format, lossless flag, bitrate mode, bit depth, etc.).
  /// Always extracted at zero computational cost.
  final AudioInfo audioInfo;

  /// ITU-R BS.1770-4 / EBU R128 loudness metrics, true peak sample amplitude, and recommended
  /// volume gain, or `null` if ReplayGain analysis was disabled (`replayGain: false`).
  final ReplayGainResult? replayGain;

  /// Normalized amplitude envelope points for rendering seekbars and track shapes,
  /// or `null` if Waveform extraction was disabled (`waveform: false`).
  final WaveformResult? waveform;

  /// Encapsulated metadata bytes, or `null` if metadata extraction was disabled (`metadata: false`).
  final AudioMetadata? metadata;

  /// Creates an [AudioAnalysisResult] with acoustic metrics.
  const AudioAnalysisResult({
    required this.audioInfo,
    this.replayGain,
    this.waveform,
    this.metadata,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioAnalysisResult &&
          runtimeType == other.runtimeType &&
          audioInfo == other.audioInfo &&
          replayGain == other.replayGain &&
          waveform == other.waveform &&
          metadata == other.metadata;

  @override
  int get hashCode => Object.hash(
        audioInfo,
        replayGain,
        waveform,
        metadata,
      );

  @override
  String toString() =>
      'AudioAnalysisResult(audioInfo: $audioInfo, replayGain: $replayGain, '
      'waveform: $waveform, metadata: $metadata)';
}

/// Representation of a track's normalized amplitude waveform points.
///
/// Ideal for rendering SoundCloud-style or WhatsApp-style audio seekbars,
/// progress tracks, or static waveform overviews.
class WaveformResult {
  /// Array of normalized amplitude points, where each point is scaled between `0.0` and `1.0`.
  ///
  /// Points are normalized relative to the track's highest peak so that quiet
  /// recordings still utilize the full visual height of custom UI components.
  final List<double> points;

  /// Creates a [WaveformResult] with normalized amplitude points.
  const WaveformResult({required this.points});

  /// Total number of extracted waveform points.
  int get length => points.length;

  /// Samples the waveform height at a fractional [progress] between `0.0` (start) and `1.0` (end).
  double getPointAtProgress(double progress) {
    if (points.isEmpty) return 0.0;
    final clamped = progress.clamp(0.0, 1.0);
    final index = (clamped * (points.length - 1)).round();
    return points[index];
  }

  /// Samples the waveform height corresponding to a specific playback [position]
  /// given the track's [totalDuration].
  double getPointAtPosition(Duration position, Duration totalDuration) {
    if (totalDuration.inMilliseconds <= 0) return 0.0;
    final progress = position.inMilliseconds / totalDuration.inMilliseconds;
    return getPointAtProgress(progress);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaveformResult &&
          runtimeType == other.runtimeType &&
          _listEquals(points, other.points);

  @override
  int get hashCode => Object.hashAll(points);

  @override
  String toString() => 'WaveformResult(${points.length} points)';

  static bool _listEquals(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

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

  /// Creates a [ReplayGainResult] with loudness normalization metrics.
  const ReplayGainResult({
    required this.gainDb,
    required this.peak,
    required this.lufs,
  });

  /// Computes the linear amplitude multiplier corresponding to [gainDb] (`10^(gainDb / 20)`).
  ///
  /// > [!IMPORTANT]
  /// > Instead of overwriting the user's master volume via `player.action.setVolume(...)`,
  /// > the **canonical and recommended approach** for loudness normalization is to pass
  /// > [gainDb] and [peak] directly to the `AudioSource`:
  /// > ```dart
  /// > AudioSource(
  /// >   filePath,
  /// >   replayGainDb: result.replayGain?.gainDb,
  /// >   replayPeak: result.replayGain?.peak,
  /// > )
  /// > ```
  /// > The native Rust DSP pipeline (`ReplayGainStage`) automatically applies track loudness
  /// > normalization in 32-bit floating-point PCM before master limiting, preserving gapless
  /// > transitions, crossfades, and independent user master volume controls.
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
