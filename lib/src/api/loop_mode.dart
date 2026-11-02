/// Repeat / loop policy for [MiniaudioEngine] queue navigation.
enum LoopMode {
  /// Queue stops after the final item finishes (unless Infinite Mix is enabled).
  off,

  /// Repeats the currently active item indefinitely on natural completion.
  /// Manual skips (`next` / `previous`) still advance across the queue.
  one,

  /// Wraps around from the final item back to index `0` (and from index `0`
  /// to the final item on `previous`).
  all,
}
