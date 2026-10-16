/// Telemetry metrics for the unified sliding-window circular buffer cache.
///
/// Designed to render smooth, semi-transparent preloaded range bars
/// in audio/video player user interfaces (similar to YouTube, Spotify, or Soundcloud).
class BufferedRange {
  /// Earliest continuous timestamp retained in RAM buffer.
  final Duration start;

  /// Furthest continuous timestamp preloaded in RAM buffer.
  final Duration end;

  /// Total duration of the track, or [Duration.zero] if unknown / live stream.
  final Duration duration;

  final double _fillPercentage;
  final double _streamPercentage;

  /// Whether the reader is currently stalled waiting for network provider chunks.
  final bool isBuffering;

  /// Whether the provider reached end of file / stream.
  final bool isEof;

  const BufferedRange({
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.duration = Duration.zero,
    double? fillPercentage,
    double? streamPercentage,
    this.isBuffering = false,
    this.isEof = false,
  })  : _fillPercentage = fillPercentage ?? -1.0,
        _streamPercentage = streamPercentage ?? -1.0;

  /// Fraction (0.0 to 1.0) of the buffer capacity currently filled.
  double get fillPercentage {
    if (_fillPercentage >= 0.0) return _fillPercentage;
    if (duration > Duration.zero) {
      return (windowDuration.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  /// Fraction (0.0 to 1.0) of the total audio stream loaded into the buffer.
  /// Used directly to draw a preloaded progress bar on a seekbar.
  double get streamPercentage {
    if (_streamPercentage >= 0.0) return _streamPercentage;
    if (duration > Duration.zero) {
      return (end.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  /// Total duration of audio currently held in the RAM window.
  Duration get windowDuration => end > start ? end - start : Duration.zero;

  /// Alias for [streamPercentage] (0.0 to 1.0).
  double get percentage => streamPercentage;

  /// Returns `true` if [position] falls continuously within the loaded window [start, end].
  bool contains(Duration position) => position >= start && position <= end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BufferedRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          duration == other.duration &&
          (fillPercentage - other.fillPercentage).abs() < 0.001 &&
          (streamPercentage - other.streamPercentage).abs() < 0.001 &&
          isBuffering == other.isBuffering &&
          isEof == other.isEof;

  @override
  int get hashCode => Object.hash(
        start,
        end,
        duration,
        (fillPercentage * 1000).round(),
        (streamPercentage * 1000).round(),
        isBuffering,
        isEof,
      );

  @override
  String toString() =>
      'BufferedRange(start: $start, end: $end, duration: $duration, '
      'streamPercentage: ${(streamPercentage * 100).toStringAsFixed(1)}%, '
      'fillPercentage: ${(fillPercentage * 100).toStringAsFixed(1)}%, '
      'isBuffering: $isBuffering)';
}
