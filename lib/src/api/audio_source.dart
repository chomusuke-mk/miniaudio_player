part of 'miniaudio_player.dart';

/// Callback signature for supplying [count] additional items when Infinite Mix
/// reaches the end of the active queue in [LoopMode.off].
typedef InfiniteMixProvider<T> = Future<List<AudioSource<T>>> Function(
  int count,
);

/// Represents a unified source of audio playable by [MiniaudioPlayer].
///
/// Designed as a single concrete class with a unified constructor [AudioSource.new]
/// accepting:
/// - [String] (local file path on native targets, automatic OPFS path on Web for
///   relative/absolute paths without a URI scheme, `file://` on native, Android
///   `content://` / `android.resource://`, Flutter `asset://` / `package:`, remote
///   `http://`/`https://`/`icy://`/HLS `.m3u8` URLs, `ws://`/`wss://`, or `data:` URI),
/// - [Uri] (file, network, or `data:` URI),
/// - [Uint8List] / `List<int>` (raw audio bytes in RAM), or
/// - [CustomByteProvider] (custom pull-based byte stream for DRM, encrypted decryption,
///   or tokenized storage).
///
/// ### Web OPFS Automatic Path Resolution
/// On **Web**, passing a relative or absolute path without a URI scheme (for example
/// `'/temporal/sistema/test/1.wav'`, `'temporal/sistema/test/1.wav'`, or `'1.wav'`)
/// automatically resolves against the browser's Origin Private File System (OPFS) with
/// $O(1)$ RAM streaming and seek support. Leading slashes are normalized so
/// `'/temporal/sistema/test/1.wav'` and `'temporal/sistema/test/1.wav'` point to the
/// same OPFS file `'temporal/sistema/test/1.wav'`, whereas `'1.wav'` points to OPFS root.
/// The legacy `opfs://` prefix is also accepted on Web, automatically stripped from canonical
/// output, and emits an `[INFO]` log indicating it is unnecessary; outside Web, `opfs://`
/// fails with [MapResult.errorUnsupported].
///
/// Bundled Flutter assets on Web must use `'asset://...'` or `'package:...'`, and
/// network streams must include `'http://'` / `'https://'`. Playback validates OPFS
/// segment names strictly ([MapResult.errorInvalidArgs] on invalid names without
/// silent sanitization) and fails with [MapResult.errorUnsupported] if the browser or
/// context does not support OPFS.
///
/// Once in-memory [bytes] are transferred across the FFI bridge to the native Rust
/// engine, Dart clears its local byte buffer reference via [_clearBytes] so the Dart GC
/// can immediately reclaim heap memory while retaining the lightweight track metadata.
class AudioSource<T> {
  /// Internal queue entry identifier assigned by the native engine.
  int? _id;

  /// Internal monotonically increasing queue entry identifier assigned by
  /// [MiniaudioPlayer] to distinguish duplicate tracks within the same queue.
  int? get id => _id;

  /// Optional caller-owned domain object (for example, metadata or a model reference).
  ///
  /// Preserved by reference without cloning.
  final T? data;

  /// Backing field for [replayGainDb].
  double? _replayGainDb;

  /// Optional ReplayGain track loudness gain in decibels (for example, `-6.5`).
  double? get replayGainDb => _replayGainDb;

  /// Backing field for [replayPeak].
  double? _replayPeak;

  /// Optional ReplayGain linear peak amplitude (`1.0` = `0 dBFS`).
  double? get replayPeak => _replayPeak;

  /// Local file path or remote network/HLS URI string, or `null` for memory/custom sources.
  final String? uri;

  /// Backing field for [bytes] prior to FFI transfer.
  Uint8List? _bytes;

  /// Raw in-memory audio bytes prior to native transfer, or `null` if URI/custom-backed
  /// or if already transferred to the native Rust engine.
  Uint8List? get bytes => _bytes;

  /// Optional HTTP headers for network and HLS streaming sources.
  final Map<String, String>? headers;

  /// Optional custom byte stream provider for DRM or encrypted audio streams.
  final CustomByteProvider? customProvider;

  /// Whether this source is backed by raw in-memory bytes.
  final bool _isMemory;

  /// Initial byte length retained for `toString` diagnostics after [_clearBytes].
  final int _initialByteLength;

  /// Backing field for [sourceKey].
  final String _sourceKey;

  /// Backing field for [hasValidSource].
  final bool _hasValidSource;

  /// Platform-normalized URI or file path passed to the native engine.
  final String? _normalizedSource;

  /// Whether this source requires asynchronous resolution in Dart before loading.
  final bool _resolveInDart;

  /// Immediate validation error code detected during URI normalization, if any.
  final int? _directErrorCode;

  /// Diagnostic error message paired with [_directErrorCode], if any.
  final String? _directErrorMessage;

  /// Whether this source originated from in-memory bytes.
  bool get isMemory => _isMemory;

  /// Whether this source is backed by a [CustomByteProvider].
  bool get isCustom => customProvider != null;

  /// Whether this source points to a remote HTTP/HTTPS or WebSocket stream.
  bool get isNetwork {
    final u = uri?.trim().toLowerCase() ?? '';
    return u.startsWith('http://') ||
        u.startsWith('https://') ||
        u.startsWith('ws://') ||
        u.startsWith('wss://');
  }

  /// Whether this source points directly to a local file path (native paths or normalized
  /// `file://` URIs) or a Web OPFS path.
  bool get isFile =>
      !_isMemory &&
      !isCustom &&
      !isNetwork &&
      !_resolveInDart &&
      _directErrorCode == null &&
      ((_normalizedSource ?? uri)?.isNotEmpty ?? false);

  /// Internal constructor initializing all fields of [AudioSource].
  ///
  /// Stores [uri], [bytes], [headers], [customProvider], [data], [replayGainDb],
  /// [replayPeak], [internalId], [isMemory], [initialByteLength], [sourceKey],
  /// [hasValidSource], [normalizedSource], [resolveInDart], [directErrorCode],
  /// and [directErrorMessage].
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
    String? normalizedSource,
    bool resolveInDart = false,
    int? directErrorCode,
    String? directErrorMessage,
  })  : _id = internalId,
        _replayGainDb = replayGainDb,
        _replayPeak = replayPeak,
        _bytes = bytes,
        _isMemory = isMemory,
        _initialByteLength = initialByteLength,
        _sourceKey = sourceKey,
        _hasValidSource = hasValidSource,
        _normalizedSource = normalizedSource,
        _resolveInDart = resolveInDart,
        _directErrorCode = directErrorCode,
        _directErrorMessage = directErrorMessage;

  /// Normalizes [originalUri] and constructs an [AudioSource] with optional
  /// [headers], [data], [replayGainDb], [replayPeak], and [id].
  static AudioSource<T> _fromUriString<T>(
    String originalUri, {
    Map<String, String>? headers,
    T? data,
    double? replayGainDb,
    double? replayPeak,
    int? id,
  }) {
    final norm = normalizePlatformAudioSourceUri(originalUri);
    if (norm.strippedOpfsPrefix &&
        norm.directErrorCode != MapResult.errorUnsupported) {
      MapLogger.logRedundantOpfsPrefix(
        originalUri,
        canonicalPath: norm.hasError ? null : norm.normalizedSource,
      );
    }
    if (!norm.hasError &&
        norm.normalizedSource.toLowerCase().startsWith('data:')) {
      try {
        final uriData = UriData.parse(norm.normalizedSource);
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
      } catch (e) {
        MapLogger.warn('Malformed data URI "$originalUri": $e');
        return AudioSource<T>._internal(
          uri: originalUri,
          headers: headers,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
          internalId: id,
          isMemory: false,
          initialByteLength: 0,
          sourceKey: 'uri:$originalUri',
          hasValidSource: false,
          normalizedSource: norm.normalizedSource,
          resolveInDart: true,
          directErrorCode: MapResult.errorInvalidArgs,
          directErrorMessage: 'Malformed data URI "$originalUri": $e',
        );
      }
    }
    final sanitizedUri = norm.strippedOpfsPrefix && !norm.hasError
        ? norm.normalizedSource
        : originalUri;
    return AudioSource<T>._internal(
      uri: sanitizedUri,
      headers: headers,
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      internalId: id,
      isMemory: false,
      initialByteLength: 0,
      sourceKey: 'uri:$sanitizedUri',
      hasValidSource: sanitizedUri.trim().isNotEmpty && !norm.hasError,
      normalizedSource: norm.normalizedSource,
      resolveInDart: norm.resolveInDart,
      directErrorCode: norm.directErrorCode,
      directErrorMessage: norm.directErrorMessage,
    );
  }

  /// Assigns [newId] as the engine queue identifier if one has not yet been attached.
  void _attachEngineId(int newId) {
    _id ??= newId;
  }

  /// Releases the Dart-side byte buffer reference after native FFI transfer.
  void _clearBytes() {
    _bytes = null;
  }

  /// Creates an [AudioSource] from a [source] value.
  ///
  /// Supported [source] types are [String] (native path or Web OPFS relative/absolute path,
  /// URL, `asset://`, `package:`, HLS stream, or `data:` URI), [Uri], in-memory audio bytes
  /// ([Uint8List] / `List<int>`), or [CustomByteProvider].
  ///
  /// On **Web**, relative and absolute paths without a URI scheme resolve automatically to OPFS
  /// (invalid segment names fail with [MapResult.errorInvalidArgs], and unsupported browsers fail
  /// with [MapResult.errorUnsupported]); optional `opfs://` prefixes are stripped with an `[INFO]`
  /// notice. Flutter assets on Web must use `asset://` or `package:`.
  ///
  /// Optional [headers] are passed to the HTTP/HLS request when [source] is a remote URL.
  /// Optional [data] attaches a domain object, [id] pre-assigns a queue entry identifier,
  /// and [replayGainDb] and [replayPeak] provide track-level loudness normalization metadata.
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
      return AudioSource._fromUriString<T>(
        source.toString(),
        headers: headers,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
      );
    }
    if (source is String) {
      return AudioSource._fromUriString<T>(
        source.trim(),
        headers: headers,
        data: data,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        id: id,
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
    MapLogger.error(
      'Unsupported AudioSource input type: ${source.runtimeType}',
    );
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

  /// Converts this source to Rust's internal queue representation `RustAudioSource`,
  /// using [autoId] as a fallback when [id] is `null`.
  rust_types.RustAudioSource toRustSource([int? autoId]) {
    final effectiveId = id ?? autoId ?? 0;
    final rustId = PlatformInt64Util.from(effectiveId);
    if (customProvider != null) {
      final provider = customProvider!;
      final streamId = provider.streamId != 0 ? provider.streamId : effectiveId;
      final url = provider.totalBytes != null
          ? 'custom://$streamId?size=${provider.totalBytes}'
          : 'custom://$streamId';
      return rust_types.RustAudioSource(
        id: rustId,
        source: url,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        resolveInDart: false,
      );
    }
    if (_isMemory) {
      return rust_types.RustAudioSource(
        id: rustId,
        source: '',
        dataBytes: _bytes,
        replayGainDb: replayGainDb,
        replayPeak: replayPeak,
        resolveInDart: false,
      );
    }
    return rust_types.RustAudioSource(
      id: rustId,
      source: _normalizedSource ?? uri ?? '',
      headers: headers?.entries
          .map((e) => rust_types.RustHttpHeader(key: e.key, value: e.value))
          .toList(),
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      resolveInDart: _resolveInDart || _directErrorCode != null,
    );
  }

  /// Creates a copy of this [AudioSource] with updated [data], [replayGainDb], [replayPeak],
  /// [id], [uri], [bytes], [headers], or [customProvider] while preserving existing values
  /// unless overridden.
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
    if (uri != null) {
      return AudioSource._fromUriString<T>(
        uri,
        headers: headers ?? this.headers,
        data: data ?? this.data,
        replayGainDb: replayGainDb ?? this.replayGainDb,
        replayPeak: replayPeak ?? this.replayPeak,
        id: id ?? _id,
      );
    }
    final nextUri = this.uri ?? '';
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
      hasValidSource: _hasValidSource,
      normalizedSource: _normalizedSource,
      resolveInDart: _resolveInDart,
      directErrorCode: _directErrorCode,
      directErrorMessage: _directErrorMessage,
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
      normalizedSource: _normalizedSource,
      resolveInDart: _resolveInDart,
      directErrorCode: _directErrorCode,
      directErrorMessage: _directErrorMessage,
    );
  }

  /// Compares this [AudioSource] with [other] by identity, source key, data, and ReplayGain values.
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

  /// Returns a hash code combining queue ID, source key, [data], and ReplayGain metadata.
  @override
  int get hashCode => Object.hash(
        _id,
        _sourceKey,
        data,
        replayGainDb,
        replayPeak,
      );

  /// Returns a concise string representation of this [AudioSource].
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
