/// Telemetry metrics for the continuous audio buffer cache range.
class Buffer {
  /// The earliest continuous timestamp retained in RAM buffer.
  final Duration start;

  /// The furthest continuous timestamp preloaded in RAM buffer.
  final Duration end;

  /// Whether the reader is currently stalled waiting for audio chunks.
  final bool isBuffering;

  /// Creates a [Buffer] telemetry snapshot.
  const Buffer({
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.isBuffering = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Buffer &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          isBuffering == other.isBuffering;

  @override
  int get hashCode => Object.hash(start, end, isBuffering);

  @override
  String toString() =>
      'Buffer(start: $start, end: $end, isBuffering: $isBuffering)';
}
