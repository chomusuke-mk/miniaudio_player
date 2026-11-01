import '../rust/api/types.dart' as rust_types;
import 'audio_source.dart';

/// Callback signature for supplying additional items when Infinite Mix reaches
/// the end of the active queue in LoopMode.off.
typedef InfiniteMixProvider<T> = Future<List<EngineItem<T>>> Function(int count);

/// Domain-agnostic queue item descriptor for `MiniaudioEngine`.
///
/// Wraps any [AudioSource] along with an optional generic user payload [data]
/// and optional per-track ReplayGain normalization metadata ([replayGainDb], [replayPeak]).
class EngineItem<T> {
  /// Monotonically increasing queue entry identifier assigned internally by
  /// `MiniaudioEngine` to distinguish duplicate tracks within the same queue.
  final int? id;

  /// Zero-based position of this entry in the queue sequence.
  final int position;

  /// Underlying audio source.
  final AudioSource source;

  /// Optional caller-owned domain object (e.g. a `Track` or `PlaylistEntry`
  /// reference). Preserved by reference without cloning.
  final T? data;

  /// Optional ReplayGain / EBU R128 track loudness gain in decibels (e.g. `-6.5`).
  final double? replayGainDb;

  /// Optional ReplayGain linear peak amplitude (`1.0` = `0 dBFS`).
  final double? replayPeak;

  /// Creates an [EngineItem] wrapping [source].
  const EngineItem({
    required this.source,
    this.data,
    this.replayGainDb,
    this.replayPeak,
    this.id,
    this.position = 0,
  });

  /// Factory creating an [EngineItem] directly from a String path/URL, audio bytes, or [AudioSource].
  factory EngineItem.from(
    Object source, {
    Map<String, String>? headers,
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    final audioSource = source is AudioSource
        ? source
        : AudioSource(source, headers: headers);
    return EngineItem<T>(
      source: audioSource,
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      id: id,
      position: position,
    );
  }

  /// Converts this item to Rust's internal queue representation.
  rust_types.RustEngineItem toRustItem([int? autoId]) {
    final effectiveId = id ?? autoId ?? position;
    return switch (source) {
      UriAudioSource s => rust_types.RustEngineItem(
          id: effectiveId,
          source: s.sourceString,
          headers: s.headers?.entries
              .map((e) => rust_types.RustHttpHeader(key: e.key, value: e.value))
              .toList(),
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      MemoryAudioSource s => rust_types.RustEngineItem(
          id: effectiveId,
          source: '',
          dataBytes: s.bytes,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      CustomAudioSource s => rust_types.RustEngineItem(
          id: effectiveId,
          source: 'custom://${s.provider.streamId}',
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
    };
  }

  /// Canonical key identifying the underlying audio resource.
  String get sourceKey {
    final s = source;
    return switch (s) {
      UriAudioSource() => 'uri:${s.sourceString}',
      MemoryAudioSource() => 'mem:${identityHashCode(s.bytes)}',
      CustomAudioSource() => 'custom:${s.provider.streamId}',
    };
  }

  /// Whether this item has non-empty source coordinates that can be opened.
  bool get hasValidSource {
    final s = source;
    return switch (s) {
      UriAudioSource() => s.sourceString.trim().isNotEmpty,
      MemoryAudioSource() => s.bytes.isNotEmpty,
      CustomAudioSource() => true,
    };
  }

  /// Creates a copy of this [EngineItem] with updated fields while preserving
  /// the exact [data] reference unless explicitly overridden.
  EngineItem<T> copyWith({
    int? id,
    int? position,
    AudioSource? source,
    T? data,
    double? replayGainDb,
    double? replayPeak,
  }) {
    return EngineItem<T>(
      id: id ?? this.id,
      position: position ?? this.position,
      source: source ?? this.source,
      data: data ?? this.data,
      replayGainDb: replayGainDb ?? this.replayGainDb,
      replayPeak: replayPeak ?? this.replayPeak,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineItem<T> &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          position == other.position &&
          sourceKey == other.sourceKey &&
          data == other.data &&
          replayGainDb == other.replayGainDb &&
          replayPeak == other.replayPeak;

  @override
  int get hashCode => Object.hash(
        id,
        position,
        sourceKey,
        data,
        replayGainDb,
        replayPeak,
      );

  @override
  String toString() =>
      'EngineItem<$T>(id: $id, position: $position, source: $sourceKey, data: $data)';
}
