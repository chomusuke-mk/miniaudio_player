/// Repeat / loop policy for [MiniaudioEngine] queue navigation.
enum LoopMode {
  /// Queue stops after the final item finishes (unless Infinite Mix is enabled).
  off,

  /// Repeats the currently active item indefinitely on natural completion.
  /// Manual skips (`next` / `previous`) still advance across the queue.
  one,

  /// Wraps around from the final item back to index `0` (and from index `0`
  /// to the final item on `previous`).
  all;

  /// Cycles to the next repeat mode in standard order: `off -> all -> one -> off`.
  LoopMode next() {
    switch (this) {
      case LoopMode.off:
        return LoopMode.all;
      case LoopMode.all:
        return LoopMode.one;
      case LoopMode.one:
        return LoopMode.off;
    }
  }
}

/// Alias for [LoopMode] maintained for ergonomic compatibility.
typedef Loop = LoopMode;
