/// Telemetry metrics for the continuous audio buffer cache range.
class Buffer {
  /// Earliest continuous timestamp retained in the RAM buffer.
  final Duration start;

  /// Furthest continuous timestamp preloaded in the RAM buffer.
  final Duration end;

  /// Whether the reader is currently stalled waiting for audio chunks.
  final bool isBuffering;

  /// Creates a [Buffer] telemetry snapshot with [start], [end], and [isBuffering].
  const Buffer({
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.isBuffering = false,
  });

  /// Compares this [Buffer] snapshot with [other] for value equality.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Buffer &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          isBuffering == other.isBuffering;

  /// Returns a hash code derived from [start], [end], and [isBuffering].
  @override
  int get hashCode => Object.hash(start, end, isBuffering);

  /// Returns a readable string representation of this [Buffer] snapshot.
  @override
  String toString() =>
      'Buffer(start: $start, end: $end, isBuffering: $isBuffering)';
}
