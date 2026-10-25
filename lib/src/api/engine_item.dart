import 'dart:typed_data';

import '../loader/audio_byte_provider.dart';
import '../platform/fs_helper.dart';
import 'audio_source.dart';

/// Callback signature for supplying additional items when Infinite Mix reaches
/// the end of the active queue in [LoopMode.off].
typedef InfiniteMixProvider<T> = Future<List<EngineItem<T>>> Function(int count);

/// Domain-agnostic queue item descriptor for [MiniaudioEngine].
///
/// Wraps any [AudioSource] ([FileAudioSource], [NetworkAudioSource],
/// [LiveStreamAudioSource], [MemoryAudioSource], or [AssetAudioSource]) along
/// with an optional generic user payload [data] (preserving direct pointer
/// identity `identical(itemA.data, itemB.data)`) and optional per-track
/// ReplayGain normalization metadata ([replayGainDb], [replayPeak]).
///
/// Track duration is intentionally omitted from [EngineItem] because
/// [MiniaudioPlayer] resolves the exact native duration directly upon opening
/// the underlying [AudioSource].
class EngineItem<T> {
  /// Monotonically increasing queue entry identifier assigned internally by
  /// [MiniaudioEngine] to distinguish duplicate tracks within the same queue.
  final int? id;

  /// Zero-based position of this entry in the queue sequence.
  final int position;

  /// Underlying audio source (local file, HTTP/HTTPS URL, livestream, memory, or asset).
  final AudioSource source;

  /// Optional caller-owned domain object (e.g. a `Track` or `PlaylistEntry`
  /// reference). Preserved by reference without cloning.
  final T? data;

  /// Optional ReplayGain / EBU R128 track loudness gain in decibels (e.g. `-6.5`).
  ///
  /// Automatically applied by [MiniaudioEngine] when volume normalization is
  /// enabled.
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

  /// Creates an [EngineItem] backed by a local filesystem [filePath].
  factory EngineItem.file(
    String filePath, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    final normalizedPath = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    return EngineItem<T>(
      source: FileAudioSource(normalizedPath),
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      id: id,
      position: position,
    );
  }

  /// Creates an [EngineItem] backed by a progressive HTTP/HTTPS [uri] stream.
  factory EngineItem.network(
    Uri uri, {
    Map<String, String>? headers,
    Duration? bufferAhead,
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    return EngineItem<T>(
      source: NetworkAudioSource(
        uri,
        headers: headers,
        bufferAhead: bufferAhead ?? const Duration(seconds: 30),
      ),
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      id: id,
      position: position,
    );
  }

  /// Creates an [EngineItem] backed by an infinite/continuous live audio stream
  /// (e.g. online radio, Icecast/Shoutcast).
  factory EngineItem.liveStream(
    Uri uri, {
    Map<String, String>? headers,
    Duration? jitterBuffer,
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    return EngineItem<T>(
      source: LiveStreamAudioSource(
        uri,
        headers: headers,
        jitterBuffer: jitterBuffer ?? const Duration(seconds: 5),
      ),
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      id: id,
      position: position,
    );
  }

  /// Creates an [EngineItem] from a [Uri], automatically selecting
  /// [LiveStreamAudioSource], [NetworkAudioSource], [AssetAudioSource], or
  /// [FileAudioSource].
  factory EngineItem.uri(
    Uri uri, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return isLive
          ? EngineItem<T>.liveStream(
              uri,
              headers: headers,
              jitterBuffer: bufferAhead,
              data: data,
              replayGainDb: replayGainDb,
              replayPeak: replayPeak,
              id: id,
              position: position,
            )
          : EngineItem<T>.network(
              uri,
              headers: headers,
              bufferAhead: bufferAhead,
              data: data,
              replayGainDb: replayGainDb,
              replayPeak: replayPeak,
              id: id,
              position: position,
            );
    }
    if (scheme == 'asset' || scheme == 'assets' || scheme == 'flutter-asset') {
      final raw = uri.toString().replaceFirst(
            RegExp(r'^(flutter-)?asset(s)?:///?', caseSensitive: false),
            '',
          );
      final normalized = raw.startsWith('assets/') ? raw : 'assets/$raw';
      return EngineItem<T>.asset(
        normalized,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    if (scheme == 'file' || scheme.isEmpty) {
      return EngineItem<T>.file(
        scheme == 'file' ? uri.toFilePath() : uri.toString(),
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    throw ArgumentError.value(
      uri,
      'uri',
      'Unsupported URI scheme: ${uri.scheme}',
    );
  }

  /// Creates an [EngineItem] backed by an in-memory [Uint8List] audio buffer.
  factory EngineItem.memory(
    Uint8List bytes, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    return EngineItem<T>(
      source: MemoryAudioSource(bytes),
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      id: id,
      position: position,
    );
  }

  /// Creates an [EngineItem] backed by a bundled application [assetKey].
  factory EngineItem.asset(
    String assetKey, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    int position = 0,
  }) {
    return EngineItem<T>(
      source: AssetAudioSource(assetKey),
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      id: id,
      position: position,
    );
  }

  /// Coerces a flexible [rawSource] ([EngineItem], [AudioSource], [String]
  /// file path / URL / asset, [Uri], [Uint8List], or [FileSystemEntity]) into
  /// an [EngineItem].
  factory EngineItem.fromDynamic(
    dynamic rawSource, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    int? id,
    int position = 0,
  }) {
    if (rawSource is EngineItem) {
      final rawData = rawSource.data;
      return EngineItem<T>(
        source: rawSource.source,
        id: id ?? rawSource.id,
        position: position,
        data: data ?? (rawData is T ? rawData : null),
        replayGainDb: replayGainDb ?? rawSource.replayGainDb,
        replayPeak: replayPeak ?? rawSource.replayPeak,
      );
    }
    if (rawSource is AudioSource) {
      return EngineItem<T>(
        source: rawSource,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    if (rawSource is AudioByteProvider) {
      return EngineItem<T>(
        source: CustomAudioSource(rawSource),
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    if (rawSource is Uint8List) {
      return EngineItem<T>.memory(
        rawSource,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    if (rawSource is Uri) {
      return EngineItem<T>.uri(
        rawSource,
        headers: headers,
        isLive: isLive,
        bufferAhead: bufferAhead,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    if (isFsEntity(rawSource)) {
      final path = getFsPath(rawSource);
      if (path != null) {
        return EngineItem<T>.file(
          path,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
          id: id,
          position: position,
        );
      }
    }
    if (rawSource is String) {
      final trimmed = rawSource.trim();
      if (trimmed.isEmpty) {
        return EngineItem<T>.file(
          '',
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
          id: id,
          position: position,
        );
      }
      final resolved = AudioSource.uri(
        trimmed,
        headers: headers,
        isLive: isLive,
        bufferAhead: bufferAhead,
      );
      return EngineItem<T>(
        source: resolved,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
        position: position,
      );
    }
    throw ArgumentError.value(
      rawSource,
      'rawSource',
      'Unsupported audio source type for EngineItem',
    );
  }

  /// Whether this item represents an infinite live stream (`LiveStreamAudioSource`).
  bool get isLiveStream =>
      source is LiveStreamAudioSource ||
      (source is CustomAudioSource &&
          (source as CustomAudioSource).provider.isLiveStream);

  /// Whether this item streams over HTTP/HTTPS (`NetworkAudioSource` or `LiveStreamAudioSource`).
  bool get isNetwork =>
      source is NetworkAudioSource ||
      source is LiveStreamAudioSource ||
      (source is CustomAudioSource &&
          (source as CustomAudioSource).provider.isNetwork);

  /// Returns the local filesystem path if [source] is a [FileAudioSource], or `null` otherwise.
  String? get filePath =>
      source is FileAudioSource ? (source as FileAudioSource).filePath : null;

  /// Returns the network [Uri] if [source] is a [NetworkAudioSource] or [LiveStreamAudioSource].
  Uri? get uri {
    final s = source;
    if (s is NetworkAudioSource) return s.uri;
    if (s is LiveStreamAudioSource) return s.uri;
    if (s is CustomAudioSource) return s.provider.uri;
    if (s is FileAudioSource && s.filePath.isNotEmpty) {
      return Uri.file(s.filePath);
    }
    return null;
  }

  /// Canonical key identifying the underlying audio resource.
  ///
  /// Used internally by the queue and crossfade engine to detect adjacent
  /// duplicate sources (preventing a track from crossfading into itself or
  /// repeating back-to-back on shuffle).
  String get sourceKey {
    final s = source;
    return switch (s) {
      FileAudioSource() => 'file:${s.filePath}',
      LiveStreamAudioSource() => 'live:${s.uri}',
      NetworkAudioSource() => s.isLive ? 'live:${s.uri}' : 'net:${s.uri}',
      AssetAudioSource() => 'asset:${s.assetKey}',
      MemoryAudioSource() => 'mem:${identityHashCode(s.bytes)}',
      CustomAudioSource() => 'custom:${s.provider.sourceId}',
    };
  }

  /// Whether this item has non-empty source coordinates that can be opened.
  bool get hasValidSource {
    final s = source;
    return switch (s) {
      FileAudioSource() => s.filePath.trim().isNotEmpty,
      NetworkAudioSource() => s.uri.toString().trim().isNotEmpty,
      AssetAudioSource() => s.assetKey.trim().isNotEmpty,
      MemoryAudioSource() => s.bytes.isNotEmpty,
      CustomAudioSource() => s.provider.sourceId.trim().isNotEmpty,
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
