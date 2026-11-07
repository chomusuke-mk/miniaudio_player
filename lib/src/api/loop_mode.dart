/// Repeat and loop policy for [MiniaudioPlayer] queue navigation.
enum LoopMode {
  /// Playback stops after the final item finishes (unless Infinite Mix is enabled).
  off,

  /// Repeats the currently active item indefinitely on natural completion.
  ///
  /// Manual skips (`next` or `previous`) still advance across the queue.
  one,

  /// Wraps around from the final item back to index `0` on forward playback,
  /// and from index `0` to the final item on `previous`.
  all,
}
