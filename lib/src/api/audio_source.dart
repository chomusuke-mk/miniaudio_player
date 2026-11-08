part of 'miniaudio_player.dart';

/// Callback signature for supplying additional items when Infinite Mix reaches
/// the end of the active queue in `LoopMode.off`.
typedef InfiniteMixProvider<T> = Future<List<AudioSource<T>>> Function(
  int count,
);

/// Represents a unified source of audio playable by `MiniaudioPlayer`.
///
/// Designed as a single concrete class with a single unified constructor [AudioSource.new]
/// accepting:
/// - [String] (local file path, remote HTTP/HTTPS URL, HLS m3u8 stream, `data:` URI),
/// - [Uri] (file, network, or `data:` URI),
/// - [Uint8List] / `List<int>` (raw audio bytes in RAM), or
/// - [CustomByteProvider] (custom pull-based byte stream for DRM, encrypted decryption,
///   or tokenized storage).
///
/// Once in-memory [bytes] are transferred across the FFI bridge to the native Rust
/// engine, Dart clears its local byte buffer reference via [_clearBytes] so the Dart GC
/// can immediately reclaim heap memory while retaining the lightweight track metadata.
class AudioSource<T> {
  int? _id;

  /// Internal monotonically increasing queue entry identifier assigned by
  /// `MiniaudioPlayer` to distinguish duplicate tracks within the same queue.
  int? get id => _id;

  /// Optional caller-owned domain object (e.g. metadata or model reference).
  /// Preserved by reference without cloning.
  final T? data;

  double? _replayGainDb;

  /// Optional ReplayGain track loudness gain in decibels (e.g. `-6.5`).
  double? get replayGainDb => _replayGainDb;

  double? _replayPeak;

  /// Optional ReplayGain linear peak amplitude (`1.0` = `0 dBFS`).
  double? get replayPeak => _replayPeak;

  /// Local file path or remote network/HLS URI string, or `null` for memory/custom sources.
  final String? uri;

  Uint8List? _bytes;

  /// Raw in-memory audio bytes prior to native transfer, or `null` if URI/custom-backed
  /// or if already transferred to the native Rust engine.
  Uint8List? get bytes => _bytes;

  /// Optional HTTP headers for network and HLS streaming sources.
  final Map<String, String>? headers;

  /// Optional custom byte stream provider for DRM or encrypted audio streams.
  final CustomByteProvider? customProvider;

  final bool _isMemory;
  final int _initialByteLength;
  final String _sourceKey;
  final bool _hasValidSource;

  /// Whether this source originated from in-memory bytes.
  bool get isMemory => _isMemory;

  /// Whether this source is backed by a [CustomByteProvider].
  bool get isCustom => customProvider != null;

  /// Whether this source points to a remote HTTP/HTTPS network stream.
  bool get isNetwork {
    final u = uri?.trim().toLowerCase() ?? '';
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /// Whether this source points to a local file path.
  bool get isFile =>
      !_isMemory && !isCustom && !isNetwork && (uri != null && uri!.isNotEmpty);

  AudioSource._internal({
    this.uri,
    Uint8List? bytes,
    this.headers,
    this.customProvider,
    this.data,
    double? replayGainDb,
    double? replayPeak,
    int? internalId,
    required bool isMemory,
    required int initialByteLength,
    required String sourceKey,
    required bool hasValidSource,
  })  : _id = internalId,
        _replayGainDb = replayGainDb,
        _replayPeak = replayPeak,
        _bytes = bytes,
        _isMemory = isMemory,
        _initialByteLength = initialByteLength,
        _sourceKey = sourceKey,
        _hasValidSource = hasValidSource;

  void _attachEngineId(int newId) {
    _id ??= newId;
  }

  void _clearBytes() {
    _bytes = null;
  }

  /// Creates an [AudioSource] from a [String] (local path, URL, HLS stream, `data:` URI),
  /// a [Uri], in-memory audio bytes ([Uint8List] / `List<int>`), or a [CustomByteProvider].
  ///
  /// Optional [headers] are passed to the HTTP/HLS request when [source] is a remote URL.
  /// Optional [data] attaches a domain object, while [replayGainDb] and [replayPeak]
  /// provide track-level loudness normalization metadata.
  factory AudioSource(
    Object source, {
    Map<String, String>? headers,
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
  }) {
    if (source is CustomByteProvider) {
      return AudioSource<T>._internal(
        customProvider: source,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        internalId: id,
        isMemory: false,
        initialByteLength: 0,
        sourceKey: 'custom:${source.streamId}',
        hasValidSource: true,
      );
    }
    if (source is Uri) {
      if (source.data != null) {
        final decoded = source.data!.contentAsBytes();
        return AudioSource<T>._internal(
          bytes: decoded,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
          internalId: id,
          isMemory: true,
          initialByteLength: decoded.lengthInBytes,
          sourceKey: 'mem:${identityHashCode(decoded)}',
          hasValidSource: decoded.isNotEmpty,
        );
      }
      final uriStr = source.toString();
      return AudioSource<T>._internal(
        uri: uriStr,
        headers: headers,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        internalId: id,
        isMemory: false,
        initialByteLength: 0,
        sourceKey: 'uri:$uriStr',
        hasValidSource: uriStr.trim().isNotEmpty,
      );
    }
    if (source is String) {
      final str = source.trim();
      if (str.toLowerCase().startsWith('data:')) {
        try {
          final uriData = UriData.parse(str);
          final decoded = uriData.contentAsBytes();
          return AudioSource<T>._internal(
            bytes: decoded,
            data: data,
            replayGainDb: replayGainDb,
            replayPeak: replayPeak,
            internalId: id,
            isMemory: true,
            initialByteLength: decoded.lengthInBytes,
            sourceKey: 'mem:${identityHashCode(decoded)}',
            hasValidSource: decoded.isNotEmpty,
          );
        } catch (_) {
          return AudioSource<T>._internal(
            uri: str,
            headers: headers,
            data: data,
            replayGainDb: replayGainDb,
            replayPeak: replayPeak,
            internalId: id,
            isMemory: false,
            initialByteLength: 0,
            sourceKey: 'uri:$str',
            hasValidSource: str.isNotEmpty,
          );
        }
      }
      return AudioSource<T>._internal(
        uri: str,
        headers: headers,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        internalId: id,
        isMemory: false,
        initialByteLength: 0,
        sourceKey: 'uri:$str',
        hasValidSource: str.isNotEmpty,
      );
    }
    if (source is Uint8List) {
      return AudioSource<T>._internal(
        bytes: source,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        internalId: id,
        isMemory: true,
        initialByteLength: source.lengthInBytes,
        sourceKey: 'mem:${identityHashCode(source)}',
        hasValidSource: source.isNotEmpty,
      );
    }
    if (source is List<int>) {
      final listBytes = Uint8List.fromList(source);
      return AudioSource<T>._internal(
        bytes: listBytes,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        internalId: id,
        isMemory: true,
        initialByteLength: listBytes.lengthInBytes,
        sourceKey: 'mem:${identityHashCode(listBytes)}',
        hasValidSource: listBytes.isNotEmpty,
      );
    }
    throw ArgumentError.value(
      source,
      'source',
      'AudioSource requires a String (path or URL), Uri, Uint8List (audio bytes), or CustomByteProvider, got ${source.runtimeType}',
    );
  }

  /// Canonical key identifying the underlying audio resource.
  String get sourceKey => _sourceKey;

  /// Whether this item has non-empty source coordinates that can be played.
  bool get hasValidSource => _hasValidSource;

  /// Converts this source to Rust's internal queue representation.
  rust_types.RustAudioSource toRustSource([int? autoId]) {
    final effectiveId = id ?? autoId ?? 0;
    if (customProvider != null) {
      final provider = customProvider!;
      final streamId = provider.streamId != 0 ? provider.streamId : effectiveId;
      final url = provider.totalBytes != null
          ? 'custom://$streamId?size=${provider.totalBytes}'
          : 'custom://$streamId';
      return rust_types.RustAudioSource(
        id: effectiveId,
        source: url,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
      );
    }
    if (_isMemory) {
      return rust_types.RustAudioSource(
        id: effectiveId,
        source: '',
        dataBytes: _bytes,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
      );
    }
    return rust_types.RustAudioSource(
      id: effectiveId,
      source: uri ?? '',
      headers: headers?.entries
          .map((e) => rust_types.RustHttpHeader(key: e.key, value: e.value))
          .toList(),
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
    );
  }

  /// Creates a copy of this [AudioSource] with updated fields while preserving
  /// the internal identifier and data unless overridden.
  AudioSource<T> copyWith({
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
    String? uri,
    Uint8List? bytes,
    Map<String, String>? headers,
    CustomByteProvider? customProvider,
  }) {
    final nextProvider = customProvider ?? this.customProvider;
    if (nextProvider != null) {
      return AudioSource<T>._internal(
        customProvider: nextProvider,
        data: data ?? this.data,
        replayGainDb: replayGainDb ?? this.replayGainDb,
        replayPeak: replayPeak ?? this.replayPeak,
        internalId: id ?? _id,
        isMemory: false,
        initialByteLength: 0,
        sourceKey: 'custom:${nextProvider.streamId}',
        hasValidSource: true,
      );
    }
    if (_isMemory && uri == null) {
      final nextBytes = bytes ?? _bytes;
      return AudioSource<T>._internal(
        bytes: nextBytes,
        data: data ?? this.data,
        replayGainDb: replayGainDb ?? this.replayGainDb,
        replayPeak: replayPeak ?? this.replayPeak,
        internalId: id ?? _id,
        isMemory: true,
        initialByteLength: nextBytes?.lengthInBytes ?? _initialByteLength,
        sourceKey: _sourceKey,
        hasValidSource: _hasValidSource,
      );
    }
    final nextUri = uri ?? this.uri ?? '';
    return AudioSource<T>._internal(
      uri: nextUri,
      headers: headers ?? this.headers,
      data: data ?? this.data,
      replayGainDb: replayGainDb ?? this.replayGainDb,
      replayPeak: replayPeak ?? this.replayPeak,
      internalId: id ?? _id,
      isMemory: false,
      initialByteLength: 0,
      sourceKey: 'uri:$nextUri',
      hasValidSource: nextUri.trim().isNotEmpty,
    );
  }

  /// Returns a copy of this [AudioSource] associated with a new generic data payload [data]
  /// and specialized to the new generic type parameter [R].
  AudioSource<R> withData<R>(R? data) {
    return AudioSource<R>._internal(
      uri: uri,
      bytes: _bytes,
      headers: headers,
      customProvider: customProvider,
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      internalId: _id,
      isMemory: _isMemory,
      initialByteLength: _initialByteLength,
      sourceKey: _sourceKey,
      hasValidSource: _hasValidSource,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioSource &&
          runtimeType == other.runtimeType &&
          _id == other._id &&
          _sourceKey == other._sourceKey &&
          data == other.data &&
          replayGainDb == other.replayGainDb &&
          replayPeak == other.replayPeak;

  @override
  int get hashCode => Object.hash(
        _id,
        _sourceKey,
        data,
        replayGainDb,
        replayPeak,
      );

  @override
  String toString() {
    if (customProvider != null) {
      return 'AudioSource(streamId: ${customProvider!.streamId})';
    }
    if (_isMemory) {
      return 'AudioSource(${_bytes?.lengthInBytes ?? _initialByteLength} bytes)';
    }
    return 'AudioSource(${uri ?? ''})';
  }
}
