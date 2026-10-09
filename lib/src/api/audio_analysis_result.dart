import 'dart:math' as math;

/// Complete result of analyzing an audio track's acoustic and DSP properties.
///
/// Contains fundamental track information (duration, sample rate, channels,
/// nominal bitrate, and true peak sample amplitude) as well as optional specialized
/// analysis modules: [replayGain] and [waveform].
///
/// To conserve processing time and CPU resources, modules that were disabled
/// during analysis (e.g. `replayGain: false` or `waveform: false`) will be `null`.
class AudioAnalysisResult {
  /// Total duration of the audio track.
  final Duration duration;

  /// Native audio sample rate in Hz (e.g. 44100, 48000).
  final int sampleRate;

  /// Number of audio channels (e.g. 1 for Mono, 2 for Stereo).
  final int channels;

  /// Average nominal bitrate of the file in bits per second (bps).
  final int bitrate;

  /// Absolute true sample peak across the entire track (where `1.0` represents 0 dBFS / digital full scale).
  final double peak;

  /// ITU-R BS.1770-4 / EBU R128 loudness metrics and recommended volume gain,
  /// or `null` if ReplayGain analysis was disabled (`replayGain: false`).
  final ReplayGainResult? replayGain;

  /// Normalized amplitude envelope points for rendering seekbars and track shapes,
  /// or `null` if Waveform extraction was disabled (`waveform: false`).
  final WaveformResult? waveform;

  const AudioAnalysisResult({
    required this.duration,
    required this.sampleRate,
    required this.channels,
    required this.bitrate,
    required this.peak,
    this.replayGain,
    this.waveform,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioAnalysisResult &&
          runtimeType == other.runtimeType &&
          duration == other.duration &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          bitrate == other.bitrate &&
          peak == other.peak &&
          replayGain == other.replayGain &&
          waveform == other.waveform;

  @override
  int get hashCode => Object.hash(
        duration,
        sampleRate,
        channels,
        bitrate,
        peak,
        replayGain,
        waveform,
      );

  @override
  String toString() =>
      'AudioAnalysisResult(duration: $duration, sampleRate: $sampleRate Hz, channels: $channels, '
      'bitrate: ${bitrate ~/ 1000} kbps, peak: ${peak.toStringAsFixed(4)}, '
      'replayGain: $replayGain, waveform: $waveform)';
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

  const ReplayGainResult({
    required this.gainDb,
    required this.peak,
    required this.lufs,
  });

  /// Recommended linear volume multiplier ready to be passed to `player.action.setVolume()`.
  ///
  /// Converts [gainDb] from logarithmic decibels to linear amplitude scale: `10^(gainDb / 20)`.
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
