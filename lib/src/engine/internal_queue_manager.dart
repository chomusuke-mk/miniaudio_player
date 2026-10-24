import 'dart:async';
import 'dart:math' as math;

import '../api/engine_item.dart';
import '../api/loop_mode.dart';

/// Internal queue state machine owned exclusively by `MiniaudioEngine`.
///
/// Kept package-private so external callers cannot mutate queue indices or
/// items out-of-band without going through `MiniaudioEngine`'s serialized
/// command lane.
class InternalQueueManager<T> {
  /// Playback position threshold after which [previous] restarts the current
  /// track (for seekable sources) instead of stepping back to the prior entry.
  static const Duration restartThreshold = Duration(seconds: 3);

  int _nextEntryId = 0;
  List<EngineItem<T>> _activeQueue = [];
  List<EngineItem<T>> _originalQueue = [];
  int _currentIndex = -1;
  bool _isShuffled = false;
  LoopMode _loopMode = LoopMode.off;
  bool _infiniteMixEnabled = false;
  bool _prefetchExhausted = false;
  Future<void>? _pendingPrefetch;

  /// Callback notified whenever queue items or state are mutated asynchronously
  /// in the background (e.g. proactive Infinite Mix prefetch).
  void Function()? onQueueMutated;

  final InfiniteMixProvider<T>? infiniteMixProvider;
  final math.Random _random;

  /// Monotonic mutation counter used to detect concurrent mutations across
  /// asynchronous gaps (such as while [infiniteMixProvider] is awaiting).
  int _version = 0;

  /// Cached unmodifiable views invalidated on every mutation for O(1) reads.
  List<EngineItem<T>>? _activeView;
  List<EngineItem<T>>? _originalView;

  final StreamController<EngineItem<T>?> _nextItemController =
      StreamController<EngineItem<T>?>.broadcast(sync: true);
  EngineItem<T>? _lastEmittedNextItem;

  /// Synchronous broadcast stream emitting whenever the candidate next item
  /// for automatic crossfade changes or becomes `null`.
  Stream<EngineItem<T>?> get nextItemStream => _nextItemController.stream;

  InternalQueueManager({
    this.infiniteMixProvider,
    math.Random? random,
  }) : _random = random ?? math.Random();

  /// Whether [a] and [b] refer to the exact same queue entry and audio source.
  static bool isSameItem<T>(EngineItem<T>? a, EngineItem<T>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.id == b.id && a.sourceKey == b.sourceKey;
  }

  // --------------------------------------------------------------------------
  // Synchronous State Getters
  // --------------------------------------------------------------------------

  /// Read-only O(1) snapshot of the active playback queue.
  List<EngineItem<T>> get activeQueue =>
      _activeView ??= List<EngineItem<T>>.unmodifiable(_activeQueue);

  /// Read-only O(1) snapshot of the original un-shuffled queue sequence.
  List<EngineItem<T>> get originalQueue =>
      _originalView ??= List<EngineItem<T>>.unmodifiable(_originalQueue);

  /// Number of items in the active queue.
  int get length => _activeQueue.length;

  /// Whether the active queue is empty.
  bool get isEmpty => _activeQueue.isEmpty;

  /// Current zero-based index into [activeQueue], or `-1` if empty.
  int get currentIndex => _currentIndex;

  /// Whether the queue is currently in shuffled order.
  bool get isShuffled => _isShuffled;

  /// Current repeat policy ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  LoopMode get loopMode => _loopMode;

  /// Whether Infinite Mix prefetching is enabled.
  bool get infiniteMixEnabled => _infiniteMixEnabled;

  /// The currently active [EngineItem], or `null` if the queue is empty.
  EngineItem<T>? get currentItem =>
      (_currentIndex >= 0 && _currentIndex < _activeQueue.length)
          ? _activeQueue[_currentIndex]
          : null;

  /// Whether there is a subsequent item available according to [loopMode] and
  /// Infinite Mix.
  bool get hasNext =>
      _activeQueue.isNotEmpty &&
      (_loopMode == LoopMode.all ||
          _loopMode == LoopMode.one ||
          _currentIndex < _activeQueue.length - 1 ||
          (_infiniteMixEnabled &&
              !_prefetchExhausted &&
              infiniteMixProvider != null));

  /// Whether there is a subsequent item available that has a distinct
  /// [EngineItem.sourceKey] from the current item.
  bool get hasNextDifferent => peekNext(distinct: true) != null;

  /// Whether there is a prior item available in the queue.
  bool get hasPrevious =>
      _activeQueue.isNotEmpty &&
      (_loopMode == LoopMode.all || _currentIndex > 0);

  int? _peekNextIndex({required bool distinct}) {
    if (_activeQueue.isEmpty ||
        _currentIndex < 0 ||
        _currentIndex >= _activeQueue.length) {
      return null;
    }
    if (_loopMode == LoopMode.one) {
      return distinct ? null : _currentIndex;
    }

    int? candidateIdx;
    if (_currentIndex < _activeQueue.length - 1) {
      candidateIdx = _currentIndex + 1;
    } else if (_loopMode == LoopMode.all) {
      candidateIdx = 0;
    }
    if (candidateIdx == null) return null;

    if (distinct &&
        _activeQueue[candidateIdx].sourceKey ==
            _activeQueue[_currentIndex].sourceKey) {
      return null;
    }
    return candidateIdx;
  }

  /// Peeks the candidate next item without mutating queue state.
  ///
  /// When [distinct] is `true` (used for automatic crossfade planning):
  /// - Returns `null` if [loopMode] is [LoopMode.one].
  /// - Returns `null` if the candidate shares the same [EngineItem.sourceKey]
  ///   as the current item (e.g. a 1-track queue in [LoopMode.all] or adjacent
  ///   duplicate items).
  EngineItem<T>? peekNext({bool distinct = true}) {
    final idx = _peekNextIndex(distinct: distinct);
    return idx == null ? null : _activeQueue[idx];
  }

  /// Atomically commits [expected] as the new current item if and only if it
  /// is still the candidate returned by `peekNext(distinct: true)`.
  EngineItem<T>? commitNext(EngineItem<T> expected) {
    final idx = _peekNextIndex(distinct: true);
    if (idx == null || !isSameItem(_activeQueue[idx], expected)) return null;
    _currentIndex = idx;
    _touch();
    _notifyNextItem();
    _maybePrefetchInfiniteMix();
    return currentItem;
  }

  void _notifyNextItem() {
    if (_nextItemController.isClosed) return;
    final currentNext = peekNext(distinct: true);
    if (!isSameItem(_lastEmittedNextItem, currentNext)) {
      _lastEmittedNextItem = currentNext;
      _nextItemController.add(currentNext);
    }
  }

  void _touch() {
    _version++;
    _activeView = null;
    _originalView = null;
  }

  void _reIndexActive() {
    for (var i = 0; i < _activeQueue.length; i++) {
      final entry = _activeQueue[i];
      if (entry.position != i) {
        _activeQueue[i] = entry.copyWith(position: i);
      }
    }
  }

  void _syncOriginalIfUnshuffled() {
    if (!_isShuffled) {
      _originalQueue = List<EngineItem<T>>.from(_activeQueue);
      _originalView = null;
    }
  }

  int _indexInOriginal(EngineItem<T> item) {
    final byIdentity = _originalQueue.indexWhere((it) => identical(it, item));
    if (byIdentity != -1) return byIdentity;
    if (item.id != null) {
      final byId = _originalQueue.indexWhere((it) => it.id == item.id);
      if (byId != -1) return byId;
    }
    return _originalQueue.indexWhere((it) => it.sourceKey == item.sourceKey);
  }

  // --------------------------------------------------------------------------
  // Proactive Lookahead Infinite Mix
  // --------------------------------------------------------------------------

  bool get _shouldPrefetchInfiniteMix =>
      _infiniteMixEnabled &&
      _loopMode == LoopMode.off &&
      !_prefetchExhausted &&
      _pendingPrefetch == null &&
      infiniteMixProvider != null &&
      _activeQueue.isNotEmpty &&
      _currentIndex >= _activeQueue.length - 1;

  Future<void> _maybePrefetchInfiniteMix() async {
    if (!_shouldPrefetchInfiniteMix) return;

    final provider = infiniteMixProvider!;
    final versionBeforeFetch = _version;
    final fetchFuture = () async {
      List<EngineItem<T>> rawItems;
      try {
        rawItems = await provider(25);
      } catch (_) {
        rawItems = const [];
      }

      if (!_infiniteMixEnabled || _loopMode != LoopMode.off) {
        return;
      }
      if (versionBeforeFetch != _version) {
        unawaited(_maybePrefetchInfiniteMix());
        return;
      }

      if (rawItems.isEmpty) {
        _prefetchExhausted = true;
        _notifyNextItem();
        onQueueMutated?.call();
        return;
      }

      final existingKeys = _activeQueue.map((it) => it.sourceKey).toSet();
      var candidates = rawItems
          .where((item) => !existingKeys.contains(item.sourceKey))
          .toList();

      if (candidates.isEmpty) {
        candidates = rawItems;
      }

      if (candidates.isNotEmpty) {
        _touch();
        final mixEntries = [
          for (var i = 0; i < candidates.length; i++)
            candidates[i].copyWith(
              id: _nextEntryId++,
              position: _activeQueue.length + i,
            ),
        ];
        _activeQueue.addAll(mixEntries);
        if (_isShuffled) {
          _originalQueue.addAll(mixEntries);
          _originalView = null;
        } else {
          _syncOriginalIfUnshuffled();
        }
        _notifyNextItem();
        onQueueMutated?.call();
      }
    }();

    _pendingPrefetch = fetchFuture;
    try {
      await fetchFuture;
    } finally {
      if (identical(_pendingPrefetch, fetchFuture)) {
        _pendingPrefetch = null;
      }
    }
  }

  /// Disposes internal stream controllers.
  Future<void> dispose() async {
    onQueueMutated = null;
    await _nextItemController.close();
  }

  // --------------------------------------------------------------------------
  // Queue Initialization & Reset
  // --------------------------------------------------------------------------

  /// Replaces the entire queue with [items].
  ///
  /// - Assigns monotonically increasing entry IDs starting from `0`.
  /// - If [shuffle] is `true`:
  ///   - When [startIndex] is provided, that entry is pinned to index `0` and
  ///     the remaining entries are shuffled via Fisher-Yates without immediate
  ///     consecutive source duplicates.
  ///   - When [startIndex] is `null`, an initial entry is selected uniformly at
  ///     random to occupy index `0` and the rest are shuffled via Fisher-Yates.
  void setQueue(
    List<EngineItem<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) {
    _touch();
    _prefetchExhausted = false;
    _nextEntryId = 0;

    if (items.isEmpty) {
      _activeQueue = [];
      _originalQueue = [];
      _currentIndex = -1;
      _isShuffled = false;
      _notifyNextItem();
      return;
    }

    final normalized = [
      for (var i = 0; i < items.length; i++)
        items[i].copyWith(id: _nextEntryId++, position: i),
    ];

    _originalQueue = List<EngineItem<T>>.from(normalized);

    if (!shuffle) {
      _activeQueue = List<EngineItem<T>>.from(normalized);
      _currentIndex = (startIndex ?? 0).clamp(0, normalized.length - 1);
      _isShuffled = false;
    } else {
      _isShuffled = true;
      final chosenIndex = startIndex != null
          ? startIndex.clamp(0, normalized.length - 1)
          : _random.nextInt(normalized.length);
      final current = normalized[chosenIndex];
      final remaining = List<EngineItem<T>>.from(normalized)
        ..removeAt(chosenIndex);

      _fisherYatesShuffle(remaining);
      _avoidImmediateDuplicate(current, remaining);

      _activeQueue = [current, ...remaining];
      _reIndexActive();
      _currentIndex = 0;
    }

    _notifyNextItem();
    _maybePrefetchInfiniteMix();
  }

  void _avoidImmediateDuplicate(
    EngineItem<T> current,
    List<EngineItem<T>> remaining,
  ) {
    if (remaining.length > 1 && remaining[0].sourceKey == current.sourceKey) {
      final nonDupIdx = remaining.indexWhere(
        (it) => it.sourceKey != current.sourceKey,
      );
      if (nonDupIdx != -1) {
        final nonDup = remaining.removeAt(nonDupIdx);
        remaining.insert(0, nonDup);
      }
    }
  }

  void _fisherYatesShuffle(List<EngineItem<T>> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final temp = list[i];
      list[i] = list[j];
      list[j] = temp;
    }
  }

  // --------------------------------------------------------------------------
  // Shuffle & Un-shuffle Controls
  // --------------------------------------------------------------------------

  /// Toggles shuffle mode on or off.
  bool toggleShuffle() {
    setShuffle(!_isShuffled);
    return _isShuffled;
  }

  /// Explicitly enables or disables shuffle mode.
  ///
  /// - Enabling shuffle pins the currently active item at index `0` and
  ///   shuffles all remaining items via Fisher-Yates without interrupting
  ///   playback.
  /// - Disabling shuffle (un-shuffle) restores the exact original order while
  ///   updating [currentIndex] to point to the currently active item.
  void setShuffle(bool enabled) {
    if (_isShuffled == enabled) return;
    final current = currentItem;
    if (current == null) {
      _isShuffled = enabled;
      return;
    }
    _touch();

    if (enabled) {
      final remaining = List<EngineItem<T>>.from(_activeQueue)
        ..removeAt(_currentIndex);

      _fisherYatesShuffle(remaining);
      _avoidImmediateDuplicate(current, remaining);

      _activeQueue = [current, ...remaining];
      _reIndexActive();
      _currentIndex = 0;
      _isShuffled = true;
    } else {
      final origIdx = _indexInOriginal(current);
      _activeQueue = List<EngineItem<T>>.from(_originalQueue);
      _reIndexActive();
      if (origIdx != -1) {
        _currentIndex = origIdx;
      } else {
        _currentIndex = _currentIndex.clamp(0, _activeQueue.length - 1);
      }
      _isShuffled = false;
    }

    _notifyNextItem();
    _maybePrefetchInfiniteMix();
  }

  // --------------------------------------------------------------------------
  // Repeat Modes & Infinite Mix Configuration
  // --------------------------------------------------------------------------

  /// Sets the repeat policy ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  void setLoopMode(LoopMode mode) {
    if (_loopMode == mode) return;
    _loopMode = mode;
    if (mode == LoopMode.off) {
      _maybePrefetchInfiniteMix();
    }
    _notifyNextItem();
  }

  /// Cycles repeat policy in order: `off -> all -> one -> off`.
  LoopMode cycleLoopMode() {
    _loopMode = _loopMode.next();
    if (_loopMode == LoopMode.off) {
      _maybePrefetchInfiniteMix();
    }
    _notifyNextItem();
    return _loopMode;
  }

  /// Enables or disables proactive Infinite Mix prefetching.
  void setInfiniteMix(bool enabled) {
    if (_infiniteMixEnabled == enabled) return;
    _infiniteMixEnabled = enabled;
    if (enabled) {
      _prefetchExhausted = false;
      _maybePrefetchInfiniteMix();
    }
    _notifyNextItem();
  }

  // --------------------------------------------------------------------------
  // Queue Mutations
  // --------------------------------------------------------------------------

  /// Inserts [item] immediately after the currently active item.
  void insertNext(EngineItem<T> item) {
    _touch();
    _prefetchExhausted = false;
    final entry = item.copyWith(id: _nextEntryId++);

    if (_activeQueue.isEmpty) {
      final first = entry.copyWith(position: 0);
      _activeQueue = [first];
      _originalQueue = [first];
      _currentIndex = 0;
      _notifyNextItem();
      _maybePrefetchInfiniteMix();
      return;
    }

    final insertIdx = (_currentIndex + 1).clamp(0, _activeQueue.length);
    _activeQueue.insert(insertIdx, entry);
    _reIndexActive();

    if (_isShuffled) {
      final origIdx = _indexInOriginal(_activeQueue[_currentIndex]);
      if (origIdx != -1) {
        _originalQueue.insert(origIdx + 1, entry);
      } else {
        _originalQueue.add(entry);
      }
      _originalView = null;
    } else {
      _syncOriginalIfUnshuffled();
    }

    _notifyNextItem();
    _maybePrefetchInfiniteMix();
  }

  /// Appends [items] to the end of the queue.
  void append(List<EngineItem<T>> items) {
    if (items.isEmpty) return;

    if (_activeQueue.isEmpty) {
      setQueue(items);
      return;
    }

    _touch();
    _prefetchExhausted = false;

    final normalized = [
      for (var i = 0; i < items.length; i++)
        items[i].copyWith(
          id: _nextEntryId++,
          position: _activeQueue.length + i,
        ),
    ];

    _activeQueue.addAll(normalized);

    if (_isShuffled) {
      _originalQueue.addAll(normalized);
      _originalView = null;
    } else {
      _syncOriginalIfUnshuffled();
    }

    _notifyNextItem();
    _maybePrefetchInfiniteMix();
  }

  /// Removes the item at [index] from both the active and original queues.
  ///
  /// Returns a record with the `removed` item and whether the removed entry
  /// `wasCurrent` (`index == currentIndex` before removal).
  ({EngineItem<T>? removed, bool wasCurrent}) remove(int index) {
    if (index < 0 || index >= _activeQueue.length) {
      return (removed: null, wasCurrent: false);
    }
    _touch();
    _prefetchExhausted = false;

    final wasCurrent = index == _currentIndex;
    final removedItem = _activeQueue.removeAt(index);
    _reIndexActive();

    if (_isShuffled) {
      final origIdx = _indexInOriginal(removedItem);
      if (origIdx != -1) {
        _originalQueue.removeAt(origIdx);
        _originalView = null;
      }
    } else {
      _syncOriginalIfUnshuffled();
    }

    if (_activeQueue.isEmpty) {
      _currentIndex = -1;
      _notifyNextItem();
      return (removed: removedItem, wasCurrent: wasCurrent);
    }

    if (index < _currentIndex) {
      _currentIndex--;
    } else if (wasCurrent && _currentIndex >= _activeQueue.length) {
      _currentIndex = _activeQueue.length - 1;
    }

    _notifyNextItem();
    _maybePrefetchInfiniteMix();
    return (removed: removedItem, wasCurrent: wasCurrent);
  }

  /// Moves the item at [from] to [to] while keeping [currentIndex] anchored
  /// to the currently playing item.
  void reorder(int from, int to) {
    if (from < 0 ||
        from >= _activeQueue.length ||
        to < 0 ||
        to >= _activeQueue.length ||
        from == to) {
      return;
    }
    _touch();

    final item = _activeQueue.removeAt(from);
    _activeQueue.insert(to, item);
    _reIndexActive();

    if (_currentIndex == from) {
      _currentIndex = to;
    } else if (from < _currentIndex && to >= _currentIndex) {
      _currentIndex--;
    } else if (from > _currentIndex && to <= _currentIndex) {
      _currentIndex++;
    }

    _syncOriginalIfUnshuffled();
    _notifyNextItem();
    _maybePrefetchInfiniteMix();
  }

  /// Jumps directly to [index] in [activeQueue].
  EngineItem<T>? jumpTo(int index) {
    if (index >= 0 && index < _activeQueue.length) {
      _currentIndex = index;
      _touch();
      _notifyNextItem();
      _maybePrefetchInfiniteMix();
      return currentItem;
    }
    return null;
  }

  /// Clears the queue.
  ///
  /// When [keepCurrent] is `true` and there is an active item, that item is
  /// retained as the sole entry at index `0` without interrupting playback.
  void clear({bool keepCurrent = false}) {
    _touch();
    _prefetchExhausted = false;
    final current = keepCurrent ? currentItem : null;
    if (current != null) {
      final entry = current.copyWith(position: 0);
      _activeQueue = [entry];
      _originalQueue = [entry];
      _currentIndex = 0;
      _isShuffled = false;
      _nextEntryId = math.max(_nextEntryId, (entry.id ?? 0) + 1);
    } else {
      _nextEntryId = 0;
      _activeQueue = [];
      _originalQueue = [];
      _currentIndex = -1;
      _isShuffled = false;
    }
    _notifyNextItem();
    if (keepCurrent && current != null) {
      _maybePrefetchInfiniteMix();
    }
  }

  // --------------------------------------------------------------------------
  // Track Navigation & Transitions
  // --------------------------------------------------------------------------

  /// Advances to the next item according to [loopMode] and [isManual].
  ///
  /// - In [LoopMode.one] when `isManual == false`, returns the same
  ///   [currentItem] so the engine restarts it.
  /// - Awaits any in-flight Infinite Mix prefetch before deciding end-of-queue.
  /// - Returns `null` when reaching the end of the queue in [LoopMode.off].
  Future<EngineItem<T>?> next({bool isManual = true}) async {
    if (_activeQueue.isEmpty) return null;

    if (!isManual && _loopMode == LoopMode.one) {
      return currentItem;
    }

    if (_pendingPrefetch != null) {
      await _pendingPrefetch;
    }

    if (_currentIndex < _activeQueue.length - 1) {
      _currentIndex++;
      _touch();
      _notifyNextItem();
      _maybePrefetchInfiniteMix();
      return currentItem;
    }

    if (_loopMode == LoopMode.off &&
        _infiniteMixEnabled &&
        !_prefetchExhausted &&
        infiniteMixProvider != null) {
      await _maybePrefetchInfiniteMix();
      if (_currentIndex < _activeQueue.length - 1) {
        _currentIndex++;
        _touch();
        _notifyNextItem();
        _maybePrefetchInfiniteMix();
        return currentItem;
      }
    }

    if (_loopMode == LoopMode.all) {
      _currentIndex = 0;
      _touch();
      _notifyNextItem();
      return currentItem;
    }

    if (_loopMode == LoopMode.one && isManual) {
      _currentIndex = 0;
      _touch();
      _notifyNextItem();
      return currentItem;
    }

    return null;
  }

  /// Steps backward in the queue.
  ///
  /// Returns the new [currentItem] after stepping back, or `null` when the
  /// engine should **restart the current item** instead:
  /// - Current playback [position] exceeds [restartThreshold] (and the item is
  ///   not a livestream), or
  /// - There is no prior item ([LoopMode.off] at index `0`).
  EngineItem<T>? previous({
    Duration position = Duration.zero,
    bool isLiveStream = false,
  }) {
    if (_activeQueue.isEmpty) return null;

    if (!isLiveStream && position > restartThreshold) {
      return null;
    }

    if (_currentIndex > 0) {
      _currentIndex--;
      _touch();
      _notifyNextItem();
      return currentItem;
    }

    if (_loopMode == LoopMode.all && _activeQueue.length > 1) {
      _currentIndex = _activeQueue.length - 1;
      _touch();
      _notifyNextItem();
      return currentItem;
    }

    return null;
  }
}
