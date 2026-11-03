/// Telemetry metrics for the continuous audio buffer cache range.
class BufferedRange {
  /// Earliest continuous timestamp retained in RAM buffer.
  final Duration start;

  /// Furthest continuous timestamp preloaded in RAM buffer.
  final Duration end;

  /// Whether the reader is currently stalled waiting for audio chunks.
  final bool isBuffering;

  const BufferedRange({
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.isBuffering = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BufferedRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          isBuffering == other.isBuffering;

  @override
  int get hashCode => Object.hash(start, end, isBuffering);

  @override
  String toString() =>
      'BufferedRange(start: $start, end: $end, isBuffering: $isBuffering)';
}
